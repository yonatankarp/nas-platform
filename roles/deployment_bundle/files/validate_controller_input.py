#!/usr/bin/env python3
"""Refuse a controller bundle input that escapes the controller checkout.

Argv: <root> <path> <allow_missing>, where allow_missing is "1" or "0".

Batch argv: --batch <root> <json>, where json is an array of
[<path>, <allow_missing>] pairs validated in the order given. One invocation
validating N inputs replaces N invocations validating one each: the role used to
include a task per input and spent a serial Python subprocess on every one of
them, which made this the largest cross-cutting cost of every integration lane
(#333). The batch stops at the first refusal and emits that input's message
verbatim, so the diagnostic an operator reads is the same one a single-path
invocation produced, naming the same path -- which is what
tests/integration_controller.sh greps for, and what was load-bearing during
#326/#329.

Exits 0 when the path is a regular non-symlink file inside root, both lexically
and after canonicalization, or when it is absent and allow_missing is "1". Any
other outcome exits with a message naming the reason, so a bundle input can never
be read from outside the checkout that owns the deployment definitions.

Both the lexical and the canonical containment checks are required: the lexical
one rejects `..` traversal, and the canonical one rejects a symlinked ancestor
that points out of the checkout.
"""

import json
import os
import stat
import sys


# The single-input containment check, unchanged from when it was the whole
# program and reached only through the three-argument form. The batch entry point
# calls exactly this, once per input, so batching cannot alter what any one input
# is held to or what refusing it says.
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


# An empty batch is refused rather than accepted trivially: both call sites name
# at least two inputs, so nothing legitimate passes none, and an expression that
# collapsed to [] would otherwise leave the task green while validating nothing.
# A malformed entry is refused for the same reason -- fail closed and say so,
# rather than unpack it and exit on a traceback.
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
