#!/usr/bin/env python3
"""One-use, in-process migration of the encrypted acquisition credentials.

Plaintext and the vault password never leave this process. Python and Ansible
necessarily create some immutable objects while decrypting, parsing, validating,
and encrypting; their lifetime cannot be deterministically erased. Mutable
buffers are overwritten and references are dropped on every exit path as a
best-effort reduction of that runtime exposure.
"""

import argparse
import importlib.util
import os
import secrets
import stat
import sys
from pathlib import Path

import yaml
from ansible.constants import DEFAULT_VAULT_ID_MATCH
from ansible.parsing.vault import VaultLib, VaultSecret


SOURCE_PATH = Path(__file__).resolve()
REPOSITORY_ROOT = SOURCE_PATH.parents[1]
EXPECTED_VAULT_ARGUMENT = "inventory/group_vars/all/vault.yml"
EXPECTED_VAULT_PATH = REPOSITORY_ROOT / EXPECTED_VAULT_ARGUMENT
CREDENTIAL_FILTER_PATH = REPOSITORY_ROOT / "filter_plugins/vault_credential_schema.py"
LEGACY_KEY = "vault_" + "tinymediamanager" + "_password"
SERVICE_NAMES = ("radarr", "sonarr", "prowlarr", "bazarr", "sabnzbd")
NEW_KEYS = tuple(
    key
    for service in SERVICE_NAMES
    for key in (
        (f"vault_arr_{service}_api_key" if service != "sabnzbd"
         else "vault_downloaders_sabnzbd_api_key"),
        (f"vault_arr_{service}_admin_username" if service != "sabnzbd"
         else "vault_downloaders_sabnzbd_admin_username"),
        (f"vault_arr_{service}_admin_password" if service != "sabnzbd"
         else "vault_downloaders_sabnzbd_admin_password"),
    )
)
MAX_DISTINCT_GENERATION_ATTEMPTS = 100
FILTER_IMPORT_NAME = "media_acquisition_migration_vault_credential_schema"


class MigrationError(Exception):
    """A safe-to-report migration failure."""


class UniqueKeyLoader(yaml.SafeLoader):
    """Safe YAML loader that rejects duplicate and non-scalar mapping keys."""

    def construct_mapping(self, node, deep=False):
        if not isinstance(node, yaml.MappingNode):
            raise MigrationError("vault YAML contains an invalid mapping")
        seen = set()
        for key_node, _value_node in node.value:
            if not isinstance(key_node, yaml.ScalarNode):
                raise MigrationError("vault YAML mapping keys must be scalar")
            key = self.construct_object(key_node, deep=deep)
            try:
                duplicate = key in seen
                seen.add(key)
            except TypeError as exc:
                raise MigrationError("vault YAML mapping keys must be scalar") from exc
            if duplicate:
                raise MigrationError("vault YAML contains a duplicate mapping key")
        return super().construct_mapping(node, deep=deep)


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        raise MigrationError("expected exact --vault and --vault-password-file arguments")


def _zero(buffer):
    if isinstance(buffer, bytearray):
        buffer[:] = b"\0" * len(buffer)


def _validate_absolute_chain(path, final_mode, description):
    if not path.is_absolute():
        raise MigrationError(f"{description} path must be absolute")
    current = Path(path.anchor)
    components = path.parts[1:]
    for index, component in enumerate(components):
        current = current / component
        try:
            metadata = current.lstat()
        except OSError as exc:
            raise MigrationError(f"{description} path cannot be inspected") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise MigrationError(f"{description} path must not contain symlinks")
        if index < len(components) - 1:
            if not stat.S_ISDIR(metadata.st_mode):
                raise MigrationError(f"{description} parent must be a directory")
        elif not stat.S_ISREG(metadata.st_mode):
            raise MigrationError(f"{description} must be a regular file")
    metadata = path.lstat()
    if stat.S_IMODE(metadata.st_mode) != final_mode:
        raise MigrationError(f"{description} must have mode {final_mode:04o}")
    return metadata


def _validate_repository_file(path, expected_mode=None, description="repository file"):
    try:
        relative = path.relative_to(REPOSITORY_ROOT)
    except ValueError as exc:
        raise MigrationError(f"{description} is outside the repository") from exc
    current = REPOSITORY_ROOT
    try:
        root_metadata = current.lstat()
    except OSError as exc:
        raise MigrationError("repository root cannot be inspected") from exc
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise MigrationError("repository root must be a non-symlink directory")
    for index, component in enumerate(relative.parts):
        current = current / component
        try:
            metadata = current.lstat()
        except OSError as exc:
            raise MigrationError(f"{description} cannot be inspected") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise MigrationError(f"{description} path must not contain symlinks")
        if index < len(relative.parts) - 1:
            if not stat.S_ISDIR(metadata.st_mode):
                raise MigrationError(f"{description} parent must be a directory")
        elif not stat.S_ISREG(metadata.st_mode):
            raise MigrationError(f"{description} must be a regular file")
    if expected_mode is not None and stat.S_IMODE(metadata.st_mode) != expected_mode:
        raise MigrationError(f"{description} must have mode {expected_mode:04o}")
    return metadata


def _load_credential_contract():
    _validate_repository_file(CREDENTIAL_FILTER_PATH, description="credential filter")
    spec = importlib.util.spec_from_file_location(FILTER_IMPORT_NAME, CREDENTIAL_FILTER_PATH)
    if spec is None or spec.loader is None:
        raise MigrationError("credential filter cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[FILTER_IMPORT_NAME] = module
    try:
        spec.loader.exec_module(module)
        rules = module.CREDENTIAL_RULES
        validator = module.vault_credential_errors
    except Exception as exc:
        raise MigrationError("credential filter cannot be loaded") from exc
    if not isinstance(rules, dict) or not callable(validator):
        raise MigrationError("credential filter contract is invalid")
    return rules, validator


def _parse_document(plaintext):
    try:
        document = yaml.load(bytes(plaintext), Loader=UniqueKeyLoader)
    except MigrationError:
        raise
    except yaml.YAMLError as exc:
        raise MigrationError("vault plaintext is malformed YAML") from exc
    if not isinstance(document, dict):
        raise MigrationError("vault plaintext must be one mapping")
    return document


def _validate_candidate(document, rules, validator):
    missing = [key for key in rules if key not in document]
    if missing:
        raise MigrationError(f"credential field is missing: {missing[0]}")
    candidate = {key: document[key] for key in rules}
    try:
        errors = validator(candidate)
    except Exception as exc:
        raise MigrationError("credential fields could not be validated") from exc
    if errors:
        raise MigrationError(f"credential validation failed: {errors[0]}")


def _distinct_values(generator):
    values = []
    attempts = 0
    while len(values) < len(SERVICE_NAMES):
        attempts += 1
        if attempts > MAX_DISTINCT_GENERATION_ATTEMPTS:
            raise MigrationError("generated acquisition credentials were not distinct")
        value = generator()
        if value not in values:
            values.append(value)
    return values


def _apply_migration(document):
    api_keys = _distinct_values(lambda: secrets.token_hex(16))
    passwords = _distinct_values(lambda: secrets.token_urlsafe(32))
    del document[LEGACY_KEY]
    for index, service in enumerate(SERVICE_NAMES):
        prefix = (f"vault_arr_{service}" if service != "sabnzbd"
                  else "vault_downloaders_sabnzbd")
        document[f"{prefix}_api_key"] = api_keys[index]
        document[f"{prefix}_admin_username"] = "nasadmin"
        document[f"{prefix}_admin_password"] = passwords[index]


def _write_all(descriptor, ciphertext):
    offset = 0
    while offset < len(ciphertext):
        written = os.write(descriptor, ciphertext[offset:])
        if written <= 0:
            raise MigrationError("encrypted temporary vault could not be written")
        offset += written


def _safe_unlink_temp(path, descriptor, ciphertext):
    try:
        descriptor_metadata = os.fstat(descriptor)
        path_metadata = path.lstat()
        same_file = (descriptor_metadata.st_dev, descriptor_metadata.st_ino) == (
            path_metadata.st_dev, path_metadata.st_ino
        )
        if (same_file and stat.S_ISREG(path_metadata.st_mode) and
                ciphertext.startswith(b"$ANSIBLE_VAULT;")):
            path.unlink()
    except OSError:
        pass


def _restore_original(vault_path, original_ciphertext):
    """Best-effort rollback when durability fails after atomic replacement."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    rollback_path = vault_path.parent / f".{vault_path.name}.rollback-{secrets.token_hex(8)}"
    descriptor = os.open(rollback_path, flags, 0o600)
    installed = False
    try:
        _write_all(descriptor, original_ciphertext)
        os.fsync(descriptor)
        os.fchmod(descriptor, 0o644)
        os.fsync(descriptor)
        os.replace(rollback_path, vault_path)
        installed = True
        parent_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        parent_descriptor = os.open(vault_path.parent, parent_flags)
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
    finally:
        if not installed:
            _safe_unlink_temp(rollback_path, descriptor, original_ciphertext)
        os.close(descriptor)


def _atomic_install(vault_path, ciphertext, original_ciphertext, password_bytes,
                    expected_document, rules, validator):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0)
    temp_path = None
    descriptor = None
    for _attempt in range(100):
        candidate = vault_path.parent / f".{vault_path.name}.migration-{secrets.token_hex(8)}"
        try:
            descriptor = os.open(candidate, flags, 0o600)
            temp_path = candidate
            break
        except FileExistsError:
            continue
        except OSError as exc:
            raise MigrationError("encrypted temporary vault could not be created") from exc
    if descriptor is None or temp_path is None:
        raise MigrationError("unique encrypted temporary vault could not be created")

    installed = False
    try:
        _write_all(descriptor, ciphertext)
        os.fsync(descriptor)

        read_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        verification_descriptor = os.open(temp_path, read_flags)
        verification_plaintext = None
        try:
            verification_ciphertext = bytearray()
            while True:
                chunk = os.read(verification_descriptor, 65536)
                if not chunk:
                    break
                verification_ciphertext.extend(chunk)
            verification_plaintext = bytearray(
                VaultLib([(DEFAULT_VAULT_ID_MATCH, VaultSecret(password_bytes))]).decrypt(
                    bytes(verification_ciphertext)
                )
            )
            verified_document = _parse_document(verification_plaintext)
            if verified_document != expected_document:
                raise MigrationError("encrypted temporary vault failed full-document verification")
            _validate_candidate(verified_document, rules, validator)
        except MigrationError:
            raise
        except Exception as exc:
            raise MigrationError("encrypted temporary vault could not be verified") from exc
        finally:
            _zero(verification_plaintext)
            if "verification_ciphertext" in locals():
                _zero(verification_ciphertext)
            os.close(verification_descriptor)

        os.fchmod(descriptor, 0o644)
        if stat.S_IMODE(os.fstat(descriptor).st_mode) != 0o644:
            raise MigrationError("encrypted temporary vault mode verification failed")
        os.fsync(descriptor)
        os.replace(temp_path, vault_path)
        installed = True
        parent_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        parent_descriptor = os.open(vault_path.parent, parent_flags)
        try:
            try:
                os.fsync(parent_descriptor)
            except OSError:
                _restore_original(vault_path, original_ciphertext)
                raise
        finally:
            os.close(parent_descriptor)
    except MigrationError:
        raise
    except OSError as exc:
        raise MigrationError("encrypted vault could not be installed atomically") from exc
    finally:
        if not installed:
            _safe_unlink_temp(temp_path, descriptor, ciphertext)
        os.close(descriptor)


def migrate(vault_argument, password_argument):
    """Migrate the exact production vault, or validate its idempotent state."""
    password_buffer = None
    ciphertext_buffer = None
    plaintext_buffer = None
    serialized_buffer = None
    encrypted_buffer = None
    document = None
    try:
        if vault_argument != EXPECTED_VAULT_ARGUMENT:
            raise MigrationError("vault argument must name the exact repository vault")
        caller_vault = Path(os.path.abspath(vault_argument))
        if str(caller_vault) != str(EXPECTED_VAULT_PATH):
            raise MigrationError("vault argument does not identify the expected repository vault")
        if not os.path.isabs(password_argument):
            raise MigrationError("vault password file argument must be absolute")
        password_path = Path(password_argument)

        _validate_repository_file(SOURCE_PATH, description="migration source")
        _validate_repository_file(EXPECTED_VAULT_PATH, expected_mode=0o644,
                                  description="encrypted vault")
        _validate_absolute_chain(password_path, 0o600, "vault password file")
        rules, validator = _load_credential_contract()

        try:
            password_buffer = bytearray(password_path.read_bytes())
            ciphertext_buffer = bytearray(EXPECTED_VAULT_PATH.read_bytes())
        except OSError as exc:
            raise MigrationError("encrypted vault inputs could not be read") from exc
        password_bytes = bytes(password_buffer).rstrip(b"\r\n")
        if not password_bytes:
            raise MigrationError("vault password file must not be empty")
        try:
            plaintext_buffer = bytearray(
                VaultLib([(DEFAULT_VAULT_ID_MATCH, VaultSecret(password_bytes))]).decrypt(
                    bytes(ciphertext_buffer)
                )
            )
        except Exception as exc:
            raise MigrationError("encrypted vault could not be decrypted") from exc
        document = _parse_document(plaintext_buffer)

        legacy_present = LEGACY_KEY in document
        new_present = [key for key in NEW_KEYS if key in document]
        if not legacy_present and len(new_present) == len(NEW_KEYS):
            _validate_candidate(document, rules, validator)
            return
        if not legacy_present or new_present:
            raise MigrationError("vault credential state is ambiguous")

        _apply_migration(document)
        _validate_candidate(document, rules, validator)
        try:
            serialized_buffer = bytearray(yaml.safe_dump(
                document, sort_keys=False, allow_unicode=False
            ).encode())
            encrypted_buffer = bytearray(
                VaultLib([(DEFAULT_VAULT_ID_MATCH, VaultSecret(password_bytes))]).encrypt(
                    bytes(serialized_buffer)
                )
            )
        except MigrationError:
            raise
        except Exception as exc:
            raise MigrationError("migrated vault could not be encrypted") from exc
        _atomic_install(EXPECTED_VAULT_PATH, bytes(encrypted_buffer),
                        bytes(ciphertext_buffer), password_bytes, document,
                        rules, validator)
    finally:
        _zero(password_buffer)
        _zero(ciphertext_buffer)
        _zero(plaintext_buffer)
        _zero(serialized_buffer)
        _zero(encrypted_buffer)
        document = None


def main(argv=None):
    parser = SafeArgumentParser(add_help=True)
    parser.add_argument("--vault", required=True)
    parser.add_argument("--vault-password-file", required=True)
    try:
        arguments = parser.parse_args(argv)
        migrate(arguments.vault, arguments.vault_password_file)
    except MigrationError as exc:
        print(f"vault migration failed: {exc}", file=sys.stderr)
        return 1
    except Exception:
        print("vault migration failed: unexpected internal error", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
