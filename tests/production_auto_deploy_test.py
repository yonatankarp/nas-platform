#!/usr/bin/env python3

import contextlib
import dataclasses
from http.client import HTTPException
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import stat
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
        ), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
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
            "zero retention": lambda payload: payload.update(
                {"log_retention_days": 0}
            ),
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
            "repository full_name": self.successful_run(
                repository={"full_name": 1}
            ),
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
        self.httpd.response_body = (
            b'{"workflow_runs":[' + b"9" * 5_000 + b"]}"
        )
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
        self.httpd.response_wire_trickle = (
            b"HTTP/1.1 200 OK\r\n" + b"X" * 100
        )
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
            ), self.assertRaises(production_auto_deploy.EligibilityError):
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
            f"#!{sys.executable}\n"
            "import time\n"
            "time.sleep(2)\n",
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
