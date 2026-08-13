# Immich Per-User Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every configured Immich administrator and managed user enters the application without the first-login wizard.

**Architecture:** Reconcile per-user onboarding exclusively through Immich 3.1.0's authenticated self-service API. Authenticate and pre-read every configured account before mutation, update only false states, then authoritatively re-read all accounts; verification and the runtime contract perform the same reads without mutation.

**Tech Stack:** Ansible 2.21.2, Immich 3.1.0 REST API, Ruby fake-HTTP behavioral tests, POSIX shell runtime contracts.

---

### Task 1: Add the failing per-user onboarding behavior fixture

**Files:**
- Create: `tests/immich_user_onboarding_test.rb`
- Modify: `tests/validate-policy.sh`
- Modify: `tests/policy_test.rb`

- [ ] **Step 1: Write the failing behavioral test**

Create a temporary inventory and fake Immich HTTP server. Run a play that includes
`roles/immich/tasks/user_onboarding.yml` with one administrator and one managed
non-administrator. Implement these exact fake API behaviors:

```ruby
case [request.request_method, request.path]
when ["POST", "/api/auth/login"]
  account = accounts.fetch(request.json.fetch("email"))
  [201, { "accessToken" => account.fetch(:token),
          "userEmail" => request.json.fetch("email"),
          "isAdmin" => account.fetch(:admin),
          "isOnboarded" => account.fetch(:onboarded) }]
when ["GET", "/api/users/me/onboarding"]
  account = accounts.values.find { |entry| "Bearer #{entry.fetch(:token)}" == request.authorization }
  [200, { "isOnboarded" => account.fetch(:onboarded) }]
when ["PUT", "/api/users/me/onboarding"]
  account = accounts.values.find { |entry| "Bearer #{entry.fetch(:token)}" == request.authorization }
  account[:onboarded] = request.json.fetch("isOnboarded")
  [200, { "isOnboarded" => account.fetch(:onboarded) }]
end
```

Assert both initially-false users receive exactly one PUT with the exact body,
the final GET for each returns true, and a second include performs zero PUTs.
Add cases proving a rejected second login or malformed second GET causes zero
PUTs for either account. Run verification mode and assert it performs only
POST/GET requests and fails if either account is false.

- [ ] **Step 2: Run the behavior fixture and verify RED**

Run:

```bash
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" ruby tests/immich_user_onboarding_test.rb
```

Expected: FAIL because `roles/immich/tasks/user_onboarding.yml` and its lifecycle are absent.

- [ ] **Step 3: Register the test in policy**

Add exactly one `ruby tests/immich_user_onboarding_test.rb` command to
`tests/validate-policy.sh`, and extend `tests/policy_test.rb` to require it once.

- [ ] **Step 4: Commit the RED test**

```bash
git add tests/immich_user_onboarding_test.rb tests/validate-policy.sh tests/policy_test.rb
git commit -m "test: reproduce Immich user onboarding wizard"
```

### Task 2: Reconcile onboarding through the supported user API

**Files:**
- Create: `roles/immich/tasks/user_onboarding.yml`
- Modify: `roles/immich/tasks/main.yml`

- [ ] **Step 1: Build the exact configured account list**

In `user_onboarding.yml`, define the administrator followed by managed users:

```yaml
- name: Resolve configured Immich onboarding accounts
  ansible.builtin.set_fact:
    immich_onboarding_accounts: >-
      {{ [{'email': vault_immich_admin_email,
           'password': vault_immich_admin_password,
           'is_admin': true}] +
         (vault_managed_immich_users | map('combine', {'is_admin': false}) | list) }}
  no_log: true
```

- [ ] **Step 2: Authenticate and pre-read every account before mutation**

POST `/auth/login` for every account. Validate HTTP 201, normalized email,
boolean `isAdmin`, expected administrator status, string access token, and
boolean login `isOnboarded`. GET `/users/me/onboarding` with each token and
require every response to be an exact one-key mapping with a boolean value.
No PUT task may precede the assertion over the complete GET result list.

- [ ] **Step 3: Update only incomplete users and re-read all users**

Use only the supported self endpoint:

```yaml
- name: Complete configured Immich user onboarding
  ansible.builtin.uri:
    url: "{{ immich_api }}/users/me/onboarding"
    method: PUT
    headers:
      Authorization: "Bearer {{ item.1.json.accessToken }}"
    body_format: json
    body:
      isOnboarded: true
    status_code: [200]
  loop: "{{ immich_onboarding_accounts | zip(immich_onboarding_logins.results) | list }}"
  when:
    - not ansible_check_mode
    - not immich_user_onboarding_verify_only | default(false) | bool
    - not immich_onboarding_reads.results[ansible_loop.index0].json.isOnboarded | bool
  loop_control:
    extended: true
  no_log: true
```

Then GET every account again and require the exact response
`{"isOnboarded": true}`. Keep all credential/token tasks `no_log: true`.

- [ ] **Step 4: Wire reconciliation and read-only verification**

Include `user_onboarding.yml` after managed-user reconciliation with
`immich_user_onboarding_verify_only: false`. Add a separately tagged
`platform_verify_immich` include after existing verification user checks with
`immich_user_onboarding_verify_only: true`. The verify include must not execute
the PUT task.

- [ ] **Step 5: Run the behavioral test and verify GREEN**

```bash
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" ruby tests/immich_user_onboarding_test.rb
```

Expected: PASS for repair, idempotence, global preflight, exact schema,
read-back, and read-only verification.

- [ ] **Step 6: Commit the role implementation**

```bash
git add roles/immich/tasks/main.yml roles/immich/tasks/user_onboarding.yml
git commit -m "fix: complete Immich onboarding for configured users"
```

### Task 3: Protect the live runtime contract

**Files:**
- Modify: `tests/contracts/immich.sh`
- Modify: `tests/policy_test.rb`

- [ ] **Step 1: Add a failing static/runtime assertion**

Require the supported self endpoints and reject SQL, `psql`, `user_metadata`,
or container-database mutation paths. After each configured user login, require:

```ruby
_response, onboarding = request("get", "/api/users/me/onboarding", token: access_token)
fail_contract("configured Immich user onboarding is incomplete") unless
  onboarding == { "isOnboarded" => true }
```

Assert every configured vault account is checked, not only the first.

- [ ] **Step 2: Run the static contract and verify RED**

```bash
tests/contracts/immich.sh static
```

Expected: FAIL because the static onboarding and no-database-write guarantees are absent.

- [ ] **Step 3: Complete the static/runtime contract and policy guard**

Add the supported-endpoint/no-database checks, implement the runtime loop over
the administrator plus all `vault_managed_users.immich` entries, and require
those assertions from `tests/policy_test.rb`.

- [ ] **Step 4: Run focused verification**

```bash
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" ruby tests/immich_user_onboarding_test.rb
tests/contracts/immich.sh static
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" ruby tests/database_managed_users_test.rb
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" ruby tests/policy_test.rb
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" ansible-playbook -i inventory/hosts.yml site.yml --syntax-check
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" ansible-playbook -i inventory/hosts.yml verify.yml --syntax-check
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" ansible-lint --strict roles/immich
git diff --check
```

Expected: every command exits 0; lint reports 0 failures and 0 warnings.

- [ ] **Step 5: Commit the contract**

```bash
git add tests/contracts/immich.sh tests/policy_test.rb
git commit -m "test: verify Immich user onboarding state"
```

### Task 4: Rebuild the manual-validation environment

**Files:**
- No source changes expected.

- [ ] **Step 1: Run the complete policy gate**

```bash
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" tests/validate-policy.sh
```

Expected: exit 0. If an unrelated environment-only test cannot run, record the
exact isolated reproduction and do not claim the full gate passed.

- [ ] **Step 2: Clean the rejected sandbox safely**

```bash
tests/mac/cleanup.sh /private/var/folders/z6/qvbh9dlx2_s98lt4__4fwg9m0000gn/T/nas-platform-mac.POcodC
```

Require the sandbox and its project-labeled containers to be absent. Preserve
the nonsecret report directory.

- [ ] **Step 3: Run the complete fresh proof to the handoff**

```bash
PATH="/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH" tests/mac/run.sh \
  --lane fresh \
  --manual-validation \
  --vault-file "$HOME/.config/nas-platform/vault.yml" \
  --vault-password-file "$HOME/.config/nas-platform/vault-password"
```

Expected: deployment, zero-change Ansible verification, every runtime contract,
and per-user onboarding checks pass; the command prints `Manual validation is
ready` and leaves services running.

- [ ] **Step 4: Hand off exact login details**

Report the generated URLs, configured usernames, sandbox path, resume command,
and cleanup command exactly as emitted. Do not resume until the user approves
manual validation.
