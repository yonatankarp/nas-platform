#!/usr/bin/env python3

import ast
import contextlib
import dataclasses
import datetime
import errno
import hashlib
from http.client import HTTPException
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import signal
import shutil
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
VERIFY_TAGS = (
    "platform_verify_ntfy,platform_verify_beszel,platform_verify_dozzle,"
    "platform_verify_audiobookshelf,platform_verify_komga,"
    "platform_verify_tinymediamanager,platform_verify_jellyfin,"
    "platform_verify_immich,platform_verify_paperless"
)


def load_production_module():
    if not SCRIPT.exists():
        return None
    spec = importlib.util.spec_from_file_location("production_auto_deploy", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


production_auto_deploy = load_production_module()


def authoritative_controller_pins():
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    integration = (ROOT / "tests/integration.sh").read_text(encoding="utf-8")
    ci_pins = re.findall(
        r"pip\" install 'ansible-core==([0-9.]+)' "
        r"'ansible-lint==([0-9.]+)'",
        workflow,
    )
    integration_pins = re.findall(
        r"^ansible_core_version=([0-9.]+)$",
        integration,
        re.MULTILINE,
    )
    if len(ci_pins) != 1 or integration_pins != [ci_pins[0][0]]:
        raise AssertionError("CI and integration must have one matching Ansible pin")
    return ci_pins[0]


def authoritative_controller_requirements():
    ansible_core, ansible_lint = authoritative_controller_pins()
    return (
        f"ansible-core=={ansible_core}\n"
        f"ansible-lint=={ansible_lint}\n"
    ).encode("ascii")


def authoritative_collection_requirements():
    payload = (ROOT / "requirements.yml").read_bytes()
    return payload, production_auto_deploy._parse_collection_requirements(payload)


def installed_tooling_manifest(collections=None):
    if collections is None:
        _payload, collections = authoritative_collection_requirements()
    return (
        json.dumps(
            {
                "ansible_core": authoritative_controller_pins()[0],
                "ansible_lint": authoritative_controller_pins()[1],
                "collections": collections,
                "pip_freeze": [],
                "python": "3.12",
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("ascii")
        + b"\n"
    )


def ansible_playbook_version_output():
    return (
        "ansible-playbook [core "
        f"{authoritative_controller_pins()[0]}]\n"
    ).encode("ascii")


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

        self.private_root = self.root / ".local" / "share" / "nas-platform"
        self.private_root.mkdir(parents=True)
        for private_parent in (
            self.root / ".local",
            self.root / ".local" / "share",
            self.private_root,
        ):
            private_parent.chmod(0o700)
        for directory in (
            "controller",
            "tooling",
            "state",
            "logs",
        ):
            (self.private_root / directory).mkdir()
            (self.private_root / directory).chmod(0o700)
        protected_root = self.root / ".config" / "nas-platform"
        protected_root.mkdir(parents=True)
        (self.root / ".config").chmod(0o700)
        protected_root.chmod(0o700)
        for protected_file in (
            protected_root / "vault.yml",
            protected_root / "vault-password",
            protected_root / "ntfy.curlrc",
        ):
            protected_file.write_text("test-only\n", encoding="utf-8")
            protected_file.chmod(0o600)
        self.state_sentinel = self.private_root / "state" / "sentinel"
        self.state_sentinel.write_text("unchanged\n", encoding="utf-8")

        self.config = {
            "repository": "yonatankarp/nas-platform",
            "repository_url": "https://github.com/yonatankarp/nas-platform.git",
            "workflow": "ci.yml",
            "workflow_name": "CI",
            "branch": "main",
            "controller_python": sys.executable,
            "deployment_home": str(self.root),
            "controller_root": str(self.private_root / "controller"),
            "tooling_root": str(self.private_root / "tooling"),
            "state_root": str(self.private_root / "state"),
            "log_root": str(self.private_root / "logs"),
            "vault_file": str(protected_root / "vault.yml"),
            "vault_password_file": str(protected_root / "vault-password"),
            "ntfy_curl_config": str(protected_root / "ntfy.curlrc"),
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
        self.config_path = protected_root / "deployer.json"
        self.write_config()
        effective_home = mock.patch.object(
            production_auto_deploy.pwd,
            "getpwuid",
            return_value=mock.Mock(pw_dir=str(self.root)),
        )
        effective_home.start()
        self.addCleanup(effective_home.stop)
        self.install_fake("git", self.fake_git_source(MAIN_SHA))
        self.install_recording_fake("ansible-playbook")
        self.install_recording_fake("curl", consume_stdin=True)
        self.real_validate_trusted_executable = (
            production_auto_deploy._validate_trusted_executable
        )
        self.real_validate_controller_python = (
            production_auto_deploy._validate_controller_python
        )
        trusted_executable = mock.patch.object(
            production_auto_deploy,
            "_validate_trusted_executable",
            side_effect=lambda path: Path(path),
        )
        trusted_executable.start()
        self.addCleanup(trusted_executable.stop)
        system_git = mock.patch.object(
            production_auto_deploy,
            "SYSTEM_GIT_PATH",
            self.fake_bin / "git",
        )
        system_git.start()
        self.addCleanup(system_git.stop)
        system_curl = mock.patch.object(
            production_auto_deploy,
            "SYSTEM_CURL_PATH",
            self.fake_bin / "curl",
        )
        system_curl.start()
        self.addCleanup(system_curl.stop)
        controller_python = mock.patch.object(
            production_auto_deploy,
            "_validate_controller_python",
            return_value=Path(sys.executable),
        )
        controller_python.start()
        self.addCleanup(controller_python.stop)

    def write_config(self):
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        self.config_path.chmod(0o600)

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
            "expected = ['--no-replace-objects', 'ls-remote', '--exit-code', "
            "'https://github.com/yonatankarp/nas-platform.git', "
            "'refs/heads/main']\n"
            "if sys.argv[1:] != expected:\n"
            "    raise SystemExit(41)\n"
            f"print({sha!r} + '\\trefs/heads/main')\n"
        )

    def install_recording_fake(self, name, *, consume_stdin=False):
        stdin_source = "sys.stdin.buffer.read()\n" if consume_stdin else ""
        self.install_fake(
            name,
            f"#!{sys.executable}\n"
            "import pathlib\n"
            "import sys\n"
            + stdin_source
            + f"pathlib.Path({str(self.tool_calls)!r}).open('a').write("
            f"{name!r} + ' ' + ' '.join(sys.argv[1:]) + '\\n')\n",
        )

    def checkout_command_runner(
        self,
        *,
        sha=MAIN_SHA,
        origin="https://github.com/yonatankarp/nas-platform.git",
        dirty=b"",
        ignored=b"",
        gitmodules=False,
        gitmodules_inspection_error=False,
        submodule=False,
        symlink=False,
        sparse_config=False,
        skip_worktree=False,
        toplevel=None,
        git_dir=None,
        git_common_dir=None,
        post_checkout_sha=None,
    ):
        calls = []

        def run(arguments, **kwargs):
            raw_arguments = list(arguments)
            command = raw_arguments[1:]
            if command[:1] == ["--no-replace-objects"]:
                command = command[1:]
            while command[:1] == ["-c"]:
                command = command[2:]
            arguments = [raw_arguments[0], *command]
            calls.append((arguments, kwargs))
            stdout = b""
            returncode = 0
            if command == ["remote", "get-url", "origin"]:
                stdout = (origin + "\n").encode()
            elif command == ["remote"]:
                stdout = b"origin\n"
            elif command == ["status", "--porcelain=v1", "--untracked-files=all"]:
                stdout = dirty
            elif command == [
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--ignored=matching",
            ]:
                stdout = dirty + ignored
            elif command[:3] == ["config", "--local", "--get-regexp"]:
                if sparse_config and "sparseCheckout" in command[3]:
                    stdout = b"core.sparseCheckout true\n"
                else:
                    returncode = 1
            elif command == ["ls-files", "-v"]:
                stdout = b"S site.yml\n" if skip_worktree else b"H site.yml\n"
            elif command == ["rev-parse", "--show-toplevel"]:
                stdout = (str(toplevel or self.private_root / "controller") + "\n").encode()
            elif command == ["rev-parse", "--absolute-git-dir"]:
                stdout = (
                    str(git_dir or self.private_root / "controller" / ".git") + "\n"
                ).encode()
            elif command == ["rev-parse", "--path-format=absolute", "--git-common-dir"]:
                stdout = (
                    str(git_common_dir or self.private_root / "controller" / ".git") + "\n"
                ).encode()
            elif command[:2] == ["ls-tree", "--name-only"]:
                if gitmodules_inspection_error:
                    returncode = 41
                else:
                    stdout = b".gitmodules\n" if gitmodules else b""
            elif command[:3] == ["ls-tree", "-r", "--full-tree"]:
                if submodule:
                    stdout = (
                        b"160000 commit 1111111111111111111111111111111111111111"
                        b"\tthird-party\n"
                    )
                elif symlink:
                    stdout = (
                        b"120000 blob 1111111111111111111111111111111111111111"
                        b"\tunsafe-link\n"
                    )
            elif command == ["symbolic-ref", "-q", "HEAD"]:
                returncode = 1
            elif command in (
                ["rev-parse", "HEAD"],
                ["rev-parse", "refs/remotes/origin/main"],
            ):
                resolved_sha = sha
                if (
                    command == ["rev-parse", "refs/remotes/origin/main"]
                    and post_checkout_sha is not None
                    and any(call[0][1:2] == ["checkout"] for call in calls)
                ):
                    resolved_sha = post_checkout_sha
                stdout = (resolved_sha + "\n").encode()
            return subprocess.CompletedProcess(
                arguments,
                returncode,
                stdout=stdout,
                stderr=b"",
            )

        return calls, run

    def seed_candidate_files(self, checkout=None):
        checkout = Path(checkout or self.config["controller_root"])
        (checkout / "controller-requirements.txt").write_bytes(
            authoritative_controller_requirements()
        )
        collection_requirements, _pins = authoritative_collection_requirements()
        (checkout / "requirements.yml").write_bytes(collection_requirements)
        (checkout / "ansible.cfg").write_text("[defaults]\n", encoding="utf-8")
        (checkout / "inventory").mkdir(exist_ok=True)
        (checkout / "inventory" / "local.yml").write_text(
            "all:\n  hosts:\n    localhost:\n",
            encoding="utf-8",
        )
        for play in (
            "validate-vault.yml",
            "site.yml",
            "verify.yml",
            "install-production-auto-deploy.yml",
        ):
            (checkout / play).write_text("---\n", encoding="utf-8")
        return checkout

    def seed_valid_tooling(self, root, identity):
        root = Path(root)
        (root / "venv" / "bin").mkdir(parents=True)
        (root / "collections").mkdir()
        root.chmod(0o700)
        for name in ("python", "ansible-playbook", "ansible-galaxy", "ansible-lint"):
            executable = root / "venv" / "bin" / name
            executable.write_text("#!/bin/sh\n", encoding="utf-8")
            executable.chmod(0o700)
        production_auto_deploy._write_seal_file(
            root,
            ".installed",
            installed_tooling_manifest(),
        )
        production_auto_deploy._seal_tooling(root, identity)
        return root

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

    def invoke_raw_main(self, *arguments):
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
            status = production_auto_deploy.main(list(arguments))
        return status, stdout.getvalue(), stderr.getvalue()

    def write_cli_generation(self, config_bytes, variant=b""):
        libexec = self.root / ".local" / "libexec" / "nas-platform"
        generations = libexec / "generations"
        generations.mkdir(parents=True, exist_ok=True)
        for directory in (
            self.root / ".local" / "libexec",
            libexec,
            generations,
        ):
            directory.chmod(0o700)
        assets = {
            "nas-platform-deploy": b"#!/bin/sh\nexit 1\n" + variant,
            "production_auto_deploy.py": SCRIPT.read_bytes() + variant,
            "deployer.json": config_bytes,
            "ntfy.curl": b"url = test-only\n" + variant,
        }
        digest = hashlib.sha256()
        for name, body in assets.items():
            digest.update(len(name).to_bytes(2, "big") + name.encode() + body)
        generation = generations / digest.hexdigest()
        generation.mkdir(mode=0o700, exist_ok=True)
        for name, body in assets.items():
            path = generation / name
            path.write_bytes(body)
            path.chmod(0o700 if name in ("nas-platform-deploy", "production_auto_deploy.py") else 0o600)
        return libexec, generation, generation / "deployer.json"

    def invoke_main(self, *arguments):
        config_bytes = self.config_path.read_bytes()
        libexec, generation, generation_config = self.write_cli_generation(
            config_bytes
        )
        current = libexec / "current"
        if os.path.lexists(current):
            current.unlink()
        current.symlink_to(f"generations/{generation.name}")
        self.config_path.unlink()
        self.config_path.symlink_to(
            "../../.local/libexec/nas-platform/current/deployer.json"
        )
        try:
            with mock.patch.object(
                production_auto_deploy,
                "__file__",
                str(generation / "production_auto_deploy.py"),
            ):
                return self.invoke_raw_main(
                    "--config", str(generation_config), *arguments
                )
        finally:
            self.config_path.unlink(missing_ok=True)
            self.config_path.write_bytes(config_bytes)
            self.config_path.chmod(0o600)

    def invoke_eligibility(self):
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
            try:
                config = production_auto_deploy.load_config(self.config_path)
                run = production_auto_deploy._evaluate_ci(config)
            except (production_auto_deploy.ConfigurationError, OSError):
                print("production auto-deploy: unsafe configuration", file=sys.stderr)
                status = 1
            except production_auto_deploy.DeploymentError:
                print("production auto-deploy: unsafe controller runtime", file=sys.stderr)
                status = 1
            except production_auto_deploy.EligibilityError:
                print("production auto-deploy: no eligible CI run", file=sys.stderr)
                status = 0
            else:
                if run is None:
                    print("production auto-deploy: no eligible CI run", file=sys.stderr)
                else:
                    print(f"production auto-deploy: CI eligible for {run.head_sha}")
                status = 0
        return status, stdout.getvalue(), stderr.getvalue()

    def state_snapshot(self):
        return {
            f"{root.name}/{path.relative_to(root)}": (
                path.read_bytes() if path.is_file() else None
            )
            for root in (self.private_root / "state", self.private_root / "logs")
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
        return self.private_root / "state" / name

    def replace_state_root(self, suffix):
        state_root = self.private_root / "state"
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
        state_root = self.private_root / "state"
        moved_root = self.private_root / "state-pinned"
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

    def test_config_requires_absolute_controller_python(self):
        self.config["controller_python"] = "python3.12"
        self.write_config()

        with self.assertRaises(production_auto_deploy.ConfigurationError):
            production_auto_deploy.load_config(self.config_path)

    def test_runtime_paths_have_separate_private_and_protected_home_boundaries(self):
        cases = {
            "controller outside private share": (
                "controller_root",
                self.root / "controller",
            ),
            "vault outside protected config": (
                "vault_file",
                self.private_root / "vault.yml",
            ),
        }
        for label, (field, hostile_path) in cases.items():
            with self.subTest(label=label):
                config = dataclasses.replace(self.loaded_config(), **{field: hostile_path})
                with self.assertRaises(production_auto_deploy.ConfigurationError):
                    production_auto_deploy._validate_protected_config(config)

    def test_prepare_tooling_uses_validated_controller_python_for_venv(self):
        checkout = self.seed_candidate_files()
        calls = []

        def stop_after_venv(arguments, **_kwargs):
            calls.append(list(arguments))
            raise production_auto_deploy.DeploymentError("stop after venv")

        with mock.patch.object(
            production_auto_deploy,
            "_validate_controller_python",
            return_value=Path("/trusted/python3.12"),
        ), mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=stop_after_venv,
        ), self.assertRaises(
            production_auto_deploy.DeploymentError
        ):
            production_auto_deploy.prepare_tooling(self.loaded_config(), checkout)

        self.assertEqual(
            calls[0][:4], ["/trusted/python3.12", "-m", "venv", "--copies"]
        )

    def test_git_commands_ignore_malicious_ambient_path(self):
        malicious_git = self.fake_bin / "git"
        calls = []

        def record(arguments, **kwargs):
            calls.append((list(arguments), kwargs))
            return subprocess.CompletedProcess(
                arguments,
                0,
                (MAIN_SHA + "\trefs/heads/main\n").encode("ascii"),
                b"",
            )

        with mock.patch.object(
            production_auto_deploy,
            "SYSTEM_GIT_PATH",
            Path("/usr/bin/git"),
            create=True,
        ), mock.patch.object(
            production_auto_deploy,
            "_validate_trusted_executable",
            return_value=Path("/usr/bin/git"),
            create=True,
        ), mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=record,
        ), mock.patch.dict(
            os.environ, {"PATH": str(self.fake_bin)}
        ):
            self.assertEqual(
                production_auto_deploy.resolve_main_sha(self.loaded_config()),
                MAIN_SHA,
            )

        self.assertNotEqual(calls[0][0][0], str(malicious_git))
        self.assertEqual(calls[0][0][0], "/usr/bin/git")
        self.assertEqual(calls[0][1]["env"]["PATH"], "/usr/bin:/bin")

    def test_git_query_rejects_oversized_output_during_execution(self):
        fake_git = self.fake_bin / "git"
        fake_git.write_text(
            f"#!{sys.executable}\n"
            "import os\n"
            f"remaining={production_auto_deploy.MAX_RESPONSE_BYTES + production_auto_deploy.HTTP_READ_SIZE}\n"
            f"chunk=b'x'*{production_auto_deploy.HTTP_READ_SIZE}\n"
            "while remaining:\n"
            " size=min(remaining,len(chunk)); os.write(1,chunk[:size]); remaining-=size\n",
            encoding="utf-8",
        )
        fake_git.chmod(0o700)

        with self.assertRaises(production_auto_deploy.EligibilityError):
            production_auto_deploy.resolve_main_sha(self.loaded_config())

    def test_trusted_executable_rejects_symlink_and_writable_binary(self):
        symlink = self.root / "git-link"
        symlink.symlink_to("/usr/bin/git")
        writable_git = self.fake_bin / "git"
        writable_git.chmod(0o777)

        with self.assertRaises(production_auto_deploy.DeploymentError):
            self.real_validate_trusted_executable(symlink)
        with self.assertRaises(production_auto_deploy.DeploymentError):
            self.real_validate_trusted_executable(writable_git)

        self.assertEqual(
            self.real_validate_trusted_executable(Path("/usr/bin/git")),
            Path("/usr/bin/git"),
        )

    @unittest.skipUnless(
        sys.platform.startswith("linux") and os.geteuid() == 0,
        "requires a root Linux test container",
    )
    def test_trusted_executable_rejects_root_binary_below_untrusted_directory(self):
        untrusted_directory = self.root / "replaceable"
        untrusted_directory.mkdir()
        os.chown(untrusted_directory, 1000, 1000)
        untrusted_directory.chmod(0o700)
        executable = untrusted_directory / "python"
        executable.write_bytes(b"#!/bin/sh\nexit 0\n")
        os.chown(executable, 0, 0)
        executable.chmod(0o755)

        with self.assertRaises(production_auto_deploy.DeploymentError):
            self.real_validate_trusted_executable(executable)

    def test_controller_python_requires_version_3_12_or_newer(self):
        config = self.loaded_config()
        for version, accepted in ((b"3.11\n", False), (b"3.12\n", True)):
            with self.subTest(version=version), mock.patch.object(
                production_auto_deploy,
                "_run_command",
                return_value=subprocess.CompletedProcess([], 0, version, b""),
            ):
                if accepted:
                    self.assertEqual(
                        self.real_validate_controller_python(config),
                        Path(sys.executable),
                    )
                else:
                    with self.assertRaises(production_auto_deploy.DeploymentError):
                        self.real_validate_controller_python(config)

    def test_poll_cli_reports_controller_runtime_failures_without_mutation(self):
        invalid_python = self.fake_bin / "invalid-controller-python"
        invalid_python.write_text(
            f"#!{sys.executable}\nprint('not-a-version')\n", encoding="utf-8"
        )
        invalid_python.chmod(0o700)
        old_python = self.fake_bin / "old-controller-python"
        old_python.write_text(f"#!{sys.executable}\nprint('3.11')\n", encoding="utf-8")
        old_python.chmod(0o700)

        for label, controller_python in (
            ("unavailable", self.fake_bin / "missing-controller-python"),
            ("invalid", invalid_python),
            ("too old", old_python),
        ):
            with self.subTest(label=label):
                self.config["controller_python"] = str(controller_python)
                self.write_config()
                before = self.state_snapshot()
                with mock.patch.object(
                    production_auto_deploy,
                    "_validate_controller_python",
                    self.real_validate_controller_python,
                ):
                    status, stdout, stderr = self.invoke_main("--poll")

                self.assertEqual(status, 1)
                self.assertEqual(stdout, "")
                self.assertEqual(
                    stderr,
                    "production auto-deploy: unsafe controller runtime\n",
                )
                self.assertNotIn("Traceback", stderr)
                self.assertEqual(self.state_snapshot(), before)

    def test_github_api_base_is_fixed_to_production_origin(self):
        self.config["github_api_base"] = self.loopback_api_base
        self.write_config()
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_eligibility()

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
            status, stdout, stderr = self.invoke_eligibility()
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
            status, stdout, stderr = self.invoke_eligibility()
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

        status, stdout, stderr = self.invoke_eligibility()

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
                "git --no-replace-objects ls-remote --exit-code "
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
                status, stdout, stderr = self.invoke_eligibility()
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
                status, stdout, stderr = self.invoke_eligibility()
                self.assert_ci_rejected(status, stdout, stderr, before)

    def test_ambiguous_duplicate_successful_runs_are_rejected_without_mutation(self):
        run = self.successful_run()
        self.respond_with_runs([run, dict(run)])
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_eligibility()

        self.assert_ci_rejected(status, stdout, stderr, before)

    def test_incomplete_result_page_is_rejected_without_mutation(self):
        self.respond_with_runs([self.successful_run()], total_count=11)
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_eligibility()

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
                status, stdout, stderr = self.invoke_eligibility()
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
                status, stdout, stderr = self.invoke_eligibility()
                self.assert_ci_rejected(status, stdout, stderr, before)

    def test_malformed_json_is_rejected_without_echoing_response(self):
        secret_body = b'{"workflow_runs":["TOP-SECRET-BODY"'
        self.httpd.response_body = secret_body
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_eligibility()

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertNotIn("TOP-SECRET-BODY", stdout + stderr)

    def test_large_json_integer_is_rejected_without_parser_exception(self):
        self.httpd.response_body = b'{"workflow_runs":[' + b"9" * 5_000 + b"]}"
        before = self.state_snapshot()

        try:
            status, stdout, stderr = self.invoke_eligibility()
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
            status, stdout, stderr = self.invoke_eligibility()
        except RecursionError as error:
            self.fail(f"JSON parser exception escaped: {type(error).__name__}")

        self.assert_ci_rejected(status, stdout, stderr, before)

    def test_rate_limit_is_not_retried_or_echoed(self):
        secret_body = b'{"message":"rate limit SECRET-BODY"}'
        self.httpd.response_status = 403
        self.httpd.response_body = secret_body
        before = self.state_snapshot()

        status, stdout, stderr = self.invoke_eligibility()

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertEqual(len(self.httpd.requests), 1)
        self.assertNotIn("SECRET-BODY", stdout + stderr)

    def test_incomplete_chunked_response_is_rejected_without_http_exception(self):
        self.httpd.response_body = b'{"workflow_runs":["TRUNCATED-SECRET"]}'
        self.httpd.response_incomplete_chunk = True
        before = self.state_snapshot()

        try:
            status, stdout, stderr = self.invoke_eligibility()
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

                status, stdout, stderr = self.invoke_eligibility()

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
            status, stdout, stderr = self.invoke_eligibility()
        elapsed = time.monotonic() - started

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertLess(elapsed, 0.8)
        self.assertTrue(self.httpd.trickle_started.is_set())
        self.assertTrue(self.httpd.trickle_finished.wait(1.0))

    def test_trickled_status_obeys_outer_deadline_and_restores_signal_state(self):
        deadline = 0.05
        self.httpd.response_trickle_interval = 0.02
        self.httpd.response_wire_trickle = b"HTTP/1.1 200 OK\r\n" + b"X" * 100
        adversarial_duration = (
            len(self.httpd.response_wire_trickle)
            * self.httpd.response_trickle_interval
        )
        previous_handler = signal.getsignal(signal.SIGALRM)
        previous_timer = signal.getitimer(signal.ITIMER_REAL)
        before = self.state_snapshot()

        started = time.monotonic()
        with mock.patch.object(
            production_auto_deploy,
            "NETWORK_TIMEOUT_SECONDS",
            deadline,
        ):
            status, stdout, stderr = self.invoke_eligibility()
        elapsed = time.monotonic() - started

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertLess(elapsed, adversarial_duration)
        self.assertTrue(self.httpd.trickle_started.is_set())
        self.assertTrue(self.httpd.trickle_finished.wait(1.0))
        self.assertIs(signal.getsignal(signal.SIGALRM), previous_handler)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), previous_timer)

    def test_trickled_header_obeys_outer_deadline_without_thread_leak(self):
        deadline = 0.05
        self.httpd.response_trickle_interval = 0.02
        self.httpd.response_wire_prefix = b"HTTP/1.1 200 OK\r\n"
        self.httpd.response_wire_trickle = b"X-Slow: " + b"x" * 100
        adversarial_duration = (
            len(self.httpd.response_wire_trickle)
            * self.httpd.response_trickle_interval
        )
        before = self.state_snapshot()

        started = time.monotonic()
        with mock.patch.object(
            production_auto_deploy,
            "NETWORK_TIMEOUT_SECONDS",
            deadline,
        ):
            status, stdout, stderr = self.invoke_eligibility()
        elapsed = time.monotonic() - started

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertLess(elapsed, adversarial_duration)
        self.assertTrue(self.httpd.trickle_started.is_set())
        self.assertTrue(self.httpd.trickle_finished.wait(1.0))

    def test_trickled_chunk_header_obeys_outer_deadline_without_thread_leak(self):
        deadline = 0.05
        self.httpd.response_trickle_interval = 0.02
        self.httpd.response_chunk_header_trickle = True
        adversarial_duration = 100 * self.httpd.response_trickle_interval
        before = self.state_snapshot()

        started = time.monotonic()
        with mock.patch.object(
            production_auto_deploy,
            "NETWORK_TIMEOUT_SECONDS",
            deadline,
        ):
            status, stdout, stderr = self.invoke_eligibility()
        elapsed = time.monotonic() - started

        self.assert_ci_rejected(status, stdout, stderr, before)
        self.assertLess(elapsed, adversarial_duration)
        self.assertTrue(self.httpd.trickle_started.is_set())
        self.assertTrue(self.httpd.trickle_finished.wait(1.0))

    def test_outer_deadline_arms_exact_configured_itimer(self):
        configured_deadline = 0.375
        previous_handler = object()

        with mock.patch.object(
            production_auto_deploy.signal,
            "getitimer",
            return_value=(0.0, 0.0),
        ), mock.patch.object(
            production_auto_deploy.signal,
            "signal",
            return_value=previous_handler,
        ) as install_handler, mock.patch.object(
            production_auto_deploy.signal,
            "setitimer",
            return_value=(0.0, 0.0),
        ) as set_timer:
            with production_auto_deploy.http_wall_clock_deadline(
                configured_deadline
            ):
                pass

        armed_call, cleanup_call = set_timer.call_args_list
        self.assertEqual(
            armed_call,
            mock.call(signal.ITIMER_REAL, configured_deadline),
        )
        self.assertEqual(cleanup_call, mock.call(signal.ITIMER_REAL, 0))
        installed_handler, restored_handler = install_handler.call_args_list
        self.assertEqual(installed_handler.args[0], signal.SIGALRM)
        with self.assertRaises(production_auto_deploy.HttpDeadlineExpired):
            installed_handler.args[1](None, None)
        self.assertEqual(
            restored_handler,
            mock.call(signal.SIGALRM, previous_handler),
        )

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
                status, stdout, stderr = self.invoke_eligibility()

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

        status, stdout, stderr = self.invoke_eligibility()

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
                status, stdout, stderr = self.invoke_eligibility()
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
            status, stdout, stderr = self.invoke_eligibility()
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

        status, stdout, stderr = self.invoke_eligibility()

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
            status, stdout, stderr = self.invoke_eligibility()
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
            state_root = self.private_root / "state"
            state_root.rename(self.private_root / "state-before-delayed-publish")

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
            "module._owned_root = lambda config: config.deployment_home\n"
            f"config = module.load_config({str(self.config_path)!r})\n"
            f"sha = {MAIN_SHA!r}\n"
            "module.resolve_main_sha = lambda _config: sha\n"
            "module.fetch_ci_runs = lambda _config, _sha: (module.CiRun(\n"
            "    head_sha=sha, status='completed', conclusion='success',\n"
            "    event='push', head_branch='main', name='CI'),)\n"
            "def terminate(_config, _sha):\n"
            f"    state = pathlib.Path({str(self.private_root / 'state')!r})\n"
            f"    state.rename(pathlib.Path({str(self.private_root / 'state-before-sigkill')!r}))\n"
            "    state.mkdir(mode=0o700)\n"
            "    os.kill(os.getpid(), signal.SIGKILL)\n"
            "module.attempt_candidate = terminate\n"
            "module._validate_controller_python = lambda config: config.controller_python\n"
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
                for log_entry in (self.private_root / "logs").iterdir():
                    log_entry.unlink()
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
            production_auto_deploy,
            "_open_lock_at",
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

        (self.private_root / "state").chmod(0o755)
        assert_rejected()
        (self.private_root / "state").chmod(0o700)

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
                self.private_root / "state",
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
            "module._owned_root = lambda config: config.deployment_home\n"
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
            "module._owned_root = lambda config: config.deployment_home\n"
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
            "module._owned_root = lambda config: config.deployment_home\n"
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
        state_root = self.private_root / "state"
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
                for path in (self.private_root / "state").iterdir()
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

    def test_controller_requirements_are_exact_authoritative_pins(self):
        ansible_core, ansible_lint = authoritative_controller_pins()
        expected = (
            f"ansible-core=={ansible_core}\n"
            f"ansible-lint=={ansible_lint}\n"
        ).encode("ascii")
        self.assertEqual(
            (ROOT / "controller-requirements.txt").read_bytes(),
            expected,
        )
        installed_manifest = json.loads(installed_tooling_manifest())
        self.assertEqual(installed_manifest["ansible_core"], ansible_core)
        self.assertEqual(installed_manifest["ansible_lint"], ansible_lint)

    def test_candidate_may_bump_controller_pins_without_quarantine(self):
        checkout = self.seed_candidate_files()
        bumped = b"ansible-core==9.9.9\nansible-lint==8.8.8\n"
        (checkout / "controller-requirements.txt").write_bytes(bumped)

        payload = production_auto_deploy._read_tooling_requirement(
            checkout,
            "controller-requirements.txt",
        )

        self.assertEqual(payload, bumped)
        self.assertEqual(
            production_auto_deploy._parse_controller_pins(payload),
            ("9.9.9", "8.8.8"),
        )

    def test_malformed_controller_pins_are_rejected(self):
        for payload in (
            b"ansible-core==1.0\n",
            b"ansible-core\nansible-lint==2.0\n",
            b"ansible-core==1.0\nansible-core==1.0\n",
            b"ansible-core==1.0\nansible-lint==2.0\nextra==3.0\n",
            b"ansible-core==\nansible-lint==2.0\n",
        ):
            with self.subTest(payload=payload):
                with self.assertRaises(production_auto_deploy.DeploymentError):
                    production_auto_deploy._parse_controller_pins(payload)

    def test_positive_controller_fixture_versions_are_not_duplicated(self):
        source = Path(__file__).read_text(encoding="utf-8")
        fixture_literals = [
            (
                node.value.decode("ascii", errors="ignore")
                if isinstance(node.value, bytes)
                else node.value
            )
            for node in ast.walk(ast.parse(source))
            if isinstance(node, ast.Constant) and isinstance(node.value, (str, bytes))
        ]
        for version in authoritative_controller_pins():
            with self.subTest(version=version):
                self.assertFalse(
                    any(version in literal for literal in fixture_literals),
                    f"positive controller fixture version {version} must be derived",
                )

    def test_collection_fixtures_follow_authoritative_requirements(self):
        requirements, collections = authoritative_collection_requirements()
        self.assertEqual(collections, {"community.docker": "5.2.2"})
        self.assertEqual(
            (self.seed_candidate_files() / "requirements.yml").read_bytes(),
            requirements,
        )
        self.assertEqual(
            json.loads(installed_tooling_manifest())["collections"],
            collections,
        )

    def test_verify_tags_match_the_current_fail_closed_verification_contract(self):
        verify = (ROOT / "verify.yml").read_text(encoding="utf-8")
        mac_verify = (ROOT / "tests/mac/verify.sh").read_text(encoding="utf-8")

        self.assertEqual(verify.count("tags: [never]"), 9)
        self.assertEqual(mac_verify.count("--tags "), 1)
        self.assertIn(f"--tags {VERIFY_TAGS}\n", mac_verify)
        self.assertEqual(
            getattr(production_auto_deploy, "EXPECTED_VERIFY_TAGS", None),
            VERIFY_TAGS,
        )

    def test_production_auto_deploy_does_not_reintroduce_retired_adoption_lane(self):
        production_paths = [
            ROOT / "install-production-auto-deploy.yml",
            ROOT / "roles/production_auto_deploy/defaults/main.yml",
            ROOT / "roles/production_auto_deploy/meta/argument_specs.yml",
            ROOT / "roles/production_auto_deploy/tasks/main.yml",
            ROOT / "scripts/production_auto_deploy.py",
        ]

        for path in production_paths:
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertNotIn("platform_adoption", path.read_text(encoding="utf-8"))

    def test_task3_public_api_is_available(self):
        self.assertEqual(
            [
                name
                for name in (
                    "DeploymentError",
                    "Tooling",
                    "_run_command",
                    "prepare_checkout",
                    "tooling_identity",
                    "prepare_tooling",
                    "deploy_candidate",
                )
                if not hasattr(production_auto_deploy, name)
            ],
            [],
        )

    def test_prepare_checkout_fetches_only_main_and_detaches_exact_sha(self):
        checkout = self.seed_candidate_files()
        (checkout / ".git" / "objects" / "info").mkdir(parents=True)
        calls, run = self.checkout_command_runner()

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=run,
        ):
            result = production_auto_deploy.prepare_checkout(
                self.loaded_config(),
                MAIN_SHA,
            )

        self.assertEqual(result, checkout)
        commands = [arguments[1:] for arguments, _kwargs in calls]
        self.assertIn(
            [
                "fetch",
                "--no-tags",
                "--prune",
                "origin",
                "+refs/heads/main:refs/remotes/origin/main",
            ],
            commands,
        )
        self.assertIn(["checkout", "--detach", MAIN_SHA], commands)
        self.assertEqual(
            commands[-4:],
            [
                ["rev-parse", "HEAD"],
                ["rev-parse", "refs/remotes/origin/main"],
                ["symbolic-ref", "-q", "HEAD"],
                [
                    "ls-tree",
                    "--name-only",
                    MAIN_SHA,
                    "--",
                    ".gitmodules",
                ],
            ],
        )

    def test_prepare_checkout_rejects_dirty_or_wrong_origin_before_fetch(self):
        self.seed_candidate_files()
        (self.private_root / "controller" / ".git" / "objects" / "info").mkdir(parents=True)
        cases = (
            {"dirty": b" M site.yml\n"},
            {"origin": "https://github.com/attacker/nas-platform.git"},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides):
                calls, run = self.checkout_command_runner(**overrides)
                with mock.patch.object(
                    production_auto_deploy,
                    "_run_command",
                    side_effect=run,
                ), self.assertRaises(production_auto_deploy.DeploymentError):
                    production_auto_deploy.prepare_checkout(
                        self.loaded_config(),
                        MAIN_SHA,
                    )
                self.assertFalse(
                    any(arguments[1] == "fetch" for arguments, _kwargs in calls)
                )

    def test_prepare_checkout_rejects_gitmodules_submodules_and_sha_mismatch(self):
        self.seed_candidate_files()
        (self.private_root / "controller" / ".git" / "objects" / "info").mkdir(parents=True)
        cases = (
            {"gitmodules": True},
            {"gitmodules_inspection_error": True},
            {"submodule": True},
            {"sha": "fedcba9876543210fedcba9876543210fedcba98"},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides):
                calls, run = self.checkout_command_runner(**overrides)
                with mock.patch.object(
                    production_auto_deploy,
                    "_run_command",
                    side_effect=run,
                ), self.assertRaises(production_auto_deploy.DeploymentError):
                    production_auto_deploy.prepare_checkout(
                        self.loaded_config(),
                        MAIN_SHA,
                    )

    def test_prepare_checkout_rejects_all_git_symlink_entries(self):
        self.seed_candidate_files()
        (self.private_root / "controller" / ".git" / "objects" / "info").mkdir(parents=True)
        _calls, run = self.checkout_command_runner(symlink=True)

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=run,
        ), self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy.prepare_checkout(self.loaded_config(), MAIN_SHA)

    def test_prepare_checkout_revalidates_origin_main_after_checkout(self):
        self.seed_candidate_files()
        (self.private_root / "controller" / ".git" / "objects" / "info").mkdir(parents=True)
        _calls, run = self.checkout_command_runner(
            post_checkout_sha="abcdef0123456789abcdef0123456789abcdef01"
        )

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=run,
        ), self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy.prepare_checkout(self.loaded_config(), MAIN_SHA)

    def test_prepare_checkout_rejects_alternate_object_environment_and_file(self):
        self.seed_candidate_files()
        alternate = (
            self.private_root / "controller" / ".git" / "objects" / "info" / "alternates"
        )
        alternate.parent.mkdir(parents=True)
        for label, environment, create_file in (
            ("object directory", {"GIT_OBJECT_DIRECTORY": "/tmp/objects"}, False),
            (
                "alternate directories",
                {"GIT_ALTERNATE_OBJECT_DIRECTORIES": "/tmp/alternate"},
                False,
            ),
            ("config injection", {"GIT_CONFIG_COUNT": "1"}, False),
            ("alternates file", {}, True),
        ):
            with self.subTest(label=label):
                if create_file:
                    alternate.write_text("/tmp/objects\n", encoding="utf-8")
                calls, run = self.checkout_command_runner()
                with mock.patch.dict(
                    os.environ, environment, clear=False
                ), mock.patch.object(
                    production_auto_deploy,
                    "_run_command",
                    side_effect=run,
                ), self.assertRaises(
                    production_auto_deploy.DeploymentError
                ):
                    production_auto_deploy.prepare_checkout(
                        self.loaded_config(),
                        MAIN_SHA,
                    )
                self.assertFalse(
                    any(arguments[1] == "fetch" for arguments, _kwargs in calls)
                )
                if alternate.exists():
                    alternate.unlink()

    def test_prepare_checkout_rejects_symlinked_git_metadata(self):
        self.seed_candidate_files()
        external_git = self.root / "external-git"
        external_git.mkdir()
        (self.private_root / "controller" / ".git").symlink_to(
            external_git,
            target_is_directory=True,
        )
        calls, run = self.checkout_command_runner()

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=run,
        ), self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy.prepare_checkout(self.loaded_config(), MAIN_SHA)

        self.assertEqual(calls, [])

    def test_prepare_checkout_rejects_replacement_refs_before_fetch(self):
        checkout = self.private_root / "controller"
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        production_auto_deploy.SYSTEM_GIT_PATH = Path(real_git)

        def git(*arguments, capture=False):
            return subprocess.run(
                [real_git, *arguments],
                cwd=checkout,
                check=True,
                stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
            )

        git("init")
        git("config", "user.name", "Test User")
        git("config", "user.email", "test@example.invalid")
        git("config", "remote.origin.url", self.config["repository_url"])
        tracked = checkout / "tracked"
        tracked.write_text("safe\n", encoding="utf-8")
        git("add", "tracked")
        git("commit", "-m", "approved")
        approved = git("rev-parse", "HEAD", capture=True).stdout.strip()
        tracked.write_text("evil\n", encoding="utf-8")
        git("commit", "-am", "replacement")
        replacement = git("rev-parse", "HEAD", capture=True).stdout.strip()
        git("replace", approved, replacement)
        git("checkout", "--detach", "--force", approved)
        self.assertEqual(tracked.read_text(encoding="utf-8"), "evil\n")
        self.assertEqual(
            git(
                "--no-replace-objects", "show", f"{approved}:tracked", capture=True
            ).stdout,
            "safe\n",
        )
        safe_show = production_auto_deploy._git_command(
            self.loaded_config(),
            ["show", f"{approved}:tracked"],
        )
        self.assertEqual((safe_show.returncode, safe_show.stdout), (0, b"safe\n"))
        fetch_marker = self.root / "replacement-fetch"
        real_command = production_auto_deploy._git_command

        def reject_fetch(config, arguments):
            if arguments[:1] == ["fetch"]:
                fetch_marker.write_text("reached fetch\n", encoding="utf-8")
                return subprocess.CompletedProcess(arguments, 1, b"", b"")
            return real_command(config, arguments)

        with mock.patch.object(
            production_auto_deploy,
            "_git_command",
            side_effect=reject_fetch,
        ), self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy.prepare_checkout(
                self.loaded_config(),
                approved,
            )

        self.assertFalse(fetch_marker.exists())

    def test_prepare_checkout_rejects_redirected_core_worktree_before_fetch(self):
        checkout = self.private_root / "controller"
        external = self.root / "external-worktree"
        external.mkdir()
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        production_auto_deploy.SYSTEM_GIT_PATH = Path(real_git)

        def git(*arguments, cwd=checkout):
            subprocess.run(
                [real_git, *arguments],
                cwd=cwd,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        git("init")
        git("config", "user.name", "Test User")
        git("config", "user.email", "test@example.invalid")
        git("config", "remote.origin.url", self.config["repository_url"])
        (checkout / "tracked").write_text("tracked\n", encoding="utf-8")
        git("add", "tracked")
        git("commit", "-m", "test fixture")
        (external / "tracked").write_text("tracked\n", encoding="utf-8")
        git("config", "core.worktree", str(external))
        before = (external / "tracked").read_bytes()
        fetch_marker = self.root / "worktree-fetch"
        real_command = production_auto_deploy._git_command

        def reject_fetch(config, arguments):
            if arguments[:1] == ["fetch"]:
                fetch_marker.write_text("reached fetch\n", encoding="utf-8")
                return subprocess.CompletedProcess(arguments, 1, b"", b"")
            return real_command(config, arguments)

        with mock.patch.object(
            production_auto_deploy,
            "_git_command",
            side_effect=reject_fetch,
        ), self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy.prepare_checkout(
                self.loaded_config(),
                "0123456789abcdef0123456789abcdef01234567",
            )

        self.assertFalse(fetch_marker.exists())
        self.assertEqual((external / "tracked").read_bytes(), before)

    def test_prepare_checkout_rejects_grafts_or_shallow_metadata(self):
        self.seed_candidate_files()
        git_directory = self.private_root / "controller" / ".git"
        (git_directory / "objects" / "info").mkdir(parents=True)
        (git_directory / "info").mkdir()
        for metadata in (
            git_directory / "info" / "grafts",
            git_directory / "shallow",
        ):
            with self.subTest(metadata=metadata):
                metadata.write_text(MAIN_SHA + "\n", encoding="ascii")
                calls, run = self.checkout_command_runner()
                with mock.patch.object(
                    production_auto_deploy,
                    "_run_command",
                    side_effect=run,
                ), self.assertRaises(production_auto_deploy.DeploymentError):
                    production_auto_deploy.prepare_checkout(
                        self.loaded_config(),
                        MAIN_SHA,
                    )
                self.assertEqual(calls, [])
                metadata.unlink()

    def test_prepare_checkout_rejects_redirected_common_git_directory(self):
        self.seed_candidate_files()
        git_directory = self.private_root / "controller" / ".git"
        git_directory.mkdir()
        external_common_directory = self.root / "external-common-git"
        external_common_directory.mkdir()
        (git_directory / "commondir").write_text(
            str(external_common_directory) + "\n",
            encoding="utf-8",
        )
        calls, run = self.checkout_command_runner()

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=run,
        ), self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy.prepare_checkout(self.loaded_config(), MAIN_SHA)

        self.assertEqual(calls, [])

    def test_prepare_checkout_rejects_mismatched_top_level_or_git_directory(self):
        self.seed_candidate_files()
        (self.private_root / "controller" / ".git" / "objects" / "info").mkdir(parents=True)
        cases = (
            {"toplevel": self.root / "external-worktree"},
            {"git_dir": self.root / "external-git"},
            {"git_common_dir": self.root / "external-common-git"},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides):
                calls, run = self.checkout_command_runner(**overrides)
                with mock.patch.object(
                    production_auto_deploy,
                    "_run_command",
                    side_effect=run,
                ), self.assertRaises(production_auto_deploy.DeploymentError):
                    production_auto_deploy.prepare_checkout(
                        self.loaded_config(),
                        MAIN_SHA,
                    )
                self.assertFalse(
                    any(arguments[1] == "fetch" for arguments, _kwargs in calls)
                )

    def test_prepare_checkout_rejects_ignored_sparse_or_skip_worktree_state(self):
        self.seed_candidate_files()
        (self.private_root / "controller" / ".git" / "objects" / "info").mkdir(parents=True)
        cases = (
            {
                "ignored": b"!! inventory/group_vars/all/vault-plain.yml\n",
            },
            {"sparse_config": True},
            {"skip_worktree": True},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides):
                calls, run = self.checkout_command_runner(**overrides)
                with mock.patch.object(
                    production_auto_deploy,
                    "_run_command",
                    side_effect=run,
                ), self.assertRaises(production_auto_deploy.DeploymentError):
                    production_auto_deploy.prepare_checkout(
                        self.loaded_config(),
                        MAIN_SHA,
                    )
                self.assertFalse(
                    any(arguments[1] == "fetch" for arguments, _kwargs in calls)
                )

    def test_git_commands_disable_repository_hooks_and_fsmonitor(self):
        checkout = self.private_root / "controller"
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        production_auto_deploy.SYSTEM_GIT_PATH = Path(real_git)

        def git(*arguments):
            subprocess.run(
                [real_git, *arguments],
                cwd=checkout,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        git("init")
        git("config", "user.name", "Test User")
        git("config", "user.email", "test@example.invalid")
        (checkout / "tracked").write_text("tracked\n", encoding="utf-8")
        git("add", "tracked")
        git("commit", "-m", "test fixture")
        sha = subprocess.check_output(
            [real_git, "rev-parse", "HEAD"],
            cwd=checkout,
            text=True,
        ).strip()

        hook_marker = self.root / "hook-executed"
        hook = checkout / ".git" / "hooks" / "post-checkout"
        hook.write_text(
            f"#!/bin/sh\nprintf executed > {str(hook_marker)!r}\n",
            encoding="utf-8",
        )
        hook.chmod(0o700)
        fsmonitor_marker = self.root / "fsmonitor-executed"
        fsmonitor = self.root / "fsmonitor"
        fsmonitor.write_text(
            f"#!/bin/sh\nprintf executed > {str(fsmonitor_marker)!r}\nprintf '\\n'\n",
            encoding="utf-8",
        )
        fsmonitor.chmod(0o700)
        git("config", "core.fsmonitor", str(fsmonitor))

        status = production_auto_deploy._git_command(
            self.loaded_config(),
            ["status", "--porcelain=v1"],
        )
        checkout_result = production_auto_deploy._git_command(
            self.loaded_config(),
            ["checkout", "--detach", sha],
        )

        self.assertEqual((status.returncode, checkout_result.returncode), (0, 0))
        self.assertFalse(fsmonitor_marker.exists())
        self.assertFalse(hook_marker.exists())

    def test_prepare_checkout_rejects_clean_filter_before_status_executes_it(self):
        checkout = self.private_root / "controller"
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        production_auto_deploy.SYSTEM_GIT_PATH = Path(real_git)

        def git(*arguments):
            subprocess.run(
                [real_git, *arguments],
                cwd=checkout,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        git("init")
        git("config", "user.name", "Test User")
        git("config", "user.email", "test@example.invalid")
        git("config", "remote.origin.url", self.config["repository_url"])
        (checkout / ".gitattributes").write_text(
            "tracked filter=hostile\n",
            encoding="utf-8",
        )
        tracked = checkout / "tracked"
        tracked.write_text("tracked\n", encoding="utf-8")
        git("add", ".gitattributes", "tracked")
        git("commit", "-m", "test fixture")
        sha = subprocess.check_output(
            [real_git, "rev-parse", "HEAD"],
            cwd=checkout,
            text=True,
        ).strip()

        filter_marker = self.root / "filter-executed"
        clean_filter = self.root / "clean-filter"
        clean_filter.write_text(
            f"#!/bin/sh\nprintf executed > {str(filter_marker)!r}\ncat\n",
            encoding="utf-8",
        )
        clean_filter.chmod(0o700)
        git("config", "filter.hostile.clean", str(clean_filter))
        tracked.write_text("tracked\n", encoding="utf-8")

        with self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy.prepare_checkout(self.loaded_config(), sha)

        self.assertFalse(filter_marker.exists())

    def test_tooling_identity_hashes_length_prefixed_exact_file_bytes(self):
        checkout = self.seed_candidate_files()
        controller = (checkout / "controller-requirements.txt").read_bytes()
        collections = (checkout / "requirements.yml").read_bytes()
        expected = hashlib.sha256(
            len(controller).to_bytes(8, "big")
            + controller
            + len(collections).to_bytes(8, "big")
            + collections
        ).hexdigest()

        self.assertEqual(production_auto_deploy.tooling_identity(checkout), expected)

    def test_tooling_identity_rejects_symlinked_requirement_inputs(self):
        checkout = self.seed_candidate_files()
        external = self.root / "external-requirements"
        external.write_text(
            f"ansible-core=={authoritative_controller_pins()[0]}\n",
            encoding="utf-8",
        )
        controller_requirements = checkout / "controller-requirements.txt"
        controller_requirements.unlink()
        controller_requirements.symlink_to(external)

        with self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy.tooling_identity(checkout)

    def test_prepare_tooling_without_sha_rejects_symlinked_requirement_inputs(self):
        checkout = self.seed_candidate_files()
        external = self.root / "external-requirements"
        external.write_bytes(authoritative_controller_requirements())
        controller_requirements = checkout / "controller-requirements.txt"
        controller_requirements.unlink()
        controller_requirements.symlink_to(external)

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
        ) as run, self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy.prepare_tooling(self.loaded_config(), checkout)

        run.assert_not_called()

    def test_prepare_tooling_builds_privately_and_atomically_publishes(self):
        checkout = self.seed_candidate_files()
        calls = []

        def build(arguments, **kwargs):
            arguments = list(arguments)
            calls.append((arguments, kwargs))
            if arguments[1:3] == ["-m", "venv"]:
                bin_path = Path(arguments[-1]) / "bin"
                bin_path.mkdir(parents=True)
                for name in (
                    "python",
                    "ansible-playbook",
                    "ansible-galaxy",
                    "ansible-lint",
                ):
                    executable = bin_path / name
                    executable.write_text("#!/bin/sh\n", encoding="utf-8")
                    executable.chmod(0o700)
            if "collection" in arguments and "install" in arguments:
                Path(arguments[arguments.index("--collections-path") + 1]).mkdir(
                    parents=True
                )
            stdout = (
                ansible_playbook_version_output()
                if arguments[-1:] == ["--version"]
                else b""
            )
            return subprocess.CompletedProcess(arguments, 0, stdout, b"")

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=build,
        ), mock.patch.object(
            production_auto_deploy,
            "_capture_installed_tooling_manifest",
            return_value=installed_tooling_manifest(),
        ):
            tooling = production_auto_deploy.prepare_tooling(
                self.loaded_config(),
                checkout,
            )

        identity = production_auto_deploy.tooling_identity(checkout)
        published = self.private_root / "tooling" / identity
        self.assertTrue(tooling.__dataclass_params__.frozen)
        self.assertEqual(
            tooling,
            production_auto_deploy.Tooling(
                ansible_playbook=(published / "venv/bin/ansible-playbook").resolve(),
                python=(published / "venv/bin/python").resolve(),
                collections=(published / "collections").resolve(),
            ),
        )
        self.assertTrue((published / ".complete").is_file())
        self.assertEqual(
            [
                path
                for path in (self.private_root / "tooling").iterdir()
                if path.name.startswith(".")
            ],
            [],
        )
        pip_calls = [
            (arguments, kwargs)
            for arguments, kwargs in calls
            if "pip" in arguments and "install" in arguments
        ]
        self.assertEqual(len(pip_calls), 1)
        pip_arguments, pip_kwargs = pip_calls[0]
        self.assertIn("--isolated", pip_arguments)
        self.assertEqual(pip_arguments[-2], "--requirement")
        self.assertTrue(
            pip_arguments[-1].endswith("/.inputs/controller-requirements.txt")
        )
        self.assertEqual(
            (published / ".inputs" / "controller-requirements.txt").read_bytes(),
            (checkout / "controller-requirements.txt").read_bytes(),
        )
        self.assertEqual(pip_kwargs["env"]["PIP_CONFIG_FILE"], "/dev/null")
        self.assertEqual(pip_kwargs["env"]["PYTHONNOUSERSITE"], "1")
        galaxy_arguments, galaxy_kwargs = next(
            (arguments, kwargs)
            for arguments, kwargs in calls
            if "collection" in arguments and "install" in arguments
        )
        self.assertTrue(
            galaxy_kwargs["env"]["ANSIBLE_CONFIG"].endswith("/.ansible-build.cfg")
        )
        self.assertEqual(
            galaxy_kwargs["env"]["ANSIBLE_COLLECTIONS_PATH"],
            galaxy_arguments[galaxy_arguments.index("--collections-path") + 1],
        )
        self.assertTrue(
            galaxy_arguments[
                galaxy_arguments.index("--requirements-file") + 1
            ].endswith("/.inputs/requirements.yml")
        )

    def test_concurrent_tooling_publication_accepts_only_valid_complete_target(self):
        checkout = self.seed_candidate_files()
        identity = production_auto_deploy.tooling_identity(checkout)
        published = self.private_root / "tooling" / identity
        published.mkdir()

        with self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy.prepare_tooling(self.loaded_config(), checkout)

        self.assertEqual(list(published.iterdir()), [])

    def test_concurrent_tooling_publication_accepts_valid_race_winner(self):
        checkout = self.seed_candidate_files()
        identity = production_auto_deploy.tooling_identity(checkout)
        published = self.private_root / "tooling" / identity

        def build(arguments, **_kwargs):
            arguments = list(arguments)
            if arguments[1:3] == ["-m", "venv"]:
                bin_path = Path(arguments[-1]) / "bin"
                bin_path.mkdir(parents=True)
                for name in (
                    "python",
                    "ansible-playbook",
                    "ansible-galaxy",
                    "ansible-lint",
                ):
                    executable = bin_path / name
                    executable.write_text("#!/bin/sh\n", encoding="utf-8")
                    executable.chmod(0o700)
            if "collection" in arguments and "install" in arguments:
                Path(arguments[arguments.index("--collections-path") + 1]).mkdir(
                    parents=True
                )
            stdout = (
                ansible_playbook_version_output()
                if arguments[-1:] == ["--version"]
                else b""
            )
            return subprocess.CompletedProcess(arguments, 0, stdout, b"")

        def publish_winner(_source, destination):
            self.seed_valid_tooling(destination, identity)
            raise OSError(errno.ENOTEMPTY, "concurrent winner published")

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=build,
        ), mock.patch.object(
            production_auto_deploy,
            "_capture_installed_tooling_manifest",
            return_value=installed_tooling_manifest(),
        ), mock.patch.object(
            production_auto_deploy.os,
            "rename",
            side_effect=publish_winner,
        ):
            try:
                tooling = production_auto_deploy.prepare_tooling(
                    self.loaded_config(),
                    checkout,
                )
            except production_auto_deploy.DeploymentError as error:
                self.fail(f"valid concurrent publication was rejected: {error}")

        self.assertEqual(tooling, production_auto_deploy._tooling_paths(published))
        self.assertEqual(
            [
                path
                for path in (self.private_root / "tooling").iterdir()
                if path.name.startswith(".")
            ],
            [],
        )

    def test_published_tooling_reuse_rejects_collection_tampering(self):
        checkout = self.seed_candidate_files()

        def build(arguments, **_kwargs):
            arguments = list(arguments)
            if arguments[1:3] == ["-m", "venv"]:
                bin_path = Path(arguments[-1]) / "bin"
                bin_path.mkdir(parents=True)
                for name in (
                    "python",
                    "ansible-playbook",
                    "ansible-galaxy",
                    "ansible-lint",
                ):
                    executable = bin_path / name
                    executable.write_text("#!/bin/sh\n", encoding="utf-8")
                    executable.chmod(0o700)
            if "collection" in arguments and "install" in arguments:
                Path(arguments[arguments.index("--collections-path") + 1]).mkdir(
                    parents=True
                )
            stdout = (
                ansible_playbook_version_output()
                if arguments[-1:] == ["--version"]
                else b""
            )
            return subprocess.CompletedProcess(arguments, 0, stdout, b"")

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=build,
        ), mock.patch.object(
            production_auto_deploy,
            "_capture_installed_tooling_manifest",
            return_value=installed_tooling_manifest(),
        ):
            tooling = production_auto_deploy.prepare_tooling(
                self.loaded_config(),
                checkout,
            )

        tooling.collections.chmod(0o700)
        (tooling.collections / "tampered.py").write_text(
            "raise RuntimeError('tampered')\n",
            encoding="utf-8",
        )
        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=build,
        ), mock.patch.object(
            production_auto_deploy,
            "_capture_installed_tooling_manifest",
            return_value=installed_tooling_manifest(),
        ), self.assertRaises(
            production_auto_deploy.DeploymentError
        ):
            production_auto_deploy.prepare_tooling(
                self.loaded_config(),
                checkout,
            )

    def test_tooling_manifest_rejects_symlink_and_hardlink_artifacts(self):
        for artifact_type in ("symlink", "hardlink"):
            with self.subTest(artifact_type=artifact_type):
                staging = self.root / f"tooling-{artifact_type}"
                staging.mkdir()
                target = staging / "target"
                target.write_text("payload\n", encoding="utf-8")
                artifact = staging / "artifact"
                if artifact_type == "symlink":
                    artifact.symlink_to(target.name)
                else:
                    os.link(target, artifact)

                with self.assertRaises(production_auto_deploy.DeploymentError):
                    production_auto_deploy._tooling_manifest(staging)

    def test_standard_venv_lib64_symlink_is_removed_but_other_links_fail(self):
        venv = self.root / "venv-links"
        (venv / "lib").mkdir(parents=True)
        (venv / "lib64").symlink_to("lib")

        production_auto_deploy._remove_standard_venv_symlink(venv)
        self.assertFalse((venv / "lib64").exists())
        self.assertFalse((venv / "lib64").is_symlink())

        (venv / "lib64").symlink_to(self.root)
        with self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy._remove_standard_venv_symlink(venv)

    def test_internal_file_symlinks_are_materialized_before_tooling_seal(self):
        staging = self.root / "materialized-tooling"
        staging.mkdir()
        target = staging / "target"
        target.write_bytes(b"exact payload\n")
        target.chmod(0o700)
        internal = staging / "internal"
        internal.symlink_to("target")

        production_auto_deploy._materialize_internal_symlinks(staging)

        self.assertFalse(internal.is_symlink())
        self.assertEqual(internal.read_bytes(), target.read_bytes())
        self.assertTrue(internal.stat().st_mode & stat.S_IXUSR)

        external_target = self.root / "external-target"
        external_target.write_bytes(b"external\n")
        (staging / "external").symlink_to(external_target)
        with self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy._materialize_internal_symlinks(staging)

    def test_installed_tooling_manifest_validates_exact_versions_and_collections(self):
        ansible_core, ansible_lint = authoritative_controller_pins()
        _requirements, expected_collections = authoritative_collection_requirements()
        root = self.root / "canonical-tooling"
        (root / "venv" / "bin").mkdir(parents=True)
        (root / "collections").mkdir()
        tooling = production_auto_deploy._tooling_paths(root)
        calls = []

        def run(arguments, **kwargs):
            arguments = list(arguments)
            calls.append((arguments, kwargs))
            if arguments[1:3] == ["-m", "pip"]:
                output = (
                    f"ansible-core=={ansible_core}\n"
                    f"ansible-lint=={ansible_lint}\n"
                ).encode("ascii")
            elif arguments[1:3] == ["-m", "ansiblelint"]:
                output = (
                    f"ansible-lint {ansible_lint} using "
                    f"ansible-core:{ansible_core}\n"
                ).encode("ascii")
            elif arguments[1:3] == ["-m", "ansible.cli.galaxy"]:
                installed_collections = {
                    name: {"version": version}
                    for name, version in expected_collections.items()
                }
                installed_collections[
                    "community.library_inventory_filtering_v1"
                ] = {"version": "1.1.5"}
                output = json.dumps(
                    {
                        str(
                            tooling.collections / "ansible_collections"
                        ): installed_collections
                    }
                ).encode("ascii")
            elif arguments[1:2] == ["-c"]:
                output = b"3.12\n"
            else:
                output = f"ansible-playbook [core {ansible_core}]\n".encode("ascii")
            return subprocess.CompletedProcess(arguments, 0, output, b"")

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=run,
        ):
            manifest = production_auto_deploy._capture_installed_tooling_manifest(
                tooling,
                self.root,
                expected_collections,
                ansible_core,
                ansible_lint,
            )

        payload = json.loads(manifest)
        self.assertEqual(payload["python"], "3.12")
        self.assertEqual(payload["ansible_core"], ansible_core)
        self.assertEqual(payload["ansible_lint"], ansible_lint)
        self.assertEqual(
            payload["collections"],
            {
                **expected_collections,
                "community.library_inventory_filtering_v1": "1.1.5",
            },
        )
        pip_call = next(arguments for arguments, _kwargs in calls if "pip" in arguments)
        self.assertIn("--isolated", pip_call)
        self.assertIn("--all", pip_call)
        self.assertIn(
            [tooling.python, "-m", "ansiblelint", "--version"],
            [arguments for arguments, _kwargs in calls],
        )
        self.assertTrue(
            any(
                arguments[1:3] == ["-m", "ansible.cli.galaxy"]
                for arguments, _kwargs in calls
            )
        )

    def test_candidate_collection_pin_drives_published_manifest_validation(self):
        checkout = self.seed_candidate_files()
        requirements, current_collections = authoritative_collection_requirements()
        current_version = current_collections["community.docker"]
        mutated_version = "9.9.9"
        current_pin = f"version: {current_version}".encode("ascii")
        mutated_pin = f"version: {mutated_version}".encode("ascii")
        self.assertEqual(requirements.count(current_pin), 1)
        (checkout / "requirements.yml").write_bytes(
            requirements.replace(current_pin, mutated_pin)
        )
        expected_collections = {"community.docker": mutated_version}

        def build_and_inspect(arguments, **_kwargs):
            arguments = list(arguments)
            if arguments[1:3] == ["-m", "venv"]:
                bin_path = Path(arguments[-1]) / "bin"
                bin_path.mkdir(parents=True)
                for name in (
                    "python",
                    "ansible-playbook",
                    "ansible-galaxy",
                    "ansible-lint",
                ):
                    executable = bin_path / name
                    executable.write_text("#!/bin/sh\n", encoding="utf-8")
                    executable.chmod(0o700)
            if "collection" in arguments and "install" in arguments:
                Path(arguments[arguments.index("--collections-path") + 1]).mkdir(
                    parents=True
                )

            if arguments[1:3] == ["-m", "pip"] and "freeze" in arguments:
                output = authoritative_controller_requirements()
            elif arguments[1:3] == ["-m", "ansiblelint"]:
                output = (
                    "ansible-lint "
                    f"{authoritative_controller_pins()[1]}\n"
                ).encode("ascii")
            elif arguments[1:3] == ["-m", "ansible.cli.galaxy"]:
                output = json.dumps(
                    {
                        "mutated": {
                            "community.docker": {"version": mutated_version}
                        }
                    }
                ).encode("ascii")
            elif arguments[-1:] == ["--version"]:
                output = (
                    "ansible-playbook [core "
                    f"{authoritative_controller_pins()[0]}]\n"
                ).encode("ascii")
            elif arguments[1:2] == ["-c"]:
                output = b"3.14\n"
            else:
                output = b""
            return subprocess.CompletedProcess(arguments, 0, output, b"")

        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=build_and_inspect,
        ):
            tooling = production_auto_deploy.prepare_tooling(
                self.loaded_config(),
                checkout,
            )

        published_manifest = json.loads(
            (tooling.python.parent.parent.parent / ".installed").read_bytes()
        )
        self.assertEqual(published_manifest["collections"], expected_collections)

    def test_deploy_candidate_runs_exact_plays_with_minimal_environment(self):
        checkout = self.seed_candidate_files()
        tooling_root = self.private_root / "tooling" / "prepared"
        (tooling_root / "venv/bin").mkdir(parents=True)
        (tooling_root / "collections").mkdir()
        tooling = production_auto_deploy.Tooling(
            ansible_playbook=(tooling_root / "venv/bin/ansible-playbook").resolve(),
            python=(tooling_root / "venv/bin/python").resolve(),
            collections=(tooling_root / "collections").resolve(),
        )
        calls = []

        def record(arguments, **kwargs):
            calls.append((list(arguments), kwargs))
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        hostile_environment = {
            "ANSIBLE_ROLES_PATH": "/attacker/roles",
        }
        with mock.patch.object(
            production_auto_deploy,
            "prepare_checkout",
            return_value=checkout,
        ), mock.patch.object(
            production_auto_deploy,
            "prepare_tooling",
            return_value=tooling,
        ), mock.patch.object(
            production_auto_deploy,
            "_validate_materialized_checkout",
        ), mock.patch.object(
            production_auto_deploy,
            "_validate_tooling_for_execution",
        ), mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=record,
        ), mock.patch.dict(
            os.environ, hostile_environment, clear=False
        ):
            succeeded = production_auto_deploy.deploy_candidate(
                self.loaded_config(),
                MAIN_SHA,
                io.BytesIO(),
            )

        self.assertTrue(succeeded)
        ansible = str(tooling.ansible_playbook)
        vault = str(self.root / ".config" / "nas-platform" / "vault.yml")
        password = str(self.root / ".config" / "nas-platform" / "vault-password")
        shared_arguments = [
            "--vault-password-file",
            password,
            "-e",
            f"@{vault}",
            "-e",
            f"platform_vault_file={vault}",
            "-e",
            f"ansible_python_interpreter={sys.executable}",
        ]
        self.assertEqual(
            [arguments for arguments, _kwargs in calls],
            [
                [ansible, "validate-vault.yml", *shared_arguments],
                [ansible, "-i", "inventory/local.yml", "site.yml", *shared_arguments],
                [
                    ansible,
                    "-i",
                    "inventory/local.yml",
                    "verify.yml",
                    *shared_arguments,
                    "--tags",
                    VERIFY_TAGS,
                ],
                [
                    ansible,
                    "-i",
                    "inventory/local.yml",
                    "install-production-auto-deploy.yml",
                    *shared_arguments,
                ],
            ],
        )
        allowed = {
            "PATH",
            "LANG",
            "LC_ALL",
            "HOME",
            "PLATFORM_NAS_ADDRESS",
            "PLATFORM_PUBLIC_HOST",
            "PLATFORM_CALLBACK_HOST",
            "PLATFORM_VAULT_FILE",
            "ANSIBLE_CONFIG",
            "ANSIBLE_COLLECTIONS_PATH",
        }
        for arguments, kwargs in calls:
            interpreter_pins = [
                argument
                for argument in arguments
                if argument.startswith("ansible_python_interpreter=")
            ]
            self.assertEqual(
                interpreter_pins,
                [f"ansible_python_interpreter={sys.executable}"],
            )
            expected_tag_count = 1 if "verify.yml" in arguments else 0
            self.assertEqual(arguments.count("--tags"), expected_tag_count)
            if expected_tag_count:
                self.assertEqual(arguments[-4:-2], ["-e", interpreter_pins[0]])
                self.assertEqual(arguments[-2:], ["--tags", VERIFY_TAGS])
            else:
                self.assertEqual(arguments[-2:], ["-e", interpreter_pins[0]])
            self.assertEqual(kwargs["cwd"], checkout)
            environment = kwargs["env"]
            self.assertEqual(set(environment), allowed)
            self.assertFalse(hostile_environment.keys() & kwargs["env"].keys())
            self.assertEqual(
                {
                    "PLATFORM_NAS_ADDRESS": environment["PLATFORM_NAS_ADDRESS"],
                    "PLATFORM_PUBLIC_HOST": environment["PLATFORM_PUBLIC_HOST"],
                    "PLATFORM_CALLBACK_HOST": environment["PLATFORM_CALLBACK_HOST"],
                    "PLATFORM_VAULT_FILE": environment["PLATFORM_VAULT_FILE"],
                    "ANSIBLE_CONFIG": environment["ANSIBLE_CONFIG"],
                    "ANSIBLE_COLLECTIONS_PATH": environment["ANSIBLE_COLLECTIONS_PATH"],
                },
                {
                    "PLATFORM_NAS_ADDRESS": "192.168.0.139",
                    "PLATFORM_PUBLIC_HOST": "192.168.0.139",
                    "PLATFORM_CALLBACK_HOST": "192.168.0.139",
                    "PLATFORM_VAULT_FILE": vault,
                    "ANSIBLE_CONFIG": str(checkout / "ansible.cfg"),
                    "ANSIBLE_COLLECTIONS_PATH": str(tooling.collections),
                },
            )

    def test_local_interpreter_pin_follows_conflicting_extra_var_files(self):
        tooling = production_auto_deploy.Tooling(
            ansible_playbook=Path("/sealed/venv/bin/ansible-playbook"),
            python=Path("/sealed/venv/bin/python"),
            collections=Path("/sealed/collections"),
        )
        conflict = self.private_root / "conflicting-extra-vars.json"
        conflict.write_text(
            json.dumps({"ansible_python_interpreter": "/attacker/python"}),
            encoding="utf-8",
        )
        conflict.chmod(0o600)

        arguments = production_auto_deploy._playbook_arguments(
            self.loaded_config(),
            tooling,
            "install-production-auto-deploy.yml",
            inventory=True,
            controller_python=Path(sys.executable),
            extra_vars_file=conflict,
        )

        pins = [
            argument
            for argument in arguments
            if argument.startswith("ansible_python_interpreter=")
        ]
        self.assertEqual(
            pins,
            [f"ansible_python_interpreter={sys.executable}"],
        )
        self.assertEqual(arguments[-4:], ["-e", f"@{conflict}", "-e", pins[0]])

    def test_local_interpreter_pin_rejects_a_conflicting_validated_identity(self):
        tooling = production_auto_deploy.Tooling(
            ansible_playbook=Path("/sealed/venv/bin/ansible-playbook"),
            python=Path("/sealed/venv/bin/python"),
            collections=Path("/sealed/collections"),
        )

        with self.assertRaisesRegex(
            production_auto_deploy.DeploymentError,
            "controller Python identity changed",
        ):
            production_auto_deploy._playbook_arguments(
                self.loaded_config(),
                tooling,
                "site.yml",
                inventory=True,
                controller_python=Path("/attacker/python"),
            )

    def test_deploy_candidate_stops_after_each_failed_play(self):
        checkout = self.seed_candidate_files()
        tooling = production_auto_deploy.Tooling(
            ansible_playbook=Path("/private/tooling/ansible-playbook"),
            python=Path("/private/tooling/python"),
            collections=Path("/private/tooling/collections"),
        )
        old_launcher = self.root / "launcher"
        old_launcher.write_text("old launcher\n", encoding="utf-8")
        plays = (
            "validate-vault.yml",
            "site.yml",
            "verify.yml",
            "install-production-auto-deploy.yml",
        )
        for failed_play in plays:
            with self.subTest(failed_play=failed_play):
                called_plays = []

                def fail_selected(arguments, **_kwargs):
                    play = next(item for item in arguments if Path(item).name in plays)
                    called_plays.append(play)
                    return subprocess.CompletedProcess(
                        arguments,
                        1 if play == failed_play else 0,
                        b"",
                        b"failed",
                    )

                with mock.patch.object(
                    production_auto_deploy,
                    "prepare_checkout",
                    return_value=checkout,
                ), mock.patch.object(
                    production_auto_deploy,
                    "prepare_tooling",
                    return_value=tooling,
                ), mock.patch.object(
                    production_auto_deploy,
                    "_validate_materialized_checkout",
                ), mock.patch.object(
                    production_auto_deploy,
                    "_validate_tooling_for_execution",
                ), mock.patch.object(
                    production_auto_deploy,
                    "_run_command",
                    side_effect=fail_selected,
                ):
                    succeeded = production_auto_deploy.deploy_candidate(
                        self.loaded_config(),
                        MAIN_SHA,
                        io.BytesIO(),
                    )

                failed_index = plays.index(failed_play)
                self.assertFalse(succeeded)
                self.assertEqual(called_plays, list(plays[: failed_index + 1]))
                self.assertEqual(
                    old_launcher.read_text(encoding="utf-8"), "old launcher\n"
                )

    def test_deploy_candidate_revalidates_checkout_before_every_play(self):
        checkout = self.seed_candidate_files()
        tooling = production_auto_deploy.Tooling(
            ansible_playbook=Path("/private/tooling/ansible-playbook"),
            python=Path("/private/tooling/python"),
            collections=Path("/private/tooling/collections"),
        )
        events = []

        def validate(_config, validated_sha):
            events.append(("validate", validated_sha))
            if (checkout / "site.yml").read_text(encoding="utf-8") != "---\n":
                raise production_auto_deploy.DeploymentError("checkout changed")

        def run(arguments, **_kwargs):
            play = next(
                item
                for item in arguments
                if item.endswith(".yml") and not item.startswith("@")
            )
            events.append(("play", play))
            (checkout / "site.yml").write_text("mutated\n", encoding="utf-8")
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        with mock.patch.object(
            production_auto_deploy,
            "prepare_checkout",
            return_value=checkout,
        ), mock.patch.object(
            production_auto_deploy,
            "prepare_tooling",
            return_value=tooling,
        ), mock.patch.object(
            production_auto_deploy,
            "_validate_materialized_checkout",
            side_effect=validate,
            create=True,
        ), mock.patch.object(
            production_auto_deploy,
            "_validate_tooling_for_execution",
            create=True,
        ), mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=run,
        ):
            succeeded = production_auto_deploy.deploy_candidate(
                self.loaded_config(), MAIN_SHA, io.BytesIO()
            )

        self.assertFalse(succeeded)
        self.assertEqual(
            events,
            [
                ("validate", MAIN_SHA),
                ("validate", MAIN_SHA),
                ("play", "validate-vault.yml"),
                ("validate", MAIN_SHA),
            ],
        )

    def test_automatic_installer_receives_a_bounded_lock_proof_without_deadlock(self):
        checkout = self.seed_candidate_files()
        tooling = production_auto_deploy.Tooling(
            ansible_playbook=Path("/private/tooling/ansible-playbook"),
            python=Path("/private/tooling/python"),
            collections=Path("/private/tooling/collections"),
        )
        proof_path = None

        def run(arguments, **_kwargs):
            nonlocal proof_path
            if "install-production-auto-deploy.yml" in arguments:
                proof_arguments = [
                    argument[1:]
                    for argument in arguments
                    if argument.startswith("@") and "lock-proof" in argument
                ]
                self.assertEqual(len(proof_arguments), 1)
                proof_path = Path(proof_arguments[0])
                self.assertEqual(stat.S_IMODE(proof_path.stat().st_mode), 0o600)
                payload = json.loads(proof_path.read_text(encoding="utf-8"))
                self.assertEqual(
                    set(payload),
                    {
                        "production_auto_deploy_lock_proof",
                        "production_auto_deploy_lock_pid",
                        "production_auto_deploy_lock_proof_path",
                    },
                )
                self.assertRegex(payload["production_auto_deploy_lock_proof"], r"^[0-9a-f]{64}$")
                self.assertEqual(payload["production_auto_deploy_lock_pid"], os.getpid())
                self.assertEqual(
                    payload["production_auto_deploy_lock_proof_path"],
                    str(proof_path),
                )
                self.assertEqual(proof_path.parent, self.private_root)
                self.assertRegex(
                    proof_path.name,
                    r"^\.production-auto-deploy-lock-proof-[0-9a-f]{64}\.json$",
                )
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        with mock.patch.object(
            production_auto_deploy,
            "prepare_checkout",
            return_value=checkout,
        ), mock.patch.object(
            production_auto_deploy,
            "prepare_tooling",
            return_value=tooling,
        ), mock.patch.object(
            production_auto_deploy,
            "_validate_materialized_checkout",
        ), mock.patch.object(
            production_auto_deploy,
            "_validate_tooling_for_execution",
        ), mock.patch.object(
            production_auto_deploy,
            "_active_deployment_lock_held",
            return_value=True,
            create=True,
        ), mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=run,
        ):
            succeeded = production_auto_deploy.deploy_candidate(
                self.loaded_config(), MAIN_SHA, io.BytesIO()
            )

        self.assertTrue(succeeded)
        self.assertIsNotNone(proof_path)
        self.assertFalse(proof_path.exists())

    def test_sigkill_stale_installer_proof_does_not_block_or_authorize_a_new_proof(self):
        child_source = (
            "import os, pathlib, pwd, signal, sys, types\n"
            f"sys.path.insert(0, {str(SCRIPT.parent)!r})\n"
            "import production_auto_deploy as module\n"
            f"home = pathlib.Path({str(self.root)!r})\n"
            "module.pwd.getpwuid = lambda _uid: types.SimpleNamespace(pw_dir=str(home))\n"
            f"config = module.load_config({str(self.config_path)!r})\n"
            "module._ACTIVE_DEPLOYMENT_LOCK.held = True\n"
            "with module._automatic_installer_lock_proof(config) as proof:\n"
            "    print(proof, flush=True)\n"
            "    os.kill(os.getpid(), signal.SIGKILL)\n"
        )
        child = subprocess.run(
            [sys.executable, "-c", child_source],
            capture_output=True,
            check=False,
            text=True,
            timeout=3.0,
        )
        self.assertEqual(child.returncode, -signal.SIGKILL)
        stale = Path(child.stdout.strip())
        self.assertTrue(stale.is_file())
        stale_payload = json.loads(stale.read_text(encoding="utf-8"))

        previous = getattr(production_auto_deploy._ACTIVE_DEPLOYMENT_LOCK, "held", False)
        production_auto_deploy._ACTIVE_DEPLOYMENT_LOCK.held = True
        try:
            with production_auto_deploy._automatic_installer_lock_proof(
                self.loaded_config()
            ) as current:
                self.assertNotEqual(current, stale)
                current_payload = json.loads(current.read_text(encoding="utf-8"))
                self.assertNotEqual(
                    current_payload["production_auto_deploy_lock_proof"],
                    stale_payload["production_auto_deploy_lock_proof"],
                )
        finally:
            production_auto_deploy._ACTIVE_DEPLOYMENT_LOCK.held = previous
            stale.unlink(missing_ok=True)

        self.assertFalse(stale.exists())

    def test_default_poll_callback_deploys_candidate_and_preserves_journal_policy(self):
        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "deploy_candidate",
            return_value=True,
        ) as deploy:
            result = production_auto_deploy.poll(self.loaded_config())

        self.assertTrue(result)
        deploy.assert_called_once()
        self.assertEqual(deploy.call_args.args[:2], (self.loaded_config(), MAIN_SHA))
        successful = production_auto_deploy.read_sha_state(
            self.state_path("last-successful")
        )
        self.assertEqual((successful.sha, successful.outcome), (MAIN_SHA, "success"))

    def test_poll_rejects_invalid_controller_python_before_resolving_candidate(self):
        before = self.state_snapshot()
        with mock.patch.object(
            production_auto_deploy,
            "_validate_controller_python",
            side_effect=production_auto_deploy.DeploymentError(
                "controller Python 3.12 or newer is required"
            ),
        ), mock.patch.object(
            production_auto_deploy,
            "resolve_main_sha",
            return_value=MAIN_SHA,
        ) as resolve, self.assertRaises(
            production_auto_deploy.DeploymentError
        ):
            production_auto_deploy.poll(self.loaded_config())

        resolve.assert_not_called()
        self.assertEqual(self.state_snapshot(), before)

    def test_command_runner_terminates_process_group_on_sigterm(self):
        orphan_marker = self.root / "orphaned-command"
        entered_marker = self.root / "command-entered"
        command_source = (
            "import pathlib, subprocess, sys, time\n"
            f"pathlib.Path({str(entered_marker)!r}).write_text('entered')\n"
            "subprocess.Popen([sys.executable, '-c', "
            f"\"import pathlib,time; time.sleep(0.8); pathlib.Path({str(orphan_marker)!r}).write_text('orphaned')\""
            "])\n"
            "time.sleep(10)\n"
        )
        runner_source = (
            "import pathlib, sys\n"
            f"sys.path.insert(0, {str(SCRIPT.parent)!r})\n"
            "import production_auto_deploy as module\n"
            f"module._run_command([sys.executable, '-c', {command_source!r}], "
            f"cwd=pathlib.Path({str(self.root)!r}), "
            "env={'PATH': '/usr/bin:/bin', 'LANG': 'C', 'LC_ALL': 'C', "
            f"'HOME': {str(self.root)!r}}}, timeout=10)\n"
        )
        runner = subprocess.Popen(
            [sys.executable, "-c", runner_source],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 2
        while not entered_marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        if not entered_marker.exists():
            runner.terminate()
            _stdout, stderr = runner.communicate(timeout=3)
            self.fail(f"command runner did not start: {stderr}")

        runner.terminate()
        runner.communicate(timeout=3)
        time.sleep(1)

        self.assertFalse(orphan_marker.exists())

    def test_command_signal_during_pipe_setup_cleans_child(self):
        orphan_marker = self.root / "pipe-setup-signal-orphan"
        child_source = (
            "import pathlib,time\n"
            "time.sleep(.5)\n"
            f"pathlib.Path({str(orphan_marker)!r}).write_text('orphaned')\n"
        )
        runner_source = (
            "import os,pathlib,signal,sys\n"
            f"sys.path.insert(0,{str(SCRIPT.parent)!r})\n"
            "import production_auto_deploy as module\n"
            "real_set_blocking=module.os.set_blocking\n"
            "def interrupt(descriptor,blocking):\n"
            " os.kill(os.getpid(),signal.SIGTERM)\n"
            " real_set_blocking(descriptor,blocking)\n"
            "module.os.set_blocking=interrupt\n"
            f"module._run_command([sys.executable,'-c',{child_source!r}],"
            f"cwd=pathlib.Path({str(self.root)!r}),"
            "env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C',"
            f"'HOME':{str(self.root)!r}}},timeout=2)\n"
        )

        subprocess.run(
            [sys.executable, "-c", runner_source],
            capture_output=True,
            check=False,
            timeout=3,
        )
        time.sleep(0.7)

        self.assertFalse(orphan_marker.exists())

    def test_command_timeout_kills_descendant_after_group_leader_exits(self):
        orphan_marker = self.root / "orphaned-after-timeout"
        command_source = (
            "import subprocess, sys\n"
            "subprocess.Popen([sys.executable, '-c', "
            f"\"import pathlib,time; time.sleep(0.8); pathlib.Path({str(orphan_marker)!r}).write_text('orphaned')\""
            "])\n"
        )

        with self.assertRaises(production_auto_deploy.DeploymentError):
            production_auto_deploy._run_command(
                [sys.executable, "-c", command_source],
                cwd=self.root,
                env={
                    "PATH": "/usr/bin:/bin",
                    "LANG": "C",
                    "LC_ALL": "C",
                    "HOME": str(self.root),
                },
                timeout=0.1,
            )
        time.sleep(1)

        self.assertFalse(orphan_marker.exists())

    def test_command_timeout_kills_term_resistant_descendant_with_closed_stdio(self):
        orphan_marker = self.root / "term-resistant-orphan"
        descendant_pid = self.root / "term-resistant-pid"
        child_source = (
            "import os,pathlib,signal,time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "os.close(1); os.close(2)\n"
            f"pathlib.Path({str(descendant_pid)!r}).write_text(str(os.getpid()))\n"
            "time.sleep(0.8)\n"
            f"pathlib.Path({str(orphan_marker)!r}).write_text('orphaned')\n"
        )
        leader_source = (
            "import pathlib,subprocess,sys,time\n"
            f"subprocess.Popen([sys.executable, '-c', {child_source!r}])\n"
            f"pid_path=pathlib.Path({str(descendant_pid)!r})\n"
            "deadline=time.monotonic()+2\n"
            "while not pid_path.exists() and time.monotonic()<deadline: time.sleep(0.01)\n"
            "time.sleep(10)\n"
        )

        with self.assertRaisesRegex(
            production_auto_deploy.DeploymentError,
            "deployment command timed out",
        ):
            production_auto_deploy._run_command(
                [sys.executable, "-c", leader_source],
                cwd=self.root,
                env={
                    "PATH": "/usr/bin:/bin",
                    "LANG": "C",
                    "LC_ALL": "C",
                    "HOME": str(self.root),
                },
                timeout=0.3,
            )
        time.sleep(1)

        self.assertTrue(descendant_pid.exists())
        self.assertFalse(orphan_marker.exists())
        pid = int(descendant_pid.read_text(encoding="utf-8"))
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_command_rejects_live_descendant_after_successful_leader_exit(self):
        orphan_marker = self.root / "successful-leader-orphan"
        descendant_pid = self.root / "successful-leader-pid"
        child_source = (
            "import os,pathlib,signal,time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "os.close(1); os.close(2)\n"
            f"pathlib.Path({str(descendant_pid)!r}).write_text(str(os.getpid()))\n"
            "time.sleep(0.8)\n"
            f"pathlib.Path({str(orphan_marker)!r}).write_text('orphaned')\n"
        )
        leader_source = (
            "import pathlib,subprocess,sys,time\n"
            f"subprocess.Popen([sys.executable, '-c', {child_source!r}])\n"
            f"pid_path=pathlib.Path({str(descendant_pid)!r})\n"
            "deadline=time.monotonic()+2\n"
            "while not pid_path.exists() and time.monotonic()<deadline: time.sleep(0.01)\n"
        )

        with self.assertRaisesRegex(
            production_auto_deploy.DeploymentError,
            "deployment command left background processes",
        ):
            production_auto_deploy._run_command(
                [sys.executable, "-c", leader_source],
                cwd=self.root,
                env={
                    "PATH": "/usr/bin:/bin",
                    "LANG": "C",
                    "LC_ALL": "C",
                    "HOME": str(self.root),
                },
                timeout=2,
            )
        time.sleep(1)

        self.assertTrue(descendant_pid.exists())
        self.assertFalse(orphan_marker.exists())
        pid = int(descendant_pid.read_text(encoding="utf-8"))
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux /proc")
    def test_command_timeout_kills_descendant_that_escapes_with_setsid(self):
        orphan_marker = self.root / "setsid-orphan"
        descendant_pid = self.root / "setsid-pid"
        child_source = (
            "import os,pathlib,signal,time\n"
            "os.setsid()\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "os.close(1); os.close(2)\n"
            f"pathlib.Path({str(descendant_pid)!r}).write_text(str(os.getpid()))\n"
            "time.sleep(0.8)\n"
            f"pathlib.Path({str(orphan_marker)!r}).write_text('orphaned')\n"
        )
        leader_source = (
            "import pathlib,subprocess,sys,time\n"
            f"subprocess.Popen([sys.executable, '-c', {child_source!r}])\n"
            f"pid_path=pathlib.Path({str(descendant_pid)!r})\n"
            "deadline=time.monotonic()+2\n"
            "while not pid_path.exists() and time.monotonic()<deadline: time.sleep(0.01)\n"
            "time.sleep(10)\n"
        )

        with self.assertRaisesRegex(
            production_auto_deploy.DeploymentError,
            "deployment command timed out",
        ):
            production_auto_deploy._run_command(
                [sys.executable, "-c", leader_source],
                cwd=self.root,
                env={
                    "PATH": "/usr/bin:/bin",
                    "LANG": "C",
                    "LC_ALL": "C",
                    "HOME": str(self.root),
                },
                timeout=0.3,
            )
        time.sleep(1)

        self.assertFalse(orphan_marker.exists())
        pid = int(descendant_pid.read_text(encoding="utf-8"))
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_command_streams_only_bounded_output_to_attempt_sink(self):
        sink = io.BytesIO()
        source = (
            "import os\n"
            f"chunk=b'x'*{production_auto_deploy.HTTP_READ_SIZE}\n"
            f"remaining={production_auto_deploy.MAX_RESPONSE_BYTES + production_auto_deploy.HTTP_READ_SIZE}\n"
            "while remaining:\n"
            " size=min(len(chunk),remaining); os.write(1,chunk[:size]); remaining-=size\n"
        )

        with self.assertRaisesRegex(
            production_auto_deploy.DeploymentError,
            "deployment command output is too large",
        ):
            production_auto_deploy._run_command(
                [sys.executable, "-c", source],
                cwd=self.root,
                env={
                    "PATH": "/usr/bin:/bin",
                    "LANG": "C",
                    "LC_ALL": "C",
                    "HOME": str(self.root),
                },
                timeout=5,
                log=sink,
            )

        self.assertLessEqual(
            len(sink.getvalue()), production_auto_deploy.MAX_RESPONSE_BYTES
        )

    def test_command_streams_large_input_and_output_without_deadlock(self):
        child_pid = self.root / "duplex-command-pid"
        transfer_size = 256 * 1024
        child_source = (
            "import os,pathlib,sys\n"
            f"pathlib.Path({str(child_pid)!r}).write_text(str(os.getpid()))\n"
            f"remaining={transfer_size}\n"
            "chunk=b'o'*65536\n"
            "while remaining:\n"
            " size=min(len(chunk),remaining); os.write(1,chunk[:size]); remaining-=size\n"
            "received=sys.stdin.buffer.read()\n"
            f"raise SystemExit(0 if len(received)=={transfer_size} else 71)\n"
        )
        runner_source = (
            "import os,pathlib,signal,sys,time\n"
            f"sys.path.insert(0,{str(SCRIPT.parent)!r})\n"
            "import production_auto_deploy as module\n"
            "def alarm(_signal,_frame): raise TimeoutError('outer deadline')\n"
            "signal.signal(signal.SIGALRM,alarm)\n"
            "signal.setitimer(signal.ITIMER_REAL,2)\n"
            "succeeded=False\n"
            "try:\n"
            f" result=module._run_command([sys.executable,'-c',{child_source!r}],"
            f"cwd=pathlib.Path({str(self.root)!r}),"
            "env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C',"
            f"'HOME':{str(self.root)!r}}},timeout=1,stdin_data=b'i'*{transfer_size})\n"
            " succeeded=result.returncode==0 and len(result.stdout)=="
            f"{transfer_size} and len(result.stdout)<=module.MAX_RESPONSE_BYTES\n"
            "except Exception:\n"
            " pass\n"
            "finally:\n"
            " signal.setitimer(signal.ITIMER_REAL,0)\n"
            "time.sleep(.2)\n"
            f"pid=int(pathlib.Path({str(child_pid)!r}).read_text())\n"
            "try:\n"
            " os.kill(pid,0)\n"
            " alive=True\n"
            "except ProcessLookupError:\n"
            " alive=False\n"
            "raise SystemExit(0 if succeeded and not alive else 9)\n"
        )

        result = subprocess.run(
            [sys.executable, "-c", runner_source],
            capture_output=True,
            check=False,
            timeout=5,
        )

        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_command_runner_passes_only_requested_private_descriptor(self):
        with tempfile.TemporaryFile(mode="w+b") as snapshot:
            snapshot.write(b"snapshot")
            snapshot.flush()
            snapshot.seek(0)
            descriptor = snapshot.fileno()

            result = production_auto_deploy._run_command(
                [
                    sys.executable,
                    "-c",
                    f"import os; os.write(1, os.read({descriptor}, 8))",
                ],
                cwd=self.root,
                env={
                    "PATH": "/usr/bin:/bin",
                    "LANG": "C",
                    "LC_ALL": "C",
                    "HOME": str(self.root),
                },
                timeout=5,
                pass_fds=(descriptor,),
            )

        self.assertEqual(result.stdout, b"snapshot")

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux /proc")
    def test_git_timeout_kills_setsid_descendant(self):
        orphan_marker = self.root / "git-setsid-orphan"
        fake_git = self.fake_bin / "git"
        child_source = (
            "import os,pathlib,signal,time; os.setsid(); "
            "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
            "os.close(1); os.close(2); time.sleep(.8); "
            f"pathlib.Path({str(orphan_marker)!r}).write_text('orphaned')"
        )
        fake_git.write_text(
            f"#!{sys.executable}\n"
            "import os,subprocess,sys,time\n"
            f"child={child_source!r}\n"
            "subprocess.Popen([sys.executable,'-c',child])\n"
            "time.sleep(10)\n",
            encoding="utf-8",
        )
        fake_git.chmod(0o700)

        with mock.patch.object(
            production_auto_deploy,
            "GIT_TIMEOUT_SECONDS",
            0.3,
        ), self.assertRaises(production_auto_deploy.EligibilityError):
            production_auto_deploy.resolve_main_sha(self.loaded_config())
        time.sleep(1)

        self.assertFalse(orphan_marker.exists())

    def test_attempt_log_is_private_exact_and_updates_regular_latest_file(self):
        config = self.loaded_config()

        with production_auto_deploy.attempt_log(config, MAIN_SHA) as log:
            log_path = Path(log.name)
            log.write(b"deployment output\n")

        self.assertRegex(
            log_path.name,
            rf"^attempt-\d{{8}}T\d{{12}}Z-{MAIN_SHA}\.log$",
        )
        self.assertEqual(stat.S_IMODE(log_path.stat().st_mode), 0o600)
        latest = self.private_root / "logs" / "latest"
        self.assertFalse(latest.is_symlink())
        self.assertTrue(latest.is_file())
        self.assertEqual(stat.S_IMODE(latest.stat().st_mode), 0o600)
        self.assertEqual(latest.read_text(encoding="utf-8"), log_path.name + "\n")

    def test_attempt_log_names_are_unique_within_the_same_second(self):
        moments = iter(
            (
                datetime.datetime(
                    2026,
                    8,
                    14,
                    12,
                    0,
                    0,
                    100001,
                    tzinfo=datetime.timezone.utc,
                ),
                datetime.datetime(
                    2026,
                    8,
                    14,
                    12,
                    0,
                    0,
                    100001,
                    tzinfo=datetime.timezone.utc,
                ),
            )
        )

        class AttemptDatetime(datetime.datetime):
            @classmethod
            def now(cls, tz=None):
                return next(moments)

        paths = []
        with mock.patch.object(production_auto_deploy, "datetime", AttemptDatetime):
            for _attempt in range(2):
                try:
                    with production_auto_deploy.attempt_log(
                        self.loaded_config(),
                        MAIN_SHA,
                    ) as log:
                        paths.append(Path(log.name))
                except production_auto_deploy.StateError:
                    break

        self.assertEqual(len(paths), 2)
        self.assertNotEqual(paths[0], paths[1])
        for path in paths:
            self.assertRegex(
                path.name,
                rf"^attempt-\d{{8}}T\d{{12}}Z-{MAIN_SHA}\.log$",
            )
            self.assertTrue(path.is_file())

    def test_attempt_log_rejects_hostile_latest_before_entering_context(self):
        latest = self.private_root / "logs" / "latest"
        external = self.root / "external-latest"
        external.write_text("external unchanged\n", encoding="utf-8")
        latest.symlink_to(external)
        entered = False

        with self.assertRaises(production_auto_deploy.StateError):
            with production_auto_deploy.attempt_log(
                self.loaded_config(),
                MAIN_SHA,
            ):
                entered = True

        self.assertFalse(entered)
        self.assertTrue(latest.is_symlink())
        self.assertEqual(external.read_text(encoding="utf-8"), "external unchanged\n")
        self.assertEqual(
            [path.name for path in (self.private_root / "logs").iterdir()],
            ["latest"],
        )

    def test_attempt_log_redacts_known_values_split_across_chunks(self):
        password = "PASSWORD_PROVIDER_SENTINEL_7654321"
        token = "NTFY_TOKEN_SENTINEL_3141592"
        password_file = Path(self.config["vault_password_file"])
        password_file.write_text(password + "\n", encoding="utf-8")
        ntfy_config = Path(self.config["ntfy_curl_config"])
        ntfy_config.write_text(
            f'header = "Authorization: Bearer {token}"\n',
            encoding="utf-8",
        )
        config = self.loaded_config()

        with production_auto_deploy.attempt_log(config, MAIN_SHA) as log:
            log_path = Path(log.name)
            split = len(password) // 2
            log.write(("before " + password[:split]).encode())
            log.write(
                (
                    password[split:]
                    + " after\nAuthorization: Bearer "
                    + token
                    + "\n"
                    + str(config.vault_file)
                    + "\n"
                ).encode()
            )

        body = log_path.read_bytes()
        self.assertNotIn(password.encode(), body)
        self.assertNotIn(token.encode(), body)
        self.assertNotIn(str(config.vault_file).encode(), body)
        self.assertIn(b"[REDACTED]", body)

    def test_attempt_log_redacts_encrypted_vault_bytes_split_across_chunks(self):
        vault_sentinel = b"ENCRYPTED_VAULT_SENTINEL_8675309"
        vault_file = Path(self.config["vault_file"])
        vault_file.write_bytes(
            b"$ANSIBLE_VAULT;1.1;AES256\n"
            b"616263646566\n"
            + vault_sentinel
            + b"\n"
        )

        with production_auto_deploy.attempt_log(
            self.loaded_config(),
            MAIN_SHA,
        ) as log:
            log_path = Path(log.name)
            split = len(vault_sentinel) // 2
            log.write(vault_sentinel[:split])
            log.write(vault_sentinel[split:] + b"\n")

        body = log_path.read_bytes()
        self.assertNotIn(vault_sentinel, body)
        self.assertEqual(body, b"[REDACTED]\n")

    def test_protected_file_read_rejects_same_inode_rewrite(self):
        vault_file = Path(self.config["vault_file"])
        old_payload = b"A" * 32000 + b"OLD_VAULT_TAIL"
        new_payload = b"B" * 32000 + b"NEW_VAULT_TAIL"
        vault_file.write_bytes(old_payload)
        vault_file.chmod(0o600)
        real_read = os.read
        reads = 0

        def rewrite_after_first_chunk(descriptor, size):
            nonlocal reads
            chunk = real_read(descriptor, min(size, 8192))
            reads += 1
            if reads == 1:
                vault_file.write_bytes(new_payload)
                vault_file.chmod(0o600)
            return chunk

        with mock.patch.object(
            production_auto_deploy.os,
            "read",
            side_effect=rewrite_after_first_chunk,
        ), self.assertRaisesRegex(
            production_auto_deploy.StateError,
            "protected file is unsafe",
        ):
            production_auto_deploy._read_protected_bytes(vault_file)

    def test_attempt_log_redacts_all_valid_curl_config_value_separators(self):
        sentinels = (
            "OAUTH_EQUALS_SENTINEL_1001",
            "OAUTH_COLON_SENTINEL_1002",
            "OAUTH_SPACE_SENTINEL_1003",
            "USER_EQUALS_SENTINEL_2001",
            "USER_COLON_SENTINEL_2002",
            "USER_SPACE_SENTINEL_2003",
        )
        ntfy_config = Path(self.config["ntfy_curl_config"])
        ntfy_config.write_text(
            "\n".join(
                (
                    f'oauth2-bearer = "{sentinels[0]}"',
                    f'oauth2-bearer: "{sentinels[1]}"',
                    f'oauth2-bearer "{sentinels[2]}"',
                    f'user = "publisher:{sentinels[3]}"',
                    f'user: "publisher:{sentinels[4]}"',
                    f'user "publisher:{sentinels[5]}"',
                )
            )
            + "\n",
            encoding="utf-8",
        )

        with production_auto_deploy.attempt_log(
            self.loaded_config(),
            MAIN_SHA,
        ) as log:
            log_path = Path(log.name)
            for sentinel in sentinels:
                split = len(sentinel) // 2
                log.write(sentinel[:split].encode())
                log.write((sentinel[split:] + "\n").encode())

        body = log_path.read_bytes()
        for sentinel in sentinels:
            self.assertNotIn(sentinel.encode(), body)
        self.assertEqual(body.count(b"[REDACTED]"), len(sentinels))

    def test_attempt_log_redacts_curl_decoded_quoted_config_values(self):
        self.assertIn(
            b'A\\B"C\tD\nE\rF\vG',
            production_auto_deploy._curl_config_value_variants(
                b'"A\\\\B\\"C\\tD\\nE\\rF\\vG"'
            ),
        )
        oauth_value = b"OAUTH\\ESCAPED_SENTINEL_3001"
        user_value = b'USER"ESCAPED_SENTINEL_3002'
        ntfy_config = Path(self.config["ntfy_curl_config"])
        ntfy_config.write_bytes(
            b'oauth2-bearer = "OAUTH\\\\ESCAPED_SENTINEL_3001"\n'
            b'user = "publisher:USER\\"ESCAPED_SENTINEL_3002"\n'
        )

        with production_auto_deploy.attempt_log(
            self.loaded_config(),
            MAIN_SHA,
        ) as log:
            log_path = Path(log.name)
            for value in (oauth_value, user_value):
                split = len(value) // 2
                log.write(value[:split])
                log.write(value[split:] + b"\n")

        body = log_path.read_bytes()
        self.assertNotIn(oauth_value, body)
        self.assertNotIn(user_value, body)
        self.assertEqual(body.count(b"[REDACTED]"), 2)

    def test_attempt_log_redacts_short_user_password_component(self):
        ntfy_config = Path(self.config["ntfy_curl_config"])
        ntfy_config.write_bytes(b'user: "u:p"\n')

        with production_auto_deploy.attempt_log(
            self.loaded_config(),
            MAIN_SHA,
        ) as log:
            log_path = Path(log.name)
            log.write(b"p")
            log.write(b"\n")

        body = log_path.read_bytes()
        self.assertNotIn(b"p", body)
        self.assertEqual(body, b"[REDACTED]\n")

    def test_attempt_log_redacts_short_dashed_curl_credential_values(self):
        ntfy_config = Path(self.config["ntfy_curl_config"])
        ntfy_config.write_bytes(
            b'--user "u:p"\n'
            b'-u "x:q"\n'
            b'--oauth2-bearer "r"\n'
        )

        with production_auto_deploy.attempt_log(
            self.loaded_config(),
            MAIN_SHA,
        ) as log:
            log_path = Path(log.name)
            for value in (b"p", b"q", b"r"):
                log.write(value)
                log.write(b"\n")

        body = log_path.read_bytes()
        for value in (b"p", b"q", b"r"):
            self.assertNotIn(value, body)
        self.assertEqual(body.count(b"[REDACTED]"), 3)

    def test_attempt_log_redacts_unknown_authorization_across_chunk_boundaries(self):
        secret = b"UNKNOWN_AUTHORIZATION_SENTINEL_" + (
            b"s" * (production_auto_deploy.PROTECTED_VALUE_MAX_BYTES + 100)
        )

        with production_auto_deploy.attempt_log(
            self.loaded_config(),
            MAIN_SHA,
        ) as log:
            log_path = Path(log.name)
            log.write(b"prefix\nAuthor")
            log.write(b"ization: Bearer " + secret)
            log.write(b"\nsuffix\n")

        body = log_path.read_bytes()
        self.assertNotIn(secret, body)
        self.assertNotIn(b"s" * 50, body)
        self.assertNotIn(b"Bearer", body)
        self.assertIn(b"Authorization: [REDACTED]", body)

    def test_attempt_log_redacts_folded_authorization_continuations(self):
        bearer_secret = b"FOLDED_BEARER_SENTINEL_4101"
        basic_secret = b"FOLDED_BASIC_SENTINEL_4102"
        response_secret = b"FOLDED_RESPONSE_SENTINEL_4103"
        trace_secret = b"FOLDED_TRACE_SENTINEL_4104"
        payload = (
            b"Authorization:\r\n  Bearer "
            + bearer_secret
            + b"\r\nsafe\n> Authorization:\n> \tBasic "
            + basic_secret
            + b"\n< Authorization:\r\n<   Bearer "
            + response_secret
            + b"\r\n* Authorization:\n*  Other "
            + trace_secret
            + b"\nend\n"
        )

        with production_auto_deploy.attempt_log(
            self.loaded_config(),
            MAIN_SHA,
        ) as log:
            log_path = Path(log.name)
            for start in range(0, len(payload), 3):
                log.write(payload[start : start + 3])

        body = log_path.read_bytes()
        self.assertNotIn(bearer_secret, body)
        self.assertNotIn(basic_secret, body)
        self.assertNotIn(response_secret, body)
        self.assertNotIn(trace_secret, body)
        self.assertNotIn(b"Bearer", body)
        self.assertNotIn(b"Basic", body)
        self.assertIn(b"safe\n", body)
        self.assertIn(b"end\n", body)

    def test_attempt_log_bounds_long_folded_authorization_continuation(self):
        secret = b"S" * (production_auto_deploy.PROTECTED_VALUE_MAX_BYTES * 2)
        payload = b"Authorization:\n  Bearer " + secret + b"\nend\n"

        with production_auto_deploy.attempt_log(
            self.loaded_config(),
            MAIN_SHA,
        ) as log:
            log_path = Path(log.name)
            for start in range(0, len(payload), 4096):
                log.write(payload[start : start + 4096])

        body = log_path.read_bytes()
        self.assertNotIn(b"S" * 50, body)
        self.assertNotIn(b"Bearer", body)
        self.assertLess(len(body), 256)
        self.assertIn(b"end\n", body)

    def test_redactor_consumes_maximum_sized_known_value_without_spinning(self):
        source = (
            "import io,pathlib,sys\n"
            f"sys.path.insert(0,{str(SCRIPT.parent)!r})\n"
            "import production_auto_deploy as module\n"
            "secret=b'x'*module.PROTECTED_VALUE_MAX_BYTES\n"
            "output=io.BytesIO()\n"
            "sink=module._RedactingLog(output,pathlib.Path('/tmp/log'),(secret,))\n"
            "sink.write(secret+b'y')\n"
            "sink.finish()\n"
            "assert secret not in output.getvalue()\n"
        )

        result = subprocess.run(
            [sys.executable, "-c", source],
            capture_output=True,
            check=False,
            timeout=1,
        )

        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_redactor_handles_protected_value_overlapping_authorization_name(self):
        output = io.BytesIO()
        sink = production_auto_deploy._RedactingLog(
            output,
            Path("/tmp/log"),
            (b"Auth",),
        )

        sink.write(b"Authorization: Bearer UNKNOWN_SECRET\n")
        sink.finish()

        body = output.getvalue()
        self.assertNotIn(b"UNKNOWN_SECRET", body)
        self.assertNotIn(b"Bearer", body)
        self.assertIn(b"[REDACTED]", body)

    def test_rotate_logs_enforces_count_and_age_without_touching_unsafe_entries(self):
        config = self.loaded_config()
        log_root = Path(config.log_root)
        now = datetime.datetime(2026, 8, 14, 12, 0, tzinfo=datetime.timezone.utc)
        names = []
        for offset in range(22):
            timestamp = now - datetime.timedelta(days=offset)
            name = (
                "attempt-"
                + timestamp.strftime("%Y%m%dT%H%M%SZ")
                + f"-{offset:040x}.log"
            )
            path = log_root / name
            path.write_bytes(str(offset).encode())
            path.chmod(0o600)
            names.append(name)
        old_name = f"attempt-20260701T120000Z-{'f' * 40}.log"
        old_path = log_root / old_name
        old_path.write_text("old\n", encoding="utf-8")
        old_path.chmod(0o600)
        external = self.root / "external-log"
        external.write_text("external unchanged\n", encoding="utf-8")
        symlink = log_root / f"attempt-20200101T000000Z-{'e' * 40}.log"
        symlink.symlink_to(external)
        unmatched = log_root / "attempt-not-a-log"
        unmatched.write_text("unchanged\n", encoding="utf-8")

        production_auto_deploy.rotate_logs(config, now)

        retained = sorted(
            path.name
            for path in log_root.glob("*.log")
            if not path.is_symlink()
        )
        self.assertEqual(retained, sorted(names[:20]))
        self.assertTrue(symlink.is_symlink())
        self.assertEqual(external.read_text(encoding="utf-8"), "external unchanged\n")
        self.assertEqual(unmatched.read_text(encoding="utf-8"), "unchanged\n")

    def test_notify_uses_exact_curl_argv_and_secret_free_json_stdin(self):
        config = self.loaded_config()
        token = "NOTIFICATION_TOKEN_SENTINEL_2718281"
        config.ntfy_curl_config.write_text(
            f'header = "Authorization: Bearer {token}"\n',
            encoding="utf-8",
        )
        log_path = config.log_root / (
            f"attempt-20260814T120000Z-{MAIN_SHA}.log"
        )
        log_path.write_text("safe\n", encoding="utf-8")
        log_path.chmod(0o600)
        calls = []
        snapshot = {}

        def run(arguments, **kwargs):
            calls.append((list(arguments), kwargs))
            descriptor = kwargs["pass_fds"][0]
            snapshot["descriptor"] = descriptor
            snapshot["payload"] = os.pread(
                descriptor,
                production_auto_deploy.PROTECTED_VALUE_MAX_BYTES,
                0,
            )
            snapshot["stat"] = os.fstat(descriptor)
            with self.assertRaises(OSError):
                os.write(descriptor, b"changed")
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        with mock.patch.object(
            production_auto_deploy,
            "SYSTEM_CURL_PATH",
            self.fake_bin / "curl",
        ), mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=run,
        ):
            delivered = production_auto_deploy.notify(
                config,
                "success",
                MAIN_SHA,
                "2026-08-14T12:00:00Z",
                "2026-08-14T12:01:00Z",
                log_path,
            )

        self.assertTrue(delivered)
        self.assertEqual(
            calls[0][0],
            [
                str(self.fake_bin / "curl"),
                "--disable",
                "--fail",
                "--silent",
                "--show-error",
                "--max-time",
                "10",
                "--config",
                f"/dev/fd/{snapshot['descriptor']}",
                "--data-binary",
                "@-",
            ],
        )
        self.assertEqual(
            snapshot["payload"],
            config.ntfy_curl_config.read_bytes(),
        )
        self.assertEqual(snapshot["stat"].st_nlink, 0)
        self.assertEqual(calls[0][1]["pass_fds"], (snapshot["descriptor"],))
        with self.assertRaises(OSError):
            os.fstat(snapshot["descriptor"])
        self.assertEqual(
            list(config.ntfy_curl_config.parent.glob(".notification-config-*")),
            [],
        )
        self.assertEqual(
            json.loads(calls[0][1]["stdin_data"]),
            {
                "outcome": "success",
                "sha": MAIN_SHA,
                "started": "2026-08-14T12:00:00Z",
                "finished": "2026-08-14T12:01:00Z",
                "log_path": str(log_path),
            },
        )
        self.assertNotIn(token, " ".join(calls[0][0]))
        self.assertNotIn(token.encode(), calls[0][1]["stdin_data"])

    def test_notify_disables_hostile_ambient_home_curl_config(self):
        config = self.loaded_config()
        log_path = config.log_root / (
            f"attempt-20260814T120000Z-{MAIN_SHA}.log"
        )
        log_path.write_text("safe\n", encoding="utf-8")
        log_path.chmod(0o600)
        ambient_sentinel = "AMBIENT_CURL_SENTINEL_9090"
        (self.root / ".curlrc").write_text(ambient_sentinel, encoding="utf-8")
        self.install_fake(
            "curl",
            f"#!{sys.executable}\n"
            "import os,pathlib,sys\n"
            "if sys.argv[1:2] != ['--disable']:\n"
            "    print((pathlib.Path(os.environ['HOME'])/'.curlrc').read_text())\n"
            "    raise SystemExit(73)\n"
            "sys.stdin.buffer.read()\n",
        )
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr):
            delivered = production_auto_deploy.notify(
                config,
                "success",
                MAIN_SHA,
                "2026-08-14T12:00:00Z",
                "2026-08-14T12:01:00Z",
                log_path,
            )

        self.assertTrue(delivered)
        self.assertEqual(stderr.getvalue(), "")
        self.assertNotIn(ambient_sentinel, stderr.getvalue())

    def test_notify_uses_snapshot_when_original_config_is_replaced_during_run(self):
        config = self.loaded_config()
        token = "SNAPSHOT_TOKEN_SENTINEL_8181"
        original_payload = f'oauth2-bearer "{token}"\n'.encode()
        config.ntfy_curl_config.write_bytes(original_payload)
        log_path = config.log_root / (
            f"attempt-20260814T120000Z-{MAIN_SHA}.log"
        )
        log_path.write_text("safe\n", encoding="utf-8")
        log_path.chmod(0o600)
        observed = {}

        def replace_config(arguments, **kwargs):
            descriptor = kwargs["pass_fds"][0]
            observed["descriptor"] = descriptor
            observed["payload"] = os.pread(
                descriptor,
                production_auto_deploy.PROTECTED_VALUE_MAX_BYTES,
                0,
            )
            observed["arguments"] = list(arguments)
            observed["stdin"] = kwargs["stdin_data"]
            replacement = config.ntfy_curl_config.with_name("replacement.curlrc")
            replacement.write_text("changed\n", encoding="utf-8")
            replacement.chmod(0o600)
            os.replace(replacement, config.ntfy_curl_config)
            return subprocess.CompletedProcess(arguments, 0, b"", b"")

        stderr = io.StringIO()
        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=replace_config,
        ), contextlib.redirect_stderr(stderr):
            delivered = production_auto_deploy.notify(
                config,
                "failed",
                MAIN_SHA,
                "2026-08-14T12:00:00Z",
                "2026-08-14T12:01:00Z",
                log_path,
            )

        self.assertTrue(delivered)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(observed["payload"], original_payload)
        self.assertEqual(config.ntfy_curl_config.read_bytes(), b"changed\n")
        self.assertNotIn(token, " ".join(observed["arguments"]))
        self.assertNotIn(token.encode(), observed["stdin"])
        with self.assertRaises(OSError):
            os.fstat(observed["descriptor"])
        self.assertEqual(
            list(config.ntfy_curl_config.parent.glob(".notification-config-*")),
            [],
        )

    def test_notify_closes_snapshot_when_runner_fails(self):
        config = self.loaded_config()
        log_path = config.log_root / (
            f"attempt-20260814T120000Z-{MAIN_SHA}.log"
        )
        log_path.write_text("safe\n", encoding="utf-8")
        log_path.chmod(0o600)
        observed = {}

        def fail(_arguments, **kwargs):
            observed["descriptor"] = kwargs["pass_fds"][0]
            raise production_auto_deploy.DeploymentError("curl failed")

        stderr = io.StringIO()
        with mock.patch.object(
            production_auto_deploy,
            "_run_command",
            side_effect=fail,
        ), contextlib.redirect_stderr(stderr):
            delivered = production_auto_deploy.notify(
                config,
                "failed",
                MAIN_SHA,
                "2026-08-14T12:00:00Z",
                "2026-08-14T12:01:00Z",
                log_path,
            )

        self.assertFalse(delivered)
        self.assertEqual(
            stderr.getvalue(),
            "deployment notification could not be delivered\n",
        )
        with self.assertRaises(OSError):
            os.fstat(observed["descriptor"])
        self.assertEqual(
            list(config.ntfy_curl_config.parent.glob(".notification-config-*")),
            [],
        )

    def test_poll_notifies_only_after_durable_outcome_and_ignores_notify_failure(self):
        observed = []
        stderr = io.StringIO()

        def notification(_config, outcome, sha, started, finished, log_path):
            state = production_auto_deploy.read_sha_state(
                self.state_path("last-successful")
            )
            observed.append((outcome, sha, started, finished, log_path, state))
            raise OSError("ntfy unavailable")

        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            return_value=True,
        ), mock.patch.object(
            production_auto_deploy,
            "notify",
            side_effect=notification,
        ), contextlib.redirect_stderr(stderr):
            result = production_auto_deploy.poll(self.loaded_config())

        self.assertTrue(result)
        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0][0:2], ("success", MAIN_SHA))
        self.assertEqual(observed[0][5].outcome, "success")
        self.assertTrue(Path(observed[0][4]).is_file())
        self.assertEqual(
            stderr.getvalue(),
            "deployment notification could not be delivered\n",
        )

    def test_failed_poll_notifies_only_after_durable_failure_and_keeps_result(self):
        observed = []

        def notification(_config, outcome, sha, started, finished, log_path):
            state = production_auto_deploy.read_sha_state(
                self.state_path("last-failed")
            )
            observed.append((outcome, sha, started, finished, log_path, state))
            return False

        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            return_value=False,
        ), mock.patch.object(
            production_auto_deploy,
            "notify",
            side_effect=notification,
        ):
            result = production_auto_deploy.poll(self.loaded_config())

        self.assertFalse(result)
        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0][0:2], ("failed", MAIN_SHA))
        self.assertEqual(observed[0][5].outcome, "failed")
        self.assertTrue(Path(observed[0][4]).is_file())

    def test_successful_cli_ignores_rotation_failure_and_notifies_once(self):
        notifications = []
        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            return_value=True,
        ), mock.patch.object(
            production_auto_deploy,
            "rotate_logs",
            side_effect=production_auto_deploy.StateError("rotation failed"),
        ), mock.patch.object(
            production_auto_deploy,
            "notify",
            side_effect=lambda _config, outcome, *_args: notifications.append(
                outcome
            ),
        ):
            status, _stdout, stderr = self.invoke_main("--poll")

        self.assertEqual(status, 0)
        self.assertEqual(notifications, ["success"])
        self.assertEqual(
            stderr,
            "deployment log rotation could not be completed\n",
        )

    def test_failed_cli_ignores_rotation_failure_and_notifies_once(self):
        notifications = []
        with self.candidate(MAIN_SHA), mock.patch.object(
            production_auto_deploy,
            "attempt_candidate",
            return_value=False,
        ), mock.patch.object(
            production_auto_deploy,
            "rotate_logs",
            side_effect=production_auto_deploy.StateError("rotation failed"),
        ), mock.patch.object(
            production_auto_deploy,
            "notify",
            side_effect=lambda _config, outcome, *_args: notifications.append(
                outcome
            ),
        ):
            status, _stdout, stderr = self.invoke_main("--poll")

        self.assertEqual(status, 1)
        self.assertEqual(notifications, ["failed"])
        self.assertEqual(
            stderr,
            "deployment log rotation could not be completed\n"
            "production auto-deploy: attempt failed\n",
        )

    def test_poll_sigterm_cleans_children_records_failure_and_releases_lock(self):
        entered = self.root / "signal-attempt-entered"
        child_pid = self.root / "signal-child-pid"
        orphan = self.root / "signal-orphan"
        command_source = (
            "import pathlib,subprocess,sys,time\n"
            "child=subprocess.Popen([sys.executable,'-c',"
            + repr(
                "import os,pathlib,time; "
                f"pathlib.Path({str(child_pid)!r}).write_text(str(os.getpid())); "
                "time.sleep(1); "
                f"pathlib.Path({str(orphan)!r}).write_text('orphaned')"
            )
            + "])\n"
            f"pid_path=pathlib.Path({str(child_pid)!r})\n"
            "deadline=time.monotonic()+2\n"
            "while not pid_path.exists() and time.monotonic()<deadline: time.sleep(.01)\n"
            f"pathlib.Path({str(entered)!r}).write_text('entered')\n"
            "time.sleep(10)\n"
        )
        runner_source = (
            "import pathlib,sys\n"
            f"sys.path.insert(0, {str(SCRIPT.parent)!r})\n"
            "import production_auto_deploy as module\n"
            "module._owned_root = lambda config: config.deployment_home\n"
            f"config=module.load_config({str(self.config_path)!r})\n"
            f"sha={MAIN_SHA!r}\n"
            "module._validate_controller_python=lambda _config: _config.controller_python\n"
            "module.resolve_main_sha=lambda _config: sha\n"
            "module.fetch_ci_runs=lambda _config,_sha: (module.CiRun("
            "head_sha=sha,status='completed',conclusion='success',event='push',"
            "head_branch='main',name='CI'),)\n"
            "module.notify=lambda *_args,**_kwargs: True\n"
            "def attempt(_config,_sha):\n"
            "    sink=getattr(module._ACTIVE_ATTEMPT_LOG,'sink')\n"
            f"    result=module._run_command([sys.executable,'-c',{command_source!r}],"
            f"cwd=pathlib.Path({str(self.root)!r}),"
            "env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C',"
            f"'HOME':{str(self.root)!r}}},timeout=10,log=sink)\n"
            "    return result.returncode == 0\n"
            "module.attempt_candidate=attempt\n"
            "module.poll(config)\n"
        )
        runner = subprocess.Popen(
            [sys.executable, "-c", runner_source],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 3
        while not entered.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        if not entered.exists():
            runner.kill()
            _stdout, stderr = runner.communicate(timeout=3)
            self.fail(f"poll attempt did not start: {stderr}")

        runner.terminate()
        runner.communicate(timeout=5)
        time.sleep(1.1)

        self.assertFalse(orphan.exists())
        failed = production_auto_deploy.read_sha_state(self.state_path("last-failed"))
        self.assertEqual((failed.sha, failed.outcome), (MAIN_SHA, "failed"))
        with production_auto_deploy.deployment_lock(self.loaded_config()) as lock_fd:
            self.assertIsNotNone(lock_fd)

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

    def test_validate_controller_is_not_a_public_cli_mode(self):
        before = self.state_snapshot()
        with mock.patch.object(
            production_auto_deploy,
            "_validate_controller_checkout",
        ) as validate:
            status, stdout, stderr = self.invoke_main(
                "--validate-controller",
                MAIN_SHA,
            )

        self.assertEqual(
            (status, stdout, stderr),
            (2, "", "production auto-deploy: invalid arguments\n"),
        )
        validate.assert_not_called()
        invalid, _, _ = self.invoke_main("--validate-controller", "not-a-sha")
        self.assertEqual(invalid, 2)
        self.assert_no_mutation(before)

    def test_cli_accepts_only_config_first_followed_by_one_exact_mode(self):
        before = self.state_snapshot()
        relative_config = os.path.relpath(self.config_path, Path.cwd())
        config_link = self.root / "config-link.json"
        config_link.symlink_to(self.config_path)
        absent_config = self.root / "absent.json"
        loose_config = self.root / "loose-config.json"
        loose_config.write_bytes(self.config_path.read_bytes())
        loose_config.chmod(0o644)
        cases = (
            (),
            ("--status",),
            ("--config",),
            ("--config", str(self.config_path)),
            ("--config", relative_config, "--status"),
            ("--config", "invalid\0config", "--status"),
            ("--config", str(config_link), "--status"),
            ("--config", str(absent_config), "--status"),
            ("--config", str(loose_config), "--status"),
            ("--status", "--config", str(self.config_path)),
            ("--config", str(self.config_path), "--config", str(self.config_path), "--status"),
            ("--config", str(self.config_path), "--status", "extra"),
            ("--config", str(self.config_path), "--retry-failed"),
            ("--config", str(self.config_path), "--retry-failed", MAIN_SHA, "extra"),
        )

        for arguments in cases:
            with self.subTest(arguments=arguments):
                status, stdout, stderr = self.invoke_raw_main(*arguments)
                self.assertEqual(status, 2)
                self.assertEqual(stdout, "")
                self.assertEqual(
                    stderr,
                    "production auto-deploy: invalid arguments\n",
                )

        self.assert_no_mutation(before)
        self.assertEqual(self.httpd.requests, [])
        self.assertEqual(self.tool_calls.read_text(encoding="utf-8"), "")

    def test_cli_accepts_only_the_physical_config_pinned_by_exact_managed_links(self):
        libexec, generation, generation_config = self.write_cli_generation(
            self.config_path.read_bytes()
        )
        generations = generation.parent
        current = libexec / "current"
        current.symlink_to(f"generations/{generation.name}")
        self.config_path.unlink()
        self.config_path.symlink_to(
            "../../.local/libexec/nas-platform/current/deployer.json"
        )

        with mock.patch.object(
            production_auto_deploy,
            "__file__",
            str(generation / "production_auto_deploy.py"),
        ):
            loaded = production_auto_deploy._load_cli_config(generation_config)
            self.assertEqual(loaded.ntfy_curl_config, generation / "ntfy.curl")
            status, stdout, stderr = self.invoke_raw_main(
                "--config", str(generation_config), "--status"
            )
        self.assertEqual((status, stdout, stderr), (0, "", ""))

        with self.assertRaises(production_auto_deploy.CliConfigPathError):
            production_auto_deploy._load_cli_config(self.config_path)

        _libexec, other, other_config = self.write_cli_generation(
            generation_config.read_bytes(), b"# other\n"
        )
        before = self.state_snapshot()
        with mock.patch.object(
            production_auto_deploy,
            "__file__",
            str(generation / "production_auto_deploy.py"),
        ):
            status, stdout, stderr = self.invoke_raw_main(
                "--config", str(other_config), "--poll"
            )
        self.assertEqual(
            (status, stdout, stderr),
            (2, "", "production auto-deploy: invalid arguments\n"),
        )
        self.assert_no_mutation(before)
        self.assertEqual(self.httpd.requests, [])
        self.assertNotEqual(other, generation)

        external = self.root / "external-config.json"
        external.write_bytes(generation_config.read_bytes())
        external.chmod(0o600)
        generation_config.unlink()
        generation_config.symlink_to(external)
        with self.assertRaises(production_auto_deploy.CliConfigPathError):
            production_auto_deploy._load_cli_config(generation_config)

    def test_cli_keeps_a_complete_pinned_config_when_current_changes_during_open(self):
        libexec, first, first_config = self.write_cli_generation(
            self.config_path.read_bytes(), b"# first\n"
        )
        _libexec, second, _second_config = self.write_cli_generation(
            self.config_path.read_bytes(), b"# second\n"
        )
        current = libexec / "current"
        current.symlink_to(f"generations/{first.name}")
        self.config_path.unlink()
        self.config_path.symlink_to(
            "../../.local/libexec/nas-platform/current/deployer.json"
        )
        real_open = production_auto_deploy.os.open
        switched = False

        def switch_current(path, flags, mode=0o777, *, dir_fd=None):
            nonlocal switched
            descriptor = real_open(path, flags, mode, dir_fd=dir_fd)
            if Path(path) == first / "deployer.json" and not switched:
                switched = True
                current.unlink()
                current.symlink_to(f"generations/{second.name}")
            return descriptor

        with mock.patch.object(
            production_auto_deploy.os,
            "open",
            side_effect=switch_current,
        ), mock.patch.object(
            production_auto_deploy,
            "__file__",
            str(first / "production_auto_deploy.py"),
        ):
            loaded = production_auto_deploy._load_cli_config(first_config)

        self.assertTrue(switched)
        self.assertEqual(loaded.deployment_home, self.root)

    def test_cli_ignores_ambient_config_fallbacks(self):
        before = self.state_snapshot()
        hostile_environment = {
            "NAS_PLATFORM_AUTO_DEPLOY_CONFIG": str(self.config_path),
            "PRODUCTION_AUTO_DEPLOY_CONFIG": str(self.config_path),
        }

        with mock.patch.dict(os.environ, hostile_environment, clear=False):
            status, stdout, stderr = self.invoke_raw_main("--status")

        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "production auto-deploy: invalid arguments\n")
        self.assert_no_mutation(before)
        self.assertEqual(self.httpd.requests, [])

    def test_cli_rejects_a_config_home_not_owned_by_the_effective_os_account(self):
        before = self.state_snapshot()
        with mock.patch.object(
            production_auto_deploy.pwd,
            "getpwuid",
            return_value=mock.Mock(pw_dir=str(self.root / "different-home")),
        ):
            status, stdout, stderr = self.invoke_raw_main(
                "--config",
                str(self.config_path),
                "--status",
            )

        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "production auto-deploy: invalid arguments\n")
        self.assert_no_mutation(before)

    def test_cli_does_not_reopen_a_replaced_config_path(self):
        before = self.state_snapshot()
        hostile_config = self.root / "hostile-config.json"
        hostile_config.write_bytes(self.config_path.read_bytes())
        hostile_config.chmod(0o600)
        real_parse = production_auto_deploy._parse_cli_arguments

        def replace_after_parse(arguments):
            parsed = real_parse(arguments)
            self.config_path.unlink()
            self.config_path.symlink_to(hostile_config)
            return parsed

        with mock.patch.object(
            production_auto_deploy,
            "_parse_cli_arguments",
            side_effect=replace_after_parse,
        ):
            status, stdout, stderr = self.invoke_raw_main(
                "--config",
                str(self.config_path),
                "--status",
            )

        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "production auto-deploy: invalid arguments\n")
        self.assert_no_mutation(before)
        self.assertEqual(self.httpd.requests, [])


if __name__ == "__main__":
    unittest.main()
