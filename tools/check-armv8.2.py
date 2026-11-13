#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# check-armv8.2.py: make sure built packages carry no AArch64 instructions beyond what the Galaxy Z
# Flip3's Snapdragon 888 has. Its Cortex-X1, A78 and A55 cores implement ARMv8.2-A (with ARMv8.1's
# LSE atomics, RDM and CRC32), the FP16 arithmetic, the LDAPR instructions of ARMv8.3 (RCpc), the
# dot product instructions of ARMv8.4 and the ARMv8.0 crypto extension (AES, PMULL, SHA1, SHA256;
# Cortex-A78/X1/A55 TRMs and their Cryptographic Extension TRMs), which is exactly drzee's
# -march=armv8.2-a+fp16+rcpc+dotprod+crypto. A GitHub runner's Neoverse cores have much more (SVE,
# SVE2, BF16, I8MM, ARMv8.5+), and a configure script, -march=native or a JIT build step can pick it.
#   check-armv8.2.py [--features LLVM-MATTR] <pkg.tar.zst>...
# Needs bsdtar and llvm-objdump (any host arch). Every AArch64 ELF is disassembled twice, once with
# every architecture feature and once with only the allowed ones (llvm-objdump
# --mattr=-all,+v8.2a,+neon,+fullfp16,+rcpc,+dotprod,+aes,+sha2). An instruction that decodes
# differently the second time needs a newer feature: FHM (FMLAL), SHA3/SHA512/SM3/SM4, LDAPUR (RCpc
# immediate offsets), BF16, I8MM, SVE/SME, JSCVT, FCMA, FRINTTS, PAuth outside the hint space, FlagM,
# SB, DC CVADP (shows up as a bare "sys"), newer system registers such as RNDR (shows up as
# S3_x_Cx_Cx_x), MTE, LS64, MOPS, ... (tried one by one against llvm-objdump 23 on 2026-11-14).
# Exempt: the hint space (PACIASP/AUTIASP/BTI/XPACLRI are NOPs on these cores). Kernel alternatives
# are exempt too: code listed as a replacement in an .altinstructions section (the kernel's vDSO in
# -headers) is only patched in at boot when the CPU has the feature.
# Go programs built for GOARM64 up to v8.2 (v8.0 is the default; read from .go.buildinfo) are exempt
# as a whole: Go guarantees they run on that level, and the standard library's assembly beyond it
# (SHA-512, SHA-3, DIT, SVE, ...) is only called after the matching internal/cpu check. Their findings
# are counted as run-time dispatched, not failed; a Go program built for a higher GOARM64 is checked
# as usual.
# Bytes that decode in neither pass are data. The kernel is skipped (vmlinux in -headers, *.ko): it
# patches newer instructions in at boot through alternatives, behind its own CPU feature checks.
# Exit status 1 on any finding; code that picks instructions at run time behind a HWCAP check of its
# own still gets reported and needs a look.
# From linux-hiby-rs6's check-armv8.0.py (the RS6 is ARMv8.0), with the Flip3's feature set.
import argparse, os, re, struct, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

ALLOWED = '-all,+v8.2a,+neon,+fullfp16,+rcpc,+dotprod,+aes,+sha2'
EM_AARCH64 = 183
KERNEL = re.compile(r'(^|/)usr/lib/modules/[^/]+/(build/vmlinux|.*\.ko)$')
INSN = re.compile(r'^\s*([0-9a-f]+):\s*\t(.*)$')
FUNC = re.compile(r'^[0-9a-f]+ <(.+)>:$')


def aarch64_elf(path):
    try:
        with open(path, 'rb') as f:
            h = f.read(20)
    except OSError:
        return False
    return len(h) == 20 and h[:4] == b'\x7fELF' and h[5] == 1 and int.from_bytes(h[18:20], 'little') == EM_AARCH64


def alt_replacements(path):
    # arm64 struct alt_instr {s32 orig_offset; s32 alt_offset; u16 cpucap; u8 orig_len; u8 alt_len;},
    # offsets relative to the field; returns the [start, end) address ranges of the replacements
    with open(path, 'rb') as f:
        d = f.read()
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    if not secs:
        return []
    stroff = secs[shstrndx][4]
    out = []
    for s in secs:
        if d[stroff + s[0]:].split(b'\0')[0] == b'.altinstructions':
            addr, off, size = s[3], s[4], s[5]
            for i in range(size // 12):
                _, a, _, _, alen = struct.unpack_from('<iiHBB', d, off + i * 12)
                start = addr + i * 12 + 4 + a
                out.append((start, start + alen))
    return out


def sections(d):
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    if not secs:
        return {}
    stroff = secs[shstrndx][4]
    return {d[stroff + s[0]:].split(b'\0')[0].decode(errors='replace'): s for s in secs}


def go_up_to_v82(path):
    # True for a Go program built for GOARM64 v8.0, v8.1 or v8.2: its build settings in .go.buildinfo
    # carry "build\tGOARM64=<level>", and Go leaves the setting out when it is the default, v8.0
    with open(path, 'rb') as f:
        d = f.read()
    s = sections(d).get('.go.buildinfo')
    if not s:
        return False
    m = re.search(rb'\tGOARM64=(v[0-9.]+)', d[s[4]:s[4] + s[5]])
    return m is None or m.group(1).split(b',')[0] in (b'v8.0', b'v8.1', b'v8.2')


def check_elf(path, rel, mattr):
    alts = alt_replacements(path)
    # llvm-objdump enables every AArch64 feature by default; both listings have the same lines
    full, lim = (subprocess.Popen(['llvm-objdump', '-d', '--no-show-raw-insn', path] + extra,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                 for extra in ([], ['--mattr=' + mattr]))
    findings, func = [], '?'
    for a, b in zip(full.stdout, lim.stdout):
        m = FUNC.match(a)
        if m:
            func = m.group(1)
            continue
        ma, mb = INSN.match(a), INSN.match(b)
        if not ma or not mb:
            continue
        ia, ib = ma.group(2).strip(), mb.group(2).strip()
        if ia != ib and not ia.startswith('<unknown>') and not ib.startswith('hint'):
            pc = int(ma.group(1), 16)
            if not any(lo <= pc < hi for lo, hi in alts):
                findings.append('%s: %s: 0x%s: %s' % (rel, func, ma.group(1), ia))
    full.wait(); lim.wait()
    if full.returncode or lim.returncode:
        findings.append('%s: llvm-objdump failed' % rel)
        return findings, 0
    if findings and go_up_to_v82(path):
        return [], len(findings)
    return findings, 0


def check(pkg, mattr):
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(['bsdtar', '-xf', pkg, '-C', d], check=True)
        elfs = []
        for root, _, files in os.walk(d):
            for fn in files:
                p = os.path.join(root, fn)
                if not os.path.islink(p) and aarch64_elf(p) and not KERNEL.search(os.path.relpath(p, d)):
                    elfs.append(p)
        with ThreadPoolExecutor(os.cpu_count()) as ex:
            res = list(ex.map(lambda p: (os.path.relpath(p, d), check_elf(p, os.path.relpath(p, d), mattr)), elfs))
            findings = [f for _, (r, _) in res for f in r]
    for f in findings:
        print('%s: %s' % (os.path.basename(pkg), f))
    for rel, (_, n) in res:
        if n:
            print('%s: %s: Go, GOARM64<=v8.2: %d instruction(s) behind internal/cpu dispatch, exempt' % (os.path.basename(pkg), rel, n))
    print('%s: %d AArch64 ELF file(s), %d finding(s)' % (os.path.basename(pkg), len(elfs), len(findings)))
    return len(findings)


ap = argparse.ArgumentParser()
ap.add_argument('--features', default=ALLOWED, help='llvm-objdump --mattr for the allowed set (default %(default)s)')
ap.add_argument('pkgs', nargs='+')
args = ap.parse_args()
total = sum(check(p, args.features) for p in args.pkgs)
print('%d instruction(s) beyond ARMv8.2+fp16+rcpc+dotprod+crypto found' % total)
sys.exit(1 if total else 0)
