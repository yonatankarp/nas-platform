#!/usr/bin/env python3
"""Refuse a controller bundle input that escapes the controller checkout.

Argv: <root> <path> <allow_missing>, where allow_missing is "1" or "0".

Exits 0 when the path is a regular non-symlink file inside root, both lexically
and after canonicalization, or when it is absent and allow_missing is "1". Any
other outcome exits with a message naming the reason, so a bundle input can never
be read from outside the checkout that owns the deployment definitions.

Both the lexical and the canonical containment checks are required: the lexical
one rejects `..` traversal, and the canonical one rejects a symlinked ancestor
that points out of the checkout.
"""

import os
import stat
import sys


def main(argv):
    root, path, allow_missing = argv[1:]
    root = os.path.normpath(root)
    path = os.path.normpath(path)

    def refuse(message):
        raise SystemExit(f"Unsafe controller bundle input {path}: {message}")

    if not os.path.isabs(root) or not os.path.isabs(path):
        refuse("paths must be absolute")
    try:
        if os.path.commonpath([root, path]) != root:
            refuse(f"path escapes controller checkout {root}")
    except ValueError:
        refuse(f"path cannot be compared with controller checkout {root}")

    if not os.path.lexists(path):
        if allow_missing == "1":
            return 0
        refuse("required file does not exist")

    entry = os.lstat(path)
    if not stat.S_ISREG(entry.st_mode) or stat.S_ISLNK(entry.st_mode):
        refuse("must be a regular non-symlink file")

    canonical_root = os.path.realpath(root)
    canonical_path = os.path.realpath(path)
    try:
        if os.path.commonpath([canonical_root, canonical_path]) != canonical_root:
            refuse(f"canonical path escapes controller checkout {canonical_root}")
    except ValueError:
        refuse(
            f"canonical path cannot be compared with controller checkout {canonical_root}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
