#!/usr/bin/env python3
"""Direct and Ansible-fixture tests for atomic no-follow file reads."""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = pathlib.Path(
    os.environ.get("ATOMIC_SAFE_SLURP_MODULE", ROOT / "library" / "atomic_safe_slurp.py")
)


def load_module():
    spec = importlib.util.spec_from_file_location("atomic_safe_slurp", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("atomic safe-slurp module cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


module = load_module()
with tempfile.TemporaryDirectory(prefix="nas-platform-safe-slurp-") as directory:
    root = pathlib.Path(directory)
    regular = root / "regular"
    replacement = root / "replacement"
    symlink = root / "symlink"
    oversized = root / "oversized"
    absent = root / "absent"
    regular.write_bytes(b"original-content")
    replacement.write_bytes(b"replacement-content")
    symlink.symlink_to(regular)
    oversized.write_bytes(b"x" * 65)

    exists, content = module.read_regular_file(str(regular), 64)
    assert exists and content == b"original-content"
    exists, content = module.read_regular_file(str(absent), 64)
    assert not exists and content == b""

    try:
        module.read_regular_file(str(symlink), 64)
    except module.SafeReadError:
        pass
    else:
        raise AssertionError("atomic reader accepted a symlink")

    original_open = module.os.open

    def swapping_open(path, flags):
        descriptor = original_open(path, flags)
        os.replace(replacement, regular)
        return descriptor

    module.os.open = swapping_open
    try:
        exists, content = module.read_regular_file(str(regular), 64)
    finally:
        module.os.open = original_open
    assert exists and content == b"original-content"
    assert regular.read_bytes() == b"replacement-content"

    try:
        module.read_regular_file(str(oversized), 64)
    except module.SafeReadError:
        pass
    else:
        raise AssertionError("atomic reader accepted an oversized file")

    fixture_regular = root / "fixture-regular"
    fixture_symlink = root / "fixture-symlink"
    fixture_oversized = root / "fixture-oversized"
    fixture_regular.write_text("regular-content", encoding="utf-8")
    fixture_symlink.symlink_to(fixture_regular)
    fixture_oversized.write_bytes(b"x" * 65)
    variables = root / "vars.json"
    variables.write_text(
        json.dumps(
            {
                "safe_slurp_regular_path": str(fixture_regular),
                "safe_slurp_absent_path": str(root / "fixture-absent"),
                "safe_slurp_symlink_path": str(fixture_symlink),
                "safe_slurp_oversized_path": str(fixture_oversized),
            }
        ),
        encoding="utf-8",
    )
    result = subprocess.run(
        [
            "ansible-playbook", "-i", "localhost,", "-c", "local",
            str(ROOT / "tests" / "safe_slurp_test.yml"), "-e",
            "@" + str(variables),
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "ANSIBLE_NOCOLOR": "1", "PYTHONDONTWRITEBYTECODE": "1"},
    )
    if result.returncode != 0:
        raise AssertionError(
            "atomic safe-slurp Ansible fixture failed\n" + result.stdout + result.stderr
        ) from None

print("atomic safe-slurp: no-follow, path-swap, absence, and bounds hold")
