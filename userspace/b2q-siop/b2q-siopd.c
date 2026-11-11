// SPDX-License-Identifier: MIT
/*
 * b2q-siopd: Samsung's skin temperature (LRP2) and its SIOP CPU/GPU limits on
 * the Galaxy Z Flip3, done the way stock does them.
 *
 * Every 10 s, as stock's thermal HAL (vendor.samsung.hardware.thermal@1.0):
 *   - read 11 sensors: seven PMK8350 ADC thermistors through stock's own
 *     tables, four modem thermistors from their thermal zones;
 *   - update its three virtual sensors (FCAM, UPSPK, DNSPK);
 *   - evaluate mercury.json's heatmap as 8 linear forms (AP2/CHG2/MEM2/WIFI2,
 *     front and rear) and take LRP2 as SDHMS does: the max, rear faces only
 *     while the phone is folded.
 * Then, as SamsungDeviceHealthManagerService's SIOP: the SIOP level, and the AP
 * component's CPUFreqMax and GPUFreqMax limiters (step 0, so their limits move
 * along Samsung's frequency tables in steps), applied the way stock's
 * cpufreq_limit applies CPUFreqMax to the three clusters.
 *
 * The model data comes from the stock firmware (tools/extract-siop-data.py).
 * B2Q_SIOP_ROOT=<dir> runs against a fake tree: one tick per line on stdin
 * ("<boottime ms>"), a status line per tick on stdout.
 */

#define _GNU_SOURCE
#include <alsa/asoundlib.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/input.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

#define INVALID		-999
#define TICK_MS		10000		/* the HAL's polling interval */
#define LID_DELAY_MS	30000		/* SDHMS applies a fold change after 30 s */

enum input { AP, BAT, SUBBATRAW, USB, CHG, WIFI, CF, PATHM, PA1THM, LRPTHM, MMWTHM,
	     FCAM, UPSPK, DNSPK, NINPUT };
static const char *const input_names[NINPUT] = {
	"AP", "BAT", "SUBBATRAW", "USB", "CHG", "WIFI", "CF", "PATHM", "PA1THM",
	"LRPTHM", "MMWTHM", "FCAM", "UPSPK", "DNSPK",
};

/* ADC inputs: our vadc label, stock's table, samples (sec_battery reads 5) */
static const struct { enum input in; const char *label, *table; int samples; } adc_inputs[] = {
	{ AP,		"ap_thm",	"ap_therm",	1 },
	{ WIFI,		"wf_thm",	"wf_therm",	1 },
	{ CF,		"cf_thm",	"cf_therm",	1 },
	{ BAT,		"wpc_thm",	"temp",		5 },
	{ USB,		"usb_thm",	"usb_temp",	5 },
	{ CHG,		"chg_thm",	"chg_temp",	5 },
	{ SUBBATRAW,	"sub_bat_thm",	"sub_bat_temp",	5 },
};

/* the modem's QMI sensors (kernel patch 0108) */
static const struct { enum input in; const char *zone; } zone_inputs[] = {
	{ PATHM,	"lte-pa1-thermal" },
	{ PA1THM,	"lte-pa2-thermal" },
	{ LRPTHM,	"mmw-pa1-thermal" },
	{ MMWTHM,	"mmw-pa3-thermal" },
};

static const char *const face_names[8] = {
	"AP2_F", "CHG2_F", "MEM2_F", "WIFI2_F", "AP2_R", "CHG2_R", "MEM2_R", "WIFI2_R",
};

struct table {
	char name[24];
	int n;
	int adc[32];
	int temp[32];
};

struct stepper {			/* SDHMS O1.X1 */
	long period;			/* ms between steps */
	long acc, last;
	int d, e, f;			/* last LRP, its rise, the rise before */
};

struct limiter {			/* SDHMS O1.Z1 with step 0 */
	const char *name;
	int n;
	int temp[16];
	int value[16];
	int level;
	int cur;			/* current limit, -1 released */
	int *list;			/* stock's frequency list, descending */
	int nlist;
	struct stepper st;
};

static struct {
	const char *root;
	bool sim;
	double form_c[8];
	double form_k[8][NINPUT];
	struct table tables[16];
	int ntables;
	int lv_n, lv_id[16], lv_temp[16];
	int release;
	struct limiter cpu, gpu;
	/* hardware */
	char iio[256];
	char zone[4][256];
	char front_cam[256];
	char lid_dev[256];
	int policy_max[3];		/* cpuinfo_max_freq of policy0, 4, 7 */
	int s_fmax, g_fmin, p_fmin, g_fmax, p_fmax, big_min;
	int vf_prime[32], vf_gold[32], nvf;
	char gpu_dir[256];
	long gpu_max_hz;
	/* state */
	double fcam, upspk, dnspk;	/* the HAL's virtual sensors, INVALID until first set */
	int ap_hist[15], ap_nhist;	/* SDHMS's AP filter */
	bool folded, lid_seen;
	long lid_change_at;
	int applied_cpu[3], applied_gpu_mhz;
} g;

static void find_zones(void);

static void logmsg(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

static void path(char *buf, size_t len, const char *fmt, ...)
{
	char rel[512];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(rel, sizeof(rel), fmt, ap);
	va_end(ap);
	snprintf(buf, len, "%s%s", g.root, rel);
}

static int read_str(const char *p, char *buf, size_t len)
{
	int fd = open(p, O_RDONLY | O_CLOEXEC);
	ssize_t n;

	if (fd < 0)
		return -errno;
	n = read(fd, buf, len - 1);
	close(fd);
	if (n < 0)
		return -errno;
	buf[n] = 0;
	while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' '))
		buf[--n] = 0;
	return 0;
}

static int read_long(const char *p, long *v)
{
	char buf[64], *end;
	int ret = read_str(p, buf, sizeof(buf));

	if (ret)
		return ret;
	errno = 0;
	*v = strtol(buf, &end, 10);
	return errno || end == buf ? -EINVAL : 0;
}

static int write_long(const char *p, long v)
{
	char buf[32];
	int fd = open(p, O_WRONLY | O_CLOEXEC);
	int n = snprintf(buf, sizeof(buf), "%ld\n", v);
	ssize_t w;

	if (fd < 0)
		return -errno;
	w = write(fd, buf, n);
	close(fd);
	return w == n ? 0 : -EIO;
}

static int read_list(const char *p, int *out, int max)
{
	char buf[1024], *s, *tok;
	int n = 0;

	if (read_str(p, buf, sizeof(buf)))
		return -1;
	for (s = buf; (tok = strsep(&s, " \t\n")) && n < max;)
		if (*tok)
			out[n++] = atoi(tok);
	return n;
}

/* ---- model data ---- */

static int parse_ints(char *s, int *out, int max)
{
	char *tok;
	int n = 0;

	while ((tok = strsep(&s, ",:")) && n < max)
		out[n++] = atoi(tok);
	return n;
}

static int load_model(const char *file)
{
	char line[8192];
	FILE *f = fopen(file, "re");
	int forms = 0;

	if (!f) {
		logmsg("%s: %m (generate it with tools/extract-siop-data.py)", file);
		return -1;
	}
	g.release = 350;
	while (fgets(line, sizeof(line), f)) {
		char *s = line, *kw = strsep(&s, " \n");

		if (!kw || !*kw || *kw == '#')
			continue;
		if (!strcmp(kw, "form")) {
			char *name = strsep(&s, " "), *tok;
			int i;

			for (i = 0; i < 8 && strcmp(face_names[i], name); i++)
				;
			if (i == 8)
				goto bad;
			g.form_c[i] = strtod(strsep(&s, " "), NULL);
			while ((tok = strsep(&s, " \n"))) {
				char *eq = strchr(tok, '=');
				int k;

				if (!eq)
					continue;
				*eq = 0;
				for (k = 0; k < NINPUT && strcmp(input_names[k], tok); k++)
					;
				if (k == NINPUT)
					goto bad;
				g.form_k[i][k] = strtod(eq + 1, NULL);
			}
			forms++;
		} else if (!strcmp(kw, "table") && g.ntables < 16) {
			struct table *t = &g.tables[g.ntables++];

			snprintf(t->name, sizeof(t->name), "%s", strsep(&s, " "));
			t->n = parse_ints(strsep(&s, " "), t->adc, 32);
			if (parse_ints(strsep(&s, " \n"), t->temp, 32) != t->n || t->n < 2)
				goto bad;
		} else if (!strcmp(kw, "levels")) {
			char *tok;

			while ((tok = strsep(&s, " \n")) && g.lv_n < 16)
				if (*tok && sscanf(tok, "%d:%d", &g.lv_id[g.lv_n], &g.lv_temp[g.lv_n]) == 2)
					g.lv_n++;
		} else if (!strcmp(kw, "limiter")) {
			char *name = strsep(&s, " ");
			struct limiter *l = !strcmp(name, "CPUFreqMax") ? &g.cpu :
					    !strcmp(name, "GPUFreqMax") ? &g.gpu : NULL;

			if (!l)
				continue;
			l->n = parse_ints(strsep(&s, " "), l->temp, 16);
			if (parse_ints(strsep(&s, " \n"), l->value, 16) != l->n)
				goto bad;
		} else if (!strcmp(kw, "release")) {
			g.release = atoi(strsep(&s, " \n"));
		}
	}
	fclose(f);
	if (forms != 8 || !g.cpu.n || !g.gpu.n || !g.lv_n) {
		logmsg("%s: incomplete", file);
		return -1;
	}
	return 0;
bad:
	fclose(f);
	logmsg("%s: cannot parse: %s", file, line);
	return -1;
}

static const struct table *find_table(const char *name)
{
	for (int i = 0; i < g.ntables; i++)
		if (!strcmp(g.tables[i].name, name))
			return &g.tables[i];
	return NULL;
}

/* sec_thermistor's convert_adc_to_temper (sec_battery's is the same) */
static int adc_to_temp(const struct table *t, int adc)
{
	int low = 0, high = t->n - 1;

	if (t->adc[low] >= adc)
		return t->temp[low];
	if (t->adc[high] <= adc)
		return t->temp[high];
	while (low <= high) {
		int mid = (low + high) / 2;

		if (t->adc[mid] > adc)
			high = mid - 1;
		else if (t->adc[mid] < adc)
			low = mid + 1;
		else
			return t->temp[mid];
	}
	return t->temp[high] + (t->temp[low] - t->temp[high]) * (adc - t->adc[high]) /
	       (t->adc[low] - t->adc[high]);
}

/*
 * Stock reads these channels as SCALE_HW_CALIB_DEFAULT: the code times 1.875 V
 * over 0x70e4, which is what its tables are in.
 */
static int read_adc_uv(const char *label, int *uv)
{
	char p[512];
	long code;

	snprintf(p, sizeof(p), "%s/in_temp_%s_raw", g.iio, label);
	if (read_long(p, &code))
		return -1;
	if (code > 0x7fff)
		code = 0;
	*uv = (int)(code * 1875000LL / 0x70e4);
	return 0;
}

/* sec_battery's sec_bat_get_adc_data, its min/max bookkeeping included */
static int read_adc_avg(const char *label, int count, int *uv)
{
	int total = 0, max = 0, min = 0xFFFF, v;

	if (count < 3)
		count = 3;
	for (int i = 0; i < count; i++) {
		if (read_adc_uv(label, &v))
			return -1;
		if (i) {
			if (v > max)
				max = v;
			else if (v < min)
				min = v;
		} else {
			max = min = v;
		}
		total += v;
	}
	*uv = (total - max - min) / (count - 2);
	return 0;
}

/* ---- amplifier temperature (CSPL real-time log variable 111) ---- */

static int amp_ctl(snd_ctl_t *ctl, const char *prefix, const char *name, bool write, uint32_t *val)
{
	snd_ctl_elem_value_t *v;
	char full[128];
	unsigned char *b;
	int ret;

	snd_ctl_elem_value_alloca(&v);
	snprintf(full, sizeof(full), "%s DSP1 Protection cd %s", prefix, name);
	snd_ctl_elem_value_set_interface(v, SND_CTL_ELEM_IFACE_MIXER);
	snd_ctl_elem_value_set_name(v, full);
	if (write) {
		unsigned char be[4] = { *val >> 24, *val >> 16, *val >> 8, *val };

		snd_ctl_elem_set_bytes(v, be, 4);
		return snd_ctl_elem_write(ctl, v);
	}
	ret = snd_ctl_elem_read(ctl, v);
	if (ret < 0)
		return ret;
	b = (unsigned char *)snd_ctl_elem_value_get_bytes(v);
	*val = (uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
	return 0;
}

/*
 * Stock's cirrus_cal_cspl_read_temp: through the protection firmware's
 * real-time logger. -1 while the amp's DSP is not running, as stock, which
 * finds that from the amp's registers; here its volatile controls fail then.
 */
static int amp_temp(const char *prefix)
{
	static snd_ctl_t *ctl;
	uint32_t st, val, one = 1, zero = 0, var = 111;
	int tries;

	if (g.sim) {
		char p[512];
		long t;

		path(p, sizeof(p), "/sim/amp-%s", prefix);
		return read_long(p, &t) ? -1 : (int)t;
	}
	if (!ctl && snd_ctl_open(&ctl, "hw:0", SND_CTL_NONBLOCK) < 0) {
		ctl = NULL;
		return -1;
	}
	if (amp_ctl(ctl, prefix, "RTLOG_STATE", false, &st) < 0)
		return -1;
	for (int attempt = 0; attempt < 2; attempt++) {
		amp_ctl(ctl, prefix, "RTLOG_COUNT", true, &zero);
		amp_ctl(ctl, prefix, "RTLOG_VARIABLE", true, &var);
		amp_ctl(ctl, prefix, "RTLOG_COUNT", true, &one);
		amp_ctl(ctl, prefix, "RTLOG_STATE", true, &zero);
		amp_ctl(ctl, prefix, "RTLOG_ENABLE", true, &one);
		for (tries = 100; tries > 0; tries--) {
			usleep(20);
			if (amp_ctl(ctl, prefix, "RTLOG_STATE", false, &st) < 0 || st)
				break;
		}
		if (!tries || amp_ctl(ctl, prefix, "RTLOG_DATA", false, &val) < 0) {
			amp_ctl(ctl, prefix, "RTLOG_ENABLE", true, &zero);
			return -1;
		}
		amp_ctl(ctl, prefix, "RTLOG_ENABLE", true, &zero);
		if (val)
			break;
	}
	/* 24-bit signed, 14 fractional bits */
	return (int32_t)(val << 8) >> 8 >> 14;
}

/* ---- inputs ---- */

static bool front_camera_open(void)
{
	char buf[32];

	if (!g.front_cam[0] || read_str(g.front_cam, buf, sizeof(buf)))
		return false;
	return !strcmp(buf, "active");
}

static bool lid_closed(void)
{
	unsigned long sw[(SW_MAX + 8 * sizeof(long)) / (8 * sizeof(long))] = { 0 };
	int fd;

	if (g.sim) {
		char p[512];
		long v;

		path(p, sizeof(p), "/sim/lid");
		return !read_long(p, &v) && v;
	}
	if (!g.lid_dev[0])
		return false;
	fd = open(g.lid_dev, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
	if (fd < 0)
		return false;
	ioctl(fd, EVIOCGSW(sizeof(sw)), sw);
	close(fd);
	return sw[SW_LID / (8 * sizeof(long))] >> (SW_LID % (8 * sizeof(long))) & 1;
}

static double ema(double prev, double x, double k)
{
	return prev == INVALID ? x : prev + (x - prev) * k;
}

/* HAL SpeakerThermistor: the reference, plus a share of the amp's excess */
static double speaker(double prev, int ref, int amp_c, double share)
{
	double amp = amp_c / 0.1, x = ref;

	if (prev == INVALID)
		return ref;
	if (x <= amp)
		x += (amp - x) * share;
	return prev + (x - prev) * 0.15;
}

static bool read_inputs(int *x, char *missing, size_t mlen)
{
	bool ok = true;
	char p[512];
	long v;

	missing[0] = 0;
	for (size_t i = 0; i < sizeof(adc_inputs) / sizeof(*adc_inputs); i++) {
		const struct table *t = find_table(adc_inputs[i].table);
		int uv;

		if (!t || (adc_inputs[i].samples > 1 ?
			   read_adc_avg(adc_inputs[i].label, adc_inputs[i].samples, &uv) :
			   read_adc_uv(adc_inputs[i].label, &uv))) {
			x[adc_inputs[i].in] = INVALID;
			continue;
		}
		x[adc_inputs[i].in] = adc_to_temp(t, uv);
	}
	for (size_t i = 0; i < 4; i++)
		if (!g.zone[i][0]) {
			find_zones();
			break;
		}
	for (size_t i = 0; i < 4; i++) {
		snprintf(p, sizeof(p), "%s/temp", g.zone[i]);
		x[zone_inputs[i].in] = g.zone[i][0] && !read_long(p, &v) ? (int)(v / 100) : INVALID;
	}

	/* the HAL's virtual thermistors, on this tick's readings */
	if (x[USB] != INVALID) {
		double usb = x[USB];

		if (g.fcam != INVALID && front_camera_open())
			usb += 80;
		g.fcam = ema(g.fcam, usb, 0.264);
		g.dnspk = speaker(g.dnspk, x[USB], amp_temp("Speaker"), 0.3);
	}
	if (x[CF] != INVALID)
		g.upspk = speaker(g.upspk, x[CF], amp_temp("Earpiece"), 0.05);
	x[FCAM] = x[USB] != INVALID ? (int)g.fcam : INVALID;
	x[UPSPK] = x[CF] != INVALID ? (int)g.upspk : INVALID;
	x[DNSPK] = x[USB] != INVALID ? (int)g.dnspk : INVALID;

	for (int i = 0; i < NINPUT; i++) {
		if (x[i] != INVALID)
			continue;
		ok = false;
		strncat(missing, " ", mlen - strlen(missing) - 1);
		strncat(missing, input_names[i], mlen - strlen(missing) - 1);
	}
	return ok;
}

/* ---- SDHMS ---- */

static int lrp2(const int *x, bool folded, int *face)
{
	int best = INVALID;

	for (int i = 0; i < 8; i++) {
		double v = g.form_c[i];

		for (int k = 0; k < NINPUT; k++)
			v += g.form_k[i][k] * x[k];
		face[i] = (int)v;
	}
	/* SDHMS Q.o.D(): rear faces only while folded, the max of what is valid */
	for (int i = folded ? 4 : 0; i < 8; i++)
		if (face[i] >= -300 && face[i] > best)
			best = face[i];
	return best;
}

static int siop_level(int skin)
{
	static int c;

	if (skin >= g.lv_temp[c]) {
		while (c < g.lv_n - 1 && skin >= g.lv_temp[c + 1])
			c++;
	} else {
		while (c > 0 && !(skin >= g.lv_temp[c]))
			c--;
	}
	return g.lv_id[c];
}

/* N0.a() with g() true: >0 when y is the higher limit (-1, released, is highest) */
static int cmp(int x, int y)
{
	if (x == y)
		return 0;
	if (x == -1)
		return -1;
	if (y == -1)
		return 1;
	return x < y ? 1 : -1;
}

static int list_index(const struct limiter *l, int v)
{
	if (v == -1)
		return 0;
	for (int i = 0; i < l->nlist; i++)
		if (l->list[i] == v)
			return i;
	return -1;
}

/* C0163b0/E0.e() (n steps lower) and f() (n steps higher) from the current limit */
static int step_from(const struct limiter *l, int n)
{
	int i = list_index(l, l->cur);

	if (i == -1)
		return -1;
	i += n;
	if (i < 0)
		i = 0;
	if (i >= l->nlist)
		i = l->nlist - 1;
	return i == 0 ? -1 : l->list[i];
}

/* Z1.z(): move n steps from the current limit toward the target, not past it */
static int toward(const struct limiter *l, int target, int n)
{
	int next;

	if (cmp(l->cur, target) > 0) {
		next = step_from(l, -n);
		if (cmp(target, next) > 0)
			return target;
	} else {
		next = step_from(l, n);
		if (cmp(target, next) < 0)
			return target;
	}
	return next;
}

static bool stepper_due(struct stepper *s, long now)
{
	long dt = now - s->last;

	s->last = now;
	if (s->acc < s->period)
		s->acc += dt;
	return s->acc >= s->period;
}

/* X1.b(): how many steps, from LRP's rise and the SIOP level */
static int stepper_next(struct limiter *l, int target, int lrp, int ap, int bat_raw, int lrp_raw,
			int lv)
{
	struct stepper *s = &l->st;
	int now_t = lrp >= -300 ? lrp : ap, rise, n = 1;
	bool tightening = cmp(l->cur, target) <= 0;

	s->acc = 0;
	if (s->d == INVALID) {
		s->d = now_t;
		return toward(l, target, 1);
	}
	rise = now_t - s->d;
	s->e = rise;
	s->d = now_t;
	if (s->f == INVALID) {
		s->f = rise;
		return toward(l, target, 1);
	}
	if (tightening) {
		int k = rise >= 10 ? 3 : rise > 6 ? 2 : rise < -2 ? 0 : 1;

		n = (s->f >= 0 || rise >= s->f) ? k : 0;
		if (lv > 4)
			n = n > 3 ? n : 3;
		else if (lv > 1)
			n = n > 2 ? n : 2;
		else if (lv == 1)
			n = n > 1 ? n : 1;
	} else if ((lrp_raw <= -200 || lrp_raw > g.release) && bat_raw > g.release) {
		if (rise >= 0 || s->f >= 0) {
			if (s->f > 3 && rise > s->f)
				n = 0;
		} else if (rise < s->f || s->f < -12) {
			n = 2;
		} else if (rise < -18 && s->f < -18) {
			n = 3;
		}
	} else {
		n = 99;			/* cool: release at once */
	}
	s->f = rise;
	return toward(l, target, n);
}

/* Z1.n(false): the level (one threshold of hysteresis on the way down), then a step */
static void limiter_eval(struct limiter *l, int skin, long now, int lrp, int ap, int bat_raw,
			 int lrp_raw, int lv)
{
	int L = l->level;

	if (skin >= l->temp[L]) {
		while (L < l->n - 1 && skin >= l->temp[L + 1])
			L++;
	} else {
		while (L > 0 && !(skin >= l->temp[L - 1]))
			L--;
	}
	l->level = L;
	if (stepper_due(&l->st, now))
		l->cur = stepper_next(l, l->value[L], lrp, ap, bat_raw, lrp_raw, lv);
}

/* ---- applying limits ---- */

static int vol_matched_gold(int prime)
{
	int out = prime;

	/* stock cflm_get_vol_matched_freq: "prime - gold offset 1" */
	for (int i = 1; i < g.nvf; i++)
		if (g.vf_prime[i] == prime)
			out = g.vf_gold[i - 1];
	return out;
}

static void apply_cpu(int v)
{
	static const int policies[3] = { 0, 4, 7 };
	int max[3];
	char p[512];

	if (v == -1) {
		memcpy(max, g.policy_max, sizeof(max));
	} else if (v < g.big_min) {
		/* cpufreq_limit: silver limited, gold and prime to their floor */
		max[0] = v * 2 < 1612800 ? v * 2 : 1612800;
		max[1] = v == g.s_fmax / 2 ? 844800 : g.g_fmin;
		max[2] = g.p_fmin;
	} else {
		max[0] = g.policy_max[0];
		max[2] = v < g.p_fmax ? v : g.p_fmax;
		max[1] = vol_matched_gold(max[2]);
		if (max[1] > g.g_fmax)
			max[1] = g.g_fmax;
	}
	for (int i = 0; i < 3; i++) {
		if (max[i] == g.applied_cpu[i])
			continue;
		path(p, sizeof(p), "/sys/devices/system/cpu/cpufreq/policy%d/scaling_max_freq",
		     policies[i]);
		if (write_long(p, max[i]))
			logmsg("%s: write failed", p);
		else
			g.applied_cpu[i] = max[i];
	}
}

static void apply_gpu(int mhz)
{
	char p[512];

	if (mhz == g.applied_gpu_mhz)
		return;
	snprintf(p, sizeof(p), "%s/max_freq", g.gpu_dir);
	if (write_long(p, mhz == -1 ? g.gpu_max_hz : mhz * 1000000L))
		logmsg("%s: write failed", p);
	else
		g.applied_gpu_mhz = mhz;
}

/* ---- setup ---- */

/* The modem's zones register when its sensor service comes up, maybe after us. */
static void find_zones(void)
{
	char p[512], buf[128];
	glob_t gl;

	path(p, sizeof(p), "/sys/class/thermal/thermal_zone*/type");
	if (glob(p, 0, NULL, &gl))
		return;
	for (size_t i = 0; i < gl.gl_pathc; i++) {
		if (read_str(gl.gl_pathv[i], buf, sizeof(buf)))
			continue;
		for (int z = 0; z < 4; z++)
			if (!strcmp(buf, zone_inputs[z].zone)) {
				snprintf(g.zone[z], sizeof(g.zone[z]), "%s", gl.gl_pathv[i]);
				*strrchr(g.zone[z], '/') = 0;
			}
	}
	globfree(&gl);
}

static int find_hardware(void)
{
	char p[512], buf[128];
	int f0[32], f4[32], f7[32], n0, n4, n7;
	glob_t gl;

	path(p, sizeof(p), "/sys/bus/iio/devices/iio:device*/in_temp_ap_thm_raw");
	if (glob(p, 0, NULL, &gl) || !gl.gl_pathc) {
		logmsg("no PMK8350 ADC with ap_thm (kernel patches 0107, 0109)");
		return -1;
	}
	snprintf(g.iio, sizeof(g.iio), "%s", gl.gl_pathv[0]);
	*strrchr(g.iio, '/') = 0;
	globfree(&gl);

	find_zones();

	path(p, sizeof(p), "/sys/bus/i2c/devices/*/name");
	if (!glob(p, 0, NULL, &gl)) {
		for (size_t i = 0; i < gl.gl_pathc; i++)
			if (!read_str(gl.gl_pathv[i], buf, sizeof(buf)) && !strcmp(buf, "imx374")) {
				snprintf(g.front_cam, sizeof(g.front_cam), "%s", gl.gl_pathv[i]);
				strcpy(strrchr(g.front_cam, '/'), "/power/runtime_status");
			}
		globfree(&gl);
	}

	if (!g.sim) {
		path(p, sizeof(p), "/sys/class/input/event*/device/capabilities/sw");
		if (!glob(p, 0, NULL, &gl)) {
			for (size_t i = 0; i < gl.gl_pathc; i++) {
				if (read_str(gl.gl_pathv[i], buf, sizeof(buf)) ||
				    !(strtoul(buf, NULL, 16) & (1UL << SW_LID)))
					continue;
				snprintf(g.lid_dev, sizeof(g.lid_dev), "/dev/input/%s",
					 strstr(gl.gl_pathv[i], "event"));
				*strchr(g.lid_dev + strlen("/dev/input/"), '/') = 0;
			}
			globfree(&gl);
		}
	}

	/* stock's merged table (cpufreq_limit): prime above little/2's top, then little/2 */
	path(p, sizeof(p), "/sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies");
	n0 = read_list(p, f0, 32);
	path(p, sizeof(p), "/sys/devices/system/cpu/cpufreq/policy4/scaling_available_frequencies");
	n4 = read_list(p, f4, 32);
	path(p, sizeof(p), "/sys/devices/system/cpu/cpufreq/policy7/scaling_available_frequencies");
	n7 = read_list(p, f7, 32);
	if (n0 < 2 || n4 < 2 || n7 < 2) {
		logmsg("no cpufreq policies 0, 4, 7");
		return -1;
	}
	g.s_fmax = f0[n0 - 1];
	g.g_fmin = f4[0];
	g.g_fmax = f4[n4 - 1];
	g.p_fmin = f7[0];
	g.p_fmax = f7[n7 - 1];
	g.policy_max[0] = g.s_fmax;
	g.policy_max[1] = g.g_fmax;
	g.policy_max[2] = g.p_fmax;
	g.big_min = 0;
	for (int i = 0; i < n7; i++)
		if (f7[i] > g.s_fmax / 2 && (!g.big_min || f7[i] < g.big_min))
			g.big_min = f7[i];
	g.cpu.list = calloc(64, sizeof(int));
	for (int i = n7 - 1; i >= 0; i--)
		if (f7[i] >= g.big_min)
			g.cpu.list[g.cpu.nlist++] = f7[i];
	for (int i = n0 - 1; i >= 0; i--)
		g.cpu.list[g.cpu.nlist++] = f0[i] / 2;

	/* stock's cpu_voltage_cooling: each prime OPP with the fastest gold OPP at or below its voltage */
	{
		long pv[32] = { 0 }, gv[32] = { 0 }, v;
		int idy = n4 - 1;

		for (int i = 0; i < n7; i++) {
			path(p, sizeof(p), "/sys/kernel/debug/opp/cpu7/opp:%ld/supply-0/u_volt_target",
			     f7[i] * 1000L);
			if (read_long(p, &v))
				goto novolt;
			pv[i] = v;
		}
		for (int i = 0; i < n4; i++) {
			path(p, sizeof(p), "/sys/kernel/debug/opp/cpu4/opp:%ld/supply-0/u_volt_target",
			     f4[i] * 1000L);
			if (read_long(p, &v))
				goto novolt;
			gv[i] = v;
		}
		if (pv[n7 - 1] < gv[n4 - 1])
			logmsg("gold's top OPP is above prime's voltage: stock would pair the other way");
		for (int i = n7 - 1; i >= 0; i--) {
			while (idy >= 0 && gv[idy] > pv[i])
				idy--;
			g.vf_prime[g.nvf] = f7[i];
			g.vf_gold[g.nvf++] = f4[idy < 0 ? 0 : idy];
		}
	}

	path(p, sizeof(p), "/sys/class/devfreq/*.gpu");
	if (glob(p, 0, NULL, &gl) || !gl.gl_pathc) {
		logmsg("no GPU devfreq");
		return -1;
	}
	snprintf(g.gpu_dir, sizeof(g.gpu_dir), "%s", gl.gl_pathv[0]);
	globfree(&gl);
	{
		int hz[32], n;

		snprintf(p, sizeof(p), "%s/available_frequencies", g.gpu_dir);
		n = read_list(p, hz, 32);
		if (n < 1)
			return -1;
		g.gpu.list = calloc(n, sizeof(int));
		for (int i = n - 1; i >= 0; i--) {
			if (hz[i] / 1000000 > g.gpu_max_hz / 1000000)
				g.gpu_max_hz = hz[i];
			g.gpu.list[g.gpu.nlist++] = hz[i] / 1000000;
		}
		/* descending, as stock's list */
		for (int i = 0; i < g.gpu.nlist; i++)
			for (int j = i + 1; j < g.gpu.nlist; j++)
				if (g.gpu.list[j] > g.gpu.list[i]) {
					int t = g.gpu.list[i];

					g.gpu.list[i] = g.gpu.list[j];
					g.gpu.list[j] = t;
				}
	}

	/* SDHMS refuses tables whose values are not in its lists */
	for (int i = 0; i < g.cpu.n; i++)
		if (g.cpu.value[i] != -1 && list_index(&g.cpu, g.cpu.value[i]) < 0) {
			logmsg("CPUFreqMax %d is not in the frequency table", g.cpu.value[i]);
			return -1;
		}
	for (int i = 0; i < g.gpu.n; i++)
		if (g.gpu.value[i] != -1 && list_index(&g.gpu, g.gpu.value[i]) < 0) {
			logmsg("GPUFreqMax %d is not in the GPU table", g.gpu.value[i]);
			return -1;
		}
	return 0;
novolt:
	logmsg("no OPP voltages in debugfs (/sys/kernel/debug/opp)");
	return -1;
}

static long boottime_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_BOOTTIME, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000;
}

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static void tick(long now)
{
	static bool was_valid = true;
	int x[NINPUT], face[8], skin, lv, ap_avg = INVALID, sum = 0;
	char missing[256];
	bool valid, closed;

	valid = read_inputs(x, missing, sizeof(missing));
	if (valid != was_valid)
		logmsg(valid ? "all inputs back" : "LRP2 invalid, missing:%s", missing);
	was_valid = valid;

	/* SDHMS: a fold change counts once the lid has kept it for 30 s */
	closed = lid_closed();
	if (closed != g.lid_seen) {
		g.lid_seen = closed;
		g.lid_change_at = now;
	}
	if (g.lid_seen != g.folded && now - g.lid_change_at >= LID_DELAY_MS)
		g.folded = g.lid_seen;

	skin = valid ? lrp2(x, g.folded, face) : INVALID;
	if (!valid)
		for (int i = 0; i < 8; i++)
			face[i] = INVALID;

	if (x[AP] != INVALID) {
		if (g.ap_nhist == 15)
			memmove(g.ap_hist, g.ap_hist + 1, 14 * sizeof(int)), g.ap_nhist--;
		g.ap_hist[g.ap_nhist++] = x[AP];
		for (int i = 0; i < g.ap_nhist; i++)
			sum += g.ap_hist[i];
		ap_avg = sum / g.ap_nhist;
	}

	lv = siop_level(skin);
	limiter_eval(&g.cpu, skin, now, skin, ap_avg, x[BAT], skin, lv);
	limiter_eval(&g.gpu, skin, now, skin, ap_avg, x[BAT], skin, lv);
	apply_cpu(g.cpu.cur);
	apply_gpu(g.gpu.cur);

	{
		FILE *o = g.sim ? stdout : fopen("/run/b2q-siop/status.tmp", "we");

		if (o) {
			fprintf(o, "lrp2=%d lv=%d folded=%d cpu=%d gpu=%d max=%d,%d,%d gpumax=%d",
				skin, lv, g.folded, g.cpu.cur, g.gpu.cur, g.applied_cpu[0],
				g.applied_cpu[1], g.applied_cpu[2], g.applied_gpu_mhz);
			for (int i = 0; i < NINPUT; i++)
				fprintf(o, " %s=%d", input_names[i], x[i]);
			for (int i = 0; i < 8; i++)
				fprintf(o, " %s=%d", face_names[i], face[i]);
			fputc('\n', o);
			fflush(o);
			if (!g.sim) {
				fclose(o);
				rename("/run/b2q-siop/status.tmp", "/run/b2q-siop/status");
			}
		}
	}
}

int main(int argc, char **argv)
{
	const char *model = argc > 1 ? argv[1] : "/usr/share/b2q-siop/model.conf";
	struct itimerspec its = { { TICK_MS / 1000, 0 }, { 0, 1 } };
	char line[64];
	int tfd;

	g.root = getenv("B2Q_SIOP_ROOT") ? getenv("B2Q_SIOP_ROOT") : "";
	g.sim = *g.root;
	g.fcam = g.upspk = g.dnspk = INVALID;
	g.cpu.name = "CPUFreqMax";
	g.gpu.name = "GPUFreqMax";
	g.cpu.cur = g.gpu.cur = -1;
	g.cpu.st = (struct stepper){ 9000, 0, 0, INVALID, INVALID, INVALID };
	g.gpu.st = (struct stepper){ 19000, 0, 0, INVALID, INVALID, INVALID };

	if (load_model(model) || find_hardware())
		return 1;
	for (int z = 0; z < 4; z++)
		if (!g.zone[z][0])
			logmsg("no %s zone (kernel patch 0108)", zone_inputs[z].zone);
	logmsg("CPU table %d entries (prime %d..%d), GPU %d entries; front camera %s, lid %s",
	       g.cpu.nlist, g.cpu.list[0], g.big_min, g.gpu.nlist,
	       g.front_cam[0] ? g.front_cam : "none", g.sim ? "sim" : g.lid_dev[0] ? g.lid_dev : "none");

	{
		/* no SA_RESTART: a signal ends the wait on the timer */
		struct sigaction sa = { .sa_handler = on_signal };

		sigaction(SIGTERM, &sa, NULL);
		sigaction(SIGINT, &sa, NULL);
	}
	/* start released: never overwrite a limit we did not set */
	memcpy(g.applied_cpu, g.policy_max, sizeof(g.applied_cpu));
	g.applied_gpu_mhz = -1;

	if (g.sim) {
		bool first = true;

		while (!stop && fgets(line, sizeof(line), stdin)) {
			long now = atol(line);

			if (first) {
				g.cpu.st.last = g.gpu.st.last = now;
				g.folded = g.lid_seen = lid_closed();
				first = false;
			}
			tick(now);
		}
		return 0;
	}

	g.cpu.st.last = g.gpu.st.last = boottime_ms();
	g.folded = g.lid_seen = lid_closed();
	/* CLOCK_MONOTONIC: no ticks, and no wakeups, while suspended */
	tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
	if (tfd < 0 || timerfd_settime(tfd, 0, &its, NULL)) {
		logmsg("timerfd: %m");
		return 1;
	}
	while (!stop) {
		uint64_t n;

		if (read(tfd, &n, sizeof(n)) != sizeof(n))
			continue;
		tick(boottime_ms());
	}
	/* release every limit we set */
	apply_cpu(-1);
	apply_gpu(-1);
	return 0;
}
