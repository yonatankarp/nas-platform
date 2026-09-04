"""Behavioural tests for the scheduled Docker image prune."""

import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from unittest import mock
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
# The reader of the record the prune writes about itself, run as the deployment
# it has to be legible to runs it: as another process, against the real file.
LOCK_PROBE = (
    Path(__file__).resolve().parents[1]
    / "roles"
    / "deployment_bundle"
    / "files"
    / "probe_deployment_lock.py"
)

import image_prune  # noqa: E402

# One pass reporting decimal units, one reporting none, so the parser is proved
# against Docker's real report rather than a single hand-picked line.
UNUSED_OUTPUT = """Deleted Images:
untagged: ghcr.io/example/service:1.2.3
deleted: sha256:{a}
deleted: sha256:{b}

Total reclaimed space: 1.5GB
""".format(a="a" * 64, b="b" * 64)
DANGLING_OUTPUT = """Deleted Images:
deleted: sha256:{c}

Total reclaimed space: 512.0kB
""".format(c="c" * 64)


class PruneTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for relative in (
            ".local/share/nas-platform/state",
            ".local/share/nas-platform/prune-state",
            ".local/share/nas-platform/prune-logs",
            ".config/nas-platform",
            "bin",
        ):
            (self.root / relative).mkdir(parents=True)
        self.notifier = self.root / ".config/nas-platform/ntfy-prune.curl"
        self.notifier.write_text("x\n", encoding="utf-8")
        self.notifier.chmod(0o600)
        self.lock = self.root / ".local/share/nas-platform/state/deployment.lock"
        self.docker = self.stub("docker")
        self.curl = self.stub("curl")
        self.config_path = self.root / ".config/nas-platform/image-prune.json"
        self.config_path.write_text(json.dumps(self.config_payload()), encoding="utf-8")

    def stub(self, name, body="exit 0"):
        """Install a recording stand-in for one tool the prune shells out to."""

        path = self.root / "bin" / name
        record = self.root / f"{name}.argv"
        path.write_text(
            "#!/bin/sh\n"
            f'printf "%s\\n" "$*" >> {record}\n'
            f"{body}\n",
            encoding="utf-8",
        )
        path.chmod(0o700)
        return path

    def invocations(self, name):
        record = self.root / f"{name}.argv"
        if not record.exists():
            return []
        return [line for line in record.read_text(encoding="utf-8").splitlines() if line]

    def config_payload(self, **overrides):
        payload = {
            "state_root": str(self.root / ".local/share/nas-platform/prune-state"),
            "log_root": str(self.root / ".local/share/nas-platform/prune-logs"),
            "deployment_lock": str(self.lock),
            "deployment_lock_wait_seconds": 0,
            "ntfy_curl_config": str(self.notifier),
            "ntfy_topic_critical": "nas-critical",
            "ntfy_topic_deployment": "nas-deployment",
            "retention_hours": 168,
            "dangling_retention_hours": 24,
            "log_retention_days": 30,
            "docker_path": str(self.docker),
            "curl_path": str(self.curl),
            "tool_path": f"{self.root / 'bin'}:/usr/bin:/bin",
        }
        payload.update(overrides)
        return payload

    def config(self, **overrides):
        path = self.root / "config.json"
        path.write_text(json.dumps(self.config_payload(**overrides)), encoding="utf-8")
        return image_prune.load_config(path)

    def state(self):
        return image_prune.read_state(self.config())


class ConfigTest(PruneTestCase):
    def test_load_config_reads_every_required_key(self):
        config = image_prune.load_config(self.config_path)
        self.assertEqual(config.retention_hours, 168)
        self.assertEqual(config.dangling_retention_hours, 24)
        self.assertEqual(config.deployment_lock, self.lock)
        self.assertEqual(config.docker_path, self.docker)

    def test_load_config_requires_every_field(self):
        for field in self.config_payload():
            payload = self.config_payload()
            del payload[field]
            path = self.root / "partial.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(image_prune.ConfigurationError):
                image_prune.load_config(path)

    def test_load_config_rejects_mistyped_or_unsafe_values(self):
        for overrides in (
            {"retention_hours": "168"},
            {"retention_hours": True},
            {"log_retention_days": 0},
            {"deployment_lock_wait_seconds": -1},
            {"docker_path": "docker"},
            {"log_root": ""},
            {"ntfy_topic_critical": 3},
        ):
            payload = self.config_payload(**overrides)
            path = self.root / "invalid.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(image_prune.ConfigurationError, msg=overrides):
                image_prune.load_config(path)

    def test_a_prune_never_removes_a_same_day_image(self):
        payload = self.config_payload(
            retention_hours=image_prune.MINIMUM_RETENTION_HOURS - 1
        )
        path = self.root / "short.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaises(image_prune.ConfigurationError):
            image_prune.load_config(path)

    def test_the_dangling_window_cannot_exceed_the_unused_window(self):
        payload = self.config_payload(retention_hours=168, dangling_retention_hours=169)
        path = self.root / "wide.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaises(image_prune.ConfigurationError):
            image_prune.load_config(path)

    def test_load_config_rejects_unreadable_or_non_object_payloads(self):
        path = self.root / "broken.json"
        path.write_text("[]", encoding="utf-8")
        with self.assertRaises(image_prune.ConfigurationError):
            image_prune.load_config(path)
        with self.assertRaises(image_prune.ConfigurationError):
            image_prune.load_config(self.root / "absent.json")


class CommandTest(PruneTestCase):
    def test_the_two_passes_are_exactly_the_declared_windows(self):
        commands = image_prune.prune_commands(self.config())
        self.assertEqual([label for label, _ in commands], ["unused", "dangling"])
        unused, dangling = (arguments for _, arguments in commands)
        self.assertEqual(
            unused,
            [
                str(self.docker),
                "image",
                "prune",
                "--all",
                "--force",
                "--filter",
                "until=168h",
            ],
        )
        self.assertEqual(
            dangling,
            [str(self.docker), "image", "prune", "--force", "--filter", "until=24h"],
        )

    def test_no_pass_can_reach_anything_but_an_image(self):
        for _, arguments in image_prune.prune_commands(self.config()):
            self.assertEqual(arguments[1:3], ["image", "prune"])
            for forbidden in ("system", "volume", "container", "network", "builder"):
                self.assertNotIn(forbidden, arguments)

    def test_every_pass_carries_an_age_filter(self):
        for _, arguments in image_prune.prune_commands(self.config()):
            self.assertIn("--filter", arguments)
            self.assertTrue(
                arguments[arguments.index("--filter") + 1].startswith("until=")
            )


class ReportParsingTest(PruneTestCase):
    def test_reclaimed_space_is_summed_across_units(self):
        self.assertEqual(image_prune.parse_reclaimed(UNUSED_OUTPUT), 1_500_000_000)
        self.assertEqual(image_prune.parse_reclaimed(DANGLING_OUTPUT), 512_000)
        self.assertEqual(
            image_prune.parse_reclaimed("Total reclaimed space: 1MiB\n"), 1_048_576
        )
        self.assertEqual(image_prune.parse_reclaimed("Total reclaimed space: 0B\n"), 0)

    def test_an_unreadable_report_reads_as_nothing_rather_than_a_guess(self):
        self.assertEqual(image_prune.parse_reclaimed("Total reclaimed space: 1XB\n"), 0)
        self.assertEqual(image_prune.parse_reclaimed("no report at all\n"), 0)

    def test_only_deletions_are_counted_as_removed_images(self):
        self.assertEqual(image_prune.count_removed(UNUSED_OUTPUT), 2)
        self.assertEqual(image_prune.count_removed(DANGLING_OUTPUT), 1)
        self.assertEqual(
            image_prune.count_removed("untagged: repo:tag\nDeleted Images:\n"), 0
        )

    def test_sizes_are_rendered_the_way_docker_reports_them(self):
        self.assertEqual(image_prune.format_bytes(0), "0 B")
        self.assertEqual(image_prune.format_bytes(999), "999 B")
        self.assertEqual(image_prune.format_bytes(1_500_000_000), "1.5 GB")
        self.assertEqual(image_prune.format_bytes(512_000), "512.0 kB")


class LockTest(PruneTestCase):
    def hold_lock(self):
        descriptor = os.open(self.lock, os.O_WRONLY | os.O_CREAT, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(os.close, descriptor)
        return descriptor

    def probe_lock(self):
        """Ask deployment_bundle's own probe who holds the lock."""

        completed = subprocess.run(
            [sys.executable, str(LOCK_PROBE), str(self.lock)],
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(completed.stdout)

    def test_a_holding_prune_names_itself_to_the_converge_that_finds_the_lock(self):
        # Crossed against the reader that actually consumes this record.
        # roles/deployment_bundle probes this lock at the first task of every
        # role and tolerates a holder it cannot identify, because a holder that
        # records nothing is a poller too old to write one and refusing it
        # deadlocks the upgrade that installs the newer poller. A prune that
        # recorded nothing would be indistinguishable from that, so every Sunday
        # a converge would run straight through a prune deleting image layers
        # underneath it. Naming itself is what keeps "no record" transient.
        with image_prune.deployment_lock(self.config()) as acquired:
            self.assertTrue(acquired)
            reported = self.probe_lock()
        self.assertTrue(reported["held"])
        self.assertEqual(reported["holder"], "image prune")
        self.assertEqual(reported["pid"], os.getpid())
        self.assertIn("started", reported)

    def test_the_record_does_not_outlive_the_prune_that_wrote_it(self):
        # Cleared while the lock is still held, so the next reader cannot find a
        # finished prune's pid under somebody else's lock.
        with image_prune.deployment_lock(self.config()) as acquired:
            self.assertTrue(acquired)
        self.assertEqual(self.lock.read_bytes(), b"")
        self.assertEqual(self.probe_lock(), {"state": "free", "held": False})

    def test_a_running_deployment_stops_the_prune_before_any_image_is_touched(self):
        self.hold_lock()
        self.assertTrue(image_prune.prune(self.config()))
        self.assertEqual(self.invocations("docker"), [])
        self.assertEqual(self.state()["outcome"], "skipped")

    def test_the_prune_waits_for_the_configured_window_before_giving_up(self):
        self.hold_lock()
        clock = {"now": 0.0}

        def advance(seconds):
            clock["now"] += seconds

        with mock.patch.object(
            image_prune.time, "monotonic", side_effect=lambda: clock["now"]
        ), mock.patch.object(
            image_prune.time, "sleep", side_effect=advance
        ) as sleeper:
            with image_prune.deployment_lock(
                self.config(deployment_lock_wait_seconds=30)
            ) as acquired:
                self.assertFalse(acquired)
        # Polled at the declared interval and gave up exactly at the window,
        # rather than spinning or waiting forever on a deployment that hung.
        self.assertEqual(
            [call.args[0] for call in sleeper.call_args_list],
            [image_prune.LOCK_POLL_SECONDS, image_prune.LOCK_POLL_SECONDS],
        )
        self.assertEqual(clock["now"], 30)

    def test_the_lock_is_released_for_the_deployment_that_follows(self):
        config = self.config()
        with image_prune.deployment_lock(config) as acquired:
            self.assertTrue(acquired)
        with image_prune.deployment_lock(config) as acquired:
            self.assertTrue(acquired)

    def test_the_prune_holds_the_lock_while_docker_runs(self):
        # Proved from inside the prune: the stub asks for the same lock a
        # deployment would ask for, and records the answer it got.
        probe = self.root / "lock-was-free"
        self.docker = self.stub(
            "docker",
            body=(
                "python3 - <<'PROBE'\n"
                "import fcntl, os\n"
                f"descriptor = os.open({str(self.lock)!r}, os.O_WRONLY | os.O_CREAT, 0o600)\n"
                "try:\n"
                "    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
                "except OSError:\n"
                "    pass\n"
                "else:\n"
                f"    open({str(probe)!r}, 'w').write('free')\n"
                "PROBE\n"
                "exit 0"
            ),
        )
        image_prune.prune(self.config())
        self.assertTrue(self.invocations("docker"), "the stub never ran")
        self.assertFalse(probe.exists(), "docker ran without the deployment lock held")


class PruneRunTest(PruneTestCase):
    def reporting_docker(self):
        return self.stub(
            "docker",
            body=(
                'case "$*" in\n'
                "  *'image ls'*) echo abc123\n    ;;\n"
                f"  *--all*) cat <<'REPORT'\n{UNUSED_OUTPUT}REPORT\n    ;;\n"
                f"  *prune*) cat <<'REPORT'\n{DANGLING_OUTPUT}REPORT\n    ;;\n"
                "esac\n"
                "exit 0"
            ),
        )

    def test_a_prune_runs_both_passes_and_records_what_it_reclaimed(self):
        self.reporting_docker()
        self.assertTrue(image_prune.prune(self.config()))
        invocations = self.invocations("docker")
        self.assertEqual(len(invocations), 3)
        self.assertIn("--all --force --filter until=168h", invocations[0])
        self.assertIn("--force --filter until=24h", invocations[1])
        recorded = self.state()
        self.assertEqual(recorded["outcome"], "reclaimed")
        self.assertEqual(recorded["reclaimed_bytes"], 1_500_512_000)
        self.assertEqual(recorded["images_removed"], 3)
        self.assertEqual(recorded["images_remaining"], 1)

    def test_a_prune_that_reclaimed_something_reports_it(self):
        self.reporting_docker()
        image_prune.prune(self.config())
        published = self.invocations("curl")
        self.assertEqual(len(published), 1)
        self.assertIn("nas-deployment", published[0])
        self.assertIn("1.5 GB", published[0])

    def test_a_week_with_nothing_to_reclaim_stays_quiet(self):
        self.stub("docker", body="echo 'Total reclaimed space: 0B'\nexit 0")
        self.assertTrue(image_prune.prune(self.config()))
        self.assertEqual(self.invocations("curl"), [])
        self.assertEqual(self.state()["outcome"], "nothing")

    def test_a_failing_pass_is_reported_as_critical_and_fails_the_run(self):
        self.stub("docker", body="echo 'Cannot connect to the Docker daemon' >&2\nexit 1")
        self.assertFalse(image_prune.prune(self.config()))
        recorded = self.state()
        self.assertEqual(recorded["outcome"], "failed")
        self.assertEqual(recorded["pass"], "unused")
        published = self.invocations("curl")
        self.assertEqual(len(published), 1)
        self.assertIn("nas-critical", published[0])

    def test_the_second_pass_never_runs_after_the_first_fails(self):
        self.stub("docker", body="exit 1")
        image_prune.prune(self.config())
        self.assertEqual(len(self.invocations("docker")), 1)

    def test_a_pass_that_outlives_its_deadline_is_a_failure_not_a_zero(self):
        with mock.patch.object(
            image_prune,
            "_run",
            side_effect=subprocess.TimeoutExpired("docker", 1),
        ):
            self.assertFalse(image_prune.prune(self.config()))
        self.assertEqual(self.state()["outcome"], "failed")

    def test_the_prune_records_its_own_log_privately(self):
        self.reporting_docker()
        image_prune.prune(self.config())
        config = self.config()
        logs = [path for path in config.log_root.iterdir() if path.name != "latest"]
        self.assertEqual(len(logs), 1)
        self.assertEqual(stat.S_IMODE(logs[0].stat().st_mode), 0o600)
        self.assertEqual((config.log_root / "latest").resolve(), logs[0].resolve())
        self.assertIn("image prune", logs[0].read_text(encoding="utf-8").lower())

    def test_recorded_state_is_private(self):
        self.reporting_docker()
        image_prune.prune(self.config())
        recorded = self.config().state_root / "last-prune"
        self.assertEqual(stat.S_IMODE(recorded.stat().st_mode), 0o600)


class LogRotationTest(PruneTestCase):
    def test_logs_past_the_window_are_removed_and_others_are_left_alone(self):
        from datetime import datetime, timedelta, timezone

        config = self.config()
        now = datetime(2026, 8, 30, 4, 0, tzinfo=timezone.utc)
        old = config.log_root / "20260101T040000Z-prune"
        recent = config.log_root / (
            (now - timedelta(days=1)).strftime("%Y%m%dT%H%M%SZ") + "-prune"
        )
        foreign = config.log_root / "20260101T040000Z-{}".format("a" * 40)
        for path in (old, recent, foreign):
            path.write_text("x", encoding="utf-8")
        image_prune.rotate_logs(config, now)
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())
        self.assertTrue(foreign.exists(), "the poller's own logs are not ours to delete")


class NotificationTest(PruneTestCase):
    def summary(self, **overrides):
        payload = {
            "reclaimed_bytes": 1_500_000_000,
            "images_removed": 3,
            "images_remaining": 24,
            "seconds": 12,
            "log": "/home/deploy/.local/share/nas-platform/prune-logs/latest",
        }
        payload.update(overrides)
        return payload

    def test_a_reclaim_reports_on_the_deployment_topic(self):
        document = image_prune.render_notification(
            self.config(), "reclaimed", self.summary()
        )
        self.assertEqual(document["topic"], "nas-deployment")
        self.assertEqual(document["priority"], 3)
        self.assertTrue(document["markdown"])
        self.assertIn("1.5 GB", document["title"])
        self.assertIn("**Images removed:** `3`", document["message"])
        self.assertIn("**Unused older than:** `168h`", document["message"])

    def test_a_failure_reports_on_the_critical_topic(self):
        document = image_prune.render_notification(
            self.config(),
            "failed",
            self.summary(**{"pass": "unused", "reason": "unused pass exited 1"}),
        )
        self.assertEqual(document["topic"], "nas-critical")
        self.assertEqual(document["priority"], 5)
        self.assertIn("unused pass exited 1", document["message"])
        self.assertEqual(document["title"], "Image prune failed")
        self.assertNotIn("1.5 GB", document["title"])

    def test_an_unknown_outcome_is_refused_rather_than_published(self):
        with self.assertRaises(ValueError):
            image_prune.render_notification(self.config(), "invented", self.summary())

    def test_the_published_document_carries_no_credential(self):
        # The token lives in the curl config the installer renders with no_log,
        # never in the body this script builds.
        document = image_prune.render_notification(
            self.config(), "reclaimed", self.summary()
        )
        self.assertNotIn("Authorization", json.dumps(document))


class CommandLineTest(PruneTestCase):
    def status(self):
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            code = image_prune.main(["--config", str(self.config_path), "--status"])
        return code, printed.getvalue()

    def test_status_reports_the_policy_before_any_prune_has_run(self):
        code, printed = self.status()
        self.assertEqual(code, 0)
        self.assertIn("last prune: none", printed)
        self.assertIn("unused retention: 168h", printed)
        self.assertIn("dangling retention: 24h", printed)

    def test_status_reports_the_last_outcome(self):
        self.stub("docker", body="echo 'Total reclaimed space: 0B'\nexit 0")
        image_prune.prune(self.config())
        _code, printed = self.status()
        self.assertIn("reclaimed 0 B from 0 images", printed)

    def test_invalid_arguments_are_refused(self):
        for argv in (
            [],
            ["--prune"],
            ["--config", str(self.config_path)],
            ["--config", str(self.config_path), "--prune", "--status"],
            ["--config", str(self.config_path), "--delete-everything"],
        ):
            self.assertEqual(image_prune.main(argv), 2, msg=argv)

    def test_a_broken_installation_reports_a_sentence_not_a_traceback(self):
        # Cron keeps only the most recent output, so a private directory the
        # installer never created has to read as a sentence a week later.
        missing = self.root / "absent"
        config_path = self.root / "broken-root.json"
        config_path.write_text(
            json.dumps(self.config_payload(log_root=str(missing))), encoding="utf-8"
        )
        printed = io.StringIO()
        with contextlib.redirect_stderr(printed):
            code = image_prune.main(["--config", str(config_path), "--prune"])
        self.assertEqual(code, 1)
        self.assertIn("is unusable", printed.getvalue())

    def test_an_unusable_configuration_fails_rather_than_pruning(self):
        broken = self.root / "broken.json"
        broken.write_text("{}", encoding="utf-8")
        self.assertEqual(image_prune.main(["--config", str(broken), "--prune"]), 1)
        self.assertEqual(self.invocations("docker"), [])


if __name__ == "__main__":
    unittest.main()
