# Split Media CI Suites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the combined `media` integration lane with independently routed and executed `komga`, `tinymediamanager`, `jellyfin`, and `immich` suites without losing scenarios or path-selective CI.

**Architecture:** The Ruby change classifier remains the single source of truth for lane selection and matrix ordering. The shell integration harness gives each service a fixed tag plan, host-side fixture preparation, service-specific preseed state, and an isolated scenario block; the generic GitHub Actions matrix consumes the expanded suite list without workflow topology changes. The manual `full` suite keeps broad normal-contract coverage, while the expensive restore lifecycle belongs only to `immich`.

**Tech Stack:** Ruby contract tests, POSIX shell integration harness, GitHub Actions YAML, Ansible tags, Docker Compose

---

## File Structure

- Modify `tests/ci/classify_changes_test.rb`: specify the four lanes, their path routing, tag plans, output ordering, and removal of `media`.
- Modify `tests/ci/classify_changes.rb`: implement the classifier lane, suite, tag, and service mappings.
- Modify `tests/ci/workflow_test.rb`: pin the expanded suite matrix contract.
- Modify `tests/ci/validate_results_test.rb`: remove the retired lane from aggregate-validator examples.
- Modify `tests/integration_suite_test.sh`: specify suite parsing, fixed tags, fixture preparation, preseed ABI, scenario ownership, and Jellyfin isolation.
- Modify `tests/immich_restore_quality_test.rb`: require Immich restore scenarios to remain in the `immich` suite.
- Modify `tests/integration.sh`: implement four fixed suites, independent fixture preparation, and independent scenario dispatch.
- Modify `tests/contracts/komga.sh`: consume Komga-specific preseed state.
- Modify `tests/contracts/tinymediamanager.sh`: consume tinyMediaManager-specific preseed state.
- Modify `tests/contracts/jellyfin.sh`: consume Jellyfin-specific preseed state and remove tinyMediaManager coupling language.
- Modify `docs/adding-a-service.md`: document one-service-per-lane routing and the expanded fail-open example.

### Task 1: Specify and implement independent change-classifier lanes

**Files:**
- Modify: `tests/ci/classify_changes_test.rb`
- Modify: `tests/ci/classify_changes.rb`

- [ ] **Step 1: Write the failing classifier expectations**

Replace the test's canonical lane constant and media-service expectations with:

```ruby
LANES = %w[
  static foundation smoke beszel dozzle audiobookshelf komga tinymediamanager jellyfin immich
  paperless idempotence_check
].freeze

{
  "beszel" => %w[beszel],
  "dozzle" => %w[dozzle],
  "audiobookshelf" => %w[audiobookshelf],
  "komga" => %w[komga],
  "tinymediamanager" => %w[tinymediamanager],
  "jellyfin" => %w[jellyfin],
  "immich" => %w[immich],
  "paperless-ngx" => %w[paperless]
}
```

Change the direct Jellyfin expectation to:

```ruby
["tests/contracts/jellyfin.sh"] => %w[static smoke jellyfin idempotence_check]
```

Add a multiple-media-service assertion:

```ruby
check(
  failures,
  selected_lanes([
    "roles/komga/tasks/main.yml",
    "services/jellyfin/compose.yml",
    "tests/contracts/immich.sh"
  ]) == %w[static smoke komga jellyfin immich idempotence_check],
  "multiple media service changes must remain independent and canonically ordered"
)
```

Pin each service's selected tags to only its prerequisites and own tag:

```ruby
"roles/komga/tasks/main.yml" => "host_prep,deployment_bundle,komga",
"roles/tinymediamanager/tasks/main.yml" => "host_prep,deployment_bundle,tinymediamanager",
"roles/jellyfin/tasks/main.yml" => "host_prep,deployment_bundle,jellyfin",
"roles/immich/tasks/main.yml" => "host_prep,deployment_bundle,immich",
```

Update all exact GitHub-output fixtures to enumerate the four booleans and this full suite order:

```text
suites=["foundation","smoke","beszel","dozzle","audiobookshelf","komga","tinymediamanager","jellyfin","immich","paperless","idempotence-check"]
```

Assert no classifier output contains a `media=` key or a `"media"` suite.

- [ ] **Step 2: Run the classifier test and verify RED**

Run:

```sh
ruby tests/ci/classify_changes_test.rb
```

Expected: FAIL because `ClassifyChanges` still returns `media` and does not define the four new lanes.

- [ ] **Step 3: Implement the classifier mappings**

Change `tests/ci/classify_changes.rb` to use:

```ruby
LANES = %w[
  static foundation smoke beszel dozzle audiobookshelf komga tinymediamanager jellyfin immich
  paperless idempotence_check
].freeze
SUITES = {
  "foundation" => "foundation",
  "smoke" => "smoke",
  "beszel" => "beszel",
  "dozzle" => "dozzle",
  "audiobookshelf" => "audiobookshelf",
  "komga" => "komga",
  "tinymediamanager" => "tinymediamanager",
  "jellyfin" => "jellyfin",
  "immich" => "immich",
  "paperless" => "paperless",
  "idempotence_check" => "idempotence-check"
}.freeze
SERVICE_LANES = %w[
  beszel dozzle audiobookshelf komga tinymediamanager jellyfin immich paperless
].freeze
SERVICE_TAGS = {
  "beszel" => %w[host_prep deployment_bundle ntfy beszel],
  "dozzle" => %w[host_prep deployment_bundle ntfy dozzle],
  "audiobookshelf" => %w[host_prep deployment_bundle audiobookshelf],
  "komga" => %w[host_prep deployment_bundle komga],
  "tinymediamanager" => %w[host_prep deployment_bundle tinymediamanager],
  "jellyfin" => %w[host_prep deployment_bundle jellyfin],
  "immich" => %w[host_prep deployment_bundle immich],
  "paperless" => %w[host_prep deployment_bundle paperless]
}.freeze
SERVICE_NAMES = {
  "beszel" => %w[beszel],
  "dozzle" => %w[dozzle],
  "audiobookshelf" => %w[audiobookshelf],
  "komga" => %w[komga],
  "tinymediamanager" => %w[tinymediamanager],
  "jellyfin" => %w[jellyfin],
  "immich" => %w[immich],
  "paperless" => %w[paperless paperless-ngx paperless_ngx]
}.freeze
```

Do not change fail-open, inert-path, diff parsing, or GitHub-output behavior.

- [ ] **Step 4: Run the classifier test and verify GREEN**

Run:

```sh
ruby tests/ci/classify_changes_test.rb
```

Expected: `changed-path classifier: all checks passed`.

- [ ] **Step 5: Commit the classifier split**

```sh
git add -- tests/ci/classify_changes.rb tests/ci/classify_changes_test.rb
git commit -m "ci: split media change routing by service"
```

### Task 2: Specify independent suite dispatch and fixture ownership

**Files:**
- Modify: `tests/integration_suite_test.sh`
- Modify: `tests/immich_restore_quality_test.rb`

- [ ] **Step 1: Replace the combined suite expectations**

Set the expected suite list to:

```sh
'foundation smoke beszel dozzle audiobookshelf komga tinymediamanager jellyfin immich paperless idempotence-check full'
```

Add these exact descriptions:

```sh
assert_output 'suite=komga tags=host_prep,deployment_bundle,komga playbook=site.yml scenarios=true' \
  --describe-suite komga
assert_output 'suite=tinymediamanager tags=host_prep,deployment_bundle,tinymediamanager playbook=site.yml scenarios=true' \
  --describe-suite tinymediamanager
assert_output 'suite=jellyfin tags=host_prep,deployment_bundle,jellyfin playbook=site.yml scenarios=true' \
  --describe-suite jellyfin
assert_output 'suite=immich tags=host_prep,deployment_bundle,immich playbook=site.yml scenarios=true' \
  --describe-suite immich
```

Replace the shared fixture assertions with a loop that proves each contract is
prepared before `docker run`, each case accepts only `<service>:true|full:true`,
and each service-specific preseed environment variable is passed:

```sh
for contract in komga tinymediamanager jellyfin; do
  preseed_line=$(grep -nF \
    '"$repo_dir/tests/contracts/'"$contract"'.sh" seed-fixture-only' \
    "$integration" | cut -d: -f1)
  [ -n "$preseed_line" ] && [ "$preseed_line" -lt "$controller_line" ] || exit 1
done
grep -qF 'komga:true|full:true)' "$integration"
grep -qF 'tinymediamanager:true|full:true)' "$integration"
grep -qF 'jellyfin:true|full:true)' "$integration"
grep -qF -- '-e PLATFORM_KOMGA_FIXTURE_PRESEEDED="$komga_fixture_preseeded"' "$integration"
grep -qF -- '-e PLATFORM_TINYMEDIAMANAGER_FIXTURE_PRESEEDED="$tinymediamanager_fixture_preseeded"' "$integration"
grep -qF -- '-e PLATFORM_JELLYFIN_FIXTURE_PRESEEDED="$jellyfin_fixture_preseeded"' "$integration"
```

Extract the Jellyfin scenario block and reject any `tinymediamanager` reference:

```sh
jellyfin_scenarios=$(sed -n '/suite_is jellyfin/,/^    fi$/p' "$integration")
printf '%s\n' "$jellyfin_scenarios" | grep -qF 'run_jellyfin_contract seed'
printf '%s\n' "$jellyfin_scenarios" | grep -qF 'run_jellyfin_contract run'
if printf '%s\n' "$jellyfin_scenarios" | grep -qi tinymediamanager; then
  printf '%s\n' 'Jellyfin scenario dispatch depends on tinyMediaManager' >&2
  exit 1
fi
```

Require `media` to be rejected as unknown and enumerate the four new suites in
the fixed-suite `--tags` rejection loop.

In `tests/immich_restore_quality_test.rb`, change the failure label to `Immich
integration omits` and require the dispatch source to contain both
`suite_is immich` and `INTEGRATION_SUITE\" = immich` around the restore calls.

- [ ] **Step 2: Run dispatch and restore-quality tests and verify RED**

Run:

```sh
tests/integration_suite_test.sh
ruby tests/immich_restore_quality_test.rb
```

Expected: both fail because the harness still exposes `media` and owns all four
scenario groups in one block.

### Task 3: Implement fixed suites and service-specific fixture ABI

**Files:**
- Modify: `tests/integration.sh`
- Modify: `tests/contracts/komga.sh`
- Modify: `tests/contracts/tinymediamanager.sh`
- Modify: `tests/contracts/jellyfin.sh`

- [ ] **Step 1: Implement suite names and fixed tag plans**

Replace the list and fixed media case in `tests/integration.sh` with:

```sh
printf '%s\n' 'foundation smoke beszel dozzle audiobookshelf komga tinymediamanager jellyfin immich paperless idempotence-check full'
```

```sh
komga) fixed_tags=host_prep,deployment_bundle,komga ;;
tinymediamanager) fixed_tags=host_prep,deployment_bundle,tinymediamanager ;;
jellyfin) fixed_tags=host_prep,deployment_bundle,jellyfin ;;
immich) fixed_tags=host_prep,deployment_bundle,immich ;;
```

- [ ] **Step 2: Split host-side fixture preparation**

Initialize:

```sh
komga_fixture_preseeded=false
tinymediamanager_fixture_preseeded=false
jellyfin_fixture_preseeded=false
```

Use three separate case blocks, each matching only its suite or `full`, running
only its contract's `seed-fixture-only` mode, then setting only its own boolean.
Pass the booleans into the controller as:

```sh
-e PLATFORM_KOMGA_FIXTURE_PRESEEDED="$komga_fixture_preseeded" \
-e PLATFORM_TINYMEDIAMANAGER_FIXTURE_PRESEEDED="$tinymediamanager_fixture_preseeded" \
-e PLATFORM_JELLYFIN_FIXTURE_PRESEEDED="$jellyfin_fixture_preseeded" \
```

- [ ] **Step 3: Split service scenario dispatch**

Replace the media block with four blocks:

```sh
if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is komga; then
  run_komga_contract seed
  if [ "$INTEGRATION_SUITE" = komga ]; then
    run_komga_contract run
  fi
fi

if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is tinymediamanager; then
  run_tinymediamanager_contract seed
  if [ "$INTEGRATION_SUITE" = tinymediamanager ]; then
    run_tinymediamanager_contract run
  fi
fi

if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is jellyfin; then
  run_jellyfin_contract seed
  if [ "$INTEGRATION_SUITE" = jellyfin ]; then
    run_jellyfin_contract run
  fi
fi

if [ "$INTEGRATION_RUN_SERVICE_SCENARIOS" = true ] && suite_is immich; then
  if [ "$INTEGRATION_SUITE" = immich ]; then
    run_immich_contract clean-restore-seed
    run_immich_clean_restore
    run_immich_restore_negative_matrix
    run_immich_contract run
  fi
fi
```

Keep the manual `full` contract runner after these blocks. Update its comment to
say the `immich` suite owns the expensive model-independent restore fixture.

- [ ] **Step 4: Rename each contract's preseed variable**

Use these one-to-one replacements in the shell defaults, exports, and Ruby
`ENV.fetch` checks:

```text
Komga:             PLATFORM_KOMGA_FIXTURE_PRESEEDED
tinyMediaManager:  PLATFORM_TINYMEDIAMANAGER_FIXTURE_PRESEEDED
Jellyfin:          PLATFORM_JELLYFIN_FIXTURE_PRESEEDED
```

Rewrite Jellyfin's fixture comment to state that its Task 11 path and bytes are
owned by the Jellyfin contract under the shared NAS media root; do not mention
tinyMediaManager.

- [ ] **Step 5: Run focused dispatch and quality tests and verify GREEN**

Run:

```sh
tests/integration_suite_test.sh
ruby tests/immich_restore_quality_test.rb
sh -n tests/integration.sh tests/contracts/komga.sh \
  tests/contracts/tinymediamanager.sh tests/contracts/jellyfin.sh
```

Expected: dispatch and restore quality checks pass; shell syntax exits zero.

- [ ] **Step 6: Commit suite dispatch and fixture isolation**

```sh
git add -- tests/integration.sh tests/integration_suite_test.sh \
  tests/immich_restore_quality_test.rb tests/contracts/komga.sh \
  tests/contracts/tinymediamanager.sh tests/contracts/jellyfin.sh
git commit -m "ci: isolate media service integration suites"
```

### Task 4: Update workflow contracts, aggregate examples, and service-authoring docs

**Files:**
- Modify: `tests/ci/workflow_test.rb`
- Modify: `tests/ci/validate_results_test.rb`
- Modify: `docs/adding-a-service.md`

- [ ] **Step 1: Write the failing workflow suite expectation**

Set `INTEGRATION_SUITES` to:

```ruby
INTEGRATION_SUITES = %w[
  foundation smoke beszel dozzle audiobookshelf komga tinymediamanager jellyfin immich paperless
  idempotence-check
].freeze
```

Change the cancelled-result example from `media=cancelled` to
`immich=cancelled`. Run:

```sh
ruby tests/ci/workflow_test.rb
ruby tests/ci/validate_results_test.rb
```

Expected before the classifier implementation is present: workflow contract
FAIL due to suite-list disagreement. When Tasks 1-3 are already green, both
commands pass and confirm the generic workflow needs no YAML topology change.

- [ ] **Step 2: Update active CI-routing documentation**

Change the example role tags to:

```yaml
- role: navidrome
  tags: [navidrome]
```

Change the routing example to show unknown paths selecting all four media
service lanes and Komga selecting only `komga`:

```text
roles/navidrome/... unmapped -> static, foundation, smoke, beszel, dozzle,
                                audiobookshelf, komga, tinymediamanager,
                                jellyfin, immich, paperless, idempotence-check
roles/komga/...     mapped   -> static, smoke, komga, idempotence-check
```

State that every service should normally own its own lane and that the generic
matrix workflow does not need editing when classifier and contract lists agree.

- [ ] **Step 3: Check for active retired-lane references**

Run:

```sh
rg -n '\bmedia\b|PLATFORM_MEDIA_FIXTURES_PRESEEDED' \
  tests/ci tests/integration.sh tests/integration_suite_test.sh \
  tests/contracts/komga.sh tests/contracts/tinymediamanager.sh \
  tests/contracts/jellyfin.sh docs/adding-a-service.md
```

Expected: no retired lane, suite, or shared preseed variable references. Ordinary
domain uses such as `/media`, `media root`, and media file descriptions may remain.

- [ ] **Step 4: Run CI contract tests**

Run:

```sh
ruby tests/ci/classify_changes_test.rb
ruby tests/ci/workflow_test.rb
ruby tests/ci/validate_results_test.rb
tests/integration_suite_test.sh
ruby tests/immich_restore_quality_test.rb
```

Expected: all five commands pass.

- [ ] **Step 5: Commit workflow contracts and documentation**

```sh
git add -- tests/ci/workflow_test.rb tests/ci/validate_results_test.rb \
  docs/adding-a-service.md
git commit -m "docs: describe service-owned CI lanes"
```

### Task 5: Run complete policy and Docker-backed verification

**Files:**
- Verify only

- [ ] **Step 1: Run formatting and diff checks**

```sh
git diff --check origin/main...HEAD
find tests -type f -name '*.sh' -exec sh -n {} +
```

Expected: both commands exit zero.

- [ ] **Step 2: Run the complete policy gate**

```sh
tests/validate-policy.sh
```

Expected: `policy validation: all <count> checks passed` with zero failed checks.

- [ ] **Step 3: Run all four Docker-backed suites**

Run sequentially because the harness uses a global integration lock:

```sh
tests/integration.sh --suite komga site.yml
tests/integration.sh --suite tinymediamanager site.yml
tests/integration.sh --suite jellyfin site.yml
tests/integration.sh --suite immich site.yml
```

Expected: each suite converges only its fixed tag plan, executes its owned
scenario block, cleans its sandbox, and exits zero. The Immich suite must print
`IMMICH_CLEAN_RESTORE_IDEMPOTENT` and `IMMICH_NEGATIVE_RESTORE_MATRIX_OK`.

- [ ] **Step 4: Inspect the final branch diff and commit state**

```sh
git status --short --branch
git diff --stat origin/main...HEAD
git log --oneline --decorate origin/main..HEAD
```

Expected: clean worktree; only the approved design, plan, classifier, harness,
contracts, tests, and active documentation differ from `origin/main`; commits
contain no `Co-Authored-By` trailers.

### Task 6: Push the verified branch

**Files:**
- Publish only

- [ ] **Step 1: Push the new branch**

```sh
git push --set-upstream origin feature/split-media-ci-suites
```

Expected: the remote branch is created or fast-forwarded to the verified local
head. Do not merge or create a PR unless separately requested.

- [ ] **Step 2: Report verification evidence and limitations**

Report the policy-gate result, each Docker suite result, pushed branch name, and
commit IDs. If a command is blocked by Docker, registry, network, or host
resources, report the exact command and failure without claiming it passed.
