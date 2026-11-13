#!/bin/sh
# SPDX-License-Identifier: MIT
# xtools-activate.sh: inside a zflip3-builder container (as root, after pacman -Syu and the build deps),
# put the native x86_64 compilers from mkxtools-zflip3.sh (mounted at /opt/zflip3-xtools) over drzee's
# AArch64 binaries, at the same paths, the way crossdirect does it:
#   gcc, binutils, ccache   always (drzee's exact versions, rebuilt for x86_64)
#   python ninja bison      Arch's x86_64 packages of drzee's versions (mkxtools-tools-zflip3.sh), each
#   flex m4 zstd bsdtar     one only while drzee's version and those of the libraries it loads still
#   debugedit xz gzip make  match (else it stays AArch64, under qemu); python only if it can also load
#   bash coreutils sed gawk every python C module that drzee's python can load here. bash is
#   grep findutils diffutils /usr/bin/sh too: from here on every shell script is native, this one
#   tar bc cpio kmod file   excepted (its shell was loaded before; install unlinks before it writes,
#   pahole faked            so replacing running programs is safe)
# Only paths drzee's packages have are replaced: xtools carries the target-prefixed names a native
# gcc/binutils install has (aarch64-unknown-linux-gnu-ld & co.), and drzee's binutils has none of
# them; a name that does not exist here is not made (a build must find the same tools as on the phone).
# Refuses if drzee's gcc/binutils/ccache/fakeroot moved since they were built.
set -eu
X=/opt/zflip3-xtools
. "$X/.stamp"
for p in gcc binutils ccache fakeroot; do
	have=$(pacman -Q "$p" | cut -d' ' -f2)
	eval want=\$$p
	[ "$have" = "$want" ] || { echo "xtools-activate: $p $have here, cross tools are for $want: run mkxtools-zflip3.sh" >&2; exit 1; }
done
cd "$X/root"
# -p: ccache keys the compiler on its mtime+size (compiler_check=mtime), keep them stable
skipped=
for f in $(find . -type f | sort); do
	if [ -e "/${f#./}" ]; then install -p -m755 "$f" "/${f#./}"; else skipped="$skipped ${f##*/}"; fi
done
# the programs a build cannot do without must be among the replaced ones
for f in usr/bin/gcc usr/bin/g++ usr/bin/as usr/bin/ld usr/bin/ar usr/bin/ccache \
	"usr/lib/gcc/aarch64-unknown-linux-gnu/${gcc%%.*}/cc1" "usr/lib/gcc/aarch64-unknown-linux-gnu/${gcc%%.*}/lto1"; do
	cmp -s "$f" "/$f" || { echo "xtools-activate: /$f is not the x86_64 one" >&2; exit 1; }
done
# their ELF interpreter, /lib64/ld-linux-x86-64.so.2 (= /usr/lib here), is the x86_64 one in lib/
ln -sf "$X/lib/ld-linux-x86-64.so.2" /usr/lib/ld-linux-x86-64.so.2
# and their libc loads its iconv modules from /opt/zf3/gconv (mkxtools-zflip3.sh), not drzee's /usr/lib/gconv
mkdir -p /opt/zf3; ln -sfn "$X/lib/gconv" /opt/zf3/gconv
msg="gcc $gcc, binutils $binutils, ccache $ccache${skipped:+ (not in drzee's packages, left out:$skipped)}"

T=$X/tools
if [ -e "$T/.stamp" ]; then
	. "$T/.python"
	pacman -Q > /tmp/xtools-installed
	q() { sed -n "s/^$1 //p" /tmp/xtools-installed; }
	ok=
	while read -r p v deps; do
		have=$(q "$p"); [ -n "$have" ] || continue
		why=; [ "$have" = "$v" ] || why="$p $have here"
		for d in $deps; do h=$(q "${d%%=*}"); [ -z "$h" ] || [ "$h" = "${d#*=}" ] || why="${why:+$why, }${d%%=*} $h here"; done
		if [ -n "$why" ]; then echo "xtools-activate: $p stays AArch64 ($why, x86_64 $p $v: run mkxtools-tools-zflip3.sh)"; continue; fi
		ok="$ok $p"
	done < "$T/.stamp"
	put() { [ ! -d "$T/pkg/$1" ] || (cd "$T/pkg/$1" && find . -type f) | while read -r f; do install -p -m755 "$T/pkg/$1/$f" "/${f#./}"; done; }
	for p in $ok; do [ "$p" = python ] || put "$p"; done
	case " $ok " in *" python "*)
		# every AArch64 module needs its x86_64 twin, unless it cannot be loaded under qemu either
		block=
		for f in $(find "/usr/lib/python$pyv" -name "*.so" ! -name "*-x86_64-linux-gnu.so"); do
			t=${f%-aarch64-linux-gnu.so}-x86_64-linux-gnu.so
			[ "$t" != "$f" ] && { [ -e "$t" ] || [ -e "$T/pkg/python$t" ]; } && continue
			ldd "$f" 2>/dev/null | grep -q "not found" && continue
			block="$block ${f#/usr/lib/python$pyv/}"
		done
		case " $ok " in *" clang-libs "*) ;; *) [ -z "$(q clang-libs)" ] || block="$block libclang";; esac
		if [ -n "$block" ]; then echo "xtools-activate: python stays AArch64, no x86_64 build of:$block"
			ok=$(for p in $ok; do [ "$p" = python ] || printf " %s" "$p"; done)
		else
			put python
			# what drzee's python says about itself (EXT_SUFFIX, SOABI, CC, CFLAGS, LIBPL...)
			for f in /usr/lib/python$pyv/_sysconfigdata_*_linux_aarch64-linux-gnu.py; do
				install -p -m644 "$f" "${f%_aarch64-linux-gnu.py}_x86_64-linux-gnu.py"; done
			ln -sfn "config-$pyv-aarch64-linux-gnu" "/usr/lib/python$pyv/config-$pyv-x86_64-linux-gnu"
			msg="$msg, python $(python3 -c 'import platform, sysconfig; print(platform.python_version(), "(" + sysconfig.get_platform(), sysconfig.get_config_var("SOABI") + ")")')"
		fi;;
	esac
	msg="$msg; x86_64 tools:$ok"
fi
echo "xtools-activate: native x86_64 $msg"
