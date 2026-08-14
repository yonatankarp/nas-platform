#!/usr/bin/env python3

import contextlib
import dataclasses
import errno
from http.client import HTTPException
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "production_auto_deploy.py"
MAIN_SHA = "0123456789abcdef0123456789abcdef01234567"


def load_production_module():
    if not SCRIPT.exists():
        return None
    spec = importlib.util.spec_from_file_location("production_auto_deploy", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


production_auto_deploy = load_production_module()


class GithubHandler(BaseHTTPRequestHandler):
    def write_trickle(self, payload):
        self.server.trickle_started.set()
        try:
            for byte in payload:
                self.wfile.write(bytes([byte]))
                self.wfile.flush()
                time.sleep(self.server.response_trickle_interval)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.server.trickle_finished.set()

    def do_GET(self):
        self.server.requests.append((self.path, dict(self.headers)))
        if self.server.response_wire_trickle is not None:
            self.wfile.write(self.server.response_wire_prefix)
            self.wfile.flush()
            self.write_trickle(self.server.response_wire_trickle)
            self.close_connection = True
            return
        self.send_response(self.server.response_status)
        self.send_header("Content-Type", "application/json")
        for header, value in self.server.response_headers.items():
            self.send_header(header, value)
        if self.server.response_chunk_header_trickle:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.write_trickle(b"1" * 100)
            return
        if self.server.response_trickle_interval is not None:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.server.trickle_started.set()
            try:
                for byte in self.server.response_body:
                    self.wfile.write(b"1\r\n" + bytes([byte]) + b"\r\n")
                    self.wfile.flush()
                    time.sleep(self.server.response_trickle_interval)
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                self.server.trickle_finished.set()
            return
        if self.server.response_incomplete_chunk:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"100\r\n" + self.server.response_body)
            self.wfile.flush()
            self.close_connection = True
            return
        self.send_header("Content-Length", str(len(self.server.response_body)))
        self.end_headers()
        try:
            self.wfile.write(self.server.response_body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, _format, *_args):
        pass


class ProductionModuleImportTest(unittest.TestCase):
    def test_production_module_exists(self):
        self.assertIsNotNone(
            production_auto_deploy,
            "scripts/production_auto_deploy.py has not been implemented",
        )


@unittest.skipIf(production_auto_deploy is None, "production module is not implemented")
class ProductionAutoDeployTest(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name).resolve()
        self.fake_bin = self.root / "bin"
        self.fake_bin.mkdir()
        self.tool_calls = self.root / "tool-calls"
        self.tool_calls.write_text("", encoding="utf-8")

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), GithubHandler)
        self.httpd.requests = []
        self.httpd.response_status = 200
        self.httpd.response_headers = {}
        self.httpd.response_body = b'{"total_count": 0, "workflow_runs": []}'
        self.httpd.response_incomplete_chunk = False
        self.httpd.response_trickle_interval = None
        self.httpd.response_wire_prefix = b""
        self.httpd.response_wire_trickle = None
        self.httpd.response_chunk_header_trickle = False
        self.httpd.trickle_started = threading.Event()
        self.httpd.trickle_finished = threading.Event()
        self.server_thread = threading.Thread(
            target=self.httpd.serve_forever,
            daemon=True,
        )
        self.server_thread.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

        for directory in (
            "controller",
            "tooling",
            "state",
            "logs",
            "config",
        ):
            (self.root / directory).mkdir()
            (self.root / directory).chmod(0o700)
        for protected_file in (
            self.root / "config" / "vault.yml",
            self.root / "config" / "vault-password",
            self.root / "config" / "ntfy.curlrc",
        ):
            protected_file.write_text("test-only\n", encoding="utf-8")
            protected_file.chmod(0o600)
        self.state_sentinel = self.root / "state" / "sentinel"
        self.state_sentinel.write_text("unchanged\n", encoding="utf-8")

        self.config = {
            "repository": "yonatankarp/nas-platform",
            "repository_url": "https://github.com/yonatankarp/nas-platform.git",
            "workflow": "ci.yml",
            "workflow_name": "CI",
            "branch": "main",
            "controller_root": str(self.root / "controller"),
            "tooling_root": str(self.root / "tooling"),
            "state_root": str(self.root / "state"),
            "log_root": str(self.root / "logs"),
            "vault_file": str(self.root / "config" / "vault.yml"),
            "vault_password_file": str(self.root / "config" / "vault-password"),
            "ntfy_curl_config": str(self.root / "config" / "ntfy.curlrc"),
            "platform_nas_address": "192.168.0.139",
            "platform_public_host": "192.168.0.139",
            "platform_callback_host": "192.168.0.139",
            "github_api_base": "https://api.github.com",
            "log_retention_count": 20,
            "log_retention_days": 30,
        }
        self.loopback_api_base = f"http://127.0.0.1:{self.httpd.server_port}"
        self.github_request_urls = []
        self.loopback_opener = build_opener(production_auto_deploy.RejectRedirects())
        self.config_path = self.root / "config.json"
        self.write_config()
        self.install_fake("git", self.fake_git_source(MAIN_SHA))
        self.install_recording_fake("ansible-playbook")
        self.install_recording_fake("curl")

    def write_config(self):
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")

    def install_fake(self, name, source):
        path = self.fake_bin / name
        path.write_text(source, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def fake_git_source(self, sha):
        return (
            f"#!{sys.executable}\n"
            "import pathlib\n"
            "import sys\n"
            f"pathlib.Path({str(self.tool_calls)!r}).open('a').write("
            "'git ' + ' '.join(sys.argv[1:]) + '\\n')\n"
            "expected = ['ls-remote', '--exit-code', "
            "'https://github.com/yonatankarp/nas-platform.git', "
            "'refs/heads/main']\n"
            "if sys.argv[1:] != expected:\n"
            "    raise SystemExit(41)\n"
            f"print({sha!r} + '\\trefs/heads/main')\n"
        )

    def install_recording_fake(self, name):
        self.install_fake(
            name,
            f"#!{sys.executable}\n"
            "import pathlib\n"
            "import sys\n"
            f"pathlib.Path({str(self.tool_calls)!r}).open('a').write("
            f"{name!r} + ' ' + ' '.join(sys.argv[1:]) + '\\n')\n",
        )

    def successful_run(self, **overrides):
        run = {
            "head_sha": MAIN_SHA,
            "status": "completed",
            "conclusion": "success",
            "event": "push",
            "head_branch": "main",
            "name": "CI",
            "path": ".github/workflows/ci.yml",
            "repository": {"full_name": "yonatankarp/nas-platform"},
        }
        run.update(overrides)
        return run

    def respond_with_runs(self, runs, *, total_count=None):
        self.httpd.response_status = 200
        self.httpd.response_headers = {}
        self.httpd.response_body = json.dumps(
            {
                "total_count": len(runs) if total_count is None else total_count,
                "workflow_runs": runs,
            }
        ).encode()

    def open_github_request(self, request, *, timeout):
        self.github_request_urls.append(request.full_url)
        parsed = urlsplit(request.full_url)
        self.assertEqual(parsed.scheme, "https")
        self.assertEqual(parsed.netloc, "api.github.com")
        loopback_request = Request(
            f"{self.loopback_api_base}{parsed.path}?{parsed.query}",
            headers=dict(request.header_items()),
            method=request.get_method(),
        )
        return self.loopback_opener.open(loopback_request, timeout=timeout)

    def invoke_main(self, *arguments):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.dict(
            os.environ,
            {"PATH": str(self.fake_bin)},
            clear=False,
        ), mock.patch.object(
            production_auto_deploy,
            "urlopen",
            self.open_github_request,
        ), contextlib.redirect_stdout(
            stdout
        ), contextlib.redirect_stderr(
            stderr
        ):
            status = production_auto_deploy.main(
                list(arguments),
                config_path=self.config_path,
            )
        return status, stdout.getvalue(), stderr.getvalue()

    def state_snapshot(self):
        return {
            f"{root.name}/{path.relative_to(root)}": (
                path.read_bytes() if path.is_file() else None
            )
            for root in (self.root / "state", self.root / "logs")
            for path in sorted(root.rglob("*"))
        }

    def assert_no_mutation(self, before):
        self.assertEqual(self.state_snapshot(), before)
        calls = self.tool_calls.read_text(encoding="utf-8").splitlines()
        self.assertFalse(any(call.startswith("ansible-playbook ") for call in calls))
        self.assertFalse(any(call.startswith("curl ") for call in calls))

    def assert_ci_rejected(self, status, stdout, stderr, before):
        self.assertEqual(status, 0)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "production auto-deploy: no eligible CI run\n",
        )
        self.assert_no_mutation(before)

    def loaded_config(self):
        return production_auto_deploy.load_config(self.config_path)

    def state_path(self, name):
        return self.root / "state" / name

    def replace_state_root(self, suffix):
        state_root = self.root / "state"
        detached_root = self.root / f"state-{suffix}"
        state_root.rename(detached_root)
        state_root.mkdir()
        state_root.chmod(0o700)
        return detached_root

    def external_state_directory(self):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        external = Path(temporary_directory.name).resolve()
        external.chmod(0o700)
        sentinel = external / "sentinel"
        sentinel.write_text("external unchanged\n", encoding="utf-8")
        sentinel.chmod(0o600)
        return external

    def install_state_root_symlink(self, external):
        state_root = self.root / "state"
        moved_root = self.root / "state-pinned"
        state_root.rename(moved_root)
        state_root.symlink_to(external, target_is_directory=True)

        def restore():
            if state_root.is_symlink():
                state_root.unlink()
            if moved_root.exists():
                moved_root.rename(state_root)

        self.addCleanup(restore)
        return moved_root

    def external_snapshot(self, external):
        return {
            path.relative_to(external): path.read_bytes()
            for path in external.iterdir()
            if path.is_file()
        }

    def write_sha_state(self, name, sha, outcome):
        writer = getattr(production_auto_deploy, "write_sha_state", None)
        self.assertIsNotNone(writer, "protected state writer is missing")
        writer(
            self.state_path(name),
            sha,
            "2026-08-14T12:34:56Z",
            outcome,
        )

    def successful_ci_record(self, sha):
        return production_auto_deploy.CiRun(
            head_sha=sha,
            status="completed",
            conclusion="success",
            event="push",
            head_branch="main",
            name="CI",
        )

    @contextlib.contextmanager
    def candidate(self, sha):
        with mock.patch.object(
            production_auto_deploy,
            "resolve_main_sha",
            return_value=sha,
        ), mock.patch.object(
            production_auto_deploy,
            "fetch_ci_runs",
            return_value=(self.successful_ci_record(sha),),
        ):
            yield

    def poll_with_attempt(self, attempt, *, sha=MAIN_SHA, retry_sha=None):
        poller = getattr(production_auto_deploy, "poll", None)
        self.assertIsNotNone(poller, "stateful poller is missing")
        with self.candidate(sha), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            side_effect=attempt,
        ):
            return poller(self.loaded_config(), retry_sha=retry_sha)

    def test_config_and_ci_run_are_frozen_typed_records_with_exact_fields(self):
        loaded = production_auto_deploy.load_config(self.config_path)

        self.assertEqual(
            [field.name for field in dataclasses.fields(loaded)],
            list(self.config),
        )
        self.assertTrue(loaded.__dataclass_params__.frozen)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            loaded.branch = "other"

        run = production_auto_deploy.CiRun(
            head_sha=MAIN_SHA,
            status="completed",
            conclusion="success",
            event="push",
            head_branch="main",
            name="CI",
        )
        self.assertEqual(
            [field.name for field in dataclasses.fields(run)],
            [
                "head_sha",
                "status",
                "conclusion",
                "event",
                "head_branch",
                "name",
            ],
        )
        self.assertTrue(run.__dataclass_params__.frozen)

    def test_config_requires_exact_keys_and_value_types(self):
        cases = {
            "missing key": lambda payload: payload.pop("workflow_name"),
            "extra key": lambda payload: payload.update({"token": "secret"}),
            "wrong string type": lambda payload: payload.update({"branch": 1}),
            "boolean retention": lambda payload: payload.update(
                {"log_retention_count": True}
            ),
            "zero retention": lambda payload: payload.update({"log_retention_days": 0}),
        }
        for label, mutate in cases.items():
            with self.subTest(label=label):
                payload = dict(self.config)
                mutate(payload)
                self.config_path.write_text(json.dumps(payload), encoding="utf-8")
                with self.assertRaises(production_auto_deploy.ConfigurationError):
                    production_auto_deploy.load_config(self.config_path)

    def test_github_api_base_is_fixed_to_production_origin(self):
        self.config["github_api_base"] = self.loopback_api_base
        self.write_config()
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_main()

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "production auto-deploy: unsafe configuration\n",
        )
        self.assert_no_mutation(before)
        self.assertEqual(self.httpd.requests, [])
        self.assertEqual(self.tool_calls.read_text(encoding="utf-8"), "")

    def test_large_integer_config_is_rejected_without_parser_exception(self):
        self.config_path.write_text("9" * 5_000, encoding="utf-8")
        before = self.state_snapshot()

        try:
            status, stdout, stderr = self.invoke_main()
        except ValueError as error:
            self.fail(f"configuration parser exception escaped: {type(error).__name__}")

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "production auto-deploy: unsafe configuration\n",
        )
        self.assert_no_mutation(before)
        self.assertEqual(self.httpd.requests, [])

    def test_deeply_nested_config_is_rejected_without_parser_exception(self):
        depth = 150_000
        self.config_path.write_text(
            "[" * depth + "0" + "]" * depth,
            encoding="utf-8",
        )
        before = self.state_snapshot()

        try:
            status, stdout, stderr = self.invoke_main()
        except RecursionError as error:
            self.fail(f"configuration parser exception escaped: {type(error).__name__}")

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "production auto-deploy: unsafe configuration\n",
        )
        self.assert_no_mutation(before)
        self.assertEqual(self.httpd.requests, [])

    def test_exact_successful_push_ci_is_eligible(self):
        self.respond_with_runs([self.successful_run()])
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_main()

        self.assertEqual(status, 0)
        self.assertEqual(
            stdout,
            f"production auto-deploy: CI eligible for {MAIN_SHA}\n",
        )
        self.assertEqual(stderr, "")
        self.assert_no_mutation(before)
        self.assertEqual(len(self.httpd.requests), 1)
        self.assertEqual(
            self.github_request_urls,
            [
                "https://api.github.com/repos/yonatankarp/nas-platform/"
                "actions/workflows/ci.yml/runs?branch=main&event=push&"
                f"status=completed&head_sha={MAIN_SHA}&per_page=10"
            ],
        )
        request_path, headers = self.httpd.requests[0]
        parsed = urlsplit(request_path)
        self.assertEqual(
            parsed.path,
            "/repos/yonatankarp/nas-platform/actions/workflows/ci.yml/runs",
        )
        self.assertEqual(
            parse_qs(parsed.query),
            {
                "branch": ["main"],
                "event": ["push"],
                "status": ["completed"],
                "head_sha": [MAIN_SHA],
                "per_page": ["10"],
            },
        )
        self.assertNotIn("Authorization", headers)
        self.assertEqual(
            self.tool_calls.read_text(encoding="utf-8").splitlines(),
            [
                "git ls-remote --exit-code "
                "https://github.com/yonatankarp/nas-platform.git refs/heads/main"
            ],
        )

    def test_non_successful_or_absent_ci_is_rejected_without_mutation(self):
        cases = {
            "pending": [self.successful_run(status="in_progress", conclusion=None)],
            "failed": [self.successful_run(conclusion="failure")],
            "cancelled": [self.successful_run(conclusion="cancelled")],
            "absent": [],
        }
        for label, runs in cases.items():
            with self.subTest(label=label):
                self.respond_with_runs(runs)
                before = self.state_snapshot()
                status, stdout, stderr = self.invoke_main()
                self.assert_ci_rejected(status, stdout, stderr, before)

    def test_wrong_ci_identity_is_rejected_without_mutation(self):
        cases = {
            "repository": {"repository": {"full_name": "other/repository"}},
            "workflow": {"path": ".github/workflows/other.yml"},
            "name": {"name": "Other"},
            "branch": {"head_branch": "feature/not-main"},
            "event": {"event": "workflow_dispatch"},
            "sha": {"head_sha": "f" * 40},
        }
        for label, overrides in cases.items():
            with self.subTest(label=label):
                self.respond_with_runs([self.successful_run(**overrides)])
                before = self.state_snapshot()
                status, stdout, stderr = self.invoke_main()
                self.assert_ci_rejected(status, stdout, stderr, before)

    def test_ambiguous_duplicate_successful_runs_are_rejected_without_mutation(self):
        run = self.successful_run()
        self.respond_with_runs([run, dict(run)])
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_main()

        self.assert_ci_rejected(status, stdout, stderr, before)

    def test_incomplete_result_page_is_rejected_without_mutation(self):
        self.respond_with_runs([self.successful_run()], total_count=11)
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_main()

        self.assert_ci_rejected(status, stdout, stderr, before)

    def test_total_count_requires_exact_nonnegative_integer_and_list_match(self):
        cases = {
            "string": ("1", [self.successful_run()]),
            "boolean": (True, [self.successful_run()]),
            "negative": (-1, [self.successful_run()]),
            "zero mismatch": (0, [self.successful_run()]),
        }
        for label, (total_count, runs) in cases.items():
            with self.subTest(label=label):
                self.respond_with_runs(runs, total_count=total_count)
                before = self.state_snapshot()
                status, stdout, stderr = self.invoke_main()
                self.assert_ci_rejected(status, stdout, stderr, before)

    def test_unexpected_json_types_are_rejected_without_mutation(self):
        run_type_cases = {
            "run": "not-an-object",
            "head_sha": self.successful_run(head_sha=1),
            "status": self.successful_run(status=[]),
            "conclusion": self.successful_run(conclusion=True),
            "event": self.successful_run(event={}),
            "head_branch": self.successful_run(head_branch=1),
            "name": self.successful_run(name=None),
            "path": self.successful_run(path=1),
            "repository": self.successful_run(repository="wrong-type"),
            "repository full_name": self.successful_run(repository={"full_name": 1}),
        }
        payloads = [
            ("top level", []),
            ("workflow_runs", {"total_count": 0, "workflow_runs": {}}),
        ]
        payloads.extend(
            (label, {"total_count": 1, "workflow_runs": [run]})
            for label, run in run_type_cases.items()
        )
        for label, payload in payloads:
            with self.subTest(label=label):
                self.httpd.response_status = 200
                self.httpd.response_body = json.dumps(payload).encode()
                before = self.state_snapshot()
                status, stdout, stderr = self.invoke_main()
                self.assert_ci_rejected(status, stdout, stderr, before)

    def test_malformed_json_is_rejected_without_echoing_response(self):
        secret_body = b'{"workflow_runs":["TOP-SECRET-BODY"'
        self.httpd.response_body = secret_body
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_main()

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertNotIn("TOP-SECRET-BODY", stdout + stderr)

    def test_large_json_integer_is_rejected_without_parser_exception(self):
        self.httpd.response_body = b'{"workflow_runs":[' + b"9" * 5_000 + b"]}"
        before = self.state_snapshot()

        try:
            status, stdout, stderr = self.invoke_main()
        except ValueError as error:
            self.fail(f"JSON parser exception escaped: {type(error).__name__}")

        self.assert_ci_rejected(status, stdout, stderr, before)

    def test_deeply_nested_json_is_rejected_without_parser_exception(self):
        depth = 150_000
        self.httpd.response_body = (
            b'{"workflow_runs":' + b"[" * depth + b"0" + b"]" * depth + b"}"
        )
        before = self.state_snapshot()

        try:
            status, stdout, stderr = self.invoke_main()
        except RecursionError as error:
            self.fail(f"JSON parser exception escaped: {type(error).__name__}")

        self.assert_ci_rejected(status, stdout, stderr, before)

    def test_rate_limit_is_not_retried_or_echoed(self):
        secret_body = b'{"message":"rate limit SECRET-BODY"}'
        self.httpd.response_status = 403
        self.httpd.response_body = secret_body
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_main()

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertEqual(len(self.httpd.requests), 1)
        self.assertNotIn("SECRET-BODY", stdout + stderr)

    def test_incomplete_chunked_response_is_rejected_without_http_exception(self):
        self.httpd.response_body = b'{"workflow_runs":["TRUNCATED-SECRET"]}'
        self.httpd.response_incomplete_chunk = True
        before = self.state_snapshot()

        try:
            status, stdout, stderr = self.invoke_main()
        except HTTPException as error:
            self.fail(f"HTTP exception escaped: {type(error).__name__}")

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertEqual(len(self.httpd.requests), 1)
        self.assertNotIn("TRUNCATED-SECRET", stdout + stderr)

    def test_redirects_are_rejected_without_following_or_mutating(self):
        redirects = {
            "cross origin": "https://attacker.invalid/secret",
            "HTTPS downgrade": "http://api.github.com/secret",
        }
        for label, location in redirects.items():
            with self.subTest(label=label):
                self.httpd.requests = []
                self.httpd.response_status = 302
                self.httpd.response_headers = {"Location": location}
                self.httpd.response_body = b"redirect body SECRET-BODY"
                before = self.state_snapshot()

                status, stdout, stderr = self.invoke_main()

                self.assert_ci_rejected(status, stdout, stderr, before)
                self.assertEqual(len(self.httpd.requests), 1)
                self.assertNotIn("SECRET-BODY", stdout + stderr)

    def test_production_redirect_handler_rejects_untrusted_targets(self):
        handler_type = getattr(production_auto_deploy, "RejectRedirects", None)
        self.assertIsNotNone(handler_type, "production redirect policy is missing")
        handler = handler_type()
        request = Request("https://api.github.com/repos/example/project")
        for target in (
            "https://attacker.invalid/secret",
            "http://api.github.com/secret",
        ):
            with self.subTest(target=target):
                self.assertIsNone(
                    handler.redirect_request(
                        request,
                        None,
                        302,
                        "Found",
                        {},
                        target,
                    )
                )

    def test_trickled_response_obeys_one_total_deadline_without_thread_leak(self):
        self.httpd.response_body = b'{"total_count":0,"workflow_runs":[]}'
        self.httpd.response_trickle_interval = 0.05
        before = self.state_snapshot()

        started = time.monotonic()
        with mock.patch.object(
            production_auto_deploy,
            "NETWORK_TIMEOUT_SECONDS",
            0.2,
        ):
            status, stdout, stderr = self.invoke_main()
        elapsed = time.monotonic() - started

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertLess(elapsed, 0.8)
        self.assertTrue(self.httpd.trickle_started.is_set())
        self.assertTrue(self.httpd.trickle_finished.wait(1.0))

    def test_trickled_status_obeys_outer_deadline_and_restores_signal_state(self):
        self.httpd.response_trickle_interval = 0.02
        self.httpd.response_wire_trickle = b"HTTP/1.1 200 OK\r\n" + b"X" * 100
        previous_handler = signal.getsignal(signal.SIGALRM)
        previous_timer = signal.getitimer(signal.ITIMER_REAL)
        before = self.state_snapshot()

        started = time.monotonic()
        with mock.patch.object(
            production_auto_deploy,
            "NETWORK_TIMEOUT_SECONDS",
            0.1,
        ):
            status, stdout, stderr = self.invoke_main()
        elapsed = time.monotonic() - started

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertLess(elapsed, 0.6)
        self.assertTrue(self.httpd.trickle_started.is_set())
        self.assertTrue(self.httpd.trickle_finished.wait(1.0))
        self.assertIs(signal.getsignal(signal.SIGALRM), previous_handler)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), previous_timer)

    def test_trickled_header_obeys_outer_deadline_without_thread_leak(self):
        self.httpd.response_trickle_interval = 0.02
        self.httpd.response_wire_prefix = b"HTTP/1.1 200 OK\r\n"
        self.httpd.response_wire_trickle = b"X-Slow: " + b"x" * 100
        before = self.state_snapshot()

        started = time.monotonic()
        with mock.patch.object(
            production_auto_deploy,
            "NETWORK_TIMEOUT_SECONDS",
            0.1,
        ):
            status, stdout, stderr = self.invoke_main()
        elapsed = time.monotonic() - started

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertLess(elapsed, 0.6)
        self.assertTrue(self.httpd.trickle_started.is_set())
        self.assertTrue(self.httpd.trickle_finished.wait(1.0))

    def test_trickled_chunk_header_obeys_outer_deadline_without_thread_leak(self):
        self.httpd.response_trickle_interval = 0.02
        self.httpd.response_chunk_header_trickle = True
        before = self.state_snapshot()

        started = time.monotonic()
        with mock.patch.object(
            production_auto_deploy,
            "NETWORK_TIMEOUT_SECONDS",
            0.1,
        ):
            status, stdout, stderr = self.invoke_main()
        elapsed = time.monotonic() - started

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertLess(elapsed, 0.6)
        self.assertTrue(self.httpd.trickle_started.is_set())
        self.assertTrue(self.httpd.trickle_finished.wait(1.0))

    def test_outer_deadline_restores_existing_alarm_handler_and_timer(self):
        self.httpd.response_trickle_interval = 0.02
        self.httpd.response_wire_prefix = b"HTTP/1.1 200 OK\r\n"
        self.httpd.response_wire_trickle = b"X-Slow: " + b"x" * 100
        original_handler = signal.getsignal(signal.SIGALRM)
        original_timer = signal.getitimer(signal.ITIMER_REAL)
        before = self.state_snapshot()

        def prior_handler(_signal_number, _frame):
            pass

        signal.signal(signal.SIGALRM, prior_handler)
        signal.setitimer(signal.ITIMER_REAL, 5.0)
        started = time.monotonic()
        try:
            with mock.patch.object(
                production_auto_deploy,
                "NETWORK_TIMEOUT_SECONDS",
                0.1,
            ):
                status, stdout, stderr = self.invoke_main()

            remaining, interval = signal.getitimer(signal.ITIMER_REAL)
            self.assertEqual(status, 0)
            self.assertEqual(stdout, "")
            self.assertEqual(
                stderr,
                "production auto-deploy: no eligible CI run\n",
            )
            self.assert_no_mutation(before)
            self.assertTrue(self.httpd.trickle_finished.wait(1.0))
            self.assertIs(signal.getsignal(signal.SIGALRM), prior_handler)
            self.assertGreater(remaining, 4.0)
            self.assertLessEqual(remaining, 5.0)
            self.assertEqual(interval, 0.0)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, original_handler)
            elapsed = time.monotonic() - started
            if original_timer[0] > 0:
                signal.setitimer(
                    signal.ITIMER_REAL,
                    max(0.000001, original_timer[0] - elapsed),
                    original_timer[1],
                )

    def test_outer_deadline_does_not_postpone_shorter_existing_alarm(self):
        self.httpd.response_trickle_interval = 0.02
        self.httpd.response_wire_prefix = b"HTTP/1.1 200 OK\r\n"
        self.httpd.response_wire_trickle = b"X-Slow: " + b"x" * 100
        original_handler = signal.getsignal(signal.SIGALRM)
        original_timer = signal.getitimer(signal.ITIMER_REAL)
        prior_alarm_fired = threading.Event()
        before = self.state_snapshot()
        config = production_auto_deploy.load_config(self.config_path)

        def prior_handler(_signal_number, _frame):
            prior_alarm_fired.set()

        signal.signal(signal.SIGALRM, prior_handler)
        signal.setitimer(signal.ITIMER_REAL, 0.05)
        started = time.monotonic()
        try:
            with mock.patch.object(
                production_auto_deploy,
                "NETWORK_TIMEOUT_SECONDS",
                0.2,
            ), mock.patch.object(
                production_auto_deploy,
                "urlopen",
                self.open_github_request,
            ), self.assertRaises(
                production_auto_deploy.EligibilityError
            ):
                production_auto_deploy.fetch_ci_runs(config, MAIN_SHA)
            elapsed = time.monotonic() - started

            self.assert_no_mutation(before)
            self.assertLess(elapsed, 0.15)
            self.assertTrue(prior_alarm_fired.wait(0.2))
            self.assertTrue(self.httpd.trickle_finished.wait(1.0))
            self.assertIs(signal.getsignal(signal.SIGALRM), prior_handler)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, original_handler)
            elapsed = time.monotonic() - started
            if original_timer[0] > 0:
                signal.setitimer(
                    signal.ITIMER_REAL,
                    max(0.000001, original_timer[0] - elapsed),
                    original_timer[1],
                )

    def test_response_larger_than_one_mib_is_rejected_without_echoing_it(self):
        marker = "OVERSIZED-SECRET-BODY"
        self.httpd.response_body = json.dumps(
            {"workflow_runs": [], "padding": marker + "x" * (1024 * 1024)}
        ).encode()
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_main()

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertNotIn(marker, stdout + stderr)

    def test_remote_must_be_exact_anonymous_github_https_url(self):
        rejected_urls = [
            "http://github.com/yonatankarp/nas-platform.git",
            "https://user:password@github.com/yonatankarp/nas-platform.git",
            "https://gitlab.com/yonatankarp/nas-platform.git",
            "https://github.com/yonatankarp/other.git",
            "https://github.com/yonatankarp/nas-platform.git?token=secret",
            "https://github.com/yonatankarp/nas-platform.git#fragment",
        ]
        for repository_url in rejected_urls:
            with self.subTest(repository_url=repository_url):
                self.config["repository_url"] = repository_url
                self.write_config()
                before = self.state_snapshot()
                status, stdout, stderr = self.invoke_main()
                self.assertEqual(status, 1)
                self.assertEqual(stdout, "")
                self.assertEqual(
                    stderr,
                    "production auto-deploy: unsafe configuration\n",
                )
                self.assert_no_mutation(before)
                self.assertEqual(self.httpd.requests, [])
                self.assertEqual(self.tool_calls.read_text(encoding="utf-8"), "")

    def test_non_utf8_git_output_is_rejected_without_decoder_exception(self):
        self.install_fake(
            "git",
            f"#!{sys.executable}\n"
            "import sys\n"
            "sys.stdout.buffer.write(b'\\xff\\xfe')\n",
        )
        before = self.state_snapshot()

        try:
            status, stdout, stderr = self.invoke_main()
        except UnicodeError as error:
            self.fail(f"Git decoder exception escaped: {type(error).__name__}")

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertEqual(self.httpd.requests, [])

    def test_oversized_git_diagnostic_is_rejected_before_api_request(self):
        self.install_fake(
            "git",
            f"#!{sys.executable}\n"
            "import sys\n"
            f"sys.stderr.buffer.write(b'x' * {1024 * 1024 + 1})\n"
            f"print({MAIN_SHA!r} + '\\trefs/heads/main')\n",
        )
        self.respond_with_runs([self.successful_run()])
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_main()

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertEqual(self.httpd.requests, [])

    def test_git_timeout_is_rejected_without_mutation_or_orphaned_process(self):
        self.install_fake(
            "git",
            f"#!{sys.executable}\n" "import time\n" "time.sleep(2)\n",
        )
        before = self.state_snapshot()

        started = time.monotonic()
        with mock.patch.object(
            production_auto_deploy,
            "GIT_TIMEOUT_SECONDS",
            0.1,
        ):
            status, stdout, stderr = self.invoke_main()
        elapsed = time.monotonic() - started

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertLess(elapsed, 0.8)
        self.assertEqual(self.httpd.requests, [])

    def test_simultaneous_polls_produce_exactly_one_attempt(self):
        poller = getattr(production_auto_deploy, "poll", None)
        self.assertIsNotNone(poller, "stateful poller is missing")
        attempt_started = threading.Event()
        release_attempt = threading.Event()
        attempts = []
        results = []

        def attempt(_config, sha):
            attempts.append(sha)
            attempt_started.set()
            self.assertTrue(release_attempt.wait(2.0))
            return True

        def run_poll():
            results.append(poller(self.loaded_config()))

        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            side_effect=attempt,
        ):
            first = threading.Thread(target=run_poll)
            second = threading.Thread(target=run_poll)
            first.start()
            self.assertTrue(attempt_started.wait(1.0))
            second.start()
            second.join(1.0)
            self.assertFalse(second.is_alive(), "contending poll blocked on the lock")
            release_attempt.set()
            first.join(2.0)

        self.assertFalse(first.is_alive())
        self.assertEqual(attempts, [MAIN_SHA])
        self.assertEqual(len(results), 2)

    def test_crash_during_attempt_leaves_durable_quarantine_before_second_poll(self):
        attempts = []

        def crash(_config, sha):
            attempts.append(sha)
            raise KeyboardInterrupt("simulated crash")

        with self.assertRaises(KeyboardInterrupt):
            self.poll_with_attempt(crash)

        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))
        self.poll_with_attempt(crash)
        self.assertEqual(attempts, [MAIN_SHA])

    def test_success_promotion_failure_cannot_repeat_attempt(self):
        attempts = []
        real_replace = os.replace

        def succeed(_config, sha):
            attempts.append(sha)
            return True

        def fail_success_promotion(*args, **kwargs):
            if args[1] == "last-successful":
                raise OSError("interrupted after attempt")
            return real_replace(*args, **kwargs)

        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            side_effect=succeed,
        ), mock.patch.object(
            production_auto_deploy.os,
            "replace",
            side_effect=fail_success_promotion,
        ), self.assertRaises(
            production_auto_deploy.ConfigurationError
        ):
            production_auto_deploy.poll(self.loaded_config())

        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))
        self.poll_with_attempt(succeed)
        self.assertEqual(attempts, [MAIN_SHA])

    def test_successful_attempt_state_root_replacement_is_quarantined(self):
        attempts = []

        def replace_then_succeed(_config, sha):
            attempts.append(sha)
            self.replace_state_root("during-successful-attempt")
            return True

        result = self.poll_with_attempt(replace_then_succeed)

        self.assertFalse(result)
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertIsNotNone(failed)
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))
        self.assertIsNone(
            production_auto_deploy.read_sha_state(self.state_path("last-successful"))
        )
        self.poll_with_attempt(replace_then_succeed)
        self.assertEqual(attempts, [MAIN_SHA])

    def test_failed_attempt_state_root_replacement_is_quarantined(self):
        attempts = []

        def replace_then_fail(_config, sha):
            attempts.append(sha)
            self.replace_state_root("during-failed-attempt")
            return False

        result = self.poll_with_attempt(replace_then_fail)

        self.assertFalse(result)
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertIsNotNone(failed)
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))
        self.poll_with_attempt(replace_then_fail)
        self.assertEqual(attempts, [MAIN_SHA])

    def test_state_root_replacement_cannot_open_concurrent_poll_window(self):
        replacement_visible = threading.Event()
        release_first_attempt = threading.Event()
        second_attempted = threading.Event()
        attempts = []
        results = []

        def replace_and_pause(_config, sha):
            attempts.append(sha)
            if len(attempts) == 1:
                self.replace_state_root("during-concurrent-attempt")
                replacement_visible.set()
                release_first_attempt.wait(2.0)
            else:
                second_attempted.set()
            return False

        def invoke_poll():
            results.append(production_auto_deploy.poll(self.loaded_config()))

        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            side_effect=replace_and_pause,
        ):
            first_poll = threading.Thread(target=invoke_poll, daemon=True)
            first_poll.start()
            self.assertTrue(replacement_visible.wait(1.0))
            second_poll = threading.Thread(target=invoke_poll, daemon=True)
            second_poll.start()
            second_poll.join(1.0)
            second_finished_while_first_paused = not second_poll.is_alive()
            release_first_attempt.set()
            first_poll.join(2.0)
            second_poll.join(2.0)

        self.assertTrue(second_finished_while_first_paused)
        self.assertFalse(second_attempted.is_set())
        self.assertEqual(attempts, [MAIN_SHA])
        self.assertEqual(
            sorted(results, key=lambda value: value is not None), [None, False]
        )
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))

    def test_state_root_swap_and_keyboard_interrupt_cannot_repeat_attempt(self):
        attempts = []

        def interrupt_after_swap(_config, sha):
            attempts.append(sha)
            self.replace_state_root("before-keyboard-interrupt")
            raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            self.poll_with_attempt(interrupt_after_swap)

        self.poll_with_attempt(lambda _config, sha: attempts.append(sha))
        self.assertEqual(attempts, [MAIN_SHA])
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))

    def test_state_root_swap_and_base_exception_cannot_repeat_attempt(self):
        class FatalAttempt(BaseException):
            pass

        attempts = []

        def terminate_after_swap(_config, sha):
            attempts.append(sha)
            self.replace_state_root("before-base-exception")
            raise FatalAttempt

        with self.assertRaises(FatalAttempt):
            self.poll_with_attempt(terminate_after_swap)

        self.poll_with_attempt(lambda _config, sha: attempts.append(sha))
        self.assertEqual(attempts, [MAIN_SHA])

    def test_delayed_state_root_publish_cannot_repeat_attempt(self):
        attempts = []
        publisher = None

        def swap_then_publish_later(_config, sha):
            nonlocal publisher
            attempts.append(sha)
            state_root = self.root / "state"
            state_root.rename(self.root / "state-before-delayed-publish")

            def publish():
                time.sleep(0.15)
                state_root.mkdir()
                state_root.chmod(0o700)

            publisher = threading.Thread(target=publish, daemon=True)
            publisher.start()
            return True

        with self.assertRaises(production_auto_deploy.ConfigurationError):
            self.poll_with_attempt(swap_then_publish_later)
        reservation_path = (
            self.root / production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
        )
        self.assertTrue(reservation_path.exists())
        publisher.join(1.0)
        self.assertFalse(publisher.is_alive())

        self.poll_with_attempt(lambda _config, sha: attempts.append(sha))
        self.assertEqual(attempts, [MAIN_SHA])
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))

    def test_sigkill_after_state_root_swap_cannot_repeat_attempt(self):
        child_source = (
            "import os, pathlib, signal, sys\n"
            f"sys.path.insert(0, {str(SCRIPT.parent)!r})\n"
            "import production_auto_deploy as module\n"
            f"config = module.load_config({str(self.config_path)!r})\n"
            f"sha = {MAIN_SHA!r}\n"
            "module.resolve_main_sha = lambda _config: sha\n"
            "module.fetch_ci_runs = lambda _config, _sha: (module.CiRun(\n"
            "    head_sha=sha, status='completed', conclusion='success',\n"
            "    event='push', head_branch='main', name='CI'),)\n"
            "def terminate(_config, _sha):\n"
            f"    state = pathlib.Path({str(self.root / 'state')!r})\n"
            f"    state.rename(pathlib.Path({str(self.root / 'state-before-sigkill')!r}))\n"
            "    state.mkdir(mode=0o700)\n"
            "    os.kill(os.getpid(), signal.SIGKILL)\n"
            "module.attempt_candidate = terminate\n"
            "module.poll(config)\n"
        )
        child = subprocess.run(
            [sys.executable, "-c", child_source],
            capture_output=True,
            check=False,
            text=True,
            timeout=3.0,
        )
        self.assertEqual(child.returncode, -signal.SIGKILL)
        self.assertTrue(
            self.root.joinpath(
                production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
            ).exists()
        )

        attempts = []
        self.poll_with_attempt(lambda _config, sha: attempts.append(sha))

        self.assertEqual(attempts, [])
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))

    def test_reservation_symlink_or_malformed_content_fails_closed(self):
        reservation_name = getattr(
            production_auto_deploy,
            "ATTEMPT_RESERVATION_FILE_NAME",
            ".deployment.attempt-reservation",
        )
        reservation_path = self.root / reservation_name
        external = self.root.parent / f"{self.root.name}-reservation-target"
        external.write_text("unchanged\n", encoding="utf-8")
        external.chmod(0o600)
        self.addCleanup(external.unlink)

        for unsafe_kind in ("symlink", "malformed"):
            with self.subTest(unsafe_kind=unsafe_kind):
                if reservation_path.exists() or reservation_path.is_symlink():
                    reservation_path.unlink()
                if unsafe_kind == "symlink":
                    reservation_path.symlink_to(external)
                else:
                    reservation_path.write_bytes(b"not-json")
                    reservation_path.chmod(0o600)
                for mode in ("--poll", "--status"):
                    with self.subTest(mode=mode):
                        status, stdout, stderr = self.invoke_main(mode)
                        self.assertEqual((status, stdout), (1, ""))
                        self.assertEqual(
                            stderr,
                            "production auto-deploy: unsafe configuration\n",
                        )
                self.assertEqual(external.read_text(), "unchanged\n")

    def test_status_reports_unresolved_reservation_without_mutation(self):
        reservation_name = getattr(
            production_auto_deploy,
            "ATTEMPT_RESERVATION_FILE_NAME",
            ".deployment.attempt-reservation",
        )
        production_auto_deploy.write_sha_state(
            self.root / reservation_name,
            MAIN_SHA,
            "2026-08-14T12:34:56Z",
            "failed",
        )
        before = (self.root / reservation_name).read_bytes()

        status, stdout, stderr = self.invoke_main("--status")

        self.assertEqual((status, stderr), (0, ""))
        self.assertNotEqual(stdout, "")
        self.assertEqual(
            json.loads(stdout),
            {
                "sha": MAIN_SHA,
                "timestamp": "2026-08-14T12:34:56Z",
                "outcome": "failed",
            },
        )
        self.assertEqual((self.root / reservation_name).read_bytes(), before)

    def test_status_suppresses_persistent_journal_represented_by_success(self):
        self.poll_with_attempt(lambda _config, _sha: True)
        journal_path = self.root / production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
        before = journal_path.read_bytes()

        status, stdout, stderr = self.invoke_main("--status")

        self.assertEqual((status, stderr), (0, ""))
        records = [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual(len(records), 1)
        self.assertEqual(
            (records[0]["sha"], records[0]["outcome"]),
            (MAIN_SHA, "success"),
        )
        self.assertEqual(journal_path.read_bytes(), before)

    def test_status_suppresses_persistent_journal_represented_by_failure(self):
        self.poll_with_attempt(lambda _config, _sha: False)
        journal_path = self.root / production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
        before = journal_path.read_bytes()

        status, stdout, stderr = self.invoke_main("--status")

        self.assertEqual((status, stderr), (0, ""))
        records = [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual(len(records), 1)
        self.assertEqual(
            (records[0]["sha"], records[0]["outcome"]),
            (MAIN_SHA, "failed"),
        )
        self.assertEqual(journal_path.read_bytes(), before)

    def test_state_root_replacement_during_success_promotion_is_quarantined(self):
        attempts = []
        swapped = False
        real_write = production_auto_deploy._write_sha_state_at

        def succeed(_config, sha):
            attempts.append(sha)
            return True

        def swap_before_success_write(directory_fd, name, *args):
            nonlocal swapped
            if name == "last-successful" and not swapped:
                swapped = True
                self.replace_state_root("during-success-promotion")
            return real_write(directory_fd, name, *args)

        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            side_effect=succeed,
        ), mock.patch.object(
            production_auto_deploy,
            "_write_sha_state_at",
            side_effect=swap_before_success_write,
        ):
            result = production_auto_deploy.poll(self.loaded_config())

        self.assertFalse(result)
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))
        self.assertIsNone(
            production_auto_deploy.read_sha_state(self.state_path("last-successful"))
        )
        self.poll_with_attempt(succeed)
        self.assertEqual(attempts, [MAIN_SHA])

    def test_successful_sha_is_never_attempted_twice(self):
        attempts = []

        def succeed(_config, sha):
            attempts.append(sha)
            return True

        self.poll_with_attempt(succeed)

        self.assertTrue(
            self.root.joinpath(
                production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
            ).exists()
        )
        self.poll_with_attempt(succeed)

        self.assertEqual(attempts, [MAIN_SHA])
        state = production_auto_deploy.read_sha_state(
            self.state_path("last-successful")
        )
        self.assertEqual((state.sha, state.outcome), (MAIN_SHA, "success"))

    def test_failed_sha_is_quarantined_without_automatic_retry(self):
        attempts = []

        def fail(_config, sha):
            attempts.append(sha)
            return False

        self.poll_with_attempt(fail)

        self.assertTrue(
            self.root.joinpath(
                production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
            ).exists()
        )
        self.poll_with_attempt(fail)

        self.assertEqual(attempts, [MAIN_SHA])
        state = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((state.sha, state.outcome), (MAIN_SHA, "failed"))

    def test_success_cleanup_state_swap_is_recovered_from_persistent_journal(self):
        attempts = []
        swapped = False
        real_is_current = production_auto_deploy._state_directory_is_current

        def succeed(_config, sha):
            attempts.append(sha)
            return True

        def swap_after_final_validation(config, directory_fd):
            nonlocal swapped
            is_current = real_is_current(config, directory_fd)
            if (
                is_current
                and not swapped
                and self.state_path("last-successful").exists()
                and not self.state_path("last-failed").exists()
            ):
                swapped = True
                self.replace_state_root("at-former-success-cleanup")
            return is_current

        with mock.patch.object(
            production_auto_deploy,
            "_state_directory_is_current",
            side_effect=swap_after_final_validation,
        ):
            result = self.poll_with_attempt(succeed)

        self.assertTrue(result)
        journal_path = self.root / production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
        self.assertTrue(journal_path.exists())
        self.poll_with_attempt(succeed)
        self.assertEqual(attempts, [MAIN_SHA])
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))
        self.assertTrue(journal_path.exists())

    def test_failure_cleanup_state_swap_is_recovered_from_persistent_journal(self):
        attempts = []
        attempt_finished = False
        swapped = False
        real_is_current = production_auto_deploy._state_directory_is_current

        def fail(_config, sha):
            nonlocal attempt_finished
            attempts.append(sha)
            attempt_finished = True
            return False

        def swap_after_post_attempt_validation(config, directory_fd):
            nonlocal swapped
            is_current = real_is_current(config, directory_fd)
            if is_current and attempt_finished and not swapped:
                swapped = True
                self.replace_state_root("at-former-failure-cleanup")
            return is_current

        with mock.patch.object(
            production_auto_deploy,
            "_state_directory_is_current",
            side_effect=swap_after_post_attempt_validation,
        ):
            result = self.poll_with_attempt(fail)

        self.assertFalse(result)
        journal_path = self.root / production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
        self.assertTrue(journal_path.exists())
        self.poll_with_attempt(fail)
        self.assertEqual(attempts, [MAIN_SHA])
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))
        self.assertTrue(journal_path.exists())

    def test_newer_successful_sha_proceeds_after_quarantined_sha(self):
        newer_sha = "fedcba9876543210fedcba9876543210fedcba98"
        attempts = []

        def record(_config, sha):
            attempts.append(sha)
            return sha == newer_sha

        self.poll_with_attempt(record, sha=MAIN_SHA)
        self.poll_with_attempt(record, sha=newer_sha)

        self.assertEqual(attempts, [MAIN_SHA, newer_sha])
        journal = production_auto_deploy.read_sha_state(
            self.root / production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
        )
        self.assertIsNotNone(journal)
        self.assertEqual((journal.sha, journal.outcome), (newer_sha, "failed"))
        successful = production_auto_deploy.read_sha_state(
            self.state_path("last-successful")
        )
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual(successful.sha, newer_sha)
        self.assertIsNone(failed)

    def test_explicit_retry_accepts_exact_current_quarantined_sha_with_ci(self):
        self.write_sha_state("last-failed", MAIN_SHA, "failed")
        attempts = []

        def succeed(_config, sha):
            attempts.append(sha)
            return True

        self.poll_with_attempt(succeed, retry_sha=MAIN_SHA)

        self.assertEqual(attempts, [MAIN_SHA])
        journal = production_auto_deploy.read_sha_state(
            self.root / production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
        )
        self.assertIsNotNone(journal)
        self.assertEqual((journal.sha, journal.outcome), (MAIN_SHA, "failed"))
        successful = production_auto_deploy.read_sha_state(
            self.state_path("last-successful")
        )
        self.assertEqual(successful.sha, MAIN_SHA)
        self.assertIsNone(
            production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        )

    def test_poll_cli_returns_nonzero_after_failed_or_raised_attempt(self):
        for label, attempted_result in (
            ("false", False),
            ("exception", RuntimeError("attempt failed")),
        ):
            with self.subTest(label=label):
                failed_path = self.state_path("last-failed")
                if failed_path.exists():
                    failed_path.unlink()
                journal_path = (
                    self.root / production_auto_deploy.ATTEMPT_RESERVATION_FILE_NAME
                )
                if journal_path.exists():
                    journal_path.unlink()
                side_effect = (
                    attempted_result
                    if isinstance(attempted_result, Exception)
                    else None
                )
                with self.candidate(MAIN_SHA), mock.patch.object(
                    production_auto_deploy,
                    "attempt_candidate",
                    return_value=attempted_result,
                    side_effect=side_effect,
                ):
                    status, stdout, stderr = self.invoke_main("--poll")

                self.assertEqual(status, 1)
                self.assertEqual(stdout, "")
                self.assertEqual(stderr, "production auto-deploy: attempt failed\n")
                failed = production_auto_deploy.read_sha_state(failed_path)
                self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))

    def test_poll_cli_returns_zero_after_successful_attempt(self):
        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            return_value=True,
        ):
            status, stdout, stderr = self.invoke_main("--poll")

        self.assertEqual((status, stdout, stderr), (0, "", ""))

    def test_poll_cli_bounds_atomic_state_write_failure(self):
        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            return_value=True,
        ), mock.patch.object(
            production_auto_deploy.os,
            "replace",
            side_effect=OSError("secret external path"),
        ):
            status, stdout, stderr = self.invoke_main("--poll")

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "production auto-deploy: unsafe configuration\n")
        self.assertNotIn("secret external path", stderr)

    def test_poll_cli_bounds_lock_descriptor_failure(self):
        with mock.patch.object(
            production_auto_deploy.os,
            "fstat",
            side_effect=OSError("secret lock path"),
        ):
            status, stdout, stderr = self.invoke_main("--poll")

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "production auto-deploy: unsafe configuration\n")
        self.assertNotIn("secret lock path", stderr)

    def test_retry_rejects_old_non_main_non_quarantined_or_ci_ineligible_sha(self):
        newer_sha = "fedcba9876543210fedcba9876543210fedcba98"
        attempts = []

        def attempt(_config, sha):
            attempts.append(sha)
            return True

        self.write_sha_state("last-failed", MAIN_SHA, "failed")
        poller = getattr(production_auto_deploy, "poll", None)
        self.assertIsNotNone(poller, "stateful poller is missing")

        with mock.patch.object(
            production_auto_deploy,
            "resolve_main_sha",
        ) as resolve:
            poller(self.loaded_config(), retry_sha=newer_sha)
        resolve.assert_not_called()

        with self.candidate(newer_sha), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            side_effect=attempt,
        ):
            poller(self.loaded_config(), retry_sha=MAIN_SHA)

        with mock.patch.object(
            production_auto_deploy,
            "resolve_main_sha",
            return_value=MAIN_SHA,
        ), mock.patch.object(
            production_auto_deploy,
            "fetch_ci_runs",
            return_value=(),
        ), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            side_effect=attempt,
        ):
            poller(self.loaded_config(), retry_sha=MAIN_SHA)

        self.assertEqual(attempts, [])

    def test_unsafe_state_paths_fail_before_git_or_attempt_and_preserve_targets(self):
        poller = getattr(production_auto_deploy, "poll", None)
        self.assertIsNotNone(poller, "stateful poller is missing")
        external = self.root.parent / f"{self.root.name}-external-state"
        external.mkdir(mode=0o700)
        self.addCleanup(external.rmdir)
        external_target = external / "target"
        external_target.write_text("unchanged\n", encoding="utf-8")
        external_target.chmod(0o600)
        self.addCleanup(external_target.unlink)

        def assert_rejected():
            with mock.patch.object(
                production_auto_deploy,
                "resolve_main_sha",
            ) as resolve, mock.patch.object(
                production_auto_deploy,
                "attempt_candidate",
            ) as attempt, self.assertRaises(
                production_auto_deploy.ConfigurationError
            ):
                poller(self.loaded_config())
            resolve.assert_not_called()
            attempt.assert_not_called()
            self.assertEqual(external_target.read_text(encoding="utf-8"), "unchanged\n")

        self.state_path("last-successful").symlink_to(external_target)
        assert_rejected()
        self.state_path("last-successful").unlink()

        (self.root / "state").chmod(0o755)
        assert_rejected()
        (self.root / "state").chmod(0o700)

        with mock.patch.object(
            production_auto_deploy.os,
            "geteuid",
            return_value=os.geteuid() + 1,
        ):
            assert_rejected()

        self.config["state_root"] = str(external)
        self.write_config()
        assert_rejected()

    def test_lock_symlink_is_rejected_without_changing_external_target(self):
        lock_target = self.root / "external-lock-target"
        lock_target.write_text("unchanged\n", encoding="utf-8")
        lock_target.chmod(0o600)
        self.state_path("deployment.lock").symlink_to(lock_target)
        lock = getattr(production_auto_deploy, "deployment_lock", None)
        self.assertIsNotNone(lock, "deployment lock is missing")

        with self.assertRaises(production_auto_deploy.ConfigurationError):
            with lock(self.loaded_config()):
                self.fail("unsafe lock was acquired")

        self.assertEqual(lock_target.read_text(encoding="utf-8"), "unchanged\n")

    def test_lock_creation_is_0600_even_under_owner_denying_umask(self):
        lock_path = self.state_path("deployment.lock")
        previous_umask = os.umask(0o777)
        try:
            with production_auto_deploy.deployment_lock(
                self.loaded_config()
            ) as acquired:
                self.assertTrue(acquired)
        finally:
            os.umask(previous_umask)

        self.assertEqual(stat.S_IMODE(lock_path.stat().st_mode), 0o600)

    def test_fifo_state_fails_quickly_in_poll_and_status_without_wedging_lock(self):
        state_path = self.state_path("last-successful")
        for mode in ("--poll", "--status"):
            with self.subTest(mode=mode):
                if state_path.exists():
                    state_path.unlink()
                os.mkfifo(state_path, 0o600)
                state_path.chmod(0o600)
                result = []

                def invoke():
                    result.append(self.invoke_main(mode))

                with mock.patch.object(
                    production_auto_deploy,
                    "resolve_main_sha",
                ) as resolve, mock.patch.object(
                    production_auto_deploy,
                    "attempt_candidate",
                ) as attempt:
                    worker = threading.Thread(target=invoke, daemon=True)
                    worker.start()
                    worker.join(0.3)
                    completed_in_time = not worker.is_alive()
                    if worker.is_alive():
                        writer = os.open(state_path, os.O_WRONLY | os.O_NONBLOCK)
                        os.close(writer)
                        worker.join(1.0)

                self.assertTrue(completed_in_time, f"{mode} blocked opening FIFO")
                self.assertFalse(worker.is_alive())
                self.assertEqual(
                    result,
                    [
                        (
                            1,
                            "",
                            "production auto-deploy: unsafe configuration\n",
                        )
                    ],
                )
                self.assertTrue(stat.S_ISFIFO(state_path.lstat().st_mode))
                self.assertFalse(self.state_path("last-failed").exists())
                resolve.assert_not_called()
                attempt.assert_not_called()
                state_path.unlink()
                with production_auto_deploy.deployment_lock(
                    self.loaded_config()
                ) as acquired:
                    self.assertIsNotNone(acquired)

    def test_directory_state_fails_quickly_in_poll_and_status(self):
        state_path = self.state_path("last-failed")
        for mode in ("--poll", "--status"):
            with self.subTest(mode=mode):
                state_path.mkdir(mode=0o700)
                started = time.monotonic()
                status, stdout, stderr = self.invoke_main(mode)
                elapsed = time.monotonic() - started

                self.assertLess(elapsed, 0.3)
                self.assertEqual((status, stdout), (1, ""))
                self.assertEqual(
                    stderr,
                    "production auto-deploy: unsafe configuration\n",
                )
                self.assertTrue(state_path.is_dir())
                state_path.rmdir()

    def test_lock_bootstrap_recovers_canonical_identity_without_public_link(self):
        identity_name = getattr(
            production_auto_deploy,
            "LOCK_IDENTITY_FILE_NAME",
            None,
        )
        self.assertIsNotNone(identity_name, "canonical lock identity is missing")
        identity_path = self.state_path(identity_name)
        identity_path.write_bytes(b"")
        identity_path.chmod(0o600)

        with production_auto_deploy.deployment_lock(self.loaded_config()) as acquired:
            self.assertIsNotNone(acquired)

        lock_stat = self.state_path("deployment.lock").stat()
        identity_stat = identity_path.stat()
        self.assertEqual(
            (lock_stat.st_dev, lock_stat.st_ino),
            (identity_stat.st_dev, identity_stat.st_ino),
        )
        self.assertEqual(lock_stat.st_nlink, 2)

    def test_public_lock_without_canonical_identity_fails_closed(self):
        lock_path = self.state_path("deployment.lock")
        lock_path.write_bytes(b"")
        lock_path.chmod(0o600)

        with self.assertRaises(production_auto_deploy.ConfigurationError):
            with production_auto_deploy.deployment_lock(self.loaded_config()):
                self.fail("unanchored lock was accepted")

        self.assertEqual(lock_path.read_bytes(), b"")

    def test_concurrent_first_use_converges_without_unsafe_lock_errors(self):
        contender_count = 12
        initial_miss_barrier = threading.Barrier(contender_count)
        public_miss_barrier = threading.Barrier(contender_count)
        canonical_pair_ready = threading.Event()
        release_entrant = threading.Event()
        results = []
        results_changed = threading.Condition()
        miss_count = 0
        public_miss_count = 0
        miss_count_lock = threading.Lock()
        real_open_entry = production_auto_deploy._open_lock_entry_at
        real_validate_identity = production_auto_deploy._validate_lock_identity

        def synchronized_open_entry(directory_fd, name):
            nonlocal miss_count, public_miss_count
            if name == production_auto_deploy.LOCK_FILE_NAME:
                with miss_count_lock:
                    public_miss_index = public_miss_count
                    public_miss_count += 1
                if public_miss_index < contender_count:
                    public_miss_barrier.wait(timeout=2.0)
                    if public_miss_index != 0:
                        self.assertTrue(canonical_pair_ready.wait(2.0))
                    raise FileNotFoundError
            try:
                return real_open_entry(directory_fd, name)
            except FileNotFoundError:
                if name != production_auto_deploy.LOCK_IDENTITY_FILE_NAME:
                    raise
                with miss_count_lock:
                    miss_count += 1
                initial_miss_barrier.wait(timeout=2.0)
                raise

        def signal_valid_pair(identity_fd, lock_fd):
            real_validate_identity(identity_fd, lock_fd)
            canonical_pair_ready.set()

        def contend():
            directory_fd = os.open(
                self.root / "state",
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            )
            lock_fd = -1
            result = None
            try:
                lock_fd = production_auto_deploy._open_lock_at(directory_fd)
                try:
                    production_auto_deploy.fcntl.flock(
                        lock_fd,
                        production_auto_deploy.fcntl.LOCK_EX
                        | production_auto_deploy.fcntl.LOCK_NB,
                    )
                except OSError as error:
                    if error.errno not in (errno.EACCES, errno.EAGAIN):
                        raise
                    result = "busy"
                else:
                    result = "entered"
            except BaseException as error:
                result = f"error:{type(error).__name__}"

            with results_changed:
                results.append(result)
                results_changed.notify_all()
            if result == "entered":
                release_entrant.wait(2.0)
                production_auto_deploy.fcntl.flock(
                    lock_fd,
                    production_auto_deploy.fcntl.LOCK_UN,
                )
            if lock_fd >= 0:
                os.close(lock_fd)
            os.close(directory_fd)

        with mock.patch.object(
            production_auto_deploy,
            "_open_lock_entry_at",
            side_effect=synchronized_open_entry,
        ), mock.patch.object(
            production_auto_deploy,
            "_validate_lock_identity",
            side_effect=signal_valid_pair,
        ):
            contenders = [
                threading.Thread(target=contend, daemon=True)
                for _ in range(contender_count)
            ]
            for contender in contenders:
                contender.start()
            with results_changed:
                results_changed.wait_for(
                    lambda: len(results) == contender_count,
                    timeout=3.0,
                )
            release_entrant.set()
            for contender in contenders:
                contender.join(2.0)

        self.assertTrue(all(not contender.is_alive() for contender in contenders))
        self.assertEqual(results.count("entered"), 1)
        self.assertEqual(results.count("busy"), contender_count - 1)
        self.assertFalse([result for result in results if result.startswith("error:")])

    def test_concurrent_first_use_processes_have_exactly_one_entrant(self):
        contender_count = 10
        start_path = self.root / "start-lock-contenders"
        result_prefix = self.root / "lock-contender-result"
        child_source = (
            "import pathlib, sys, time\n"
            f"sys.path.insert(0, {str(SCRIPT.parent)!r})\n"
            "import production_auto_deploy as module\n"
            f"config = module.load_config({str(self.config_path)!r})\n"
            f"start = pathlib.Path({str(start_path)!r})\n"
            f"result = pathlib.Path({str(result_prefix)!r} + '-' + sys.argv[1])\n"
            "while not start.exists():\n"
            "    time.sleep(0.001)\n"
            "try:\n"
            "    with module.deployment_lock(config) as acquired:\n"
            "        outcome = 'busy' if acquired is None else 'entered'\n"
            "        result.write_text(outcome)\n"
            "        if outcome == 'entered':\n"
            f"            expected = {contender_count}\n"
            "            deadline = time.monotonic() + 3.0\n"
            "            while len(list(result.parent.glob(result.name.rsplit('-', 1)[0] + '-*'))) < expected:\n"
            "                if time.monotonic() >= deadline:\n"
            "                    raise RuntimeError('contenders did not finish')\n"
            "                time.sleep(0.005)\n"
            "except module.ConfigurationError:\n"
            "    result.write_text('error')\n"
        )
        contenders = [
            subprocess.Popen(
                [sys.executable, "-c", child_source, str(index)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for index in range(contender_count)
        ]
        start_path.write_bytes(b"")
        completed = [contender.communicate(timeout=5.0) for contender in contenders]
        outcomes = [
            self.root.joinpath(f"lock-contender-result-{index}").read_text()
            for index in range(contender_count)
        ]

        self.assertTrue(all(contender.returncode == 0 for contender in contenders))
        self.assertEqual(completed, [("", "")] * contender_count)
        self.assertEqual(outcomes.count("entered"), 1)
        self.assertEqual(outcomes.count("busy"), contender_count - 1)

    def test_replaced_lock_path_cannot_create_second_lock_namespace(self):
        lock_path = self.state_path("deployment.lock")
        renamed_path = self.state_path("deployment.lock.renamed")
        marker_path = self.root / "second-lock-entered"
        child_source = (
            "import pathlib, sys\n"
            f"sys.path.insert(0, {str(SCRIPT.parent)!r})\n"
            "import production_auto_deploy as module\n"
            f"config = module.load_config({str(self.config_path)!r})\n"
            "try:\n"
            "    with module.deployment_lock(config) as acquired:\n"
            "        if acquired is None:\n"
            "            print('busy')\n"
            "        else:\n"
            f"            pathlib.Path({str(marker_path)!r}).write_text('entered')\n"
            "            print('entered')\n"
            "except module.ConfigurationError:\n"
            "    print('rejected')\n"
        )

        try:
            with production_auto_deploy.deployment_lock(
                self.loaded_config()
            ) as acquired:
                self.assertIsNotNone(acquired)
                lock_path.rename(renamed_path)
                lock_path.write_text("replacement unchanged\n", encoding="utf-8")
                lock_path.chmod(0o600)
                renamed_before = renamed_path.stat()

                child = subprocess.run(
                    [sys.executable, "-c", child_source],
                    capture_output=True,
                    check=False,
                    text=True,
                    timeout=2.0,
                )

                self.assertEqual(child.returncode, 0)
                self.assertEqual(child.stdout, "busy\n")
                self.assertEqual(child.stderr, "")
                self.assertFalse(marker_path.exists())
                renamed_after = renamed_path.stat()
                self.assertEqual(
                    (renamed_after.st_dev, renamed_after.st_ino),
                    (renamed_before.st_dev, renamed_before.st_ino),
                )
                self.assertEqual(renamed_path.read_bytes(), b"")
                self.assertEqual(
                    lock_path.read_text(encoding="utf-8"),
                    "replacement unchanged\n",
                )
        finally:
            if lock_path.exists():
                lock_path.unlink()
            if renamed_path.exists():
                renamed_path.rename(lock_path)

    def test_replacing_both_lock_names_cannot_create_second_lock_namespace(self):
        identity_name = production_auto_deploy.LOCK_IDENTITY_FILE_NAME
        lock_path = self.state_path("deployment.lock")
        identity_path = self.state_path(identity_name)
        renamed_lock_path = self.state_path("deployment.lock.renamed")
        renamed_identity_path = self.state_path(f"{identity_name}.renamed")
        marker_path = self.root / "second-pair-entered"
        child_source = (
            "import pathlib, sys\n"
            f"sys.path.insert(0, {str(SCRIPT.parent)!r})\n"
            "import production_auto_deploy as module\n"
            f"config = module.load_config({str(self.config_path)!r})\n"
            "try:\n"
            "    with module.deployment_lock(config) as acquired:\n"
            "        if acquired is None:\n"
            "            print('busy')\n"
            "        else:\n"
            f"            pathlib.Path({str(marker_path)!r}).write_text('entered')\n"
            "            print('entered')\n"
            "except module.ConfigurationError:\n"
            "    print('rejected')\n"
        )

        with production_auto_deploy.deployment_lock(self.loaded_config()) as acquired:
            self.assertIsNotNone(acquired)
            identity_path.rename(renamed_identity_path)
            lock_path.rename(renamed_lock_path)
            identity_path.write_bytes(b"")
            identity_path.chmod(0o600)
            os.link(identity_path, lock_path)
            replacement_before = identity_path.stat()

            child = subprocess.run(
                [sys.executable, "-c", child_source],
                capture_output=True,
                check=False,
                text=True,
                timeout=2.0,
            )

            self.assertEqual(child.returncode, 0)
            self.assertEqual(child.stdout, "busy\n")
            self.assertEqual(child.stderr, "")
            self.assertFalse(marker_path.exists())
            replacement_after = identity_path.stat()
            self.assertEqual(
                (replacement_after.st_dev, replacement_after.st_ino),
                (replacement_before.st_dev, replacement_before.st_ino),
            )
            self.assertEqual(replacement_after.st_nlink, 2)

    def test_state_root_swap_before_second_validation_fails_before_commands(self):
        external = self.external_state_directory()
        before = self.external_snapshot(external)
        validate = production_auto_deploy._validate_protected_config
        validations = 0

        def swap_before_revalidation(config):
            nonlocal validations
            validations += 1
            if validations == 2:
                self.install_state_root_symlink(external)
            return validate(config)

        with mock.patch.object(
            production_auto_deploy,
            "_validate_protected_config",
            side_effect=swap_before_revalidation,
        ), mock.patch.object(
            production_auto_deploy,
            "resolve_main_sha",
            side_effect=AssertionError("Git ran after unsafe swap"),
        ), self.assertRaises(
            production_auto_deploy.ConfigurationError
        ):
            production_auto_deploy.poll(self.loaded_config())

        self.assertGreaterEqual(validations, 2)
        self.assertEqual(self.external_snapshot(external), before)

    def test_state_root_swap_at_directory_open_does_not_touch_external(self):
        external = self.external_state_directory()
        before = self.external_snapshot(external)
        state_root = self.root / "state"
        lock_path = state_root / "deployment.lock"
        real_open = os.open
        swapped = False

        def swap_at_open(path, flags, mode=0o777, *, dir_fd=None):
            nonlocal swapped
            if not swapped and dir_fd is None and Path(path) in (state_root, lock_path):
                swapped = True
                self.install_state_root_symlink(external)
            return real_open(path, flags, mode, dir_fd=dir_fd)

        with mock.patch.object(
            production_auto_deploy.os,
            "open",
            side_effect=swap_at_open,
        ), mock.patch.object(
            production_auto_deploy,
            "resolve_main_sha",
            side_effect=AssertionError("Git ran after unsafe swap"),
        ), self.assertRaises(
            production_auto_deploy.ConfigurationError
        ):
            production_auto_deploy.poll(self.loaded_config())

        self.assertTrue(swapped)
        self.assertEqual(self.external_snapshot(external), before)

    def test_state_root_swap_at_atomic_replace_cannot_replace_external_state(self):
        external = self.external_state_directory()
        external_state = external / "last-successful"
        external_state.write_text("external state unchanged\n", encoding="utf-8")
        external_state.chmod(0o600)
        before = self.external_snapshot(external)
        real_replace = os.replace
        swapped = False
        attacker_source = None

        def swap_at_replace(source, destination, *args, **kwargs):
            nonlocal attacker_source, swapped
            if not swapped:
                swapped = True
                self.install_state_root_symlink(external)
                attacker_source = external / Path(source).name
                attacker_source.write_text("attacker controlled\n", encoding="utf-8")
                attacker_source.chmod(0o600)
            return real_replace(source, destination, *args, **kwargs)

        with mock.patch.object(
            production_auto_deploy.os,
            "replace",
            side_effect=swap_at_replace,
        ):
            production_auto_deploy.write_sha_state(
                self.state_path("last-successful"),
                MAIN_SHA,
                "2026-08-14T12:34:56Z",
                "success",
            )

        if attacker_source is not None and attacker_source.exists():
            attacker_source.unlink()
        self.assertTrue(swapped)
        self.assertEqual(self.external_snapshot(external), before)

    def test_atomic_state_preserves_old_record_when_replace_is_interrupted(self):
        self.write_sha_state("last-successful", MAIN_SHA, "success")
        newer_sha = "fedcba9876543210fedcba9876543210fedcba98"

        with mock.patch.object(
            production_auto_deploy.os,
            "replace",
            side_effect=OSError("interrupted"),
        ), self.assertRaises(production_auto_deploy.ConfigurationError):
            production_auto_deploy.write_sha_state(
                self.state_path("last-successful"),
                newer_sha,
                "2026-08-14T12:35:56Z",
                "success",
            )

        state = production_auto_deploy.read_sha_state(
            self.state_path("last-successful")
        )
        self.assertEqual(state.sha, MAIN_SHA)
        self.assertEqual(
            [
                path.name
                for path in (self.root / "state").iterdir()
                if ".tmp" in path.name
            ],
            [],
        )

    def test_state_schema_rejects_invalid_sha_timestamp_outcome_or_extra_keys(self):
        reader = getattr(production_auto_deploy, "read_sha_state", None)
        self.assertIsNotNone(reader, "protected state reader is missing")
        cases = (
            {
                "sha": MAIN_SHA.upper(),
                "timestamp": "2026-08-14T12:34:56Z",
                "outcome": "success",
            },
            {"sha": MAIN_SHA, "timestamp": "2026-08-14 12:34:56", "outcome": "success"},
            {
                "sha": MAIN_SHA,
                "timestamp": "2026-08-14T12:34:56Z",
                "outcome": "unknown",
            },
            {
                "sha": MAIN_SHA,
                "timestamp": "2026-08-14T12:34:56Z",
                "outcome": "success",
                "extra": True,
            },
        )
        state_path = self.state_path("last-successful")
        for payload in cases:
            with self.subTest(payload=payload):
                state_path.write_text(json.dumps(payload), encoding="utf-8")
                state_path.chmod(0o600)
                with self.assertRaises(production_auto_deploy.ConfigurationError):
                    reader(state_path)

    def test_state_schema_rejects_duplicate_json_keys(self):
        state_path = self.state_path("last-successful")
        state_path.write_text(
            '{"sha":"'
            + MAIN_SHA
            + '","sha":"'
            + MAIN_SHA
            + '","timestamp":"2026-08-14T12:34:56Z","outcome":"success"}',
            encoding="utf-8",
        )
        state_path.chmod(0o600)

        with self.assertRaises(production_auto_deploy.ConfigurationError):
            production_auto_deploy.read_sha_state(state_path)

    def test_poll_rejects_outcome_in_wrong_state_file_before_git(self):
        self.write_sha_state("last-successful", MAIN_SHA, "failed")

        with mock.patch.object(
            production_auto_deploy,
            "resolve_main_sha",
        ) as resolve, self.assertRaises(production_auto_deploy.ConfigurationError):
            production_auto_deploy.poll(self.loaded_config())

        resolve.assert_not_called()

    def test_status_prints_only_state_fields_without_network_or_attempt(self):
        self.write_sha_state("last-successful", MAIN_SHA, "success")
        failed_sha = "fedcba9876543210fedcba9876543210fedcba98"
        self.write_sha_state("last-failed", failed_sha, "failed")
        before = self.state_snapshot()

        with mock.patch.object(
            production_auto_deploy,
            "resolve_main_sha",
            side_effect=AssertionError("status used Git"),
        ), mock.patch.object(
            production_auto_deploy,
            "fetch_ci_runs",
            side_effect=AssertionError("status used GitHub"),
        ), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            side_effect=AssertionError("status attempted deployment"),
        ):
            status, stdout, stderr = self.invoke_main("--status")

        self.assertEqual(status, 0)
        self.assertEqual(stderr, "")
        records = [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual(
            records,
            [
                {
                    "sha": MAIN_SHA,
                    "timestamp": "2026-08-14T12:34:56Z",
                    "outcome": "success",
                },
                {
                    "sha": failed_sha,
                    "timestamp": "2026-08-14T12:34:56Z",
                    "outcome": "failed",
                },
            ],
        )
        self.assertEqual(
            set().union(*(record.keys() for record in records)),
            {"sha", "timestamp", "outcome"},
        )
        self.assertEqual(self.state_snapshot(), before)
        self.assertEqual(self.httpd.requests, [])

    def test_matching_success_and_failure_recovers_before_network(self):
        self.write_sha_state("last-successful", MAIN_SHA, "success")
        self.write_sha_state("last-failed", MAIN_SHA, "failed")

        def resolve_after_cleanup(_config):
            self.assertIsNone(
                production_auto_deploy.read_sha_state(self.state_path("last-failed"))
            )
            return MAIN_SHA

        with mock.patch.object(
            production_auto_deploy,
            "resolve_main_sha",
            side_effect=resolve_after_cleanup,
        ) as resolve, mock.patch.object(
            production_auto_deploy,
            "fetch_ci_runs",
        ) as fetch:
            production_auto_deploy.poll(self.loaded_config())

        resolve.assert_called_once()
        fetch.assert_not_called()
        self.assertIsNone(
            production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        )
        successful = production_auto_deploy.read_sha_state(
            self.state_path("last-successful")
        )
        self.assertEqual(successful.sha, MAIN_SHA)

    def test_status_suppresses_matching_stale_failure_without_mutation(self):
        self.write_sha_state("last-successful", MAIN_SHA, "success")
        self.write_sha_state("last-failed", MAIN_SHA, "failed")
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_main("--status")

        self.assertEqual((status, stderr), (0, ""))
        self.assertEqual(
            [json.loads(line) for line in stdout.splitlines()],
            [
                {
                    "sha": MAIN_SHA,
                    "timestamp": "2026-08-14T12:34:56Z",
                    "outcome": "success",
                }
            ],
        )
        self.assertEqual(self.state_snapshot(), before)

    def test_poll_status_and_retry_cli_modes_are_mutually_exclusive(self):
        before = self.state_snapshot()
        cases = (
            ("--poll", "--status"),
            ("--poll", "--retry-failed", MAIN_SHA),
            ("--status", "--retry-failed", MAIN_SHA),
            ("--retry-failed", "not-a-sha"),
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                status, stdout, stderr = self.invoke_main(*arguments)
                self.assertEqual(status, 2)
                self.assertEqual(stdout, "")
                self.assertEqual(stderr, "production auto-deploy: invalid arguments\n")
        self.assert_no_mutation(before)
        self.assertEqual(self.httpd.requests, [])

    def test_unknown_cli_arguments_fail_before_git_api_or_mutation(self):
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_main("--unexpected", "secret-value")

        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "production auto-deploy: invalid arguments\n",
        )
        self.assertNotIn("secret-value", stderr)
        self.assert_no_mutation(before)
        self.assertEqual(self.httpd.requests, [])
        self.assertEqual(self.tool_calls.read_text(encoding="utf-8"), "")


if __name__ == "__main__":
    unittest.main()
