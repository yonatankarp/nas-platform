#!/usr/bin/env python3
"""Refuse a controller bundle input that escapes the controller checkout.

Argv: <root> <path> <allow_missing>, or --batch <root> <json> with [<path>, <allow_missing>]
pairs checked in order (#333). The batch stops at the first refusal, whose message
tests/integration_controller.sh greps for. Both lexical (`..`) and canonical
(symlinked ancestor) containment are required.
"""

import json
import os
import stat
import sys


# The single-input check; the batch calls exactly this once per input.
def validate_input(root, path, allow_missing):
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


# An empty or malformed batch is refused: [] would otherwise validate nothing, green.
def validate_batch(root, entries):
    if not isinstance(entries, list) or not entries:
        raise SystemExit(
            "Unsafe controller bundle input batch: expected a nonempty list of inputs"
        )
    for entry in entries:
        if (
            not isinstance(entry, list)
            or len(entry) != 2
            or not all(isinstance(field, str) for field in entry)
        ):
            raise SystemExit(
                "Unsafe controller bundle input batch: "
                f"expected a [path, allow_missing] pair, read {entry!r}"
            )
        path, allow_missing = entry
        validate_input(root, path, allow_missing)
    return 0


def main(argv):
    if argv[1] == "--batch":
        root, raw_entries = argv[2:4]
        try:
            entries = json.loads(raw_entries)
        except ValueError as error:
            raise SystemExit(
                f"Unsafe controller bundle input batch: input list is not JSON: {error}"
            ) from error
        return validate_batch(root, entries)

    root, path, allow_missing = argv[1:4]
    return validate_input(root, path, allow_missing)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
