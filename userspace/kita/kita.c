// SPDX-License-Identifier: MIT
// kita: the Galaxy Z Flip3 cover display daemon.
//
// The cover panel is a non-desktop DRM connector. KWin does not use it and
// only offers it through wp_drm_lease_v1. This daemon takes the lease, owns
// the connector with DRM/KMS, and draws the clock, notifications and the
// incoming-call banner with Cairo/Pango. The DE never touches it.
//
// The panel is 260x512, one DSI lane, command mode. Frames are pushed with
// drmModeDirtyFB after each redraw.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <cairo/cairo.h>
#include <pango/pangocairo.h>

#include <gio/gio.h>
#include <glib-unix.h>
#include <linux/input.h>
#include <wayland-client.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#include "drm-lease-v1-client-protocol.h"

#define BACKLIGHT_PATH "/sys/class/backlight/ae96000.dsi.0/brightness"
#define BACKLIGHT_ON 160
#define MAX_NOTIFICATIONS 3
#define NOTIFICATION_LIFETIME 90
#define WAKE_SECONDS 8

struct notification {
	guint32 id;
	gint64 created;
	char *app;
	char *summary;
	char *body;
	double top;
	double height;
};

struct connector {
	struct wp_drm_lease_connector_v1 *obj;
	char *name;
	uint32_t id;
	struct connector *next;
};

struct daemon {
	GMainLoop *loop;
	struct wl_display *wl;
	struct wl_registry *registry;
	struct wp_drm_lease_device_v1 *lease_dev;
	struct connector *connectors;
	gboolean requested;
	struct wp_drm_lease_v1 *lease;
	gboolean lease_granted;
	int lease_fd;

	uint32_t crtc_id;
	uint32_t connector_id;
	drmModeModeInfo mode;
	gboolean have_mode;
	gboolean scanout;
	struct {
		uint32_t fb_id;
		uint32_t handle;
		uint32_t pitch;
		uint64_t size;
		void *map;
	} buf;

	GDBusConnection *system_bus;
	guint imsd_sub;
	GDBusProxy *logind;
	gboolean folded;
	int backlight;
	gboolean awake;
	guint sleep_source;
	uint32_t dpms_prop;
	int power_fd;
	guint power_source;

	int touch_fd;
	guint touch_source;
	gboolean touch_down;
	int touch_x;
	int touch_y;
	int touch_down_x;
	int touch_down_y;
	GDBusConnection *session_bus;

	GArray *notifications;
	gboolean call_active;
	gboolean call_answered;
	guint32 call_id;
	char call_number[64];

	char clock_text[8];
	char date_text[32];
	/* One-shot timers, armed only while the cover is awake. */
	guint clock_source;
	guint expiry_source;

	/* Session-bus monitor connection for NotificationWatcher.Notify. */
	GDBusConnection *monitor;
	guint monitor_filter;
	gulong monitor_closed_handler;
	gint64 monitor_started;

	/* The qml6 DPMS helper for the main panel: one child at a time. */
	GPid dpms_child;
	gboolean dpms_child_state;
	gboolean dpms_pending;
	gboolean dpms_pending_state;

	char *dump_path;
};

static void draw_ui(struct daemon *d);
static void set_backlight(struct daemon *d, int value);
static void set_panel_power(struct daemon *d, gboolean on);
static void wake_display(struct daemon *d);

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h,
			 double r)
{
	if (r > w / 2)
		r = w / 2;
	if (r > h / 2)
		r = h / 2;
	cairo_new_sub_path(cr);
	cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
	cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
	cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
	cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
	cairo_close_path(cr);
}

static int draw_text(cairo_t *cr, const char *text, const char *font,
		     double x, double y, double width, PangoAlignment align,
		     double red, double green, double blue, double alpha,
		     gboolean ellipsize, double max_height)
{
	PangoLayout *layout;
	PangoFontDescription *desc;
	PangoRectangle ext;
	int height;

	if (!text)
		text = "";

	layout = pango_cairo_create_layout(cr);
	desc = pango_font_description_from_string(font);
	pango_layout_set_font_description(layout, desc);
	pango_layout_set_text(layout, text, -1);
	if (width > 0) {
		pango_layout_set_width(layout, (int)(width * PANGO_SCALE));
		pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
	}
	pango_layout_set_alignment(layout, align);
	if (ellipsize) {
		pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
		if (max_height > 0)
			pango_layout_set_height(layout,
						(int)(max_height * PANGO_SCALE));
	}

	cairo_set_source_rgba(cr, red, green, blue, alpha);
	cairo_move_to(cr, x, y);
	pango_cairo_show_layout(cr, layout);

	pango_layout_get_pixel_extents(layout, NULL, &ext);
	height = ext.height;
	pango_font_description_free(desc);
	g_object_unref(layout);
	return height;
}

static void update_clock(struct daemon *d)
{
	time_t now = time(NULL);
	struct tm tm;

	localtime_r(&now, &tm);
	strftime(d->clock_text, sizeof(d->clock_text), "%H:%M", &tm);
	strftime(d->date_text, sizeof(d->date_text), "%a %d %b", &tm);
}

static void free_notification(struct notification *n)
{
	g_free(n->app);
	g_free(n->summary);
	g_free(n->body);
}

static void prune_notifications(struct daemon *d)
{
	gint64 now = g_get_monotonic_time();
	guint i = 0;

	while (i < d->notifications->len) {
		struct notification *n = &g_array_index(d->notifications,
							struct notification, i);

		if (now - n->created >= NOTIFICATION_LIFETIME * G_TIME_SPAN_SECOND) {
			free_notification(n);
			g_array_remove_index(d->notifications, i);
		} else {
			i++;
		}
	}
}

static void stop_awake_timers(struct daemon *d)
{
	if (d->clock_source) {
		g_source_remove(d->clock_source);
		d->clock_source = 0;
	}
	if (d->expiry_source) {
		g_source_remove(d->expiry_source);
		d->expiry_source = 0;
	}
}

static gboolean clock_cb(gpointer user_data)
{
	struct daemon *d = user_data;

	d->clock_source = 0;
	if (d->awake)
		draw_ui(d);
	return G_SOURCE_REMOVE;
}

static gboolean expiry_cb(gpointer user_data)
{
	struct daemon *d = user_data;

	d->expiry_source = 0;
	if (d->awake)
		draw_ui(d);
	return G_SOURCE_REMOVE;
}

/*
 * While the cover is lit: one timeout at the next minute boundary for the
 * clock and one at the earliest notification expiry. Asleep, nothing runs;
 * the next wake redraws (and prunes) anyway.
 */
static void arm_awake_timers(struct daemon *d)
{
	gint64 now_real = g_get_real_time();
	gint64 now_mono = g_get_monotonic_time();
	gint64 earliest = G_MAXINT64;
	guint ms;
	guint i;

	stop_awake_timers(d);
	if (!d->awake)
		return;

	ms = (guint)((60 * G_TIME_SPAN_SECOND -
		      now_real % (60 * G_TIME_SPAN_SECOND)) / 1000) + 50;
	d->clock_source = g_timeout_add(ms, clock_cb, d);

	for (i = 0; i < d->notifications->len; i++) {
		struct notification *n = &g_array_index(d->notifications,
							struct notification, i);
		gint64 expires = n->created +
				 NOTIFICATION_LIFETIME * G_TIME_SPAN_SECOND;

		if (expires < earliest)
			earliest = expires;
	}
	if (earliest != G_MAXINT64) {
		gint64 delay = earliest - now_mono;

		if (delay < 0)
			delay = 0;
		d->expiry_source = g_timeout_add((guint)(delay / 1000) + 1,
						 expiry_cb, d);
	}
}

static void draw_call_banner(cairo_t *cr, struct daemon *d, double *y)
{
	const double margin = 12;
	double x = margin;
	double w = 512 - 2 * margin;
	double h = 62;
	int inner;

	rounded_rect(cr, x, *y, w, h, 12);
	cairo_set_source_rgb(cr, 0.70, 0.13, 0.11);
	cairo_fill(cr);

	inner = draw_text(cr, d->call_answered ? "In call" : "Incoming call",
			  "Sans 12", x, *y + 6, w, PANGO_ALIGN_CENTER,
			  1, 1, 1, 1, FALSE, 0);
	draw_text(cr, d->call_number, "Sans 18", x,
		  *y + 6 + inner + 2, w, PANGO_ALIGN_CENTER,
		  1, 1, 1, 1, TRUE, 26);

	*y += h + 10;
}

static void draw_notification(cairo_t *cr, struct notification *n, double *y)
{
	const double x = 280;
	const double w = 512 - x - 14;
	const double pad = 9;
	const double text_width = w - 2 * pad;
	double top = *y;
	int app_h, sum_h, body_h;
	char app[128];

	g_snprintf(app, sizeof(app), "%s", n->app && n->app[0] ? n->app : "Notification");

	app_h = draw_text(cr, app, "Sans 8", x + pad, top + 7, text_width,
			  PANGO_ALIGN_LEFT, 0.62, 0.65, 0.68, 1, TRUE, 16);
	sum_h = draw_text(cr, n->summary, "Sans 10 Bold", x + pad,
			  top + 7 + app_h + 2, text_width, PANGO_ALIGN_LEFT,
			  1, 1, 1, 1, TRUE, 18);
	body_h = draw_text(cr, n->body, "Sans 9", x + pad,
			   top + 7 + app_h + 2 + sum_h + 2, text_width,
			   PANGO_ALIGN_LEFT, 0.78, 0.80, 0.82, 1, TRUE, 36);

	if (body_h < 0)
		body_h = 0;

	{
		double h = 7 + app_h + 2 + sum_h + 2 + body_h + 7;

		if (h < 52)
			h = 52;

		n->top = top;
		n->height = h;

		rounded_rect(cr, x, top, w, h, 10);
		cairo_set_source_rgb(cr, 0.105, 0.105, 0.105);
		cairo_fill(cr);

		draw_text(cr, app, "Sans 8", x + pad, top + 7, text_width,
			  PANGO_ALIGN_LEFT, 0.62, 0.65, 0.68, 1, TRUE, 16);
		draw_text(cr, n->summary, "Sans 10 Bold", x + pad,
			  top + 7 + app_h + 2, text_width, PANGO_ALIGN_LEFT,
			  1, 1, 1, 1, TRUE, 18);
		draw_text(cr, n->body, "Sans 9", x + pad,
			  top + 7 + app_h + 2 + sum_h + 2, text_width,
			  PANGO_ALIGN_LEFT, 0.78, 0.80, 0.82, 1, TRUE, 36);

		*y = top + h + 8;
	}
}

static void draw_ui(struct daemon *d)
{
	cairo_surface_t *logical;
	cairo_surface_t *fb;
	cairo_t *cr;
	cairo_t *fcr;
	double y = 14;
	int clock_h;
	guint i;

	if (!d->have_mode || !d->buf.map)
		return;

	update_clock(d);
	prune_notifications(d);
	arm_awake_timers(d);

	logical = cairo_image_surface_create(CAIRO_FORMAT_RGB24, 512, 260);
	cr = cairo_create(logical);
	cairo_set_source_rgb(cr, 0, 0, 0);
	cairo_paint(cr);

	if (d->call_active) {
		draw_call_banner(cr, d, &y);
		clock_h = draw_text(cr, d->clock_text, "Sans 44", 22, y, 260,
				    PANGO_ALIGN_LEFT, 1, 1, 1, 1, FALSE, 0);
		draw_text(cr, d->date_text, "Sans 12", 24, y + clock_h + 2, 260,
			  PANGO_ALIGN_LEFT, 0.62, 0.65, 0.68, 1, FALSE, 0);
	} else {
		clock_h = draw_text(cr, d->clock_text, "Sans 58", 24, 32, 250,
				    PANGO_ALIGN_LEFT, 1, 1, 1, 1, FALSE, 0);
		draw_text(cr, d->date_text, "Sans 13", 26, 32 + clock_h + 2, 250,
			  PANGO_ALIGN_LEFT, 0.62, 0.65, 0.68, 1, FALSE, 0);

		y = 14;
		for (i = 0; i < d->notifications->len; i++) {
			struct notification *n = &g_array_index(d->notifications,
								struct notification, i);

			if (y > 260 - 50)
				break;
			draw_notification(cr, n, &y);
		}
	}

	cairo_destroy(cr);
	cairo_surface_flush(logical);

	if (d->dump_path)
		cairo_surface_write_to_png(logical, d->dump_path);

	/* The panel is mounted landscape but scans out 260x512. Rotate the
	 * 512x260 logical frame counter-clockwise into the framebuffer; the
	 * mount turns it back upright. */
	fb = cairo_image_surface_create_for_data(d->buf.map, CAIRO_FORMAT_RGB24,
						 d->mode.hdisplay,
						 d->mode.vdisplay, d->buf.pitch);
	fcr = cairo_create(fb);
	cairo_set_source_rgb(fcr, 0, 0, 0);
	cairo_paint(fcr);
	cairo_translate(fcr, d->mode.hdisplay, 0);
	cairo_rotate(fcr, M_PI / 2);
	cairo_set_source_surface(fcr, logical, 0, 0);
	cairo_paint(fcr);
	cairo_destroy(fcr);
	cairo_surface_flush(fb);
	cairo_surface_destroy(fb);
	cairo_surface_destroy(logical);

	if (d->scanout && d->lease_fd >= 0 && d->buf.fb_id) {
		int ret = drmModeDirtyFB(d->lease_fd, d->buf.fb_id, NULL, 0);

		if (ret)
			g_message("DirtyFB failed: %s", strerror(errno));
	}
}

static void set_backlight(struct daemon *d, int value)
{
	char buf[16];
	int fd, len;
	ssize_t wr;

	fd = open(BACKLIGHT_PATH, O_WRONLY);
	if (fd < 0) {
		g_message("backlight %d: %s", value, strerror(errno));
		return;
	}
	len = g_snprintf(buf, sizeof(buf), "%d\n", value);
	wr = write(fd, buf, len);
	g_message("backlight %d: %s", value,
		  wr == len ? "ok" : strerror(errno));
	close(fd);
	if (wr == len)
		d->backlight = value;
}

static void set_panel_power(struct daemon *d, gboolean on)
{
	int ret;

	if (!d->have_mode || d->lease_fd < 0 || !d->dpms_prop)
		return;
	ret = drmModeConnectorSetProperty(d->lease_fd, d->connector_id,
					  d->dpms_prop,
					  on ? DRM_MODE_DPMS_ON :
					       DRM_MODE_DPMS_OFF);
	if (ret)
		g_message("DPMS %s: %s", on ? "on" : "off", strerror(errno));
}

static void wake_display(struct daemon *d);

static void close_notification_id(struct daemon *d, guint32 id)
{
	if (!d->session_bus)
		return;
	g_dbus_connection_call(d->session_bus,
			       "org.freedesktop.Notifications",
			       "/org/freedesktop/Notifications",
			       "org.freedesktop.Notifications",
			       "CloseNotification", g_variant_new("(u)", id),
			       NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL,
			       NULL);
}

static void dismiss_notification(struct daemon *d, guint index)
{
	struct notification *n = &g_array_index(d->notifications,
						struct notification, index);

	close_notification_id(d, n->id);
	free_notification(n);
	g_array_remove_index(d->notifications, index);
}

static void handle_tap(struct daemon *d, int x, int y)
{
	guint i;

	/*
	 * A tap never wakes the panel: only a notification, a call, an SMS
	 * or the power key do. While the cover is lit, a tap dismisses the
	 * notification card it lands on and restarts the sleep timer.
	 */
	if (!d->awake)
		return;

	if (!d->call_active && x >= 280) {
		for (i = 0; i < d->notifications->len; i++) {
			struct notification *n = &g_array_index(d->notifications,
						struct notification, i);

			if (y >= n->top && y < n->top + n->height) {
				dismiss_notification(d, i);
				break;
			}
		}
	}

	wake_display(d);
}

static gboolean touch_event(gint fd, GIOCondition condition,
			    gpointer user_data)
{
	struct daemon *d = user_data;
	struct input_event ev;
	ssize_t n;

	while ((n = read(fd, &ev, sizeof(ev))) == sizeof(ev)) {
		if (ev.type == EV_ABS) {
			if (ev.code == ABS_MT_POSITION_X)
				d->touch_x = ev.value;
			else if (ev.code == ABS_MT_POSITION_Y)
				d->touch_y = ev.value;
		} else if (ev.type == EV_KEY && ev.code == BTN_TOUCH) {
			if (ev.value) {
				d->touch_down = TRUE;
				d->touch_down_x = d->touch_x;
				d->touch_down_y = d->touch_y;
			} else if (d->touch_down) {
				d->touch_down = FALSE;
				if (abs(d->touch_x - d->touch_down_x) < 40 &&
				    abs(d->touch_y - d->touch_down_y) < 40)
					handle_tap(d, d->touch_x, d->touch_y);
				else
					wake_display(d);
			}
		}
	}
	if ((condition & (G_IO_HUP | G_IO_ERR | G_IO_NVAL)) ||
	    (n < 0 && errno != EAGAIN && errno != EINTR)) {
		g_message("touch device gone");
		close(fd);
		d->touch_fd = -1;
		d->touch_source = 0;
		return G_SOURCE_REMOVE;
	}
	return G_SOURCE_CONTINUE;
}

static void setup_touch(struct daemon *d)
{
	GDir *dir;
	const char *name;

	dir = g_dir_open("/dev/input", 0, NULL);
	if (!dir)
		return;
	while ((name = g_dir_read_name(dir))) {
		char path[64];
		char devname[64] = { 0 };
		int fd;

		if (!g_str_has_prefix(name, "event"))
			continue;
		g_snprintf(path, sizeof(path), "/dev/input/%s", name);
		fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (ioctl(fd, EVIOCGNAME(sizeof(devname)), devname) < 0 ||
		    strcmp(devname, "Zinitix Capacitive TouchScreen")) {
			close(fd);
			continue;
		}
		if (ioctl(fd, EVIOCGRAB, 1) < 0)
			g_message("touch: EVIOCGRAB: %s", strerror(errno));
		d->touch_fd = fd;
		d->touch_source = g_unix_fd_add(fd, G_IO_IN | G_IO_HUP | G_IO_ERR,
						touch_event, d);
		g_message("touch on %s", path);
		break;
	}
	g_dir_close(dir);
}

static gboolean sleep_display_cb(gpointer user_data)
{
	struct daemon *d = user_data;

	d->sleep_source = 0;
	d->awake = FALSE;
	stop_awake_timers(d);
	set_backlight(d, 0);
	set_panel_power(d, FALSE);
	return G_SOURCE_REMOVE;
}

static void wake_display(struct daemon *d)
{
	if (!d->folded || !d->have_mode)
		return;
	if (d->sleep_source) {
		g_source_remove(d->sleep_source);
		d->sleep_source = 0;
	}
	d->awake = TRUE;
	set_panel_power(d, TRUE);
	set_backlight(d, BACKLIGHT_ON);
	draw_ui(d);
	if (!d->call_active)
		d->sleep_source = g_timeout_add_seconds(WAKE_SECONDS,
							sleep_display_cb, d);
}

static void spawn_main_dpms(struct daemon *d, gboolean on);

static void main_dpms_exit(GPid pid, gint status, gpointer user_data)
{
	struct daemon *d = user_data;

	(void)status;
	g_spawn_close_pid(pid);
	d->dpms_child = 0;
	if (d->dpms_pending) {
		d->dpms_pending = FALSE;
		if (d->dpms_pending_state != d->dpms_child_state)
			spawn_main_dpms(d, d->dpms_pending_state);
	}
}

static void spawn_main_dpms(struct daemon *d, gboolean on)
{
	gchar *argv[] = {
		(gchar *)"/usr/bin/qml6",
		(gchar *)(on ? "/usr/local/share/kita/dpms-main-on.qml" :
				 "/usr/local/share/kita/dpms-main-off.qml"),
		NULL
	};
	GError *err = NULL;
	GPid pid;

	g_message("main DPMS %s", on ? "on" : "off");
	if (!g_spawn_async(NULL, argv, NULL,
			   G_SPAWN_SEARCH_PATH | G_SPAWN_DO_NOT_REAP_CHILD,
			   NULL, NULL, &pid, &err)) {
		g_message("main DPMS: %s", err->message);
		g_error_free(err);
		return;
	}
	d->dpms_child = pid;
	d->dpms_child_state = on;
	g_child_watch_add(pid, main_dpms_exit, d);
}

/*
 * One helper at a time: a quick fold/unfold would otherwise run the off and
 * on helpers concurrently and leave the main panel in whichever finished
 * last. A request made while one runs is applied when it exits, unless the
 * running helper already applies that state.
 */
static void set_main_dpms(struct daemon *d, gboolean on)
{
	if (d->dpms_child) {
		d->dpms_pending = TRUE;
		d->dpms_pending_state = on;
		return;
	}
	spawn_main_dpms(d, on);
}

static void apply_lid(struct daemon *d)
{
	g_message("lid %s", d->folded ? "closed" : "open");
	set_main_dpms(d, !d->folded);
	if (!d->folded || !d->call_active) {
		if (d->sleep_source) {
			g_source_remove(d->sleep_source);
			d->sleep_source = 0;
		}
		d->awake = FALSE;
		stop_awake_timers(d);
		set_backlight(d, 0);
		set_panel_power(d, FALSE);
		return;
	}
	wake_display(d);
}

static void on_logind_properties(GDBusProxy *proxy, GVariant *changed,
				 GStrv invalidated, gpointer user_data)
{
	struct daemon *d = user_data;
	GVariant *v;

	(void)proxy;
	(void)invalidated;
	v = g_variant_lookup_value(changed, "LidClosed", G_VARIANT_TYPE_BOOLEAN);
	if (v) {
		d->folded = g_variant_get_boolean(v);
		g_variant_unref(v);
		apply_lid(d);
	}
}

static void setup_logind(struct daemon *d)
{
	GError *err = NULL;
	GVariant *v;

	d->folded = TRUE;
	d->logind = g_dbus_proxy_new_sync(d->system_bus,
					  G_DBUS_PROXY_FLAGS_NONE, NULL,
					  "org.freedesktop.login1",
					  "/org/freedesktop/login1",
					  "org.freedesktop.login1.Manager",
					  NULL, &err);
	if (!d->logind) {
		g_message("logind: %s", err->message);
		g_error_free(err);
		return;
	}

	v = g_dbus_proxy_get_cached_property(d->logind, "LidClosed");
	if (v) {
		d->folded = g_variant_get_boolean(v);
		g_variant_unref(v);
	}
	g_signal_connect(d->logind, "g-properties-changed",
			 G_CALLBACK(on_logind_properties), d);
	apply_lid(d);
}

static void add_notification(struct daemon *d, guint32 id, const char *app,
			     const char *summary, const char *body)
{
	struct notification n;
	guint i;

	if (app && !strcmp(app, "b2q-call"))
		return;

	for (i = 0; i < d->notifications->len; i++) {
		struct notification *old = &g_array_index(d->notifications,
							 struct notification, i);

		if (old->id == id) {
			free_notification(old);
			g_array_remove_index(d->notifications, i);
			break;
		}
	}

	n.id = id;
	n.created = g_get_monotonic_time();
	n.app = g_strdup(app ? app : "");
	n.summary = g_strdup(summary ? summary : "");
	n.body = g_strdup(body ? body : "");
	g_array_prepend_val(d->notifications, n);

	while (d->notifications->len > MAX_NOTIFICATIONS) {
		struct notification *old = &g_array_index(d->notifications,
							 struct notification,
							 d->notifications->len - 1);

		free_notification(old);
		g_array_remove_index(d->notifications,
				     d->notifications->len - 1);
	}

	wake_display(d);
}

/*
 * Plasma delivers each notification to its watchers as a method call,
 * org.kde.NotificationWatcher.Notify(u id, s app_name, u replaces_id,
 * s app_icon, s summary, s body, as actions, a{sv} hints, i timeout).
 * A monitor connection on the session bus sees those calls without
 * registering as a watcher. The filter runs in the GDBus worker thread, so
 * it only copies the fields out and hands them to the main loop.
 */
struct pending_notification {
	struct daemon *d;
	guint32 id;
	char *app;
	char *summary;
	char *body;
};

static void pending_notification_free(gpointer data)
{
	struct pending_notification *p = data;

	g_free(p->app);
	g_free(p->summary);
	g_free(p->body);
	g_free(p);
}

static gboolean deliver_notification(gpointer data)
{
	struct pending_notification *p = data;

	add_notification(p->d, p->id, p->app, p->summary, p->body);
	return G_SOURCE_REMOVE;
}

static char *child_string(GVariant *body, gsize index)
{
	GVariant *v = g_variant_get_child_value(body, index);
	char *s = NULL;

	if (g_variant_is_of_type(v, G_VARIANT_TYPE_STRING))
		s = g_variant_dup_string(v, NULL);
	g_variant_unref(v);
	return s;
}

static GDBusMessage *monitor_filter(GDBusConnection *connection,
				    GDBusMessage *message, gboolean incoming,
				    gpointer user_data)
{
	struct daemon *d = user_data;
	struct pending_notification *p;
	GVariant *body;
	GVariant *idv;

	(void)connection;
	if (!incoming)
		return message;

	if (g_dbus_message_get_message_type(message) ==
		    G_DBUS_MESSAGE_TYPE_METHOD_CALL &&
	    !g_strcmp0(g_dbus_message_get_interface(message),
		       "org.kde.NotificationWatcher") &&
	    !g_strcmp0(g_dbus_message_get_member(message), "Notify")) {
		body = g_dbus_message_get_body(message);
		if (body && g_variant_is_of_type(body, G_VARIANT_TYPE_TUPLE) &&
		    g_variant_n_children(body) >= 6) {
			idv = g_variant_get_child_value(body, 0);
			if (g_variant_is_of_type(idv, G_VARIANT_TYPE_UINT32)) {
				p = g_new0(struct pending_notification, 1);
				p->d = d;
				p->id = g_variant_get_uint32(idv);
				p->app = child_string(body, 1);
				p->summary = child_string(body, 4);
				p->body = child_string(body, 5);
				g_idle_add_full(G_PRIORITY_DEFAULT,
						deliver_notification, p,
						pending_notification_free);
			}
			g_variant_unref(idv);
		}
	}

	/*
	 * Replies and signals addressed to this connection (the BecomeMonitor
	 * reply, NameLost) go on to GDBus. Monitored traffic is addressed to
	 * someone else, and no method call may reach GDBus's dispatch, which
	 * would answer it: a monitor that sends anything is disconnected.
	 */
	if (g_dbus_message_get_message_type(message) !=
		    G_DBUS_MESSAGE_TYPE_METHOD_CALL &&
	    !g_strcmp0(g_dbus_message_get_destination(message),
		       g_dbus_connection_get_unique_name(connection)))
		return message;
	g_object_unref(message);
	return NULL;
}

static void start_notification_monitor(struct daemon *d);

static void monitor_closed(GDBusConnection *connection,
			   gboolean remote_peer_vanished, GError *error,
			   gpointer user_data)
{
	struct daemon *d = user_data;
	gboolean was_long_lived;

	(void)remote_peer_vanished;
	g_message("notification monitor closed: %s",
		  error ? error->message : "no error");
	if (connection != d->monitor)
		return;
	g_dbus_connection_remove_filter(d->monitor, d->monitor_filter);
	g_signal_handler_disconnect(d->monitor, d->monitor_closed_handler);
	g_clear_object(&d->monitor);
	d->monitor_filter = 0;
	d->monitor_closed_handler = 0;

	/*
	 * Reconnect once per close. A connection that dies right after it was
	 * made would only die again, so give up then instead of looping.
	 */
	was_long_lived = g_get_monotonic_time() - d->monitor_started >
			 10 * G_TIME_SPAN_SECOND;
	if (was_long_lived)
		start_notification_monitor(d);
	else
		g_message("notification monitor: not reconnecting");
}

static void start_notification_monitor(struct daemon *d)
{
	static const char *rules[] = {
		"type='method_call',interface='org.kde.NotificationWatcher',member='Notify'",
		NULL
	};
	GError *err = NULL;
	GVariant *ret;
	gchar *address;

	address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, NULL, &err);
	if (!address) {
		g_message("notification monitor: %s", err->message);
		g_error_free(err);
		return;
	}
	d->monitor = g_dbus_connection_new_for_address_sync(address,
		G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
		G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
		NULL, NULL, &err);
	g_free(address);
	if (!d->monitor) {
		g_message("notification monitor: %s", err->message);
		g_error_free(err);
		return;
	}
	g_dbus_connection_set_exit_on_close(d->monitor, FALSE);

	/* Install the filter first so nothing arriving after BecomeMonitor
	 * reaches GDBus's own dispatch. */
	d->monitor_filter = g_dbus_connection_add_filter(d->monitor,
							 monitor_filter, d,
							 NULL);
	ret = g_dbus_connection_call_sync(d->monitor, "org.freedesktop.DBus",
					  "/org/freedesktop/DBus",
					  "org.freedesktop.DBus.Monitoring",
					  "BecomeMonitor",
					  g_variant_new("(^asu)", rules, 0u),
					  NULL, G_DBUS_CALL_FLAGS_NONE, -1,
					  NULL, &err);
	if (!ret) {
		g_message("BecomeMonitor: %s", err->message);
		g_error_free(err);
		g_dbus_connection_remove_filter(d->monitor, d->monitor_filter);
		d->monitor_filter = 0;
		g_dbus_connection_close_sync(d->monitor, NULL, NULL);
		g_clear_object(&d->monitor);
		return;
	}
	g_variant_unref(ret);
	d->monitor_started = g_get_monotonic_time();
	d->monitor_closed_handler = g_signal_connect(d->monitor, "closed",
						     G_CALLBACK(monitor_closed),
						     d);
	g_message("notification monitor on the session bus");
}

static void on_imsd_signal(GDBusConnection *connection, const gchar *sender,
			   const gchar *path, const gchar *interface,
			   const gchar *signal, GVariant *params,
			   gpointer user_data)
{
	struct daemon *d = user_data;
	guint32 id;
	gint32 direction, state;

	(void)connection;
	(void)sender;
	(void)path;
	(void)interface;

	if (!g_strcmp0(signal, "CallAdded")) {
		const gchar *number;

		g_variant_get(params, "(u&si)", &id, &number, &direction);
		if (direction != 1)
			return;
		d->call_active = TRUE;
		d->call_answered = FALSE;
		d->call_id = id;
		g_strlcpy(d->call_number,
			  number && number[0] ? number : "unknown",
			  sizeof(d->call_number));
		wake_display(d);
	} else if (!g_strcmp0(signal, "CallStateChanged")) {
		gint32 reason;

		g_variant_get(params, "(uii)", &id, &state, &reason);
		if (!d->call_active || id != d->call_id)
			return;
		if (state == 4) {
			d->call_answered = TRUE;
			if (d->awake)
				draw_ui(d);
		} else if (state == 0 || state == 6 || state == 7) {
			/*
			 * imsd's own numbering, not ModemManager's enum
			 * (map_imsd_call_state() in IMSroha's modemmanager/0001
			 * translates): 0 is idle, and 6 and 7 both map to
			 * terminated. imsd emits 6 on every hangup path
			 * (local BYE, remote BYE, CANCEL). 5 is held, which
			 * is still a call and must not clear the banner.
			 */
			g_message("call %u ended (state %d)", id, state);
			d->call_active = FALSE;
			d->call_answered = FALSE;
			wake_display(d);
		}
	} else if (!g_strcmp0(signal, "PduReceived")) {
		/* An SMS wakes the cover; Spacebar normally posts a
		 * notification as well, this is the direct path. */
		wake_display(d);
	}
}

static void setup_system_bus(struct daemon *d)
{
	GError *err = NULL;

	d->system_bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &err);
	if (!d->system_bus) {
		g_message("system bus: %s", err->message);
		g_error_free(err);
		return;
	}
	d->imsd_sub = g_dbus_connection_signal_subscribe(d->system_bus, NULL,
							 "codes.noa.IMSroha",
							 NULL,
							 "/codes/noa/IMSroha",
							 NULL,
							 G_DBUS_SIGNAL_FLAGS_NONE,
							 on_imsd_signal, d,
							 NULL);
}

static int start_display(struct daemon *d, int fd)
{
	drmModeRes *res;
	drmModeConnector *conn = NULL;
	drmModeEncoder *enc;
	struct drm_mode_create_dumb dumb = { 0 };
	struct drm_mode_map_dumb map = { 0 };
	uint32_t crtc_id = 0;
	unsigned int i;
	int ret;

	res = drmModeGetResources(fd);
	if (!res) {
		g_message("drmModeGetResources: %s", strerror(errno));
		return -1;
	}

	for (i = 0; i < res->count_connectors; i++) {
		drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);

		if (!c)
			continue;
		if (!conn && c->connection == DRM_MODE_CONNECTED &&
		    c->count_modes > 0) {
			conn = c;
		} else {
			drmModeFreeConnector(c);
		}
	}
	if (!conn) {
		g_message("leased connector is not connected");
		drmModeFreeResources(res);
		return -1;
	}

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
		g_message("no CRTC in the lease");
		drmModeFreeConnector(conn);
		drmModeFreeResources(res);
		return -1;
	}

	d->crtc_id = crtc_id;
	d->connector_id = conn->connector_id;
	d->mode = conn->modes[0];
	d->have_mode = TRUE;

	for (i = 0; i < conn->count_props; i++) {
		drmModePropertyRes *prop = drmModeGetProperty(fd, conn->props[i]);

		if (!prop)
			continue;
		if (!strcmp(prop->name, "DPMS"))
			d->dpms_prop = prop->prop_id;
		drmModeFreeProperty(prop);
	}

	dumb.width = d->mode.hdisplay;
	dumb.height = d->mode.vdisplay;
	dumb.bpp = 32;
	ret = ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &dumb);
	if (ret) {
		g_message("CREATE_DUMB: %s", strerror(errno));
		goto err;
	}
	map.handle = dumb.handle;
	ret = ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map);
	if (ret) {
		g_message("MAP_DUMB: %s", strerror(errno));
		goto err;
	}
	d->buf.map = mmap(NULL, dumb.size, PROT_READ | PROT_WRITE, MAP_SHARED,
			  fd, map.offset);
	if (d->buf.map == MAP_FAILED) {
		g_message("mmap: %s", strerror(errno));
		d->buf.map = NULL;
		goto err;
	}
	d->buf.handle = dumb.handle;
	d->buf.pitch = dumb.pitch;
	d->buf.size = dumb.size;

	ret = drmModeAddFB(fd, d->mode.hdisplay, d->mode.vdisplay, 24, 32,
			   d->buf.pitch, d->buf.handle, &d->buf.fb_id);
	if (ret) {
		g_message("AddFB: %s", strerror(errno));
		goto err;
	}

	draw_ui(d);

	ret = drmModeSetCrtc(fd, d->crtc_id, d->buf.fb_id, 0, 0,
			     &d->connector_id, 1, &d->mode);
	if (ret) {
		g_message("SetCrtc: %s", strerror(errno));
		goto err;
	}

	g_message("cover on %ux%u@%u crtc %u", d->mode.hdisplay,
		  d->mode.vdisplay, d->mode.vrefresh, d->crtc_id);
	d->scanout = TRUE;
	drmModeFreeConnector(conn);
	drmModeFreeResources(res);
	d->awake = FALSE;
	set_backlight(d, 0);
	set_panel_power(d, FALSE);
	return 0;

err:
	if (d->buf.fb_id)
		drmModeRmFB(fd, d->buf.fb_id);
	d->buf.fb_id = 0;
	if (d->buf.map)
		munmap(d->buf.map, dumb.size);
	d->buf.map = NULL;
	if (dumb.handle) {
		struct drm_mode_destroy_dumb destroy = { .handle = dumb.handle };

		ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
	}
	d->buf.handle = 0;
	d->have_mode = FALSE;
	d->dpms_prop = 0;
	drmModeFreeConnector(conn);
	drmModeFreeResources(res);
	return -1;
}

static void destroy_display(struct daemon *d)
{
	if (d->sleep_source) {
		g_source_remove(d->sleep_source);
		d->sleep_source = 0;
	}
	d->awake = FALSE;
	stop_awake_timers(d);
	/* Panel off while the lease fd is still open. */
	set_backlight(d, 0);
	set_panel_power(d, FALSE);
	if (d->lease_fd >= 0) {
		if (d->buf.fb_id)
			drmModeRmFB(d->lease_fd, d->buf.fb_id);
		if (d->buf.map && d->buf.map != MAP_FAILED)
			munmap(d->buf.map, d->buf.size);
		close(d->lease_fd);
	}
	d->lease_fd = -1;
	d->buf.fb_id = 0;
	d->buf.map = NULL;
	d->buf.handle = 0;
	d->have_mode = FALSE;
	d->dpms_prop = 0;
	d->scanout = FALSE;
}

static struct connector *find_connector(struct daemon *d,
					struct wp_drm_lease_connector_v1 *obj)
{
	struct connector *c;

	for (c = d->connectors; c; c = c->next)
		if (c->obj == obj)
			return c;
	return NULL;
}

static void connector_name(void *data, struct wp_drm_lease_connector_v1 *obj,
			   const char *name)
{
	struct daemon *d = data;
	struct connector *c = find_connector(d, obj);

	if (c) {
		g_free(c->name);
		c->name = g_strdup(name);
		g_message("connector name %s", name);
	}
}

static void connector_description(void *data,
				  struct wp_drm_lease_connector_v1 *obj,
				  const char *description)
{
	(void)data;
	(void)obj;
	(void)description;
}

static void connector_id(void *data, struct wp_drm_lease_connector_v1 *obj,
			 uint32_t id)
{
	struct daemon *d = data;
	struct connector *c = find_connector(d, obj);

	if (c)
		c->id = id;
}

static void connector_done(void *data, struct wp_drm_lease_connector_v1 *obj)
{
	(void)data;
	(void)obj;
}

static void connector_withdrawn(void *data,
				struct wp_drm_lease_connector_v1 *obj)
{
	struct daemon *d = data;
	struct connector **link = &d->connectors;
	struct connector *c = *link;

	while (c) {
		if (c->obj == obj) {
			*link = c->next;
			g_message("connector %s withdrawn",
				  c->name ? c->name : "?");
			wp_drm_lease_connector_v1_destroy(obj);
			g_free(c->name);
			g_free(c);
			return;
		}
		link = &c->next;
		c = c->next;
	}
}

static const struct wp_drm_lease_connector_v1_listener connector_listener = {
	.name = connector_name,
	.description = connector_description,
	.connector_id = connector_id,
	.done = connector_done,
	.withdrawn = connector_withdrawn,
};

static void release_lease(struct daemon *d)
{
	if (d->lease) {
		wp_drm_lease_v1_destroy(d->lease);
		d->lease = NULL;
	}
	d->requested = FALSE;
	d->lease_granted = FALSE;
}

static void request_lease(struct daemon *d);

static void lease_fd_event(void *data, struct wp_drm_lease_v1 *lease,
			   int32_t fd)
{
	struct daemon *d = data;
	int flags;

	(void)lease;
	d->lease_granted = TRUE;
	flags = fcntl(fd, F_GETFD);
	if (flags >= 0)
		fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
	d->lease_fd = fd;
	g_message("cover lease fd %d", d->lease_fd);
	if (start_display(d, d->lease_fd) < 0) {
		/*
		 * Hand the lease back so the connector can be offered again.
		 * The next device_done (a connector change) requests it anew;
		 * retrying right away would fail the same way.
		 */
		close(d->lease_fd);
		d->lease_fd = -1;
		release_lease(d);
		wl_display_flush(d->wl);
	}
}

static void lease_finished(void *data, struct wp_drm_lease_v1 *lease)
{
	struct daemon *d = data;
	gboolean was_granted = d->lease_granted;

	(void)lease;
	g_message(was_granted ? "cover lease revoked" : "cover lease rejected");
	destroy_display(d);
	release_lease(d);
	/*
	 * A revoked lease is re-requested now if the connector is still on
	 * offer; otherwise KWin announces it again (connector + done) and
	 * device_done requests it. A rejected request waits for that
	 * announcement, so a refusing compositor cannot make this loop.
	 */
	if (was_granted)
		request_lease(d);
	wl_display_flush(d->wl);
}

static const struct wp_drm_lease_v1_listener lease_listener = {
	.lease_fd = lease_fd_event,
	.finished = lease_finished,
};

static void device_drm_fd(void *data, struct wp_drm_lease_device_v1 *dev,
			  int32_t fd)
{
	(void)data;
	(void)dev;
	(void)fd;
}

static void device_connector(void *data, struct wp_drm_lease_device_v1 *dev,
			     struct wp_drm_lease_connector_v1 *obj)
{
	struct daemon *d = data;
	struct connector *c = g_new0(struct connector, 1);

	(void)dev;
	c->obj = obj;
	c->next = d->connectors;
	d->connectors = c;
	g_message("connector object");
	wp_drm_lease_connector_v1_add_listener(obj, &connector_listener, d);
}

static void request_lease(struct daemon *d)
{
	struct connector *c;

	if (d->requested || d->lease_fd >= 0 || !d->lease_dev)
		return;

	for (c = d->connectors; c; c = c->next) {
		if (c->name && !strcmp(c->name, "DSI-2")) {
			struct wp_drm_lease_request_v1 *req;

			g_message("requesting cover lease");
			req = wp_drm_lease_device_v1_create_lease_request(d->lease_dev);
			wp_drm_lease_request_v1_request_connector(req, c->obj);
			d->lease = wp_drm_lease_request_v1_submit(req);
			wp_drm_lease_v1_add_listener(d->lease, &lease_listener, d);
			d->requested = TRUE;
			d->lease_granted = FALSE;
			wl_display_flush(d->wl);
			return;
		}
	}
}

static void device_done(void *data, struct wp_drm_lease_device_v1 *dev)
{
	struct daemon *d = data;

	(void)dev;
	g_message("lease device done");
	request_lease(d);
}

static void device_released(void *data, struct wp_drm_lease_device_v1 *dev)
{
	struct daemon *d = data;

	(void)dev;
	g_message("lease device released");
	if (d->loop)
		g_main_loop_quit(d->loop);
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
	struct daemon *d = data;

	(void)version;
	if (!strcmp(interface, wp_drm_lease_device_v1_interface.name)) {
		g_message("binding lease device");
		d->lease_dev = wl_registry_bind(registry, name,
						&wp_drm_lease_device_v1_interface,
						1);
		wp_drm_lease_device_v1_add_listener(d->lease_dev,
						    &device_listener, d);
	}
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
};

static gboolean on_wayland(gint fd, GIOCondition condition, gpointer user_data)
{
	struct daemon *d = user_data;

	(void)fd;
	(void)condition;
	if (wl_display_dispatch(d->wl) < 0) {
		g_message("Wayland connection lost");
		g_main_loop_quit(d->loop);
		return G_SOURCE_REMOVE;
	}
	wl_display_flush(d->wl);
	return G_SOURCE_CONTINUE;
}

static gboolean on_signal(gpointer user_data)
{
	struct daemon *d = user_data;

	if (d->loop)
		g_main_loop_quit(d->loop);
	return G_SOURCE_REMOVE;
}

static void cleanup(struct daemon *d)
{
	guint i;

	if (d->monitor) {
		if (d->monitor_closed_handler)
			g_signal_handler_disconnect(d->monitor,
						    d->monitor_closed_handler);
		if (d->monitor_filter)
			g_dbus_connection_remove_filter(d->monitor,
							d->monitor_filter);
		g_dbus_connection_close_sync(d->monitor, NULL, NULL);
		g_object_unref(d->monitor);
	}
	stop_awake_timers(d);
	if (d->power_source)
		g_source_remove(d->power_source);
	if (d->power_fd >= 0)
		close(d->power_fd);
	if (d->touch_source)
		g_source_remove(d->touch_source);
	if (d->touch_fd >= 0)
		close(d->touch_fd);
	if (d->sleep_source)
		g_source_remove(d->sleep_source);
	destroy_display(d);
	for (i = 0; i < d->notifications->len; i++) {
		struct notification *n = &g_array_index(d->notifications,
							struct notification, i);

		g_free(n->app);
		g_free(n->summary);
		g_free(n->body);
	}
	g_array_free(d->notifications, TRUE);
	if (d->logind)
		g_object_unref(d->logind);
	if (d->imsd_sub && d->system_bus)
		g_dbus_connection_signal_unsubscribe(d->system_bus, d->imsd_sub);
	if (d->system_bus)
		g_object_unref(d->system_bus);
	if (d->session_bus)
		g_object_unref(d->session_bus);
	if (d->wl)
		wl_display_disconnect(d->wl);
	g_free(d->dump_path);
	g_free(d);
}

static gboolean power_key_event(gint fd, GIOCondition condition,
				gpointer user_data)
{
	struct daemon *d = user_data;
	struct input_event ev;
	ssize_t n;

	while ((n = read(fd, &ev, sizeof(ev))) == sizeof(ev)) {
		if (ev.type == EV_KEY && ev.code == KEY_POWER && ev.value == 1 &&
		    d->folded) {
			/* Keep the inside off; only the cover wakes. */
			set_main_dpms(d, FALSE);
			wake_display(d);
		}
	}
	if ((condition & (G_IO_HUP | G_IO_ERR | G_IO_NVAL)) ||
	    (n < 0 && errno != EAGAIN && errno != EINTR)) {
		g_message("power key device gone");
		close(fd);
		d->power_fd = -1;
		d->power_source = 0;
		return G_SOURCE_REMOVE;
	}
	return G_SOURCE_CONTINUE;
}

static void setup_power_key(struct daemon *d)
{
	GDir *dir;
	const char *name;

	dir = g_dir_open("/dev/input", 0, NULL);
	if (!dir)
		return;
	while ((name = g_dir_read_name(dir))) {
		char path[64];
		unsigned char keybits[(KEY_MAX + 8) / 8] = { 0 };
		int fd;

		if (!g_str_has_prefix(name, "event"))
			continue;
		g_snprintf(path, sizeof(path), "/dev/input/%s", name);
		fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits) < 0 ||
		    !(keybits[KEY_POWER / 8] & (1 << (KEY_POWER % 8)))) {
			close(fd);
			continue;
		}
		d->power_fd = fd;
		d->power_source = g_unix_fd_add(fd, G_IO_IN | G_IO_HUP | G_IO_ERR,
						power_key_event, d);
		g_message("power key on %s", path);
		break;
	}
	g_dir_close(dir);
}

int main(int argc, char **argv)
{
	struct daemon *d;
	const char *dump = NULL;
	GOptionEntry options[] = {
		{ "dump", 'd', 0, G_OPTION_ARG_FILENAME, &dump,
		  "write each rendered frame to PATH (debug)", "PATH" },
		{ NULL }
	};
	GError *err = NULL;
	GOptionContext *context;
	int wl_fd;

	context = g_option_context_new("b2q cover display daemon");
	g_option_context_add_main_entries(context, options, NULL);
	if (!g_option_context_parse(context, &argc, &argv, &err)) {
		g_printerr("%s\n", err->message);
		g_error_free(err);
		g_option_context_free(context);
		return 1;
	}
	g_option_context_free(context);

	d = g_new0(struct daemon, 1);
	d->lease_fd = -1;
	d->backlight = -1;
	d->power_fd = -1;
	d->touch_fd = -1;
	d->dump_path = dump ? g_strdup(dump) : NULL;
	d->notifications = g_array_new(FALSE, TRUE, sizeof(struct notification));

	d->wl = wl_display_connect(NULL);
	if (!d->wl) {
		g_printerr("cannot connect to Wayland\n");
		return 1;
	}
	d->registry = wl_display_get_registry(d->wl);
	wl_registry_add_listener(d->registry, &registry_listener, d);
	wl_display_roundtrip(d->wl);
	/* Flush the lease-device bind and collect the initial connectors. */
	wl_display_roundtrip(d->wl);

	wl_fd = wl_display_get_fd(d->wl);
	g_unix_fd_add(wl_fd, G_IO_IN, on_wayland, d);

	d->session_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
	setup_system_bus(d);
	setup_logind(d);
	setup_power_key(d);
	setup_touch(d);
	update_clock(d);
	start_notification_monitor(d);

	d->loop = g_main_loop_new(NULL, FALSE);
	g_unix_signal_add(SIGINT, on_signal, d);
	g_unix_signal_add(SIGTERM, on_signal, d);

	g_message("kita started");
	g_main_loop_run(d->loop);
	g_message("kita stopped");
	cleanup(d);
	return 0;
}
