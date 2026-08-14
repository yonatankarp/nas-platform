#!/usr/bin/env python3

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "roles"
    / "deployment_bundle"
    / "files"
    / "validate_target.py"
)
RELEASE_ID = "1" * 40
OTHER_RELEASE_ID = "2" * 40


class DeploymentTargetValidatorTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.base = Path(os.path.realpath(self.temporary_directory.name))
        self.root = self.base / "storage"
        self.media_root = self.base / "media"
        self.deploy_root = self.root / "nas-platform"
        self.releases = self.deploy_root / "releases"
        self.expected_release = self.releases / RELEASE_ID
        self.current = self.deploy_root / "current"
        self.next_pointer = self.deploy_root / f".current-{RELEASE_ID}"
        self.adoption_root = self.base / "adoption"
        self.expected_release.mkdir(parents=True)
        self.media_root.mkdir()

    def run_validator(
        self,
        paths,
        *,
        require_current="0",
        paths_json=None,
        adoption_enabled="0",
        adoption_root=None,
        storage_root=None,
        media_root=None,
    ):
        payload = json.dumps(paths) if paths_json is None else paths_json
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(storage_root or self.root),
                str(media_root or self.media_root),
                str(self.expected_release),
                str(self.current),
                str(self.next_pointer),
                require_current,
                payload,
                str(adoption_root or self.adoption_root),
                adoption_enabled,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_refused(self, result, message):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_accepts_multiple_safe_targets_in_one_json_array(self):
        result = self.run_validator(
            [
                str(self.root),
                str(self.deploy_root),
                str(self.expected_release),
                str(self.deploy_root / "runtime" / "services" / "paperless"),
            ]
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_lexical_escape_and_names_exact_target(self):
        escaped_target = str(self.base / "outside")

        result = self.run_validator([str(self.root), escaped_target])

        self.assert_refused(
            result,
            f"Unsafe deployment target {escaped_target}: "
            f"path escapes storage root {self.root}",
        )

    def test_rejects_storage_root_ancestor_symlink(self):
        real_storage = self.base / "real-storage"
        real_storage.mkdir()
        linked_storage = self.base / "linked-storage"
        linked_storage.symlink_to(real_storage, target_is_directory=True)
        target = linked_storage / "nas-platform"

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(linked_storage),
                str(self.media_root),
                str(target / "releases" / RELEASE_ID),
                str(target / "current"),
                str(target / f".current-{RELEASE_ID}"),
                "0",
                json.dumps([str(target)]),
                str(self.adoption_root),
                "0",
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assert_refused(
            result,
            f"Unsafe deployment target {target}: storage-root ancestor "
            f"{linked_storage} must be a real directory",
        )

    def test_rejects_non_pointer_symlink(self):
        symlink = self.deploy_root / "unexpected-link"
        symlink.symlink_to(self.expected_release, target_is_directory=True)

        result = self.run_validator([str(symlink)])

        self.assert_refused(
            result,
            f"Unsafe deployment target {symlink}: symlink component {symlink} "
            "is not an allowed deployment pointer",
        )

    def test_current_pointer_must_resolve_to_hex_directory_directly_under_releases(self):
        nested_release = self.releases / "nested" / OTHER_RELEASE_ID
        nested_release.mkdir(parents=True)
        self.current.symlink_to(nested_release, target_is_directory=True)

        result = self.run_validator([str(self.current)])

        self.assert_refused(
            result,
            f"Unsafe deployment target {self.current}: current pointer {self.current} "
            "escapes versioned releases",
        )

    def test_accepts_current_pointer_to_hex_directory_directly_under_releases(self):
        other_release = self.releases / OTHER_RELEASE_ID
        other_release.mkdir()
        self.current.symlink_to(other_release, target_is_directory=True)

        result = self.run_validator([str(self.current)])

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_require_current_rejects_pointer_to_different_release(self):
        other_release = self.releases / OTHER_RELEASE_ID
        other_release.mkdir()
        self.current.symlink_to(other_release, target_is_directory=True)

        result = self.run_validator([str(self.current)], require_current="1")

        self.assert_refused(
            result,
            f"Unsafe deployment target {self.current}: current pointer {self.current} "
            f"does not resolve to {self.expected_release}",
        )

    def test_rejects_malformed_json(self):
        result = self.run_validator([], paths_json="[")

        self.assert_refused(result, "Unsafe deployment target payload: invalid JSON")

    def test_rejects_non_array_payload(self):
        result = self.run_validator([], paths_json=json.dumps({"path": str(self.root)}))

        self.assert_refused(
            result, "Unsafe deployment target payload: expected a JSON array"
        )

    def test_rejects_non_string_array_entry(self):
        result = self.run_validator([str(self.root), 7])

        self.assert_refused(
            result, "Unsafe deployment target payload: target at index 1 must be a string"
        )

    def test_rejects_wrong_argument_count_without_traceback(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assert_refused(
            result, "Unsafe deployment target invocation: expected 9 arguments"
        )

    def test_accepts_media_target_and_rejects_media_symlink_escape(self):
        documents = self.media_root / "Documents"
        documents.mkdir()
        archive = documents / "archive"

        result = self.run_validator([str(archive)])
        self.assertEqual(result.returncode, 0, result.stderr)

        outside = self.base / "outside-documents"
        outside.mkdir()
        archive.symlink_to(outside, target_is_directory=True)
        result = self.run_validator([str(archive)])
        self.assert_refused(
            result,
            f"Unsafe deployment target {archive}: symlink component {archive} "
            "is not an allowed deployment pointer",
        )

    def test_rejects_state_root_nested_under_document_roots(self):
        for document_name in ("archive", "inbox", "export"):
            document_root = self.media_root / "Documents" / document_name
            state_root = document_root / "paperless-state"
            state_root.mkdir(parents=True)

            result = self.run_validator(
                [], storage_root=state_root, media_root=self.media_root
            )

            self.assert_refused(
                result,
                "Unsafe deployment target invocation: storage roots must not overlap",
            )

    def test_rejects_media_root_nested_under_state_or_aliasing_it(self):
        nested_media = self.root / "paperless-state" / "Documents"
        nested_media.mkdir(parents=True)
        result = self.run_validator([], storage_root=self.root, media_root=nested_media)
        self.assert_refused(
            result,
            "Unsafe deployment target invocation: storage roots must not overlap",
        )

        alias = self.base / "media-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        result = self.run_validator([], storage_root=self.root, media_root=alias)
        self.assert_refused(
            result,
            "Unsafe deployment target invocation: storage roots must not overlap",
        )

    def test_rejects_invalid_require_current_without_traceback(self):
        result = self.run_validator([str(self.root)], require_current="invalid")

        self.assert_refused(
            result,
            "Unsafe deployment target invocation: require_current must be 0 or 1",
        )

    def test_accepts_exact_reviewed_adoption_source(self):
        source = self.adoption_root / "legacy" / "ntfy" / "data"
        source.mkdir(parents=True)

        result = self.run_validator([str(source)], adoption_enabled="1")

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_adopted_paperless_tessdata_directory_and_model(self):
        tessdata = self.adoption_root / "legacy" / "paperless-ngx" / "tessdata"
        tessdata.mkdir(parents=True)
        model = tessdata / "heb.traineddata"
        cache = self.adoption_root / "legacy" / "paperless-ngx" / "cache"

        result = self.run_validator(
            [str(tessdata), str(model), str(cache)], adoption_enabled="1"
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_symlinked_adopted_paperless_tessdata_before_model_write(self):
        paperless = self.adoption_root / "legacy" / "paperless-ngx"
        paperless.mkdir(parents=True)
        outside = self.base / "outside-tessdata"
        outside.mkdir()
        tessdata = paperless / "tessdata"
        tessdata.symlink_to(outside, target_is_directory=True)

        result = self.run_validator(
            [str(tessdata), str(tessdata / "heb.traineddata")],
            adoption_enabled="1",
        )

        self.assert_refused(
            result,
            f"Unsafe deployment target {tessdata}: symlink component {tessdata} "
            "is not an allowed deployment pointer",
        )

    def test_rejects_symlinked_audiobookshelf_backup_adoption_source(self):
        service_root = self.adoption_root / "legacy" / "audiobookshelf"
        service_root.mkdir(parents=True)
        outside = self.base / "outside-backups"
        outside.mkdir()
        backup_source = service_root / "backups"
        backup_source.symlink_to(outside, target_is_directory=True)

        result = self.run_validator(
            [str(backup_source)], adoption_enabled="1"
        )

        self.assert_refused(
            result,
            f"Unsafe deployment target {backup_source}: symlink component "
            f"{backup_source} is not an allowed deployment pointer",
        )

    def test_rejects_unreviewed_adoption_source(self):
        source = self.adoption_root / "legacy" / "ntfy" / "unexpected"
        source.mkdir(parents=True)

        result = self.run_validator([str(source)], adoption_enabled="1")

        self.assert_refused(
            result,
            f"Unsafe deployment target {source}: path escapes storage root {self.root}",
        )

    def test_rejects_noncanonical_adoption_root(self):
        source = self.adoption_root / "legacy" / "ntfy" / "data"

        result = self.run_validator(
            [str(source)],
            adoption_enabled="1",
            adoption_root=f"{self.adoption_root}/.",
        )

        self.assert_refused(
            result,
            "Unsafe deployment target invocation: adoption root must be an absolute normalized path",
        )

    def test_rejects_invalid_adoption_enabled_without_traceback(self):
        result = self.run_validator(
            [str(self.root)], adoption_enabled="invalid"
        )

        self.assert_refused(
            result,
            "Unsafe deployment target invocation: adoption_enabled must be 0 or 1",
        )

    def test_next_pointer_only_accepts_expected_canonical_release(self):
        self.next_pointer.symlink_to(self.expected_release, target_is_directory=True)
        accepted = self.run_validator([str(self.next_pointer)])
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        self.next_pointer.unlink()
        other_release = self.releases / OTHER_RELEASE_ID
        other_release.mkdir()
        self.next_pointer.symlink_to(other_release, target_is_directory=True)

        rejected = self.run_validator([str(self.next_pointer)])

        self.assert_refused(
            rejected,
            f"Unsafe deployment target {self.next_pointer}: deployment pointer "
            f"{self.next_pointer} does not resolve to {self.expected_release}",
        )


if __name__ == "__main__":
    unittest.main()
