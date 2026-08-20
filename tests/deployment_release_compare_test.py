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
    / "compare_release_trees.py"
)


class DeploymentReleaseCompareTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.base = Path(os.path.realpath(self.temporary_directory.name))

    def tree(self, name, *, content=b"compose", mode=0o644):
        root = self.base / name
        (root / "services" / "ntfy").mkdir(parents=True)
        target = root / "services" / "ntfy" / "compose.yml"
        target.write_bytes(content)
        target.chmod(mode)
        return root

    def compare(self, left, right):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(left), str(right)],
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_identical(self, left, right, message):
        result = self.compare(left, right)
        self.assertEqual(result.returncode, 0, f"{message}: {result.stderr}")

    def assert_differs(self, left, right, message):
        result = self.compare(left, right)
        self.assertEqual(result.returncode, 1, f"{message}: {result.stderr}")

    def test_identical_trees_compare_equal(self):
        self.assert_identical(self.tree("a"), self.tree("b"), "identical trees differed")

    def test_content_difference_is_detected(self):
        self.assert_differs(
            self.tree("a"), self.tree("b", content=b"other"), "content change missed"
        )

    def test_mode_difference_is_detected(self):
        self.assert_differs(
            self.tree("a"), self.tree("b", mode=0o600), "mode change missed"
        )

    def test_extra_entry_is_detected(self):
        left = self.tree("a")
        right = self.tree("b")
        (right / "services" / "undeclared").mkdir()
        self.assert_differs(left, right, "extra directory missed")

    def test_symlink_is_compared_by_target_without_following(self):
        left = self.tree("a")
        right = self.tree("b")
        for root, destination in ((left, "compose.yml"), (right, "../ntfy/compose.yml")):
            os.symlink(destination, root / "services" / "link")
        self.assert_differs(left, right, "symlink target change missed")

    def test_a_symlink_is_not_resolved_into_its_content(self):
        left = self.tree("a")
        right = self.tree("b")
        os.symlink("compose.yml", left / "services" / "ntfy" / "alias")
        (right / "services" / "ntfy" / "alias").write_bytes(b"compose")
        self.assert_differs(left, right, "symlink was resolved to its target's content")


if __name__ == "__main__":
    unittest.main(verbosity=2)
