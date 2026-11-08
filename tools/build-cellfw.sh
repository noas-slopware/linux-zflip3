#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the static aarch64 Qualcomm modem userspace: qrtr (libqrtr, qrtr-ns,
# qrtr-lookup, qrtr-cfg), rmtfs and tqftpserv, plus their units, into out/cellfw.
#
# These are the three daemons the modem needs on the AP side: rmtfs serves the
# modem's remotefs (EFS) partition over QRTR, tqftpserv serves the carrier
# configs out of modem_pr, and qrtr-ns is the nameserver. Everything is linked
# statically so the binaries drop onto the phone's rootfs as plain files.
#
# Pins are here rather than in sources.lock because this is a delivery build,
# not something the kernel/rootfs images depend on.
#
# Two things make a byte-for-byte rebuild less obvious than it looks:
#
#  * qrtr-ns no longer exists at the pinned qrtr commit. Upstream dropped it in
#    3edda0e ("ns: Drop qrtr-ns", PR #37) because the kernel grew a nameserver
#    in 5.7; src/ns.c last exists at b51ffaf (tag v1.2). libqrtr's sources are
#    identical in both trees, so qrtr-ns is built from b51ffaf and only
#    lib/meson.build is taken from the pinned commit (v1.2 forces
#    shared_library(), which cannot satisfy a -static link).
#  * Several inputs carry their build paths into the binary: rmtfs (upstream
#    adds -g), libudev-zero (meson's default buildtype is debug), liblzma
#    (autotools' default CFLAGS are -g -O2), and libzstd's divsufsort.o puts
#    __FILE__ in .rodata. ld hashes the pre-strip image into the BuildID note,
#    so a relocated build changes exactly those 20 bytes. FILEMAP below rewrites
#    the paths back to the ones the delivered MANIFEST hashes were produced
#    under; without it only the BuildID note differs.
#
# Requirements: aarch64-linux-gnu-gcc (16.2.0 produced the pinned hashes), meson,
# ninja, pkg-config, make, git, curl, file, binutils. Nothing needs a device.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: build-cellfw.sh [--cross PREFIX] [--jobs N] [--out DIR] [--fat IMAGE]
                       [--clean] [--no-verify]

  --cross PREFIX  cross compiler prefix (default: aarch64-linux-gnu-)
  --jobs N        parallel make/configure (default: nproc)
  --out DIR       output tree (default: out/cellfw)
  --fat IMAGE     also inventory ::/image/modem_pr/ and ::/image/lahaina/ from
                  the stock CP modem FAT (modem.bin inside CP_*.tar.md5) into
                  the manifest. Skipped when not given.
  --clean         drop .cache/cellfw-src and .cache/cellfw-build first
  --no-verify     build but do not compare against the pinned sha256 list

Output: out/cellfw/usr/bin/{rmtfs,qrtr-ns,qrtr-lookup,qrtr-cfg,tqftpserv}
        out/cellfw/usr/lib/systemd/system/*.service
        out/cellfw/usr/lib/udev/rules.d/rmtfs.rules
        out/cellfw/usr/libexec/tqftpserv/populate-readwrite.sh
        out/cellfw/MANIFEST.txt
EOF
}

# ---------------------------------------------------------------------------
# Pins
# ---------------------------------------------------------------------------
QRTR_GIT=https://github.com/linux-msm/qrtr.git
QRTR_COMMIT=29e36ae164389580a0f8ea7a7fdb728140ae978d
QRTR_NS_COMMIT=b51ffaf22707b6000ecfb894c5b750f3bb7843b2   # v1.2, last with src/ns.c
RMTFS_GIT=https://github.com/linux-msm/rmtfs.git
RMTFS_COMMIT=b30a3eb38f9af283f18dbd3c7755653efc52c094
TQFTPSERV_GIT=https://github.com/linux-msm/tqftpserv.git
TQFTPSERV_COMMIT=eb4b9a04ff92d2753ededf32cc3b6ed287f6e29b
LIBUDEV_ZERO_GIT=https://github.com/illiliti/libudev-zero.git
LIBUDEV_ZERO_COMMIT=8f1d3d0624496f1c4967f18d6afaddbd552d8bce   # 1.0.4, stands in for libudev
XZ_VERSION=5.8.1
XZ_URL=https://tukaani.org/xz/xz-$XZ_VERSION.tar.gz
XZ_SHA256=507825b599356c10dca1cd720c9d0d0c9d5400b9de300af00e4d1ea150795543
ZSTD_GIT=https://github.com/facebook/zstd.git
ZSTD_COMMIT=f8745da6ff1ad1e7bab384bd1f9d742439278e99           # v1.5.7

# The absolute paths the delivered binaries were built under. Only FILEMAP uses
# them, to rewrite paths back into the output; nothing is written there.
PIN_SRC_ROOT=/tmp/opencode/cellbuild
PIN_SYSROOT=/tmp/opencode/cellsysroot

# sha256 of the delivered binaries, in "name hash" form.
EXPECTED="qrtr-cfg 39b13b3917515800d28779eb570d1c473fa890005b5f05725ec318cadb3abb56
qrtr-lookup 394b67970e7db3195898cb764688758dc03fc554cb5bb3e092d2dd9e306ea2a2
qrtr-ns ee123f963adcd515a65e33f5ced42903e4cd95b71fa7e1c4887713c0a81ae758
rmtfs 47c7ecaaf3b4ab2dde1e0e7abe45775aa3aa3e56431bec239c1747c345740619
tqftpserv e2fa53f5e4d0025157b8ddd738863a747af67fbaabd6ce050f568bb66c43d2d5"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
CROSS=aarch64-linux-gnu-
JOBS=$(nproc)
OUT="$REPO_ROOT/out/cellfw"
FAT=""
CLEAN=0
VERIFY=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cross) CROSS=${2:?}; shift 2 ;;
    --jobs) JOBS=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --fat) FAT=${2:?}; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    --no-verify) VERIFY=0; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

need git curl tar make meson ninja pkg-config sha256sum file printf \
     "${CROSS}gcc" "${CROSS}ar" "${CROSS}strip" "${CROSS}readelf"
[ -f "$("${CROSS}gcc" -print-file-name=libc.a)" ] \
  || die "${CROSS}gcc has no static libc.a; static linking cannot work"
GCC_VERSION=$("${CROSS}gcc" -dumpversion)
LD_VERSION=$("${CROSS}ld" --version 2>/dev/null | head -1 || echo unknown)
[ "$GCC_VERSION" = 16.2.0 ] \
  || warn "gcc $GCC_VERSION != 16.2.0: the pinned hashes were produced with 16.2.0"

SRC="$REPO_ROOT/.cache/cellfw-src"
BUILD="$REPO_ROOT/.cache/cellfw-build"
SYSROOT="$REPO_ROOT/.cache/cellfw-sysroot"
if [ "$CLEAN" = 1 ]; then
  log "cleaning $SRC, $BUILD and $SYSROOT"
  rm -rf "$SRC" "$BUILD" "$SYSROOT"
fi
mkdir -p "$SRC" "$BUILD"

CROSS_FILE="$BUILD/aarch64-cross.txt"

# The worktrees mirror the delivered layout (sources directly under the build
# root, meson dirs next to them as b-<name>), because meson records source
# paths relative to its build dir; libudev-zero is the one meson project with
# debug info, so its relative paths have to match too.
#
# Several inputs carry their build paths into the output: rmtfs (upstream adds
# -g), libudev-zero (meson's default buildtype is debug), liblzma (autotools
# default CFLAGS -g -O2), and libzstd's divsufsort.o embeds __FILE__. ld hashes
# the pre-strip image into the BuildID note, so a relocated build differs in
# exactly those 20 bytes. -ffile-prefix-map rewrites both DWARF and __FILE__
# back to the paths the pinned hashes were produced under.
FILEMAP="-ffile-prefix-map=$BUILD=$PIN_SRC_ROOT -ffile-prefix-map=$SYSROOT=$PIN_SYSROOT"

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
fetch_repo() { # NAME URL COMMIT
  local name=$1 url=$2 commit=$3 dir="$SRC/$1"
  if [ ! -d "$dir/.git" ]; then
    log "cloning $name"
    git clone -q --no-checkout --filter=blob:none "$url" "$dir"
  fi
  if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    log "fetching $name $commit"
    git -C "$dir" fetch -q origin "$commit" 2>/dev/null \
      || git -C "$dir" fetch -q origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'
  fi
  git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null \
    || die "$name: commit $commit is not in $url"
  git -C "$dir" rev-parse "$commit^{commit}"
}

export_tree() { # NAME COMMIT DEST
  local name=$1 commit=$2 dest=$3
  git -C "$SRC/$name" worktree prune
  [ -e "$dest" ] && rm -rf "$dest"
  mkdir -p "$(dirname -- "$dest")"
  git -C "$SRC/$name" worktree add -q --detach --force "$dest" "$commit"
}

log "resolving pinned sources"
fetch_repo qrtr "$QRTR_GIT" "$QRTR_COMMIT" >/dev/null
fetch_repo qrtr "$QRTR_GIT" "$QRTR_NS_COMMIT" >/dev/null
fetch_repo rmtfs "$RMTFS_GIT" "$RMTFS_COMMIT" >/dev/null
fetch_repo tqftpserv "$TQFTPSERV_GIT" "$TQFTPSERV_COMMIT" >/dev/null
fetch_repo libudev-zero "$LIBUDEV_ZERO_GIT" "$LIBUDEV_ZERO_COMMIT" >/dev/null
fetch_repo zstd "$ZSTD_GIT" "$ZSTD_COMMIT" >/dev/null

XZ_TARBALL="$SRC/xz-$XZ_VERSION.tar.gz"
if [ ! -f "$XZ_TARBALL" ]; then
  log "fetching xz $XZ_VERSION"
  curl -fsSL -o "$XZ_TARBALL.part" "$XZ_URL"
  mv "$XZ_TARBALL.part" "$XZ_TARBALL"
fi
echo "$XZ_SHA256  $XZ_TARBALL" | sha256sum -c --quiet - || die "checksum mismatch: $XZ_TARBALL"

log "exporting worktrees under $BUILD"
export_tree qrtr "$QRTR_COMMIT" "$BUILD/qrtr"
export_tree qrtr "$QRTR_NS_COMMIT" "$BUILD/qrtr-ns-src"
export_tree rmtfs "$RMTFS_COMMIT" "$BUILD/rmtfs"
export_tree tqftpserv "$TQFTPSERV_COMMIT" "$BUILD/tqftpserv"
export_tree libudev-zero "$LIBUDEV_ZERO_COMMIT" "$BUILD/libudev-zero"
export_tree zstd "$ZSTD_COMMIT" "$BUILD/zstd"
rm -rf "$BUILD/xz-$XZ_VERSION"
tar -xf "$XZ_TARBALL" -C "$BUILD"

# qrtr-ns needs the pinned tree's lib/meson.build (v1.2 forces a shared libqrtr).
cp "$BUILD/qrtr/lib/meson.build" "$BUILD/qrtr-ns-src/lib/meson.build"
cmp -s "$BUILD/qrtr/lib/qrtr.c" "$BUILD/qrtr-ns-src/lib/qrtr.c" \
  || die "libqrtr sources differ between $QRTR_COMMIT and $QRTR_NS_COMMIT"

cat > "$CROSS_FILE" <<EOF
[binaries]
c = '${CROSS}gcc'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkgconfig = 'pkg-config'
exe_wrapper = ''

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

# ---------------------------------------------------------------------------
# 1. qrtr -> sysroot (libqrtr.a, qrtr.pc, qrtr-lookup, qrtr-cfg)
# ---------------------------------------------------------------------------
log "building qrtr (libqrtr, qrtr-lookup, qrtr-cfg)"
rm -rf "$SYSROOT" "$BUILD/b-qrtr"
mkdir -p "$SYSROOT"
CFLAGS="-O2 -static $FILEMAP" LDFLAGS="-static" \
  meson setup "$BUILD/b-qrtr" "$BUILD/qrtr" \
    --cross-file "$CROSS_FILE" --default-library=static \
    --prefix="$SYSROOT" --unity=off >/dev/null
ninja -C "$BUILD/b-qrtr" >/dev/null
ninja -C "$BUILD/b-qrtr" install >/dev/null

# ---------------------------------------------------------------------------
# 2. qrtr-ns (from v1.2, links its own copy of the same libqrtr sources)
# ---------------------------------------------------------------------------
log "building qrtr-ns"
rm -rf "$BUILD/b-qrtr-ns"
CFLAGS="-O2 -static $FILEMAP" LDFLAGS="-static" \
  meson setup "$BUILD/b-qrtr-ns" "$BUILD/qrtr-ns-src" \
    --cross-file "$CROSS_FILE" --default-library=static \
    -Dqrtr-ns=enabled -Dsystemd-service=disabled --prefix=/usr >/dev/null
ninja -C "$BUILD/b-qrtr-ns" >/dev/null

# ---------------------------------------------------------------------------
# 3. libudev / liblzma / libzstd into the sysroot
# ---------------------------------------------------------------------------
log "building libudev-zero (for rmtfs)"
rm -rf "$BUILD/b-libudev"
# libudev-zero bakes its configured usb.ids path into udev.c.o (a string
# literal, so -ffile-prefix-map does not touch it); pin it to the sysroot the
# delivered bytes were built against.
CFLAGS="-O2 -static $FILEMAP" LDFLAGS="-static" \
  meson setup "$BUILD/b-libudev" "$BUILD/libudev-zero" \
    --cross-file "$CROSS_FILE" --default-library=static \
    -Dusb-ids-path="$PIN_SYSROOT/share/hwdata/usb.ids" \
    --prefix="$SYSROOT" >/dev/null
ninja -C "$BUILD/b-libudev" >/dev/null
ninja -C "$BUILD/b-libudev" install >/dev/null

log "building liblzma (xz $XZ_VERSION)"
( cd "$BUILD/xz-$XZ_VERSION" \
    && CFLAGS="-g -O2 $FILEMAP" ./configure --host="${CROSS%-}" CC="${CROSS}gcc" \
         --prefix="$SYSROOT" --disable-shared --enable-static --disable-nls \
         --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
         --disable-scripts --disable-doc --disable-sandbox >/dev/null \
    && make -s -j"$JOBS" >/dev/null \
    && make -s install >/dev/null ) \
  || die "xz build failed"

log "building libzstd (zstd 1.5.7)"
make -s -C "$BUILD/zstd" -j"$JOBS" lib-release \
  CC="${CROSS}gcc" AR="${CROSS}ar" CFLAGS="-O2 -fPIC $FILEMAP" >/dev/null \
  || die "zstd build failed"
install -m644 "$BUILD/zstd/lib/libzstd.a" "$SYSROOT/lib/"
install -m644 "$BUILD/zstd/lib/zstd.h" "$BUILD/zstd/lib/zdict.h" \
              "$BUILD/zstd/lib/zstd_errors.h" "$SYSROOT/include/"
sed -e 's|@PREFIX@|'"$SYSROOT"'|' -e 's|@EXEC_PREFIX@|'"$SYSROOT"'|' \
    -e 's|@LIBDIR@|'"$SYSROOT"'/lib|' -e 's|@INCLUDEDIR@|'"$SYSROOT"'/include|' \
    -e 's|@VERSION@|1.5.7|' -e 's|@LIBVER@|1.5.7|' \
    -e 's| @LIBS_MT@||' -e 's| @LIBS_PRIVATE@||' \
    "$BUILD/zstd/lib/libzstd.pc.in" > "$SYSROOT/lib/pkgconfig/libzstd.pc"

export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig"
log "sysroot: $(pkg-config --modversion qrtr libudev liblzma libzstd | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 4. rmtfs
# ---------------------------------------------------------------------------
log "building rmtfs"
# The Makefile would regenerate qmi_rmtfs.c with qmic (not packaged anywhere);
# the generated file is checked in, so make sure it looks newer than the .qmi.
touch "$BUILD/rmtfs/qmi_rmtfs.c"
RMTFS_CFLAGS="-O2 -Wall -g -I$SYSROOT/include $FILEMAP"
RMTFS_LDFLAGS="-static -L$SYSROOT/lib -lqrtr -ludev -lpthread"
make -s -C "$BUILD/rmtfs" CC="${CROSS}gcc" \
     CFLAGS="$RMTFS_CFLAGS" LDFLAGS="$RMTFS_LDFLAGS" rmtfs >/dev/null
make -s -C "$BUILD/rmtfs" prefix=/usr rmtfs.service rmtfs-dir.service >/dev/null

# ---------------------------------------------------------------------------
# 5. tqftpserv
# ---------------------------------------------------------------------------
log "building tqftpserv"
rm -rf "$BUILD/b-tqftpserv"
CFLAGS="-O2 -static $FILEMAP" LDFLAGS="-static" \
  meson setup "$BUILD/b-tqftpserv" "$BUILD/tqftpserv" \
    --cross-file "$CROSS_FILE" \
    -Dsystemd-unit-prefix=/usr/lib/systemd/system --prefix=/usr >/dev/null
ninja -C "$BUILD/b-tqftpserv" >/dev/null

# ---------------------------------------------------------------------------
# Assemble out/cellfw
# ---------------------------------------------------------------------------
log "assembling $OUT"
rm -rf "$OUT"
install -d "$OUT/usr/bin" "$OUT/usr/lib/systemd/system" \
           "$OUT/usr/lib/udev/rules.d" "$OUT/usr/libexec/tqftpserv"
install -m755 "$SYSROOT/bin/qrtr-lookup" "$SYSROOT/bin/qrtr-cfg" "$OUT/usr/bin/"
install -m755 "$BUILD/b-qrtr-ns/src/qrtr-ns" "$OUT/usr/bin/"
install -m755 "$BUILD/rmtfs/rmtfs" "$OUT/usr/bin/"
install -m755 "$BUILD/b-tqftpserv/tqftpserv" "$OUT/usr/bin/"
install -m644 "$BUILD/rmtfs/rmtfs.service" "$BUILD/rmtfs/rmtfs-dir.service" \
              "$OUT/usr/lib/systemd/system/"
install -m644 "$BUILD/rmtfs/rmtfs.rules" "$OUT/usr/lib/udev/rules.d/"
install -m644 "$BUILD/b-tqftpserv/tqftpserv.service" \
              "$BUILD/b-tqftpserv/tqftpserv-populate-readwrite.service" \
              "$OUT/usr/lib/systemd/system/"
install -m755 "$BUILD/tqftpserv/populate-readwrite.sh" "$OUT/usr/libexec/tqftpserv/"
sed 's+@prefix@+/usr+g' "$BUILD/qrtr-ns-src/qrtr-ns.service.in" \
  > "$OUT/usr/lib/systemd/system/qrtr-ns.service"
chmod 644 "$OUT/usr/lib/systemd/system/qrtr-ns.service"

for b in "$OUT"/usr/bin/*; do "${CROSS}strip" "$b"; done

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
if [ "$VERIFY" = 1 ]; then
  log "verifying against the pinned sha256s"
  failed=0
  printf '  %-12s %10s  %-64s %s\n' file bytes sha256 result >&2
  while read -r name want; do
    f="$OUT/usr/bin/$name"
    [ -f "$f" ] || die "missing $f"
    have=$(sha256sum "$f" | cut -d' ' -f1)
    size=$(stat -c%s "$f")
    if [ "$have" = "$want" ]; then
      res=OK
    else
      res=MISMATCH; failed=1
    fi
    printf '  %-12s %10d  %s %s\n' "$name" "$size" "$have" "$res" >&2
    # static check (readelf exits 0 and says so for a static executable)
    dyn=$("${CROSS}readelf" -d "$f" 2>&1 || true)
    case "$dyn" in
      *"no dynamic section"*) ;;
      *) printf '  %-12s not static: %s\n' "$name" "$dyn" >&2; failed=1 ;;
    esac
  done <<< "$EXPECTED"
  [ "$failed" = 0 ] || die "build does not reproduce the pinned binaries (see above)"
  log "all pinned hashes reproduced"
else
  warn "verification skipped (--no-verify)"
  for b in "$OUT"/usr/bin/*; do sha256sum "$b" >&2; done
fi

# ---------------------------------------------------------------------------
# MANIFEST
# ---------------------------------------------------------------------------
log "writing MANIFEST.txt"
M="$OUT/MANIFEST.txt"
{
cat <<EOF
CELLFW - Qualcomm modem userspace for the Galaxy Z Flip3 (SM-F711N / SM8350)
Regenerated by tools/build-cellfw.sh on $(date -u '+%Y-%m-%d %H:%M UTC').

TARGET
  aarch64-linux-gnu, glibc, fully static.
  Toolchain : ${CROSS}gcc $GCC_VERSION ($LD_VERSION), meson $(meson --version), ninja $(ninja --version)
  Sysroot   : .cache/cellfw-sysroot (libqrtr, libudev, liblzma, libzstd)
  Cross file: \$BUILD/aarch64-cross.txt (host_machine aarch64/linux, needs_exe_wrapper)
  Build root: .cache/cellfw-build, sources from .cache/cellfw-src (pins below).
  Binaries are stripped with ${CROSS}strip (--strip-all) after the link, so the
  sizes and hashes below are the delivered files. Nothing is run: verification
  is file/readelf/sha256 only.

================================================================================
1. SOURCES AND COMMITS
================================================================================

qrtr        $QRTR_GIT
            $QRTR_COMMIT
            -> libqrtr.a, qrtr-lookup, qrtr-cfg

qrtr-ns     $QRTR_GIT (same repo, older revision)
            $QRTR_NS_COMMIT  (tag v1.2, last commit with src/ns.c)
            -> qrtr-ns, qrtr-ns.service
            qrtr-ns was dropped upstream in 3edda0e "ns: Drop qrtr-ns" (PR #37)
            because the kernel has an in-kernel QRTR nameserver since 5.7, so
            the pinned commit has no src/ns.c. libqrtr sources are identical in
            both trees; only lib/meson.build is taken from the pinned commit
            (v1.2 calls shared_library(), which cannot be linked statically).

rmtfs       $RMTFS_GIT
            $RMTFS_COMMIT
            -> rmtfs, rmtfs.service, rmtfs-dir.service, rmtfs.rules

tqftpserv   $TQFTPSERV_GIT
            $TQFTPSERV_COMMIT  (1.1.1)
            -> tqftpserv, tqftpserv.service, tqftpserv-populate-readwrite.service,
               populate-readwrite.sh

Dependencies built into the sysroot (none installed on the host):
  libudev  libudev-zero $LIBUDEV_ZERO_COMMIT (1.0.4) -> static libudev.a
  liblzma  xz $XZ_VERSION, $XZ_URL
           sha256 $XZ_SHA256 -> static liblzma.a
  libzstd  zstd $ZSTD_COMMIT (v1.5.7) -> static libzstd.a
  liblzma/libzstd give tqftpserv HAVE_XZ / HAVE_ZSTD, so it can serve
  .xz/.zst compressed modem_pr files as well as raw ones.

================================================================================
2. BINARIES (out/cellfw/usr/bin)
================================================================================
EOF
printf '  %-12s %10s  %s  %s\n' file bytes sha256 type
printf '  %-12s %10s  %s  %s\n' ------------ ---------- ---------------------------------------------------------------- ------
while read -r name want; do
  f="$OUT/usr/bin/$name"
  printf '  %-12s %10d  %s  static\n' "$name" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
done <<< "$EXPECTED"
printf '\n  total %d bytes\n\n' "$(find "$OUT/usr/bin" -type f -printf '%s\n' | awk '{s+=$1} END {print s}')"
echo "  file(1) output, verbatim:"
for f in "$OUT"/usr/bin/*; do printf '    usr/bin/%s: %s\n' "$(basename "$f")" "$(file -b "$f")"; done
cat <<'EOF'

  Every one of them: ELF 64-bit LSB executable, ARM aarch64, version 1
  (GNU/Linux), statically linked, stripped, for GNU/Linux 3.7.0.
  readelf -d on each prints "There is no dynamic section in this file": no
  DT_NEEDED, no PT_INTERP, no runtime .so dependencies.

================================================================================
3. SYSTEMD UNIT / UDEV FILES
================================================================================
Copied with their exact post-configuration content: the packaged .in files with
only the upstream placeholder substitution applied (RMTFS_PATH, RMTFS_EFS_PATH,
@prefix@ -> /usr).

  qrtr-ns.service                        qrtr @ v1.2: qrtr-ns.service.in
                                         ExecStart=/usr/bin/qrtr-ns -f 1
  rmtfs.service                          rmtfs: rmtfs.service.in
                                         RMTFS_PATH -> /usr/bin, RMTFS_EFS_PATH -> /var/lib/rmtfs
  rmtfs-dir.service                      rmtfs: rmtfs-dir.service.in  (-s -o /var/lib/rmtfs)
  rmtfs.rules                            rmtfs: rmtfs.rules verbatim; a udev rule, so it
                                         lives in usr/lib/udev/rules.d/
  tqftpserv.service                      tqftpserv: tqftpserv.service.in
  tqftpserv-populate-readwrite.service   tqftpserv: tqftpserv-populate-readwrite.service.in
  usr/libexec/tqftpserv/populate-readwrite.sh
                                         tqftpserv: installed verbatim (ExecStart target)

  rmtfs.service carries ConditionPathExists=/dev/qcom_rmtfs_mem1 and rmtfs.rules
  re-triggers it on udev add of qcom_rmtfs_mem*, so the unit only needs
  /dev/qcom_rmtfs_mem1 to exist; if the DTS only brings up mem0 that line has to
  be relaxed. qrtr-ns.service is redundant with CONFIG_QRTR_NS (the daemon goes
  dormant when a nameserver already exists), which is why shipping it is
  harmless. tqftpserv.service has StateDirectory=tqftpserv ->
  /var/lib/tqftpserv, where the modem's readwrite files get served from;
  tqftpserv-populate-readwrite.service Requires= partlabel-persist.device and
  copies persist:/rfs/msm/mpss/* there, so it does nothing if the phone's GPT
  has no partition labelled "persist".

================================================================================
4. EXACT BUILD COMMANDS
================================================================================

BUILD below stands for the absolute build root (.cache/cellfw-build), SYSROOT
for .cache/cellfw-sysroot, and FILEMAP for the -ffile-prefix-map list that
keeps build paths out of the binaries (section 5.5).
EOF
cat <<EOF
Cross file \$BUILD/aarch64-cross.txt:
EOF
sed 's/^/  /' "$CROSS_FILE"
cat <<EOF

1) qrtr (libqrtr.a, qrtr.pc, qrtr-lookup, qrtr-cfg into the sysroot)
  CFLAGS="-O2 -static" LDFLAGS="-static" \\
  meson setup \$BUILD/b-qrtr \$BUILD/qrtr --cross-file \$BUILD/aarch64-cross.txt \\
        --default-library=static --prefix=\$SYSROOT --unity=off
  ninja -C \$BUILD/b-qrtr && ninja -C \$BUILD/b-qrtr install

2) qrtr-ns (source from v1.2, its lib/meson.build replaced with the pinned one)
  cp \$BUILD/qrtr/lib/meson.build \$BUILD/qrtr-ns-src/lib/meson.build
  CFLAGS="-O2 -static" LDFLAGS="-static" \\
  meson setup \$BUILD/b-qrtr-ns \$BUILD/qrtr-ns-src --cross-file \$BUILD/aarch64-cross.txt \\
        --default-library=static -Dqrtr-ns=enabled -Dsystemd-service=disabled --prefix=/usr
  ninja -C \$BUILD/b-qrtr-ns

3) libudev-zero
  CFLAGS="-O2 -static $FILEMAP" LDFLAGS="-static" \\
  meson setup \$BUILD/b-libudev \$BUILD/libudev-zero --cross-file \$BUILD/aarch64-cross.txt \\
        --default-library=static -Dusb-ids-path=\$PIN_SYSROOT/share/hwdata/usb.ids \\
        --prefix=\$SYSROOT
  ninja -C \$BUILD/b-libudev && ninja -C \$BUILD/b-libudev install

4) liblzma and libzstd
  (cd \$BUILD/xz-$XZ_VERSION && CFLAGS="-g -O2 $FILEMAP" ./configure --host=${CROSS%-} \\
        CC=${CROSS}gcc --prefix=\$SYSROOT --disable-shared --enable-static \\
        --disable-nls --disable-xz --disable-xzdec --disable-lzmadec \\
        --disable-lzmainfo --disable-scripts --disable-doc --disable-sandbox \\
     && make -j$JOBS && make install)
  make -C \$BUILD/zstd -j$JOBS lib-release CC=${CROSS}gcc AR=${CROSS}ar CFLAGS="-O2 -fPIC $FILEMAP"
  # then libzstd.a, zstd.h/zdict.h/zstd_errors.h and a libzstd.pc generated from
  # libzstd.pc.in (placeholders expanded, @LIBS_MT@/@LIBS_PRIVATE@ dropped) are
  # copied into the sysroot

5) rmtfs
  touch \$BUILD/rmtfs/qmi_rmtfs.c      # else make wants qmic to regenerate it
  make -C \$BUILD/rmtfs CC=${CROSS}gcc \\
       CFLAGS="$RMTFS_CFLAGS" \\
       LDFLAGS="$RMTFS_LDFLAGS" rmtfs
  make -C \$BUILD/rmtfs prefix=/usr rmtfs.service rmtfs-dir.service

6) tqftpserv
  PKG_CONFIG_LIBDIR=\$SYSROOT/lib/pkgconfig \\
  CFLAGS="-O2 -static" LDFLAGS="-static" \\
  meson setup \$BUILD/b-tqftpserv \$BUILD/tqftpserv --cross-file \$BUILD/aarch64-cross.txt \\
        -Dsystemd-unit-prefix=/usr/lib/systemd/system --prefix=/usr
  ninja -C \$BUILD/b-tqftpserv

7) delivery
  install the binaries into usr/bin, ${CROSS}strip each of them, then assemble
  the units. Verification: sha256 vs the pinned list below.

Pinned sha256 of the delivered binaries:
EOF
while read -r name want; do printf '  %s  usr/bin/%s\n' "$want" "$name"; done <<< "$EXPECTED"
cat <<'EOF'

================================================================================
5. ADJUSTMENTS AND FINDINGS
================================================================================

5.1 qrtr-ns is not in the pinned qrtr commit (see section 1). Built from v1.2,
    with v1.2's lib/meson.build (shared_library()) replaced by the pinned
    commit's (library()). Without that, -static fails with
    "hidden symbol __fini_array_end isn't defined" and undefined
    __preinit_array_start/__init_array_start, because the link pulls in a
    libqrtr.so next to the static libc. The script asserts that lib/*.c is
    identical in both trees before copying the file.

5.2 rmtfs has no pkg-config support. Its Makefile just does
    LDFLAGS += -lqrtr -ludev -lpthread, so the sysroot is passed explicitly
    with -I/-L; a .pc file alone is not enough. (Libraries in LDFLAGS is
    upstream's quirk; it works because the link line ends with $(LDFLAGS).)

5.3 qmic is not needed. rmtfs ships the generated qmi_rmtfs.c, but a fresh
    checkout/worktree can leave qmi_rmtfs.qmi with a newer mtime, which makes
    the "%.c: %.qmi" rule run qmic and fail with "qmic: command not found".
    The script touches qmi_rmtfs.c first.

5.4 libudev is libudev-zero. No aarch64 libudev exists on the build host.
    rmtfs uses five symbols only, all in sharedmem.c, all for "given the
    /dev/qcom_rmtfs_memN char device, read sysfs attributes": udev_new,
    udev_unref, udev_device_new_from_devnum, udev_device_get_sysattr_value,
    udev_device_unref. libudev-zero implements devnum lookup as
    /sys/dev/char/<maj>:<min> plus a read of <syspath>/<attr>, which is exactly
    what rmtfs does with it. (Alternative: build systemd's libudev, which drags
    in most of libbasic.)

5.5 Reproducibility. ld hashes the pre-strip image (debug info included) into
    the BuildID note, and three inputs carry their build path into that image:
    rmtfs (upstream Makefile adds -g, and -I brings the sysroot path in),
    libudev-zero (meson's default buildtype is debug, so -g), liblzma
    (autotools' default CFLAGS are -g -O2), and libzstd's divsufsort.o has
    __FILE__ in .rodata. Building in a different directory therefore changes
    exactly those 20 bytes of .note.gnu.build-id and nothing else (same size,
    same section headers). The script passes -ffile-prefix-map (covers DWARF
    and __FILE__) from its own build root back to the paths the pinned hashes
    were produced under: PIN_SRC_ROOT=/tmp/opencode/cellbuild and
    PIN_SYSROOT=/tmp/opencode/cellsysroot. Nothing is written there; if those
    constants are changed, the hashes change.

5.6 tqftpserv unit dir: meson finds systemdsystemunitdir through the systemd
    .pc file, which does not exist for a cross build, so
    -Dsystemd-unit-prefix=/usr/lib/systemd/system is passed. Without it meson
    emits no unit files at all.

5.7 Sizes are static-glibc dominated. qrtr-cfg is the least essential binary
    (it only writes /etc/qrtr/interfaces.conf entries); qrtr-lookup is the tool
    for checking that the modem's services registered.

5.8 Nothing in these projects uses NSS or dlopen, which is why the static glibc
    link works: no getaddrinfo, getpw*, initgroups or dlopen anywhere in the
    three source trees.

5.9 libudev-zero compiles its usb.ids path in as a string literal (meson option
    usb-ids-path, default prefix/datadir/hwdata/usb.ids), so it shows up in
    rmtfs's bytes. -ffile-prefix-map does not rewrite string literals, hence
    -Dusb-ids-path is pinned to the delivered sysroot
    (PIN_SYSROOT/share/hwdata/usb.ids). This is the only thing in rmtfs that a
    relocated sysroot would otherwise change besides the BuildID.

================================================================================
6. STOCK MODEM FIRMWARE FAT
================================================================================
EOF
if [ -n "$FAT" ]; then
  [ -f "$FAT" ] || die "no such firmware image: $FAT"
  command -v mdir >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1 \
    || die "--fat needs mtools (mdir, mcopy)"
  W=$(mktemp -d "$BUILD/fat.XXXXXX")
  trap 'rm -rf "$W"' EXIT
  for d in modem_pr lahaina; do
    mcopy -n -i "$FAT" -s "::/image/$d/" "$W/"
    got=$(find "$W/$d" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
    # last "N files ... bytes" line in the recursive listing is the dir total
    want=$(mdir -i "$FAT" -/ "::/image/$d/" | grep -E '[0-9]+ files.*bytes' | tail -1 \
           | sed 's/.*files//; s/[^0-9]//g')
    [ "$got" = "$want" ] || die "$d: mcopy total $got != mdir total $want"
  done
  echo "Image: $(basename -- "$FAT"), $(stat -c%s "$FAT") bytes, FAT (mtools)."
  echo "Entries are 8.3 short names plus long names; names below are the long ones."
  echo "Byte total per directory was cross-checked against mdir -/."
  echo ""
  for d in modem_pr lahaina; do
    n=$(find "$W/$d" -type f | wc -l)
    printf '::/image/%s/  %d file%s, %s bytes\n' "$d" "$n" \
      "$([ "$n" = 1 ] || echo s)" \
      "$(find "$W/$d" -type f -printf '%s\n' | awk '{s+=$1} END {print s}')"
  done
  echo ""
  echo "modem_pr is the tree tqftpserv serves: mcfg/configs/{mcfg_hw,mcfg_sw} are"
  echo "the carrier configs the modem's MCFG loader picks from (mbn_sw.txt lists"
  echo "all operators, oem_sw.txt the ones this CSC defaults to), and so/ holds"
  echo "the <mcfg-id>_<0a|0c|ff> blobs it requests afterwards."
  echo ""
  echo "Full listing, byte size then path (relative to ::/image/):"
  for d in modem_pr lahaina; do
    ( cd "$W" && find "$d" -type f | sort | while read -r f; do
        printf '%10d  %s\n' "$(stat -c%s "$f")" "$f"
      done )
  done
  echo ""
  echo "Not extracted (the big modem image): modem.b* segments, modem.mdt, modemr.jsn,"
  echo "::/verinfo/."
else
  echo "Not regenerated: pass --fat <CP_*.tar.md5-extracted modem.bin> to inventory"
  echo "::/image/modem_pr/ (carrier configs served by tqftpserv) and"
  echo "::/image/lahaina/ (qdsp6m.qdb, the QDSP6M debug database) here."
fi
cat <<'EOF'

================================================================================
7. WHAT IS IN out/cellfw
================================================================================
EOF
( cd "$OUT" && find . -type f | sed 's|^\./||' | sort | sed 's/^/  /' )
cat <<'EOF'

Install on the phone: usr/bin/* -> /usr/bin, usr/lib/systemd/system/* ->
/usr/lib/systemd/system, usr/lib/udev/rules.d/rmtfs.rules ->
/usr/lib/udev/rules.d, usr/libexec/tqftpserv/ -> /usr/libexec/tqftpserv; then
udevadm control --reload and systemctl daemon-reload.
EOF
} > "$M"

log "wrote $M"
find "$OUT" -type f -printf '  %P (%s bytes)\n' | sort >&2
