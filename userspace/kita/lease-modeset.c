// SPDX-License-Identifier: MIT
// Lease the cover connector from KWin and modeset it to a solid colour.
// This is the proof that a dedicated daemon can own DSI-2.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_mode.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <wayland-client.h>

#include "drm-lease-v1-client-protocol.h"

struct connector {
	struct wp_drm_lease_connector_v1 *obj;
	char *name;
	uint32_t id;
	struct connector *next;
};

static struct wp_drm_lease_device_v1 *lease_device;
static struct connector *connectors;
static const char *want = "DSI-2";
static int requested;
static int lease_fd = -1;

static int modeset(int fd)
{
	drmModeRes *res;
	drmModeConnector *conn = NULL;
	drmModeEncoder *enc;
	drmModeCrtc *crtc;
	struct drm_mode_create_dumb dumb = { 0 };
	struct drm_mode_map_dumb map = { 0 };
	drmModeModeInfo *mode;
	uint32_t crtc_id = 0, fb_id = 0;
	uint32_t *pixels;
	unsigned int i, npixels;
	int ret;

	res = drmModeGetResources(fd);
	if (!res) {
		fprintf(stderr, "drmModeGetResources: %s\n", strerror(errno));
		return -1;
	}
	printf("leased resources: %d connectors, %d crtcs, %d encoders\n",
	       res->count_connectors, res->count_crtcs, res->count_encoders);

	for (i = 0; i < res->count_connectors; i++) {
		drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);

		if (!c)
			continue;
		printf("connector %u: %s, %d modes\n", c->connector_id,
		       c->connection == DRM_MODE_CONNECTED ? "connected" : "disconnected",
		       c->count_modes);
		if (!conn && c->connection == DRM_MODE_CONNECTED)
			conn = c;
		else
			drmModeFreeConnector(c);
	}
	if (!conn || conn->count_modes == 0) {
		fprintf(stderr, "no connected connector with a mode\n");
		return -1;
	}

	mode = &conn->modes[0];
	printf("mode: %s %dx%d@%d\n", mode->name, mode->hdisplay, mode->vdisplay,
	       mode->vrefresh);

	if (conn->encoder_id) {
		enc = drmModeGetEncoder(fd, conn->encoder_id);
		if (enc) {
			crtc_id = enc->crtc_id;
			drmModeFreeEncoder(enc);
		}
	}
	if (!crtc_id && res->count_crtcs)
		crtc_id = res->crtcs[0];
	if (!crtc_id) {
		fprintf(stderr, "no crtc in the lease\n");
		return -1;
	}
	crtc = drmModeGetCrtc(fd, crtc_id);
	printf("crtc %u (current fb %u)\n", crtc_id, crtc ? crtc->buffer_id : 0);
	if (crtc)
		drmModeFreeCrtc(crtc);

	dumb.width = mode->hdisplay;
	dumb.height = mode->vdisplay;
	dumb.bpp = 32;
	ret = ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &dumb);
	if (ret) {
		fprintf(stderr, "CREATE_DUMB: %s\n", strerror(errno));
		return -1;
	}
	printf("dumb: handle %u pitch %u size %llu\n", dumb.handle, dumb.pitch,
	       (unsigned long long)dumb.size);

	map.handle = dumb.handle;
	ret = ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map);
	if (ret) {
		fprintf(stderr, "MAP_DUMB: %s\n", strerror(errno));
		return -1;
	}
	pixels = mmap(NULL, dumb.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
		      map.offset);
	if (pixels == MAP_FAILED) {
		fprintf(stderr, "mmap: %s\n", strerror(errno));
		return -1;
	}
	npixels = dumb.pitch / 4 * dumb.height;
	for (i = 0; i < npixels; i++)
		pixels[i] = 0x000000ff; /* XRGB8888: red */

	ret = drmModeAddFB(fd, dumb.width, dumb.height, 24, 32, dumb.pitch,
			   dumb.handle, &fb_id);
	if (ret) {
		fprintf(stderr, "AddFB: %s\n", strerror(errno));
		return -1;
	}
	printf("fb %u\n", fb_id);

	ret = drmModeSetCrtc(fd, crtc_id, fb_id, 0, 0, &conn->connector_id, 1, mode);
	printf("SetCrtc: %d (%s)\n", ret, ret ? strerror(errno) : "ok");

	return ret;
}

static void connector_name(void *data, struct wp_drm_lease_connector_v1 *obj,
			   const char *name)
{
	struct connector *c = data;

	free(c->name);
	c->name = strdup(name);
}

static void connector_description(void *data,
				  struct wp_drm_lease_connector_v1 *obj,
				  const char *description)
{
}

static void connector_id(void *data, struct wp_drm_lease_connector_v1 *obj,
			 uint32_t id)
{
	struct connector *c = data;

	c->id = id;
}

static void connector_done(void *data, struct wp_drm_lease_connector_v1 *obj)
{
}

static void connector_withdrawn(void *data,
				struct wp_drm_lease_connector_v1 *obj)
{
	struct connector *c = data;

	printf("connector %s withdrawn\n", c->name ? c->name : "?");
}

static const struct wp_drm_lease_connector_v1_listener connector_listener = {
	.name = connector_name,
	.description = connector_description,
	.connector_id = connector_id,
	.done = connector_done,
	.withdrawn = connector_withdrawn,
};

static void lease_fd_event(void *data, struct wp_drm_lease_v1 *lease,
			   int32_t fd)
{
	char path[64];

	lease_fd = fcntl(fd, F_DUPFD_CLOEXEC, 3);
	snprintf(path, sizeof(path), "/proc/self/fd/%d", lease_fd);
	printf("lease fd %d -> %s\n", lease_fd, realpath(path, NULL));
	modeset(lease_fd);
}

static void lease_finished(void *data, struct wp_drm_lease_v1 *lease)
{
	printf("lease finished (revoked)\n");
	lease_fd = -1;
}

static const struct wp_drm_lease_v1_listener lease_listener = {
	.lease_fd = lease_fd_event,
	.finished = lease_finished,
};

static void device_drm_fd(void *data, struct wp_drm_lease_device_v1 *dev,
			  int32_t fd)
{
}

static void device_connector(void *data, struct wp_drm_lease_device_v1 *dev,
			     struct wp_drm_lease_connector_v1 *obj)
{
	struct connector *c = calloc(1, sizeof(*c));

	c->obj = obj;
	c->next = connectors;
	connectors = c;
	wp_drm_lease_connector_v1_add_listener(obj, &connector_listener, c);
}

static void device_done(void *data, struct wp_drm_lease_device_v1 *dev)
{
	struct connector *c;

	if (requested)
		return;
	for (c = connectors; c; c = c->next) {
		if (c->name && strstr(c->name, want)) {
			struct wp_drm_lease_request_v1 *req;
			struct wp_drm_lease_v1 *lease;

			printf("requesting lease for %s (connector %u)\n",
			       c->name, c->id);
			req = wp_drm_lease_device_v1_create_lease_request(dev);
			wp_drm_lease_request_v1_request_connector(req, c->obj);
			lease = wp_drm_lease_request_v1_submit(req);
			wp_drm_lease_v1_add_listener(lease, &lease_listener, NULL);
			requested = 1;
			return;
		}
	}
}

static void device_released(void *data, struct wp_drm_lease_device_v1 *dev)
{
}

static const struct wp_drm_lease_device_v1_listener device_listener = {
	.drm_fd = device_drm_fd,
	.connector = device_connector,
	.done = device_done,
	.released = device_released,
};

static void registry_global(void *data, struct wl_registry *registry,
			    uint32_t name, const char *interface,
			    uint32_t version)
{
	if (!strcmp(interface, wp_drm_lease_device_v1_interface.name)) {
		lease_device = wl_registry_bind(registry, name,
						&wp_drm_lease_device_v1_interface, 1);
		wp_drm_lease_device_v1_add_listener(lease_device,
						    &device_listener, NULL);
	}
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
};

int main(void)
{
	struct wl_display *display;
	struct wl_registry *registry;

	setvbuf(stdout, NULL, _IONBF, 0);

	display = wl_display_connect(NULL);
	if (!display) {
		fprintf(stderr, "cannot connect to Wayland\n");
		return 1;
	}
	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);

	while (lease_fd < 0) {
		if (wl_display_roundtrip(display) < 0)
			break;
	}
	sleep(600);
	return 0;
}
