"""Behavioural tests for the production auto-deploy poller."""

import contextlib
from datetime import datetime, timedelta, timezone
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest import mock
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import production_auto_deploy  # noqa: E402

MAIN_SHA = "a" * 40
OTHER_SHA = "b" * 40


class PollerTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for relative in (
            ".local/share/nas-platform/state",
            ".local/share/nas-platform/logs",
            ".local/share/nas-platform/controller",
            ".config/nas-platform",
        ):
            (self.root / relative).mkdir(parents=True)
        self.vault = self.root / ".config/nas-platform/vault.yml"
        self.password = self.root / ".config/nas-platform/vault-password"
        self.notifier = self.root / ".config/nas-platform/ntfy.curl"
        for path in (self.vault, self.password, self.notifier):
            path.write_text("x\n", encoding="utf-8")
            path.chmod(0o600)
        self.config_path = self.root / ".config/nas-platform/deployer.json"
        self.config_path.write_text(json.dumps(self.config_payload()), encoding="utf-8")

    def config_payload(self, **overrides):
        payload = {
            "repository": "yonatankarp/nas-platform",
            "repository_url": "https://github.com/yonatankarp/nas-platform.git",
            "workflow": "ci.yml",
            "workflow_name": "CI",
            "branch": "main",
            "checkout": str(self.root / ".local/share/nas-platform/controller"),
            "state_root": str(self.root / ".local/share/nas-platform/state"),
            "log_root": str(self.root / ".local/share/nas-platform/logs"),
            "vault_file": str(self.vault),
            "vault_password_file": str(self.password),
            "ntfy_curl_config": str(self.notifier),
            "platform_nas_address": "192.168.0.139",
            "platform_public_host": "192.168.0.139",
            "platform_callback_host": "192.168.0.139",
            "github_api_base": "https://api.github.com",
            "log_retention_days": 30,
            "verify_tags": "platform_verify_ntfy,platform_verify_beszel",
        }
        payload.update(overrides)
        return payload

    def loaded_config(self, **overrides):
        if overrides:
            self.config_path.write_text(
                json.dumps(self.config_payload(**overrides)), encoding="utf-8"
            )
        return production_auto_deploy.load_config(self.config_path)


class ConfigTest(PollerTestCase):
    def test_load_config_reads_every_required_key(self):
        config = self.loaded_config()

        self.assertEqual(config.repository, "yonatankarp/nas-platform")
        self.assertEqual(config.branch, "main")
        self.assertEqual(config.workflow_name, "CI")
        self.assertEqual(config.log_retention_days, 30)
        self.assertIsInstance(config.checkout, Path)
        self.assertIsInstance(config.vault_password_file, Path)
        self.assertTrue(config.state_root.is_absolute())

    def test_load_config_requires_every_field(self):
        for field in [f.name for f in production_auto_deploy.fields(
                production_auto_deploy.Config)]:
            payload = self.config_payload()
            payload.pop(field)
            self.config_path.write_text(json.dumps(payload), encoding="utf-8")
            with self.subTest(missing=field):
                with self.assertRaises(production_auto_deploy.ConfigurationError):
                    production_auto_deploy.load_config(self.config_path)

    def test_load_config_rejects_mistyped_or_unsafe_values(self):
        cases = (
            {"log_retention_days": "30"},
            {"log_retention_days": 0},
            {"log_retention_days": True},
            {"branch": ""},
            {"repository_url": "http://github.com/x/y.git"},
            {"github_api_base": "http://api.github.com"},
            {"state_root": "relative/path"},
        )
        for override in cases:
            payload = self.config_payload(**override)
            self.config_path.write_text(json.dumps(payload), encoding="utf-8")
            with self.subTest(override=override):
                with self.assertRaises(production_auto_deploy.ConfigurationError):
                    production_auto_deploy.load_config(self.config_path)

    def test_load_config_rejects_unreadable_or_non_object_payloads(self):
        for payload in ("[]", "null", "not json", '"text"'):
            self.config_path.write_text(payload, encoding="utf-8")
            with self.subTest(payload=payload):
                with self.assertRaises(production_auto_deploy.ConfigurationError):
                    production_auto_deploy.load_config(self.config_path)
        with self.assertRaises(production_auto_deploy.ConfigurationError):
            production_auto_deploy.load_config(self.root / "absent.json")


class EligibilityTest(PollerTestCase):
    GREEN_RUN = {
        "head_sha": MAIN_SHA,
        "status": "completed",
        "conclusion": "success",
        "event": "push",
        "head_branch": "main",
        "name": "CI",
    }

    def test_exactly_one_matching_success_is_green(self):
        config = self.loaded_config()
        self.assertTrue(
            production_auto_deploy.is_ci_green(config, MAIN_SHA, (self.GREEN_RUN,))
        )

    def test_ambiguity_is_not_green(self):
        config = self.loaded_config()
        self.assertFalse(
            production_auto_deploy.is_ci_green(
                config, MAIN_SHA, (self.GREEN_RUN, self.GREEN_RUN)
            )
        )

    def test_no_runs_is_not_green(self):
        config = self.loaded_config()
        self.assertFalse(production_auto_deploy.is_ci_green(config, MAIN_SHA, ()))

    def test_every_field_must_match(self):
        config = self.loaded_config()
        for key, bad in (
            ("head_sha", OTHER_SHA),
            ("status", "in_progress"),
            ("conclusion", "failure"),
            ("event", "workflow_dispatch"),
            ("head_branch", "topic"),
            ("name", "Lint"),
        ):
            run = {**self.GREEN_RUN, key: bad}
            with self.subTest(key=key):
                self.assertFalse(
                    production_auto_deploy.is_ci_green(config, MAIN_SHA, (run,))
                )

    def test_resolve_main_sha_reads_ls_remote(self):
        config = self.loaded_config()
        with mock.patch.object(production_auto_deploy, "_run") as run:
            run.return_value = subprocess.CompletedProcess(
                [], 0, (MAIN_SHA + "\trefs/heads/main\n").encode("ascii"), b""
            )
            self.assertEqual(production_auto_deploy.resolve_main_sha(config), MAIN_SHA)
        arguments = [str(a) for a in run.call_args.args[0]]
        self.assertEqual(arguments[:3], ["git", "ls-remote", "--exit-code"])
        self.assertIn("refs/heads/main", arguments)

    def test_resolve_main_sha_rejects_malformed_answers(self):
        config = self.loaded_config()
        cases = (
            (0, b""),
            (0, b"nope\trefs/heads/main\n"),
            (0, (MAIN_SHA + "\trefs/heads/other\n").encode("ascii")),
            (0, (MAIN_SHA + "\trefs/heads/main\n" + OTHER_SHA
                 + "\trefs/heads/main\n").encode("ascii")),
            (2, (MAIN_SHA + "\trefs/heads/main\n").encode("ascii")),
        )
        for returncode, stdout in cases:
            with mock.patch.object(production_auto_deploy, "_run") as run:
                run.return_value = subprocess.CompletedProcess([], returncode, stdout, b"")
                with self.subTest(stdout=stdout, returncode=returncode):
                    with self.assertRaises(production_auto_deploy.EligibilityError):
                        production_auto_deploy.resolve_main_sha(config)

    def test_fetch_ci_runs_rejects_an_invalid_sha_before_any_request(self):
        config = self.loaded_config()
        with mock.patch.object(production_auto_deploy, "urlopen") as opener:
            with self.assertRaises(production_auto_deploy.EligibilityError):
                production_auto_deploy.fetch_ci_runs(config, "nope")
        opener.assert_not_called()

    def test_fetch_ci_runs_requests_the_pinned_query_and_parses_runs(self):
        config = self.loaded_config()
        body = json.dumps({"workflow_runs": [self.GREEN_RUN, "junk"]}).encode("utf-8")
        with mock.patch.object(production_auto_deploy, "urlopen") as opener:
            opener.return_value.__enter__.return_value.read.return_value = body
            runs = production_auto_deploy.fetch_ci_runs(config, MAIN_SHA)
        self.assertEqual(runs, (self.GREEN_RUN,))
        url = opener.call_args.args[0].full_url
        self.assertIn("/repos/yonatankarp/nas-platform/", url)
        self.assertIn("workflows/ci.yml/runs", url)
        self.assertIn("event=push", url)
        self.assertIn(f"head_sha={MAIN_SHA}", url)

    def test_fetch_ci_runs_rejects_an_oversized_or_invalid_body(self):
        config = self.loaded_config()
        for body in (
            b"x" * (production_auto_deploy.MAX_RESPONSE_BYTES + 1),
            b"not json",
            json.dumps({"workflow_runs": "nope"}).encode("utf-8"),
            json.dumps({"other": []}).encode("utf-8"),
        ):
            with mock.patch.object(production_auto_deploy, "urlopen") as opener:
                opener.return_value.__enter__.return_value.read.return_value = body
                with self.subTest(body=body[:20]):
                    with self.assertRaises(production_auto_deploy.EligibilityError):
                        production_auto_deploy.fetch_ci_runs(config, MAIN_SHA)


class StateTest(PollerTestCase):
    def test_a_sha_is_recorded_once_and_is_idempotent(self):
        config = self.loaded_config()
        self.assertEqual(production_auto_deploy.attempted_shas(config), set())
        production_auto_deploy.record_attempt(config, MAIN_SHA)
        production_auto_deploy.record_attempt(config, MAIN_SHA)
        self.assertEqual(production_auto_deploy.attempted_shas(config), {MAIN_SHA})

    def test_forget_attempt_removes_only_the_named_sha(self):
        config = self.loaded_config()
        production_auto_deploy.record_attempt(config, MAIN_SHA)
        production_auto_deploy.record_attempt(config, OTHER_SHA)
        production_auto_deploy.forget_attempt(config, MAIN_SHA)
        self.assertEqual(production_auto_deploy.attempted_shas(config), {OTHER_SHA})

    def test_absent_state_reads_as_empty_rather_than_failing(self):
        config = self.loaded_config()
        self.assertEqual(
            production_auto_deploy.read_state(config),
            {"attempted": [], "last_successful": None},
        )

    def test_corrupt_state_is_ignored_rather_than_trusted(self):
        config = self.loaded_config()
        (config.state_root / "attempted").write_text("garbage\n" + MAIN_SHA + "\n")
        (config.state_root / "last-successful").write_text("not-a-sha 2026\n")
        self.assertEqual(production_auto_deploy.attempted_shas(config), {MAIN_SHA})
        self.assertIsNone(production_auto_deploy.read_state(config)["last_successful"])

    def test_read_state_reports_the_recorded_success(self):
        config = self.loaded_config()
        production_auto_deploy.record_success(config, MAIN_SHA, "2026-08-20T10:00:00Z")
        self.assertEqual(
            production_auto_deploy.read_state(config)["last_successful"],
            {"sha": MAIN_SHA, "timestamp": "2026-08-20T10:00:00Z"},
        )

    def test_state_files_are_private(self):
        config = self.loaded_config()
        production_auto_deploy.record_attempt(config, MAIN_SHA)
        production_auto_deploy.record_success(config, MAIN_SHA, "2026-08-20T10:00:00Z")
        for name in ("attempted", "last-successful"):
            with self.subTest(name=name):
                mode = (config.state_root / name).stat().st_mode & 0o777
                self.assertEqual(mode, 0o600)

    def test_the_record_is_capped_by_count(self):
        config = self.loaded_config()
        now = datetime(2026, 8, 20, tzinfo=timezone.utc)
        shas = [f"{index:040x}" for index in range(60)]
        for offset, sha in enumerate(shas):
            production_auto_deploy.record_attempt(
                config, sha, now=now + timedelta(minutes=offset)
            )

        recorded = production_auto_deploy.attempted_shas(config)
        self.assertEqual(len(recorded), production_auto_deploy.ATTEMPTED_RETENTION_COUNT)
        # The newest survive; the oldest are dropped.
        self.assertIn(shas[-1], recorded)
        self.assertNotIn(shas[0], recorded)

    def test_the_record_drops_entries_past_the_retention_window(self):
        config = self.loaded_config()
        old = datetime(2026, 1, 1, tzinfo=timezone.utc)
        production_auto_deploy.record_attempt(config, MAIN_SHA, now=old)
        self.assertEqual(production_auto_deploy.attempted_shas(config), {MAIN_SHA})

        recent = old + timedelta(days=200)
        production_auto_deploy.record_attempt(config, OTHER_SHA, now=recent)

        recorded = production_auto_deploy.attempted_shas(config)
        self.assertIn(OTHER_SHA, recorded)
        self.assertNotIn(MAIN_SHA, recorded, "an aged-out attempt should be pruned")

    def test_the_just_recorded_attempt_always_survives_pruning(self):
        """This is the invariant that stops a retry loop: whatever else is
        pruned, the revision being attempted right now must remain recorded."""

        config = self.loaded_config()
        now = datetime(2026, 8, 20, tzinfo=timezone.utc)
        # Fill the record past its cap with entries old enough to age out.
        stale = datetime(2020, 1, 1, tzinfo=timezone.utc)
        (config.state_root / "attempted").write_text(
            "".join(
                f"{index:040x} {production_auto_deploy._timestamp(stale)}\n"
                for index in range(80)
            ),
            encoding="ascii",
        )
        production_auto_deploy.record_attempt(config, MAIN_SHA, now=now)

        recorded = production_auto_deploy.attempted_shas(config)
        self.assertEqual(recorded, {MAIN_SHA})

    def test_pruning_an_all_legacy_record_empties_it(self):
        """Bare SHAs carry no age, so they cannot be kept once pruning runs.
        Documented deliberately: the entry being recorded is what protects the
        current revision, not the legacy rows."""

        now = datetime(2026, 8, 20, tzinfo=timezone.utc)
        self.assertEqual(
            production_auto_deploy._prune_attempts([(MAIN_SHA, None)], now), []
        )

    def test_a_record_from_an_older_poller_still_parses(self):
        config = self.loaded_config()
        (config.state_root / "attempted").write_text(
            f"{MAIN_SHA}\n{OTHER_SHA}\n", encoding="ascii"
        )
        self.assertEqual(
            production_auto_deploy.attempted_shas(config), {MAIN_SHA, OTHER_SHA}
        )

    def test_recording_the_same_sha_twice_keeps_one_entry(self):
        config = self.loaded_config()
        now = datetime(2026, 8, 20, tzinfo=timezone.utc)
        production_auto_deploy.record_attempt(config, MAIN_SHA, now=now)
        production_auto_deploy.record_attempt(
            config, MAIN_SHA, now=now + timedelta(minutes=5)
        )
        body = (config.state_root / "attempted").read_text(encoding="ascii")
        self.assertEqual(body.count(MAIN_SHA), 1)

    def test_the_lock_is_exclusive_across_processes(self):
        config = self.loaded_config()
        program = (
            "import sys\n"
            f"sys.path.insert(0, {str(SCRIPTS)!r})\n"
            "import production_auto_deploy as p\n"
            f"config = p.load_config({str(self.config_path)!r})\n"
            "with p.deployment_lock(config) as acquired:\n"
            "    sys.exit(0 if acquired is False else 1)\n"
        )
        with production_auto_deploy.deployment_lock(config) as acquired:
            self.assertTrue(acquired)
            probe = subprocess.run([sys.executable, "-c", program])
            self.assertEqual(probe.returncode, 0, "second holder should be refused")

    def test_the_lock_is_released_for_the_next_holder(self):
        config = self.loaded_config()
        with production_auto_deploy.deployment_lock(config) as first:
            self.assertTrue(first)
        with production_auto_deploy.deployment_lock(config) as second:
            self.assertTrue(second)


class DeployTest(PollerTestCase):
    def record_runs(self, returncode=0, fail_on=None):
        calls = []

        def run(arguments, **kwargs):
            rendered = [str(a) for a in arguments]
            calls.append((rendered, kwargs))
            code = returncode
            if fail_on is not None and any(fail_on in part for part in rendered):
                code = 1
            return subprocess.CompletedProcess(arguments, code, b"", b"")

        return calls, run

    def deploy_with(self, config, **kwargs):
        calls, run = self.record_runs(**kwargs)
        with mock.patch.object(production_auto_deploy, "_run", side_effect=run):
            outcome = production_auto_deploy.deploy(config, MAIN_SHA, None)
        return outcome, [call[0] for call in calls], [call[1] for call in calls]

    def test_deploy_checks_out_then_syncs_tooling_then_runs_the_plays(self):
        config = self.loaded_config()
        outcome, calls, _kwargs = self.deploy_with(config)

        self.assertTrue(outcome)
        self.assertEqual(len(calls), 7)

        self.assertEqual(calls[0][:2], ["git", "fetch"])
        self.assertEqual(calls[1][:3], ["git", "checkout", "--detach"])
        self.assertEqual(calls[1][3], MAIN_SHA)

        self.assertTrue(calls[2][0].endswith("pip"))
        self.assertIn("--requirement", calls[2])
        self.assertTrue(calls[2][-1].endswith("controller-requirements.txt"))

        playbooks = [call[-1] if "--tags" not in call else call[-3] for call in calls[3:]]
        self.assertEqual(
            playbooks,
            [
                "validate-vault.yml",
                "site.yml",
                "verify.yml",
                "install-production-auto-deploy.yml",
            ],
        )

    def test_tooling_is_synchronised_before_any_ansible_process_starts(self):
        """The pins being installed are the ones ansible itself will run under."""

        config = self.loaded_config()
        _outcome, calls, _kwargs = self.deploy_with(config)
        pip_index = next(i for i, call in enumerate(calls) if call[0].endswith("pip"))
        first_ansible = next(
            i for i, call in enumerate(calls) if call[0] == "ansible-playbook"
        )
        self.assertLess(pip_index, first_ansible)

    def test_only_verify_receives_the_tag_list(self):
        config = self.loaded_config()
        _outcome, calls, _kwargs = self.deploy_with(config)
        tagged = [call for call in calls if "--tags" in call]
        self.assertEqual(len(tagged), 1)
        self.assertIn("verify.yml", tagged[0])
        self.assertEqual(
            tagged[0][tagged[0].index("--tags") + 1],
            "platform_verify_ntfy,platform_verify_beszel",
        )

    def test_every_play_carries_the_vault_arguments(self):
        config = self.loaded_config()
        _outcome, calls, _kwargs = self.deploy_with(config)
        for call in calls:
            if call[0] != "ansible-playbook":
                continue
            with self.subTest(play=call[-1]):
                self.assertIn("--vault-password-file", call)
                self.assertIn(str(config.vault_password_file), call)
                self.assertIn(f"@{config.vault_file}", call)

    def test_a_failed_checkout_stops_before_touching_tooling(self):
        config = self.loaded_config()
        outcome, calls, _kwargs = self.deploy_with(config, fail_on="checkout")
        self.assertFalse(outcome)
        self.assertTrue(all(not call[0].endswith("pip") for call in calls))
        self.assertTrue(all(call[0] != "ansible-playbook" for call in calls))

    def test_a_failed_tooling_sync_stops_before_any_play(self):
        config = self.loaded_config()
        outcome, calls, _kwargs = self.deploy_with(config, fail_on="pip")
        self.assertFalse(outcome)
        self.assertTrue(all(call[0] != "ansible-playbook" for call in calls))

    def test_deploy_stops_at_the_first_failing_play(self):
        config = self.loaded_config()
        outcome, calls, _kwargs = self.deploy_with(config, fail_on="site.yml")
        self.assertFalse(outcome)
        self.assertNotIn(
            "verify.yml", [part for call in calls for part in call]
        )

    def test_deploy_reports_failure_when_a_command_cannot_run(self):
        config = self.loaded_config()
        with mock.patch.object(
            production_auto_deploy, "_run", side_effect=OSError("no git")
        ):
            self.assertFalse(production_auto_deploy.deploy(config, MAIN_SHA, None))

    def test_plays_find_ansible_in_the_checkout_virtualenv(self):
        config = self.loaded_config()
        _outcome, calls, kwargs = self.deploy_with(config)
        expected = str(config.checkout / ".venv" / "bin")
        for call, options in zip(calls, kwargs):
            if call[0] != "ansible-playbook":
                continue
            entries = options["env"]["PATH"].split(os.pathsep)
            with self.subTest(play=call[-1]):
                self.assertEqual(entries[0], expected)
                self.assertIn("/usr/bin", entries)

    def test_no_command_receives_a_secret_through_its_environment(self):
        config = self.loaded_config()
        _outcome, _calls, kwargs = self.deploy_with(config)
        for options in kwargs:
            environment = options["env"]
            self.assertNotIn("ANSIBLE_VAULT_PASSWORD", environment)
            self.assertNotIn(str(config.vault_password_file), environment.values())

    def test_the_installed_poller_can_locate_a_real_ansible(self):
        """A smoke test that does not mock _run: the tooling path must resolve."""

        config = self.loaded_config()
        binary = config.checkout / ".venv" / "bin"
        binary.mkdir(parents=True)
        fake = binary / "ansible-playbook"
        fake.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake.chmod(0o700)
        environment = production_auto_deploy._ansible_environment(config)
        self.assertEqual(
            shutil.which("ansible-playbook", path=environment["PATH"]), str(fake)
        )


class RunTest(PollerTestCase):
    def test_run_streams_output_to_the_log_and_returns_it(self):
        sink = self.root / "sink"
        with sink.open("wb") as log:
            result = production_auto_deploy._run(
                [sys.executable, "-c", "print('hello')"], timeout=30, log=log
            )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"hello\n")
        self.assertEqual(sink.read_bytes(), b"hello\n")

    def test_run_merges_stderr_into_the_stream(self):
        result = production_auto_deploy._run(
            [sys.executable, "-c", "import sys; sys.stderr.write('bad\\n')"],
            timeout=30,
        )
        self.assertEqual(result.stdout, b"bad\n")

    def test_run_kills_the_whole_process_tree_on_timeout(self):
        program = (
            "import subprocess, sys, time\n"
            "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
            "time.sleep(60)\n"
        )
        with self.assertRaises(subprocess.TimeoutExpired):
            production_auto_deploy._run(
                [sys.executable, "-c", program], timeout=1
            )

    def test_run_reports_a_non_zero_exit(self):
        result = production_auto_deploy._run(
            [sys.executable, "-c", "raise SystemExit(3)"], timeout=30
        )
        self.assertEqual(result.returncode, 3)


class LogTest(PollerTestCase):
    def test_attempt_log_is_private_and_linked_as_latest(self):
        config = self.loaded_config()
        with production_auto_deploy.attempt_log(config, MAIN_SHA) as log:
            log.write(b"hello\n")
            path = Path(log.name)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.read_bytes(), b"hello\n")
        link = config.log_root / "latest"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), path.resolve())

    def test_latest_moves_to_the_newest_attempt(self):
        config = self.loaded_config()
        with production_auto_deploy.attempt_log(config, MAIN_SHA) as first:
            first_path = Path(first.name)
        with production_auto_deploy.attempt_log(config, OTHER_SHA) as second:
            second_path = Path(second.name)
        self.assertNotEqual(first_path, second_path)
        self.assertEqual((config.log_root / "latest").resolve(), second_path.resolve())

    def test_rotate_logs_removes_only_expired_attempt_logs(self):
        config = self.loaded_config()
        now = datetime(2026, 8, 20, tzinfo=timezone.utc)
        fresh = config.log_root / ("20260819T000000Z-" + MAIN_SHA)
        stale = config.log_root / ("20260101T000000Z-" + OTHER_SHA)
        unrelated = config.log_root / "notes.txt"
        for path in (fresh, stale, unrelated):
            path.write_bytes(b"")

        production_auto_deploy.rotate_logs(config, now)

        self.assertTrue(fresh.exists())
        self.assertFalse(stale.exists())
        self.assertTrue(unrelated.exists(), "only attempt logs are rotated")

    def test_rotate_logs_keeps_the_boundary_and_ignores_junk_names(self):
        config = self.loaded_config()
        now = datetime(2026, 8, 20, tzinfo=timezone.utc)
        boundary = config.log_root / ("20260721T000000Z-" + MAIN_SHA)
        malformed = config.log_root / ("20261399T999999Z-" + OTHER_SHA)
        for path in (boundary, malformed):
            path.write_bytes(b"")

        production_auto_deploy.rotate_logs(config, now)

        self.assertTrue(boundary.exists(), "30 days back is inside retention")
        self.assertTrue(malformed.exists(), "an unparsable stamp is left alone")


class NotifyTest(PollerTestCase):
    def test_notify_posts_the_outcome_through_the_protected_config(self):
        config = self.loaded_config()
        seen = {}

        def run(arguments, **kwargs):
            seen["arguments"] = [str(a) for a in arguments]
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        with mock.patch.object(production_auto_deploy, "_run", side_effect=run):
            self.assertTrue(
                production_auto_deploy.notify(
                    config, "success", MAIN_SHA, "start", "finish",
                    config.log_root / "latest",
                )
            )

        arguments = seen["arguments"]
        self.assertEqual(arguments[0], "curl")
        self.assertIn("--config", arguments)
        self.assertEqual(
            arguments[arguments.index("--config") + 1], str(config.ntfy_curl_config)
        )
        payload = json.loads(arguments[arguments.index("--data-binary") + 1])
        self.assertEqual(payload["outcome"], "success")
        self.assertEqual(payload["sha"], MAIN_SHA)

    def test_notify_never_places_a_token_on_the_command_line(self):
        config = self.loaded_config()
        config.ntfy_curl_config.write_text(
            'header = "Authorization: Bearer supersecret"\n', encoding="utf-8"
        )
        seen = {}

        def run(arguments, **kwargs):
            seen["arguments"] = [str(a) for a in arguments]
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        with mock.patch.object(production_auto_deploy, "_run", side_effect=run):
            production_auto_deploy.notify(
                config, "failed", MAIN_SHA, "start", "finish",
                config.log_root / "latest",
            )

        joined = " ".join(seen["arguments"])
        self.assertNotIn("supersecret", joined)
        self.assertNotIn("Bearer", joined)

    def test_notify_reports_failure_without_raising(self):
        config = self.loaded_config()
        for side_effect in (
            lambda *a, **k: subprocess.CompletedProcess([], 7, b"", b""),
            OSError("no curl"),
        ):
            with mock.patch.object(
                production_auto_deploy, "_run", side_effect=side_effect
            ):
                with self.subTest(side_effect=side_effect):
                    self.assertFalse(
                        production_auto_deploy.notify(
                            config, "failed", MAIN_SHA, "s", "f",
                            config.log_root / "latest",
                        )
                    )


class PollTest(PollerTestCase):
    GREEN_RUN = EligibilityTest.GREEN_RUN

    @contextlib.contextmanager
    def eligible(self, sha, green=True):
        runs = ({**self.GREEN_RUN, "head_sha": sha},) if green else ()
        with mock.patch.object(
            production_auto_deploy, "resolve_main_sha", return_value=sha
        ), mock.patch.object(
            production_auto_deploy, "fetch_ci_runs", return_value=runs
        ), mock.patch.object(production_auto_deploy, "notify", return_value=True):
            yield

    def test_poll_deploys_a_green_unattempted_revision(self):
        config = self.loaded_config()
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ) as deploy:
            self.assertTrue(production_auto_deploy.poll(config))
        deploy.assert_called_once()
        state = production_auto_deploy.read_state(config)
        self.assertEqual(state["last_successful"]["sha"], MAIN_SHA)
        self.assertEqual(state["attempted"], [MAIN_SHA])

    def test_poll_is_a_no_op_once_the_revision_is_recorded(self):
        config = self.loaded_config()
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ):
            self.assertTrue(production_auto_deploy.poll(config))
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy"
        ) as deploy:
            self.assertIsNone(production_auto_deploy.poll(config))
        deploy.assert_not_called()

    def test_a_failed_revision_is_never_retried_automatically(self):
        config = self.loaded_config()
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", return_value=False
        ):
            self.assertFalse(production_auto_deploy.poll(config))
        self.assertIsNone(production_auto_deploy.read_state(config)["last_successful"])
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy"
        ) as deploy:
            self.assertIsNone(production_auto_deploy.poll(config))
        deploy.assert_not_called()

    def test_a_newer_revision_proceeds_after_an_earlier_failure(self):
        config = self.loaded_config()
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", return_value=False
        ):
            self.assertFalse(production_auto_deploy.poll(config))
        with self.eligible(OTHER_SHA), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ) as deploy:
            self.assertTrue(production_auto_deploy.poll(config))
        deploy.assert_called_once()
        self.assertEqual(
            production_auto_deploy.read_state(config)["last_successful"]["sha"],
            OTHER_SHA,
        )

    def test_the_attempt_is_recorded_before_deploying(self):
        config = self.loaded_config()
        seen = {}

        def explode(cfg, sha, log):
            seen["attempted"] = production_auto_deploy.attempted_shas(cfg)
            raise RuntimeError("power cut")

        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", side_effect=explode
        ):
            with self.assertRaises(RuntimeError):
                production_auto_deploy.poll(config)
        self.assertEqual(seen["attempted"], {MAIN_SHA})
        self.assertEqual(production_auto_deploy.attempted_shas(config), {MAIN_SHA})

    def test_poll_skips_a_revision_without_a_green_run(self):
        config = self.loaded_config()
        with self.eligible(MAIN_SHA, green=False), mock.patch.object(
            production_auto_deploy, "deploy"
        ) as deploy:
            self.assertIsNone(production_auto_deploy.poll(config))
        deploy.assert_not_called()
        self.assertEqual(production_auto_deploy.attempted_shas(config), set())

    def test_retry_runs_only_for_the_current_attempted_revision(self):
        config = self.loaded_config()
        production_auto_deploy.record_attempt(config, MAIN_SHA)
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ) as deploy:
            self.assertTrue(production_auto_deploy.poll(config, retry_sha=MAIN_SHA))
        deploy.assert_called_once()

    def test_retry_is_refused_for_an_unattempted_or_stale_revision(self):
        config = self.loaded_config()
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy"
        ) as deploy:
            self.assertIsNone(production_auto_deploy.poll(config, retry_sha=MAIN_SHA))
            production_auto_deploy.record_attempt(config, OTHER_SHA)
            self.assertIsNone(production_auto_deploy.poll(config, retry_sha=OTHER_SHA))
        deploy.assert_not_called()

    def test_retry_refuses_a_revision_already_deployed_successfully(self):
        """--retry-failed must mean failed; a successful SHA stays in the
        attempted record, so it would otherwise be redeployed on demand."""

        config = self.loaded_config()
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ):
            self.assertTrue(production_auto_deploy.poll(config))

        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy"
        ) as deploy:
            self.assertIsNone(production_auto_deploy.poll(config, retry_sha=MAIN_SHA))
        deploy.assert_not_called()

    def test_retry_rejects_a_malformed_sha(self):
        config = self.loaded_config()
        with self.assertRaises(production_auto_deploy.EligibilityError):
            production_auto_deploy.poll(config, retry_sha="nope")

    def test_a_failed_notification_is_recorded_rather_than_swallowed(self):
        config = self.loaded_config()
        with mock.patch.object(
            production_auto_deploy, "resolve_main_sha", return_value=MAIN_SHA
        ), mock.patch.object(
            production_auto_deploy,
            "fetch_ci_runs",
            return_value=({**self.GREEN_RUN, "head_sha": MAIN_SHA},),
        ), mock.patch.object(
            production_auto_deploy, "notify", return_value=False
        ), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ):
            buffer = io.StringIO()
            with contextlib.redirect_stderr(buffer):
                self.assertTrue(production_auto_deploy.poll(config))

        self.assertIn("notification failed", buffer.getvalue())
        latest = (config.log_root / "latest").resolve()
        self.assertIn("notification failed", latest.read_text(encoding="ascii"))
        # A lost notification must not cast doubt on the deployment itself.
        self.assertEqual(
            production_auto_deploy.read_state(config)["last_successful"]["sha"],
            MAIN_SHA,
        )

    def test_poll_declines_while_another_holder_deploys(self):
        config = self.loaded_config()
        program = (
            "import sys\n"
            f"sys.path.insert(0, {str(SCRIPTS)!r})\n"
            "import production_auto_deploy as p\n"
            f"config = p.load_config({str(self.config_path)!r})\n"
            "sys.exit(0 if p.poll(config) is None else 1)\n"
        )
        with production_auto_deploy.deployment_lock(config) as acquired:
            self.assertTrue(acquired)
            probe = subprocess.run([sys.executable, "-c", program])
            self.assertEqual(probe.returncode, 0)


class CliTest(PollerTestCase):
    def test_status_prints_recorded_state_and_exits_zero(self):
        production_auto_deploy.record_success(
            self.loaded_config(), MAIN_SHA, "2026-08-20T10:00:00Z"
        )
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = production_auto_deploy.main(
                ["--config", str(self.config_path), "--status"]
            )
        self.assertEqual(code, 0)
        self.assertIn(MAIN_SHA, buffer.getvalue())

    def test_invalid_arguments_exit_two(self):
        for argv in (
            [],
            ["--status"],
            ["--config", str(self.config_path)],
            ["--config", str(self.config_path), "--poll", "--status"],
            ["--config", str(self.config_path), "--retry-failed", "nope"],
            ["--config", str(self.config_path), "--retry-failed"],
            ["--config", str(self.config_path), "--poll", "extra"],
        ):
            with self.subTest(argv=argv):
                self.assertEqual(production_auto_deploy.main(argv), 2)

    def test_a_failed_attempt_exits_one_and_a_no_op_exits_zero(self):
        with mock.patch.object(production_auto_deploy, "poll", return_value=False):
            self.assertEqual(
                production_auto_deploy.main(
                    ["--config", str(self.config_path), "--poll"]
                ),
                1,
            )
        with mock.patch.object(production_auto_deploy, "poll", return_value=None):
            self.assertEqual(
                production_auto_deploy.main(
                    ["--config", str(self.config_path), "--poll"]
                ),
                0,
            )

    def test_an_ineligible_poll_exits_zero(self):
        with mock.patch.object(
            production_auto_deploy,
            "poll",
            side_effect=production_auto_deploy.EligibilityError("nope"),
        ):
            self.assertEqual(
                production_auto_deploy.main(
                    ["--config", str(self.config_path), "--poll"]
                ),
                0,
            )

    def test_an_unusable_configuration_exits_one(self):
        self.config_path.write_text("{}", encoding="utf-8")
        self.assertEqual(
            production_auto_deploy.main(["--config", str(self.config_path), "--poll"]),
            1,
        )


if __name__ == "__main__":
    unittest.main()
