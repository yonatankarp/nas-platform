#!/usr/bin/env python3
"""Behavior contract for Immich clean-deployment restore classification."""

import gzip
import importlib.util
import itertools
import json
import os
from pathlib import Path
import resource
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
CLASSIFIER = ROOT / "services" / "immich" / "classify_restore.py"
VALID_NAME = "immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz"
CLASSIFIER_SPEC = importlib.util.spec_from_file_location(
    "immich_restore_classifier", CLASSIFIER
)
CLASSIFIER_MODULE = importlib.util.module_from_spec(CLASSIFIER_SPEC)
CLASSIFIER_SPEC.loader.exec_module(CLASSIFIER_MODULE)


class ScandirSequence:
    def __init__(self, entries):
        self.entries = iter(entries)
        self.request_count = 0

    def __enter__(self):
        return self

    def __exit__(self, _type, _value, _traceback):
        return False

    def __iter__(self):
        return self

    def __next__(self):
        self.request_count += 1
        return next(self.entries)


class FakeScandirEntry:
    def __init__(self, name, mode):
        self.name = name
        self.mode = mode
        self.stat_calls = 0

    def stat(self, *, follow_symlinks):
        if follow_symlinks:
            raise AssertionError("original traversal followed a directory entry")
        self.stat_calls += 1
        return os.stat_result((self.mode, 0, 0, 0, 0, 0, 1, 0, 0, 0))


class ClassifierFixture:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.postgres = self.root / "docker" / "immich" / "postgres"
        self.media = self.root / "media"
        self.originals_root = self.media / "Immich"
        self.backups = self.media / "Immich-backups" / "database"
        self.marker = self.root / "docker" / "immich" / ".restore-failed"
        self.postgres.mkdir(parents=True)
        self.backups.mkdir(parents=True)

    @property
    def originals(self):
        return self.originals_root / "upload"

    def add_original(self, name="library/admin/asset.jpg", content=b"asset"):
        path = self.originals / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def add_backup(self, name=VALID_NAME, content=b"SELECT 1;\n"):
        path = self.backups / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with gzip.open(path, "wb") as stream:
            stream.write(content)
        return path

    def run(
        self,
        *,
        expected_uid=None,
        expected_gid=None,
        expected_postgres_major=14,
        descriptor_limit=None,
    ):
        command = [
            "python3",
            str(CLASSIFIER),
            "--postgres-dir",
            str(self.postgres),
            "--originals-root",
            str(self.originals_root),
            "--backup-dir",
            str(self.backups),
            "--failure-marker",
            str(self.marker),
            "--expected-uid",
            str(os.getuid() if expected_uid is None else expected_uid),
            "--expected-gid",
            str(os.getgid() if expected_gid is None else expected_gid),
            "--expected-immich-version",
            "3.1.0",
            "--expected-postgres-major",
            str(expected_postgres_major),
        ]
        # Bounded so a classifier blocked on an open reports as a failure
        # rather than hanging the suite.
        def limit_descriptors():
            if descriptor_limit is not None:
                resource.setrlimit(
                    resource.RLIMIT_NOFILE, (descriptor_limit, descriptor_limit)
                )

        return subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
            preexec_fn=limit_descriptors,
        )

    def verify_assets(self, assets):
        return subprocess.run(
            [
                "python3",
                str(CLASSIFIER),
                "--verify-assets-json",
                "-",
                "--originals-root",
                str(self.originals_root),
            ],
            input=json.dumps(assets),
            text=True,
            capture_output=True,
            check=False,
        )

    def age_originals(self, mtime):
        """Date every real directory and file under the originals root.

        os.walk does not descend into a symlinked directory, and only the
        directories it yields are touched, so no link target is re-dated.
        """
        for directory, _dirs, files in os.walk(self.originals_root):
            for name in files:
                path = Path(directory) / name
                if not path.is_symlink():
                    os.utime(path, (mtime, mtime))
            os.utime(directory, (mtime, mtime))

    def classify(self, *, warning="", **kwargs):
        result = self.run(**kwargs)
        if result.returncode != 0:
            raise AssertionError(
                f"classifier failed rc={result.returncode}: {result.stderr!r}"
            )
        self._assert_strict_output(result, warning)
        return json.loads(result.stdout)

    @staticmethod
    def _assert_strict_output(result, warning=""):
        if result.stderr.strip() != warning:
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

    def test_absent_database_directory_is_fresh(self):
        self.fixture.postgres.rmdir()
        self.assertEqual(self.fixture.classify()["database"], "fresh")

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

    def test_adopted_existing_database_never_uses_normal_restore_inputs(self):
        normal_original = self.fixture.add_original("normal-only.jpg")
        self.fixture.add_backup()
        adopted = self.fixture.root / "adoption" / "legacy" / "immich"
        self.fixture.postgres = adopted / "postgres"
        self.fixture.originals_root = adopted / "data"
        self.fixture.backups = adopted / "backups"
        self.fixture.marker = adopted / ".restore-failed"
        self.fixture.postgres.mkdir(parents=True)
        (self.fixture.postgres / "PG_VERSION").write_text("14\n")
        self.fixture.backups.mkdir(parents=True)

        self.assertTrue(normal_original.is_file())
        self.assertEqual(
            self.fixture.classify(),
            {
                "database": "existing",
                "originalsPresent": False,
                "restoreRequired": False,
                "backupFilename": None,
            },
        )

    def test_adopted_fresh_database_selects_only_adopted_backup(self):
        self.fixture.add_original("normal-only.jpg")
        self.fixture.add_backup("immich-db-backup-20260816T010000-v3.1.0-pg14.19.sql.gz")
        adopted = self.fixture.root / "adoption" / "legacy" / "immich"
        self.fixture.postgres = adopted / "postgres"
        self.fixture.originals_root = adopted / "data"
        self.fixture.backups = adopted / "backups"
        self.fixture.marker = adopted / ".restore-failed"
        self.fixture.postgres.mkdir(parents=True)
        self.fixture.add_original("adopted.jpg")
        self.fixture.add_backup(VALID_NAME)

        classification = self.fixture.classify()
        self.assertTrue(classification["restoreRequired"])
        self.assertEqual(classification["backupFilename"], VALID_NAME)

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

    def test_incompatible_newest_immich_version_does_not_fall_back(self):
        self.fixture.add_original()
        self.fixture.add_backup(
            "immich-db-backup-20260814T010000-v3.1.0-pg14.19.sql.gz"
        )
        self.fixture.add_backup(
            "immich-db-backup-20260815T010000-v3.2.0-pg14.19.sql.gz"
        )
        self.assert_refused("incompatible-newest-backup")

    def test_incompatible_newest_postgres_major_does_not_fall_back(self):
        self.fixture.add_original()
        self.fixture.add_backup(
            "immich-db-backup-20260814T010000-v3.1.0-pg14.19.sql.gz"
        )
        self.fixture.add_backup(
            "immich-db-backup-20260815T010000-v3.1.0-pg15.1.sql.gz"
        )
        self.assert_refused("incompatible-newest-backup")

    # A plain-SQL dump loads forward into a newer major and not backward, so a
    # repin of the database image restores the dump the older major just wrote.
    def test_older_postgres_major_backup_restores_into_newer_pin(self):
        self.fixture.add_original()
        self.fixture.add_backup(VALID_NAME)
        classification = self.fixture.classify(expected_postgres_major=17)
        self.assertTrue(classification["restoreRequired"])
        self.assertEqual(classification["backupFilename"], VALID_NAME)

    def test_newer_postgres_major_backup_is_refused(self):
        self.fixture.add_original()
        self.fixture.add_backup(
            "immich-db-backup-20260815T010000-v3.1.0-pg18.4.sql.gz"
        )
        self.assert_refused("incompatible-newest-backup", expected_postgres_major=17)

    def test_existing_database_of_another_postgres_major_is_refused(self):
        for data_major in ("13", "15"):
            with self.subTest(data_major=data_major):
                (self.fixture.postgres / "PG_VERSION").write_text(data_major + "\n")
                self.assert_refused("postgres-major-mismatch")

    def test_existing_database_major_is_checked_before_originals(self):
        (self.fixture.postgres / "PG_VERSION").write_text("14\n")
        self.fixture.add_original()
        self.assert_refused("postgres-major-mismatch", expected_postgres_major=17)

    def test_existing_database_without_readable_postgres_version_is_refused(self):
        version = self.fixture.postgres / "PG_VERSION"
        (self.fixture.postgres / "base").mkdir()
        self.assert_refused("unreadable-postgres-version")
        version.write_text("fourteen\n")
        self.assert_refused("unreadable-postgres-version")
        version.unlink()
        version.mkdir()
        self.assert_refused("unreadable-postgres-version")
        version.rmdir()
        outside = self.fixture.root / "outside-version"
        outside.write_text("14\n")
        version.symlink_to(outside)
        self.assert_refused("unreadable-postgres-version")

    # A deploy account that can list the cluster but not read its version is
    # no worse off than before the major was checked at all, so it proceeds and
    # says so rather than stalling every deployment on an unmeasured permission.
    @unittest.skipIf(os.geteuid() == 0, "root reads a mode-0 file")
    def test_permission_denied_postgres_version_proceeds_unverified(self):
        version = self.fixture.postgres / "PG_VERSION"
        version.write_text("13\n")
        version.chmod(0)
        try:
            classification = self.fixture.classify(
                warning="postgres-version-unverified"
            )
        finally:
            version.chmod(0o600)
        self.assertEqual(classification["database"], "existing")
        self.assertFalse(classification["restoreRequired"])

    def test_fifo_postgres_version_is_refused_without_blocking(self):
        os.mkfifo(self.fixture.postgres / "PG_VERSION")
        self.assert_refused("unreadable-postgres-version")

    # A storage-template move renames originals into new folders. rename(2)
    # keeps the file's own mtime, so only the directories it touched show that
    # the originals changed after the dump was written (#900).
    def stale_fixture(self):
        self.fixture.add_original("00-first.jpg")
        self.fixture.add_original("library/admin/asset.jpg")
        backup = self.fixture.add_backup()
        now = backup.stat().st_mtime
        self.fixture.age_originals(now - 7200)
        os.utime(backup, (now - 3600, now - 3600))
        return backup

    def test_originals_moved_after_the_dump_refuse_it_as_stale(self):
        self.stale_fixture()
        moved = self.fixture.originals_root / "library" / "admin" / "Album"
        moved.mkdir(parents=True)
        (self.fixture.originals / "library" / "admin" / "asset.jpg").rename(
            moved / "asset.jpg"
        )
        self.assertLess(
            (moved / "asset.jpg").stat().st_mtime,
            (self.fixture.backups / VALID_NAME).stat().st_mtime,
        )
        self.assert_refused("stale-newest-backup")

    def test_originals_all_older_than_the_dump_restore_it(self):
        self.stale_fixture()
        classification = self.fixture.classify()
        self.assertTrue(classification["restoreRequired"])
        self.assertEqual(classification["backupFilename"], VALID_NAME)

    def test_touching_the_dump_accepts_it(self):
        backup = self.stale_fixture()
        (self.fixture.originals / "late.jpg").write_bytes(b"late")
        self.assert_refused("stale-newest-backup")
        os.utime(backup)
        self.assertTrue(self.fixture.classify()["restoreRequired"])

    # Only directory mtimes are read: Immich rewrites its .immich mount-check
    # file in place on every start, which moves no path a row could name.
    def test_an_original_rewritten_in_place_is_not_a_stale_dump(self):
        self.stale_fixture()
        os.utime(self.fixture.originals / "00-first.jpg")
        self.assertTrue(self.fixture.classify()["restoreRequired"])

    def test_existing_database_never_reads_dump_age(self):
        (self.fixture.postgres / "PG_VERSION").write_text("14\n")
        self.stale_fixture()
        (self.fixture.originals / "late.jpg").write_bytes(b"late")
        self.assertEqual(self.fixture.classify()["database"], "existing")

    def test_symlinked_directory_under_originals_is_not_followed(self):
        backup = self.stale_fixture()
        outside = self.fixture.root / "outside-directory"
        outside.mkdir()
        (self.fixture.originals_root / "library").mkdir()
        (self.fixture.originals_root / "library" / "linked").symlink_to(
            outside, target_is_directory=True
        )
        self.fixture.age_originals(backup.stat().st_mtime - 3600)
        (outside / "new.jpg").write_bytes(b"new")
        self.assertGreater(outside.stat().st_mtime, backup.stat().st_mtime)
        self.assertTrue(self.fixture.classify()["restoreRequired"])

    def test_scan_cap_reached_without_a_newer_directory_proceeds(self):
        backup = self.stale_fixture()
        for name in ("upload", "library"):
            path = self.fixture.originals_root / name
            for child in sorted(path.rglob("*"), reverse=True):
                child.rmdir() if child.is_dir() else child.unlink()
        self.fixture.add_original("00-first.jpg")
        deep = self.fixture.originals_root / "library" / "deep"
        (deep / "newer").mkdir(parents=True)
        dated = backup.stat().st_mtime
        self.fixture.age_originals(dated - 3600)
        os.utime(deep / "newer")
        self.assert_refused("stale-newest-backup")
        with mock.patch.object(CLASSIFIER_MODULE, "STALE_SCAN_ENTRY_CAP", 1):
            self.assertFalse(
                CLASSIFIER_MODULE.originals_changed_since(
                    str(self.fixture.originals_root), dated
                )
            )
        with mock.patch.object(CLASSIFIER_MODULE, "STALE_SCAN_ENTRY_CAP", 3):
            self.assertTrue(
                CLASSIFIER_MODULE.originals_changed_since(
                    str(self.fixture.originals_root), dated
                )
            )

    # Only the ancestor chain is held open, so a wide library does not run the
    # walk out of descriptors and misreport that as unsafe originals.
    def test_wide_originals_tree_scans_within_a_small_descriptor_limit(self):
        backup = self.stale_fixture()
        for index in range(300):
            (self.fixture.originals_root / "library" / "admin" / f"a{index}").mkdir(
                parents=True
            )
        self.fixture.age_originals(backup.stat().st_mtime - 3600)
        classification = self.fixture.classify(descriptor_limit=64)
        self.assertTrue(classification["restoreRequired"])

    def test_stale_scan_stops_at_the_first_newer_directory(self):
        self.stale_fixture()
        scans = []
        real_scandir = os.scandir

        def counting_scandir(descriptor):
            scans.append(descriptor)
            return real_scandir(descriptor)

        os.utime(self.fixture.originals)
        for index in range(50):
            (self.fixture.originals_root / "library" / f"d{index}").mkdir(parents=True)
        self.fixture.age_originals(0)
        os.utime(self.fixture.originals)
        with mock.patch.object(CLASSIFIER_MODULE.os, "scandir", counting_scandir):
            self.assertTrue(
                CLASSIFIER_MODULE.originals_changed_since(
                    str(self.fixture.originals_root), 1
                )
            )
        self.assertEqual(scans, [])

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

    def test_permission_denied_original_traversal_is_refused(self):
        denied = self.fixture.originals / "denied"
        denied.mkdir(parents=True)
        denied.chmod(0)
        try:
            self.assert_refused("unsafe-originals")
        finally:
            denied.chmod(0o700)

    def test_scan_stops_after_first_safe_regular_original(self):
        self.fixture.add_original("00-first.jpg")
        for index in range(2000):
            (self.fixture.originals / f"later-{index:04d}.jpg").write_bytes(b"asset")
        self.fixture.add_backup()
        self.assertTrue(self.fixture.classify()["originalsPresent"])

    def test_streaming_scan_never_requests_entries_after_first_safe_original(self):
        first = FakeScandirEntry("first.jpg", stat.S_IFREG | 0o600)
        later = FakeScandirEntry("later-symlink", stat.S_IFLNK | 0o777)
        entries = itertools.chain([first], itertools.repeat(later, 100_000))
        scan = ScandirSequence(entries)
        with mock.patch.object(CLASSIFIER_MODULE.os, "scandir", return_value=scan):
            self.assertTrue(CLASSIFIER_MODULE.directory_has_regular_file(123))
        self.assertEqual(scan.request_count, 1)
        self.assertEqual(first.stat_calls, 1)
        self.assertEqual(later.stat_calls, 0)

    def test_streaming_scan_refuses_unsafe_entry_encountered_before_original(self):
        unsafe = FakeScandirEntry("linked.jpg", stat.S_IFLNK | 0o777)
        safe = FakeScandirEntry("safe.jpg", stat.S_IFREG | 0o600)
        scan = ScandirSequence([unsafe, safe])
        with mock.patch.object(CLASSIFIER_MODULE.os, "scandir", return_value=scan):
            with self.assertRaisesRegex(CLASSIFIER_MODULE.Refusal, "unsafe-originals"):
                CLASSIFIER_MODULE.directory_has_regular_file(123)
        self.assertEqual(scan.request_count, 1)
        self.assertEqual(safe.stat_calls, 0)

    def test_original_traversal_documents_its_early_stop_safety_policy(self):
        policy = CLASSIFIER_MODULE.directory_has_regular_file.__doc__ or ""
        for requirement in (
            "streaming",
            "encountered before",
            "first safe regular file",
            "not inspected",
        ):
            self.assertIn(requirement, policy)

    def test_restored_asset_sample_requires_readable_internal_originals(self):
        original = self.fixture.add_original("library/admin/asset.jpg")
        original.chmod(0o600)
        result = self.fixture.verify_assets(
            [{"id": "safe-id", "originalPath": "/data/upload/library/admin/asset.jpg"}]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"verified": 1, "missing": 0})

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

    # A missing source is counted rather than refused on the first, so the role
    # can say how many of the sample failed; it still refuses on any (#900).
    # The count is all that is reported: no path leaves the helper.
    def test_restored_asset_sample_counts_symlink_or_missing_sources(self):
        self.fixture.add_original("present.jpg")
        outside = self.fixture.root / "outside.jpg"
        outside.write_bytes(b"outside")
        (self.fixture.originals / "linked.jpg").symlink_to(outside)
        (self.fixture.originals / "album").symlink_to(
            self.fixture.originals, target_is_directory=True
        )
        result = self.fixture.verify_assets(
            [
                {"id": "a", "originalPath": "/data/upload/present.jpg"},
                {"id": "b", "originalPath": "/data/upload/linked.jpg"},
                {"id": "c", "originalPath": "/data/upload/missing.jpg"},
                {"id": "d", "originalPath": "/data/upload/album/present.jpg"},
                {"id": "e", "originalPath": "/data/library/gone/x.jpg"},
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(result.stdout), {"verified": 1, "missing": 4})
        self.assertNotIn("present", result.stdout)

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
