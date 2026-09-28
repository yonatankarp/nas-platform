#!/usr/bin/env python3
"""Compare two release trees for byte and metadata equality; exit 0 same, 1 different.

A false "identical" silently skips a reinstall. Symlinks compare by target, unfollowed.
"""

import os
import stat
import sys


def snapshot(root):
    result = {}

    def record(path, relative):
        st = os.lstat(path)
        metadata = (stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid)
        if stat.S_ISLNK(st.st_mode):
            result[relative] = ("link", *metadata, os.readlink(path))
        elif stat.S_ISDIR(st.st_mode):
            result[relative] = ("dir", *metadata)
            for entry in sorted(os.scandir(path), key=lambda item: item.name):
                child_relative = entry.name if relative == "." else f"{relative}/{entry.name}"
                record(entry.path, child_relative)
        elif stat.S_ISREG(st.st_mode):
            with open(path, "rb") as handle:
                result[relative] = ("file", *metadata, handle.read())
        else:
            result[relative] = ("other", stat.S_IFMT(st.st_mode), *metadata)

    record(root, ".")
    return result


def main(argv):
    expected = snapshot(argv[1])
    actual = snapshot(argv[2])
    return int(expected != actual)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
