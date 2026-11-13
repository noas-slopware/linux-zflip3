#!/usr/bin/env python3
"""The arch part of the GitHub Pages site (arch/), as a list of files and as a copy of the live one.

Every Pages deployment replaces the whole site; here only arch-packages.yml deploys it, so nothing has
to be carried over between workflows (linux-hiby-rs6, where this comes from, shares its site with a
Nura workflow). What is left is the file list and the download by it: arch/files.txt lists the part's
files (paths relative to the site root), and the YuruMirror job fetches the live part by it when its
run deployed nothing, so a mirror that missed an update catches up on the next run.

  site.py list <site dir> arch               write arch/files.txt
  site.py fetch <site URL> arch <site dir>   download the live part into <site dir>
"""

import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

LISTS = {"arch": "arch/files.txt"}


def in_part(rel: str, part: str) -> bool:
    return rel == part or rel.startswith(part + "/")


def get(url: str) -> bytes | None:
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if attempt == 3:
                raise
        except (urllib.error.URLError, TimeoutError):
            if attempt == 3:
                raise
        time.sleep(5 * (attempt + 1))
    return None


def list_part(site: str, part: str) -> None:
    out = os.path.join(site, LISTS[part])
    files = []
    for root, _dirs, names in os.walk(site):
        for n in names:
            rel = os.path.relpath(os.path.join(root, n), site)
            if in_part(rel, part) and rel != LISTS[part]:
                files.append(rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write("".join(f"{r}\n" for r in sorted(files)))
    print(f"{LISTS[part]}: {len(files)} files")


def fetch_part(url: str, part: str, site: str) -> None:
    listing = get(f"{url}/{LISTS[part]}")
    if listing is None:
        print(f"{url}: no {part} part published, nothing to fetch")
        return
    files = [line for line in listing.decode().splitlines() if line] + [LISTS[part]]
    for rel in files:
        if not in_part(rel, part) or rel.startswith("/") or ".." in rel.split("/"):
            sys.exit(f"{LISTS[part]}: refusing {rel!r}")

    def one(rel: str) -> int:
        data = get(f"{url}/{rel}")
        if data is None:
            sys.exit(f"{url}/{rel}: listed but missing")
        dest = os.path.join(site, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
        return len(data)

    with ThreadPoolExecutor(8) as ex:
        size = sum(ex.map(one, files))
    print(f"fetched the {part} part: {len(files)} files, {size / 1e6:.1f} MB")


def main() -> None:
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == "list" and a[2] in LISTS:
        list_part(a[1], a[2])
    elif len(a) == 4 and a[0] == "fetch" and a[2] in LISTS:
        fetch_part(a[1].rstrip("/"), a[2], a[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
