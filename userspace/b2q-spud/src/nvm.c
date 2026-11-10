// SPDX-License-Identifier: MIT
/*
 * The secure processor's NVM service: what Qualcomm's sec_nvm does on the
 * HLOS side of the SPSS channels sec_nvm_<app>, one manager per channel.
 * The SPSS keeps each partition (up to 5 segments) in DDR while it runs and
 * asks the HLOS to load it from and commit it to two copies of each segment
 * on persist:
 *
 *   /mnt/vendor/persist/secnvm/<uuid>_<seg>_0 and _1
 *
 * <uuid> is the 16 UUID bytes printed as decimal and concatenated. Which
 * copy is current is decided by the marker the SPSS sends (the 32-byte ARC
 * for its own kernel partition, "SKP"; a 16-byte CMAC per segment for app
 * partitions) and then by a counter at the end of each file. The layouts
 * and the algorithms are decoded from stock sec_nvm, see
 * scratch/fp-ta/sec-nvm.md section 2.
 *
 * Implemented: IsCommit (0x5), Open (0x1/0xa) and Open SKP (0x7/0xc),
 * Commit (0x2), Async Commit (0x4, run at once, its result handed over by
 * the next IsCommit as stock does) and Commit SKP (0x8), Abort (0x3),
 * ScratchBuffer (0xd/0xe) and InitDone (0xf). Create is refused while the
 * files exist: it would truncate both copies.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "qcom_qsee_app.h"
#include "spud.h"

#define SECNVM_DIR	"/mnt/vendor/persist/secnvm"
#define VMID_CP_SPSS_HLOS_SHARED 0x24
#define MAX_SEGS	5
#define MAX_BLOCKS	0x400

enum {
	REQ_CREATE = 0x0, REQ_OPEN = 0x1, REQ_COMMIT = 0x2, REQ_ABORT = 0x3, REQ_ASYNC_COMMIT = 0x4,
	REQ_IS_COMMIT = 0x5, REQ_CREATE_SKP = 0x6, REQ_OPEN_SKP = 0x7, REQ_COMMIT_SKP = 0x8,
	REQ_CREATE_EXT = 0x9, REQ_OPEN_EXT = 0xa, REQ_CREATE_SKP_EXT = 0xb, REQ_OPEN_SKP_EXT = 0xc,
	REQ_GET_SBDB_ADDR = 0xd, REQ_LOOKUP_SBAPP = 0xe, REQ_INIT_DONE = 0xf,
};
enum {
	RSP_CREATE = 0x64, RSP_OPEN = 0x65, RSP_COMMIT = 0x66, RSP_ABORT = 0x67, RSP_ASYNC_COMMIT = 0x68,
	RSP_IS_COMMIT = 0x69, RSP_SCRATCH = 0x6a, RSP_INIT_DONE = 0x6b,
};
enum {
	ST_OK = 0, ST_FAIL = 1, ST_BADMSG = 2, ST_NOMEM = 3, ST_INVAL = 4, ST_BUSY = 6, ST_EXIST = 7,
	ST_NOENT = 8, ST_OTHER = 9, ST_VERSION = 10,
};

/* One segment's layout, u32 arithmetic as stock does it */
struct seg_layout {
	uint32_t s;		/* blocks of 1 KiB */
	uint32_t A, D, C, B, E, F, G;
	uint32_t file_size, ddr_size;
	uint32_t arc, cmac;	/* marker offsets */
	uint32_t bytemap, counter;	/* in the file */
};

static void layout(uint32_t s, struct seg_layout *l)
{
	l->s = s;
	l->A = s * 1024;
	l->D = (s >> 5) * 0x600;
	l->C = s & ~31u;
	l->B = (l->C | 1) + 0x2f;
	l->E = l->A + l->D + l->B;
	l->F = (l->E + 0x10) | 2;
	l->G = l->F + s + 1;
	l->counter = l->G - 3;
	l->bytemap = l->G - 3 - s;
	l->file_size = l->G + 1;
	l->arc = l->A + l->D + l->C + 0x10;
	l->cmac = l->A + l->D + l->C + 0x30;
	l->ddr_size = (l->G + ((0u - l->G) & 7) + 4095) & ~4095u;
}

struct nvm_seg {
	struct seg_layout l;
	uint32_t off;		/* in the partition's DDR buffer */
	uint8_t bytemap[MAX_BLOCKS];	/* in-memory dirty bytemap */
	uint32_t mem_counter;
};

/* A buffer shared with the SPSS: {VMID 0x24 RW, HLOS RW}, below 4 GiB */
struct sp_buf {
	int fd;
	uint8_t *map;
	uint64_t pa;
	uint32_t size;
};

struct nvm_part {
	char channel[64];
	int open, skp;
	uint8_t uuid[16];
	char name[64];
	unsigned nseg;
	struct nvm_seg seg[MAX_SEGS];
	struct sp_buf ddr;
	int skp_state;		/* stock's NVM_READY state machine */
	uint8_t async_rsp[0x12];	/* Async Commit result for the next IsCommit */
	int async_pending;
};

/* Scratch buffers are process-wide in stock (globals), not per channel */
struct sbdb_entry {		/* stock's 40-byte record, kept in the SBDB buffer itself */
	uint8_t id[16];
	int32_t fd;
	uint32_t size;
	uint64_t pad[2];
};
static struct sp_buf sbdb = { .fd = -1 };
static struct sp_buf sbapp[3] = { { .fd = -1 }, { .fd = -1 }, { .fd = -1 } };

/* B2Q_SPUD_SECNVM_DIR and B2Q_SPUD_FAKE_DDR are for testing against copies off the phone */
static const char *secnvm_dir(void)
{
	const char *d = getenv("B2Q_SPUD_SECNVM_DIR");

	return d && *d ? d : SECNVM_DIR;
}

static int sp_buf_alloc(struct sp_buf *b, uint32_t size)
{
	struct qsee_app_vmbuf vb = {
		.size = size, .vmid = VMID_CP_SPSS_HLOS_SHARED,
		.flags = QSEE_APP_VMBUF_HLOS | QSEE_APP_VMBUF_KEEP,
	};

	if (getenv("B2Q_SPUD_FAKE_DDR")) {
		static uint64_t fake_pa = 0xdd000000;

		b->map = calloc(1, size);
		b->pa = fake_pa;
		fake_pa += size;
		b->size = size;
		b->fd = 1000;
		return b->map ? 0 : -1;
	}
	b->fd = open("/dev/qsee-app", O_RDWR | O_CLOEXEC);
	if (b->fd < 0)
		return -1;
	if (ioctl(b->fd, QSEE_APP_IOC_VMBUF, &vb) < 0) {
		spud_log("sec_nvm: shared buffer of %u bytes: %m", size);
		close(b->fd);
		b->fd = -1;
		return -1;
	}
	b->map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, b->fd, 0);
	if (b->map == MAP_FAILED) {
		spud_log("sec_nvm: mapping the shared buffer: %m");
		b->map = NULL;
		return -1;	/* it stays assigned (KEEP); fd kept open */
	}
	b->pa = vb.phys;
	b->size = size;
	return 0;
}

static void uuid_name(const uint8_t uuid[16], char *out, size_t n)
{
	size_t o = 0;

	out[0] = '\0';
	for (int i = 0; i < 16 && o < n; i++)
		o += snprintf(out + o, n - o, "%u", uuid[i]);
}

static int seg_path(const struct nvm_part *p, unsigned seg, int copy, char *out, size_t n)
{
	return snprintf(out, n, "%s/%s_%u_%d", secnvm_dir(), p->name, seg, copy) >= (int)n ? -1 : 0;
}

static int pread_all(int fd, void *buf, size_t len, off_t off)
{
	return pread(fd, buf, len, off) == (ssize_t)len ? 0 : -1;
}

static int pwrite_all(int fd, const void *buf, size_t len, off_t off)
{
	return pwrite(fd, buf, len, off) == (ssize_t)len ? 0 : -1;
}

static uint32_t file_counter(int fd, const struct seg_layout *l)
{
	uint32_t c = 0;

	if (pread_all(fd, &c, 4, l->counter))
		return 0;
	return c;
}

/* The marker a request carries for a segment: ARC (SKP) or that segment's CMAC */
struct marker {
	const uint8_t *m;
	uint32_t len, off;
};

static struct marker seg_marker(const struct nvm_part *p, const struct nvm_seg *s, const uint8_t *m)
{
	struct marker k = { m, p->skp ? 32 : 16, p->skp ? s->l.arc : s->l.cmac };

	return k;
}

/*
 * Stock open_files: the copy whose marker equals the request's is current;
 * both matching ("ari bypass") falls back to the higher counter, both 0 is
 * -EBADMSG, neither matching is "both markers mismatch". Returns the index
 * of the current copy, or -1.
 */
static int pick_active(const struct nvm_part *p, const struct nvm_seg *s, int fd[2], struct marker k)
{
	uint8_t m[2][32];
	int match[2];
	uint32_t c[2];

	for (int i = 0; i < 2; i++) {
		if (pread_all(fd[i], m[i], k.len, k.off))
			return -1;
		match[i] = !memcmp(m[i], k.m, k.len);
		c[i] = file_counter(fd[i], &s->l);
	}
	if (match[0] != match[1])
		return match[0] ? 0 : 1;
	if (!match[0]) {
		spud_log("sec_nvm: %s: both markers mismatch", p->name);
		return -1;
	}
	if (!c[0] && !c[1])
		return -1;
	return c[0] >= c[1] ? 0 : 1;
}

/* Both copies of a segment, refused unless each is exactly the layout's size */
static int open_copies(const struct nvm_part *p, unsigned seg, int fd[2])
{
	const struct seg_layout *l = &p->seg[seg].l;
	char path[320];
	struct stat st;

	for (int i = 0; i < 2; i++) {
		if (seg_path(p, seg, i, path, sizeof(path)))
			goto fail;
		fd[i] = open(path, O_RDWR | O_CLOEXEC);
		if (fd[i] < 0) {
			spud_log("sec_nvm: %s: %m", path);
			goto fail;
		}
		if (fstat(fd[i], &st) || st.st_size != l->file_size) {
			spud_log("sec_nvm: %s is %lld bytes, the layout for %u blocks wants %u",
				 path, (long long)st.st_size, l->s, l->file_size);
			close(fd[i]);
			goto fail;
		}
		continue;
fail:
		if (i)
			close(fd[0]);
		return -1;
	}
	return 0;
}

static int uuid_set(struct nvm_part *p, const uint8_t *uuid)
{
	if (p->name[0] && memcmp(p->uuid, uuid, 16)) {
		spud_log("sec_nvm: %s: UUID redefinition refused", p->channel);
		return -1;
	}
	memcpy(p->uuid, uuid, 16);
	uuid_name(p->uuid, p->name, sizeof(p->name));
	return 0;
}

/* Open (0x1/0xa) and Open SKP (0x7/0xc): load the current copies into DDR, hand its address over */
static size_t nvm_open(struct nvm_part *p, const uint8_t *req, size_t len, uint8_t *rsp)
{
	int ext = req[0] == REQ_OPEN_EXT || req[0] == REQ_OPEN_SKP_EXT;
	int skp = req[0] == REQ_OPEN_SKP || req[0] == REQ_OPEN_SKP_EXT;
	uint32_t total = 0;
	unsigned nseg;
	uint8_t st;

	memset(rsp, 0, 0x2f);
	rsp[0] = RSP_OPEN;
	if (len >= 0x11)
		memcpy(rsp + 1, req + 1, 16);
	if (len < (ext ? 0x96u : 0x82u)) {
		rsp[0x2e] = ST_INVAL;
		return 0x2f;
	}
	nseg = skp ? 1 : req[0x11];
	rsp[0x11] = nseg;
	if (!nseg || nseg > MAX_SEGS || uuid_set(p, req + 1)) {
		rsp[0x2e] = ST_INVAL;
		return 0x2f;
	}
	p->open = 0;
	p->skp = skp;
	p->nseg = nseg;
	for (unsigned i = 0; i < nseg; i++) {
		uint32_t blocks = MAX_BLOCKS;

		if (ext)
			memcpy(&blocks, req + 0x82 + 4 * i, 4);
		if (!blocks || blocks > MAX_BLOCKS) {
			rsp[0x2e] = ST_INVAL;
			return 0x2f;
		}
		layout(blocks, &p->seg[i].l);
		p->seg[i].off = total;
		total += p->seg[i].l.ddr_size;
		memcpy(rsp + 0x1a + 4 * i, &p->seg[i].off, 4);
	}
	/* stock frees and reallocates; a KEEP buffer cannot be given back, so reuse it */
	if (p->ddr.map && total > p->ddr.size) {
		spud_log("sec_nvm: %s: re-open needs %u bytes of DDR, %u are mapped", p->channel, total, p->ddr.size);
		rsp[0x2e] = ST_NOMEM;
		return 0x2f;
	}
	if (!p->ddr.map && sp_buf_alloc(&p->ddr, total)) {
		rsp[0x2e] = ST_NOMEM;
		return 0x2f;
	}
	memset(p->ddr.map, 0, p->ddr.size);

	st = ST_OK;
	for (unsigned i = 0; i < nseg && st == ST_OK; i++) {
		struct nvm_seg *s = &p->seg[i];
		struct marker k = seg_marker(p, s, skp ? req + 0x12 : req + 0x32 + 16 * i);
		int fd[2], act;

		if (open_copies(p, i, fd)) {
			st = ST_NOENT;
			break;
		}
		act = pick_active(p, s, fd, k);
		if (act < 0)
			st = ST_BADMSG;
		/* data blocks, hashes and the L1/root block, at the same offsets as in the file */
		else if (pread_all(fd[act], p->ddr.map + s->off, s->l.E + 0x10, 0) ||
			 pread_all(fd[act], s->bytemap, s->l.s, s->l.bytemap))
			st = ST_OTHER;
		else {
			s->mem_counter = file_counter(fd[act], &s->l);
			spud_log("sec_nvm: %s: opened %s_%u (%u blocks, copy %d, counter %u)",
				 p->channel, p->name, i, s->l.s, act, s->mem_counter);
		}
		close(fd[0]);
		close(fd[1]);
	}
	if (st == ST_OK) {
		p->open = 1;
		if (skp && p->skp_state == 0)
			p->skp_state = 2;
		memcpy(rsp + 0x12, &p->ddr.pa, 8);
		spud_log("sec_nvm: %s: partition %s, %u segment(s) at DDR %#llx",
			 p->channel, p->name, nseg, (unsigned long long)p->ddr.pa);
	}
	rsp[0x2e] = st;
	return 0x2f;
}

/* One segment of a commit: write what the SPSS changed in DDR to the older copy */
static uint8_t commit_seg(struct nvm_part *p, unsigned segno, const uint8_t *marker)
{
	struct nvm_seg *s = &p->seg[segno];
	const struct seg_layout *l = &s->l;
	uint8_t *ddr = p->ddr.map + s->off, *ddr_map = ddr + l->F;
	uint32_t bc, zero = 0, next;
	int fd[2], act, bak;
	uint8_t st = ST_OTHER;

	if (open_copies(p, segno, fd))
		return ST_OTHER;
	act = pick_active(p, s, fd, seg_marker(p, s, marker));
	if (act < 0)
		goto out;
	bak = !act;
	bc = file_counter(fd[bak], l);
	if (!bc || bc >= s->mem_counter)
		memset(s->bytemap, 1, l->s);	/* "dirty backup": rewrite all of it */
	else
		for (uint32_t i = 0; i < l->s; i++)
			s->bytemap[i] |= ddr_map[i];

	if (pwrite_all(fd[bak], &zero, 4, l->counter))
		goto out;
	for (uint32_t blk = 0; blk < l->s; blk++) {
		if (!s->bytemap[blk])
			continue;
		if (pwrite_all(fd[bak], ddr + blk * 1024, 1024, (off_t)blk * 1024) ||
		    pwrite_all(fd[bak], ddr + l->A + blk * 0x30, 0x30, (off_t)l->A + blk * 0x30))
			goto out;
	}
	if (pwrite_all(fd[bak], ddr + l->A + l->D, l->B + 0x10, (off_t)l->A + l->D) ||
	    pwrite_all(fd[bak], ddr_map, l->s, l->bytemap) || fsync(fd[bak]))
		goto out;
	next = s->mem_counter + 1;
	if (pwrite_all(fd[bak], &next, 4, l->counter) || fsync(fd[bak]))
		goto out;
	s->mem_counter = next;
	memcpy(s->bytemap, ddr_map, l->s);
	st = ST_OK;
	spud_log("sec_nvm: %s: committed %s_%u to copy %d (counter %u)", p->channel, p->name, segno, bak, next);
out:
	close(fd[0]);
	close(fd[1]);
	return st;
}

/* Commit (0x2, and 0x4's payload) and Commit SKP (0x8); rsp is the 0x12-byte commit reply */
static void nvm_commit(struct nvm_part *p, const uint8_t *req, size_t len, uint8_t *rsp)
{
	int skp = req[0] == REQ_COMMIT_SKP;
	uint8_t st = ST_OK;

	memset(rsp, 0, 0x12);
	rsp[0] = RSP_COMMIT;
	if (len != 0x87 || req[0x11] > MAX_SEGS) {
		rsp[0x11] = ST_INVAL;
		return;
	}
	if (!p->open || memcmp(req + 1, p->uuid, 16) || req[0x11] > p->nseg || skp != p->skp) {
		spud_log("sec_nvm: %s: commit for a partition that is not open", p->channel);
		rsp[0x11] = ST_OTHER;
		return;
	}
	for (unsigned i = 0; i < req[0x11] && st == ST_OK; i++) {
		unsigned segno = req[0x12 + 0x11 * i];

		if (segno >= p->nseg) {
			st = ST_OTHER;
			break;
		}
		st = commit_seg(p, segno, skp ? req + 0x67 : req + 0x13 + 0x11 * i);
	}
	if (st != ST_OK)
		spud_log("sec_nvm: %s: commit failed, the SPSS should abort", p->channel);
	else if (skp && p->skp_state == 1)
		p->skp_state = 3;
	else if (skp && p->skp_state >= 2)
		p->skp_state = 4;
	rsp[0x11] = st == ST_OK ? ST_OK : ST_OTHER;
}

/* Abort (0x3): throw away what changed in DDR, reload every segment from its newest copy */
static size_t nvm_abort(struct nvm_part *p, uint8_t *rsp)
{
	uint8_t st = ST_OK;

	memset(rsp, 0, 0x12);
	rsp[0] = RSP_ABORT;
	if (!p->open) {
		rsp[0x11] = ST_INVAL;
		return 0x12;
	}
	for (unsigned i = 0; i < p->nseg && st == ST_OK; i++) {
		struct nvm_seg *s = &p->seg[i];
		int fd[2], act;

		if (open_copies(p, i, fd)) {
			st = ST_OTHER;
			break;
		}
		act = file_counter(fd[0], &s->l) >= file_counter(fd[1], &s->l) ? 0 : 1;
		if (pread_all(fd[act], p->ddr.map + s->off, s->l.E + 0x10, 0))
			st = ST_OTHER;
		close(fd[0]);
		close(fd[1]);
	}
	spud_log("sec_nvm: %s: abort (%u)", p->channel, st);
	rsp[0x11] = st;
	return 0x12;
}

/*
 * ScratchBuffer (stock ScratchBufferOp): 0xd hands over the 4 KiB scratch
 * database, 0xe finds or makes an app's scratch buffer of the requested
 * size, by its 16-byte id at +0xb. Reply: {0x6a, 3, u64 PA @2,
 * is_created @0xa, id @0xb, u32 size @0x1b (0xd), status @0x1f}.
 */
static size_t nvm_scratch(const uint8_t *req, size_t len, uint8_t *rsp)
{
	struct sbdb_entry *e = NULL;
	struct sp_buf *b;
	uint32_t want;
	int slot = -1;

	memset(rsp, 0, 0x20);
	rsp[0] = RSP_SCRATCH;
	rsp[1] = 3;
	if (len < 0x20) {
		rsp[0x1f] = ST_INVAL;
		return 0x20;
	}
	if (req[0] == REQ_GET_SBDB_ADDR) {
		if (!sbdb.map) {
			if (sp_buf_alloc(&sbdb, 0x1000)) {
				rsp[0x1f] = ST_NOMEM;
				return 0x20;
			}
			memset(sbdb.map, 0, 0x8c);
			rsp[0xa] = 1;
		}
		memcpy(rsp + 2, &sbdb.pa, 8);
		memcpy(rsp + 0x1b, &sbdb.size, 4);
		spud_log("sec_nvm: scratch database at %#llx", (unsigned long long)sbdb.pa);
		return 0x20;
	}
	/* LOOKUP_SBAPP */
	if (!sbdb.map) {
		rsp[0x1f] = ST_INVAL;
		return 0x20;
	}
	memcpy(&want, req + 0x1b, 4);
	for (int i = 0; i < 3 && slot < 0; i++) {
		e = (struct sbdb_entry *)(sbdb.map + 40 * i);
		if (e->fd > 0 && !memcmp(e->id, req + 0xb, 16))
			slot = i;
	}
	if (slot < 0)
		for (int i = 0; i < 3 && slot < 0; i++) {
			e = (struct sbdb_entry *)(sbdb.map + 40 * i);
			if (e->fd == 0)
				slot = i;
		}
	if (slot < 0) {
		spud_log("sec_nvm: scratch database full");
		rsp[0x1f] = ST_INVAL;
		return 0x20;
	}
	b = &sbapp[slot];
	if (e->fd == 0) {
		if (!want || sp_buf_alloc(b, want)) {
			rsp[0x1f] = ST_NOMEM;
			return 0x20;
		}
		memcpy(e->id, req + 0xb, 16);
		e->fd = b->fd;
		e->size = want;
		sbdb.map[0x78]++;
		rsp[0xa] = 1;
	} else if (e->size < want) {
		spud_log("sec_nvm: scratch buffer %d is %u bytes, %u requested", slot, e->size, want);
		rsp[0x1f] = ST_INVAL;
		return 0x20;
	}
	memcpy(rsp + 2, &b->pa, 8);
	memcpy(rsp + 0xb, req + 0xb, 16);
	spud_log("sec_nvm: app scratch buffer %d (%u bytes) at %#llx", slot, e->size, (unsigned long long)b->pa);
	return 0x20;
}

/* Serve one request; returns the reply length (0: nothing to send) */
size_t nvm_handle(struct nvm_part *p, const uint8_t *req, size_t len, uint8_t *rsp, size_t rsp_cap)
{
	if (!len || rsp_cap < 0x40)
		return 0;
	switch (req[0]) {
	case REQ_IS_COMMIT:
		/*
		 * Stock IsCommitOp: req[1] is the SPSS's NVM version, 3 and 4 are
		 * spoken. +0x13 = 1: no async commit running; a finished one's
		 * 0x12-byte result goes at +1. +0x14 = status.
		 */
		memset(rsp, 0, 0x15);
		rsp[0] = RSP_IS_COMMIT;
		if (len < 2 || req[1] < 3 || req[1] > 4) {
			spud_log("sec_nvm: NVM version %u is not 3 or 4", len < 2 ? 0 : req[1]);
			rsp[0x14] = ST_VERSION;
			return 0x15;
		}
		rsp[0x13] = 1;
		if (p->async_pending) {
			memcpy(rsp + 1, p->async_rsp, 0x12);
			p->async_pending = 0;
		}
		return 0x15;
	case REQ_OPEN:
	case REQ_OPEN_EXT:
	case REQ_OPEN_SKP:
	case REQ_OPEN_SKP_EXT:
		return nvm_open(p, req, len, rsp);
	case REQ_COMMIT:
	case REQ_COMMIT_SKP:
		nvm_commit(p, req, len, rsp);
		return 0x12;
	case REQ_ASYNC_COMMIT:
		memset(rsp, 0, 2);
		rsp[0] = RSP_ASYNC_COMMIT;
		if (p->async_pending) {
			spud_log("sec_nvm: %s: async result still waiting for delivery", p->channel);
			rsp[1] = ST_FAIL;
			return 2;
		}
		nvm_commit(p, req, len, p->async_rsp);
		p->async_pending = 1;
		return 2;
	case REQ_ABORT:
		return nvm_abort(p, rsp);
	case REQ_GET_SBDB_ADDR:
	case REQ_LOOKUP_SBAPP:
		return nvm_scratch(req, len, rsp);
	case REQ_INIT_DONE:
		rsp[0] = RSP_INIT_DONE;
		rsp[1] = ST_OK;
		if (p->skp_state >= 1)
			p->skp_state = 4;
		spud_log("sec_nvm: %s: init done", p->channel);
		return 2;
	case REQ_CREATE:
	case REQ_CREATE_SKP:
	case REQ_CREATE_EXT:
	case REQ_CREATE_SKP_EXT:
		spud_log("sec_nvm: %s: CREATE (%#x) refused: it would truncate the stored copies", p->channel, req[0]);
		memset(rsp, 0, 0x2f);
		rsp[0] = RSP_CREATE;
		if (len >= 0x11)
			memcpy(rsp + 1, req + 1, 16);
		rsp[0x2e] = ST_EXIST;
		return 0x2f;
	default:
		spud_log("sec_nvm: %s: request %#x not implemented", p->channel, req[0]);
		memset(rsp, 0, 0x12);
		rsp[0] = req[0] + 0x64;
		rsp[0x11] = ST_OTHER;
		return 0x12;
	}
}

int nvm_ready(const struct nvm_part *p)
{
	return p->skp_state == 4;
}

struct nvm_part *nvm_new(const char *channel)
{
	struct nvm_part *p = calloc(1, sizeof(*p));

	if (p) {
		snprintf(p->channel, sizeof(p->channel), "%s", channel);
		p->ddr.fd = -1;
	}
	return p;
}
