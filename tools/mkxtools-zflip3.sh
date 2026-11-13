#!/bin/bash
# SPDX-License-Identifier: MIT
# mkxtools-zflip3.sh: rebuild drzee's exact AArch64 toolchain (gcc, binutils, ccache, at whatever
# versions drzee's sync db has now) as x86_64 programs, for build-zflip3.sh's ZFLIP3_ACCEL=xgcc: inside
# the qemu-user builder they replace drzee's AArch64 binaries at the same paths and run natively (the
# kernel runs x86_64 ELF directly; only AArch64 ELF goes through binfmt_misc/qemu). Everything else in
# the container (make, cmake, ninja, moc, python, the libraries and headers, gcc's own crt files,
# libgcc, libstdc++ and include dirs) stays drzee's. Same source and configure line as drzee, so the
# same code comes out: the self-test at the end compiles and links C/C++ (LTO and not, -g) with
# drzee's gcc under qemu and with these, and requires byte-identical objects, libraries and executables.
#   mkxtools-zflip3.sh         -> $ZFLIP3_WORK/xtools (mounted read-only at /opt/zflip3-xtools)
# Nothing in here names a version. drzee's gcc/binutils/ccache/fakeroot versions come from the sync db.
# drzee does not publish the PKGBUILDs of its toolchain at those versions: its builder
# (github.com/solskogen/archlinux-aarch64-builder, bootstrap_toolchain.py) takes gcc from
# gitlab.archlinux.org/solskogen/gcc, branch experimental, and binutils from Arch's packaging (pkgctl
# repo clone), and builds them with local version bumps to newer commits of the release branches.
# So the PKGBUILDs here are those two at their current heads (their prepare() and binutils' configure
# flags), and the source commit is the one drzee's version names (…+g<12 hex>), resolved to the full
# hash through forge.sourceware.org; the checkout must then carry drzee's base version (and, for gcc,
# its DATESTAMP), and the gcc PKGBUILD's configure flags must be the ones drzee's gcc reports (gcc -v).
# The steps of prepare() are replayed (only sed one-liners and patches: anything else stops here).
# Neither PKGBUILD is provably the one drzee built from (the pkgbuild_sha256sum in its .BUILDINFO is
# of its locally bumped copy): the byte-identical self-test is what shows the result is the same.
# build-zflip3.sh reruns this whenever drzee's versions move (lib-zflip3.sh xtools_use).
# Differences from drzee's build that do not change output: host x86_64, C/C++/LTO only (gfortran & co.
# stay drzee's AArch64 binaries under qemu), no bootstrap/PGO/LTO of the compiler itself,
# no debuginfod lookups in objdump/readelf. lib/ has Arch's x86_64 glibc with its iconv modules in
# lib/gconv; its libc.so.6 has /usr/lib/gconv (drzee's AArch64 modules in the builder) replaced by
# /opt/zf3/gconv (same length, 14 bytes), which xtools-activate.sh links to lib/gconv. Two source
# patches make the cross tools keep native path logic: gcc without -DCROSS_DIRECTORY_STRUCTURE (same
# search dirs, include dirs, tool names as a native gcc, C++ headers in /usr/include/c++/<major>; the
# build system still treats it as a cross) and ld with genscripts.sh's NATIVE=yes (same SEARCH_DIRs,
# ld.so.conf/DT_RUNPATH lookups as a native ld). -march=native is unsupported (the host-CPU probe is
# only built into AArch64-hosted drivers); our packages must not use it anyway.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-zflip3.sh"
[ "$HOSTARCH" = x86_64 ] || { echo "only for x86_64 hosts" >&2; exit 1; }
xtools_lock
mkdir -p "$W/xsrc/pkgbuild"

# where drzee's builder takes the toolchain PKGBUILDs from (see above): repo and ref
GCC_PKG=(https://gitlab.archlinux.org/solskogen/gcc refs/heads/experimental)
BIN_PKG=(https://gitlab.archlinux.org/archlinux/packaging/packages/binutils HEAD)

# drzee's versions now: the tools are only used while they match (xtools-activate.sh)
fetch_sync > /dev/null
declare -A B
while read -r n v; do B[$n]=$v; done < <(drzee_versions)
gccv=${B[gcc]} binv=${B[binutils]} ccachev=${B[ccache]} fakerootv=${B[fakeroot]}
major=${gccv%%.*}
log "drzee: gcc $gccv, binutils $binv, ccache $ccachev, fakeroot $fakerootv"

# the PKGBUILDs at their current heads, read without running them: the simple assignments and
# source/sha256sums arrays are evaluated in a throwaway container; the result, zflip3.parsed, has
# "pkgbuild <url> <commit> <its own version>", "git <url> <commit> <dir>" (the commit drzee's version
# names), "file <name> <sha256>", "sed <expr> <path>", "patch <-Npn> <name>" (prepare(), in order),
# "configure <flags>" (build()'s configure call) and "confflags <flags>" (a _confflags array)
mapfile -t parsed < <(fetch_user bash -euo pipefail -c '
	while [ $# -gt 0 ]; do
		n=$1 v=$2 repo=$3 ref=$4; shift 4
		pc=$(git ls-remote "$repo.git" "$ref" | cut -f1)
		[ -n "$pc" ] || { echo "$n: no $ref in $repo" >&2; exit 1; }
		d=/w/xsrc/pkgbuild/$n-${v/:/-}-${pc:0:12}
		echo "${d#/w/xsrc/}/zflip3.parsed"	# (stdout: the parsed file, per package)
		[ -s "$d/zflip3.parsed" ] && continue
		rm -rf "$d.part"; mkdir -p "$d.part"; cd "$d.part"
		raw=$repo/-/raw/$pc
		curl -fsSL -o PKGBUILD "$raw/PKGBUILD"
		(	epoch= pkgver= pkgrel= _commit=
			eval "$(grep -E "^(epoch|pkgver|pkgrel|_commit|_tag)=[A-Za-z0-9_.+-]*$" PKGBUILD)"
			# the base version (epoch, upstream release) must be drzee'"'"'s; the commit is drzee'"'"'s
			want=${v%-*}; want=${want%%+*}; have=${epoch:+$epoch:}${pkgver%%+*}
			[ "$have" = "$want" ] || { echo "$n PKGBUILD at $repo $pc is $have, drzee $v" >&2; exit 1; }
			abbrev=${v##*+g}; abbrev=${abbrev%-*}
			[[ $abbrev =~ ^[0-9a-f]{12}$ ]] || { echo "$n $v names no commit" >&2; exit 1; }
			echo "pkgbuild $repo $pc ${epoch:+$epoch:}$pkgver-$pkgrel"
			eval "$(sed -n "/^source=(/,/)/p" PKGBUILD)"; eval "$(sed -n "/^sha256sums=(/,/)/p" PKGBUILD)"
			[ ${#source[@]} = ${#sha256sums[@]} ]
			srcdir_name=
			for i in "${!source[@]}"; do
				s=${source[$i]}; name=; case $s in *::*) name=${s%%::*}; s=${s#*::};; esac
				case $s in
					git+https://forge.sourceware.org/*"#commit="*) u=${s#git+}; u=${u%%#*}
						[ -n "$name" ] || { name=${u##*/}; name=${name%.git}; }
						# Forgejo resolves an abbreviated hash
						api=https://forge.sourceware.org/api/v1/repos/${u#https://forge.sourceware.org/}/git/commits/$abbrev
						c=$(curl -fsSL "$api" | python3 -c "import json, sys; print(json.load(sys.stdin)[\"sha\"])")
						[ "${c:0:12}" = "$abbrev" ] || { echo "$n: $abbrev resolved to $c" >&2; exit 1; }
						srcdir_name=$name; echo "git $u $c $name";;
					*://*) echo "$n: source $s?" >&2; exit 1;;
					*) curl -fsSL -o "$s" "$raw/$s"; echo "${sha256sums[$i]}  $s" | sha256sum -c --quiet; echo "file $s ${sha256sums[$i]}";;
				esac
			done
			[ -n "$srcdir_name" ] || { echo "$n: no git source" >&2; exit 1; }
			sed -n "/^prepare() {$/,/^}$/p" PKGBUILD | sed "1d;\$d" | while IFS= read -r l; do
				l=$(printf "%s" "$l" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")
				case $l in
					""|"#"*) ;;
					"[[ ! -d $srcdir_name ]] && ln -s "*) ;;		# makepkg source dir names
					"cd $srcdir_name"|"mkdir -p "*) ;;			# the steps run in the source tree
					"patch -Np"[01]" < "*) f=${l#*< }; f=${f//\"/}; f=${f##*/}; echo "patch ${l:6:4} $f";;
					*) if printf "%s\n" "$l" | grep -qE "^sed -i '"'"'[^'"'"']*'"'"' [A-Za-z0-9_./+-]+$"; then echo "sed ${l#sed -i }"
					   else echo "$n: prepare() has a step this script cannot replay: $l" >&2; exit 1; fi;;
				esac
			done
			# configure flags of build()'"'"'s configure call (gcc: drzee'"'"'s gcc -v instead, see below)
			f=$(sed -n "/^build() {$/,/^}$/p" PKGBUILD | sed -n "/\/configure \\\\$/,/[^\\\\]$/p" | sed "1d;s/\\\\$//" | tr -s " \n" "  ")
			echo "configure $f"
			# a _confflags=( ... ) array of plain flags (solskogen'"'"'s gcc), to compare with gcc -v
			a=$(sed -n "/^  local _confflags=(/,/)/p" PKGBUILD | sed "s/^  local //")
			if [ -n "$a" ]; then eval "$a"; echo "confflags ${_confflags[*]}"; fi
		) > zflip3.parsed
		cd /; mv "$d.part" "$d"
	done' sh gcc "$gccv" "${GCC_PKG[@]}" binutils "$binv" "${BIN_PKG[@]}")
[ ${#parsed[@]} = 2 ] && [ -s "$W/xsrc/${parsed[0]}" ] && [ -s "$W/xsrc/${parsed[1]}" ] || { echo "PKGBUILDs not parsed" >&2; exit 1; }
pg=$W/xsrc/${parsed[0]} pb=$W/xsrc/${parsed[1]}
read -r _ gcc_url gcc_commit _ < <(grep "^git " "$pg")
read -r _ bin_url bin_commit _ < <(grep "^git " "$pb")
read -r -a bin_flags < <(sed -n "s/^configure //p" "$pb")
# no PGO/LTO of binutils itself (output unchanged), no debuginfod client (no lookups from objdump/readelf)
bin_flags=($(printf "%s\n" "${bin_flags[@]}" | grep -v -e "^--enable-pgo-build=" -e "^--with-debuginfod$") --without-debuginfod)
printf "%s\n" "${bin_flags[@]}" | grep -qvE "^--[a-z0-9-]+(=[A-Za-z0-9_.,:/+-]*)?$" &&
	{ echo "binutils configure flags: $(printf "%s\n" "${bin_flags[@]}" | grep -vE "^--[a-z0-9-]+(=[A-Za-z0-9_.,:/+-]*)?$")?" >&2; exit 1; }
printf "%s\n" "${bin_flags[@]}" | grep -qx -- --prefix=/usr || { echo "binutils: no configure flags found in its PKGBUILD" >&2; exit 1; }
log "PKGBUILDs: $(sed -n 's/^pkgbuild //p' "$pg" | tr '\n' ' ')/ $(sed -n 's/^pkgbuild //p' "$pb")"
log "sources: gcc $gcc_commit, binutils $bin_commit; prepare: $(grep -c "^\(sed\|patch\) " "$pg") + $(grep -c "^\(sed\|patch\) " "$pb") steps"

# drzee's gcc itself, current (pacman -Syu as in a build): its configure line, multilib directory,
# version strings
mapfile -t probe < <(builder_current -- 'pacman -Q gcc binutils | tr "\n" " "; echo
	gcc -v 2>&1 | sed -n "s/^Configured with: //p"; gcc -print-multi-os-directory
	gcc -v 2>&1 | sed -n "s/^gcc version //p"; ld -v')
[ "${probe[0]}" = "gcc $gccv binutils $binv " ] || { echo "builder has ${probe[0]}, the sync db gcc $gccv binutils $binv" >&2; exit 1; }
# drzee's configure flags minus the languages, bootstrap and its LTO build config (ours: C, C++, LTO, no bootstrap)
read -r -a gcc_all <<< "${probe[1]}"
gcc_flags=($(printf "%s\n" "${gcc_all[@]:1}" | grep -v -e "^--enable-languages=" -e "^--enable-bootstrap$" -e "^--with-build-config="))
printf "%s\n" "${gcc_flags[@]}" | grep -qvE "^--[a-z0-9-]+(=[A-Za-z0-9_.,:/+-]*)?$" &&
	{ echo "drzee gcc configure flags: $(printf "%s\n" "${gcc_flags[@]}" | grep -vE "^--[a-z0-9-]+(=[A-Za-z0-9_.,:/+-]*)?$")?" >&2; exit 1; }
# the gcc PKGBUILD is the one drzee's gcc was configured from: the same flags (its build() adds
# --with-build-config=bootstrap-lto to _confflags)
diff <(printf "%s\n" "${gcc_all[@]:1}" | grep -v "^--with-build-config=" | sort) \
	<(sed -n "s/^confflags //p" "$pg" | tr " " "\n" | grep -v "^--with-build-config=" | sort) ||
	{ echo "the gcc PKGBUILD's _confflags are not drzee's gcc -v (above: < drzee, > PKGBUILD)" >&2; exit 1; }
# drzee's libraries are in /usr/lib (its specs say "lp64:../lib"; the PKGBUILD's prepare() does it)
[ "${probe[2]}" = ../lib ] || { echo "drzee gcc -print-multi-os-directory: ${probe[2]}, not ../lib" >&2; exit 1; }
gcc_date=${probe[3]#* }; gcc_date=${gcc_date%% *}			# "16.2.1 20261021 (GCC)"
bin_ver=${probe[4]##* }							# "GNU ld (GNU Binutils) 2.47.0"

# sources at those commits (fetcher: native, plain git as the user), checked against what drzee's
# binaries say they are
fetch_user sh -euc '
	while [ $# -gt 0 ]; do [ -d "/w/xsrc/$1" ] || {
		rm -rf "/w/xsrc/$1.part"; git init -q "/w/xsrc/$1.part"; git -C "/w/xsrc/$1.part" fetch -q --depth 1 "$2" "$3"
		git -C "/w/xsrc/$1.part" -c advice.detachedHead=false checkout -q FETCH_HEAD; mv "/w/xsrc/$1.part" "/w/xsrc/$1"; }
		[ "$(git -C "/w/xsrc/$1" rev-parse HEAD)" = "$3" ]; shift 3; done' \
	sh "gcc-$gcc_commit" "$gcc_url" "$gcc_commit" "binutils-$bin_commit" "$bin_url" "$bin_commit"
want=${gccv%%+*}; want=${want#*:}
[ "$(cat "$W/xsrc/gcc-$gcc_commit/gcc/BASE-VER")" = "$want" ] &&
	[ "$(cat "$W/xsrc/gcc-$gcc_commit/gcc/DATESTAMP")" = "$gcc_date" ] ||
	{ echo "gcc $gcc_commit is $(cat "$W/xsrc/gcc-$gcc_commit/gcc/BASE-VER") $(cat "$W/xsrc/gcc-$gcc_commit/gcc/DATESTAMP"), drzee's gcc $want $gcc_date" >&2; exit 1; }
grep -qF "m4_define([BFD_VERSION], [$bin_ver])" "$W/xsrc/binutils-$bin_commit/bfd/version.m4" ||
	{ echo "binutils $bin_commit is not $bin_ver: $(grep BFD_VERSION "$W/xsrc/binutils-$bin_commit/bfd/version.m4")" >&2; exit 1; }

# x86_64 build image: zflip3-fetch + gcc's/binutils' build deps + Arch's x86_64 ccache and fakeroot of
# drzee's versions (libfakeroot.so must also be preloadable into the x86_64 strip/objcopy that makepkg
# runs under fakeroot, and it talks to drzee's AArch64 faked over SysV IPC, same LP64 message layout).
# Brought up to date on every run: its glibc and libraries become xtools/lib
c=zflip3-xbuild-$$
"$ENGINE" image inspect localhost/zflip3-xbuild > /dev/null 2>&1 && from=localhost/zflip3-xbuild || from=localhost/zflip3-fetch
"$ENGINE" run --name "$c" --security-opt no-new-privileges -e "XGET=$XGET" "$from" bash -euo pipefail -c '
	eval "$XGET"
	pacman -Syu --noconfirm --needed gmp mpfr libmpc libisl zstd zlib jansson patchelf git > /dev/null
	xget "ccache=$1" "fakeroot=$2"
	rm -rf /var/cache/pacman/pkg/*' sh "$ccachev" "$fakerootv" || { "$ENGINE" rm -f "$c" > /dev/null; exit 1; }
"$ENGINE" commit "$c" localhost/zflip3-xbuild > /dev/null; "$ENGINE" rm "$c" > /dev/null
xglibc=$("$ENGINE" run --rm localhost/zflip3-xbuild pacman -Q glibc | cut -d" " -f2)

# drzee glibc + kernel headers as the build sysroot for gcc's configure checks of the target libc
fetch_pkgs core/glibc core/linux-api-headers > /dev/null
sysroot_pkgs=("glibc-${B[glibc]}-aarch64.pkg.tar.zst" "linux-api-headers-${B[linux-api-headers]}-aarch64.pkg.tar.zst")

# the compiler build is reused while everything it is made from is the same
key=$({ echo "zflip3 rev 1 gcc $gccv $gcc_commit binutils $binv $bin_commit"; cat "$pg" "$pb"; printf "%s\n" "${gcc_flags[@]}"
	"$ENGINE" run --rm localhost/zflip3-xbuild pacman -Q gmp mpfr libmpc libisl zstd zlib jansson; } | sha256sum | cut -d" " -f1)
if [ -e "$W/xbuild/stage/.done" ] && [ "$(cat "$W/xbuild/.for" 2>/dev/null)" = "$key" ]; then
	log "binutils + gcc already built for $gccv / $binv"
else
log "building binutils + gcc (log: $W/logs/mkxtools.log)"
"$ENGINE" run --rm -v "$W:/w" localhost/zflip3-xbuild sh -c 'rm -rf /w/xbuild && mkdir /w/xbuild && chown "$1" /w/xbuild' sh "$(id -u):$(id -g)"
echo "$key" > "$W/xbuild/.for"
"$ENGINE" run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$W/xbuild:/xb" -v "$W/xsrc:/xsrc:ro" \
	-v "$W/pkgcache:/pkgcache:ro" -e "GCC_FLAGS=${gcc_flags[*]}" -e "BIN_FLAGS=${bin_flags[*]}" localhost/zflip3-xbuild bash -euc '
	J=$(nproc); gsrc=$1 bsrc=$2 gp=$3 bp=$4; shift 4
	mkdir -p /xb/sysroot
	for p; do bsdtar -xf /pkgcache/$p -C /xb/sysroot; done
	# the PKGBUILD prepare(), replayed: its seds and patches, in order, in the source tree
	replay() {
		local k rest a b
		while read -r k rest; do case $k in
			sed) eval "sed -i $rest";;
			patch) read -r a b <<< "$rest"; patch "$a" < "${2%/*}/$b";;
		esac; done < "$2"
	}

	# binutils: Arch'"'"'s configure line; host != target
	cp -a "/xsrc/$bsrc" /xb/binutils-src && cd /xb/binutils-src
	replay binutils "/xsrc/$bp"
	sed -i "s/^    if \[ \"x\${host}\" = \"x\${target}\" \] ; then/    if [ \"x\${host}\" = \"x\${target}\" ] || [ -n \"\${ZFLIP3_NATIVE_LD}\" ] ; then/" ld/genscripts.sh
	grep -q ZFLIP3_NATIVE_LD ld/genscripts.sh
	# at run time the libraries come from /opt/zflip3-xtools/lib (DT_RPATH, searched before anything
	# else; the AArch64 /usr/lib of the builder comes later). Absent here, so the build uses this image libs.
	export LDFLAGS="-Wl,-rpath,/opt/zflip3-xtools/lib -Wl,--disable-new-dtags"
	mkdir /xb/b-binutils && cd /xb/b-binutils
	/xb/binutils-src/configure --target=aarch64-unknown-linux-gnu $BIN_FLAGS > /xb/binutils-configure.log
	ZFLIP3_NATIVE_LD=1 make -s -j$J tooldir=/usr > /xb/binutils-make.log 2>&1
	make -s DESTDIR=/xb/stage tooldir=/usr install > /dev/null 2>&1

	# gcc: drzee'"'"'s configure line, C/C++/LTO, no CROSS_DIRECTORY_STRUCTURE
	cp -a "/xsrc/$gsrc" /xb/gcc-src && cd /xb/gcc-src
	replay gcc "/xsrc/$gp"
	# libraries in /usr/lib, not lib64 (drzee'"'"'s specs say "lp64:../lib"): the PKGBUILD'"'"'s prepare()
	# has already done it; kept so a PKGBUILD without it cannot slip through
	sed -i "/mabi.lp64=/s/lib64/lib/" gcc/config/aarch64/t-aarch64-linux
	grep -qF "mabi.lp64=../lib\$(call" gcc/config/aarch64/t-aarch64-linux
	sed -i "s/^    CROSS=\"-DCROSS_DIRECTORY_STRUCTURE\"$/    CROSS=/" gcc/configure
	grep -q "^    CROSS=$" gcc/configure
	# and the C++ include dirs where a native gcc has them (/usr/include/c++/<major>, not under the target alias)
	sed -i -e '"'"'s|^       libstdcxx_incdir="$target_alias/$libstdcxx_incdir"$|       :|'"'"' \
		-e '"'"'s|^       libcxx_incdir="$target_alias/$libcxx_incdir"$|       :|'"'"' gcc/configure
	[ "$(grep -c '"'"'_incdir="$target_alias/'"'"' gcc/configure)" = 0 ]
	mkdir /xb/b-gcc && cd /xb/b-gcc
	# only the target-prefixed names: stage/usr/bin also has plain as/ld for AArch64
	export LD_LIBRARY_PATH=/xb/stage/usr/x86_64-pc-linux-gnu/aarch64-unknown-linux-gnu/lib:/xb/stage/usr/lib	# cross libbfd/libopcodes live in the former
	mkdir /xb/tbin && ln -s /xb/stage/usr/bin/aarch64-unknown-linux-gnu-* /xb/tbin/
	export PATH=/xb/tbin:$PATH
	CFLAGS="-O2 -pipe" CXXFLAGS="-O2 -pipe" /xb/gcc-src/configure \
		--build=x86_64-pc-linux-gnu --host=x86_64-pc-linux-gnu --target=aarch64-unknown-linux-gnu \
		--enable-languages=c,c++,lto --with-build-sysroot=/xb/sysroot $GCC_FLAGS > /xb/gcc-configure.log
	make -s -j$J all-gcc all-lto-plugin all-c++tools > /xb/gcc-make.log 2>&1
	make -s DESTDIR=/xb/stage install-gcc install-lto-plugin install-c++tools > /dev/null 2>&1
	touch /xb/stage/.done
	' sh "gcc-$gcc_commit" "binutils-$bin_commit" "${pg#$W/xsrc/}" "${pb#$W/xsrc/}" \
	"${sysroot_pkgs[@]}" > "$W/logs/mkxtools.log" 2>&1 ||
	{ tail -30 "$W/logs/mkxtools.log"; tail -30 "$W"/xbuild/*-make.log; exit 1; }
fi

# assemble /opt/zflip3-xtools: root/ mirrors the paths the tools take in the builder (xtools-activate.sh
# installs only the ones drzee's packages have there); lib/ is a private x86_64 glibc + the libraries
# they need (ld.so path and DT_RPATH point there, never at the container's AArch64 /usr/lib)
log "assembling $W/xtools"
"$ENGINE" run --rm -v "$W:/w" localhost/zflip3-xbuild sh -c 'rm -rf /w/xtools.new && mkdir /w/xtools.new && chown "$1" /w/xtools.new' sh "$(id -u):$(id -g)"
"$ENGINE" run --rm --user "$(id -u):$(id -g)" -v "$W/xbuild:/xb:ro" -v "$W/xtools.new:/xt" localhost/zflip3-xbuild bash -euc '
	s=/xb/stage/usr; t=aarch64-unknown-linux-gnu; g=usr/lib/gcc/$t/$1
	r=/xt/root; mkdir -p $r/usr/bin $r/$g $r/usr/lib/bfd-plugins /xt/lib
	for d in gcc g++ c++ cpp gcc-ar gcc-nm gcc-ranlib; do
		install -m755 $s/bin/$t-$d $r/usr/bin/$d; ln -f $r/usr/bin/$d $r/usr/bin/$t-$d; done
	ln -f $r/usr/bin/gcc $r/usr/bin/$t-gcc-$1
	for f in cc1 cc1plus collect2 lto1 lto-wrapper g++-mapper-server liblto_plugin.so; do
		install -m755 /xb/stage/$g/$f $r/$g/$f; done
	for b in addr2line ar as c++filt elfedit ld ld.bfd ld.gold nm objcopy objdump ranlib readelf size strings strip; do
		install -m755 $s/bin/$t-$b $r/usr/bin/$b; ln -f $r/usr/bin/$b $r/usr/bin/$t-$b; done
	install -m755 $s/lib/bfd-plugins/libdep.so $r/usr/lib/bfd-plugins/libdep.so
	install -m755 /usr/bin/ccache $r/usr/bin/ccache
	# found through the DT_RPATH before LD_LIBRARY_PATH=/usr/lib/libfakeroot (AArch64) when fakeroot
	# preloads "libfakeroot.so" into one of these
	cp -L /usr/lib/libfakeroot/libfakeroot.so /xt/lib/libfakeroot.so
	# private runtime: everything these need, from this x86_64 Arch image
	export LD_LIBRARY_PATH=/xb/stage/usr/x86_64-pc-linux-gnu/aarch64-unknown-linux-gnu/lib:/xb/stage/usr/lib	# cross libbfd/libopcodes live in the former
	if find $r -type f -exec ldd {} \; 2>/dev/null | grep "not found"; then echo "unresolved libraries" >&2; exit 1; fi
	for f in $(find $r -type f); do ldd $f 2>/dev/null | sed -n "s/.*=> \(\/[^ ]*\) .*/\1/p;s/^\s*\(\/[^ ]*ld-linux[^ ]*\) .*/\1/p"; done |
		sort -u | while read -r l; do cp -L "$l" /xt/lib/; done
	# glibc dlopen()s the iconv modules of every charset it has no built-in converter for (ISO-8859-1,
	# EUC-KR...) from /usr/lib/gconv, which in the builder holds AArch64 ones: iconv_open() would fail
	# in every x86_64 program (gcc -finput-charset, guile in make, tar, python embedding iconv). Its own
	# modules go to lib/gconv, and this libc looks for them in /opt/zf3/gconv instead, the same length
	# as /usr/lib/gconv (14 bytes) so only those bytes change (xtools-activate.sh links /opt/zf3/gconv
	# to lib/gconv; /opt/zflip3/gconv would be 17)
	cp -a /usr/lib/gconv /xt/lib/gconv
	[ ! -e /xt/lib/gconv/gconv-modules.cache ]	# would name /usr/lib/gconv; the config files do not
	[ ${#2} = ${#3} ]
	[ "$(LC_ALL=C grep -c -a "$3" /xt/lib/libc.so.6)" = 0 ]
	LC_ALL=C sed -i "s|$2|$3|g" /xt/lib/libc.so.6
	[ "$(strings -a /xt/lib/libc.so.6 | grep -c "^$3")" = 2 ] && ! LC_ALL=C grep -q -a "$2" /xt/lib/libc.so.6
	[ "$(stat -c %s /xt/lib/libc.so.6)" = "$(stat -c %s -L /usr/lib/libc.so.6)" ]
	# gcc/binutils got their DT_RPATH at link time; Arch'"'"'s ccache gets it here (only --set-rpath:
	# patchelf 0.19 breaks the gcc driver when it also moves PT_INTERP). The interpreter stays
	# /lib64/ld-linux-x86-64.so.2, which xtools-activate.sh points at lib/ (no AArch64 file has that name).
	patchelf --force-rpath --set-rpath /opt/zflip3-xtools/lib $r/usr/bin/ccache
	for f in $(find $r -type f); do
		readelf -d $f | grep -q "(RPATH).*/opt/zflip3-xtools/lib" || { echo "$f: no DT_RPATH /opt/zflip3-xtools/lib" >&2; exit 1; }
	done
	' sh "$major" /usr/lib/gconv /opt/zf3/gconv
printf 'gcc=%s\nbinutils=%s\nccache=%s\nfakeroot=%s\nxglibc=%s\n' "$gccv" "$binv" "$ccachev" "$fakerootv" "$xglibc" > "$W/xtools.new/.stamp"

# self-test: drzee gcc under qemu (brought up to date first) vs these, same inputs, byte-identical
# outputs required; still as xtools.new, mounted where the builds see xtools
log "self-test: drzee gcc (qemu) vs xtools"
BUILDER_ARGS=(-v "$W/xtools.new:/opt/zflip3-xtools:ro" -v "$TOOLS/xtools-activate.sh:/usr/local/bin/xtools-activate:ro"
	-v "$TOOLS/xtools-selftest.sh:/usr/local/bin/xtools-selftest:ro")
builder_current -- 'xtools-selftest /tmp/native; xtools-activate; xtools-selftest /tmp/x
	cd /tmp/native; rc=0
	for f in *; do cmp -s "$f" "/tmp/x/$f" && continue; rc=1; echo "DIFFERS: $f"
		case $f in *.txt|*.s) diff "$f" "/tmp/x/$f" | head -20;; esac; done
	echo "$(ls | wc -l) outputs compared"; exit $rc' > "$W/logs/xtools-selftest.log" 2>&1 ||
	{ grep -v "^ " "$W/logs/xtools-selftest.log" | tail -40; echo "self-test FAILED: outputs differ (xtools.new not used)" >&2; exit 1; }
BUILDER_ARGS=()
grep "^xtools-activate" "$W/logs/xtools-selftest.log" >&2 || true
tail -1 "$W/logs/xtools-selftest.log"
# into place (no build runs: xtools_lock); the compiler build trees go, stage/ (what xtools is
# assembled from) and .for stay for a rerun with the same inputs
"$ENGINE" run --rm -v "$W:/w" localhost/zflip3-xbuild sh -euc 'rm -rf /w/xtools.old; [ ! -e /w/xtools ] || mv /w/xtools /w/xtools.old
	mv /w/xtools.new /w/xtools; rm -rf /w/xtools.old
	rm -rf /w/xbuild/b-gcc /w/xbuild/b-binutils /w/xbuild/gcc-src /w/xbuild/binutils-src /w/xbuild/tbin /w/xbuild/sysroot'
log "xtools ready: $(tr '\n' ' ' < "$W/xtools/.stamp")"
