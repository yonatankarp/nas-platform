# Production Auto-Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically deploy each exact `main` commit on the NAS once that commit's GitHub Actions push CI succeeds.

**Architecture:** A standard-library Python poller installed on the NAS checks anonymous Git and GitHub Actions every five minutes, then invokes the existing Ansible deployment and verification through `inventory/local.yml`. A dedicated installation playbook atomically installs the launcher, poller, cron entry, configuration, protected notifier material, and private state only after the initial production deployment has been manually verified.

**Tech Stack:** Python 3 standard library, POSIX shell, Ansible Core 2.21.2, Git HTTPS, GitHub REST API, ntfy, Ruby/Python/shell tests.

---

## File structure

- Create `scripts/production_auto_deploy.py`: CI gate, exact checkout, tooling, locking, deployment, state, logs, notifications, and CLI.
- Create `scripts/nas-platform-deploy`: stable installed launcher.
- Create `controller-requirements.txt`: exact controller Python pins.
- Create `roles/production_auto_deploy/{defaults,meta,tasks,templates}`: NAS-only atomic installer.
- Create `install-production-auto-deploy.yml`: explicit bootstrap/update playbook.
- Create `tests/production_auto_deploy_test.py`: disposable poller behavior tests.
- Create `tests/production_auto_deploy_role_test.rb`: installer contract tests.
- Modify policy, CI, documentation, and documentation tests to register and explain the feature.

### Task 1: Build the exact CI eligibility gate

**Files:**
- Create: `scripts/production_auto_deploy.py`
- Create: `tests/production_auto_deploy_test.py`

- [ ] **Step 1: Write failing CI-gate tests**

Create a `unittest` harness with a private temporary root, fake `git`, fake
Ansible/curl commands, and a loopback GitHub server. Use this exact config shape:

```python
config = {
    "repository": "yonatankarp/nas-platform",
    "repository_url": "https://github.com/yonatankarp/nas-platform.git",
    "workflow": "ci.yml",
    "workflow_name": "CI",
    "branch": "main",
    "controller_root": str(root / "controller"),
    "tooling_root": str(root / "tooling"),
    "state_root": str(root / "state"),
    "log_root": str(root / "logs"),
    "vault_file": str(root / "protected/vault.yml"),
    "vault_password_file": str(root / "protected/vault-password"),
    "ntfy_curl_config": str(root / "protected/ntfy.curl"),
    "platform_nas_address": "192.168.0.139",
    "platform_public_host": "192.168.0.139",
    "platform_callback_host": "192.168.0.139",
    "github_api_base": server.url,
    "log_retention_count": 20,
    "log_retention_days": 30,
}
```

Cover exact successful push CI, pending/failed/cancelled/absent/rate-limited CI,
wrong repository/workflow/name/branch/event/SHA/types, ambiguous duplicate runs,
credentialed/non-HTTPS remotes, malformed JSON, oversized responses, and unknown
CLI arguments. Every rejection must assert zero Ansible/state mutations and a
fixed diagnostic without response-body content.

- [ ] **Step 2: Run RED**

```sh
.venv/bin/python -m unittest -v tests.production_auto_deploy_test
```

Expected: FAIL because the poller is absent.

- [ ] **Step 3: Implement typed config and CI eligibility**

Implement frozen `Config` and `CiRun` dataclasses. `Config` has one typed field
for every exact JSON key in Step 1. `CiRun` has string fields `head_sha`,
`status`, `conclusion`, `event`, `head_branch`, and `name`. Add typed functions
`load_config(path)`, `resolve_main_sha(config)`, `fetch_ci_runs(config, sha)`,
`eligible_ci_run(config, sha, runs)`, and `main(argv)`.

Require HTTPS `github.com`, no URL credentials/query/fragment, and exact path
`/yonatankarp/nas-platform.git`. Resolve main with `git ls-remote --exit-code`.
Query the public endpoint for workflow `ci.yml` with `branch=main`, `event=push`,
`status=completed`, exact `head_sha`, and `per_page=10`. Accept exactly one run
whose typed fields equal the approved repository policy and conclusion success.
Bound HTTP time and body to 1 MiB; never retry inside one poll.

- [ ] **Step 4: Run GREEN and commit**

```sh
.venv/bin/python -m unittest -v tests.production_auto_deploy_test
git add scripts/production_auto_deploy.py tests/production_auto_deploy_test.py
git commit -m "feat: gate production deploys on successful CI"
```

Expected: focused tests PASS.

### Task 2: Add locking, atomic state, quarantine, and retry

**Files:**
- Modify: `scripts/production_auto_deploy.py`
- Modify: `tests/production_auto_deploy_test.py`

- [ ] **Step 1: Write failing state tests**

Add tests proving simultaneous polls produce one attempt, successful SHA is
never repeated, failed SHA is quarantined, newer successful B proceeds after
failed A, and explicit retry accepts only the exact current quarantined SHA with
successful CI. Add real filesystem mutations for symlink, wrong owner/mode,
external target, interrupted temporary write, and status-mode non-disclosure.

- [ ] **Step 2: Run RED**

Run Task 1's unittest command. Expected: new state tests FAIL.

- [ ] **Step 3: Implement state primitives**

Add a `deployment_lock(config)` context manager plus typed
`read_sha_state(path)`, `write_sha_state(path, sha, timestamp, outcome)`,
`poll(config, retry_sha=None)`, and `print_status(config)` functions.

Use `O_NOFOLLOW`, owner/mode/realpath checks, and `fcntl.flock(LOCK_EX|LOCK_NB)`.
Write mode-0600 state through same-directory temporary file, `fsync`, atomic
rename, and parent `fsync`. State JSON has exactly `sha`, UTC RFC3339
`timestamp`, and `outcome`. `--status` performs no network or deployment work.
`--retry-failed SHA` rechecks current main and exact successful CI; it cannot
deploy an older commit or bypass quarantine/CI.

- [ ] **Step 4: Run GREEN and commit**

```sh
.venv/bin/python -m unittest -v tests.production_auto_deploy_test
git add scripts/production_auto_deploy.py tests/production_auto_deploy_test.py
git commit -m "feat: quarantine failed production revisions"
```

### Task 3: Deploy the exact SHA with atomic tooling

**Files:**
- Create: `controller-requirements.txt`
- Modify: `scripts/production_auto_deploy.py`
- Modify: `tests/production_auto_deploy_test.py`

- [ ] **Step 1: Write failing execution tests**

Test clean detached checkout, dirty checkout, wrong remote, submodule, alternate
Git object environment, SHA mismatch, tooling identity/publication, exact play
order, and stop-on-first-failure. Require this order:

```python
plays = [
    "validate-vault.yml",
    "site.yml",
    "verify.yml",
    "install-production-auto-deploy.yml",
]
```

Each uses the absolute password file, `-e @<vault>`, and
`-e platform_vault_file=<vault>`; the latter three use
`-i inventory/local.yml`. Site failure skips verify/installer; verify failure
skips installer; installer failure retains the previous launcher and
quarantines. Require a minimal environment with platform addresses and no
adoption, parity, legacy, or ambient Ansible variables.

- [ ] **Step 2: Run RED**

Run Task 1's unittest command. Expected: execution tests FAIL.

- [ ] **Step 3: Add authoritative pins**

Create exactly:

```text
ansible-core==2.21.2
ansible-lint==26.6.0
```

- [ ] **Step 4: Implement checkout, tooling, and execution**

Add typed `prepare_checkout(config, sha)`, `tooling_identity(checkout)`,
`prepare_tooling(config, checkout)`, and `deploy_candidate(config, sha, log)`
functions. Return an immutable `Tooling` value containing the absolute
`ansible-playbook`, Python, and collections paths.

Refuse dirty status, `.gitmodules`, alternate object stores, wrong origin, or
SHA mismatch. Fetch only origin main and detach-checkout exact SHA. Hash
length-prefixed bytes of `controller-requirements.txt` and `requirements.yml`;
build a private staging venv/collection tree, validate it, then atomically
publish `tooling/<hash>`. Run subprocesses as argument arrays with fixed cwd,
minimal environment, process-group timeout/signal cleanup, and output only to
the protected attempt log.

- [ ] **Step 5: Run GREEN and commit**

```sh
.venv/bin/python -m unittest -v tests.production_auto_deploy_test
git add controller-requirements.txt scripts/production_auto_deploy.py \
  tests/production_auto_deploy_test.py
git commit -m "feat: deploy successful revisions on the NAS"
```

### Task 4: Protect logs and publish best-effort notifications

**Files:**
- Modify: `scripts/production_auto_deploy.py`
- Modify: `tests/production_auto_deploy_test.py`

- [ ] **Step 1: Write failing log/notification tests**

Test mode-0600 logs, bounded rotation, regular latest-pointer file, external
symlink preservation, credential redaction, durable-state-before-notification,
notification failure independence, and signal cleanup. Seed distinct vault,
password, Authorization, and token sentinels and assert none appear in output,
state, filenames, or logs.

- [ ] **Step 2: Run RED**

Run Task 1's unittest command. Expected: new tests FAIL.

- [ ] **Step 3: Implement logging and notification**

Add an `attempt_log(config, sha)` context manager plus typed
`redact(chunk, protected_values)`, `rotate_logs(config, now)`, and
`notify(config, outcome, sha, started, finished, log_path)` functions.

Use exact `attempt-<UTC>-<sha>.log` names with `O_EXCL|O_NOFOLLOW`; retain newest
20 and files under 30 days, operating only on exact regular filenames. Invoke
curl with `--config <protected-file>` and JSON on stdin so credentials never
enter argv. Record state before notifying. Catch notification errors and emit
only `deployment notification could not be delivered`.

- [ ] **Step 4: Run GREEN and commit**

```sh
.venv/bin/python -m unittest -v tests.production_auto_deploy_test
git add scripts/production_auto_deploy.py tests/production_auto_deploy_test.py
git commit -m "feat: report automatic deployment outcomes"
```

### Task 5: Install the poller on NAS only

**Files:**
- Create: `scripts/nas-platform-deploy`
- Create: `roles/production_auto_deploy/defaults/main.yml`
- Create: `roles/production_auto_deploy/meta/argument_specs.yml`
- Create: `roles/production_auto_deploy/tasks/main.yml`
- Create: `roles/production_auto_deploy/templates/config.json.j2`
- Create: `roles/production_auto_deploy/templates/ntfy.curl.j2`
- Create: `install-production-auto-deploy.yml`
- Create: `tests/production_auto_deploy_role_test.rb`

- [ ] **Step 1: Write failing real-Ansible installer tests**

Use disposable homes to prove non-NAS and root fail before mutation; protected
inputs require regular non-symlink owner-only files; installed dirs/files are
0700/0600; JSON contains no secrets; curl config is no-log; cron is exactly one
`*/5` entry; check mode creates nothing; second run is idempotent; injected
staging/activation failure retains the prior complete launcher/poller pair.

- [ ] **Step 2: Run RED**

```sh
PATH="$PWD/.venv/bin:$PATH" ruby tests/production_auto_deploy_role_test.rb
```

Expected: FAIL because the role/playbook are absent.

- [ ] **Step 3: Implement the stable launcher**

The template-equivalent behavior is:

```sh
#!/bin/sh
set -eu
exec "/absolute/deployer/home/.local/libexec/nas-platform/production_auto_deploy.py" \
  --config "/absolute/deployer/home/.config/nas-platform/deployer.json" "$@"
```

Render literal validated paths; do not trust cron `HOME` or accept path env
overrides.

- [ ] **Step 4: Implement role contract and atomic installation**

Derive all paths beneath the effective non-root account home. Fix repository,
workflow, schedule `*/5 * * * *`, retention 20/30, and platform addresses.
Assert NAS, non-root, ownership, containment, types, and modes before mutation.
Stage and syntax-validate launcher, Python, JSON, and curl config, then activate
atomically with rescue preserving the previous pair. Install exactly one named
cron entry invoking only the launcher with `--poll`.

Render the mode-0600, `no_log` curl config as:

```text
url = "http://127.0.0.1:2586/nas-critical"
header = "Authorization: Bearer {{ vault_ntfy_dozzle_token }}"
header = "Content-Type: application/json"
```

The JSON config contains paths/coordinates/policy only, never the token.

- [ ] **Step 5: Implement installation playbook**

Use `hosts: platform_hosts`, facts enabled, the same external vault convention
as `site.yml`, a no-log `vault_contract` pre-task, an assertion that platform is
NAS and adoption is false/undefined, then only `production_auto_deploy`.

- [ ] **Step 6: Run GREEN, syntax/lint, and commit**

```sh
PATH="$PWD/.venv/bin:$PATH" ruby tests/production_auto_deploy_role_test.rb
.venv/bin/ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml --syntax-check
.venv/bin/ansible-lint --strict roles/production_auto_deploy install-production-auto-deploy.yml
sh -n scripts/nas-platform-deploy
git add scripts/nas-platform-deploy roles/production_auto_deploy \
  install-production-auto-deploy.yml tests/production_auto_deploy_role_test.rb
git commit -m "feat: install the NAS deployment poller"
```

Expected: tests/syntax pass; lint reports zero failures/warnings.

### Task 6: Mutation-protect policy and CI registration

**Files:**
- Modify: `tests/validate-policy.sh`
- Modify: `tests/policy_test.rb`
- Modify: `tests/policy_manifest_test.rb`
- Modify: `tests/ci/workflow_test.rb`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write failing registration/mutation checks**

Require the Python and role suites exactly once in policy and CI, plus syntax
check of `install-production-auto-deploy.yml`. Mutants must reject missing test
commands, wrong cadence, weakened exact SHA/CI match, PAT/credentialed URL,
automatic retry, missing verify, missing NAS gate, weak modes/no-log, or token
in argv, each with fixed diagnostics and no stack trace.

- [ ] **Step 2: Run RED**

```sh
ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
ruby tests/ci/workflow_test.rb
```

Expected: new registration checks FAIL.

- [ ] **Step 3: Register exact commands without deployment permissions**

Register:

```sh
.venv/bin/python -m unittest -v tests.production_auto_deploy_test
ruby tests/production_auto_deploy_role_test.rb
ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml --syntax-check
```

Keep GitHub workflow permissions `contents: read`; add no deployment job,
runner, PAT, secret, or write permission.

- [ ] **Step 4: Run GREEN and commit**

```sh
ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
ruby tests/ci/workflow_test.rb
tests/validate-policy.sh
git add .github/workflows/ci.yml tests/validate-policy.sh tests/policy_test.rb \
  tests/policy_manifest_test.rb tests/ci/workflow_test.rb
git commit -m "test: enforce production deployment polling"
```

### Task 7: Document bootstrap and operations

**Files:**
- Modify: `docs/getting-started-nas.md`
- Modify: `docs/secrets.md`
- Modify: `README.md`
- Modify: `tests/secrets_docs_test.rb`

- [ ] **Step 1: Write failing docs contracts**

Require exact initial `site.yml`, `verify.yml`, installer, `--status`, `--poll`,
`--retry-failed "$FAILED_SHA"`, and `crontab -l` commands. Require statements
covering first manual bootstrap, five-minute polling, exact successful main push
CI, no PAT, no same-SHA auto retry, newer-SHA progression, optional SSH disable,
protected logs, and safe removal boundaries.

- [ ] **Step 2: Run RED**

```sh
ruby tests/secrets_docs_test.rb
tests/validate-docs.sh
```

Expected: documentation assertions FAIL.

- [ ] **Step 3: Write the operator guide**

Document in order: dedicated non-root account/Docker access; vault/password
placement; controller clone outside `/volume1/Docker/nas-platform`; pinned
tooling; manual vault/site/verify; installer play; cron/status/no-op poll;
automatic flow; logs/ntfy; exact current-SHA retry; SSH disable; automation
disable/removal without deleting services, data, or immutable releases. Add a
README summary and make secrets.md state that vault/password remain private NAS
inputs never committed or logged.

- [ ] **Step 4: Run GREEN and commit**

```sh
ruby tests/secrets_docs_test.rb
tests/validate-docs.sh
git add README.md docs/getting-started-nas.md docs/secrets.md tests/secrets_docs_test.rb
git commit -m "docs: explain automatic NAS deployments"
```

### Task 8: Full verification and two-commit rehearsal

**Files:**
- Modify only files from Tasks 1–7 if a failing test proves a scoped defect.

- [ ] **Step 1: Run focused tests repeatedly**

```sh
for run in 1 2 3 4 5; do
  .venv/bin/python -m unittest -v tests.production_auto_deploy_test || exit 1
done
PATH="$PWD/.venv/bin:$PATH" ruby tests/production_auto_deploy_role_test.rb
```

- [ ] **Step 2: Run full verification**

```sh
.venv/bin/ansible-playbook -i inventory/local.yml site.yml --syntax-check
.venv/bin/ansible-playbook -i inventory/local.yml verify.yml --syntax-check
.venv/bin/ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml --syntax-check
.venv/bin/ansible-lint --strict
find scripts tests -type f -name '*.sh' -exec sh -n {} +
.venv/bin/python -m py_compile scripts/production_auto_deploy.py tests/production_auto_deploy_test.py
tests/validate-policy.sh
tests/validate-docs.sh
git diff --check
```

Expected: every command exits 0; lint has zero failures/warnings.

- [ ] **Step 3: Run exact A-fails/B-succeeds rehearsal**

The fake integration must assert:

```text
A first poll: site=1, verify=0, installer=0, failed=1
A second poll: site=0
B poll: site=1, verify=1, installer=1, successful=1
notifications: A=failure, B=success
```

Run the named unittest case for newer B after failed A and require PASS.

- [ ] **Step 4: Review scope, trailers, and secrets**

```sh
git status --short
git diff --check
git log --format='%h %s%n%b' --max-count=8
rg -n "Co-Authored-By|github_pat_|ghp_|Authorization: Bearer [A-Za-z0-9]" \
  scripts roles/production_auto_deploy install-production-auto-deploy.yml \
  docs/getting-started-nas.md README.md
```

Expected: intended files only, no Co-Authored-By, no PAT/literal token, and only
the notifier template's Jinja variable reference.

- [ ] **Step 5: Commit only a test-proven final correction**

If Steps 1–4 required a correction:

List the correction with `git diff --name-only`, stage only the individual
Task 1–7 paths shown by that command, and commit them with:

```sh
git commit -m "fix: harden production deployment polling"
```

Otherwise do not create an empty commit.

## Self-review

- Coverage: every approved design requirement maps to a task, including exact
  CI identity, anonymous HTTPS, five-minute cadence, locking, atomic tooling,
  one attempt, quarantine, newer commit progression, explicit retry, local
  Ansible, verify-before-poller-activation, notification, bootstrap, SSH
  disablement, safe removal, and mutation tests.
- Consistency: `Config`, `CiRun`, CLI modes, state fields, play order, and paths
  use identical names across implementation, installer, policy, and docs.
- Scope: no Portainer authority, inbound webhook, self-hosted runner, PAT,
  migration, database mutation, or automatic rollback is included.
