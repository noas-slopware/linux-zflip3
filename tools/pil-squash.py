#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Join a split Qualcomm firmware image (NAME.mdt + NAME.bNN) into one NAME.mbn.

Same result as linux-msm's pil-squasher: the .mdt holds the ELF header and program
headers, and segment N's file contents live in NAME.bNN; each segment is written at
its p_offset. Segments with no file contents are skipped.

usage: pil-squash.py OUT.mbn IN.mdt
"""
import os
import struct
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip())
    out, mdt = sys.argv[1], sys.argv[2]
    if not mdt.endswith('.mdt'):
        sys.exit('input must be .mdt')
    base = mdt[:-len('.mdt')]
    with open(mdt, 'rb') as f:
        head = f.read()
    if head[:4] != b'\x7fELF':
        sys.exit(f'{mdt}: not an ELF')
    is64 = head[4] == 2
    endian = '<' if head[5] == 1 else '>'
    if is64:
        phoff, = struct.unpack_from(endian + 'Q', head, 0x20)
        phentsize, phnum = struct.unpack_from(endian + 'HH', head, 0x36)
    else:
        phoff, = struct.unpack_from(endian + 'I', head, 0x1c)
        phentsize, phnum = struct.unpack_from(endian + 'HH', head, 0x2a)

    with open(out + '.tmp', 'wb') as o:
        for i in range(phnum):
            ph = phoff + i * phentsize
            if is64:
                _, _, offset, _, _, filesz = struct.unpack_from(endian + 'IIQQQQ', head, ph)
            else:
                _, offset, _, _, filesz = struct.unpack_from(endian + 'IIIII', head, ph)
            if not filesz:
                continue
            seg = f'{base}.b{i:02d}'
            if not os.path.exists(seg):
                sys.exit(f'{seg}: missing segment {i} ({filesz} bytes)')
            with open(seg, 'rb') as s:
                data = s.read()
            if len(data) != filesz:
                sys.exit(f'{seg}: {len(data)} bytes, program header says {filesz}')
            o.seek(offset)
            o.write(data)
    os.replace(out + '.tmp', out)


if __name__ == '__main__':
    main()
