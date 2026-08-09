import json
import os
import re
import stat
import sys


def refuse_payload(message):
    raise SystemExit(f"Unsafe deployment target payload: {message}")


def validate_target(root, expected_release, current, next_pointer, require_current, target):
    raw_root, raw_target = root, target
    root = os.path.normpath(root)
    target = os.path.normpath(target)
    expected_release = os.path.normpath(expected_release)
    allowed_pointers = {
        os.path.normpath(current),
        os.path.normpath(next_pointer),
    }

    def refuse(message):
        raise SystemExit(f"Unsafe deployment target {target}: {message}")

    if raw_root != root or raw_target != target:
        refuse("paths must be lexically normalized")
    if not os.path.isabs(root) or not os.path.isabs(target):
        refuse("paths must be absolute")
    try:
        if os.path.commonpath([root, target]) != root:
            refuse(f"path escapes storage root {root}")
    except ValueError:
        refuse(f"path cannot be compared with storage root {root}")

    root_cursor = os.path.abspath(os.sep)
    root_relative_parts = root[len(os.sep) :].split(os.sep)
    for component in root_relative_parts:
        root_cursor = os.path.join(root_cursor, component)
        if not os.path.lexists(root_cursor):
            refuse(f"storage-root ancestor {root_cursor} does not exist")
        root_stat = os.lstat(root_cursor)
        if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
            refuse(f"storage-root ancestor {root_cursor} must be a real directory")

    canonical_root = os.path.realpath(root)
    cursor = root
    nearest_existing = root
    relative_parts = os.path.relpath(target, root).split(os.sep)
    if relative_parts == ["."]:
        relative_parts = []

    for index, component in enumerate(relative_parts):
        cursor = os.path.join(cursor, component)
        if not os.path.lexists(cursor):
            break

        entry_stat = os.lstat(cursor)
        is_leaf = index == len(relative_parts) - 1
        if stat.S_ISLNK(entry_stat.st_mode):
            normalized_cursor = os.path.normpath(cursor)
            if normalized_cursor not in allowed_pointers:
                refuse(f"symlink component {cursor} is not an allowed deployment pointer")
            resolved_pointer = os.path.realpath(cursor)
            expected_canonical = os.path.realpath(expected_release)
            if (
                normalized_cursor == os.path.normpath(next_pointer)
                and resolved_pointer != expected_canonical
            ):
                refuse(
                    f"deployment pointer {cursor} does not resolve to {expected_release}"
                )
            if normalized_cursor == os.path.normpath(current):
                releases_root = os.path.realpath(os.path.dirname(expected_release))
                contained_release = (
                    os.path.dirname(resolved_pointer) == releases_root
                    and re.fullmatch(
                        r"[0-9a-f]{40}", os.path.basename(resolved_pointer)
                    )
                )
                if not contained_release:
                    refuse(f"current pointer {cursor} escapes versioned releases")
                if require_current == "1" and resolved_pointer != expected_canonical:
                    refuse(
                        f"current pointer {cursor} does not resolve to {expected_release}"
                    )
        elif not stat.S_ISDIR(entry_stat.st_mode) and not is_leaf:
            refuse(f"non-directory ancestor {cursor}")
        nearest_existing = cursor

    canonical_existing = os.path.realpath(nearest_existing)
    try:
        if os.path.commonpath([canonical_root, canonical_existing]) != canonical_root:
            refuse(f"canonical ancestor {canonical_existing} escapes {canonical_root}")
    except ValueError:
        refuse(f"canonical ancestor cannot be compared with {canonical_root}")


def main(argv):
    root, expected_release, current, next_pointer, require_current, paths_json = argv
    try:
        paths = json.loads(paths_json)
    except json.JSONDecodeError:
        refuse_payload("invalid JSON")
    if not isinstance(paths, list):
        refuse_payload("expected a JSON array")
    for index, target in enumerate(paths):
        if not isinstance(target, str):
            refuse_payload(f"target at index {index} must be a string")

    for target in paths:
        validate_target(
            root,
            expected_release,
            current,
            next_pointer,
            require_current,
            target,
        )


if __name__ == "__main__":
    main(sys.argv[1:])
