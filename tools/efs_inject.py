#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Inject small files into a Qualcomm EFS2 partition image (offline).

Built on efs2_extractor.py's structures (read path). Write path:
inline 'n' records (mode + data, no inode) appended to the directory
node chain. For 1-byte NV-style files this avoids inode/cluster
allocation entirely.

Usage: efs_inject.py modemst1.img /nv/item_files/ims/IMS_enable 01
       (hex data) or: efs_inject.py modemst1.img /path file.bin

DANGER: modifies the image in place. Back it up first.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                'efs2_extractor'))
from efs2_extractor import (superblock_data, node_data, efs_info_data,
                            find_efs_info, read_node, collect_entries,
                            is_valid_page, INVALID_PAGE)

PAGE_SCAN_STRIDE = 0x800


def load_superblock(f, file_size):
    age = -1
    sb = None
    sb_off = 0
    i = 0
    while True:
        try:
            f.seek(i * PAGE_SCAN_STRIDE)
            s = superblock_data.parse_stream(f)
            s["file_size"] = file_size
            s["efs_info"] = find_efs_info(f, s)
            if s["age"] > age:
                age = s["age"]
                sb = s
                sb_off = i * PAGE_SCAN_STRIDE
        except Exception:
            pass
        i += 1
        if i * PAGE_SCAN_STRIDE >= file_size:
            break
    if sb is None:
        raise ValueError("No usable EFS2 superblock found")
    return sb, sb_off


def find_dir_inode(files, dirpath, root_inode):
    """Resolve /a/b/c to the inode of directory c (via parent links)."""
    parts = [p for p in dirpath.split('/') if p]
    # build child->(name, parent) map for dirs
    parent_of = {}
    name_of = {}
    inodes = set()
    for e in files:
        if e.inode is not None:
            inodes.add(e.inode)
    for e in files:
        if e.inode is None:
            continue
        if e.is_dir() or e.inode in [x.parent_inode for x in files]:
            parent_of[e.inode] = e.parent_inode
            name_of[e.inode] = e.name
    cur = root_inode
    for part in parts:
        nxt = None
        for ino, (nm, par) in [(i, (name_of[i], parent_of[i]))
                               for i in parent_of if parent_of[i] == cur]:
            if nm == part:
                nxt = ino
                break
        if nxt is None:
            return None, cur, part  # missing: parent=cur, need=part
        cur = nxt
    return cur, None, None


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 1
    img, efspath, payload = sys.argv[1:4]
    if os.path.isfile(payload):
        with open(payload, 'rb') as fh:
            filedata = fh.read()
    else:
        filedata = bytes.fromhex(payload)

    parentdir, filename = efspath.rsplit('/', 1)
    if not parentdir:
        parentdir = '/'

    with open(img, 'r+b') as f:
        f.seek(0, os.SEEK_END)
        file_size = f.tell()

        sb, sb_off = load_superblock(f, file_size)
        print(f"[I] superblock age=0x{sb['age']:x} "
              f"page_size=0x{sb['page_size']:x} off=0x{sb_off:x}")
        root_inode = sb["efs_info"]["root_inode"]
        ps = sb["page_size"]

        # collect existing entries (start node 2, fallback 4)
        files = None
        for cand in (2, 4):
            try:
                f.seek(0)
                from efs2_extractor import collect_entries as ce
                files = ce(f, sb, cand)
                break
            except Exception:
                continue
        if files is None:
            print("[E] cannot parse node list")
            return 1

        # resolve parent dir; create missing dirs as inline records is
        # out of scope -- require existing parent chain
        cur = root_inode
        parts = [p for p in parentdir.split('/') if p]
        parent_of = {}
        name_of = {}
        for e in files:
            if e.inode is None:
                continue
            if e.is_dir():
                parent_of[e.inode] = e.parent_inode
                name_of[e.inode] = e.name
        # also infer dirs referenced as parents
        for e in files:
            if e.parent_inode not in parent_of and e.parent_inode != root_inode:
                # unknown; may still resolve if named below
                pass
        for part in parts:
            nxt = None
            for ino, par in parent_of.items():
                if par == cur and name_of.get(ino) == part:
                    nxt = ino
                    break
            if nxt is None:
                print(f"[E] directory {parentdir} missing at '{part}' "
                      f"(parent inode 0x{cur:x}); create parents first")
                return 1
            cur = nxt
        parent_inode = cur
        print(f"[I] parent '{parentdir}' inode=0x{parent_inode:x}")

        # check if file already exists (update vs create)
        for e in files:
            if e.parent_inode == parent_inode and e.name == filename:
                print(f"[I] '{efspath}' exists "
                      f"({len(e.data)} bytes); refusing to overwrite")
                return 1

        # Build inline 'n' record: flen, mlen, 'd'+u32 parent+name,
        # 'n'+u16 mode+u8 pad+data
        mode = 0x81A4  # S_IFREG|0644
        name_b = filename.encode()
        drec = b'd' + struct.pack('<I', parent_inode) + name_b
        flen = len(drec)
        mrec = b'n' + struct.pack('<H', mode) + b'\x00' + filedata
        mlen = len(mrec)
        record = bytes([flen, mlen]) + drec + mrec
        print(f"[I] record {len(record)} bytes: flen={flen} mlen={mlen}")

        # find the last node page in the level-0 chain with room
        node_id = 2
        try:
            from efs2_extractor import collect_entries as ce2
            ce2(f, sb, 2)
        except Exception:
            node_id = 4
        # walk to tail
        tail_id = node_id
        seen = set()
        while tail_id != INVALID_PAGE and tail_id not in seen:
            seen.add(tail_id)
            node = read_node(f, sb, tail_id)
            if node["next"] == INVALID_PAGE:
                break
            tail_id = node["next"]
        page_id = sb["pt"][tail_id]
        f.seek(page_id * ps)
        tail = node_data.parse_stream(f)
        used = tail["used"]
        free = ps - 8 - used  # node header prev/next/used/pad/gid/lvl
        print(f"[I] tail node {tail_id} page {page_id} used={used} free~{free}")
        if free < len(record) + 8:
            print("[E] no room in tail node; multi-node append not implemented")
            return 1

        # append record, bump used
        f.seek(page_id * ps + 8 + used)
        f.write(record)
        # update used field (offset 8 in node header: prev, next, used u16)
        f.seek(page_id * ps + 8)
        f.write(struct.pack('<H', used + len(record)))
        f.flush()
        print(f"[I] wrote {efspath} ({len(filedata)} bytes) "
              f"to node {tail_id} page {page_id}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
