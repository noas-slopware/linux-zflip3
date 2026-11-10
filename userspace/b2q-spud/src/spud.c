// SPDX-License-Identifier: MIT
/*
 * b2q-spud: the secure-world services the Galaxy Z Flip3's fingerprint TA
 * depends on, set up the way Samsung/Qualcomm's Android stack does at boot
 * (keymaster HAL, hermesd), over the kernel's /dev/qsee-app.
 *
 *   1. keymaster64 (resident, loaded by ABL): KM_NEW_CONFIGURE with stock's
 *      OS version and patch levels, then KEYMASTER_SPU_INIT with a buffer
 *      handed to the secure processor (VMID CP_SPSS_SP_SHARED) for the boot.
 *   2. hwvault: loaded and kept loaded (securefp derives its template key
 *      from it, QSEE service 0x89), with its root of trust set from the
 *      saved blob, or generated and saved once.
 *
 * Before any of that, in stock's order (spdaemon, sec_nvm): the SPSS GLINK
 * edge's channels are bound to rpmsg_chrdev as they appear: sp_kernel,
 * sec_nvm_<app> (served here, see nvm.c) and, once the SPSS kernel partition
 * is open (NVM_READY), sp_keymaster. Then keymaster64 and hwvault.
 *
 * It then stays up holding hwvault and serving sec_nvm until it is stopped.
 */
#include <dirent.h>
#include <pthread.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <unistd.h>
#include "qcom_qsee_app.h"	/* copy of the kernel uapi header (patch 0049) */
#include "spud.h"
#include <systemd/sd-daemon.h>
#include <systemd/sd-device.h>
#include <systemd/sd-event.h>

#define STATE_DIR	"/var/lib/b2q-spud"
#define HVR_FILE	STATE_DIR "/hwvault.hvr"

/* keymaster64 */
#define KM_SBUF		0x5000
#define KM_SPU_BUF	0x5000
#define VMID_CP_SPSS_SP_SHARED 0x22
#define KM_ERR_SPU_ALREADY_INIT (-10006)
/* QCBOR map {0x16: count, os_version 150000, os_patchlevel 202608, vendor_patchlevel 20260805} */
static const uint8_t km_configure[37] = {
	0x16, 0x21, 0x00, 0x00, 0xa4, 0x16, 0x03, 0x1a, 0x30, 0x00, 0x02, 0xc1, 0x1a,
	0x00, 0x02, 0x49, 0xf0, 0x1a, 0x30, 0x00, 0x02, 0xc2, 0x1a, 0x00, 0x03, 0x17,
	0x70, 0x1a, 0x30, 0x00, 0x02, 0xce, 0x1a, 0x01, 0x35, 0x27, 0xc5,
};

/* hwvault, hv_msg framing: u32 cmd, u32 payload_len, then tagged items */
#define HV_PATH		"qcom/sm8350/Samsung/b2q/hwvault"
#define HV_SBUF		0x14100
#define HV_MSG		0xa080
#define HV_CMD_TEST	0x2710
#define HV_CMD_GEN_ROT	0x271b
#define HV_CMD_SET_ROT	0x271c
#define HV_TAG_RET	0x01000001u
#define HV_TAG_ROT	0x0200000fu
#define HV_TAG_LOG	0x020003e8u
#define HV_RET_ROT_BROKEN 0x11

static int app_open(const char *path, uint32_t sbuf, int must_be_resident)
{
	struct qsee_app_load req = { .sbuf_size = sbuf };
	int fd = open("/dev/qsee-app", O_RDWR | O_CLOEXEC);

	if (fd < 0) {
		fprintf(stderr, "b2q-spud: /dev/qsee-app: %m\n");
		return -1;
	}
	snprintf(req.path, sizeof(req.path), "%s", path);
	if (ioctl(fd, QSEE_APP_IOC_LOAD, &req) < 0) {
		fprintf(stderr, "b2q-spud: loading %s: %m\n", path);
		close(fd);
		return -1;
	}
	if (must_be_resident && (req.flags & QSEE_APP_LOADED_HERE)) {
		fprintf(stderr, "b2q-spud: %s was not resident\n", path);
		close(fd);
		return -1;
	}
	fprintf(stderr, "b2q-spud: %s: app id %u%s\n", path, req.app_id,
		(req.flags & QSEE_APP_LOADED_HERE) ? " (loaded)" : "");
	return fd;
}

static int app_send(int fd, void *req, uint32_t req_len, void *rsp, uint32_t rsp_len)
{
	struct qsee_app_send s = {
		.req = (uintptr_t)req, .req_len = req_len,
		.rsp = (uintptr_t)rsp, .rsp_len = rsp_len,
	};

	return ioctl(fd, QSEE_APP_IOC_SEND, &s);
}

static int32_t rd32(const uint8_t *p) { int32_t v; memcpy(&v, p, 4); return v; }

/* ---- keymaster64 ---- */

static int km_setup(void)
{
	uint8_t req[0x10], rsp[0x40] = { 0 };
	struct qsee_app_vmbuf vb = {
		.size = KM_SPU_BUF, .vmid = VMID_CP_SPSS_SP_SHARED, .flags = QSEE_APP_VMBUF_KEEP,
	};
	uint32_t cmd = 0x20d, len = KM_SPU_BUF;
	int fd, st;

	fd = app_open("resident/keymaster64", KM_SBUF, 1);
	if (fd < 0)
		return -1;

	/* SEND copies the request area back too, so it must be writable */
	uint8_t cfg[sizeof(km_configure)];

	memcpy(cfg, km_configure, sizeof(cfg));
	if (app_send(fd, cfg, sizeof(cfg), rsp, sizeof(rsp)) < 0) {
		fprintf(stderr, "b2q-spud: KM_NEW_CONFIGURE: %m\n");
		return -1;
	}
	st = rd32(rsp);
	fprintf(stderr, "b2q-spud: keymaster64 configure: %d\n", st);
	if (st)
		return -1;

	if (ioctl(fd, QSEE_APP_IOC_VMBUF, &vb) < 0) {
		fprintf(stderr, "b2q-spud: SPU buffer: %m\n");
		return -1;
	}
	memcpy(req, &cmd, 4);
	memcpy(req + 4, &vb.phys, 8);
	memcpy(req + 12, &len, 4);
	memset(rsp, 0, sizeof(rsp));
	if (app_send(fd, req, sizeof(req), rsp, sizeof(rsp)) < 0) {
		fprintf(stderr, "b2q-spud: KEYMASTER_SPU_INIT: %m\n");
		return -1;
	}
	st = rd32(rsp);
	fprintf(stderr, "b2q-spud: keymaster64 SPU init (buffer %#llx): %d\n",
		(unsigned long long)vb.phys, st);
	close(fd);	/* the buffer stays with the SPSS for the boot */
	return st == 0 || st == KM_ERR_SPU_ALREADY_INIT ? 0 : -1;
}

/* ---- hwvault ---- */

static uint8_t hv_req[HV_MSG], hv_rsp[HV_MSG];

/* Send one hv_msg; return the handler's ret item (or -1), print the TA's log lines */
static long hv_cmd(int fd, uint32_t cmd, const uint8_t *items, uint32_t items_len,
		   uint8_t *blob, uint32_t *blob_len)
{
	uint32_t n, p = 8;
	long ret = -1;

	memset(hv_req, 0, sizeof(hv_req));
	memcpy(hv_req, &cmd, 4);
	memcpy(hv_req + 4, &items_len, 4);
	if (items_len)
		memcpy(hv_req + 8, items, items_len);
	memset(hv_rsp, 0, sizeof(hv_rsp));
	if (app_send(fd, hv_req, sizeof(hv_req), hv_rsp, sizeof(hv_rsp)) < 0) {
		fprintf(stderr, "b2q-spud: hwvault cmd %#x: %m\n", cmd);
		return -1;
	}
	memcpy(&n, hv_rsp + 4, 4);
	if (n > sizeof(hv_rsp) - 8)
		return -1;
	while (p + 8 <= 8 + n) {
		uint32_t tag, v;

		memcpy(&tag, hv_rsp + p, 4);
		memcpy(&v, hv_rsp + p + 4, 4);
		p += 8;
		if (tag >> 24 == 1) {
			if (tag == HV_TAG_RET)
				ret = v;
			continue;
		}
		if (v > 8 + n - p)
			break;
		if (tag == HV_TAG_LOG)
			fprintf(stderr, "b2q-spud: hwvault: %.*s\n", (int)strnlen((char *)hv_rsp + p, v),
				(char *)hv_rsp + p);
		else if (tag == HV_TAG_ROT && blob && blob_len && v <= *blob_len) {
			memcpy(blob, hv_rsp + p, v);
			*blob_len = v;
		}
		p += v;
	}
	return ret;
}

static int hv_set_rot(int fd, const uint8_t *blob, uint32_t len)
{
	uint8_t items[8 + 4096];
	uint32_t tag = HV_TAG_ROT;

	if (len > sizeof(items) - 8)
		return -1;
	memcpy(items, &tag, 4);
	memcpy(items + 4, &len, 4);
	memcpy(items + 8, blob, len);
	return (int)hv_cmd(fd, HV_CMD_SET_ROT, items, 8 + len, NULL, NULL);
}

static int save_blob(const uint8_t *blob, uint32_t len)
{
	int fd;

	mkdir(STATE_DIR, 0700);
	fd = open(HVR_FILE ".new", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (fd < 0)
		return -1;
	if (write(fd, blob, len) != (ssize_t)len || fsync(fd)) {
		close(fd);
		return -1;
	}
	close(fd);
	return rename(HVR_FILE ".new", HVR_FILE);
}

/* As hermesd: hand the saved root of trust back, or create it once. */
static void hv_rot(int fd)
{
	static uint8_t blob[4096];
	uint32_t len = sizeof(blob);
	int in = open(HVR_FILE, O_RDONLY | O_CLOEXEC);
	long r;

	if (in >= 0) {
		ssize_t n = read(in, blob, sizeof(blob));

		close(in);
		if (n > 0) {
			r = hv_set_rot(fd, blob, (uint32_t)n);
			fprintf(stderr, "b2q-spud: hwvault set ROT: %ld\n", r);
			if (r == 0 || r != HV_RET_ROT_BROKEN)
				return;
			fprintf(stderr, "b2q-spud: saved ROT is broken, making a new one\n");
		}
	}
	r = hv_cmd(fd, HV_CMD_GEN_ROT, NULL, 0, blob, &len);
	fprintf(stderr, "b2q-spud: hwvault generate ROT: %ld (%u bytes)\n", r, r == 0 ? len : 0);
	if (r != 0)
		return;
	if (save_blob(blob, len))
		fprintf(stderr, "b2q-spud: saving %s: %m\n", HVR_FILE);
	r = hv_set_rot(fd, blob, len);
	fprintf(stderr, "b2q-spud: hwvault set ROT: %ld\n", r);
}

/* ---- the SPSS channels (spdaemon and sec_nvm's part) ---- */

#define SPSS_EDGE	"1885008.glink-edge"
#define NVM_WAIT_USEC	(60ULL * 1000000)

static sd_event *ev;
static int hv_fd = -1, secure_done, keymaster_bound, kernel_bound, nvm_ready_seen;
static char keymaster_dev[128];

/* rpmsg device name "<edge>.<channel>.-1.-1" -> channel */
static int channel_of(const char *dev, char *out, size_t n)
{
	size_t el = strlen(SPSS_EDGE);
	const char *end;

	if (strncmp(dev, SPSS_EDGE ".", el + 1))
		return -1;
	dev += el + 1;
	end = strstr(dev, ".-1.-1");
	if (!end || (size_t)(end - dev) >= n)
		return -1;
	memcpy(out, dev, end - dev);
	out[end - dev] = '\0';
	return 0;
}

static int write_file(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	ssize_t r;

	if (fd < 0)
		return -1;
	r = write(fd, val, strlen(val));
	close(fd);
	return r == (ssize_t)strlen(val) ? 0 : -1;
}

/* Bind the channel to rpmsg_chrdev (this opens it towards the SPSS) and open its /dev/rpmsgN */
static int bind_channel(const char *dev, int want_fd)
{
	char path[256], node[280] = "";
	struct dirent *de;
	DIR *d;

	snprintf(path, sizeof(path), "/sys/bus/rpmsg/devices/%s/driver_override", dev);
	if (write_file(path, "rpmsg_chrdev")) {
		spud_log("%s: driver_override: %m", dev);
		return -1;
	}
	if (write_file("/sys/bus/rpmsg/drivers/rpmsg_chrdev/bind", dev) && errno != EBUSY) {
		spud_log("%s: bind: %m", dev);
		return -1;
	}
	if (!want_fd)
		return 0;
	snprintf(path, sizeof(path), "/sys/bus/rpmsg/devices/%s/rpmsg", dev);
	d = opendir(path);
	if (!d) {
		spud_log("%s: no rpmsg chardev: %m", dev);
		return -1;
	}
	while ((de = readdir(d)))
		if (!strncmp(de->d_name, "rpmsg", 5) && strcmp(de->d_name, "rpmsg_ctrl"))
			snprintf(node, sizeof(node), "/dev/%s", de->d_name);
	closedir(d);
	if (!node[0])
		return -1;
	return open(node, O_RDWR | O_CLOEXEC);
}

/*
 * keymaster64 and hwvault run on their own thread: generating the root key
 * makes the SPSS work, and it may need sec_nvm answered meanwhile.
 */
static void *secure_thread(void *arg)
{
	(void)arg;
	if (km_setup())
		spud_log("keymaster64 setup failed; the SPSS key path will not work");
	hv_fd = app_open(HV_PATH, HV_SBUF, 0);
	if (hv_fd < 0 || hv_cmd(hv_fd, HV_CMD_TEST, NULL, 0, NULL, NULL) != 1000) {
		spud_log("hwvault does not answer");
		return NULL;
	}
	hv_rot(hv_fd);
	sd_notify(0, "STATUS=holding hwvault, serving sec_nvm");
	return NULL;
}

static void secure_setup(void)
{
	pthread_t t;

	if (secure_done)
		return;
	secure_done = 1;
	if (pthread_create(&t, NULL, secure_thread, NULL)) {
		spud_log("cannot start the keymaster64 thread");
		return;
	}
	pthread_detach(t);
}

static void hexdump(const char *what, const uint8_t *b, size_t n)
{
	char line[3 * 32 + 1];

	for (size_t o = 0; o < n; o += 32) {
		size_t k = n - o < 32 ? n - o : 32, w = 0;

		for (size_t i = 0; i < k; i++)
			w += snprintf(line + w, sizeof(line) - w, "%02x ", b[o + i]);
		spud_log("%s +%#04zx: %s", what, o, line);
	}
}

static void on_nvm_ready(void)
{
	nvm_ready_seen = 1;
	spud_log("SPSS kernel partition ready (NVM_READY)");
	if (keymaster_dev[0] && !keymaster_bound && !bind_channel(keymaster_dev, 0)) {
		keymaster_bound = 1;
		spud_log("sp_keymaster opened from HLOS");
	}
	secure_setup();
}

static int on_nvm_msg(sd_event_source *s, int fd, uint32_t revents, void *userdata)
{
	static uint8_t in[4096], out[4096];
	struct nvm_part *nvm = userdata;
	int was_ready = nvm_ready(nvm);
	uint32_t hdr[2];
	ssize_t n;
	size_t r;

	if (revents & (EPOLLHUP | EPOLLERR)) {
		spud_log("a sec_nvm channel closed");
		return sd_event_source_set_enabled(s, SD_EVENT_OFF);
	}
	n = read(fd, in, sizeof(in));
	if (n < 8)
		return 0;
	memcpy(hdr, in, 8);	/* {u32 0, u32 txn_id}: the reply echoes txn_id */
	hexdump("sec_nvm <", in, (size_t)n);
	r = nvm_handle(nvm, in + 8, (size_t)n - 8, out + 8, sizeof(out) - 8);
	if (r) {
		hdr[0] = 0;
		memcpy(out, hdr, 8);
		hexdump("sec_nvm >", out, 8 + r);
		if (write(fd, out, 8 + r) != (ssize_t)(8 + r))
			spud_log("sec_nvm: reply: %m");
	}
	if (!was_ready && nvm_ready(nvm))
		on_nvm_ready();
	return 0;
}

static void on_channel(sd_device *d)
{
	const char *name;
	char ch[64];
	int fd;

	if (sd_device_get_sysname(d, &name) < 0 || channel_of(name, ch, sizeof(ch)))
		return;
	if (!strcmp(ch, "sp_kernel")) {
		if (!kernel_bound && !bind_channel(name, 0)) {
			kernel_bound = 1;
			spud_log("sp_kernel opened");
		}
	} else if (!strncmp(ch, "sec_nvm_", 8)) {
		/* one sec_nvm manager per channel, as stock runs one per SPSS app */
		struct nvm_part *nvm = nvm_new(ch);

		if (!nvm)
			return;
		fd = bind_channel(name, 1);
		if (fd < 0) {
			free(nvm);
			return;
		}
		sd_event_add_io(ev, NULL, fd, EPOLLIN, on_nvm_msg, nvm);
		spud_log("serving %s", ch);
	} else if (!strcmp(ch, "sp_keymaster")) {
		snprintf(keymaster_dev, sizeof(keymaster_dev), "%s", name);
		if (nvm_ready_seen && !keymaster_bound && !bind_channel(name, 0))
			keymaster_bound = 1;
	}
}

static int on_uevent(sd_device_monitor *m, sd_device *d, void *userdata)
{
	sd_device_action_t a;

	(void)m;
	(void)userdata;
	if (sd_device_get_action(d, &a) >= 0 && a == SD_DEVICE_ADD)
		on_channel(d);
	return 0;
}

static int on_nvm_timeout(sd_event_source *s, uint64_t usec, void *userdata)
{
	(void)s;
	(void)usec;
	(void)userdata;
	/*
	 * Stock spdaemon waits for NVM_READY before it touches keymaster64, and
	 * keymaster64 latches a failed SPSS link until reboot: keep waiting.
	 */
	if (!secure_done)
		spud_log("no NVM_READY from the SPSS after %llu s, still waiting", NVM_WAIT_USEC / 1000000);
	return 0;
}

int main(void)
{
	sd_device_monitor *mon = NULL;
	sd_device_enumerator *e = NULL;
	uint64_t now;

	if (sd_event_default(&ev) < 0)
		return 1;
	sd_event_add_signal(ev, NULL, SIGTERM | SD_EVENT_SIGNAL_PROCMASK, NULL, NULL);
	sd_event_add_signal(ev, NULL, SIGINT | SD_EVENT_SIGNAL_PROCMASK, NULL, NULL);

	if (sd_device_monitor_new(&mon) >= 0) {
		sd_device_monitor_filter_add_match_subsystem_devtype(mon, "rpmsg", NULL);
		sd_device_monitor_attach_event(mon, ev);
		sd_device_monitor_start(mon, on_uevent, NULL);
	}
	/* channels already there: sp_kernel first, as stock spdaemon opens it before sec_nvm starts */
	if (sd_device_enumerator_new(&e) >= 0) {
		sd_device_enumerator_add_match_subsystem(e, "rpmsg", 1);
		sd_device_enumerator_add_match_sysname(e, SPSS_EDGE ".sp_kernel.-1.-1");
		for (sd_device *d = sd_device_enumerator_get_device_first(e); d;
		     d = sd_device_enumerator_get_device_next(e))
			on_channel(d);
		sd_device_enumerator_unref(e);
	}
	if (sd_device_enumerator_new(&e) >= 0) {
		sd_device_enumerator_add_match_subsystem(e, "rpmsg", 1);
		for (sd_device *d = sd_device_enumerator_get_device_first(e); d;
		     d = sd_device_enumerator_get_device_next(e))
			on_channel(d);
		sd_device_enumerator_unref(e);
	}

	sd_event_now(ev, CLOCK_MONOTONIC, &now);
	sd_event_add_time(ev, NULL, CLOCK_MONOTONIC, now + NVM_WAIT_USEC, 0, on_nvm_timeout, NULL);
	sd_notify(0, "READY=1\nSTATUS=waiting for the SPSS");
	sd_event_loop(ev);

	sd_notify(0, "STOPPING=1");
	if (hv_fd >= 0)
		close(hv_fd);	/* unloads hwvault; securefp cannot seal templates without it */
	sd_device_monitor_unref(mon);
	sd_event_unref(ev);
	return 0;
}
