"""Behavioural tests for the production auto-deploy poller."""

import contextlib
from datetime import datetime, timedelta, timezone
import io
import itertools
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
# A third revision, for the walk back from a head whose run is still going.
OLDER_SHA = "c" * 40


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
            "vault_password_file": str(self.password),
            "ntfy_curl_config": str(self.notifier),
            "ntfy_topic_critical": "nas-critical",
            "ntfy_topic_deployment": "nas-deployment",
            "platform_nas_address": "192.168.0.139",
            "platform_public_host": "192.168.0.139",
            "platform_callback_host": "192.168.0.139",
            "github_api_base": "https://api.github.com",
            "log_retention_days": 30,
            "verify_tags": "platform_verify_ntfy,platform_verify_beszel",
            "git_path": "/usr/local/bin/git",
            "curl_path": "/usr/bin/curl",
            "tool_path": "/usr/local/bin:/usr/bin:/bin",
            "ansible_locale": "en_US.UTF-8",
            "external_scheduler": True,
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

    def verdict_of(self, runs):
        return production_auto_deploy.ci_verdict(self.loaded_config(), MAIN_SHA, runs)[0]

    def test_exactly_one_matching_success_is_green(self):
        self.assertEqual(
            self.verdict_of((self.GREEN_RUN,)), production_auto_deploy.CI_GREEN
        )

    def test_ambiguity_is_not_green(self):
        self.assertEqual(
            self.verdict_of((self.GREEN_RUN, self.GREEN_RUN)),
            production_auto_deploy.CI_AMBIGUOUS,
        )

    def test_no_runs_is_not_green(self):
        self.assertEqual(self.verdict_of(()), production_auto_deploy.CI_PENDING)

    def test_every_field_must_match(self):
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
                self.assertNotEqual(
                    self.verdict_of((run,)), production_auto_deploy.CI_GREEN
                )

    def test_verdict_separates_a_red_run_from_one_that_has_not_finished(self):
        config = self.loaded_config()
        red = {
            **self.GREEN_RUN,
            "conclusion": "failure",
            "html_url": "https://github.com/o/r/actions/runs/1",
        }

        self.assertEqual(
            production_auto_deploy.ci_verdict(config, MAIN_SHA, (red,)),
            (
                production_auto_deploy.CI_FAILED,
                "failure",
                "https://github.com/o/r/actions/runs/1",
            ),
        )
        self.assertEqual(
            production_auto_deploy.ci_verdict(config, MAIN_SHA, ())[0],
            production_auto_deploy.CI_PENDING,
        )
        self.assertEqual(
            production_auto_deploy.ci_verdict(config, MAIN_SHA, (self.GREEN_RUN,))[0],
            production_auto_deploy.CI_GREEN,
        )

    def test_verdict_reports_the_newest_conclusion_and_names_ambiguity(self):
        """The newest run that judged the revision is the verdict, so a
        cancelled re-run cannot bury the failure that prompted it."""

        config = self.loaded_config()
        newest = {**self.GREEN_RUN, "conclusion": "cancelled"}
        older = {**self.GREEN_RUN, "conclusion": "timed_out"}

        verdict, detail, _url = production_auto_deploy.ci_verdict(
            config, MAIN_SHA, (newest, older)
        )
        self.assertEqual((verdict, detail), (production_auto_deploy.CI_FAILED, "timed_out"))

        verdict, detail, _url = production_auto_deploy.ci_verdict(
            config, MAIN_SHA, (self.GREEN_RUN, self.GREEN_RUN)
        )
        self.assertEqual(verdict, production_auto_deploy.CI_AMBIGUOUS)
        self.assertIn("exactly one is required", detail)

    def test_a_cancelled_run_is_superseded_rather_than_refused(self):
        """A run can end without ever judging the revision it was running: by
        hand, or `skipped`, `stale` or `neutral`, and — until `cancel-in-progress`
        was confined to pull requests — by the next merge cancelling it. Reading
        any of those as a red main pages a human for a verdict nobody reached."""

        config = self.loaded_config()

        for conclusion in ("cancelled", "skipped", "stale", "neutral"):
            run = {**self.GREEN_RUN, "conclusion": conclusion}
            with self.subTest(conclusion=conclusion):
                verdict, detail, _url = production_auto_deploy.ci_verdict(
                    config, MAIN_SHA, (run,)
                )
                self.assertEqual(verdict, production_auto_deploy.CI_SUPERSEDED)
                self.assertEqual(detail, conclusion)

    def test_an_unrecognised_conclusion_still_refuses_the_revision(self):
        """An answer from CI this poller has never heard of is exactly what
        should stop a deployment rather than pass unnoticed."""

        config = self.loaded_config()
        for conclusion in ("failure", "timed_out", "startup_failure", "moon", None):
            run = {**self.GREEN_RUN, "conclusion": conclusion}
            with self.subTest(conclusion=conclusion):
                self.assertEqual(
                    production_auto_deploy.ci_verdict(config, MAIN_SHA, (run,))[0],
                    production_auto_deploy.CI_FAILED,
                )

    def test_a_cancelled_run_does_not_unseat_a_successful_one(self):
        config = self.loaded_config()
        cancelled = {**self.GREEN_RUN, "conclusion": "cancelled"}

        self.assertEqual(
            production_auto_deploy.ci_verdict(
                config, MAIN_SHA, (cancelled, self.GREEN_RUN)
            )[0],
            production_auto_deploy.CI_GREEN,
        )

    def test_verdict_ignores_runs_of_another_branch_workflow_or_revision(self):
        config = self.loaded_config()
        for key, bad in (
            ("head_sha", OTHER_SHA),
            ("event", "workflow_dispatch"),
            ("head_branch", "topic"),
            ("name", "Lint"),
        ):
            run = {**self.GREEN_RUN, "conclusion": "failure", key: bad}
            with self.subTest(key=key):
                self.assertEqual(
                    production_auto_deploy.ci_verdict(config, MAIN_SHA, (run,))[0],
                    production_auto_deploy.CI_PENDING,
                )

    def test_verdict_drops_a_run_url_it_cannot_trust(self):
        config = self.loaded_config()
        for url in (None, 42, "javascript:alert(1)", "http://github.com/o/r", ""):
            run = {**self.GREEN_RUN, "conclusion": "failure", "html_url": url}
            with self.subTest(url=url):
                self.assertEqual(
                    production_auto_deploy.ci_verdict(config, MAIN_SHA, (run,))[2], ""
                )

    def test_resolve_main_sha_reads_ls_remote(self):
        config = self.loaded_config()
        with mock.patch.object(production_auto_deploy, "_run") as run:
            run.return_value = subprocess.CompletedProcess(
                [], 0, (MAIN_SHA + "\trefs/heads/main\n").encode("ascii"), b""
            )
            self.assertEqual(production_auto_deploy.resolve_main_sha(config), MAIN_SHA)
        arguments = [str(a) for a in run.call_args.args[0]]
        self.assertEqual(arguments[0], "/usr/local/bin/git")
        self.assertEqual(arguments[1:3], ["ls-remote", "--exit-code"])
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

    def test_fetch_ci_runs_requests_the_pinned_query_and_parses_runs(self):
        config = self.loaded_config()
        body = json.dumps({"workflow_runs": [self.GREEN_RUN, "junk"]}).encode("utf-8")
        with mock.patch.object(production_auto_deploy, "urlopen") as opener:
            opener.return_value.__enter__.return_value.read.return_value = body
            runs = production_auto_deploy.fetch_ci_runs(config)
        self.assertEqual(runs, (self.GREEN_RUN,))
        url = opener.call_args.args[0].full_url
        self.assertIn("/repos/yonatankarp/nas-platform/", url)
        self.assertIn("workflows/ci.yml/runs", url)
        self.assertIn("event=push", url)
        self.assertIn("branch=main", url)
        self.assertIn("status=completed", url)

    def test_fetch_ci_runs_asks_about_the_branch_rather_than_one_revision(self):
        """A per-revision query cannot see that the head is still running while
        the revision behind it has already passed, which is the whole question."""

        config = self.loaded_config()
        body = json.dumps({"workflow_runs": []}).encode("utf-8")
        with mock.patch.object(production_auto_deploy, "urlopen") as opener:
            opener.return_value.__enter__.return_value.read.return_value = body
            production_auto_deploy.fetch_ci_runs(config)
        url = opener.call_args.args[0].full_url
        self.assertNotIn("head_sha", url)
        self.assertIn(f"per_page={production_auto_deploy.CI_RUN_PAGE_SIZE}", url)
        self.assertGreater(
            production_auto_deploy.CI_RUN_PAGE_SIZE,
            1,
            "a page that holds one run cannot show a revision behind the head",
        )

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
                        production_auto_deploy.fetch_ci_runs(config)


class SelectionTest(PollerTestCase):
    """Which revision a poll picks when main has moved on since CI started.

    A run takes longer than the gap between merges, so the head of main is
    usually still going while the revision behind it has already passed. The
    poller used to look at the head and nothing else, which meant a green
    revision sat undeployed for as long as the next commit's run took.
    """

    GREEN_RUN = EligibilityTest.GREEN_RUN
    RED_RUN = {**EligibilityTest.GREEN_RUN, "conclusion": "failure"}

    def run_for(self, sha, **overrides):
        return {**self.GREEN_RUN, "head_sha": sha, **overrides}

    def select(self, runs, head=MAIN_SHA, retry_sha=None):
        return production_auto_deploy.select_revision(
            self.loaded_config(), head, runs, retry_sha
        )

    def test_a_running_head_is_stepped_over_for_the_revision_behind_it(self):
        selection = self.select((self.run_for(OTHER_SHA),))

        self.assertEqual(selection.candidate, OTHER_SHA)
        self.assertEqual(selection.judged, OTHER_SHA)

    def test_the_head_wins_once_its_own_run_is_green(self):
        selection = self.select(
            (self.run_for(MAIN_SHA), self.run_for(OTHER_SHA)),
        )

        self.assertEqual(selection.candidate, MAIN_SHA)

    def test_a_red_head_still_blocks_the_green_revision_behind_it(self):
        """A red main stops every deployment; stepping over a run that has not
        finished must not become stepping over one that failed."""

        selection = self.select(
            (self.run_for(MAIN_SHA, conclusion="failure"), self.run_for(OTHER_SHA)),
        )

        self.assertIsNone(selection.candidate)
        self.assertEqual(selection.judged, MAIN_SHA)
        self.assertEqual(selection.verdict[0], production_auto_deploy.CI_FAILED)

    def test_a_red_revision_behind_a_running_head_blocks_and_is_named(self):
        selection = self.select((self.run_for(OTHER_SHA, conclusion="failure"),))

        self.assertIsNone(selection.candidate)
        self.assertEqual(selection.judged, OTHER_SHA)
        self.assertEqual(selection.verdict[0], production_auto_deploy.CI_FAILED)

    def test_a_cancelled_revision_is_walked_past_to_the_green_one_behind_it(self):
        """Two merges inside one CI window leave the first revision cancelled.
        Stopping there would block on a run the workflow itself killed."""

        selection = self.select(
            (
                self.run_for(OTHER_SHA, conclusion="cancelled"),
                self.run_for(OLDER_SHA),
            ),
        )

        self.assertEqual(selection.candidate, OLDER_SHA)

    def test_a_run_of_cancelled_revisions_leaves_nothing_to_deploy_and_no_alarm(self):
        selection = self.select(
            (
                self.run_for(OTHER_SHA, conclusion="cancelled"),
                self.run_for(OLDER_SHA, conclusion="cancelled"),
            ),
        )

        self.assertIsNone(selection.candidate)
        self.assertEqual(selection.judged, MAIN_SHA)
        self.assertEqual(selection.verdict[0], production_auto_deploy.CI_PENDING)

    def test_a_failure_behind_a_cancelled_revision_still_blocks(self):
        selection = self.select(
            (
                self.run_for(OTHER_SHA, conclusion="cancelled"),
                self.run_for(OLDER_SHA, conclusion="failure"),
            ),
        )

        self.assertIsNone(selection.candidate)
        self.assertEqual(selection.judged, OLDER_SHA)
        self.assertEqual(selection.verdict[0], production_auto_deploy.CI_FAILED)

    def test_an_attempted_head_stops_the_walk_before_anything_older(self):
        """Everything behind an attempted revision has already had its turn;
        walking past it would put an older revision back on the NAS."""

        config = self.loaded_config()
        production_auto_deploy.record_attempt(config, MAIN_SHA)

        selection = self.select(
            (self.run_for(MAIN_SHA), self.run_for(OTHER_SHA)),
        )

        self.assertIsNone(selection.candidate)
        self.assertEqual(selection.attempted, MAIN_SHA)
        self.assertIsNone(selection.verdict)

    def test_a_revision_already_deployed_is_not_deployed_a_second_time(self):
        config = self.loaded_config()
        production_auto_deploy.record_attempt(config, OTHER_SHA)

        selection = self.select((self.run_for(OTHER_SHA),))

        self.assertIsNone(selection.candidate)
        self.assertEqual(selection.attempted, OTHER_SHA)

    def test_nothing_finished_reports_the_head_as_still_running(self):
        selection = self.select(())

        self.assertIsNone(selection.candidate)
        self.assertEqual(selection.judged, MAIN_SHA)
        self.assertEqual(selection.verdict[0], production_auto_deploy.CI_PENDING)

    def test_the_candidates_are_the_head_then_the_runs_newest_first(self):
        candidates = production_auto_deploy.candidate_revisions(
            self.loaded_config(),
            MAIN_SHA,
            (
                self.run_for(OTHER_SHA),
                self.run_for(OTHER_SHA, conclusion="failure"),
                self.run_for(OLDER_SHA),
            ),
        )

        self.assertEqual(candidates, [MAIN_SHA, OTHER_SHA, OLDER_SHA])

    def test_a_candidate_must_be_a_real_sha_from_the_gating_workflow(self):
        """These SHAs come from the network and end up as arguments to git."""

        candidates = production_auto_deploy.candidate_revisions(
            self.loaded_config(),
            MAIN_SHA,
            (
                self.run_for("../../etc/passwd"),
                self.run_for(OTHER_SHA.upper()),
                self.run_for(OTHER_SHA, head_branch="release"),
                self.run_for(OTHER_SHA, name="Nightly"),
                self.run_for(OTHER_SHA, event="pull_request"),
                self.run_for(OTHER_SHA, status="in_progress"),
                {"head_sha": None},
            ),
        )

        self.assertEqual(candidates, [MAIN_SHA])


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

    def test_a_quiet_poller_still_expires_old_attempts(self):
        """Recording an attempt prunes as a side effect, so the age bound used
        to wait for the next deployment. A platform that changes rarely is
        exactly the one whose record would never be cleaned."""

        config = self.loaded_config()
        old = datetime.now(timezone.utc) - timedelta(
            days=production_auto_deploy.ATTEMPTED_RETENTION_DAYS + 1
        )
        production_auto_deploy.record_attempt(config, OTHER_SHA, now=old)
        self.assertEqual(production_auto_deploy.attempted_shas(config), {OTHER_SHA})

        production_auto_deploy.prune_attempts(config, datetime.now(timezone.utc))

        self.assertEqual(production_auto_deploy.attempted_shas(config), set())

    def test_pruning_keeps_an_attempt_inside_the_window(self):
        config = self.loaded_config()
        recent = datetime.now(timezone.utc) - timedelta(
            days=production_auto_deploy.ATTEMPTED_RETENTION_DAYS - 1
        )
        production_auto_deploy.record_attempt(config, OTHER_SHA, now=recent)

        production_auto_deploy.prune_attempts(config, datetime.now(timezone.utc))

        self.assertEqual(production_auto_deploy.attempted_shas(config), {OTHER_SHA})

    def test_pruning_does_not_rewrite_a_record_it_did_not_change(self):
        """Twelve polls an hour rewriting unchanged state is twelve needless
        writes to the NAS's flash."""

        config = self.loaded_config()
        production_auto_deploy.record_attempt(config, MAIN_SHA)
        path = config.state_root / "attempted"
        os.utime(path, (0, 0))

        production_auto_deploy.prune_attempts(config, datetime.now(timezone.utc))

        self.assertEqual(path.stat().st_mtime, 0)

    def test_every_poll_prunes_the_record_and_rotates_the_logs(self):
        config = self.loaded_config()
        old = datetime.now(timezone.utc) - timedelta(
            days=production_auto_deploy.ATTEMPTED_RETENTION_DAYS + 1
        )
        production_auto_deploy.record_attempt(config, OLDER_SHA, now=old)

        with mock.patch.object(
            production_auto_deploy, "resolve_main_sha", return_value=MAIN_SHA
        ), mock.patch.object(
            production_auto_deploy, "fetch_ci_runs", return_value=()
        ):
            self.assertIsNone(production_auto_deploy.poll(config))

        self.assertEqual(production_auto_deploy.attempted_shas(config), set())

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

    def test_the_holder_records_who_it_is_while_it_holds(self):
        """Issue #326: the operator who lost the race could not tell what had
        happened, because the only thing the lock said was that it was taken.
        deployment_bundle reads this record to name the holder it refuses for."""

        config = self.loaded_config()
        with production_auto_deploy.deployment_lock(config, holder="operator converge"):
            record = production_auto_deploy.read_lock_holder(config)
        self.assertEqual(record["pid"], os.getpid())
        self.assertEqual(record["holder"], "operator converge")
        self.assertRegex(record["started"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_the_poll_records_itself_as_the_holder_by_default(self):
        config = self.loaded_config()
        with production_auto_deploy.deployment_lock(config):
            self.assertEqual(
                production_auto_deploy.read_lock_holder(config)["holder"], "poll"
            )

    def test_the_record_is_cleared_when_the_lock_is_released(self):
        """scripts/image_prune.py takes this same lock and writes no record, so a
        record left behind by the last deployment would name a finished process
        as the holder of a lock something else is holding now."""

        config = self.loaded_config()
        with production_auto_deploy.deployment_lock(config):
            pass
        self.assertIsNone(production_auto_deploy.read_lock_holder(config))
        self.assertEqual(production_auto_deploy.lock_path(config).read_bytes(), b"")

    def test_an_illegible_record_is_reported_as_no_record(self):
        config = self.loaded_config()
        production_auto_deploy.lock_path(config).write_text("[]\n", encoding="ascii")
        self.assertIsNone(production_auto_deploy.read_lock_holder(config))

    def test_the_lock_path_is_the_one_the_role_probes(self):
        """roles/deployment_bundle derives the same path from the account home,
        so a rename here that was not made there would be a lock nobody shares."""

        config = self.loaded_config()
        self.assertEqual(
            production_auto_deploy.lock_path(config),
            Path(config.state_root) / "deployment.lock",
        )


class DeployHarness:
    """Runs deploy() against recorded commands rather than real ones."""

    def record_runs(self, returncode=0, fail_on=None, stall_on=None):
        calls = []

        def run(arguments, **kwargs):
            rendered = [str(a) for a in arguments]
            calls.append((rendered, kwargs))
            if stall_on is not None and any(stall_on in part for part in rendered):
                # What _run raises when its own deadline expires, which is the
                # only way this suite can observe a stalled command without
                # waiting for one.
                raise subprocess.TimeoutExpired(rendered, kwargs["timeout"])
            code = returncode
            if fail_on is not None and any(fail_on in part for part in rendered):
                code = 1
            return subprocess.CompletedProcess(arguments, code, b"", b"")

        return calls, run

    @contextlib.contextmanager
    def running(self, **kwargs):
        """Record every command, its options and every backoff slept between them.

        The sleeps are recorded rather than taken. A retry ladder that really
        slept would put its backoff on the wall clock of the `static` job, which
        CLAUDE.md is emphatic is how that budget keeps being blown, and would
        measure Python's sleep rather than this file's behaviour.
        """

        calls, run = self.record_runs(**kwargs)
        slept: list[float] = []
        with mock.patch.object(
            production_auto_deploy, "_run", side_effect=run
        ), mock.patch.object(
            production_auto_deploy.time, "sleep", side_effect=slept.append
        ):
            yield calls, slept

    def deploy_with(self, config, **kwargs):
        with self.running(**kwargs) as (calls, _slept):
            outcome = production_auto_deploy.deploy(config, MAIN_SHA, None)
        return outcome, [call[0] for call in calls], [call[1] for call in calls]


class DeployTest(DeployHarness, PollerTestCase):
    def test_deploy_checks_out_then_syncs_tooling_then_runs_the_plays(self):
        config = self.loaded_config()
        outcome, calls, _kwargs = self.deploy_with(config)

        self.assertTrue(outcome)
        self.assertEqual(len(calls), 9)

        self.assertEqual([calls[0][0], calls[0][1]], ["/usr/local/bin/git", "fetch"])
        self.assertEqual(
            calls[1],
            [
                "/usr/local/bin/git",
                "merge-base",
                "--is-ancestor",
                MAIN_SHA,
                "FETCH_HEAD",
            ],
        )
        self.assertEqual(calls[2][:3], ["/usr/local/bin/git", "checkout", "--detach"])
        self.assertEqual(calls[2][3], MAIN_SHA)

        self.assertTrue(calls[3][0].endswith("pip"))
        self.assertIn("--requirement", calls[3])
        self.assertTrue(calls[3][-1].endswith("controller-requirements.txt"))

        self.assertTrue(calls[4][0].endswith("ansible-galaxy"))

        def playbook_of(call):
            # A playbook is a bare filename: vault arguments are paths or
            # key=value pairs and also end in .yml.
            names = [
                a
                for a in call
                if a.endswith(".yml")
                and "/" not in a
                and "=" not in a
                and not a.startswith("@")
            ]
            self.assertEqual(len(names), 1, f"one playbook per call, got {names}")
            return names[0]

        playbooks = [playbook_of(call) for call in calls[5:]]
        self.assertEqual(
            playbooks,
            [
                "validate-vault.yml",
                "site.yml",
                "verify.yml",
                "install-production-auto-deploy.yml",
            ],
        )

    def test_collections_are_installed_and_pointed_at_explicitly(self):
        """pip installs ansible-core but not Galaxy collections, and HOME is
        pinned, so an operator's ~/.ansible is deliberately not consulted."""

        config = self.loaded_config()
        _outcome, calls, kwargs = self.deploy_with(config)
        expected = str(config.checkout / ".venv" / "collections")

        galaxy = [c for c in calls if c[0].endswith("ansible-galaxy")]
        self.assertEqual(len(galaxy), 1)
        self.assertEqual(galaxy[0][1:3], ["collection", "install"])
        self.assertIn("--collections-path", galaxy[0])
        self.assertEqual(galaxy[0][galaxy[0].index("--collections-path") + 1], expected)
        self.assertTrue(galaxy[0][-3].endswith("requirements.yml"))

        for call, options in zip(calls, kwargs):
            if call[0] != "ansible-playbook":
                continue
            with self.subTest(play=" ".join(call[-1:])):
                self.assertEqual(options["env"]["ANSIBLE_COLLECTIONS_PATH"], expected)

    def test_collections_install_before_any_play_runs(self):
        config = self.loaded_config()
        _outcome, calls, _kwargs = self.deploy_with(config)
        galaxy_index = next(i for i, c in enumerate(calls) if c[0].endswith("ansible-galaxy"))
        first_play = next(i for i, c in enumerate(calls) if c[0] == "ansible-playbook")
        self.assertLess(galaxy_index, first_play)

    def test_a_failed_collection_sync_stops_before_any_play(self):
        """Still a stop, but a classified one: the install reaches
        galaxy.ansible.com, so an exhausted ladder there says nothing about the
        revision and the caller decides what it costs."""

        config = self.loaded_config()
        with self.running(fail_on="ansible-galaxy") as (calls, _slept):
            with self.assertRaises(production_auto_deploy.TransientDeploymentError):
                production_auto_deploy.deploy(config, MAIN_SHA, None)
        self.assertTrue(all(call[0][0] != "ansible-playbook" for call in calls))

    def test_tooling_is_synchronised_before_any_ansible_process_starts(self):
        """The pins being installed are the ones ansible itself will run under."""

        config = self.loaded_config()
        _outcome, calls, _kwargs = self.deploy_with(config)
        pip_index = next(i for i, call in enumerate(calls) if call[0].endswith("pip"))
        first_ansible = next(
            i for i, call in enumerate(calls) if call[0] == "ansible-playbook"
        )
        self.assertLess(pip_index, first_ansible)

    def test_the_self_reinstall_replays_the_installer_choices(self):
        """The fourth play reinstalls this poller. Without the installer's own
        variables the role rejects its own invocation, which is how a deploy
        can succeed through verification and still fail at the last step."""

        config = self.loaded_config()
        _outcome, calls, _kwargs = self.deploy_with(config)
        install = next(c for c in calls if "install-production-auto-deploy.yml" in c)
        joined = " ".join(install)
        self.assertIn(
            f"production_auto_deploy_public_host={config.platform_public_host}", joined
        )
        self.assertIn("production_auto_deploy_external_scheduler=true", joined)

    def test_the_reinstall_passes_scheduling_false_when_cron_is_managed(self):
        config = self.loaded_config(external_scheduler=False)
        _outcome, calls, _kwargs = self.deploy_with(config)
        install = next(c for c in calls if "install-production-auto-deploy.yml" in c)
        self.assertIn("production_auto_deploy_external_scheduler=false", " ".join(install))

    def test_only_the_install_play_receives_the_installer_variables(self):
        config = self.loaded_config()
        _outcome, calls, _kwargs = self.deploy_with(config)
        for call in calls:
            if call[0] != "ansible-playbook":
                continue
            if "install-production-auto-deploy.yml" in call:
                continue
            with self.subTest(play=" ".join(call[-1:])):
                self.assertNotIn("production_auto_deploy_public_host", " ".join(call))

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

    def test_every_play_carries_the_vault_password_provider(self):
        config = self.loaded_config()
        _outcome, calls, _kwargs = self.deploy_with(config)
        for call in calls:
            if call[0] != "ansible-playbook":
                continue
            with self.subTest(play=" ".join(call[-1:])):
                self.assertIn("--vault-password-file", call)
                self.assertIn(str(config.vault_password_file), call)

    def test_no_play_supplies_vault_values_outside_the_checkout(self):
        """Credentials come from the candidate's own committed group_vars.

        An out-of-checkout copy passed as extra vars outranks group_vars, so a
        stale one silently shadows the revision being deployed while every
        play still reports success. Only the password provider, which cannot
        be committed, stays outside.
        """

        config = self.loaded_config()
        _outcome, calls, _kwargs = self.deploy_with(config)
        for call in calls:
            if call[0] != "ansible-playbook":
                continue
            extra_vars = [
                call[index + 1] for index, item in enumerate(call) if item == "-e"
            ]
            with self.subTest(play=" ".join(call[-1:])):
                self.assertFalse(
                    [value for value in extra_vars if value.startswith("@")],
                    f"a play loaded an out-of-checkout vault: {extra_vars}",
                )
                self.assertFalse(
                    [
                        value
                        for value in extra_vars
                        if value.startswith("platform_vault_file=")
                    ],
                    f"a play overrode the vault identity: {extra_vars}",
                )

    def test_the_environment_does_not_redirect_the_vault_identity(self):
        config = self.loaded_config()
        _outcome, _calls, kwargs = self.deploy_with(config)
        for call_kwargs in kwargs:
            environment = (call_kwargs or {}).get("env") or {}
            self.assertNotIn("PLATFORM_VAULT_FILE", environment)

    def test_a_revision_no_longer_on_main_is_never_checked_out(self):
        """A revision behind the head is named by GitHub's record of what it
        ran, which is a record of the past. Only the branch just fetched says
        what main is now."""

        config = self.loaded_config()
        outcome, calls, _kwargs = self.deploy_with(config, fail_on="merge-base")

        self.assertFalse(outcome)
        self.assertNotIn("checkout", [part for call in calls for part in call])

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
            with self.subTest(play=" ".join(call[-1:])):
                self.assertEqual(entries[0], expected)
                self.assertIn("/usr/bin", entries)

    def test_ansible_runs_under_a_utf8_locale_without_lc_all(self):
        """Ansible refuses to run unless locale.getlocale() reports UTF-8, and
        setting LC_ALL alongside LANG is rejected on some platforms."""

        config = self.loaded_config()
        _outcome, calls, kwargs = self.deploy_with(config)
        for call, options in zip(calls, kwargs):
            if call[0] != "ansible-playbook":
                continue
            with self.subTest(play=" ".join(call[-1:])):
                self.assertEqual(options["env"]["LANG"], "en_US.UTF-8")
                self.assertNotIn("LC_ALL", options["env"])

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

    def test_the_plays_are_told_the_poller_already_holds_the_lock(self):
        """deploy() runs inside poll()'s lock, and deployment_bundle refuses a
        converge another process is running. Without this declaration the poller
        would be refused by the guard it installs, on every tick."""

        config = self.loaded_config()
        environment = production_auto_deploy._ansible_environment(config)
        self.assertEqual(
            environment[production_auto_deploy.LOCK_OWNER_ENVIRONMENT], str(os.getpid())
        )


class DeployBudgetTest(DeployHarness, PollerTestCase):
    """What the steps before the first play are allowed to cost.

    The timeout each command is given is recorded and asserted rather than
    waited out: the question is which budget the code chose, and a test that
    measured it with a stopwatch would answer that in wall time the `static` job
    has to pay for.
    """

    FETCH = "fetch"
    GALAXY = "ansible-galaxy"

    def timeouts_for(self, calls, program):
        return [
            options["timeout"]
            for rendered, options in calls
            if any(program in part for part in rendered)
        ]

    def test_nothing_before_the_plays_carries_the_hour_long_command_budget(self):
        """The general form of #351. COMMAND_TIMEOUT_SECONDS is an hour, which
        is the right budget for a converge and the wrong one for anything the
        poller runs while holding the deployment lock before it starts. Stated
        over every such call rather than over the fetch alone, so the next
        command added here inherits the rule instead of the defect.

        Bounded by the largest budget a step before the plays legitimately has,
        rather than by inequality with the hour: a ladder gives its first
        attempt whatever is left of its deadline, which is a hair under the
        constant, so `!= COMMAND_TIMEOUT_SECONDS` would hold even for a command
        handed the whole hour."""

        config = self.loaded_config()
        _outcome, calls, kwargs = self.deploy_with(config)
        examined = 0
        for call, options in zip(calls, kwargs):
            if call[0] == "ansible-playbook":
                continue
            examined += 1
            with self.subTest(command=call[0]):
                self.assertLessEqual(
                    options["timeout"], production_auto_deploy.TOOLING_TIMEOUT_SECONDS
                )
        # A floor, not non-emptiness: this list is derived from what deploy()
        # happens to run, and a guard over an empty one passes vacuously.
        self.assertGreaterEqual(examined, 4)

    def test_the_fetch_is_bounded_in_minutes_and_the_local_steps_below_that(self):
        config = self.loaded_config()
        _outcome, calls, kwargs = self.deploy_with(config)
        # argv[1] is the git subcommand, and the first three commands a deploy
        # runs are the three steps of the checkout.
        budgets = dict(
            zip((call[1] for call in calls[:3]), (o["timeout"] for o in kwargs[:3]))
        )

        self.assertEqual(sorted(budgets), ["checkout", "fetch", "merge-base"])
        # The fetch draws from a deadline, so its first attempt is given a hair
        # under the constant rather than the constant itself.
        self.assertLessEqual(
            budgets["fetch"], production_auto_deploy.GIT_FETCH_TIMEOUT_SECONDS
        )
        for step in ("merge-base", "checkout"):
            self.assertEqual(
                budgets[step], production_auto_deploy.GIT_LOCAL_TIMEOUT_SECONDS
            )
            # The relationship rather than the numbers: a transfer needs longer
            # than a local ref comparison, and this survives either constant
            # being retuned.
            self.assertGreater(budgets["fetch"], budgets[step])

    def test_a_stalled_fetch_is_abandoned_at_its_bound_and_not_retried_in_place(self):
        """The defect #351 names. A blackholed connection used to park the
        deployment lock for an hour; it now costs one bounded attempt, and the
        retry happens on the next tick with the lock released rather than
        immediately, when a killed fetch is least likely to succeed."""

        config = self.loaded_config()
        with self.running(stall_on=self.FETCH) as (calls, slept):
            with self.assertRaises(production_auto_deploy.TransientDeploymentError):
                production_auto_deploy.deploy(config, MAIN_SHA, None)

        timeouts = self.timeouts_for(calls, self.FETCH)
        self.assertEqual(len(timeouts), 1)
        self.assertLessEqual(
            timeouts[0], production_auto_deploy.GIT_FETCH_TIMEOUT_SECONDS
        )
        self.assertEqual(slept, [])

    def test_a_fast_fetch_failure_is_retried_before_the_tick_is_given_up(self):
        config = self.loaded_config()
        with self.running(fail_on=self.FETCH) as (calls, slept):
            with self.assertRaises(production_auto_deploy.TransientDeploymentError):
                production_auto_deploy.deploy(config, MAIN_SHA, None)

        self.assertEqual(
            len(self.timeouts_for(calls, self.FETCH)),
            production_auto_deploy.NETWORK_RETRY_ATTEMPTS,
        )
        self.assertEqual(
            slept, list(production_auto_deploy.NETWORK_RETRY_BACKOFF_SECONDS)
        )
        # Nothing after the fetch ran, and in particular nothing was checked out
        # from a fetch that did not land.
        self.assertTrue(all(self.FETCH in rendered for rendered, _ in calls))

    def test_the_collection_install_retries_within_the_budget_it_already_had(self):
        """Adding a ladder must not add lock time. The install keeps
        TOOLING_TIMEOUT_SECONDS, and the attempts share it."""

        config = self.loaded_config()
        with self.running(fail_on=self.GALAXY) as (calls, slept):
            with self.assertRaises(production_auto_deploy.TransientDeploymentError):
                production_auto_deploy.deploy(config, MAIN_SHA, None)

        timeouts = self.timeouts_for(calls, self.GALAXY)
        self.assertEqual(len(timeouts), production_auto_deploy.NETWORK_RETRY_ATTEMPTS)
        for timeout in timeouts:
            self.assertLessEqual(timeout, production_auto_deploy.TOOLING_TIMEOUT_SECONDS)
        self.assertEqual(
            slept, list(production_auto_deploy.NETWORK_RETRY_BACKOFF_SECONDS)
        )

    def test_a_stalled_collection_install_is_abandoned_rather_than_repeated(self):
        config = self.loaded_config()
        with self.running(stall_on=self.GALAXY) as (calls, slept):
            with self.assertRaises(production_auto_deploy.TransientDeploymentError):
                production_auto_deploy.deploy(config, MAIN_SHA, None)

        self.assertEqual(len(self.timeouts_for(calls, self.GALAXY)), 1)
        self.assertEqual(slept, [])

    def test_a_revision_rewritten_off_the_branch_is_neither_retried_nor_transient(self):
        """merge-base answers a question about this candidate. Retrying it would
        ask the same question again, and calling it transient would forgive a
        revision that is permanently ineligible."""

        config = self.loaded_config()
        with self.running(fail_on="merge-base") as (calls, slept):
            self.assertFalse(production_auto_deploy.deploy(config, MAIN_SHA, None))

        self.assertEqual(len([c for c in calls if "merge-base" in c[0]]), 1)
        self.assertEqual(slept, [])
        self.assertTrue(all("checkout" not in c[0] for c in calls))

    def test_a_stalled_local_git_step_is_transient_because_it_names_the_host(self):
        config = self.loaded_config()
        with self.running(stall_on="merge-base") as (_calls, _slept):
            with self.assertRaises(production_auto_deploy.TransientDeploymentError):
                production_auto_deploy.deploy(config, MAIN_SHA, None)

    def test_the_ladder_spends_one_budget_rather_than_one_per_attempt(self):
        """The property the whole change turns on, and the one a ladder gets
        wrong by default: retries=3 over an hour is three hours of held lock.
        Read against a clock that advances a fixed step per reading, the
        attempts must be given shrinking budgets that never exceed the first."""

        budget = 180.0
        for step, expected in ((50.0, 3), (100.0, 1)):
            with self.subTest(step=step):
                clock = itertools.count(step, step)
                timeouts = []

                def run(arguments, **kwargs):
                    timeouts.append(kwargs["timeout"])
                    return subprocess.CompletedProcess(arguments, 1, b"", b"")

                with mock.patch.object(
                    production_auto_deploy, "_run", side_effect=run
                ), mock.patch.object(
                    production_auto_deploy.time, "monotonic", side_effect=lambda: next(clock)
                ), mock.patch.object(
                    production_auto_deploy.time, "sleep"
                ):
                    with self.assertRaises(
                        production_auto_deploy.TransientDeploymentError
                    ):
                        production_auto_deploy._run_network_command(
                            ["/usr/local/bin/git", "fetch"],
                            failure="git fetch failed",
                            budget=budget,
                        )

                self.assertEqual(len(timeouts), expected)
                self.assertEqual(timeouts, sorted(timeouts, reverse=True))
                self.assertLessEqual(max(timeouts), budget)
                self.assertGreater(min(timeouts), 0)


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
    def published(self, config, outcome):
        """Return the ntfy publish body notify() would send for one outcome."""

        seen = {}

        def run(arguments, **kwargs):
            seen["arguments"] = [str(a) for a in arguments]
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        with mock.patch.object(production_auto_deploy, "_run", side_effect=run):
            delivered = production_auto_deploy.notify(
                config, outcome, MAIN_SHA,
                "2026-08-21T15:00:00Z", "2026-08-21T15:04:30Z",
                config.log_root / "20260821T150000Z-deploy.log",
            )
        arguments = seen["arguments"]
        body = json.loads(arguments[arguments.index("--data-binary") + 1])
        return delivered, arguments, body

    def test_notify_posts_through_the_protected_config(self):
        config = self.loaded_config()
        delivered, arguments, _body = self.published(config, "success")

        self.assertTrue(delivered)
        self.assertEqual(arguments[0], "/usr/bin/curl")
        self.assertIn("--config", arguments)
        self.assertEqual(
            arguments[arguments.index("--config") + 1], str(config.ntfy_curl_config)
        )

    def test_notify_publishes_ntfy_structured_json_not_a_raw_outcome_dict(self):
        """The body must be ntfy's publish schema, addressed to the root URL.

        Posting a JSON document to /<topic> makes ntfy treat it as literal
        message text, which is how deploy alerts arrived as unreadable JSON.
        """

        config = self.loaded_config()
        _delivered, _arguments, body = self.published(config, "success")

        self.assertEqual(
            sorted(body),
            ["markdown", "message", "priority", "tags", "title", "topic"],
        )
        self.assertTrue(body["markdown"])
        self.assertNotIn("outcome", body)
        self.assertNotIn("log_path", body)

    def test_notify_routes_success_to_the_events_topic_quietly(self):
        config = self.loaded_config()
        _delivered, _arguments, body = self.published(config, "success")

        self.assertEqual(body["topic"], "nas-deployment")
        self.assertEqual(body["priority"], 3)
        self.assertEqual(body["tags"], ["white_check_mark"])
        self.assertEqual(body["title"], f"Deployed \u00b7 {MAIN_SHA[:9]}")

    def test_notify_routes_failure_to_the_critical_topic_loudly(self):
        """Severity, not source, picks the topic: a failed deploy is critical."""

        config = self.loaded_config()
        _delivered, _arguments, body = self.published(config, "failed")

        self.assertEqual(body["topic"], "nas-critical")
        self.assertEqual(body["priority"], 5)
        self.assertEqual(body["tags"], ["warning", "skull"])
        self.assertEqual(body["title"], f"Deploy failed \u00b7 {MAIN_SHA[:9]}")

    def test_notify_message_states_commit_duration_and_log(self):
        config = self.loaded_config()
        _delivered, _arguments, body = self.published(config, "success")

        self.assertEqual(
            body["message"],
            "\n".join(
                (
                    f"**Commit:** `{MAIN_SHA}`",
                    "**Started:** `2026-08-21T15:00:00Z`",
                    "**Finished:** `2026-08-21T15:04:30Z`",
                    "**Duration:** `4m 30s`",
                    "**Log:** `"
                    + production_auto_deploy.markdown_escape(
                        str(config.log_root / "20260821T150000Z-deploy.log")
                    )
                    + "`",
                )
            ),
        )

    def test_notify_states_an_unknown_duration_rather_than_guessing(self):
        """Timestamps come from the poller, but a corrupt one must not crash it."""

        config = self.loaded_config()
        seen = {}

        def run(arguments, **kwargs):
            seen["arguments"] = [str(a) for a in arguments]
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        with mock.patch.object(production_auto_deploy, "_run", side_effect=run):
            production_auto_deploy.notify(
                config, "success", MAIN_SHA, "start", "finish",
                config.log_root / "latest",
            )

        arguments = seen["arguments"]
        body = json.loads(arguments[arguments.index("--data-binary") + 1])
        self.assertIn("**Duration:** `unknown`", body["message"])

    def test_notify_escapes_markdown_in_the_log_path(self):
        """The path is operator-controlled, but it lands inside markdown."""

        config = self.loaded_config()
        seen = {}

        def run(arguments, **kwargs):
            seen["arguments"] = [str(a) for a in arguments]
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        with mock.patch.object(production_auto_deploy, "_run", side_effect=run):
            production_auto_deploy.notify(
                config, "success", MAIN_SHA, "s", "f",
                config.log_root / "we*ird_[name].log",
            )

        arguments = seen["arguments"]
        body = json.loads(arguments[arguments.index("--data-binary") + 1])
        self.assertIn(r"we\*ird", body["message"])
        self.assertIn(r"\[name\]", body["message"])

    def test_notify_refuses_an_unknown_outcome(self):
        config = self.loaded_config()

        with mock.patch.object(production_auto_deploy, "_run") as run:
            with self.assertRaises(ValueError):
                production_auto_deploy.notify(
                    config, "partially", MAIN_SHA, "s", "f",
                    config.log_root / "latest",
                )
        run.assert_not_called()

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


class PollBlindnessTest(PollerTestCase):
    """A poller that cannot see main is silent today, and exits 0 while doing it.

    Silence is also what a healthy idle poll looks like, so an unreachable
    GitHub is indistinguishable from nothing to deploy until someone runs
    --status by hand. That is the failure worth alerting on.
    """

    def blind_poll(self, config, reason="GitHub request failed", delivered=True):
        published = []

        def fake_notify(_config, notification):
            published.append(notification)
            # `delivered` is what the real publish() reports when curl cannot
            # reach ntfy: attempted, not received. The distinction is the whole
            # point of the alarm path, so it is a parameter of the fake rather
            # than an always-true stub.
            return delivered

        with mock.patch.object(
            production_auto_deploy, "resolve_main_sha",
            side_effect=production_auto_deploy.EligibilityError(reason),
        ), mock.patch.object(production_auto_deploy, "publish", fake_notify):
            buffer = io.StringIO()
            with contextlib.redirect_stderr(buffer):
                with self.assertRaises(production_auto_deploy.EligibilityError):
                    production_auto_deploy.poll(config)
        self.last_stderr = buffer.getvalue()
        return published

    def seeing_poll(self, config, delivered=True):
        published = []

        def fake_notify(_config, notification):
            published.append(notification)
            return delivered

        state = production_auto_deploy.read_state(config)
        # fetch_ci_runs is stubbed because poll() reaches api.github.com through
        # it, and a unit test must not. Unstubbed, this helper made a real
        # request on every call: it passed while the network answered and raised
        # EligibilityError -- "GitHub request failed" -- the moment a runner's
        # connection to GitHub timed out, failing `static` on a diff that had
        # nothing to do with the poller. An empty page of runs is the same
        # decision the real one produced here anyway, because attempted_shas
        # already claims the head.
        with mock.patch.object(
            production_auto_deploy, "resolve_main_sha", return_value=MAIN_SHA
        ), mock.patch.object(
            production_auto_deploy, "fetch_ci_runs", return_value=()
        ), mock.patch.object(
            production_auto_deploy, "attempted_shas", return_value={MAIN_SHA}
        ), mock.patch.object(production_auto_deploy, "publish", fake_notify):
            buffer = io.StringIO()
            with contextlib.redirect_stderr(buffer):
                production_auto_deploy.poll(config)
        self.last_stderr = buffer.getvalue()
        del state
        return published

    def test_a_single_blind_poll_stays_quiet(self):
        """A transient blip at a five-minute cadence must not become an alert."""

        config = self.loaded_config()

        self.assertEqual(self.blind_poll(config), [])

    def test_sustained_blindness_alerts_once_on_the_critical_topic(self):
        config = self.loaded_config()

        for _poll in range(production_auto_deploy.BLIND_POLL_THRESHOLD - 1):
            self.assertEqual(self.blind_poll(config), [])
        published = self.blind_poll(config)

        self.assertEqual(len(published), 1)
        self.assertEqual(published[0]["topic"], "nas-critical")
        self.assertEqual(published[0]["priority"], 5)
        self.assertIn("GitHub request failed", published[0]["message"])
        self.assertIn(
            str(production_auto_deploy.BLIND_POLL_THRESHOLD), published[0]["message"]
        )

        # Still blind is not news; only the transition is.
        self.assertEqual(self.blind_poll(config), [])
        self.assertEqual(self.blind_poll(config), [])

    def test_recovery_is_announced_once_and_resets_the_count(self):
        config = self.loaded_config()
        for _poll in range(production_auto_deploy.BLIND_POLL_THRESHOLD):
            self.blind_poll(config)

        published = self.seeing_poll(config)
        self.assertEqual(len(published), 1)
        self.assertEqual(published[0]["topic"], "nas-deployment")
        self.assertIn("again", published[0]["message"])

        self.assertEqual(self.seeing_poll(config), [])
        # The count reset, so the next outage needs the full threshold again.
        for _poll in range(production_auto_deploy.BLIND_POLL_THRESHOLD - 1):
            self.assertEqual(self.blind_poll(config), [])
        self.assertEqual(len(self.blind_poll(config)), 1)

    def test_recovery_is_silent_when_blindness_never_reached_the_threshold(self):
        config = self.loaded_config()
        self.blind_poll(config)

        self.assertEqual(self.seeing_poll(config), [])

    def test_an_undeliverable_alarm_is_retried_until_it_lands(self):
        """The alarm is the only thing that makes blindness visible at all.

        Attempting it on exactly the poll where the count meets the threshold
        makes an unreachable publisher permanent silence: the count climbs past
        the threshold, the poller never says so again, and cron sees a success
        every five minutes.
        """

        config = self.loaded_config()
        for _poll in range(production_auto_deploy.BLIND_POLL_THRESHOLD - 1):
            self.assertEqual(self.blind_poll(config, delivered=False), [])

        attempted = self.blind_poll(config, delivered=False)
        self.assertEqual(len(attempted), 1)
        self.assertIn("blindness notification failed", self.last_stderr)

        retried = self.blind_poll(config, delivered=True)
        self.assertEqual(len(retried), 1)
        self.assertEqual(retried[0]["topic"], "nas-critical")
        # The count kept climbing while the alarm was retried, so the notice
        # that finally lands reports the outage as it actually stands.
        self.assertIn(
            f"`{production_auto_deploy.BLIND_POLL_THRESHOLD + 1}`",
            retried[0]["message"],
        )

        # Delivered once is delivered; the retry must not become a repeat.
        self.assertEqual(self.blind_poll(config), [])
        self.assertEqual(self.blind_poll(config), [])

    def test_a_count_already_past_the_threshold_is_not_read_as_announced(self):
        """State written by the previously installed poller carries no delivery.

        The poller that runs is the one installed by the last deployment, so a
        count this revision never wrote is exactly what it wakes up to. A count
        past the threshold is what both a delivered alarm and an undeliverable
        one leave behind, and inheriting one must not buy silence.
        """

        config = self.loaded_config()
        (config.state_root / "blind-polls").write_text(
            f"{production_auto_deploy.BLIND_POLL_THRESHOLD + 4}\n", encoding="ascii"
        )

        published = self.blind_poll(config)

        self.assertEqual(len(published), 1)
        self.assertEqual(published[0]["topic"], "nas-critical")

    def test_an_undeliverable_recovery_notice_is_retried_on_the_next_poll(self):
        config = self.loaded_config()
        for _poll in range(production_auto_deploy.BLIND_POLL_THRESHOLD):
            self.blind_poll(config)

        self.assertEqual(len(self.seeing_poll(config, delivered=False)), 1)
        self.assertIn("recovery notification failed", self.last_stderr)

        retried = self.seeing_poll(config)
        self.assertEqual(len(retried), 1)
        self.assertEqual(retried[0]["topic"], "nas-deployment")

        # Delivered, so the count is finally cleared and the all-clear stops.
        self.assertEqual(self.seeing_poll(config), [])
        self.assertEqual(
            (config.state_root / "blind-polls").read_text(encoding="ascii").strip(), "0"
        )

    def test_a_corrupt_blind_count_does_not_stop_the_poller(self):
        config = self.loaded_config()
        (config.state_root / "blind-polls").write_text("not-a-number\n", encoding="ascii")

        self.assertEqual(self.blind_poll(config), [])
        self.assertEqual(
            (config.state_root / "blind-polls").read_text(encoding="ascii").strip(), "1"
        )


    def test_the_count_and_the_marker_cannot_disagree_across_a_crashed_write(self):
        """#401: two facts that must agree, stored so that they could disagree.

        read_blind_polls reports 0 for a count file it cannot parse, and the
        blind-alarm marker persists independently of it. An empty count file
        beside an announced marker is therefore the one combination that
        silences the rest of an outage: the count climbs back to the threshold
        and finds the marker already set. The truncating write this poller used
        to do produced exactly that file, which is what the control below
        shows; the atomic one cannot.
        """

        config = self.loaded_config()
        for _poll in range(production_auto_deploy.BLIND_POLL_THRESHOLD):
            self.blind_poll(config)
        self.assertTrue(production_auto_deploy.read_blind_alarm(config))
        count_path = config.state_root / "blind-polls"
        seen = []
        real_fdopen = os.fdopen

        def watching_fdopen(descriptor, *arguments, **keywords):
            # Whatever is on disk here is whatever a crash here would leave.
            seen.append(count_path.read_bytes())
            return real_fdopen(descriptor, *arguments, **keywords)

        with mock.patch("os.fdopen", watching_fdopen):
            production_auto_deploy._write_blind_polls(config, 4)

        count_path.write_bytes(seen[0])
        self.assertEqual(production_auto_deploy.read_blind_polls(config), 3)
        self.assertTrue(production_auto_deploy.read_blind_alarm(config))

    def test_the_pre_354_write_could_strand_the_marker(self):
        """The negative control, carried through to the silence it caused.

        The same instrument against the body #354 replaced yields an empty
        count file, and the rest of this test is the consequence: three further
        blind polls, which is the whole threshold again, announce nothing.
        """

        config = self.loaded_config()
        for _poll in range(production_auto_deploy.BLIND_POLL_THRESHOLD):
            self.blind_poll(config)
        count_path = config.state_root / "blind-polls"
        seen = []
        real_fdopen = os.fdopen

        def legacy_write(path, payload):
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            seen.append(count_path.read_bytes())
            with real_fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())

        with mock.patch.object(production_auto_deploy, "_write_private", legacy_write):
            production_auto_deploy._write_blind_polls(config, 4)

        self.assertEqual(seen[0], b"")
        count_path.write_bytes(seen[0])
        self.assertEqual(production_auto_deploy.read_blind_polls(config), 0)
        self.assertTrue(production_auto_deploy.read_blind_alarm(config))

        announced = []
        for _poll in range(production_auto_deploy.BLIND_POLL_THRESHOLD):
            announced.extend(self.blind_poll(config))
        self.assertEqual(announced, [])

    def test_the_marker_is_cleared_before_the_count_is_zeroed(self):
        """Recovery writes two files, and only one order of them is safe.

        Zeroing the count first would leave a window whose contents are the
        #401 pair -- a count of 0 beside an announced marker -- reachable
        without any torn write at all, just a crash between two writes that
        each landed whole. Clearing the marker first leaves the opposite pair,
        which costs a duplicate alarm and never a missing one. The order is
        load-bearing, so it is pinned rather than left to line order.
        """

        config = self.loaded_config()
        for _poll in range(production_auto_deploy.BLIND_POLL_THRESHOLD):
            self.blind_poll(config)
        written = []
        real_write = production_auto_deploy._write_private

        def recording_write(path, payload):
            written.append(Path(path).name)
            real_write(path, payload)

        with mock.patch.object(
            production_auto_deploy, "_write_private", recording_write
        ):
            self.seeing_poll(config)

        self.assertEqual(written, ["blind-alarm", "blind-polls"])


class PrivateWriteTest(PollerTestCase):
    """State the poller must not lose, written so a crash cannot lose it.

    Every fact the poller keeps between polls goes through _write_private: the
    attempted record, the last successful revision, the CI refusal marker, and
    the blind-poll pair whose disagreement #401 is about. Before #354 the write
    truncated the target in place, so the whole window between the truncation
    and the write was a window in which the record simply was not there.

    The instrument below is the honest one for that claim: what a reader finds
    on disk at the instant the payload is being written is exactly what a crash
    at that instant would leave behind. Every assertion here is paired with the
    same assertion against the pre-#354 body, which is kept in this file for
    that purpose -- a passing test is only evidence if the same test fails on
    the code it replaced.
    """

    def setUp(self):
        super().setUp()
        self.target = self.root / ".local/share/nas-platform/state/record"
        self.target.write_bytes(b"5\n")
        self.target.chmod(0o600)

    @staticmethod
    def legacy_write(path, payload):
        """scripts/production_auto_deploy.py's _write_private before #354."""

        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())

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
        self.assertEqual(
            self.content_while_writing(production_auto_deploy._write_private), b"5\n"
        )
        self.assertEqual(self.target.read_bytes(), b"6\n")

    def test_the_pre_354_write_had_already_discarded_it(self):
        """The negative control: the same instrument, the body #354 replaced."""

        self.assertEqual(self.content_while_writing(self.legacy_write), b"")

    def test_a_pre_existing_loose_mode_target_is_repaired(self):
        """os.open's mode applies only at creation, so an existing file kept its own."""

        self.target.chmod(0o644)

        production_auto_deploy._write_private(self.target, b"6\n")

        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)

    def test_the_pre_354_poller_left_a_loose_mode_alone(self):
        """The negative control for the half the prune's copy had and this one lacked."""

        self.target.chmod(0o644)

        self.legacy_write(self.target, b"6\n")

        self.assertEqual(self.target.stat().st_mode & 0o777, 0o644)

    def test_a_failed_replacement_leaves_neither_a_loss_nor_a_temporary_file(self):
        with mock.patch("os.replace", side_effect=OSError("no space")):
            with self.assertRaises(OSError):
                production_auto_deploy._write_private(self.target, b"6\n")

        self.assertEqual(self.target.read_bytes(), b"5\n")
        self.assertEqual(
            sorted(entry.name for entry in self.target.parent.iterdir()), ["record"]
        )


class PollCiRefusalTest(PollerTestCase):
    """A revision CI refuses stops every deployment, so it must be announced."""

    GREEN_RUN = EligibilityTest.GREEN_RUN
    RED_RUN = {
        **EligibilityTest.GREEN_RUN,
        "conclusion": "failure",
        "html_url": "https://github.com/yonatankarp/nas-platform/actions/runs/17",
    }

    def poll_with(self, config, runs, sha=MAIN_SHA, delivered=True):
        """Run one poll against a fixed CI answer, capturing what it published."""

        published = []

        def fake_publish(_config, notification):
            published.append(notification)
            return delivered

        with mock.patch.object(
            production_auto_deploy, "resolve_main_sha", return_value=sha
        ), mock.patch.object(
            production_auto_deploy, "fetch_ci_runs", return_value=runs
        ), mock.patch.object(
            production_auto_deploy, "publish", side_effect=fake_publish
        ), mock.patch.object(
            production_auto_deploy, "notify", return_value=True
        ), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ):
            outcome = production_auto_deploy.poll(config)
        return published, outcome

    def test_a_red_run_alerts_once_on_the_critical_topic(self):
        config = self.loaded_config()

        published, outcome = self.poll_with(config, (self.RED_RUN,))

        self.assertIsNone(outcome)
        self.assertEqual(len(published), 1)
        self.assertEqual(published[0]["topic"], "nas-critical")
        self.assertEqual(published[0]["priority"], 4)
        self.assertIn(MAIN_SHA[:9], published[0]["title"])
        self.assertIn("failure", published[0]["message"])
        self.assertIn("actions/runs/17", published[0]["message"])
        # Nothing was attempted, so the revision stays deployable once it goes
        # green rather than being quarantined by the report.
        self.assertEqual(production_auto_deploy.attempted_shas(config), set())

    def test_the_same_red_revision_is_not_reported_every_five_minutes(self):
        config = self.loaded_config()

        self.assertEqual(len(self.poll_with(config, (self.RED_RUN,))[0]), 1)
        self.assertEqual(self.poll_with(config, (self.RED_RUN,))[0], [])
        self.assertEqual(self.poll_with(config, (self.RED_RUN,))[0], [])

    def test_ci_that_has_not_finished_stays_quiet(self):
        config = self.loaded_config()

        self.assertEqual(self.poll_with(config, ())[0], [])

    def test_a_cancelled_run_is_never_announced_as_a_red_main(self):
        """The alert says "no deployment until this revision passes CI" at
        priority 4. A run the workflow cancelled to make way for the next merge
        is not that, and it happens whenever two changes land together."""

        config = self.loaded_config()

        published, outcome = self.poll_with(
            config, ({**self.GREEN_RUN, "conclusion": "cancelled"},)
        )

        self.assertIsNone(outcome)
        self.assertEqual(published, [])

    def test_a_cancelled_run_clears_a_refusal_so_a_real_failure_reports_again(self):
        config = self.loaded_config()
        self.poll_with(config, (self.RED_RUN,))

        self.poll_with(config, ({**self.GREEN_RUN, "conclusion": "cancelled"},))
        self.assertEqual(production_auto_deploy.read_ci_refusal(config), "")

        self.assertEqual(len(self.poll_with(config, (self.RED_RUN,))[0]), 1)

    def test_ambiguous_successful_runs_are_reported_as_a_refusal(self):
        config = self.loaded_config()

        published, outcome = self.poll_with(
            config, (self.GREEN_RUN, self.GREEN_RUN)
        )

        self.assertIsNone(outcome)
        self.assertEqual(len(published), 1)
        self.assertIn("exactly one is required", published[0]["message"])

    def test_a_second_red_revision_is_reported_in_its_own_right(self):
        config = self.loaded_config()
        self.poll_with(config, (self.RED_RUN,))

        published, _outcome = self.poll_with(
            config,
            ({**self.RED_RUN, "head_sha": OTHER_SHA},),
            sha=OTHER_SHA,
        )

        self.assertEqual(len(published), 1)
        self.assertIn(OTHER_SHA[:9], published[0]["title"])

    def test_a_revision_that_goes_green_clears_the_refusal(self):
        config = self.loaded_config()
        self.poll_with(config, (self.RED_RUN,))

        published, outcome = self.poll_with(config, (self.GREEN_RUN,))

        self.assertTrue(outcome)
        self.assertEqual(published, [])
        self.assertEqual(production_auto_deploy.read_ci_refusal(config), "")

    def test_a_re_run_that_fails_again_is_reported_again(self):
        config = self.loaded_config()
        self.poll_with(config, (self.RED_RUN,))
        # A re-running workflow is no longer a completed run, so the poller
        # sees nothing for the revision until it concludes a second time.
        self.assertEqual(self.poll_with(config, ())[0], [])

        self.assertEqual(len(self.poll_with(config, (self.RED_RUN,))[0]), 1)

    def test_an_undelivered_refusal_is_reported_on_the_next_poll(self):
        config = self.loaded_config()

        self.assertEqual(len(self.poll_with(config, (self.RED_RUN,), delivered=False)[0]), 1)
        self.assertEqual(production_auto_deploy.read_ci_refusal(config), "")

        self.assertEqual(len(self.poll_with(config, (self.RED_RUN,))[0]), 1)

    def test_an_already_attempted_revision_leaves_the_refusal_untouched(self):
        config = self.loaded_config()
        self.poll_with(config, (self.RED_RUN,))
        recorded = production_auto_deploy.read_ci_refusal(config)
        production_auto_deploy.record_attempt(config, MAIN_SHA)

        published, outcome = self.poll_with(config, (self.GREEN_RUN,))

        self.assertIsNone(outcome)
        self.assertEqual(published, [])
        self.assertEqual(production_auto_deploy.read_ci_refusal(config), recorded)

    def test_an_unreadable_refusal_record_does_not_stop_the_poller(self):
        config = self.loaded_config()
        (config.state_root / "ci-refusal").write_bytes(b"\xff\xfe not ascii\n")

        self.assertEqual(len(self.poll_with(config, (self.RED_RUN,))[0]), 1)


class PollHarness:
    """One poll against an explicit view of the branch and its CI history."""

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

    @contextlib.contextmanager
    def seeing(self, head, runs):
        """One poll against an explicit branch history: `head` is main's tip,
        `runs` are the completed runs GitHub reports for the branch."""

        with mock.patch.object(
            production_auto_deploy, "resolve_main_sha", return_value=head
        ), mock.patch.object(
            production_auto_deploy, "fetch_ci_runs", return_value=runs
        ), mock.patch.object(production_auto_deploy, "notify", return_value=True):
            yield

    def green_run(self, sha):
        return {**self.GREEN_RUN, "head_sha": sha}


class PollTest(PollHarness, PollerTestCase):
    def test_poll_deploys_the_green_revision_behind_a_running_head(self):
        """The bug this replaced: a merge landing during a run left the
        revision that had just passed undeployed for the length of the next
        run, which is over half an hour."""

        config = self.loaded_config()
        with self.seeing(MAIN_SHA, (self.green_run(OTHER_SHA),)), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ) as deploy:
            self.assertTrue(production_auto_deploy.poll(config))

        self.assertEqual(deploy.call_args.args[1], OTHER_SHA)
        state = production_auto_deploy.read_state(config)
        self.assertEqual(state["last_successful"]["sha"], OTHER_SHA)
        self.assertEqual(state["attempted"], [OTHER_SHA])

    def test_a_cancelled_revision_does_not_hide_the_green_one_behind_it(self):
        config = self.loaded_config()
        runs = (
            {**self.GREEN_RUN, "head_sha": OTHER_SHA, "conclusion": "cancelled"},
            self.green_run(OLDER_SHA),
        )
        with self.seeing(MAIN_SHA, runs), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ) as deploy:
            self.assertTrue(production_auto_deploy.poll(config))

        self.assertEqual(deploy.call_args.args[1], OLDER_SHA)

    def test_the_head_deploys_in_its_own_right_once_its_run_finishes(self):
        """Stepping over a revision is not skipping it. Deploying its parent
        first must leave it deployable, and must not deploy it twice."""

        config = self.loaded_config()
        with self.seeing(MAIN_SHA, (self.green_run(OTHER_SHA),)), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ):
            production_auto_deploy.poll(config)

        history = (self.green_run(MAIN_SHA), self.green_run(OTHER_SHA))
        with self.seeing(MAIN_SHA, history), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ) as deploy:
            self.assertTrue(production_auto_deploy.poll(config))
        self.assertEqual(deploy.call_args.args[1], MAIN_SHA)

        with self.seeing(MAIN_SHA, history), mock.patch.object(
            production_auto_deploy, "deploy"
        ) as deploy:
            self.assertIsNone(production_auto_deploy.poll(config))
        deploy.assert_not_called()

    def test_a_deployed_revision_is_not_redeployed_behind_a_running_head(self):
        config = self.loaded_config()
        runs = (self.green_run(OTHER_SHA),)
        with self.seeing(MAIN_SHA, runs), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ):
            production_auto_deploy.poll(config)

        with self.seeing(MAIN_SHA, runs), mock.patch.object(
            production_auto_deploy, "deploy"
        ) as deploy:
            self.assertIsNone(production_auto_deploy.poll(config))
        deploy.assert_not_called()

    def test_retry_is_refused_once_a_newer_revision_is_deployable(self):
        """--retry-failed overrides the attempted record, not the ordering: it
        must not put an older revision back on the NAS."""

        config = self.loaded_config()
        with self.seeing(OTHER_SHA, (self.green_run(OTHER_SHA),)), mock.patch.object(
            production_auto_deploy, "deploy", return_value=False
        ):
            self.assertFalse(production_auto_deploy.poll(config))

        history = (self.green_run(MAIN_SHA), self.green_run(OTHER_SHA))
        with self.seeing(MAIN_SHA, history), mock.patch.object(
            production_auto_deploy, "deploy"
        ) as deploy:
            self.assertIsNone(
                production_auto_deploy.poll(config, retry_sha=OTHER_SHA)
            )
        deploy.assert_not_called()

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
            production_auto_deploy, "deploy", return_value=False
        ):
            buffer = io.StringIO()
            with contextlib.redirect_stderr(buffer):
                self.assertFalse(production_auto_deploy.poll(config))

        self.assertIn("notification failed", buffer.getvalue())
        latest = (config.log_root / "latest").resolve()
        self.assertIn("notification failed", latest.read_text(encoding="ascii"))
        # A lost notification must not cast doubt on the recorded state.
        self.assertIsNone(production_auto_deploy.read_state(config)["last_successful"])

    def test_a_successful_deployment_leaves_reporting_to_the_deployment(self):
        config = self.loaded_config()
        with mock.patch.object(
            production_auto_deploy, "resolve_main_sha", return_value=MAIN_SHA
        ), mock.patch.object(
            production_auto_deploy,
            "fetch_ci_runs",
            return_value=({**self.GREEN_RUN, "head_sha": MAIN_SHA},),
        ), mock.patch.object(
            production_auto_deploy, "notify", return_value=True
        ) as notified, mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ):
            self.assertTrue(production_auto_deploy.poll(config))

        # site.yml publishes the summary that says what shipped; a second
        # message here would carry a revision and say less.
        notified.assert_not_called()
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


class PollTransientFailureTest(PollHarness, PollerTestCase):
    """Who retries a deployment that never reached the target.

    Before #351 the answer was always an operator: the revision was recorded as
    attempted before the run and stayed recorded whatever went wrong, so one
    blip on github.com or galaxy.ansible.com quarantined it until somebody ran
    --retry-failed by hand, on a host whose whole premise is that nobody does.
    """

    def transient(self, message="git fetch failed"):
        return production_auto_deploy.TransientDeploymentError(message)

    def failing_poll(self, config, sha=MAIN_SHA, error=None):
        with self.eligible(sha), mock.patch.object(
            production_auto_deploy,
            "deploy",
            side_effect=[error if error is not None else self.transient()],
        ):
            return production_auto_deploy.poll(config)

    def test_a_transient_failure_leaves_the_revision_deployable_next_tick(self):
        config = self.loaded_config()
        self.assertFalse(self.failing_poll(config))
        self.assertEqual(production_auto_deploy.attempted_shas(config), set())

        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", return_value=True
        ) as deploy:
            self.assertTrue(production_auto_deploy.poll(config))
        deploy.assert_called_once()

    def test_a_transient_failure_is_still_reported_and_logged(self):
        """Forgiving the revision must not make the failure invisible: the tick
        was spent and the operator gets the same notification as any other
        failure."""

        config = self.loaded_config()
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", side_effect=[self.transient()]
        ), mock.patch.object(
            production_auto_deploy, "notify", return_value=True
        ) as notify:
            self.assertFalse(production_auto_deploy.poll(config))
        self.assertEqual(notify.call_args.args[1], "failed")
        latest = (config.log_root / "latest").resolve().read_text(encoding="ascii")
        self.assertIn("transient failure", latest)
        self.assertIn("git fetch failed", latest)

    def test_a_failure_that_is_not_transient_still_quarantines_the_revision(self):
        """The guard on the classification itself. TransientDeploymentError is a
        DeploymentError, so a broad except clause ordered ahead of it would
        forgive every failure -- including a converge that half-ran."""

        config = self.loaded_config()
        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", return_value=False
        ):
            self.assertFalse(production_auto_deploy.poll(config))
        self.assertEqual(production_auto_deploy.attempted_shas(config), {MAIN_SHA})

    def test_forgiveness_is_bounded_and_the_revision_ends_up_quarantined(self):
        """A cause that only looks transient must not be retried every five
        minutes forever: each attempt holds the deployment lock, so unbounded
        forgiveness is worse than the quarantine it replaces."""

        config = self.loaded_config()
        for tick in range(production_auto_deploy.TRANSIENT_FORGIVENESS_LIMIT):
            with self.subTest(tick=tick):
                self.assertFalse(self.failing_poll(config))
                self.assertEqual(production_auto_deploy.attempted_shas(config), set())

        self.assertFalse(self.failing_poll(config))
        self.assertEqual(production_auto_deploy.attempted_shas(config), {MAIN_SHA})

        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy"
        ) as deploy:
            self.assertIsNone(production_auto_deploy.poll(config))
        deploy.assert_not_called()

    def test_a_different_revision_starts_the_budget_over(self):
        config = self.loaded_config()
        for _tick in range(production_auto_deploy.TRANSIENT_FORGIVENESS_LIMIT):
            self.failing_poll(config, sha=OTHER_SHA)

        self.assertFalse(self.failing_poll(config, sha=MAIN_SHA))
        self.assertEqual(production_auto_deploy.attempted_shas(config), set())

    def test_an_operator_retry_starts_the_budget_over_too(self):
        """--retry-failed is the intervention that clears the quarantine.
        Inheriting the spent budget would re-quarantine the revision on the
        first blip after it."""

        config = self.loaded_config()
        for _tick in range(production_auto_deploy.TRANSIENT_FORGIVENESS_LIMIT + 1):
            self.failing_poll(config)
        self.assertEqual(production_auto_deploy.attempted_shas(config), {MAIN_SHA})

        with self.eligible(MAIN_SHA), mock.patch.object(
            production_auto_deploy, "deploy", side_effect=[self.transient()]
        ):
            self.assertFalse(production_auto_deploy.poll(config, retry_sha=MAIN_SHA))
        self.assertEqual(production_auto_deploy.attempted_shas(config), set())

    def test_a_counter_that_cannot_be_written_forgives_nothing(self):
        """Fails closed. A bound that cannot be recorded cannot be enforced, and
        the unbounded retry is the failure mode that matters."""

        config = self.loaded_config()
        with mock.patch.object(
            production_auto_deploy, "_write_private", side_effect=OSError
        ):
            self.assertFalse(
                production_auto_deploy.may_retry_after_transient_failure(
                    config, MAIN_SHA
                )
            )

    def test_an_unreadable_counter_reads_as_a_fresh_budget(self):
        config = self.loaded_config()
        (config.state_root / "transient-failures").write_text("junk\n", encoding="ascii")
        self.assertEqual(
            production_auto_deploy.read_transient_failures(config), (None, 0)
        )


class ConvergeTest(PollerTestCase):
    """The operator entry point that closes issue #326.

    A hand-run ansible-playbook took no lock, so a manual converge outliving the
    five-minute poll interval overlapped a poll and died 1463 tasks in on a
    containment guard. --converge is that same command under the poller's own
    lock: everything but the lock stays the operator's.
    """

    def fake_playbook(self, exit_code=0):
        """An ansible-playbook that reports what it was given and what it sees."""

        binary = self.root / "bin"
        binary.mkdir(exist_ok=True)
        record = self.root / "playbook-invocation.json"
        fake = binary / "ansible-playbook"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import fcntl, json, os, sys\n"
            f"lock = {str(self.root / '.local/share/nas-platform/state/deployment.lock')!r}\n"
            "descriptor = os.open(lock, os.O_RDONLY)\n"
            "try:\n"
            "    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
            "    held = False\n"
            "    fcntl.flock(descriptor, fcntl.LOCK_UN)\n"
            "except OSError:\n"
            "    held = True\n"
            "record = {\n"
            "    'argv': sys.argv[1:],\n"
            "    'owner': os.environ.get('PLATFORM_DEPLOYMENT_LOCK_OWNER'),\n"
            "    'held': held,\n"
            "    'cwd': os.getcwd(),\n"
            "    'lock_record': open(lock).read(),\n"
            "}\n"
            f"open({str(record)!r}, 'w').write(json.dumps(record))\n"
            f"sys.exit({exit_code})\n",
            encoding="utf-8",
        )
        fake.chmod(0o700)
        path = f"{binary}{os.pathsep}{os.environ.get('PATH', '')}"
        patched = mock.patch.dict(os.environ, {"PATH": path})
        patched.start()
        self.addCleanup(patched.stop)
        return record

    def test_converge_runs_the_operator_command_while_holding_the_lock(self):
        record = self.fake_playbook()

        code = production_auto_deploy.main(
            [
                "--config",
                str(self.config_path),
                "--converge",
                "--",
                "-i",
                "inventory/local.yml",
                "site.yml",
                "--ask-vault-pass",
            ]
        )

        self.assertEqual(code, 0)
        invocation = json.loads(record.read_text(encoding="utf-8"))
        self.assertEqual(
            invocation["argv"],
            ["-i", "inventory/local.yml", "site.yml", "--ask-vault-pass"],
        )
        self.assertTrue(invocation["held"], "the plays must run under the lock")
        # The plays refuse a converge somebody else is running, so the converge
        # that took the lock has to say the holder is its own.
        self.assertEqual(invocation["owner"], str(os.getpid()))
        self.assertEqual(invocation["cwd"], os.getcwd())
        # Read from inside the child, while the lock is still held: the record is
        # cleared on release precisely so nothing reads it afterwards.
        record = json.loads(invocation["lock_record"])
        self.assertEqual(record["holder"], "operator converge")
        self.assertEqual(record["pid"], os.getpid())

    def test_converge_reports_the_playbook_exit_code(self):
        self.fake_playbook(exit_code=2)
        code = production_auto_deploy.main(
            ["--config", str(self.config_path), "--converge", "site.yml"]
        )
        self.assertEqual(code, 2)

    def test_converge_passes_arguments_through_without_a_separator(self):
        record = self.fake_playbook()
        production_auto_deploy.main(
            ["--config", str(self.config_path), "--converge", "site.yml", "--check"]
        )
        self.assertEqual(
            json.loads(record.read_text(encoding="utf-8"))["argv"],
            ["site.yml", "--check"],
        )

    def test_converge_is_refused_while_another_deployment_holds_the_lock(self):
        self.fake_playbook()
        config = self.loaded_config()
        buffer = io.StringIO()
        with production_auto_deploy.deployment_lock(config, holder="poll") as acquired:
            self.assertTrue(acquired)
            with contextlib.redirect_stderr(buffer):
                code = production_auto_deploy.main(
                    ["--config", str(self.config_path), "--converge", "site.yml"]
                )
        self.assertEqual(code, 1)
        message = buffer.getvalue()
        self.assertIn("refusing to converge", message)
        self.assertIn(f"pid {os.getpid()}", message)
        self.assertIn("poll", message)

    def test_converge_without_a_command_is_an_invalid_invocation(self):
        buffer = io.StringIO()
        with contextlib.redirect_stderr(buffer):
            code = production_auto_deploy.main(
                ["--config", str(self.config_path), "--converge"]
            )
        self.assertEqual(code, 2)
        self.assertIn("invalid arguments", buffer.getvalue())

    def test_converge_reports_a_missing_ansible_playbook(self):
        buffer = io.StringIO()
        with mock.patch.dict(os.environ, {"PATH": str(self.root / "empty")}), \
                contextlib.redirect_stderr(buffer):
            code = production_auto_deploy.main(
                ["--config", str(self.config_path), "--converge", "site.yml"]
            )
        self.assertEqual(code, 1)
        self.assertIn("could not run ansible-playbook", buffer.getvalue())


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

    def status_text(self, sha=MAIN_SHA, runs=None, resolve_error=None):
        buffer = io.StringIO()
        resolve = (
            mock.patch.object(
                production_auto_deploy, "resolve_main_sha", side_effect=resolve_error
            )
            if resolve_error
            else mock.patch.object(
                production_auto_deploy, "resolve_main_sha", return_value=sha
            )
        )
        with resolve, mock.patch.object(
            production_auto_deploy, "fetch_ci_runs", return_value=runs or ()
        ), contextlib.redirect_stdout(buffer):
            production_auto_deploy.main(["--config", str(self.config_path), "--status"])
        return buffer.getvalue()

    GREEN_RUN = EligibilityTest.GREEN_RUN

    def test_status_says_it_would_deploy_a_green_unattempted_head(self):
        text = self.status_text(runs=(self.GREEN_RUN,))
        self.assertIn(f"current main: {MAIN_SHA}", text)
        self.assertIn("would deploy", text)

    def test_status_names_the_revision_it_would_deploy_behind_a_running_head(self):
        text = self.status_text(
            runs=({**self.GREEN_RUN, "head_sha": OTHER_SHA},)
        )
        self.assertIn(f"current main: {MAIN_SHA}", text)
        self.assertIn(f"would deploy {OTHER_SHA[:9]}", text)
        self.assertIn("has not finished its run", text)

    def test_status_distinguishes_waiting_for_ci_from_broken(self):
        """Silence is the normal outcome of a poll, so an idle poller and a
        broken one must not look the same."""

        text = self.status_text(runs=())
        self.assertIn("waiting", text)
        self.assertIn("no completed successful CI push run", text)

    def test_status_distinguishes_a_superseded_run_from_a_broken_one(self):
        text = self.status_text(
            runs=({**self.GREEN_RUN, "conclusion": "cancelled"},)
        )
        self.assertIn("waiting", text)
        self.assertIn("cancelled without judging it", text)
        self.assertNotIn("Fix main", text)

    def test_status_reports_a_deployed_head_as_nothing_to_do(self):
        config = self.loaded_config()
        production_auto_deploy.record_attempt(config, MAIN_SHA)
        production_auto_deploy.record_success(config, MAIN_SHA, "2026-08-21T10:00:00Z")
        text = self.status_text(runs=(self.GREEN_RUN,))
        self.assertIn("is deployed", text)

    def test_status_tells_you_how_to_retry_a_quarantined_head(self):
        config = self.loaded_config()
        production_auto_deploy.record_attempt(config, MAIN_SHA)
        text = self.status_text(runs=(self.GREEN_RUN,))
        self.assertIn("already attempted and failed", text)
        self.assertIn(f"--retry-failed {MAIN_SHA}", text)

    def test_status_names_the_ambiguous_run_trap(self):
        text = self.status_text(runs=(self.GREEN_RUN, self.GREEN_RUN))
        self.assertIn("2 successful push runs", text)
        self.assertIn("exactly one is required", text)

    def test_status_survives_being_offline(self):
        text = self.status_text(
            resolve_error=production_auto_deploy.EligibilityError("git query failed")
        )
        self.assertIn("could not resolve main", text)
        self.assertIn("last successful:", text)

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
