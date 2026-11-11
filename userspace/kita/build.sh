#!/bin/sh
# Build the cover daemon and the lease probe. Run in userspace/kita.
set -eu
cd "$(dirname "$0")"

wayland-scanner client-header drm-lease-v1.xml drm-lease-v1-client-protocol.h
wayland-scanner private-code drm-lease-v1.xml drm-lease-v1-protocol.c

cc -O2 -Wall kita.c drm-lease-v1-protocol.c -o kita \
	$(pkg-config --cflags --libs gio-2.0 wayland-client libdrm cairo pangocairo) -lm

cc -O2 -Wall lease-modeset.c drm-lease-v1-protocol.c -o lease-modeset \
	$(pkg-config --cflags --libs wayland-client libdrm)
