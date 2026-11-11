/* SPDX-License-Identifier: GPL-2.0-only WITH Linux-syscall-note */
/*
 * Userspace access to one QSEE trusted application per file descriptor,
 * through the legacy QSEECOM calls (see drivers/firmware/qcom/qcom_qsee_app.c).
 */
#ifndef _UAPI_LINUX_QCOM_QSEE_APP_H
#define _UAPI_LINUX_QCOM_QSEE_APP_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define QSEE_APP_NAME_MAX	64

/**
 * struct qsee_app_load - load a trusted application for this descriptor
 * @path:	firmware path without suffix, e.g. "qcom/sm8350/Samsung/b2q/securefp";
 *		<path>.mdt and <path>.b00.. are read with request_firmware()
 * @sbuf_size:	size of the shared buffer the application exchanges commands in
 * @app_id:	out: the id QSEE gave the application
 * @flags:	out: QSEE_APP_LOADED_HERE if this call loaded it, 0 if it was
 *		already resident (it is then not unloaded on close)
 */
struct qsee_app_load {
	char path[128];
	__u32 sbuf_size;
	__u32 app_id;
	__u32 flags;
	__u32 reserved;
};

#define QSEE_APP_LOADED_HERE	(1 << 0)

/**
 * struct qsee_app_send - send one command to the loaded application
 * @req:	userspace request buffer, copied to the start of the shared buffer
 *		before the call and back from it afterwards
 * @req_len:	request length
 * @rsp:	userspace response buffer, copied to the shared buffer at the
 *		64-byte aligned offset after the request before the call (apps
 *		may read input from it) and back from it afterwards
 * @rsp_len:	response length; ALIGN(req_len, 64) + rsp_len must fit in
 *		sbuf_size
 */
struct qsee_app_send {
	__u64 req;
	__u32 req_len;
	__u32 rsp_len;
	__u64 rsp;
};

/**
 * struct qsee_app_vmbuf - a buffer handed to another VM for this descriptor
 * @size:	bytes, rounded up to pages
 * @vmid:	VM that gets read/write access (e.g. 0x22, CP_SPSS_SP_SHARED);
 *		Linux loses access until the descriptor is closed
 * @flags:	QSEE_APP_VMBUF_KEEP or 0
 * @phys:	out: physical address to pass to the application
 *
 * Some apps take a shared buffer by physical address that must belong to
 * another VM (keymaster64's SPU_INIT wants one owned by CP_SPSS_SP_SHARED).
 * One per descriptor; it is assigned back to HLOS and freed on close,
 * unless QSEE_APP_VMBUF_KEEP is set: then it stays with the other VM until
 * reboot, for buffers the secure side keeps using after the call.
 */
struct qsee_app_vmbuf {
	__u64 size;
	__u32 vmid;
	__u32 flags;
	__u64 phys;
};

#define QSEE_APP_VMBUF_KEEP	(1 << 0)
/*
 * Share instead of hand over: Linux keeps read/write access next to @vmid,
 * and the descriptor can be mmap()ed (uncached) to read and fill the buffer.
 * The SPSS NVM service's DDR copy is such a buffer (VMID CP_SPSS_HLOS_SHARED).
 */
#define QSEE_APP_VMBUF_HLOS	(1 << 1)

#define QSEE_APP_IOC_MAGIC	'Q'
#define QSEE_APP_IOC_LOAD	_IOWR(QSEE_APP_IOC_MAGIC, 1, struct qsee_app_load)
#define QSEE_APP_IOC_SEND	_IOW(QSEE_APP_IOC_MAGIC, 2, struct qsee_app_send)	/* buffers are in/out */
#define QSEE_APP_IOC_VMBUF	_IOWR(QSEE_APP_IOC_MAGIC, 3, struct qsee_app_vmbuf)

#endif /* _UAPI_LINUX_QCOM_QSEE_APP_H */
