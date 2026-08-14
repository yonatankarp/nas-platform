# Dozzle Friendly Container Names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display every deployed container in Dozzle under its exact Compose service key while retaining collision-safe physical Docker names.

**Architecture:** Add Dozzle's supported `dev.dozzle.name` metadata to the shared Compose service definitions, leaving physical `container_name` and existing `dev.dozzle.group` values intact. Extend effective-Compose and runtime contracts so every supported platform proves the exact alias and Mac continues proving that physical names remain sandbox-prefixed.

**Tech Stack:** Docker Compose YAML, Dozzle v10.7.1 container labels, POSIX shell, Ruby contract assertions, Docker CLI, existing Mac proof harness.

---

## File structure

- `services/*/compose.yml`: own the platform-independent friendly display label for each Compose service.
- `tests/contracts/dozzle.sh`: render base, Mac, adoption, Mac-adoption, and supported integration variants; enforce exact display labels and reject duplicate raw label keys.
- `tests/mac/hooks/verify/20-dozzle.sh`: inspect every running proof container and assert both its friendly display label and, where applicable, its group.
- `tests/mac/hooks/drift/20-dozzle.sh`: corrupt the Dozzle socket proxy's owned display/group labels and prove normal Compose reconciliation restores them.
- `tests/mac/dozzle-drift-hook-test.sh`: fake-Docker regression coverage for wrong, missing, and repaired runtime display labels.
- `tests/mac/config-isolation.sh`: retain the existing proof that physical container names differ between simultaneous sandboxes while adding stable alias assertions.

### Task 1: Make the effective-Compose contract fail on absent or incorrect friendly names

**Files:**
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/dozzle_quality_test.rb`

- [ ] **Step 1: Extend the rendered Compose assertion with the exact service-key alias**

Inside `render_group_contract`, assert the following for every rendered service before checking group behavior:

```ruby
services.each do |service, definition|
  labels = definition.fetch("labels", {})
  display_matches = labels.select { |name, _value| name == "dev.dozzle.name" }
  abort "Dozzle contract failed: #{stack} #{variant} #{service} display name differs" unless
    display_matches == {"dev.dozzle.name" => service}
end
```

Keep the existing single-container rule: those services gain only `dev.dozzle.name`; they do not gain `dev.dozzle.group`.

- [ ] **Step 2: Reject duplicate raw `dev.dozzle.name` mapping keys**

Load `tests/policy_support.rb`, parse every base Compose file rendered by the contract with `Psych.parse_stream`, and fail if the duplicate-key walker reports `dev.dozzle.name`:

```ruby
require_relative "../policy_support"

duplicate_names = PolicySupport.duplicate_yaml_keys(Psych.parse_stream(File.read(compose_path)))
abort "Dozzle contract failed: #{stack} Compose contains duplicate dev.dozzle.name label" if
  duplicate_names.include?("dev.dozzle.name")
```

Pass the repository path or exact Compose paths into this Ruby assertion without using a glob that could silently omit a service.

- [ ] **Step 3: Add mutation probes to the focused quality test**

In a temporary copied repository, exercise these mutations independently against `tests/contracts/dozzle.sh static`:

```ruby
mutations = {
  "missing display name" => ->(yaml) { yaml.sub(/^\s+dev\.dozzle\.name: gotenberg\n/, "") },
  "wrong display name" => ->(yaml) { yaml.sub("dev.dozzle.name: gotenberg", "dev.dozzle.name: paperless-gotenberg") },
  "duplicate display name" => ->(yaml) {
    yaml.sub("dev.dozzle.name: gotenberg", "dev.dozzle.name: gotenberg\n      dev.dozzle.name: paperless-gotenberg")
  }
}
```

Require nonzero status and the fixed, nonsecret display-name diagnostic for each mutation. Ensure the unmodified fixture still passes.

- [ ] **Step 4: Run the tests and capture genuine RED**

Run:

```bash
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  tests/contracts/dozzle.sh static
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  ruby tests/dozzle_quality_test.rb
```

Expected: both fail because the Compose services do not yet define `dev.dozzle.name`; mutation probes must also demonstrate that missing/wrong/duplicate values are rejected by the new test logic rather than by a Ruby stack trace.

- [ ] **Step 5: Commit the RED contract**

```bash
git add tests/contracts/dozzle.sh tests/dozzle_quality_test.rb
git commit -m "test: require friendly Dozzle container names"
```

### Task 2: Add exact friendly aliases without changing physical names or groups

**Files:**
- Modify: `services/audiobookshelf/compose.yml`
- Modify: `services/beszel/compose.yml`
- Modify: `services/dozzle/compose.yml`
- Modify: `services/immich/compose.yml`
- Modify: `services/jellyfin/compose.yml`
- Modify: `services/komga/compose.yml`
- Modify: `services/ntfy/compose.yml`
- Modify: `services/paperless-ngx/compose.yml`
- Modify: `services/tinymediamanager/compose.yml`

- [ ] **Step 1: Add the exact label to all 20 shared service definitions**

Add a mapping-form label to each service, merging with any existing labels:

```yaml
labels:
  dev.dozzle.name: SERVICE_KEY
```

Use this exact inventory:

```ruby
EXPECTED_NAMES = {
  "audiobookshelf" => %w[audiobookshelf],
  "beszel" => %w[hub agent-portable agent-intel socket-proxy],
  "dozzle" => %w[dozzle socket-proxy],
  "immich" => %w[immich-server immich-machine-learning redis database],
  "jellyfin" => %w[jellyfin],
  "komga" => %w[komga],
  "ntfy" => %w[ntfy],
  "paperless-ngx" => %w[broker db webserver gotenberg tika],
  "tinymediamanager" => %w[tinymediamanager]
}.freeze
```

For example:

```yaml
services:
  gotenberg:
    labels:
      dev.dozzle.group: paperless
      dev.dozzle.name: gotenberg
```

Do not edit any `container_name`, `dev.dozzle.group`, profile, image, port, mount, device, or environment value.

- [ ] **Step 2: Run focused effective-Compose validation**

Run:

```bash
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  tests/contracts/dozzle.sh static
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  ruby tests/dozzle_quality_test.rb
```

Expected: both pass across base, Mac, adoption, Mac-adoption, and supported integration renders.

- [ ] **Step 3: Prove physical Mac names remain isolated while aliases remain stable**

Extend `tests/mac/config-isolation.sh` so each rendered service asserts:

```ruby
first_alias = first_definition.fetch("labels").fetch("dev.dozzle.name")
second_alias = second_definition.fetch("labels").fetch("dev.dozzle.name")
raise "#{stack} #{service} display name differs" unless
  first_alias == service && second_alias == service
raise "#{stack} #{service} physical names collide" if first_name == second_name
```

Cover all services already rendered by the isolation test, including single-container stacks. Run:

```bash
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  tests/mac/config-isolation.sh
```

Expected: pass, showing stable friendly aliases and different prefixed physical names.

- [ ] **Step 4: Commit the Compose implementation**

```bash
git add services/*/compose.yml tests/mac/config-isolation.sh
git commit -m "feat: label containers with friendly Dozzle names"
```

### Task 3: Verify and drift-test deployed friendly labels

**Files:**
- Modify: `tests/mac/hooks/verify/20-dozzle.sh`
- Modify: `tests/mac/hooks/drift/20-dozzle.sh`
- Modify: `tests/mac/dozzle-drift-hook-test.sh`
- Modify: `tests/contracts/dozzle.sh`

- [ ] **Step 1: Generalize runtime verification to check exact aliases**

Replace the group-only helper with a helper that accepts physical name, expected Compose service key, and optional group:

```sh
verify_dozzle_labels() {
  container=$1
  expected_name=$2
  expected_group=$3
  labels=$(docker container inspect --format '{{json .Config.Labels}}' "$container") ||
    mac_die "Dozzle label verification could not inspect $container"
  DOZZLE_RUNTIME_LABELS=$labels ruby -rjson - "$container" "$expected_name" "$expected_group" <<'RUBY'
container, expected_name, expected_group = ARGV
labels = JSON.parse(ENV.fetch("DOZZLE_RUNTIME_LABELS"))
abort "#{container} has an incorrect dev.dozzle.name label" unless
  labels["dev.dozzle.name"] == expected_name
if expected_group.empty?
  abort "#{container} unexpectedly has a dev.dozzle.group label" if labels.key?("dev.dozzle.group")
else
  abort "#{container} has an incorrect dev.dozzle.group label" unless
    labels["dev.dozzle.group"] == expected_group
end
abort "#{container} retained the unmanaged Dozzle drift sentinel" if
  labels.key?("dev.dozzle.contract.sentinel")
RUBY
}
```

Invoke it for every running Mac/integration container. Use the Compose service keys (`hub`, `broker`, `db`, and so on) as expected aliases, even when historical physical names are `beszel`, `paperless_redis`, or sandbox-prefixed equivalents. Include the five single-container services with an empty group.

- [ ] **Step 2: Drift both owned labels on the Dozzle socket proxy**

Make the drift override own this exact malformed state:

```yaml
services:
  socket-proxy:
    labels:
      dev.dozzle.group: dozzle-contract-drift
      dev.dozzle.name: dozzle-contract-drift
      dev.dozzle.contract.sentinel: unrelated-label-must-not-survive-reconciliation
```

Assert the drift took effect, then retain the existing Compose reconciliation and final verification so rerun restores `dev.dozzle.group=dozzle`, `dev.dozzle.name=socket-proxy`, and removes the sentinel.

- [ ] **Step 3: Strengthen the fake Docker hook test**

Return exact alias and group labels for every inspected fake container. Add independent states for:

```json
{"dev.dozzle.group":"dozzle","dev.dozzle.name":"wrong-name"}
```

and:

```json
{"dev.dozzle.group":"dozzle"}
```

Require both states to fail before the contract runner executes, and require the repaired state to pass. Continue proving an unrelated sentinel fails verification.

- [ ] **Step 4: Pin the static runtime-hook contract**

In `tests/contracts/dozzle.sh static`, require the verify hook to contain both the Docker label inspection and `dev.dozzle.name`, and require the drift hook to corrupt both owned labels:

```ruby
abort "Dozzle contract failed: Mac runtime verification omits friendly display names" unless
  mac_verify.include?("docker container inspect") &&
  mac_verify.include?("dev.dozzle.name")
abort "Dozzle contract failed: Mac drift proof does not corrupt a managed display label" unless
  mac_drift.include?("dev.dozzle.name: dozzle-contract-drift")
```

- [ ] **Step 5: Run the focused runtime suite**

Run:

```bash
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  tests/mac/dozzle-drift-hook-test.sh
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  tests/contracts/dozzle.sh static
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  ruby tests/dozzle_quality_test.rb
```

Expected: all pass; wrong/missing name mutations fail with the fixed display-label diagnostic.

- [ ] **Step 6: Commit runtime verification**

```bash
git add tests/mac/hooks/verify/20-dozzle.sh \
  tests/mac/hooks/drift/20-dozzle.sh \
  tests/mac/dozzle-drift-hook-test.sh \
  tests/contracts/dozzle.sh
git commit -m "test: verify friendly Dozzle names at runtime"
```

### Task 4: Run policy regression and refresh the retained manual-proof deployment

**Files:**
- No source files expected
- Runtime output: existing retained Mac sandbox and its report directory

- [ ] **Step 1: Run syntax and policy checks**

Run:

```bash
git diff --check
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  ruby tests/policy_test.rb
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  tests/validate-policy.sh
```

Expected: exit 0 from all commands with no Ruby stack traces, Compose warnings, or policy failures.

- [ ] **Step 2: Resume the retained fresh proof to recreate labeled containers**

Run:

```bash
PATH=/Users/yonatankarp-rudin/Projects/nas-platform/.venv/bin:$PATH \
  tests/mac/run.sh \
    --lane fresh \
    --vault-file /Users/yonatankarp-rudin/.config/nas-platform/vault.yml \
    --vault-password-file /Users/yonatankarp-rudin/.config/nas-platform/vault-password \
    --sandbox /private/var/folders/z6/qvbh9dlx2_s98lt4__4fwg9m0000gn/T/nas-platform-mac.czAjo0
```

Expected: Compose recreates affected containers, Ansible finishes with `failed=0`, verification finishes with `changed=0 failed=0`, and the manual-validation boundary is printed again.

- [ ] **Step 3: Inspect physical names and friendly labels directly**

Run:

```bash
docker container inspect \
  nas-platform-mac-czAjo0-paperless-gotenberg \
  --format '{{.Name}} {{index .Config.Labels "dev.dozzle.name"}} {{index .Config.Labels "dev.dozzle.group"}}'
```

Use the exact retained project prefix printed by the runner if Docker normalized its case. Expected output retains the physical sandbox prefix and reports:

```text
/nas-platform-mac-czajo0-paperless-gotenberg gotenberg paperless
```

Repeat through the runtime hook for all deployed containers rather than relying only on this example.

- [ ] **Step 4: Confirm the working tree and hand off manual validation**

Run:

```bash
git status --short --branch
```

Expected: clean worktree. Report the new commits, focused/full test evidence, retained sandbox path, Dozzle URL, resume command, and cleanup command. Ask the user to refresh Dozzle and confirm entries now use Compose service keys.
