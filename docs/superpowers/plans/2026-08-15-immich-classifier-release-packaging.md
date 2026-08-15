# Immich Classifier Release Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the canonical Immich restore classifier inside every immutable release and make all runtime and verification paths consume that deployed copy.

**Architecture:** Move the only classifier source to `services/immich/classify_restore.py`, validate it as a controller input, copy it into the immutable service directory with mode `0644`, and record its exact checksum and mode in the deployment manifest. The Immich role validates and executes only `platform_current_dir/services/immich/classify_restore.py`; executable fixtures build a real release tree and prove missing or modified release helpers fail closed.

**Tech Stack:** Ansible, Python 3, Ruby executable contracts, Docker Compose validation.

---

### Task 1: Encode the release-boundary regression

**Files:**
- Create: `tests/immich_release_helper_test.rb`
- Modify: `tests/immich_restore_quality_test.rb`
- Modify: `tests/immich_restore_lifecycle_test.rb`
- Modify: `tests/immich_restore_classifier_test.py`

- [ ] Add a bundle fixture that deploys a committed controller checkout and asserts `current/services/immich/classify_restore.py` has the controller bytes, mode `0644`, and matching manifest checksum/mode.
- [ ] Add missing-controller, modified-release, and missing-release cases that require nonzero Ansible status and preserve the active release/pointer.
- [ ] Require both role invocations to use `{{ platform_current_dir }}/services/immich/classify_restore.py` and add a mutation that restores the invalid `roles/immich/files` path.
- [ ] Construct `release/services/immich/classify_restore.py` in the lifecycle fixture and set `platform_current_dir` to that release.
- [ ] Change the classifier unit import to `services/immich/classify_restore.py`.
- [ ] Run the focused tests and observe failures caused by absent packaging and the old runtime path.

### Task 2: Package one canonical helper

**Files:**
- Move: `roles/immich/files/classify_restore.py` to `services/immich/classify_restore.py`
- Modify: `roles/deployment_bundle/tasks/inputs.yml`
- Modify: `roles/deployment_bundle/tasks/main.yml`
- Modify: `roles/deployment_bundle/templates/manifest.yml.j2`
- Modify: `tests/verify_deployment_manifest.rb`
- Modify: `roles/immich/tasks/main.yml`
- Modify: `roles/immich/tasks/restore.yml`

- [ ] Validate the canonical classifier as a required regular, non-symlink controller input.
- [ ] Inspect and copy it into `services/immich/classify_restore.py` in staging with exact mode `0644`.
- [ ] Add runtime helper checksum and mode records to the manifest and verifier, retaining the existing Dozzle helper as a declared bundled runtime file.
- [ ] Add the deployed helper to Immich target containment and use that path for classification and restored-asset verification.
- [ ] Run classifier, quality, lifecycle, release-helper, manifest, and target-validator tests until GREEN.

### Task 3: Register and mutation-protect the contract

**Files:**
- Modify: `tests/validate-policy.sh`
- Modify: `tests/policy_test.rb`
- Modify: `tests/policy_manifest_test.rb`

- [ ] Register the immutable-release helper test exactly once.
- [ ] Add policy assertions and mutations for controller validation, staging copy, manifest checksum/mode, target path, and canonical source uniqueness.
- [ ] Run policy mutation tests and the full policy suite until GREEN.

### Task 4: Verify and commit

**Files:**
- Verify all modified files and generated release behavior.

- [ ] Run classifier, Immich quality/lifecycle/release tests, deployment bundle contracts, full policy, syntax, lint, both Compose renders, and `git diff --check`.
- [ ] Confirm no old role-local classifier or dirty worktree remains after commit.
- [ ] Commit without a `Co-Authored-By` footer and report the SHA plus exact results.
