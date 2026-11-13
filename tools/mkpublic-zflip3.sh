#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# mkpublic-zflip3.sh: build the public Arch Linux Ports image for the Galaxy Z Flip3 (SM-F711N) from the
# published [zflip3] repository, refuse it unless it is what a public image must be, then checksum it
# under its release names. From linux-hiby-rs6's mkpublic-rs6.sh.
#
#   tools/mkpublic-zflip3.sh prepare   fresh work dir (/var/tmp/zflip3-public-build), [zflip3] from Pages
#   tools/mkpublic-zflip3.sh image     mkimage-zflip3.sh with the public package set, then finish
#   tools/mkpublic-zflip3.sh verify    check the packed image against the published repository (below)
#   tools/mkpublic-zflip3.sh finish    verify, then zstd, .sha256/.sha512, sha256sums (image runs it)
#   tools/mkpublic-zflip3.sh all       prepare + image
# ZFLIP3_PUBLIC_TEST=1: the same from the local repo (/var/tmp/zflip3-arch-build/repo) into
#   /var/tmp/zflip3-public-build-test and /var/tmp/zflip3-public-image-TEST-NOT-FOR-RELEASE, files named
#   NOT-FOR-RELEASE-*: for checking unpublished packages only, never to be published (verify fails on
#   it by design: its packages and zflip3.db are not the published ones).
# ZFLIP3_VERIFY_DENY=<file> is handed on to mkimage-zflip3.sh (your own hostname, addresses, names).
#
# Out (release tag arch-ports-YYYY.MM.DD):
#   archlinux-zflip3-YYYY.MM.DD-rootfs.tar.zst  the root file system userspace/installer/install-rootfs.sh
#                                               (senpai branch) unpacks onto the F2FS on LVM
#   archlinux-zflip3-YYYY.MM.DD-boot.img.zst    the boot image for the recovery partition, as zflip3-boot
#                                               made it (on the phone it rewrites it on every update)
#   *.sha256, *.sha512, sha256sums
#
# What is in it: Plasma Mobile on the phone's packages, the set mkimage-zflip3.sh was run with on
# 2026-11-14 plus zflip3-mirrorlist. Accounts as Arch Linux Ports' bootstrap has them (none: the
# installer makes the user), no sshd, nothing personal (verify-zflip3-image.sh, run by mkimage).
# Why it can only come from the published repository: the sync databases in the image are what
# pacstrap synced, so a locally built [zflip3] package or zflip3.db would make the phone fetch files
# the mirrors do not have. prepare downloads zflip3.db and every package file it lists from GitHub
# Pages (the first [zflip3] server of pacman-zflip3-published.conf) into a fresh repo dir, after
# checking that YuruMirror (the second) serves the same zflip3.db; mkimage-zflip3.sh then installs
# from exactly those files with an empty package cache, so the image's sync/zflip3.db is the published
# one byte for byte, and serving every file is proven on the way.
set -euo pipefail
TOOLS=$(dirname "$(realpath "$0")")
ARCHSRC=$(dirname "$TOOLS")
mapfile -t SERVERS < <(awk '/^\[zflip3\]$/ { s = 1; next } /^\[/ { s = 0 }
	s && /^Server = / { sub(/^Server = /, ""); sub(/\$arch$/, "aarch64"); print }' "$TOOLS/pacman-zflip3-published.conf")
[ ${#SERVERS[@]} -eq 2 ] || { echo "pacman-zflip3-published.conf: [zflip3] needs Pages and YuruMirror" >&2; exit 1; }
PUB=${SERVERS[0]}
MIRROR=${SERVERS[1]}
PKGS=(base linux-zflip3 linux-zflip3-dtbs mkinitcpio firmware-zflip3 zflip3-device zflip3-plasma
	zflip3-mirrorlist networkmanager sudo vim nano plasma-mobile plasma-settings plasma-dialer spacebar
	plasma-camera plasma-keyboard plasma-nm plasma-pa bluedevil bluez bluez-utils kscreen
	xdg-desktop-portal-kde qqc2-breeze-style breeze-icons noto-fonts noto-fonts-cjk noto-fonts-emoji
	firefox fprintd geoclue feedbackd mesa vulkan-freedreno polkit-kde-agent qmlkonsole libcamera
	libcamera-ipa gst-plugin-libcamera iio-sensor-proxy mihari claire neard zram-generator)
# never in this image: a way in that the image itself hands out, and Noa's own packages
NOT=(openssh tailscale claude-code claude-desktop paru kagi-cli dissent-bin nocturne touko
	librepods-plamo orca-mobile delfin sloptube-qt plasma-hangul-keyboard)

# literal paths only (they are also the only paths this script removes)
if [ -n "${ZFLIP3_PUBLIC_TEST:-}" ]; then
	WORK=/var/tmp/zflip3-public-build-test
	OUT=/var/tmp/zflip3-public-image-TEST-NOT-FOR-RELEASE
	NAME="NOT-FOR-RELEASE-archlinux-zflip3"
else
	WORK=/var/tmp/zflip3-public-build
	OUT=/var/tmp/zflip3-public-image
	NAME=archlinux-zflip3
fi
PREFIX_FILE=$WORK/prefix

# remove a work dir: mkimage-zflip3.sh leaves root-owned files in it (image-root), so the removal runs
# as root in a container that sees only that directory, as clean-image-root-zflip3.sh does
wipe() {
	[ -e "$1" ] || return 0
	ls -ld "$1"
	case $1 in
		/var/tmp/zflip3-public-build) docker run --rm -v /var/tmp/zflip3-public-build:/w docker.io/library/archlinux:latest \
			sh -c 'umount -R /w/image-root 2>/dev/null; find /w -mindepth 1 -delete'
			rmdir /var/tmp/zflip3-public-build ;;
		/var/tmp/zflip3-public-build-test) docker run --rm -v /var/tmp/zflip3-public-build-test:/w docker.io/library/archlinux:latest \
			sh -c 'umount -R /w/image-root 2>/dev/null; find /w -mindepth 1 -delete'
			rmdir /var/tmp/zflip3-public-build-test ;;
		*) echo "wipe: $1?" >&2; exit 1 ;;
	esac
}

# the verify dir holds the invoking user's copies of a few image files
rm_verify() {
	if [ -n "${ZFLIP3_PUBLIC_TEST:-}" ]; then
		[ ! -e /var/tmp/zflip3-public-build-test/verify ] || rm -rf /var/tmp/zflip3-public-build-test/verify
	else
		[ ! -e /var/tmp/zflip3-public-build/verify ] || rm -rf /var/tmp/zflip3-public-build/verify
	fi
}

prepare() {
	wipe "$WORK"
	mkdir -p "$WORK/repo"
	if [ -n "${ZFLIP3_PUBLIC_TEST:-}" ]; then
		cp -a /var/tmp/zflip3-arch-build/repo/. "$WORK/repo/"
		echo "prepared $WORK from the local repo (TEST, NOT FOR RELEASE)"
		return
	fi
	curl -fsSL --retry 3 -o "$WORK/repo/zflip3.db" "$PUB/zflip3.db"
	curl -fsSL --retry 3 -o "$WORK/mirror-zflip3.db" "$MIRROR/zflip3.db"
	cmp -s "$WORK/repo/zflip3.db" "$WORK/mirror-zflip3.db" ||
		{ echo "GitHub Pages and YuruMirror serve different zflip3.db: wait for the mirror job" >&2; exit 1; }
	curl -fsSL --retry 3 -o "$WORK/repo/packages.txt" "$PUB/packages.txt"
	local f n=0
	while read -r f; do
		curl -fsSL --retry 3 -o "$WORK/repo/$f" "$PUB/$f"
		n=$((n + 1))
	done < "$WORK/repo/packages.txt"
	# every file zflip3.db names, and nothing else, with its checksum
	python3 -I - "$WORK/repo" <<-'EOF'
	import hashlib, os, re, sys, tarfile
	repo = sys.argv[1]
	want = {}
	with tarfile.open(os.path.join(repo, "zflip3.db")) as t:
	    for m in t.getmembers():
	        if m.name.endswith("/desc"):
	            f = dict(re.findall(r"%(\w+)%\n(.*?)\n(?:\n|$)", t.extractfile(m).read().decode(), re.S))
	            want[f["FILENAME"]] = f["SHA256SUM"]
	have = {f for f in os.listdir(repo) if ".pkg.tar" in f}
	bad = sorted(set(want) ^ have)
	if bad:
	    sys.exit(f"zflip3.db and packages.txt disagree: {bad}")
	for f, s in want.items():
	    with open(os.path.join(repo, f), "rb") as fh:
	        if hashlib.sha256(fh.read()).hexdigest() != s:
	            sys.exit(f"{f}: not the file zflip3.db describes")
	print(f"{len(want)} package files, as zflip3.db describes them")
	EOF
	echo "prepared $WORK: zflip3.db and $n package files from $PUB"
}

image() {
	[ -s "$WORK/repo/zflip3.db" ] || { echo "run prepare first"; exit 1; }
	mkdir -p "$OUT"
	if [ -n "$(ls -A "$OUT")" ]; then echo "$OUT is not empty:"; ls -l "$OUT"; exit 1; fi
	[ ! -e "$WORK/out" ] || { echo "$WORK/out exists: run prepare first"; exit 1; }
	local prefix
	prefix=$NAME-$(date +%Y.%m.%d)
	ZFLIP3_WORK=$WORK ZFLIP3_REPO=$WORK/repo ZFLIP3_IMAGE_PKGS="${PKGS[*]}" \
		"$TOOLS/mkimage-zflip3.sh" "$WORK/out"
	mv "$WORK/out/archlinux-zflip3-rootfs.tar.zst" "$OUT/$prefix-rootfs.tar.zst"
	mv "$WORK/out/linux-zflip3.img" "$OUT/$prefix-boot.img"
	echo "$prefix" > "$PREFIX_FILE"
	finish
}

finish() {
	if [ -n "${ZFLIP3_PUBLIC_TEST:-}" ]; then
		# a test image is expected to fail the published-repository checks; it is finished anyway
		# so the install chain can be checked, and its names say NOT-FOR-RELEASE
		verify || echo "TEST image: verify failed (expected for unpublished packages); NOT FOR RELEASE"
	else
		verify
	fi
	local prefix; prefix=$(cat "$PREFIX_FILE")
	(cd "$OUT" && zstd -q -19 -T0 --rm "$prefix-boot.img"
	for i in "$prefix-rootfs.tar.zst" "$prefix-boot.img.zst"; do
		sha256sum "$i" | tee "$i.sha256"
		sha512sum "$i" > "$i.sha512"
	done
	cat ./*.zst.sha256 > sha256sums)
	ls -l "$OUT"
}

# Read the packed image (the files that say what it is) and refuse anything a public image must not
# be or must have
verify() {
	local prefix; prefix=$(cat "$PREFIX_FILE")
	local tar=$OUT/$prefix-rootfs.tar.zst d=$WORK/verify
	[ -f "$tar" ] || { echo "no $tar"; exit 1; }
	rm_verify
	mkdir -p "$d/root" "$d/pub"
	if [ -z "${ZFLIP3_PUBLIC_TEST:-}" ]; then
		curl -fsSL --retry 3 -o "$d/pub/zflip3.db" "$PUB/zflip3.db"
		curl -fsSL --retry 3 -o "$d/pub/zflip3-mirror.db" "$MIRROR/zflip3.db"
	else
		cp /var/tmp/zflip3-arch-build/repo/zflip3.db "$d/pub/zflip3.db"
		cp /var/tmp/zflip3-arch-build/repo/zflip3.db "$d/pub/zflip3-mirror.db"
	fi
	# as the invoking user: the files land as theirs, modes kept (/etc/shadow too)
	# (--include: a path the image does not have, /etc/ssh without openssh, is not an error)
	bsdtar -xf "$tar" -C "$d/root" --include='./var/lib/pacman/local/*' --include='./var/lib/pacman/sync/*' \
		--include=./etc/pacman.conf --include='./etc/pacman.d/*' --include=./etc/passwd --include=./etc/shadow \
		--include=./etc/machine-id --include='./etc/systemd/system/*' --include='./etc/ssh/*' --include='./home/*' \
		--include=./home
	local rc=0
	python3 -I - "$d/root" "$d/pub" "$ARCHSRC" "$PUB" "$MIRROR" "${PKGS[*]}" "${NOT[*]}" <<-'EOF' || rc=$?
	import hashlib, pathlib, re, subprocess, sys, tarfile
	root, pub, archsrc, puburl, mirrorurl, pkgs, notpkgs = sys.argv[1:]
	R = pathlib.Path(root); P = pathlib.Path(pub)
	fail = []
	def need(ok, what):
	    print(("ok   " if ok else "FAIL ") + what)
	    if not ok:
	        fail.append(what)
	def descs(db):
	    out = {}
	    with tarfile.open(db) as t:
	        for m in t.getmembers():
	            if m.name.endswith("/desc"):
	                f = dict(re.findall(r"%(\w+)%\n(.*?)\n(?:\n|$)", t.extractfile(m).read().decode(), re.S))
	                out[f["NAME"]] = f["VERSION"]
	    return out
	inst, explicit = {}, set()
	for desc in (R / "var/lib/pacman/local").glob("*/desc"):
	    f = dict(re.findall(r"%(\w+)%\n(.*?)\n(?:\n|$)", desc.read_text(), re.S))
	    inst[f["NAME"]] = f["VERSION"]
	    if f.get("REASON", "0") == "0":
	        explicit.add(f["NAME"])
	h = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
	need(h(P / "zflip3.db") == h(P / "zflip3-mirror.db"), f"GitHub Pages and YuruMirror serve the same zflip3.db ({h(P / 'zflip3.db')[:16]})")
	sync = R / "var/lib/pacman/sync/zflip3.db"
	need(sync.exists() and h(sync) == h(P / "zflip3.db"),
	     f"image sync/zflip3.db {h(sync)[:16] if sync.exists() else '-'} is the published zflip3.db")
	pubdb = descs(P / "zflip3.db")
	ours = sorted(n for n in inst if n in pubdb)
	print(f"{len(inst)} packages installed, {len(ours)} of them from [zflip3]")
	for n in ours:
	    need(inst[n] == pubdb[n], f"[zflip3] {n} {inst[n]} == published {pubdb[n]}")
	# every installed package built from this arch checkout is at the checkout's version
	for pb in sorted(pathlib.Path(archsrc).glob("*/PKGBUILD")):
	    out = subprocess.run(["bash", "-c", '. ./PKGBUILD; echo "${epoch:+$epoch:}$pkgver-$pkgrel ${pkgname[*]}"'],
	                         cwd=pb.parent, capture_output=True, text=True).stdout.split()
	    for n in out[1:]:
	        if n in inst:
	            need(inst[n] == out[0], f"{n} {inst[n]} is the arch branch version {out[0]}")
	need(explicit == set(pkgs.split()), f"explicitly installed = the public set ({' '.join(sorted(explicit ^ set(pkgs.split()))) or 'same'})")
	for n in notpkgs.split():
	    need(n not in inst, f"{n} not installed")
	# pacman.conf: [zflip3] unsigned, before [extra], from the published servers only (directly, or
	# through zflip3-mirrorlist)
	conf = (R / "etc/pacman.conf").read_text()
	secs = re.findall(r"^\[([^\]]+)\]\n((?:(?!\[).*\n?)*)", conf, re.M)
	repos = [s[0] for s in secs if s[0] != "options"]
	print("repositories: " + " ".join(repos))
	need("zflip3" in repos and "extra" in repos and repos.index("zflip3") < repos.index("extra"), "[zflip3] comes before [extra]")
	body = dict(secs).get("zflip3", "")
	need(re.search(r"^SigLevel = Never$", body, re.M) is not None, "[zflip3]: SigLevel = Never")
	servers = re.findall(r"^Server = (.*)$", body, re.M)
	inc = re.findall(r"^Include = (.*)$", body, re.M)
	if inc:
	    need(inc == ["/etc/pacman.d/zflip3-mirrorlist"], f"[zflip3] includes zflip3-mirrorlist ({inc})")
	    ml = R / "etc/pacman.d/zflip3-mirrorlist"
	    servers += re.findall(r"^Server = (.*)$", ml.read_text(), re.M) if ml.exists() else []
	allowed = {u.replace("/aarch64", "/$arch") for u in (puburl, mirrorurl)}
	need(servers and set(servers) <= allowed, f"[zflip3] servers are the published ones ({servers})")
	# accounts as Arch Linux Ports' bootstrap: no password, no user, no home (the installer makes one)
	pw = [l.split(":") for l in (R / "etc/passwd").read_text().splitlines() if l]
	need([p[0] for p in pw if 1000 <= int(p[2]) < 65534] == [], "no user with uid >= 1000")
	sh = [l.split(":") for l in (R / "etc/shadow").read_text().splitlines() if l]
	need([s[0] for s in sh if not s[1].startswith(("*", "!"))] == [], "every account locked (no password, none empty)")
	home = R / "home"
	need(not home.exists() or not any(home.iterdir()), "/home is empty")
	keys = [str(p) for d in ("home", "etc/ssh") for p in (R / d).rglob("authorized_keys*")] if (R / "etc/ssh").exists() else []
	need(not keys, f"no authorized_keys ({keys})")
	need(not list((R / "etc/ssh").glob("ssh_host_*")) if (R / "etc/ssh").exists() else True, "no SSH host keys")
	need((R / "etc/machine-id").read_text() == "", "/etc/machine-id empty")
	wants = {p.name for p in (R / "etc/systemd/system").glob("*.wants/*")}
	print("enabled: " + " ".join(sorted(wants)))
	need(not any(n.startswith("sshd") for n in wants), "sshd not enabled")
	dm = R / "etc/systemd/system/display-manager.service"
	need(dm.is_symlink() and str(dm.readlink()).endswith("/plasmalogin.service"), f"plasmalogin is the display manager ({dm.readlink() if dm.is_symlink() else None})")
	sys.exit(f"verify: {len(fail)} failed" if fail else 0)
	EOF
	rm_verify
	[ "$rc" = 0 ] || { echo "verify FAILED: not a public image"; return 1; }
	echo "verify: all checks passed"
}

case "${1:-}" in
	prepare) prepare ;;
	image) image ;;
	verify) verify ;;
	finish) finish ;;
	all) prepare; image ;;
	*) sed -n '3,16p' "$0"; exit 1 ;;
esac
