# Portainer Parity Intake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert exactly nine protected Portainer environment exports into a validated external encrypted parity vault without evaluating or disclosing values.

**Architecture:** Ruby owns strict parsing, mapping, and schema validation. POSIX shell owns safe paths, permissions, encryption, atomic publication, and overwrite refusal.

**Tech Stack:** Ruby, POSIX shell, YAML, Ansible Vault, SHA-256.

---

### Task 1: Commit the mapping contract

**Files:**
- Create: config/portainer-parity.yml
- Create: tests/portainer_parity_mapping_test.rb
- Modify: tests/validate-policy.sh

- [ ] **Step 1: Write the failing mapping test**

Require schema 1, commit 400f03f276ae1bb69f5460c175b9fb923d620f1a,
the nine manifest services, and exact variable sets:

~~~ruby
EXPECTED = {
  "audiobookshelf" => %w[TZ],
  "beszel" => %w[BESZEL_AGENT_KEY BESZEL_AGENT_TOKEN BESZEL_APP_URL BESZEL_SYSTEM_NAME TZ],
  "dozzle" => %w[TZ],
  "immich" => %w[DB_DATABASE_NAME DB_PASSWORD DB_USERNAME TZ],
  "jellyfin" => %w[TZ],
  "komga" => %w[GROUP_ID TZ USER_ID],
  "ntfy" => %w[GROUP_ID NTFY_BASE_URL TZ USER_ID],
  "paperless-ngx" => %w[
    DB_NAME DB_PASSWORD DB_USER GROUP_ID PAPERLESS_AI_ENABLED
    PAPERLESS_AI_LLM_ENDPOINT PAPERLESS_AI_LLM_MODEL PAPERLESS_SECRET_KEY
    PAPERLESS_TASK_WORKERS PAPERLESS_THREADS_PER_WORKER TZ USER_ID
  ],
  "tinymediamanager" => %w[GROUP_ID PASSWORD TZ USER_ID]
}.transform_values(&:sort).freeze
~~~

Each rule has classification plus target, except excluded, which requires reason.

Run: ruby tests/portainer_parity_mapping_test.rb

Expected: FAIL because the mapping is absent.

- [ ] **Step 2: Add exact classifications**

Map TZ to inventory:nas_timezone; USER_ID/GROUP_ID to
inventory:nas_uid/nas_gid; database credentials, secrets, agent key/token, and
tinyMediaManager password to their existing vault keys; and URLs, Beszel system
name, workers, and Paperless AI values to same-named role variables.

The contract starts:

~~~yaml
---
schema: 1
legacy_commit: 400f03f276ae1bb69f5460c175b9fb923d620f1a
stacks:
  beszel:
    TZ: {classification: inventory, target: nas_timezone}
    BESZEL_APP_URL: {classification: role, target: beszel_app_url}
    BESZEL_AGENT_KEY: {classification: vault, target: vault_beszel_agent_key}
    BESZEL_AGENT_TOKEN: {classification: vault, target: vault_beszel_universal_token}
    BESZEL_SYSTEM_NAME: {classification: role, target: beszel_system_name}
~~~

Do not exclude any currently expected variable.

- [ ] **Step 3: Register, verify, and commit**

~~~bash
ruby tests/portainer_parity_mapping_test.rb
git add config/portainer-parity.yml tests/portainer_parity_mapping_test.rb tests/validate-policy.sh
git commit -m "test: define Portainer parity mapping"
~~~

Expected: Portainer parity mapping: all nine stacks are explicit.

### Task 2: Implement the non-evaluating parser

**Files:**
- Create: scripts/portainer-parity.rb
- Create: tests/portainer_parity_parser_test.rb

- [ ] **Step 1: Write parser mutation tests**

Use Dir.mktmpdir with all nine synthetic files. Assert preservation of
space-dollar-hash-equals values and empty values. Require sanitized failure for
missing/extra files, duplicate/unknown/missing keys, malformed names, NUL, CR,
indented assignments, symlinks, wrong schema, and commit mismatch. No canary may
occur in stderr.

Run: ruby tests/portainer_parity_parser_test.rb

Expected: FAIL because the parser is absent.

- [ ] **Step 2: Implement strict parsing**

Create these core functions:

~~~ruby
def parse_env(path)
  raise "unsafe environment file" unless File.file?(path) && !File.symlink?(path)
  bytes = File.binread(path)
  raise "environment file contains NUL" if bytes.include?("\0")
  raise "environment file contains CR" if bytes.include?("\r")
  values = {}
  bytes.split("\n", -1).each_with_index do |line, index|
    next if line.empty? || line.match?(/\A[ \t]*#/)
    match = line.match(/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/)
    raise "line #{index + 1} is malformed" unless match
    key, value = match.captures
    raise "duplicate variable #{key}" if values.key?(key)
    values[key] = value
  end
  values
end

def build_parity(input_dir, mapping, commit)
  raise "unsafe input directory" unless File.directory?(input_dir) && !File.symlink?(input_dir)
  raise "legacy commit mismatch" unless mapping.fetch("legacy_commit") == commit
  stacks = mapping.fetch("stacks")
  expected = stacks.keys.map { |name| "#{name}.env" }.sort
  raise "stack file set differs from mapping" unless Dir.children(input_dir).sort == expected
  values = stacks.to_h do |stack, rules|
    parsed = parse_env(File.join(input_dir, "#{stack}.env"))
    raise "#{stack} variable set differs from mapping" unless parsed.keys.sort == rules.keys.sort
    [stack, parsed]
  end
  {"schema" => 1, "legacy_commit" => commit, "stacks" => values}
end
~~~

Use YAML.safe_load_file with aliases disabled and OptionParser options
--input-dir, --mapping, --legacy-commit, and --format yaml|json. Validate exact
root/rule fields before reading values. Expected failures emit one
portainer-parity-error line without a backtrace or value.

- [ ] **Step 3: Verify and commit**

~~~bash
ruby -c scripts/portainer-parity.rb
ruby tests/portainer_parity_parser_test.rb
git add scripts/portainer-parity.rb tests/portainer_parity_parser_test.rb
git commit -m "feat: parse protected Portainer exports"
~~~

### Task 3: Encrypt and publish atomically

**Files:**
- Create: scripts/import-portainer-parity.sh
- Create: tests/portainer_parity_import_test.sh
- Modify: scripts/portainer-parity.rb
- Modify: tests/validate-policy.sh

- [ ] **Step 1: Write the failing importer test**

Create nine synthetic exports under mode 0700, files and external password input
mode 0600. Require a Vault header, output mode 0600, valid decrypted schema, and
canary absence. Mutate output existence, unsafe modes, symlinks,
repository-contained password/output, and encryption failure; require unchanged
sources and no output.

Run: tests/portainer_parity_import_test.sh

Expected: FAIL because the importer is absent.

- [ ] **Step 2: Implement ordered safety gates**

The executable interface is:

~~~text
import-portainer-parity.sh --input-dir DIR --output FILE
  --vault-password-file FILE_OR_EXECUTABLE
  [--mapping config/portainer-parity.yml]
~~~

Use set -eu, set +x, and umask 077. Resolve parents physically; require external
source/output/password paths, exact modes, regular non-symlink inputs, and absent
output. Render YAML to one owned mode-0600 temporary file, encrypt to a second,
verify the Ansible Vault header, pipe ansible-vault view to
scripts/portainer-parity.rb --validate-stdin, then atomically rename ciphertext
into place. The trap removes only invocation-owned temporary paths.
--validate-stdin requires exact schema, commit, stack set, and string-only values
while emitting no values.

- [ ] **Step 3: Verify, register, and commit**

~~~bash
sh -n scripts/import-portainer-parity.sh tests/portainer_parity_import_test.sh
tests/portainer_parity_import_test.sh
git add scripts/import-portainer-parity.sh scripts/portainer-parity.rb \
  tests/portainer_parity_import_test.sh tests/validate-policy.sh
git commit -m "feat: encrypt Portainer parity inputs"
~~~

### Task 4: Make Paperless worker settings declarative

**Files:**
- Modify: roles/paperless_ngx/defaults/main.yml
- Modify: roles/paperless_ngx/meta/argument_specs.yml
- Modify: roles/paperless_ngx/templates/env.j2
- Modify: tests/policy_test.rb

- [ ] **Step 1: Add failing assertions**

Require integer defaults paperless_task_workers: 2 and
paperless_threads_per_worker: 1, matching specs, and exact template lines:

~~~text
PAPERLESS_TASK_WORKERS={{ paperless_task_workers }}
PAPERLESS_THREADS_PER_WORKER={{ paperless_threads_per_worker }}
~~~

Run: ruby tests/policy_test.rb

Expected: FAIL because Compose currently owns the defaults.

- [ ] **Step 2: Implement, verify, and commit**

~~~bash
ruby tests/policy_test.rb
git diff --check
git add roles/paperless_ngx tests/policy_test.rb
git commit -m "feat: manage Paperless worker settings"
~~~

### Task 5: Document the lifecycle

**Files:**
- Create: docs/portainer-parity.md
- Modify: docs/secrets.md
- Modify: tests/secrets_docs_test.rb

- [ ] **Step 1: Add the failing documentation contract**

Require all nine filenames plus outside-the-repository, non-sourcing,
never-overwrite, ciphertext-checksum, explicit-operator-deletion, and
rollback-expiry statements. Require docs/secrets.md to distinguish and link both
vaults.

Run: ruby tests/secrets_docs_test.rb

Expected: FAIL because the guide is absent.

- [ ] **Step 2: Write, verify, and commit the guide**

Document permissions, importer invocation, header/checksum validation, explicit
plaintext removal after verification, and parity-vault retirement after rollback
expiry. Tooling never deletes protected sources automatically.

~~~bash
tests/validate-docs.sh
ruby tests/secrets_docs_test.rb
git diff --check
git add docs/portainer-parity.md docs/secrets.md tests/secrets_docs_test.rb
git commit -m "docs: explain Portainer parity lifecycle"
~~~

### Task 6: Verify and stop at the protected-input gate

**Files:** none

- [ ] **Step 1: Run complete verification**

~~~bash
ruby tests/portainer_parity_mapping_test.rb
ruby tests/portainer_parity_parser_test.rb
tests/portainer_parity_import_test.sh
tests/validate-docs.sh
tests/validate-policy.sh
ansible-playbook -i inventory/local.yml site.yml --syntax-check
git diff --check
git status --short
~~~

Expected: all commands pass, no canary appears, and no files are uncommitted.

- [ ] **Step 2: Request only the external-path handoff**

Ask the operator to run the importer against protected exports. Never request
values in chat. Unknown or missing names require a reviewed classification or
exclusion before producing the real parity artifact.
