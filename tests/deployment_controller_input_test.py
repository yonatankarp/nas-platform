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
    / "validate_controller_input.py"
)


class ControllerInputFixture(unittest.TestCase):
    """A checkout with one tracked input, and a sibling directory outside it."""

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


class ControllerInputValidatorTest(ControllerInputFixture):
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


# The batch entry point the role actually calls since #333. Every case above
# still exercises the single-input form, which the batch calls once per input, so
# these only have to hold the batch to the two properties batching could break:
# every input is really validated, and the first refusal is the one reported,
# with the message a single-input invocation would have produced.
class ControllerInputBatchTest(ControllerInputFixture):
    def run_batch(self, entries, *, root=None):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--batch",
                str(root or self.checkout),
                json.dumps([[str(path), flag] for path, flag in entries]),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_batch_accepts_every_valid_input(self):
        optional = self.checkout / "services" / "absent.yml"
        other = self.checkout / "services" / "second.yml"
        other.write_text("services: []\n")
        result = self.run_batch(
            [(self.tracked, "0"), (optional, "1"), (other, "0")]
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_batch_refuses_a_single_bad_input_among_good_ones(self):
        # The refusal has to survive being surrounded by acceptable inputs: a
        # batch that stopped iterating, or validated only its first entry, would
        # pass this.
        result = self.run_batch(
            [(self.tracked, "0"), (self.secret, "0"), (self.tracked, "0")]
        )
        self.assertNotEqual(result.returncode, 0, "a batch hiding a bad input was accepted")
        self.assertIn(
            f"Unsafe controller bundle input {self.secret}: "
            f"path escapes controller checkout {self.checkout}",
            result.stderr,
        )

    def test_batch_reports_the_first_refusal_verbatim(self):
        # The message tests/integration_controller.sh greps for, produced by the
        # ordering inputs.yml states rather than by whichever input is worst.
        link = self.checkout / "services" / "alias.yml"
        os.symlink(self.tracked, link)
        missing = self.checkout / "services" / "absent.yml"
        result = self.run_batch([(link, "0"), (missing, "0")])
        self.assertNotEqual(result.returncode, 0, "a symlinked batch input was accepted")
        self.assertIn(
            f"Unsafe controller bundle input {link}: must be a regular non-symlink file",
            result.stderr,
        )
        self.assertNotIn("required file does not exist", result.stderr)

    def test_batch_honours_allow_missing_per_input(self):
        missing = self.checkout / "services" / "absent.yml"
        self.assertEqual(self.run_batch([(missing, "1")]).returncode, 0)
        required = self.run_batch([(missing, "0")])
        self.assertNotEqual(required.returncode, 0, "an absent required batch input was accepted")
        self.assertIn(
            f"Unsafe controller bundle input {missing}: required file does not exist",
            required.stderr,
        )

    def test_empty_batch_is_refused(self):
        # An expression that collapsed to [] would otherwise leave the task green
        # while validating nothing. Both call sites name at least two inputs.
        result = self.run_batch([])
        self.assertNotEqual(result.returncode, 0, "an empty batch was accepted")
        self.assertIn("expected a nonempty list of inputs", result.stderr)

    def test_malformed_batch_entries_are_refused(self):
        for payload, description in (
            ('{"path": "/x"}', "a mapping instead of a list"),
            ('[["/x"]]', "a pair missing its allow_missing flag"),
            ('[["/x", true]]', "a non-string allow_missing flag"),
            ("not json", "a payload that is not JSON"),
        ):
            with self.subTest(payload=description):
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), "--batch", str(self.checkout), payload],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0, description)
                self.assertIn("Unsafe controller bundle input batch", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
