#!/usr/bin/env python3
"""Behavior contract for Immich clean-deployment restore classification."""

import gzip
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CLASSIFIER = ROOT / "roles" / "immich" / "files" / "classify_restore.py"
VALID_NAME = "immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz"


class ClassifierFixture:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.postgres = self.root / "docker" / "immich" / "postgres"
        self.media = self.root / "media"
        self.backups = self.media / "Immich-backups" / "database"
        self.marker = self.root / "docker" / "immich" / ".restore-failed"
        self.postgres.mkdir(parents=True)
        self.backups.mkdir(parents=True)

    @property
    def originals(self):
        return self.media / "Immich" / "upload"

    def add_original(self, name="library/admin/asset.jpg", content=b"asset"):
        path = self.originals / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def add_backup(self, name=VALID_NAME, content=b"SELECT 1;\n"):
        path = self.backups / name
        with gzip.open(path, "wb") as stream:
            stream.write(content)
        return path

    def run(self, *, expected_uid=None, expected_gid=None):
        command = [
            "python3",
            str(CLASSIFIER),
            "--postgres-dir",
            str(self.postgres),
            "--media-root",
            str(self.media),
            "--backup-dir",
            str(self.backups),
            "--failure-marker",
            str(self.marker),
            "--expected-uid",
            str(os.getuid() if expected_uid is None else expected_uid),
            "--expected-gid",
            str(os.getgid() if expected_gid is None else expected_gid),
        ]
        return subprocess.run(command, text=True, capture_output=True, check=False)

    def verify_assets(self, assets):
        return subprocess.run(
            [
                "python3",
                str(CLASSIFIER),
                "--verify-assets-json",
                "-",
                "--media-root",
                str(self.media),
            ],
            input=json.dumps(assets),
            text=True,
            capture_output=True,
            check=False,
        )

    def classify(self, **kwargs):
        result = self.run(**kwargs)
        if result.returncode != 0:
            raise AssertionError(
                f"classifier failed rc={result.returncode}: {result.stderr!r}"
            )
        self._assert_strict_output(result)
        return json.loads(result.stdout)

    @staticmethod
    def _assert_strict_output(result):
        if result.stderr:
            raise AssertionError(f"successful classifier wrote stderr: {result.stderr!r}")
        document = json.loads(result.stdout)
        expected_keys = {
            "database",
            "originalsPresent",
            "restoreRequired",
            "backupFilename",
        }
        if set(document) != expected_keys:
            raise AssertionError(f"unexpected output keys: {set(document)!r}")


class ImmichRestoreClassifierTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.fixture = ClassifierFixture(Path(self.temporary.name))

    def tearDown(self):
        self.temporary.cleanup()

    def assert_refused(self, category, **kwargs):
        result = self.fixture.run(**kwargs)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.strip(), category)
        self.assertNotIn(str(self.fixture.root), result.stderr)
        return result

    def test_fresh_database_without_originals_uses_normal_initialization(self):
        self.assertEqual(
            self.fixture.classify(),
            {
                "database": "fresh",
                "originalsPresent": False,
                "restoreRequired": False,
                "backupFilename": None,
            },
        )

    def test_fresh_database_with_originals_requires_newest_backup(self):
        self.fixture.add_original()
        self.fixture.add_backup(
            "immich-db-backup-20260814T235959-v3.1.0-pg14.19.sql.gz"
        )
        self.fixture.add_backup(VALID_NAME)
        self.assertEqual(
            self.fixture.classify(),
            {
                "database": "fresh",
                "originalsPresent": True,
                "restoreRequired": True,
                "backupFilename": VALID_NAME,
            },
        )

    def test_existing_database_never_restores_without_originals(self):
        (self.fixture.postgres / "PG_VERSION").write_text("14\n")
        self.assertEqual(
            self.fixture.classify(),
            {
                "database": "existing",
                "originalsPresent": False,
                "restoreRequired": False,
                "backupFilename": None,
            },
        )

    def test_existing_database_never_restores_with_originals(self):
        (self.fixture.postgres / "PG_VERSION").write_text("14\n")
        self.fixture.add_original()
        self.fixture.add_backup()
        classification = self.fixture.classify()
        self.assertEqual(classification["database"], "existing")
        self.assertTrue(classification["originalsPresent"])
        self.assertFalse(classification["restoreRequired"])
        self.assertIsNone(classification["backupFilename"])

    def test_existing_database_ignores_irrelevant_corrupt_backup(self):
        (self.fixture.postgres / "PG_VERSION").write_text("14\n")
        self.fixture.add_original()
        (self.fixture.backups / VALID_NAME).write_bytes(b"not gzip")
        self.assertEqual(self.fixture.classify()["database"], "existing")

    def test_originals_without_backup_are_refused(self):
        self.fixture.add_original()
        self.assert_refused("missing-safe-backup")

    def test_noncanonical_backup_names_are_not_candidates(self):
        self.fixture.add_original()
        for name in (
            "uploaded.sql.gz",
            "restore-point-20260815.sql.gz",
            "immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql",
            "immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz.tmp",
            "../escape.sql.gz",
        ):
            if "/" not in name:
                self.fixture.add_backup(name)
        self.assert_refused("missing-safe-backup")

    def test_invalid_calendar_timestamp_is_not_a_candidate(self):
        self.fixture.add_original()
        self.fixture.add_backup(
            "immich-db-backup-20261340T256199-v3.1.0-pg14.19.sql.gz"
        )
        self.assert_refused("missing-safe-backup")

    def test_ambiguous_newest_timestamp_is_refused(self):
        self.fixture.add_original()
        self.fixture.add_backup(VALID_NAME)
        self.fixture.add_backup(
            "immich-db-backup-20260815T010000-v3.1.1-pg14.20.sql.gz"
        )
        self.assert_refused("ambiguous-newest-backup")

    def test_unsafe_newest_backup_does_not_fall_back(self):
        self.fixture.add_original()
        self.fixture.add_backup(
            "immich-db-backup-20260814T010000-v3.1.0-pg14.19.sql.gz"
        )
        newest = self.fixture.backups / VALID_NAME
        newest.write_bytes(b"not gzip")
        self.assert_refused("unsafe-newest-backup")

    def test_symlink_backup_is_refused(self):
        self.fixture.add_original()
        target = self.fixture.root / "outside.sql.gz"
        with gzip.open(target, "wb") as stream:
            stream.write(b"SELECT 1;\n")
        (self.fixture.backups / VALID_NAME).symlink_to(target)
        self.assert_refused("unsafe-newest-backup")

    def test_nonregular_backup_is_refused(self):
        self.fixture.add_original()
        (self.fixture.backups / VALID_NAME).mkdir()
        self.assert_refused("unsafe-newest-backup")

    def test_wrong_owner_backup_is_refused(self):
        self.fixture.add_original()
        self.fixture.add_backup()
        self.assert_refused("unsafe-newest-backup", expected_uid=os.getuid() + 1)

    def test_wrong_group_backup_is_refused(self):
        self.fixture.add_original()
        self.fixture.add_backup()
        self.assert_refused("unsafe-newest-backup", expected_gid=os.getgid() + 1)

    def test_group_or_world_writable_backup_is_refused(self):
        self.fixture.add_original()
        backup = self.fixture.add_backup()
        backup.chmod(0o660)
        self.assert_refused("unsafe-newest-backup")
        backup.chmod(0o606)
        self.assert_refused("unsafe-newest-backup")

    def test_empty_backup_is_refused(self):
        self.fixture.add_original()
        (self.fixture.backups / VALID_NAME).touch()
        self.assert_refused("unsafe-newest-backup")

    def test_invalid_gzip_and_trailing_junk_are_refused(self):
        self.fixture.add_original()
        backup = self.fixture.backups / VALID_NAME
        backup.write_bytes(b"not gzip")
        self.assert_refused("unsafe-newest-backup")
        self.fixture.add_backup()
        with backup.open("ab") as stream:
            stream.write(b"trailing junk")
        self.assert_refused("unsafe-newest-backup")

    def test_present_failure_marker_stops_classification(self):
        self.fixture.marker.write_text('{"version":1,"stage":"restore"}\n')
        self.fixture.marker.chmod(0o600)
        self.assert_refused("previous-failed-restore")

    def test_symlinked_storage_roots_are_refused(self):
        real_postgres = self.fixture.root / "real-postgres"
        real_postgres.mkdir()
        self.fixture.postgres.rmdir()
        self.fixture.postgres.symlink_to(real_postgres, target_is_directory=True)
        self.assert_refused("unsafe-storage")

    def test_symlink_and_special_entries_under_originals_are_refused(self):
        outside = self.fixture.root / "outside.jpg"
        outside.write_bytes(b"outside")
        self.fixture.originals.mkdir(parents=True)
        (self.fixture.originals / "asset.jpg").symlink_to(outside)
        self.assert_refused("unsafe-originals")
        (self.fixture.originals / "asset.jpg").unlink()
        fifo = self.fixture.originals / "asset.fifo"
        os.mkfifo(fifo)
        self.assertTrue(stat.S_ISFIFO(fifo.lstat().st_mode))
        self.assert_refused("unsafe-originals")

    def test_scan_stops_after_first_safe_regular_original(self):
        self.fixture.add_original("00-first.jpg")
        (self.fixture.originals / "99-unsafe").symlink_to(self.fixture.root)
        self.fixture.add_backup()
        self.assertTrue(self.fixture.classify()["originalsPresent"])

    def test_restored_asset_sample_requires_readable_internal_originals(self):
        original = self.fixture.add_original("library/admin/asset.jpg")
        original.chmod(0o600)
        result = self.fixture.verify_assets(
            [{"id": "safe-id", "originalPath": "/data/upload/library/admin/asset.jpg"}]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"verified": 1})

    def test_restored_asset_sample_rejects_escape_and_noninternal_paths(self):
        for path in (
            "/etc/passwd",
            "/data/../etc/passwd",
            "/data/thumbs/asset.webp",
            "/data/upload/../../outside.jpg",
            "data/upload/asset.jpg",
        ):
            with self.subTest(path=path):
                result = self.fixture.verify_assets(
                    [{"id": "unsafe-id", "originalPath": path}]
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr.strip(), "unsafe-restored-assets")

    def test_restored_asset_sample_rejects_symlink_or_missing_source(self):
        self.fixture.originals.mkdir(parents=True)
        outside = self.fixture.root / "outside.jpg"
        outside.write_bytes(b"outside")
        (self.fixture.originals / "linked.jpg").symlink_to(outside)
        for path in ("/data/upload/linked.jpg", "/data/upload/missing.jpg"):
            with self.subTest(path=path):
                result = self.fixture.verify_assets(
                    [{"id": "unsafe-id", "originalPath": path}]
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stderr.strip(), "unsafe-restored-assets")

    def test_restored_asset_sample_requires_exact_bounded_json_shape(self):
        for payload in (
            {},
            [{"id": "id"}],
            [{"id": "id", "originalPath": "/data/upload/x", "extra": True}],
            [{"id": "", "originalPath": "/data/upload/x"}],
        ):
            with self.subTest(payload=payload):
                result = self.fixture.verify_assets(payload)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stderr.strip(), "unsafe-restored-assets")


if __name__ == "__main__":
    unittest.main()
