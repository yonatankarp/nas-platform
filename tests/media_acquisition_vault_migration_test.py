#!/usr/bin/env python3
"""Black-box audit for the one-use encrypted acquisition-vault migrator.

Every behavior case uses a synthetic repository and synthetic encrypted vault.
The production vault is snapshotted only as opaque bytes and is never supplied
to the migrator by this suite.
"""

import hashlib
import importlib.util
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml
from ansible.constants import DEFAULT_VAULT_ID_MATCH
from ansible.parsing.vault import VaultLib, VaultSecret


ROOT = Path(__file__).resolve().parents[1]
MIGRATOR = ROOT / "scripts/migrate-media-acquisition-vault.py"
FILTER = ROOT / "filter_plugins/vault_credential_schema.py"
REAL_VAULT = ROOT / "inventory/group_vars/all/vault.yml"
LEGACY_KEY = "vault_" + "tinymediamanager" + "_password"
NEW_KEYS = (
    "vault_arr_radarr_api_key",
    "vault_arr_radarr_admin_username",
    "vault_arr_radarr_admin_password",
    "vault_arr_sonarr_api_key",
    "vault_arr_sonarr_admin_username",
    "vault_arr_sonarr_admin_password",
    "vault_arr_prowlarr_api_key",
    "vault_arr_prowlarr_admin_username",
    "vault_arr_prowlarr_admin_password",
    "vault_arr_bazarr_api_key",
    "vault_arr_bazarr_admin_username",
    "vault_arr_bazarr_admin_password",
    "vault_downloaders_sabnzbd_api_key",
    "vault_downloaders_sabnzbd_admin_username",
    "vault_downloaders_sabnzbd_admin_password",
)
FIXTURE_PASSWORD = "synthetic-vault-password-never-log"
FIXTURE_LEGACY_SECRET = "synthetic-retired-password-never-log"
INJECTED_API_SECRET = "a" * 32
INJECTED_PASSWORD_SECRET = "synthetic-generated-password-never-log"
FIXTURE_SECRETS = (
    FIXTURE_PASSWORD,
    FIXTURE_LEGACY_SECRET,
    INJECTED_API_SECRET,
    INJECTED_PASSWORD_SECRET,
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def load_schema(path):
    name = "synthetic_vault_credential_schema"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


SCHEMA = load_schema(FILTER)


def valid_credentials():
    values = {}
    for key in SCHEMA.CREDENTIAL_RULES:
        if key.endswith("_password_hash"):
            value = "$2b$12$" + "A" * 53
        elif key.endswith("_email") or key.endswith("_gmail_account"):
            value = "synthetic@example.invalid"
        elif key.endswith("_db_name"):
            value = "synthetic_db"
        elif key.endswith("_db_username"):
            value = "synthetic_user"
        elif key.endswith("_token") and key.startswith("vault_ntfy_"):
            value = "tk_" + "a" * 29
        elif key == "vault_beszel_agent_key":
            value = "ssh-ed25519 AAAA"
        elif key == "vault_beszel_universal_token":
            value = "12345678-1234-4123-8123-123456789abc"
        elif key == "vault_beszel_hub_private_key":
            value = "BEGIN OPENSSH PRIVATE KEY"
        elif key == "vault_jellyfin_admin_username":
            value = SCHEMA.JELLYFIN_ADMIN_USERNAME
        elif key.endswith("_api_key"):
            value = "f" * 32
        else:
            value = "synthetic-value"
        values[key] = value

    for index, key in enumerate((
        "vault_ntfy_dozzle_token",
        "vault_ntfy_beszel_token",
        "vault_ntfy_deploy_token",
    )):
        values[key] = "tk_" + str(index) * 29
    for index, key in enumerate(key for key in NEW_KEYS if key.endswith("_api_key")):
        values[key] = f"{index + 1:032x}"
    for index, key in enumerate(key for key in NEW_KEYS if key.endswith("_admin_password")):
        values[key] = f"synthetic-distinct-password-{index}"
    return values


def encrypt(document, password=FIXTURE_PASSWORD, raw_yaml=None):
    plaintext = raw_yaml if raw_yaml is not None else yaml.safe_dump(
        document, sort_keys=False, allow_unicode=False
    )
    vault = VaultLib([(DEFAULT_VAULT_ID_MATCH, VaultSecret(password.encode()))])
    return vault.encrypt(plaintext.encode())


def decrypt(ciphertext, password=FIXTURE_PASSWORD):
    vault = VaultLib([(DEFAULT_VAULT_ID_MATCH, VaultSecret(password.encode()))])
    return yaml.safe_load(vault.decrypt(ciphertext))


def migrated_document(extra=None):
    document = valid_credentials()
    if extra:
        document.update(extra)
    return document


def legacy_document(extra=None):
    document = valid_credentials()
    for key in NEW_KEYS:
        document.pop(key)
    document[LEGACY_KEY] = FIXTURE_LEGACY_SECRET
    if extra:
        document.update(extra)
    return document


CHILD_HARNESS = r'''
import importlib.util
import os
import sys
from pathlib import Path
from unittest import mock

repo = Path(sys.argv[1])
password = Path(sys.argv[2])
if repo.resolve() != Path.cwd().resolve():
    raise SystemExit("child cwd is not the synthetic repository")
mode = (repo / ".failure-mode").read_text(encoding="ascii").strip()
path = repo / "scripts/migrate-media-acquisition-vault.py"
name = "audited_media_acquisition_vault_migrator"
spec = importlib.util.spec_from_file_location(name, path)
module = importlib.util.module_from_spec(spec)
sys.modules[name] = module
spec.loader.exec_module(module)

patches = []
if mode == "duplicate-generated-api":
    patches.append(mock.patch.object(module.secrets, "token_hex", return_value="a" * 32))
elif mode == "duplicate-generated-password":
    patches.append(mock.patch.object(
        module.secrets, "token_urlsafe", return_value=__INJECTED_PASSWORD_SECRET__
    ))
elif mode == "encrypt":
    patches.append(mock.patch.object(module.VaultLib, "encrypt", side_effect=RuntimeError("synthetic encrypt failure")))
elif mode.startswith("decrypt-"):
    original = module.VaultLib.decrypt
    target = int(mode.rsplit("-", 1)[1])
    calls = {"count": 0}
    def fail_decrypt(instance, *args, **kwargs):
        calls["count"] += 1
        if calls["count"] == target:
            raise RuntimeError("synthetic decrypt failure")
        return original(instance, *args, **kwargs)
    patches.append(mock.patch.object(module.VaultLib, "decrypt", fail_decrypt))
elif mode == "fchmod":
    patches.append(mock.patch.object(module.os, "fchmod", side_effect=OSError("synthetic fchmod failure")))
elif mode.startswith("fsync-"):
    original = module.os.fsync
    target = int(mode.rsplit("-", 1)[1])
    calls = {"count": 0}
    def fail_fsync(fd):
        calls["count"] += 1
        if calls["count"] == target:
            raise OSError("synthetic fsync failure")
        return original(fd)
    patches.append(mock.patch.object(module.os, "fsync", fail_fsync))
elif mode == "replace":
    patches.append(mock.patch.object(module.os, "replace", side_effect=OSError("synthetic replace failure")))
else:
    raise SystemExit("unknown synthetic failure mode")

for patcher in patches:
    patcher.start()
try:
    result = module.main([
        "--vault", "inventory/group_vars/all/vault.yml",
        "--vault-password-file", str(password.resolve()),
    ])
finally:
    for patcher in reversed(patches):
        patcher.stop()

if result != 1:
    raise SystemExit("injected failure was not rejected")
'''
CHILD_HARNESS = CHILD_HARNESS.replace(
    "__INJECTED_PASSWORD_SECRET__", repr(INJECTED_PASSWORD_SECRET)
)


class SyntheticRepository:
    def __init__(self, case, document=None, raw_yaml=None, password=FIXTURE_PASSWORD):
        self.case = case
        self.parent = Path(case.enterContext(tempfile.TemporaryDirectory())).resolve()
        self.root = self.parent / "repo"
        self.vault = self.root / "inventory/group_vars/all/vault.yml"
        self.password = self.parent / "protected-password"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "filter_plugins").mkdir()
        self.vault.parent.mkdir(parents=True)

        source = MIGRATOR.read_bytes()
        shutil.copyfile(MIGRATOR, self.root / "scripts/migrate-media-acquisition-vault.py")
        copied = (self.root / "scripts/migrate-media-acquisition-vault.py").read_bytes()
        case.assertEqual(copied, source)
        case.assertEqual(sha256(copied), sha256(source))

        filter_source = FILTER.read_bytes()
        shutil.copyfile(FILTER, self.root / "filter_plugins/vault_credential_schema.py")
        filter_copy = (self.root / "filter_plugins/vault_credential_schema.py").read_bytes()
        case.assertEqual(filter_copy, filter_source)
        case.assertEqual(sha256(filter_copy), sha256(filter_source))

        self.password.write_text(password, encoding="utf-8")
        self.password.chmod(0o600)
        self.vault.write_bytes(encrypt(document or {}, password=password, raw_yaml=raw_yaml))
        self.vault.chmod(0o644)
        self.initial_paths = self.snapshot_paths()

    def snapshot_paths(self):
        return {path.relative_to(self.parent): (path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
                for path in self.parent.rglob("*") if path.is_file() and not path.is_symlink()}

    def run(self, vault_argument="inventory/group_vars/all/vault.yml",
            password_argument=None):
        password_argument = password_argument or str(self.password.resolve())
        return self.run_argv([
            "--vault", vault_argument,
            "--vault-password-file", password_argument,
        ])

    def run_argv(self, arguments):
        result = subprocess.run(
            [sys.executable, "scripts/migrate-media-acquisition-vault.py", *arguments],
            cwd=self.root, capture_output=True, text=True, check=False,
        )
        self.assert_safe_output(result)
        return result

    def vault_neighbor_names(self):
        return {path.name for path in self.vault.parent.iterdir()}

    def assert_no_new_vault_neighbors(self, before):
        self.case.assertEqual(self.vault_neighbor_names(), before)

    def inject(self, mode):
        (self.root / ".failure-mode").write_text(mode, encoding="ascii")
        before = self.vault.read_bytes()
        before_mode = stat.S_IMODE(self.vault.stat().st_mode)
        neighbor_names = self.vault_neighbor_names()
        result = subprocess.run(
            [sys.executable, "-c", CHILD_HARNESS,
             str(self.root), str(self.password.resolve())],
            cwd=self.root, capture_output=True, text=True, check=False,
        )
        self.assert_safe_output(result)
        self.case.assertEqual(result.returncode, 0, result.stderr)
        self.case.assertEqual(self.vault.read_bytes(), before)
        self.case.assertEqual(stat.S_IMODE(self.vault.stat().st_mode), before_mode)
        self.assert_no_new_vault_neighbors(neighbor_names)

    def assert_safe_output(self, result):
        combined = result.stdout + result.stderr
        for secret in FIXTURE_SECRETS:
            self.case.assertNotIn(secret, combined)
        for path in self.parent.rglob("*"):
            for secret in FIXTURE_SECRETS:
                self.case.assertNotIn(secret, path.name)

    def assert_only_ciphertext_neighbors(self):
        after = self.snapshot_paths()
        for relative, (content, _mode) in after.items():
            if relative not in self.initial_paths and relative.parent == self.vault.relative_to(self.parent).parent:
                self.case.assertTrue(content.startswith(b"$ANSIBLE_VAULT;"), relative)


class MigrationBehaviorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.real_vault_bytes = REAL_VAULT.read_bytes()
        cls.real_vault_mode = stat.S_IMODE(REAL_VAULT.stat().st_mode)
        cls.addClassCleanup(cls.assert_real_vault_unchanged)

    @classmethod
    def assert_real_vault_unchanged(cls):
        if REAL_VAULT.read_bytes() != cls.real_vault_bytes:
            raise AssertionError("real encrypted vault changed during synthetic behavior tests")
        if stat.S_IMODE(REAL_VAULT.stat().st_mode) != cls.real_vault_mode:
            raise AssertionError("real encrypted vault mode changed during synthetic behavior tests")

    def test_output_redaction_rejects_every_registered_fixture_secret(self):
        repo = SyntheticRepository(self, migrated_document())
        for index, secret in enumerate(FIXTURE_SECRETS):
            with self.subTest(sentinel=index):
                emitted = subprocess.CompletedProcess([], 1, secret, "")
                with self.assertRaises(AssertionError):
                    repo.assert_safe_output(emitted)
        self.assertTrue(
            INJECTED_PASSWORD_SECRET in CHILD_HARNESS,
            "duplicate-password injected value is not covered by redaction sentinels",
        )

    def test_migrates_full_document_and_second_run_is_byte_idempotent(self):
        repo = SyntheticRepository(self, legacy_document({"unrelated_mapping": {"kept": True}}))
        first = repo.run()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, "")
        self.assertEqual(first.stderr, "")
        self.assertEqual(stat.S_IMODE(repo.vault.stat().st_mode), 0o644)
        migrated = decrypt(repo.vault.read_bytes())
        self.assertNotIn(LEGACY_KEY, migrated)
        self.assertEqual(migrated["unrelated_mapping"], {"kept": True})
        api_keys = {migrated[key] for key in NEW_KEYS if key.endswith("_api_key")}
        passwords = {
            migrated[key] for key in NEW_KEYS if key.endswith("_admin_password")
        }
        self.assertEqual(len(api_keys), 5)
        self.assertEqual(len(passwords), 5)
        for key in NEW_KEYS:
            if key.endswith("_admin_username"):
                self.assertEqual(migrated[key], "nasadmin")
        candidate = {key: migrated[key] for key in SCHEMA.CREDENTIAL_RULES}
        self.assertEqual(SCHEMA.vault_credential_errors(candidate), [])
        ciphertext = repo.vault.read_bytes()
        mode = stat.S_IMODE(repo.vault.stat().st_mode)
        second = repo.run()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, "")
        self.assertEqual(second.stderr, "")
        self.assertEqual(repo.vault.read_bytes(), ciphertext)
        self.assertEqual(stat.S_IMODE(repo.vault.stat().st_mode), mode)
        repo.assert_only_ciphertext_neighbors()

    def test_valid_new_document_is_noop(self):
        repo = SyntheticRepository(self, migrated_document({"unrelated": [1, 2]}))
        before = repo.vault.read_bytes()
        result = repo.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(repo.vault.read_bytes(), before)

    def test_rejects_missing_non_acquisition_scalar_without_mutation(self):
        document = migrated_document()
        missing_key = next(key for key in SCHEMA.CREDENTIAL_RULES if key not in NEW_KEYS)
        del document[missing_key]
        repo = SyntheticRepository(self, document)
        before = repo.vault.read_bytes()
        before_mode = stat.S_IMODE(repo.vault.stat().st_mode)
        neighbor_names = repo.vault_neighbor_names()
        result = repo.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(repo.vault.read_bytes(), before)
        self.assertEqual(stat.S_IMODE(repo.vault.stat().st_mode), before_mode)
        repo.assert_no_new_vault_neighbors(neighbor_names)

    def test_rejects_ambiguous_key_states_without_mutation(self):
        cases = {
            "partial-new": legacy_document({NEW_KEYS[0]: "1" * 32}),
            "legacy-and-new": {**migrated_document(), LEGACY_KEY: FIXTURE_LEGACY_SECRET},
            "neither": {key: value for key, value in valid_credentials().items() if key not in NEW_KEYS},
        }
        for name, document in cases.items():
            with self.subTest(name=name):
                repo = SyntheticRepository(self, document)
                before = repo.vault.read_bytes()
                neighbor_names = repo.vault_neighbor_names()
                result = repo.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(repo.vault.read_bytes(), before)
                repo.assert_no_new_vault_neighbors(neighbor_names)

    def test_rejects_malformed_yaml_and_wrong_password(self):
        repo = SyntheticRepository(self, raw_yaml="key: [unterminated")
        before = repo.vault.read_bytes()
        neighbor_names = repo.vault_neighbor_names()
        self.assertNotEqual(repo.run().returncode, 0)
        self.assertEqual(repo.vault.read_bytes(), before)
        repo.assert_no_new_vault_neighbors(neighbor_names)
        wrong = repo.parent / "wrong-password"
        wrong.write_text("wrong-synthetic-password", encoding="ascii")
        wrong.chmod(0o600)
        self.assertNotEqual(repo.run(password_argument=str(wrong.resolve())).returncode, 0)
        self.assertEqual(repo.vault.read_bytes(), before)
        repo.assert_no_new_vault_neighbors(neighbor_names)

    def test_rejects_duplicate_yaml_keys_byte_identically(self):
        base = yaml.safe_dump(legacy_document(), sort_keys=False)
        duplicate_cases = {
            "legacy": base + f"{LEGACY_KEY}: duplicate\n",
            "new": base + f"{NEW_KEYS[0]}: {'9' * 32}\n{NEW_KEYS[0]}: {'8' * 32}\n",
            "unrelated": base + "unrelated: first\nunrelated: second\n",
            "nonscalar": base + "? [one, two]\n: value\n",
        }
        for name, raw_yaml in duplicate_cases.items():
            with self.subTest(name=name):
                repo = SyntheticRepository(self, raw_yaml=raw_yaml)
                before = repo.vault.read_bytes()
                neighbor_names = repo.vault_neighbor_names()
                result = repo.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(repo.vault.read_bytes(), before)
                repo.assert_no_new_vault_neighbors(neighbor_names)

    def test_rejects_noncanonical_cli_argument_sequences(self):
        for name in (
            "missing-all", "missing-vault", "missing-password", "extra",
            "reordered", "alternate-dot", "alternate-absolute", "alternate-parent",
        ):
            with self.subTest(name=name):
                repo = SyntheticRepository(self, legacy_document())
                password = str(repo.password.resolve())
                canonical_vault = "inventory/group_vars/all/vault.yml"
                cases = {
                    "missing-all": [],
                    "missing-vault": ["--vault-password-file", password],
                    "missing-password": ["--vault", canonical_vault],
                    "extra": ["--vault", canonical_vault,
                              "--vault-password-file", password, "unexpected"],
                    "reordered": ["--vault-password-file", password,
                                  "--vault", canonical_vault],
                    "alternate-dot": ["--vault", f"./{canonical_vault}",
                                      "--vault-password-file", password],
                    "alternate-absolute": ["--vault", str(repo.vault),
                                           "--vault-password-file", password],
                    "alternate-parent": [
                        "--vault", "inventory/group_vars/all/../all/vault.yml",
                        "--vault-password-file", password,
                    ],
                }
                before = repo.vault.read_bytes()
                neighbor_names = repo.vault_neighbor_names()
                result = repo.run_argv(cases[name])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(repo.vault.read_bytes(), before)
                repo.assert_no_new_vault_neighbors(neighbor_names)

    def test_rejects_symlinks_modes_and_outside_target_without_mutation(self):
        for target in ("vault", "password"):
            with self.subTest(target=target):
                repo = SyntheticRepository(self, legacy_document())
                if target == "vault":
                    backing = repo.parent / "vault-backing"
                    os.replace(repo.vault, backing)
                    repo.vault.symlink_to(backing)
                else:
                    backing = repo.parent / "password-backing"
                    os.replace(repo.password, backing)
                    repo.password.symlink_to(backing)
                before = backing.read_bytes()
                neighbor_names = repo.vault_neighbor_names()
                password_argument = (str(repo.password.absolute()) if target == "password"
                                     else None)
                result = repo.run(password_argument=password_argument)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(backing.read_bytes(), before)
                repo.assert_no_new_vault_neighbors(neighbor_names)

        for target, mode in (("vault", 0o600), ("password", 0o644)):
            with self.subTest(target=target, mode=mode):
                repo = SyntheticRepository(self, legacy_document())
                path = repo.vault if target == "vault" else repo.password
                path.chmod(mode)
                before = repo.vault.read_bytes()
                neighbor_names = repo.vault_neighbor_names()
                self.assertNotEqual(repo.run().returncode, 0)
                self.assertEqual(repo.vault.read_bytes(), before)
                repo.assert_no_new_vault_neighbors(neighbor_names)

        repo = SyntheticRepository(self, legacy_document())
        outside = repo.parent / "outside.yml"
        outside.write_bytes(repo.vault.read_bytes())
        outside.chmod(0o644)
        vault_before = repo.vault.read_bytes()
        outside_before = outside.read_bytes()
        neighbor_names = repo.vault_neighbor_names()
        self.assertNotEqual(repo.run(vault_argument=str(outside)).returncode, 0)
        self.assertEqual(repo.vault.read_bytes(), vault_before)
        self.assertEqual(outside.read_bytes(), outside_before)
        repo.assert_no_new_vault_neighbors(neighbor_names)

    def test_rejects_same_repository_symlink_invocation_without_mutation(self):
        repo = SyntheticRepository(self, legacy_document())
        source = repo.root / "scripts/migrate-media-acquisition-vault.py"
        internal_copy = repo.root / "scripts/internal-migration-helper.py"
        shutil.copyfile(source, internal_copy)
        source.unlink()
        source.symlink_to(internal_copy.name)
        before = repo.vault.read_bytes()
        neighbor_names = repo.vault_neighbor_names()
        result = repo.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(repo.vault.read_bytes(), before)
        repo.assert_no_new_vault_neighbors(neighbor_names)

    def test_rejects_repository_and_filter_parent_chain_symlinks(self):
        setups = {
            "vault-parent": lambda repo: self._replace_with_internal_symlink(
                repo.root / "inventory/group_vars", repo.root / "vault-parent-copy"
            ),
            "source-parent": lambda repo: self._replace_with_internal_symlink(
                repo.root / "scripts", repo.root / "scripts-copy"
            ),
            "filter-file": lambda repo: self._replace_with_internal_symlink(
                repo.root / "filter_plugins/vault_credential_schema.py",
                repo.root / "filter_plugins/schema-copy.py",
            ),
            "filter-parent": lambda repo: self._replace_with_internal_symlink(
                repo.root / "filter_plugins", repo.root / "filter-plugins-copy"
            ),
        }
        for name, setup in setups.items():
            with self.subTest(name=name):
                repo = SyntheticRepository(self, legacy_document())
                setup(repo)
                before = repo.vault.read_bytes()
                neighbor_names = repo.vault_neighbor_names()
                result = repo.run()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(repo.vault.read_bytes(), before)
                repo.assert_no_new_vault_neighbors(neighbor_names)

    @staticmethod
    def _replace_with_internal_symlink(path, replacement):
        os.replace(path, replacement)
        path.symlink_to(replacement, target_is_directory=replacement.is_dir())

    def test_rejects_symlinked_and_nonregular_migrator_source(self):
        repo = SyntheticRepository(self, legacy_document())
        source = repo.root / "scripts/migrate-media-acquisition-vault.py"
        external = repo.parent / "external-migrator.py"
        shutil.copyfile(source, external)
        source.unlink()
        source.symlink_to(external)
        before = repo.vault.read_bytes()
        neighbor_names = repo.vault_neighbor_names()
        self.assertNotEqual(repo.run().returncode, 0)
        self.assertEqual(repo.vault.read_bytes(), before)
        repo.assert_no_new_vault_neighbors(neighbor_names)

        repo = SyntheticRepository(self, legacy_document())
        source = repo.root / "scripts/migrate-media-acquisition-vault.py"
        source.unlink()
        source.mkdir()
        before = repo.vault.read_bytes()
        neighbor_names = repo.vault_neighbor_names()
        self.assertNotEqual(repo.run().returncode, 0)
        self.assertEqual(repo.vault.read_bytes(), before)
        repo.assert_no_new_vault_neighbors(neighbor_names)

    def test_injected_generation_and_io_failures_leave_ciphertext_unchanged(self):
        for failure in (
            "duplicate-generated-api", "duplicate-generated-password",
            "decrypt-1", "decrypt-2", "encrypt", "fchmod",
            "fsync-1", "fsync-2", "fsync-3", "replace",
        ):
            with self.subTest(failure=failure):
                SyntheticRepository(self, legacy_document()).inject(failure)


if __name__ == "__main__":
    unittest.main()
