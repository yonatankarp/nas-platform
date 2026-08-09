# Config-Managed Users Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Dozzle and ntfy managed-user reconciliation refuse ambiguous identity adoption and password replacement before any configuration mutation.

**Architecture:** A strict controller-side YAML filter validates Dozzle’s existing document without aliases, duplicate keys, or multiple documents. ntfy treats the prior runtime `.env` as the declarative ownership record and uses the pinned v2.27 `ntfy user list` CLI against the existing auth database to distinguish safe creation from unmanaged-name collisions before rendering or deployment.

**Tech Stack:** Ansible, community.docker 5.2.1, PyYAML SafeLoader, Ruby contract tests.

---

### Task 1: Pin the expanded ntfy list interface

**Files:**
- Modify: `config/managed-user-capabilities.yml`
- Modify: `tests/managed_user_capabilities_test.rb`

- [ ] Write a failing capability test requiring `NTFY_AUTH_USERS and ntfy user list` as the exact ntfy list interface.
- [ ] Run `ruby tests/managed_user_capabilities_test.rb` and observe the old declarative-only value fail.
- [ ] Update the matrix and run normal plus mutation self-test to green.

### Task 2: Validate existing Dozzle YAML semantically

**Files:**
- Create: `filter_plugins/managed_user_state.py`
- Create: `tests/managed_user_state_filter_test.py`
- Modify: `roles/dozzle/tasks/managed_users.yml`
- Modify: `tests/config_managed_users_test.rb`
- Modify: `tests/policy_manifest_test.rb`

- [ ] Write failing direct filter tests for malformed syntax, aliases, exact duplicate keys, normalized duplicate user keys, multiple documents, and arbitrary unmanaged values.
- [ ] Add failing Dozzle reconciliation tests for existing null, empty scalar, empty list, and missing-password entries.
- [ ] Run focused tests and observe duplicate documents and zero-length entries being accepted.
- [ ] Implement a `yaml.SafeLoader`-based filter that rejects anchors/aliases and duplicate semantic keys, then make Dozzle track normalized-key membership independently from entry length.
- [ ] Run filter and Dozzle tests to green.

### Task 3: Refuse unsafe ntfy adoption before mutation

**Files:**
- Modify: `roles/ntfy/tasks/managed_users.yml`
- Modify: `roles/ntfy/tasks/main.yml`
- Modify: `tests/config_managed_users_test.rb`

- [ ] Add failing tests that require safe prior `.env` inspection, exact owned-hash comparison, `ntfy user list` parsing, unmanaged-name refusal, authoritative absence for creation, fail-closed existing-state handling, and all guards before template/deploy.
- [ ] Implement preflight state checks and use `community.docker.docker_compose_v2_run` with the prior environment to execute `user --auth-file=/var/lib/ntfy/auth.db --auth-default-access=deny-all list` without starting the service.
- [ ] Parse only v2.27’s exact `user NAME (role: ROLE, tier: ...[, server config])` records, reject malformed/duplicate output, and classify desired users as owned, unmanaged collision, safely absent, or unprovable.
- [ ] Assert owned hashes exactly match and refuse unmanaged adoption before rendering the new `.env`.
- [ ] Run provision and verify-path fixtures to green.

### Task 4: Register and verify fail-closed coverage

**Files:**
- Modify: `tests/validate-policy.sh`
- Modify: `tests/config_managed_users_test.rb`
- Modify: `tests/policy_manifest_test.rb`

- [ ] Make the focused contract fail clearly when Ansible execution dependencies are absent instead of silently skipping behavior.
- [ ] Extend mutation self-test across parser, ordering, authentication, collision, and ownership guards.
- [ ] Run focused normal/self-test, capability tests, filter tests, Dozzle static/quality, policy/manifest, syntax checks, and `git diff --check`.
- [ ] Commit corrections without a co-author trailer.
