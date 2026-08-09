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
        self.deploy_root = self.root / "nas-platform"
        self.releases = self.deploy_root / "releases"
        self.expected_release = self.releases / RELEASE_ID
        self.current = self.deploy_root / "current"
        self.next_pointer = self.deploy_root / f".current-{RELEASE_ID}"
        self.expected_release.mkdir(parents=True)

    def run_validator(self, paths, *, require_current="0", paths_json=None):
        payload = json.dumps(paths) if paths_json is None else paths_json
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(self.root),
                str(self.expected_release),
                str(self.current),
                str(self.next_pointer),
                require_current,
                payload,
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
                str(target / "releases" / RELEASE_ID),
                str(target / "current"),
                str(target / f".current-{RELEASE_ID}"),
                "0",
                json.dumps([str(target)]),
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
