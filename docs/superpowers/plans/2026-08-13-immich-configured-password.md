# Immich Configured-Password Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the configured Immich vault passwords immediately usable by clearing the supported `shouldChangePassword` policy for the administrator and every managed user without changing any password or writing to the database.

**Architecture:** Add one focused Immich task unit that treats the administrator plus all configured managed users as a single validated batch, repairs only the password-change flag through the pinned v3 admin PATCH endpoint, and performs authoritative read-back. Keep managed-user creation explicit by sending `shouldChangePassword: false`, then extend behavioral, static, runtime, and policy tests before rebuilding the disposable fresh Mac proof.

**Tech Stack:** Ansible Core 2.21.2, Immich v3.1.0 HTTP API, Ruby fixture servers and contract tests, Docker Compose Mac proof harness.

---

## File structure

- Create `roles/immich/tasks/configured_password.yml`: isolated reconcile/verify unit for complete target discovery, schema validation, minimal PATCH, and read-back.
- Create `tests/immich_configured_password_test.rb`: real-Ansible fake-HTTP regression and lifecycle coverage for the new unit.
- Modify `roles/immich/tasks/main.yml`: invoke the unit during reconciliation and tagged verification.
- Modify `roles/immich/tasks/managed_users.yml`: explicitly disable forced password changes in fresh managed-user creation.
- Modify `tests/database_managed_users_test.rb`: protect the exact safe creation payload and separation from password repair.
- Modify `tests/contracts/immich.sh`: enforce static wiring and live login/admin-user policy for all configured accounts.
- Modify `tests/validate-policy.sh` and `tests/policy_test.rb`: register and mutation-protect the focused regression.

### Task 1: Capture the forced-password regression

**Files:**
- Create: `tests/immich_configured_password_test.rb`

- [ ] **Step 1: Build a focused fake Immich API fixture**

Create a TCP fixture that serves `GET /api/admin/users?withDeleted=true`, accepts only `PATCH /api/admin/users/{id}` with the exact body below, and updates only the selected record:

```ruby
raise "unexpected password-policy body" unless parsed == { "shouldChangePassword" => false }
record["shouldChangePassword"] = false
[200, record]
```

Run a temporary playbook that includes `roles/immich/tasks/configured_password.yml` with an administrator, two non-admin managed users, an administrator bearer token, and `immich_configured_password_phase` set to `reconcile` or `verify`.

- [ ] **Step 2: Add failing lifecycle and safety cases**

Cover all of these assertions in the test:

```ruby
# true administrator + true managed users: exactly one minimal PATCH per target
# a second reconcile plus verify: zero additional PATCH calls
# malformed shouldChangePassword on any target: zero PATCH calls
# duplicate normalized managed email: zero PATCH calls
# managed target with isAdmin=true: zero PATCH calls
# missing configured target: zero PATCH calls
# check mode: plan output, zero PATCH calls
# verify mode with true flag: failure, zero PATCH calls
# no request body contains password or isAdmin
```

- [ ] **Step 3: Run the focused test and record RED**

Run:

```bash
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" \
  ruby tests/immich_configured_password_test.rb
```

Expected: FAIL because `roles/immich/tasks/configured_password.yml` does not exist and no password-policy PATCH occurs.

### Task 2: Implement supported API reconciliation

**Files:**
- Create: `roles/immich/tasks/configured_password.yml`
- Modify: `roles/immich/tasks/main.yml`
- Modify: `roles/immich/tasks/managed_users.yml`
- Modify: `tests/database_managed_users_test.rb`

- [ ] **Step 1: Add explicit fresh-user creation policy**

Change the existing managed-user creation body to exactly:

```yaml
body:
  email: "{{ item.email }}"
  password: "{{ item.password }}"
  name: "{{ item.name }}"
  shouldChangePassword: false
```

Update the static assertion to require that key while continuing to reject `isAdmin` and any password field in existing-user repair bodies.

- [ ] **Step 2: Implement complete target preflight**

In `configured_password.yml`, list the complete admin inventory with the supplied bearer token, build the desired normalized email set from `vault_immich_admin_email` plus `vault_managed_immich_users`, and require before mutation:

```yaml
- listing is a list
- every configured normalized email resolves exactly once
- every target ID matches the existing safe UUID contract
- every target is active
- every target exposes boolean isAdmin and shouldChangePassword
- the vault administrator is an administrator
- every configured managed user is not an administrator
```

Keep all requests and derived identity maps `no_log: true`.

- [ ] **Step 3: Add minimal reconcile/check behavior**

For each target whose flag is true, report `IMMICH_PLAN_CONFIGURED_PASSWORD` in check mode. Outside check mode and only in the reconcile phase, send:

```yaml
method: PATCH
body_format: json
body:
  shouldChangePassword: false
status_code: [200]
```

Do not include `password`, `isAdmin`, email, name, quota, or preference fields.

- [ ] **Step 4: Add authoritative read-back**

After reconciliation, repeat the complete user listing and schema/identity checks, then require every configured record to have `shouldChangePassword == false`. In verify phase, perform the same reads and assertions without a PATCH path.

- [ ] **Step 5: Wire reconcile and tagged verification**

After managed-user reconciliation in `main.yml`, include:

```yaml
- name: Reconcile configured Immich passwords
  ansible.builtin.include_tasks: configured_password.yml
  vars:
    immich_configured_password_phase: reconcile
    immich_configured_password_token: "{{ immich_reconcile_token }}"
```

After managed-user verification, add the corresponding include with `apply.tags: [platform_verify_immich]`, phase `verify`, and `immich_verification_token`.

- [ ] **Step 6: Run focused GREEN checks**

Run:

```bash
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" \
  ruby tests/immich_configured_password_test.rb
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" \
  ruby tests/database_managed_users_test.rb
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" \
  ansible-playbook -i inventory/hosts.yml site.yml --syntax-check
```

Expected: all commands exit 0.

### Task 3: Protect static, live, and CI contracts

**Files:**
- Modify: `tests/contracts/immich.sh`
- Modify: `tests/validate-policy.sh`
- Modify: `tests/policy_test.rb`

- [ ] **Step 1: Add static role assertions**

Require both includes, exact reconcile/verify phases, redacted API tasks, full-target preflight before the first password-policy PATCH, exact minimal PATCH body, authoritative read-back, and absence of database operations in `configured_password.yml`.

- [ ] **Step 2: Strengthen the live Immich contract**

For the administrator login and each managed-user login, require:

```ruby
session.fetch("shouldChangePassword") == false
```

For administrator and managed-user authoritative records, require a real boolean and exact false. Preserve all existing onboarding, preference, role, avatar, storage-label, and credential assertions.

- [ ] **Step 3: Register the focused regression exactly once**

Add this command once to `tests/validate-policy.sh`:

```sh
ruby tests/immich_configured_password_test.rb
```

Add the same exact command to the required validation-command inventory in `tests/policy_test.rb` so removing it causes policy failure.

- [ ] **Step 4: Run focused and policy checks**

Run:

```bash
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" \
  ruby tests/immich_configured_password_test.rb
tests/contracts/immich.sh static mac
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" \
  ruby tests/policy_test.rb
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" \
  ansible-lint --strict roles/immich
git diff --check
```

Expected: all commands exit 0.

### Task 4: Verify, commit, and rebuild manual validation

**Files:**
- Modify only files listed in Tasks 1-3.

- [ ] **Step 1: Run the full repository verification gate**

Run:

```bash
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" \
  tests/validate-policy.sh
```

Expected: exit 0. Investigate any failure before claiming completion.

- [ ] **Step 2: Commit the implementation**

Run:

```bash
git add roles/immich/tasks/configured_password.yml \
  roles/immich/tasks/main.yml roles/immich/tasks/managed_users.yml \
  tests/immich_configured_password_test.rb tests/database_managed_users_test.rb \
  tests/contracts/immich.sh tests/validate-policy.sh tests/policy_test.rb
git commit -m "fix: use configured Immich passwords immediately"
```

The commit must contain no `Co-Authored-By` trailer.

- [ ] **Step 3: Remove the superseded disposable sandbox**

Verify the exact prior sandbox path and then run:

```bash
tests/mac/cleanup.sh \
  /private/var/folders/z6/qvbh9dlx2_s98lt4__4fwg9m0000gn/T/nas-platform-mac.NrJy1O
```

Expected: the prior project containers and sandbox are removed by the repository cleanup workflow.

- [ ] **Step 4: Run a new fresh proof to the manual boundary**

Run:

```bash
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" \
tests/mac/run.sh \
  --lane fresh \
  --manual-validation \
  --vault-file "$HOME/.config/nas-platform/vault.yml" \
  --vault-password-file "$HOME/.config/nas-platform/vault-password"
```

Expected: deployment, idempotence, verification, and runtime contracts pass; the runner stops at the durable manual-validation handoff and leaves services running.

- [ ] **Step 5: Hand off exact login information**

Report the new sandbox path, service URLs, configured usernames, quoted resume command, and cleanup command. Ask the user to confirm that the administrator and Family accounts enter Immich directly with their existing vault passwords and without either onboarding screen.
