#!/usr/bin/env python3
"""Classify whether a clean Immich deployment needs a database restore."""

import argparse
from datetime import datetime
import gzip
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


BACKUP_NAME = re.compile(
    r"^immich-db-backup-(\d{8}T\d{6})-"
    r"v[0-9]+(?:\.[0-9]+)*-pg[0-9]+(?:\.[0-9]+)*\.sql\.gz$"
)
OUTPUT_KEYS = (
    "database",
    "originalsPresent",
    "restoreRequired",
    "backupFilename",
)


class Refusal(Exception):
    """A sanitized, operator-actionable classification failure."""


def parse_args():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--postgres-dir")
    parser.add_argument("--originals-root", required=True)
    parser.add_argument("--backup-dir")
    parser.add_argument("--failure-marker")
    parser.add_argument("--expected-uid", type=int)
    parser.add_argument("--expected-gid", type=int)
    parser.add_argument("--verify-assets-json")
    args = parser.parse_args()
    classification_values = (
        args.postgres_dir,
        args.backup_dir,
        args.failure_marker,
        args.expected_uid,
        args.expected_gid,
    )
    if args.verify_assets_json is None and any(value is None for value in classification_values):
        parser.error("classification arguments are required")
    if args.verify_assets_json is not None and any(
        value is not None for value in classification_values
    ):
        parser.error("verification and classification arguments may not be combined")
    return args


def _absolute_parts(path):
    candidate = Path(path)
    if not candidate.is_absolute() or any(part == ".." for part in candidate.parts):
        raise Refusal("unsafe-storage")
    return candidate.parts[1:]


def open_directory(path, *, missing_ok=False, category="unsafe-storage"):
    """Open an absolute directory without following any pathname symlink."""
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    parts = _absolute_parts(path)
    try:
        for index, part in enumerate(parts):
            try:
                child = os.open(
                    part,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=descriptor,
                )
            except FileNotFoundError:
                if missing_ok and index == len(parts) - 1:
                    os.close(descriptor)
                    return None
                raise Refusal(category) from None
            except OSError:
                raise Refusal(category) from None
            os.close(descriptor)
            descriptor = child
        return descriptor
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        raise


def open_child_directory(parent_fd, name, *, missing_ok=False, category):
    try:
        return os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
    except FileNotFoundError:
        if missing_ok:
            return None
        raise Refusal(category) from None
    except OSError:
        raise Refusal(category) from None


def marker_present(path):
    marker = Path(path)
    parts = _absolute_parts(marker)
    if not parts:
        raise Refusal("unsafe-storage")
    parent = marker.parent
    descriptor = open_directory(parent, category="unsafe-storage")
    try:
        try:
            metadata = os.stat(marker.name, dir_fd=descriptor, follow_symlinks=False)
        except FileNotFoundError:
            return False
        except OSError:
            raise Refusal("unsafe-storage") from None
        if not stat.S_ISREG(metadata.st_mode):
            raise Refusal("unsafe-storage")
        return True
    finally:
        os.close(descriptor)


def classify_database(path):
    descriptor = open_directory(path, missing_ok=True, category="unsafe-storage")
    if descriptor is None:
        return "fresh"
    try:
        try:
            return "existing" if os.listdir(descriptor) else "fresh"
        except OSError:
            raise Refusal("unsafe-storage") from None
    finally:
        os.close(descriptor)


def directory_has_regular_file(descriptor):
    try:
        entries = os.scandir(descriptor)
    except OSError:
        raise Refusal("unsafe-originals") from None
    with entries:
        for entry in entries:
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError:
                raise Refusal("unsafe-originals") from None
            if stat.S_ISREG(metadata.st_mode):
                return True
            if not stat.S_ISDIR(metadata.st_mode):
                raise Refusal("unsafe-originals")
            child = open_child_directory(
                descriptor, entry.name, category="unsafe-originals"
            )
            try:
                if directory_has_regular_file(child):
                    return True
            finally:
                os.close(child)
    return False


def originals_present(originals_root):
    immich_fd = open_directory(
        originals_root, missing_ok=True, category="unsafe-originals"
    )
    if immich_fd is None:
        return False
    try:
        for tree in ("upload", "library"):
            tree_fd = open_child_directory(
                immich_fd, tree, missing_ok=True, category="unsafe-originals"
            )
            if tree_fd is None:
                continue
            try:
                if directory_has_regular_file(tree_fd):
                    return True
            finally:
                os.close(tree_fd)
        return False
    finally:
        os.close(immich_fd)


def parse_backup_timestamp(name):
    match = BACKUP_NAME.fullmatch(name)
    if match is None:
        return None
    try:
        return datetime.strptime(match.group(1), "%Y%m%dT%H%M%S")
    except ValueError:
        return None


def validate_backup(descriptor, name, expected_uid, expected_gid):
    try:
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
    except OSError:
        raise Refusal("unsafe-newest-backup") from None
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != expected_uid
        or before.st_gid != expected_gid
        or before.st_mode & 0o022
        or before.st_size == 0
    ):
        raise Refusal("unsafe-newest-backup")

    try:
        backup_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=descriptor)
    except OSError:
        raise Refusal("unsafe-newest-backup") from None
    try:
        after = os.fstat(backup_fd)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise Refusal("unsafe-newest-backup")
        decompressed_size = 0
        with os.fdopen(backup_fd, "rb", closefd=False) as raw:
            with gzip.GzipFile(fileobj=raw, mode="rb") as stream:
                while True:
                    chunk = stream.read(1024 * 1024)
                    if not chunk:
                        break
                    decompressed_size += len(chunk)
        if decompressed_size == 0:
            raise Refusal("unsafe-newest-backup")
    except (EOFError, OSError, gzip.BadGzipFile):
        raise Refusal("unsafe-newest-backup") from None
    finally:
        os.close(backup_fd)


def select_backup(path, expected_uid, expected_gid):
    descriptor = open_directory(path, missing_ok=True, category="missing-safe-backup")
    if descriptor is None:
        raise Refusal("missing-safe-backup")
    try:
        try:
            candidates = [
                (timestamp, name)
                for name in os.listdir(descriptor)
                if (timestamp := parse_backup_timestamp(name)) is not None
            ]
        except OSError:
            raise Refusal("missing-safe-backup") from None
        if not candidates:
            raise Refusal("missing-safe-backup")
        newest_timestamp = max(timestamp for timestamp, _ in candidates)
        newest = [name for timestamp, name in candidates if timestamp == newest_timestamp]
        if len(newest) != 1:
            raise Refusal("ambiguous-newest-backup")
        validate_backup(descriptor, newest[0], expected_uid, expected_gid)
        return newest[0]
    finally:
        os.close(descriptor)


def verify_asset_path(immich_fd, original_path):
    path = PurePosixPath(original_path)
    parts = path.parts
    if (
        not path.is_absolute()
        or ".." in parts
        or len(parts) < 4
        or parts[:3] not in (("/", "data", "upload"), ("/", "data", "library"))
    ):
        raise Refusal("unsafe-restored-assets")
    descriptor = os.dup(immich_fd)
    try:
        for part in parts[2:-1]:
            child = open_child_directory(
                descriptor, part, category="unsafe-restored-assets"
            )
            os.close(descriptor)
            descriptor = child
        try:
            source_fd = os.open(
                parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=descriptor
            )
        except OSError:
            raise Refusal("unsafe-restored-assets") from None
        try:
            if not stat.S_ISREG(os.fstat(source_fd).st_mode):
                raise Refusal("unsafe-restored-assets")
            os.read(source_fd, 1)
        finally:
            os.close(source_fd)
    finally:
        os.close(descriptor)


def verify_assets(originals_root, source):
    if source != "-":
        raise Refusal("unsafe-restored-assets")
    try:
        assets = json.load(sys.stdin)
    except (UnicodeError, json.JSONDecodeError):
        raise Refusal("unsafe-restored-assets") from None
    if not isinstance(assets, list) or not 1 <= len(assets) <= 1000:
        raise Refusal("unsafe-restored-assets")

    immich_fd = open_directory(originals_root, category="unsafe-restored-assets")
    try:
        for asset in assets:
            if (
                not isinstance(asset, dict)
                or set(asset) != {"id", "originalPath"}
                or not isinstance(asset["id"], str)
                or not asset["id"]
                or not isinstance(asset["originalPath"], str)
            ):
                raise Refusal("unsafe-restored-assets")
            verify_asset_path(immich_fd, asset["originalPath"])
    finally:
        os.close(immich_fd)
    return {"verified": len(assets)}


def classify(args):
    if marker_present(args.failure_marker):
        raise Refusal("previous-failed-restore")
    database = classify_database(args.postgres_dir)
    present = originals_present(args.originals_root)
    restore_required = database == "fresh" and present
    backup = None
    if restore_required:
        backup = select_backup(args.backup_dir, args.expected_uid, args.expected_gid)
    return dict(zip(OUTPUT_KEYS, (database, present, restore_required, backup)))


def main():
    try:
        args = parse_args()
        if args.verify_assets_json is not None:
            document = verify_assets(args.originals_root, args.verify_assets_json)
        else:
            document = classify(args)
    except Refusal as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print("unsafe-storage", file=sys.stderr)
        return 1
    print(json.dumps(document, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
