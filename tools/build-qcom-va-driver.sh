#!/bin/sh
# SPDX-License-Identifier: MIT
# Build and install qcom-va-driver (nyanmisaka/libva-v4l2-qcom) on the phone.
#
# Run this on the phone as <user>, from a checkout of this repo (or point
# QCOM_VA_DRIVER_PATCH at the patch). The source must already be at
# ~/src/qcom-va-driver.
#
#   tools/build-qcom-va-driver.sh
#
# It applies the local decode-order patch idempotently, does a fresh meson
# setup with the options the working install uses, builds, installs to /usr
# and leaves /usr/lib/dri/qcom_drv_video.so (plus the msm/v4l2 aliases).
set -eu

SRC="${QCOM_VA_DRIVER_SRC:-$HOME/src/qcom-va-driver}"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCH="${QCOM_VA_DRIVER_PATCH:-$here/../patches/qcom-va-driver/local-0001-make-decode-order-controls-optional.patch}"

if [ ! -d "$SRC" ]; then
	echo "qcom-va-driver source not found at $SRC" >&2
	exit 1
fi
if [ ! -f "$PATCH" ]; then
	echo "patch not found at $PATCH" >&2
	exit 1
fi

cd "$SRC"

# The zero fd is needed both to dry-run and to apply; keep the check and the
# apply on the same patch. Reverse-dry-run succeeding means it is already in.
if patch -p1 -R --dry-run -s -f <"$PATCH" >/dev/null 2>&1; then
	echo "local patch already applied"
else
	echo "applying $(basename "$PATCH")"
	patch -p1 -s <"$PATCH"
fi

# meson setup refuses an existing build directory, so start clean.
rm -rf build
meson setup build --buildtype=release --prefix=/usr -Dlibdir=lib \
	-Dcdsp_vpp=disabled -Dvulkan_vpp=disabled
meson compile -C build
sudo meson install -C build

ls -l /usr/lib/dri/qcom_drv_video.so /usr/lib/dri/msm_drv_video.so \
	/usr/lib/dri/v4l2_drv_video.so
