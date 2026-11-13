#!/usr/bin/env bash
# Make the container images the Arch jobs use, natively on an arm64 runner, from Arch Linux Ports'
# own bootstrap (arch-linux-repo.drzee.net, ARMv8.2, which the Snapdragon 888 has) and nothing else:
# every repository in them is a drzee one (the arch branch's tools/pacman-zflip3.conf) plus [zflip3]
# itself.
#
#   images.sh <arch branch checkout> <image>...
#     base     localhost/zflip3-arch-base  the drzee bootstrap the arch branch's tools/lib-zflip3.sh
#                                          names (sha256 checked); makepkg --printsrcinfo, repo-add
#     builder  localhost/zflip3-builder    drzee's key (by the fingerprint lib-zflip3.sh pins),
#                                          archports-keyring, the CI pacman.conf, BUILDER_PKGS of
#                                          tools/mkimages-zflip3.sh, tools/makepkg-zflip3.conf, user
#                                          builder (the runner's uid): what the local zflip3-builder
#                                          image has
#     checker  localhost/zflip3-check      the same keyring, llvm + python for tools/check-armv8.2.py
#
# builder and checker need $ARCH_WORK/repo (local-repo.sh) for [zflip3]. The CI pacman.conf is
# tools/pacman-zflip3.conf with the published repository ($ARCH_SITE/arch/$arch) as a second [zflip3]
# server after file:///repo, and without DisableSandbox: that line is for qemu-user, which cannot
# give pacman's download sandbox Landlock or seccomp, and here everything runs natively.
# local-repo.sh puts the published db plus this run's packages in /repo, and pacman fetches the
# published package files it needs from Pages.
#
# Environment: ARCH_WORK (work dir), ARCH_SITE (the Pages site).
set -euo pipefail

: "${ARCH_WORK:?}" "${ARCH_SITE:?}"
src=$(realpath "${1:?usage: $0 <arch checkout> <image>...}")
shift
lib=$src/tools/lib-zflip3.sh
val() { sed -n "s/^$1=\([^[:space:]#]*\).*/\1/p" "$lib" | head -n 1; }
DRZEE=$(val DRZEE)
DRZEE_KEY_FPR=$(val DRZEE_KEY_FPR)
BOOTSTRAP=$(val BOOTSTRAP)
BOOTSTRAP_SHA256=$(val BOOTSTRAP_SHA256)
BUILDER_PKGS=$(sed -n 's/^BUILDER_PKGS=(\([^)]*\)).*/\1/p' "$src/tools/mkimages-zflip3.sh")
for v in DRZEE DRZEE_KEY_FPR BOOTSTRAP BOOTSTRAP_SHA256 BUILDER_PKGS; do
	[ -n "${!v}" ] || { echo "$v not found in the arch branch's tools/" >&2; exit 1; }
done
[ "$(uname -m)" = aarch64 ] || { echo "native aarch64 only" >&2; exit 1; }
mkdir -p "$ARCH_WORK/dl" "$ARCH_WORK/ci"

# tools/pacman-zflip3.conf + the Pages server for [zflip3], minus DisableSandbox and its comment
sed -e "\|^Server = file:///repo\$|a Server = $ARCH_SITE/arch/\$arch" \
	-e '/^DisableSandbox$/d' -e '/^# qemu-user implements/d' "$src/tools/pacman-zflip3.conf" \
	> "$ARCH_WORK/ci/pacman.conf"
grep -q "^Server = $ARCH_SITE/arch/\\\$arch\$" "$ARCH_WORK/ci/pacman.conf" ||
	{ echo "tools/pacman-zflip3.conf has no 'Server = file:///repo' line" >&2; exit 1; }
if grep -n '^Server' "$ARCH_WORK/ci/pacman.conf" | grep -vF -e "$DRZEE/\$repo/os/" -e "file:///repo" -e "$ARCH_SITE/arch/"; then
	echo "pacman-zflip3.conf has a server that is not drzee's" >&2
	exit 1
fi

mk_base() {
	local tarball=$ARCH_WORK/dl/$BOOTSTRAP root
	if [ ! -e "$tarball" ]; then
		curl -fL --retry 3 -o "$tarball.part" "$DRZEE/tarballs/os/aarch64/$BOOTSTRAP"
		mv "$tarball.part" "$tarball"
	fi
	echo "$BOOTSTRAP_SHA256  $tarball" | sha256sum -c --quiet
	root=$(mktemp -d "$ARCH_WORK/rootfs.XXXXXX")
	sudo tar --zstd -xpf "$tarball" -C "$root" --strip-components=1 --numeric-owner
	sudo tar -C "$root" -cf - . | docker import --change 'CMD ["/bin/bash"]' - localhost/zflip3-arch-base
}

# prep <image> <script> <pkg>...: run <script> in a container from zflip3-arch-base after the keyring
# and pacman.conf are in place and <pkg>... are installed, then commit it as <image>
prep() {
	local image=$1 script=$2 c
	shift 2
	c=prep-$(basename "$image")-$$
	[ -e "$ARCH_WORK/repo/zflip3.db" ] || { echo "no $ARCH_WORK/repo/zflip3.db: run local-repo.sh first" >&2; exit 1; }
	# no-new-privileges: pacman's download sandbox (Landlock) needs it without CAP_SYS_ADMIN
	docker run --name "$c" --security-opt no-new-privileges \
		-v "$src/tools:/tools:ro" -v "$ARCH_WORK/ci:/ci:ro" -v "$ARCH_WORK/repo:/repo:ro" \
		localhost/zflip3-arch-base bash -euo pipefail -c '
		drzee=$1 fpr=$2 script=$3; shift 3
		install -m644 /ci/pacman.conf /etc/pacman.conf
		getent passwd alpm >/dev/null || systemd-sysusers
		pacman-key --init
		pacman-key --populate archlinux
		# drzee signs with its own key, trusted by the fingerprint lib-zflip3.sh pins, as
		# mkimages-zflip3.sh does; archports-keyring then brings it in as Arch Linux Ports ship it
		curl -fsSL "$drzee/extra/os/aarch64/public.key" -o /tmp/drzee.key
		got=$(gpg --show-keys --with-colons /tmp/drzee.key | awk -F: "/^fpr/{print \$10; exit}")
		[ "$got" = "$fpr" ] || { echo "drzee key is $got, expected $fpr" >&2; exit 1; }
		pacman-key --add /tmp/drzee.key
		pacman-key --lsign-key "$fpr"
		rm /tmp/drzee.key
		pacman -Syu --noconfirm --needed archports-keyring
		pacman-key --populate archports
		pacman -S --noconfirm --needed "$@"
		eval "$script"
		find /var/cache/pacman/pkg -mindepth 1 -delete' sh "$DRZEE" "$DRZEE_KEY_FPR" "$script" "$@"
	docker commit "$c" "$image" >/dev/null
	docker rm "$c" >/dev/null
}

mk_builder() {
	# shellcheck disable=SC2086 # BUILDER_PKGS is a word list
	prep localhost/zflip3-builder '
		# drzee baseline unchanged? tools/makepkg-zflip3.conf leaves CFLAGS as drzee sets them
		grep -q "^CFLAGS=\"-march=armv8.2-a+fp16+rcpc+dotprod+crypto " /etc/makepkg.conf
		install -m644 /tools/makepkg-zflip3.conf /etc/makepkg.conf.d/zflip3.conf
		useradd -m -u '"$(id -u)"' builder
		echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
		flags=$(runuser -u builder -- bash -c ". /etc/makepkg.conf; for f in /etc/makepkg.conf.d/*.conf; do . \$f; done; echo \$CFLAGS")
		echo "zflip3 CFLAGS: $flags"
		case $flags in "-march=armv8.2-a+fp16+rcpc+dotprod+crypto -O2 "*) ;; *) exit 1;; esac
		echo "int main(void){return 0;}" | gcc $flags -x c - -o /dev/null
		gcc -v 2>&1 | tail -n 1' $BUILDER_PKGS
}

mk_checker() {
	prep localhost/zflip3-check 'llvm-objdump --version | head -n 2' llvm python
}

for image; do
	echo "::group::image $image"
	"mk_$image"
	echo "::endgroup::"
done
