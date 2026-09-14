"""Behavioural tests for the scheduled Docker image prune."""

import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import re
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

# A half-cut or invented entity: an ampersand that does not open one html.escape writes.
HALF_ENTITY = re.compile(r"&(?!amp;|lt;|gt;|quot;|#x27;)")

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
        self.alerts_notifier = self.root / ".config/nas-platform/pushover-prune-alerts.curl"
        self.deployments_notifier = (
            self.root / ".config/nas-platform/pushover-prune-deployments.curl"
        )
        for notifier in (self.alerts_notifier, self.deployments_notifier):
            notifier.write_text("x\n", encoding="utf-8")
            notifier.chmod(0o600)
        self.lock = self.root / ".local/share/nas-platform/state/deployment.lock"
        self.docker = self.stub("docker")
        # Records each send's argv as one JSON line -- a message spans lines, so
        # the shell stub's one-line record cannot hold it -- and answers as
        # Pushover does when it takes a message, unless curl-answer says otherwise.
        self.curl_calls = self.root / "curl.jsonl"
        self.curl_answer = self.root / "curl-answer"
        self.curl = self.root / "bin" / "curl"
        self.curl.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"with open({str(self.curl_calls)!r}, 'a') as sink:\n"
            "    sink.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"answer = {str(self.curl_answer)!r}\n"
            "sys.stdout.write(open(answer).read() if os.path.exists(answer)\n"
            "                 else '{\"status\":1,\"request\":\"r\"}\\n200')\n",
            encoding="utf-8",
        )
        self.curl.chmod(0o700)
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

    def published(self):
        """Every Pushover send: its config and --form-string fields, in order."""

        if not self.curl_calls.exists():
            return []
        sends = []
        for line in self.curl_calls.read_text(encoding="utf-8").splitlines():
            argv = json.loads(line)
            form = dict(
                argv[index + 1].split("=", 1)
                for index, argument in enumerate(argv)
                if argument == "--form-string"
            )
            sends.append({"config": argv[argv.index("--config") + 1], "argv": argv, **form})
        return sends

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
            "pushover_alerts_curl_config": str(self.alerts_notifier),
            "pushover_deployments_curl_config": str(self.deployments_notifier),
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
        # The two Pushover configs are optional and have their own test below.
        optional = {"pushover_alerts_curl_config", "pushover_deployments_curl_config"}
        for field in [name for name in self.config_payload() if name not in optional]:
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
        ):
            payload = self.config_payload(**overrides)
            path = self.root / "invalid.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(image_prune.ConfigurationError, msg=overrides):
                image_prune.load_config(path)

    def test_an_ntfy_era_configuration_loads_and_cannot_publish(self):
        # The install play copies this script before it renders its
        # configuration, so a prune in that window reads the ntfy-era file
        # (#327). It must prune, not refuse: one stderr line, nothing published.
        payload = self.config_payload(
            ntfy_curl_config=str(self.root / ".config/nas-platform/ntfy-prune.curl"),
            ntfy_topic_critical="nas-critical",
            ntfy_topic_deployment="nas-deployment",
        )
        payload.pop("pushover_alerts_curl_config")
        payload.pop("pushover_deployments_curl_config")
        path = self.root / "ntfy-era.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            config = image_prune.load_config(path)

        self.assertIsNone(config.pushover_alerts_curl_config)
        self.assertIsNone(config.pushover_deployments_curl_config)
        (line,) = stderr.getvalue().splitlines()
        self.assertIn("pushover_alerts_curl_config", line)
        self.stub("docker", body="echo 'Cannot connect to the Docker daemon'\nexit 1")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(image_prune.prune(config))
        self.assertEqual(self.published(), [])
        self.assertEqual(self.state()["outcome"], "failed")

    def test_an_unusable_pushover_path_cannot_publish_rather_than_refusing(self):
        for raw in ("", "relative/pushover.curl", 42, None):
            with self.subTest(raw=raw):
                with contextlib.redirect_stderr(io.StringIO()):
                    config = self.config(pushover_deployments_curl_config=raw)
                self.assertIsNone(config.pushover_deployments_curl_config)
                self.assertEqual(config.pushover_alerts_curl_config, self.alerts_notifier)

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
        (send,) = self.published()
        # A record, not an alarm: the Deployments app, silent, gone in a week.
        self.assertEqual(send["config"], str(self.deployments_notifier))
        self.assertEqual((send["priority"], send["ttl"], send["html"]), ("-1", "604800", "1"))
        self.assertIn("1.5 GB", send["title"])
        self.assertNotIn("--fail", send["argv"])
        # --disable first, which is the only place curl honours it: the prune
        # passes HOME, so without it ~/.curlrc's proxy and headers ride along.
        self.assertEqual(send["argv"][0], "--disable")

    def test_a_week_with_nothing_to_reclaim_stays_quiet(self):
        self.stub("docker", body="echo 'Total reclaimed space: 0B'\nexit 0")
        self.assertTrue(image_prune.prune(self.config()))
        self.assertEqual(self.published(), [])
        self.assertEqual(self.state()["outcome"], "nothing")

    def test_a_failing_pass_is_reported_as_critical_and_fails_the_run(self):
        self.stub("docker", body="echo 'Cannot connect to the Docker daemon' >&2\nexit 1")
        self.assertFalse(image_prune.prune(self.config()))
        recorded = self.state()
        self.assertEqual(recorded["outcome"], "failed")
        self.assertEqual(recorded["pass"], "unused")
        (send,) = self.published()
        self.assertEqual(send["config"], str(self.alerts_notifier))
        self.assertEqual(send["priority"], "1")
        self.assertNotIn("ttl", send)

    def test_a_refused_or_unanswered_report_changes_no_outcome_and_names_only_keys(self):
        sentinel = "sentinel-token-that-must-stay-in-its-file"
        self.deployments_notifier.write_text(f'form-string = "token={sentinel}"\n', encoding="utf-8")
        for label, answer, named in (
            ("refused", '{"status":0,"errors":["application token is invalid"]}\n400', True),
            ("unanswered", '<html>captive portal</html>\n200', False),
            ("rate limited", '{"status":0}\n429', False),
        ):
            with self.subTest(label):
                self.curl_answer.write_text(answer, encoding="utf-8")
                self.reporting_docker()
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr):
                    self.assertTrue(image_prune.prune(self.config()))
                self.assertEqual(self.state()["outcome"], "reclaimed")
                self.assertIn("outcome notification failed", stderr.getvalue())
                self.assertEqual("vault_pushover_deployments_token" in stderr.getvalue(), named)
                self.assertEqual("HTTP 429" in stderr.getvalue(), label == "rate limited")
                self.assertNotIn(sentinel, stderr.getvalue())
                self.assertTrue(all(sentinel not in " ".join(send["argv"])
                                    for send in self.published()))
                self.curl_calls.unlink()

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

    def test_a_reclaim_reports_to_the_deployments_application_quietly(self):
        app, fields = image_prune.render_notification(
            self.config(), "reclaimed", self.summary()
        )
        self.assertEqual(app, "deployments")
        self.assertEqual(fields["priority"], -1)
        self.assertEqual(fields["ttl"], 604800)
        self.assertIn("1.5 GB", fields["title"])
        self.assertIn("<b>Images removed:</b> 3", fields["message"])
        self.assertIn("<b>Unused older than:</b> 168h", fields["message"])

    def test_a_failure_reports_to_the_alerts_application(self):
        app, fields = image_prune.render_notification(
            self.config(),
            "failed",
            self.summary(**{"pass": "unused", "reason": "unused pass exited 1"}),
        )
        self.assertEqual(app, "alerts")
        self.assertEqual(fields["priority"], 1)
        # A ttl would let a failure expire unread.
        self.assertNotIn("ttl", fields)
        self.assertIn("<b>Reason:</b> unused pass exited 1", fields["message"])
        self.assertEqual(fields["title"], "Image prune failed")
        self.assertNotIn("1.5 GB", fields["title"])

    def test_hostile_input_stays_inside_pushovers_limits_without_a_cut_entity(self):
        hostile = ("<b>&'\"" * 2500)[:10_000]
        app, fields = image_prune.render_notification(
            self.config(), "failed",
            self.summary(**{"pass": hostile, "reason": hostile, "log": hostile}),
        )
        message = fields["message"]
        self.assertLessEqual(len(message), image_prune.MAX_MESSAGE_CHARACTERS)
        self.assertTrue(message)
        self.assertIsNone(HALF_ENTITY.search(message), message)
        self.assertEqual(message.count("<b>"), message.count("</b>"))
        with mock.patch.object(
            image_prune, "_run",
            return_value=subprocess.CompletedProcess([], 0, b'{"status":1}\n200', b""),
        ) as run:
            self.assertTrue(image_prune.publish(self.config(), app, dict(fields, title=hostile)))
        arguments = run.call_args.args[0]
        titles = [argument for argument in arguments if argument.startswith("title=")]
        self.assertEqual([len(title) - len("title=") for title in titles],
                         [image_prune.MAX_TITLE_CHARACTERS])

    def test_only_an_integer_status_of_1_is_accepted(self):
        verdict = image_prune.pushover_verdict
        self.assertEqual(verdict(0, b'{"status":1}\n200'), "accepted")
        for output in (b'{"status":"1"}\n200', b'{"status":true}\n200',
                       b"[" * 200_000 + b"\n200"):
            with self.subTest(output=output[:20]):
                self.assertEqual(verdict(0, output), "unanswered")

    def test_publish_never_raises(self):
        config = self.config()
        with contextlib.redirect_stderr(io.StringIO()):
            # A NUL no argv can carry, through the real _run.
            self.assertFalse(image_prune.publish(
                config, "alerts", {"title": "a\0b", "message": "m", "priority": 1}))
            with mock.patch.object(
                image_prune, "_run",
                return_value=subprocess.CompletedProcess([], 0, b"[" * 200_000 + b"\n200", b""),
            ):
                self.assertFalse(image_prune.publish(
                    config, "alerts", {"title": "t", "message": "m", "priority": 1}))
        self.assertEqual(self.published(), [])

    def test_a_message_that_cannot_fit_is_cut_without_emptying_it_or_splitting_markup(self):
        entities = "&amp;" * 300
        for lines in (["x" * 5000], ["y" * 1100, "z"], [entities], [entities, "<b>t</b>"],
                      ["<b>" + "w" * 1030 + "</b>"]):
            with self.subTest(lines=[line[:12] for line in lines]):
                message = image_prune.fit_message(lines)
                self.assertTrue(message)
                self.assertLessEqual(len(message), image_prune.MAX_MESSAGE_CHARACTERS)
                self.assertIsNone(HALF_ENTITY.search(message), message[-20:])
                self.assertEqual(message.count("<b>"), message.count("</b>"))

    def test_an_unknown_outcome_is_refused_rather_than_published(self):
        with self.assertRaises(ValueError):
            image_prune.render_notification(self.config(), "invented", self.summary())

    def test_the_published_document_carries_no_credential(self):
        # The token lives in the curl config the installer renders with no_log,
        # never in the body this script builds.
        _app, fields = image_prune.render_notification(
            self.config(), "reclaimed", self.summary()
        )
        self.assertNotIn("token", json.dumps(fields))
        self.assertNotIn("user", json.dumps(fields))


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


class PrivateWriteTest(PruneTestCase):
    """The prune's copy of the write, held to the same properties as the poller's.

    Both scripts ship one implementation of _write_private and
    tests/policy_test.rb compares the two definitions, but that check reads
    source text. These assertions read behaviour, so a copy that agreed
    textually while the script shadowed it with something else still fails
    here. The prune's own record is what --status reports and what a converge
    refused by the deployment lock names, so losing it is not free (#354).
    """

    def setUp(self):
        super().setUp()
        self.target = self.root / ".local/share/nas-platform/prune-state/record"
        self.target.write_bytes(b"5\n")
        self.target.chmod(0o600)

    @staticmethod
    def legacy_write(path, payload):
        """scripts/image_prune.py's _write_private before #354."""

        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as sink:
            sink.write(payload)
        os.chmod(path, 0o600)

    def content_while_writing(self, writer, payload=b"6\n"):
        """What is on disk at the moment the payload is handed to the kernel."""

        seen = []
        real_fdopen = os.fdopen

        def watching_fdopen(descriptor, *arguments, **keywords):
            seen.append(self.target.read_bytes())
            return real_fdopen(descriptor, *arguments, **keywords)

        with mock.patch("os.fdopen", watching_fdopen):
            writer(self.target, payload)
        self.assertEqual(len(seen), 1)
        return seen[0]

    def test_the_previous_payload_is_whole_until_the_new_one_lands(self):
        self.assertEqual(self.content_while_writing(image_prune._write_private), b"5\n")
        self.assertEqual(self.target.read_bytes(), b"6\n")

    def test_the_pre_354_write_had_already_discarded_it(self):
        """The negative control: the same instrument, the body #354 replaced."""

        self.assertEqual(self.content_while_writing(self.legacy_write), b"")

    def test_a_pre_existing_loose_mode_target_is_repaired(self):
        """The half the prune already had, kept by the rename rather than a chmod."""

        self.target.chmod(0o644)

        image_prune._write_private(self.target, b"6\n")

        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)

    def test_a_failed_replacement_leaves_neither_a_loss_nor_a_temporary_file(self):
        with mock.patch("os.replace", side_effect=OSError("no space")):
            with self.assertRaises(OSError):
                image_prune._write_private(self.target, b"6\n")

        self.assertEqual(self.target.read_bytes(), b"5\n")
        self.assertEqual(
            sorted(entry.name for entry in self.target.parent.iterdir()), ["record"]
        )
