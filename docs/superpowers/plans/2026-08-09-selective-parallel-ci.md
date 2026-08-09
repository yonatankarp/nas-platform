# Selective Parallel CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the one-hour serial pull-request workflow with a lightweight required gate, fail-safe path classification, parallel integration suites, and a batched deployment-target validator.

**Architecture:** Repository-owned Ruby scripts classify changed paths and validate aggregate job results. The existing integration harness receives an explicit suite interface and conditionally executes foundation, service, smoke, and idempotence/check phases while preserving `full` as the compatibility mode. GitHub Actions runs selected suites on isolated runners and retains one stable required `validate` context.

**Tech Stack:** GitHub Actions YAML, POSIX shell, Ruby standard library, Python 3, Ansible, Docker Compose

---

## File structure

- Create `tests/ci/classify_changes.rb`: pure path-to-lane classifier plus Git diff and GitHub-output adapters.
- Create `tests/ci/classify_changes_test.rb`: table-driven classifier and rename/delete regression tests.
- Create `tests/ci/validate_results.rb`: aggregate required-gate result validator.
- Create `tests/ci/validate_results_test.rb`: accepted and rejected job-result tests.
- Create `tests/ci/workflow_test.rb`: workflow trigger, dependency, concurrency, and required-gate policy checks.
- Create `tests/integration_suite_test.sh`: suite CLI and pre-Docker rejection tests.
- Modify `tests/integration.sh`: explicit suite parsing and conditional phase dispatch.
- Create `roles/deployment_bundle/files/validate_target.py`: one-process containment validator.
- Create `tests/deployment_target_validator_test.py`: direct filesystem behavior tests for the validator.
- Modify `roles/deployment_bundle/tasks/target.yml`: replace the per-path Ansible command loop with one validator process.
- Modify `tests/validate-policy.sh`: include the new fast CI policy tests.
- Modify `.github/workflows/ci.yml`: change classification, parallel jobs, full-run events, concurrency cancellation, and aggregate `validate`.

### Task 1: Changed-path classifier

**Files:**
- Create: `tests/ci/classify_changes_test.rb`
- Create: `tests/ci/classify_changes.rb`
- Modify: `tests/validate-policy.sh`

- [ ] **Step 1: Write the failing classifier tests**

Create table-driven tests that invoke `classify(paths, full: false)` and assert exact selections for:

```ruby
{
  ["docs/getting-started.md"] => [],
  ["README.md", ".gitignore"] => [],
  ["roles/paperless_ngx/tasks/main.yml"] => %w[static smoke paperless idempotence_check],
  ["services/dozzle/compose.yml"] => %w[static smoke dozzle idempotence_check],
  ["tests/contracts/jellyfin.sh"] => %w[static smoke media idempotence_check],
  ["roles/deployment_bundle/tasks/main.yml"] => %w[static foundation smoke beszel dozzle audiobookshelf media paperless idempotence_check],
  ["unexpected/new-runtime-file"] => %w[static foundation smoke beszel dozzle audiobookshelf media paperless idempotence_check]
}
```

Also create a temporary Git repository, rename a Paperless-owned file into
`docs/`, and assert that both old and new names are classified so the Paperless
lane remains selected.

- [ ] **Step 2: Run the classifier test and verify RED**

Run: `ruby tests/ci/classify_changes_test.rb`

Expected: failure because `tests/ci/classify_changes.rb` does not exist.

- [ ] **Step 3: Implement the pure classifier and adapters**

Define these constants and public functions:

```ruby
LANES = %w[static foundation smoke beszel dozzle audiobookshelf media paperless idempotence_check].freeze
FULL_LANES = LANES.freeze

def classify(paths, full: false)
  return FULL_LANES.to_h { |lane| [lane, true] } if full
  # Start every lane false, ignore inert paths, union service mappings, and
  # select FULL_LANES for shared or unknown paths.
end

def changed_paths(base, head)
  # Parse `git diff --name-status -z --find-renames base...head` and include
  # both source and destination paths for rename/copy records.
end

def write_github_outputs(selection, io)
  LANES.each { |lane| io.puts("#{lane}=#{selection.fetch(lane)}") }
  io.puts("run_ci=#{selection.values.any?}")
  selected_tags = selected service lanes mapped to Ansible tags
  io.puts("selected_tags=#{selected_tags.join(',')}")
end
```

The CLI supports exactly one of:

```text
classify_changes.rb --files PATH...
classify_changes.rb --diff BASE HEAD
classify_changes.rb --full
```

and optionally `--github-output PATH`. Invalid combinations exit 2 before
writing output.

- [ ] **Step 4: Run classifier tests and verify GREEN**

Run: `ruby tests/ci/classify_changes_test.rb`

Expected: all classifier cases pass, including rename coverage.

- [ ] **Step 5: Add the classifier test to the policy runner**

Append:

```sh
ruby tests/ci/classify_changes_test.rb
```

to `tests/validate-policy.sh` and run it once to prove the new test is reachable.

- [ ] **Step 6: Commit**

```bash
git add tests/ci/classify_changes.rb tests/ci/classify_changes_test.rb tests/validate-policy.sh
git commit -m "test: classify selective CI lanes"
```

### Task 2: Aggregate required gate

**Files:**
- Create: `tests/ci/validate_results_test.rb`
- Create: `tests/ci/validate_results.rb`
- Modify: `tests/validate-policy.sh`

- [ ] **Step 1: Write failing result-policy tests**

Invoke the result validator with job arguments and assert:

```ruby
accepted = [
  %w[changes success],
  %w[static skipped],
  %w[paperless success]
]
rejected = [
  %w[paperless failure],
  %w[media cancelled],
  %w[smoke pending]
]
```

The error must name the job and unexpected result.

- [ ] **Step 2: Run and verify RED**

Run: `ruby tests/ci/validate_results_test.rb`

Expected: failure because the validator is absent.

- [ ] **Step 3: Implement the validator**

Implement a CLI accepting `JOB=RESULT` arguments. Accept only `success` and
`skipped`; reject missing, malformed, `failure`, `cancelled`, and unknown values.
Print a compact accepted-job summary on success.

- [ ] **Step 4: Run and verify GREEN**

Run: `ruby tests/ci/validate_results_test.rb`

Expected: all result-policy cases pass.

- [ ] **Step 5: Register and commit**

Add the test to `tests/validate-policy.sh`, run both CI policy tests, then commit:

```bash
git add tests/ci/validate_results.rb tests/ci/validate_results_test.rb tests/validate-policy.sh
git commit -m "test: enforce aggregate CI gate results"
```

### Task 3: Explicit integration suite interface

**Files:**
- Create: `tests/integration_suite_test.sh`
- Modify: `tests/integration.sh`
- Modify: `tests/validate-policy.sh`

- [ ] **Step 1: Write failing suite CLI tests**

The test runs the harness with `docker()` replaced by a function that records
unexpected access. Assert:

```sh
tests/integration.sh --list-suites
# exact output: foundation smoke beszel dozzle audiobookshelf media paperless idempotence-check full

tests/integration.sh --suite unknown site.yml
# exits 2, prints "unknown integration suite: unknown", and never invokes docker
```

Source a small dispatch-only mode and assert the tag plans:

```text
beszel => deployment_bundle,ntfy,beszel
dozzle => deployment_bundle,ntfy,dozzle
audiobookshelf => deployment_bundle,audiobookshelf
media => deployment_bundle,komga,tinymediamanager,jellyfin,immich
paperless => deployment_bundle,paperless
```

- [ ] **Step 2: Run and verify RED**

Run: `tests/integration_suite_test.sh`

Expected: `--list-suites` and `--suite` are not implemented.

- [ ] **Step 3: Add suite parsing before sandbox or Docker access**

Parse options before `acquire_integration_lock`:

```sh
integration_suite=full
selected_tags=

case "${1:-}" in
  --list-suites) printf '%s\n' 'foundation smoke beszel dozzle audiobookshelf media paperless idempotence-check full'; exit 0 ;;
  --suite) integration_suite=${2:-}; shift 2 ;;
esac
```

Validate the suite with an exhaustive `case`, derive the fixed tag list, then
parse the optional playbook. `smoke` and `idempotence-check` accept
`--tags TAGS`; other suites reject that option.

- [ ] **Step 4: Split phase dispatch without duplicating setup**

Pass `INTEGRATION_SUITE` and `INTEGRATION_TAGS` into the runner container. Add:

```sh
suite_is() {
  [ "$INTEGRATION_SUITE" = full ] || [ "$INTEGRATION_SUITE" = "$1" ]
}
```

Then make execution conditional:

- controller/symlink/stale-state scenarios: `foundation` and `full`;
- fresh converge only: `smoke`;
- Beszel scenario block: `beszel` and `full`;
- Dozzle scenario block: `dozzle` and `full`;
- Audiobookshelf scenario block: `audiobookshelf` and `full`;
- Komga/tinyMediaManager/Jellyfin/Immich contracts: `media` and `full`;
- Paperless seed/snapshot/recreate contracts: `paperless` and `full`;
- second converge and check mode: `idempotence-check` and `full`.

For every non-foundation suite, the initial converge uses its selected tags.
`full` passes no tags and retains byte-for-byte scenario ordering. Every suite
performs vault cleanup and falls through the existing exit trap.

- [ ] **Step 5: Run suite tests and existing syntax tests**

Run:

```bash
tests/integration_suite_test.sh
sh -n tests/integration.sh tests/integration_suite_test.sh
tests/integration_cleanup_test.sh
```

Expected: all commands exit 0 and no suite rejection touches Docker.

- [ ] **Step 6: Register and commit**

Add `tests/integration_suite_test.sh` to `tests/validate-policy.sh`, then commit:

```bash
git add tests/integration.sh tests/integration_suite_test.sh tests/validate-policy.sh
git commit -m "feat: split integration harness into suites"
```

### Task 4: Batch deployment-target containment validation

**Files:**
- Create: `tests/deployment_target_validator_test.py`
- Create: `roles/deployment_bundle/files/validate_target.py`
- Modify: `roles/deployment_bundle/tasks/target.yml`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write failing direct validator tests**

Use `tempfile.TemporaryDirectory` and subprocess execution to cover:

- multiple safe targets accepted in one invocation;
- lexical escape rejected with the exact target in stderr;
- storage-root ancestor symlink rejected;
- non-pointer symlink rejected;
- `current` pointer accepted only within the releases directory;
- `require_current=1` rejects a pointer to a different release;
- malformed JSON and a non-array path payload fail closed.

- [ ] **Step 2: Run and verify RED**

Run: `python3 tests/deployment_target_validator_test.py`

Expected: failure because `validate_target.py` is absent.

- [ ] **Step 3: Extract and batch the existing validator**

Move the Python containment algorithm from `target.yml` into
`roles/deployment_bundle/files/validate_target.py`. Preserve every existing
condition and message. Replace the single `target` argument with a JSON array
and run the unchanged per-target algorithm for each entry.

- [ ] **Step 4: Run direct tests and verify GREEN**

Run: `python3 tests/deployment_target_validator_test.py`

Expected: all filesystem cases pass.

- [ ] **Step 5: Replace the Ansible loop with one command**

Use one `ansible.builtin.command` whose `argv` is:

```yaml
- "{{ ansible_facts.python.executable }}"
- -c
- "{{ lookup('ansible.builtin.file', role_path ~ '/files/validate_target.py') }}"
- "{{ nas_docker_root }}"
- "{{ platform_release_dir }}"
- "{{ platform_current_dir }}"
- "{{ platform_deploy_root }}/.current-{{ platform_release_id }}"
- "{{ require_current | ternary('1', '0') }}"
- "{{ all_target_paths | to_json }}"
```

Remove `loop` and keep `changed_when: false`, `check_mode: false`, and the same
adjacency to mutations.

- [ ] **Step 6: Run Ansible and integration regressions**

Run:

```bash
python3 tests/deployment_target_validator_test.py
ansible-playbook -i inventory/local.yml site.yml --syntax-check
tests/integration.sh --suite foundation site.yml
```

Expected: direct tests pass, syntax check passes, and every existing unsafe-path
scenario still refuses mutation.

- [ ] **Step 7: Register the direct test and commit**

Add the direct validator test to the workflow static job and commit:

```bash
git add roles/deployment_bundle/files/validate_target.py roles/deployment_bundle/tasks/target.yml tests/deployment_target_validator_test.py
git commit -m "perf: batch deployment target validation"
```

### Task 5: Parallel selective workflow

**Files:**
- Create: `tests/ci/workflow_test.rb`
- Modify: `.github/workflows/ci.yml`
- Modify: `tests/validate-policy.sh`

- [ ] **Step 1: Write failing workflow-policy tests**

Parse `.github/workflows/ci.yml` and assert:

- triggers include pull request, push to main, nightly schedule, and manual dispatch;
- concurrency contains pull-request identity and `cancel-in-progress: true`;
- `changes` exposes every classifier output;
- docs-only selection can skip every expensive job;
- service jobs depend on `changes` and use their matching output;
- `validate` is named exactly `validate`, has `if: always()`, and needs every
  selectable job;
- the aggregate validator receives every `needs.<job>.result`;
- full events use `--full` classification;
- no third-party path-filter action is used.

- [ ] **Step 2: Run and verify RED**

Run: `ruby tests/ci/workflow_test.rb`

Expected: the serial workflow lacks classifier, concurrency, schedule, manual,
parallel suites, and gate aggregation.

- [ ] **Step 3: Implement workflow triggers and classification**

Add:

```yaml
on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: "23 3 * * *"
  workflow_dispatch:

concurrency:
  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
```

The `changes` job checks out full history. Pull requests run
`classify_changes.rb --diff "$BASE" "$HEAD"`; every other event runs
`classify_changes.rb --full`. Publish all booleans and `selected_tags` as job
outputs.

- [ ] **Step 4: Add conditional parallel jobs**

Keep static setup in a reusable YAML anchor-free step sequence. Add independent
jobs for `foundation`, `smoke`, `beszel`, `dozzle`, `audiobookshelf`, `media`,
`paperless`, and `idempotence_check`, each guarded by the corresponding output.
Every integration job checks out the repository and invokes exactly one suite.
`smoke` and `idempotence-check` receive `selected_tags`.

- [ ] **Step 5: Add the stable aggregate gate**

Define `validate` with `if: always()` and `needs` containing `changes` and all
selectable jobs. Pass each result to:

```bash
ruby tests/ci/validate_results.rb \
  "changes=${{ needs.changes.result }}" \
  "static=${{ needs.static.result }}" \
  "foundation=${{ needs.foundation.result }}" \
  "smoke=${{ needs.smoke.result }}" \
  "beszel=${{ needs.beszel.result }}" \
  "dozzle=${{ needs.dozzle.result }}" \
  "audiobookshelf=${{ needs.audiobookshelf.result }}" \
  "media=${{ needs.media.result }}" \
  "paperless=${{ needs.paperless.result }}" \
  "idempotence_check=${{ needs.idempotence_check.result }}"
```

Checkout in the gate job so the validator is available. Documentation-only
changes run only `changes` and `validate`.

- [ ] **Step 6: Run workflow tests and syntax checks**

Run:

```bash
ruby tests/ci/workflow_test.rb
ruby -e 'require "yaml"; YAML.safe_load_file(".github/workflows/ci.yml", aliases: true)'
sh -n tests/integration.sh
```

Expected: all exit 0.

- [ ] **Step 7: Register and commit**

Add `ruby tests/ci/workflow_test.rb` to `tests/validate-policy.sh`, then commit:

```bash
git add .github/workflows/ci.yml tests/ci/workflow_test.rb tests/validate-policy.sh
git commit -m "ci: run selective suites in parallel"
```

### Task 6: Simplification and complete verification

**Files:**
- Modify only files touched above when clarity improvements preserve behavior.

- [ ] **Step 1: Review the complete diff for unnecessary complexity**

Run:

```bash
git diff origin/agent/task-13-paperless...HEAD -- .github/workflows/ci.yml tests/ci tests/integration.sh roles/deployment_bundle/tasks/target.yml roles/deployment_bundle/files/validate_target.py
```

Consolidate duplicated lane lists and shell branches only where tests preserve
the exact classifier and dispatch behavior.

- [ ] **Step 2: Run all fast verification**

```bash
find tests -type f -name '*.sh' -exec sh -n {} +
tests/validate-policy.sh
tests/integration_cleanup_test.sh
python3 tests/deployment_target_validator_test.py
ansible-lint --strict
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ansible-playbook generate-secrets.yml --syntax-check
```

Expected: every command exits 0.

- [ ] **Step 3: Run representative integration suites**

```bash
tests/integration.sh --suite foundation site.yml
tests/integration.sh --suite paperless site.yml
tests/integration.sh --suite full site.yml
```

Expected: all suites exit 0; `full` retains fresh converge, every registered
contract, idempotence, and check-mode evidence.

- [ ] **Step 4: Verify documentation-only classification**

```bash
ruby tests/ci/classify_changes.rb --files README.md docs/getting-started.md
```

Expected: `run_ci=false` and every expensive lane is false.

- [ ] **Step 5: Verify repository state and commit any simplification**

Run `git diff --check` and `git status --short`. If simplification changed files,
commit only those changes with:

```bash
git add <modified-files>
git commit -m "refactor: simplify selective CI dispatch"
```
