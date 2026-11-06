#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# M0: pull a Samsung AP tar apart into the pieces this port needs.
#
# Produces, under --out (default evidence/raw):
#   boot.img, recovery.img, dtbo.img, vbmeta.img      (super.img with --with-super)
#   boot/            unpacked kernel, ramdisk, dtb, header.txt, mkbootimg_args
#   dtbo/entry.N     each overlay blob from the dtbo partition
#   dts/*.dts        decompiled device trees
#   vbmeta.info      avbtool's view of the vbmeta partition
#   SHA256SUMS
#
# boot/mkbootimg_args is the important one: tools/bootimg.sh reuses the stock
# header verbatim (board string, offsets, page size) instead of guessing it.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: extract-firmware.sh [--out DIR] [--with-super] AP.tar.md5

The AP tar is the AP_*.tar.md5 from a full stock firmware package.
--with-super also pulls super.img, which is 12 GB of Android and usually not wanted.
EOF
}

AP=""
OUT="$REPO_ROOT/evidence/raw"
WITH_SUPER=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) OUT=${2:?--out needs a directory}; shift 2 ;;
    --with-super) WITH_SUPER=1; shift ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) AP=$1; shift ;;
  esac
done

[ -n "$AP" ] || { usage >&2; exit 1; }
[ -f "$AP" ] || die "no such file: $AP"
need tar lz4 dtc unpack_bootimg mkdtboimg sha256sum

mkdir -p "$OUT"
log "reading $AP"
members=$(tar -tf "$AP")

wanted=(boot.img recovery.img dtbo.img vbmeta.img vendor_boot.img vbmeta_system.img)
if [ "$WITH_SUPER" = 1 ]; then wanted+=(super.img); fi

# One tar pass for everything: the AP tar is ~10 GB and a pass per member is painful.
to_extract=()
for base in "${wanted[@]}"; do
  found=""
  for cand in "$base" "$base.lz4" "$base.md5" "$base.lz4.md5"; do
    if printf '%s\n' "$members" | grep -Fqx -- "$cand"; then found=$cand; break; fi
  done
  if [ -n "$found" ]; then
    to_extract+=("$found")
  else
    warn "$base is not in this archive"
  fi
done
[ "${#to_extract[@]}" -gt 0 ] || die "nothing to extract; is this an AP tar?"

log "extracting ${#to_extract[@]} member(s) in one pass"
tar -xf "$AP" -C "$OUT" -- "${to_extract[@]}"

for m in "${to_extract[@]}"; do
  case "$m" in
    *.lz4)
      base=${m%.lz4}
      log "decompressing $m"
      lz4 -d -f "$OUT/$m" "$OUT/$base" >/dev/null
      rm -f "$OUT/$m"
      ;;
  esac
done

[ -f "$OUT/boot.img" ] || die "no boot.img came out of $AP; is this an AP tar?"

log "unpacking boot.img"
rm -rf "${OUT:?}/boot"
mkdir -p "$OUT/boot" "$OUT/dts"
unpack_bootimg --boot_img "$OUT/boot.img" --out "$OUT/boot" | tee "$OUT/boot/header.txt"
unpack_bootimg --boot_img "$OUT/boot.img" --format mkbootimg > "$OUT/boot/mkbootimg_args"

if [ -f "$OUT/vendor_boot.img" ]; then
  log "unpacking vendor_boot.img"
  rm -rf "${OUT:?}/vendor_boot"
  mkdir -p "$OUT/vendor_boot"
  unpack_bootimg --boot_img "$OUT/vendor_boot.img" --out "$OUT/vendor_boot" \
    | tee "$OUT/vendor_boot/header.txt"
  unpack_bootimg --boot_img "$OUT/vendor_boot.img" --format mkbootimg \
    > "$OUT/vendor_boot/mkbootimg_args"
  if [ -f "$OUT/vendor_boot/dtb" ]; then
    dtc -I dtb -O dts -o "$OUT/dts/vendor_boot.dts" "$OUT/vendor_boot/dtb" 2>/dev/null || \
      warn "could not decompile vendor_boot's dtb"
  fi
fi

if [ -f "$OUT/boot/dtb" ]; then
  dtc -I dtb -O dts -o "$OUT/dts/boot.dts" "$OUT/boot/dtb" 2>/dev/null || {
    warn "could not decompile boot.img's dtb"
  }
fi

if [ -f "$OUT/dtbo.img" ]; then
  log "splitting dtbo.img"
  mkdir -p "$OUT/dtbo"
  mkdtboimg dump "$OUT/dtbo.img" --dtb "$OUT/dtbo/entry" > "$OUT/dtbo/index.txt"
  for blob in "$OUT"/dtbo/entry.*; do
    case "$blob" in *.dts) continue ;; esac
    dtc -I dtb -O dts -o "$blob.dts" "$blob" 2>/dev/null || warn "could not decompile $blob"
  done
fi

if [ -f "$OUT/vbmeta.img" ] && command -v avbtool >/dev/null 2>&1; then
  avbtool info_image --image "$OUT/vbmeta.img" > "$OUT/vbmeta.info" 2>/dev/null || \
    warn "avbtool could not read vbmeta.img"
fi

( cd "$OUT" && find . -maxdepth 2 -type f ! -name SHA256SUMS -print0 | sort -z | \
    xargs -0 sha256sum ) > "$OUT/SHA256SUMS"

echo
log "panel candidates in the stock device trees:"
grep -h 'qcom,mdss-dsi-panel-name' "$OUT"/dtbo/*.dts 2>/dev/null \
  | sed 's/.*= *//' | sort -u | sed 's/^/    /' || warn "none found"

cat <<EOF

Next:
  $OUT/boot/mkbootimg_args  stock boot header arguments, reused by tools/bootimg.sh
  $OUT/dts                 decompiled device trees; this is the source for the board DTS
EOF
