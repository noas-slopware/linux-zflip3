#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Pack board data files into an ath11k board-2.bin.

    ath11k-board2.py OUT NAME=FILE [NAME=FILE ...]

Each NAME is a board name as ath11k builds it, e.g.
  bus=pci,qmi-chip-id=0,qmi-board-id=255,variant=Samsung_Galaxy_Z_Flip3
and FILE is the board data for it (Samsung ships it as bdwlan.elf).

Layout (drivers/net/wireless/ath/ath11k/core.c, hw.h): the magic
"QCA-ATH11K-BOARD\\0" padded to 4 bytes, then one ATH11K_BD_IE_BOARD element per
board, each holding a BOARD_NAME and a BOARD_DATA element. Every element is
<le32 id><le32 len><data>, with data padded to 4 bytes.
"""
import struct
import sys

MAGIC = b"QCA-ATH11K-BOARD\0"
IE_BOARD = 0
IE_BOARD_NAME = 0
IE_BOARD_DATA = 1


def pad4(b):
    return b + b"\0" * (-len(b) % 4)


def ie(ie_id, data):
    return struct.pack("<II", ie_id, len(data)) + pad4(data)


def main(argv):
    if len(argv) < 3 or any("=" not in a for a in argv[2:]):
        sys.exit(__doc__)
    out = pad4(MAGIC)
    for arg in argv[2:]:
        # board names themselves contain '=', so split NAME=FILE at the last '='
        name, path = arg[: arg.rfind("=")], arg[arg.rfind("=") + 1 :]
        with open(path, "rb") as f:
            data = f.read()
        out += ie(IE_BOARD, ie(IE_BOARD_NAME, name.encode()) + ie(IE_BOARD_DATA, data))
    with open(argv[1], "wb") as f:
        f.write(out)


if __name__ == "__main__":
    main(sys.argv)
