#!/usr/bin/python
"""Atomically read a bounded regular file without following symlinks."""

from __future__ import annotations

import base64
import errno
import os
import stat

from ansible.module_utils.basic import AnsibleModule


class SafeReadError(Exception):
    """A value-free refusal to read unsafe state."""


def read_regular_file(path: str, max_bytes: int) -> tuple[bool, bytes]:
    """Open once without symlink traversal, then validate and read that descriptor."""
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_NONBLOCK"):
        raise SafeReadError("atomic nonblocking no-follow reads are unsupported on this target")

    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        return False, b""
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.EMLINK):
            raise SafeReadError("refused non-regular or linked file state") from None
        raise SafeReadError("could not safely open existing file state") from None

    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise SafeReadError("refused non-regular or linked file state")
        if metadata.st_size > max_bytes:
            raise SafeReadError("existing file exceeds the safe read limit")

        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65_536, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise SafeReadError("existing file exceeds the safe read limit")
        return True, b"".join(chunks)
    except OSError:
        raise SafeReadError("could not safely read existing file state") from None
    finally:
        os.close(descriptor)


def main() -> None:
    module = AnsibleModule(
        argument_spec={
            "path": {"type": "path", "required": True},
            "max_bytes": {"type": "int", "default": 1_048_576},
        },
        supports_check_mode=True,
    )
    max_bytes = module.params["max_bytes"]
    if max_bytes < 1:
        module.fail_json(msg="safe read limit must be positive")
    try:
        exists, content = read_regular_file(module.params["path"], max_bytes)
    except SafeReadError as error:
        module.fail_json(msg=str(error))
    module.exit_json(
        changed=False,
        exists=exists,
        content=base64.b64encode(content).decode("ascii"),
    )


if __name__ == "__main__":
    main()
