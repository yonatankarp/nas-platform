#!/usr/bin/env python3

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
    / "validate_controller_input.py"
)


class ControllerInputValidatorTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.base = Path(os.path.realpath(self.temporary_directory.name))
        self.checkout = self.base / "checkout"
        self.outside = self.base / "outside"
        (self.checkout / "services").mkdir(parents=True)
        self.outside.mkdir()
        self.tracked = self.checkout / "services" / "manifest.yml"
        self.tracked.write_text("services: []\n")
        self.secret = self.outside / "secret.yml"
        self.secret.write_text("stolen\n")

    def run_validator(self, path, *, root=None, allow_missing="0"):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(root or self.checkout), str(path), allow_missing],
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_accepted(self, path, message, **kwargs):
        result = self.run_validator(path, **kwargs)
        self.assertEqual(result.returncode, 0, f"{message}: {result.stderr}")

    def assert_refused(self, path, message, **kwargs):
        result = self.run_validator(path, **kwargs)
        self.assertNotEqual(result.returncode, 0, message)
        self.assertIn("Unsafe controller bundle input", result.stderr, message)

    def test_tracked_file_inside_the_checkout_is_accepted(self):
        self.assert_accepted(self.tracked, "a tracked input was refused")

    def test_relative_paths_are_refused(self):
        self.assert_refused(Path("services/manifest.yml"), "a relative path was accepted")

    def test_traversal_out_of_the_checkout_is_refused(self):
        escape = self.checkout / ".." / "outside" / "secret.yml"
        self.assert_refused(escape, "a traversal path was accepted")

    def test_absent_file_is_refused_unless_allowed(self):
        missing = self.checkout / "services" / "absent.yml"
        self.assert_refused(missing, "an absent required input was accepted")
        self.assert_accepted(missing, "an absent optional input was refused", allow_missing="1")

    def test_directory_is_refused(self):
        self.assert_refused(self.checkout / "services", "a directory was accepted")

    def test_symlink_is_refused_even_when_it_points_inside(self):
        link = self.checkout / "services" / "alias.yml"
        os.symlink(self.tracked, link)
        self.assert_refused(link, "a symlink inside the checkout was accepted")

    def test_path_outside_the_checkout_is_refused_even_if_it_resolves_inside(self):
        # Isolates the lexical containment check from the canonical one: this
        # path's realpath lands on a tracked file inside the checkout, so only
        # the pre-canonicalization comparison can reject it.
        # The symlink is an ancestor, not the leaf, so the leaf lstats as a
        # regular file and the symlink rule does not fire.
        os.symlink(self.checkout / "services", self.outside / "linked")
        self.assert_refused(
            self.outside / "linked" / "manifest.yml",
            "a path outside the checkout was accepted because it resolved inside",
        )

    def test_symlinked_ancestor_escaping_the_checkout_is_refused(self):
        (self.outside / "payload.yml").write_text("stolen\n")
        os.symlink(self.outside, self.checkout / "linked")
        self.assert_refused(
            self.checkout / "linked" / "payload.yml",
            "a symlinked ancestor escaping the checkout was accepted",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
