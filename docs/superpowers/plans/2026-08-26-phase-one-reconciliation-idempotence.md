# Phase One Reconciliation Idempotence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every enabled Arr relationship converge complete owned state and report zero changes on a stable second normal run.

**Architecture:** Normalize desired and current owned projections before mutation, and use private desired-input fingerprints for masked credentials. Exercise extracted production task blocks against stateful local HTTP fixtures, then add a second live enabled convergence as the end-to-end acceptance gate.

**Tech Stack:** Ansible URI tasks, Ruby TCPServer fixtures, SHA-256 fingerprints, Docker integration harness.

---

### Task 1: Build the stateful reconciliation behavior fixture

**Files:**
- Create: `tests/media_acquisition_reconciliation_test.rb`
- Modify: `tests/validate-policy.sh`
- Modify: `tests/policy_ci_test.rb`
- Modify: `tests/policy_mutation_support.rb`
- Test: `tests/media_acquisition_reconciliation_test.rb`

- [ ] **Step 1: Create a failing extracted-task fixture**

Follow `tests/paperless_mail_reconciliation_test.rb`: use `TCPServer`, record requests, keep mutable application/client/indexer/Bazarr state, extract the production task blocks by their first and last task names, and execute them with `ansible-playbook -i localhost, -c local`.

The fixture state must expose these endpoints and methods:

```ruby
ROUTES = {
  ["GET", "/api/v1/applications"] => :applications,
  ["POST", "/api/v1/applications"] => :create_application,
  ["PUT", %r{\A/api/v1/applications/\d+\z}] => :update_application,
  ["GET", "/api/v1/indexer"] => :indexers,
  ["POST", "/api/v1/indexer"] => :create_indexer,
  ["PUT", %r{\A/api/v1/indexer/\d+\z}] => :update_indexer,
  ["GET", "/api/v3/downloadclient"] => :download_clients,
  ["POST", "/api/v3/downloadclient"] => :create_download_client,
  ["PUT", %r{\A/api/v3/downloadclient/\d+\z}] => :update_download_client,
  ["GET", "/api/system/settings"] => :bazarr_settings,
  ["POST", "/api/system/settings"] => :update_bazarr_settings
}.freeze
```

Store secret-bearing response fields as `"********"`, but retain submitted secrets privately in fixture state so the test can prove desired bodies repair them without printing them.

Add scenario tables for every owned field enumerated in Tasks 3 and 4 below.
Each mutation must cause exactly one applicable PUT/POST and `changed=1`;
stable state must report `changed=0`. Add fingerprint-change and
fingerprint-stable scenarios for all four relationship classes and Configarr.

- [ ] **Step 2: Run the new test and confirm RED**

Run: `ruby tests/media_acquisition_reconciliation_test.rb`

Expected: FAIL naming omitted owned fields and perpetual-change writes in the current tasks.

- [ ] **Step 3: Register the behavior test**

Add exactly one policy command:

```sh
ruby tests/media_acquisition_reconciliation_test.rb
```

Require that line in `tests/policy_ci_test.rb` and add the new Ruby fixture to `POLICY_FIXTURE_PATHS` in `tests/policy_mutation_support.rb`.

- [ ] **Step 4: Commit the RED fixture**

```bash
git add tests/media_acquisition_reconciliation_test.rb tests/validate-policy.sh tests/policy_ci_test.rb tests/policy_mutation_support.rb
git commit -m "test: expose acquisition reconciliation drift"
```

### Task 2: Add private desired-input fingerprints

**Files:**
- Create: `roles/arr/tasks/reconciliation_fingerprints.yml`
- Create: `roles/arr/tasks/record_reconciliation_fingerprints.yml`
- Modify: `roles/arr/tasks/main.yml`
- Modify: `tests/media_acquisition_reconciliation_test.rb`
- Test: `tests/media_acquisition_reconciliation_test.rb`

- [ ] **Step 1: Pin the five private fingerprints in the fixture**

Require these runtime files and exact permissions:

```ruby
EXPECTED_FINGERPRINTS = %w[
  .configarr-input.sha256
  .prowlarr-applications-input.sha256
  .servarr-sabnzbd-input.sha256
  .prowlarr-indexers-input.sha256
  .bazarr-providers-input.sha256
].freeze
```

Tests must reject missing files, modes other than `0600`, changed fingerprints that do not force reconciliation, and failed reconciliation that advances a fingerprint.

- [ ] **Step 2: Compute and read fingerprints under no_log**

Create `reconciliation_fingerprints.yml` with these canonical desired values:

```yaml
- name: Compute private Arr desired-input fingerprints
  ansible.builtin.set_fact:
    arr_desired_reconciliation_fingerprints:
      prowlarr_applications: "{{ arr_prowlarr_applications | to_json | hash('sha256') }}"
      servarr_sabnzbd: >-
        {{ {'instances': arr_servarr_instances,
            'name': arr_sabnzbd_client_name,
            'host': arr_sabnzbd_host,
            'port': arr_sabnzbd_port,
            'api_key': vault_downloaders_sabnzbd_api_key,
            'username': vault_downloaders_sabnzbd_admin_username,
            'password': vault_downloaders_sabnzbd_admin_password} | to_json | hash('sha256') }}
      prowlarr_indexers: "{{ media_arr_indexers | to_json | hash('sha256') }}"
      bazarr_providers: "{{ media_bazarr_providers | to_json | hash('sha256') }}"
      configarr: >-
        {{ {'config': lookup('file', role_path ~ '/files/configarr/config.yml'),
            'radarr_api_key': vault_arr_radarr_api_key,
            'sonarr_api_key': vault_arr_sonarr_api_key,
            'image': 'ghcr.io/raydak-labs/configarr:1.28.0@sha256:008d8659ff35f63fbcc20b860b33ba7cc49e8d7458a6ec446810ec4d783ef017'} |
           to_json | hash('sha256') }}
  changed_when: false
  no_log: true
```

Stat and slurp the five files, validate each existing file is regular, non-symlink, mode `0600`, owned by `nas_uid:nas_gid`, and build `arr_installed_reconciliation_fingerprints`, defaulting missing values to an empty string.

Declare the filename map once and use it for both loading and recording:

```yaml
arr_reconciliation_fingerprint_paths:
  configarr: .configarr-input.sha256
  prowlarr_applications: .prowlarr-applications-input.sha256
  servarr_sabnzbd: .servarr-sabnzbd-input.sha256
  prowlarr_indexers: .prowlarr-indexers-input.sha256
  bazarr_providers: .bazarr-providers-input.sha256
```

- [ ] **Step 3: Record fingerprints only after verification**

Create `record_reconciliation_fingerprints.yml` using `ansible.builtin.copy`:

```yaml
- name: Record verified Arr desired-input fingerprints
  ansible.builtin.copy:
    content: "{{ item.value }}\n"
    dest: "{{ platform_runtime_dir }}/services/arr/{{ arr_reconciliation_fingerprint_paths[item.key] }}"
    owner: "{{ nas_uid }}"
    group: "{{ nas_gid }}"
    mode: "0600"
  loop: "{{ arr_desired_reconciliation_fingerprints | dict2items }}"
  loop_control:
    label: "{{ item.key }}"
  no_log: true
```

Do not write any fingerprint until all applicable post-read assertions have succeeded.

- [ ] **Step 4: Wire and verify**

Include fingerprint loading before any API mutation and recording after `verify.yml`. Run:

```bash
ruby tests/media_acquisition_reconciliation_test.rb
../../.venv/bin/ansible-playbook site.yml --syntax-check
../../.venv/bin/ansible-lint --strict roles/arr
```

Expected: fingerprint permission and failure-order scenarios pass.

- [ ] **Step 5: Commit**

```bash
git add roles/arr/tasks tests/media_acquisition_reconciliation_test.rb
git commit -m "feat: track verified acquisition inputs"
```

### Task 3: Normalize complete Prowlarr and Servarr relationships

**Files:**
- Modify: `roles/arr/tasks/reconcile_prowlarr_application.yml`
- Modify: `roles/arr/tasks/reconcile_prowlarr.yml`
- Modify: `roles/arr/tasks/reconcile_servarr_download_client.yml`
- Modify: `roles/arr/tasks/verify.yml`
- Modify: `roles/downloaders/tasks/verify.yml`
- Test: `tests/media_acquisition_reconciliation_test.rb`

- [ ] **Step 1: Define exact owned projections**

For each desired/current object, build mappings containing these exact owned
fields:

- Prowlarr applications: `name`, `enable`, `syncLevel`, `implementation`,
  `implementationName`, `configContract`, sorted `tags`, and field-map values
  for `prowlarrUrl`, `baseUrl`, blank `username`, blank `password`, `apiKey`,
  and sorted `syncCategories`.
- Radarr/Sonarr SABnzbd clients: `name`, `enable`, `protocol`, `priority`,
  `removeCompletedDownloads`, `removeFailedDownloads`, `implementation`,
  `implementationName`, `configContract`, sorted `tags`, and field-map values
  for `host`, integer `port`, `useSsl`, `urlBase`, `apiKey`, `username`,
  `password`, and `tvCategory`/`movieCategory` as applicable.
- Operator Prowlarr indexers: `name`, `enable`, `priority`, `implementation`,
  `implementationName`, `configContract`, sorted `tags`, and every declared
  desired `fields[].name` whose current value is readable.
- Bazarr: authentication type and username; Radarr/Sonarr enablement, host,
  integer port, base URL, SSL, and identical-path mappings; sorted languages;
  sorted enabled provider names; and every readable declared provider setting.

Convert API `fields` arrays to dictionaries with
`items2dict(key_name='name', value_name='value')`, normalize integer and boolean
types, normalize absent optional strings to `''`, and sort tags and category
lists before comparison. Keep masked values out of current projections and use
the private fingerprint predicate for their drift.

The Prowlarr application update predicate must be:

```yaml
arr_prowlarr_application_needs_update: >-
  {{ arr_prowlarr_application_matches | length == 0 or
     arr_prowlarr_application_current_projection != arr_prowlarr_application_desired_projection or
     arr_installed_reconciliation_fingerprints.prowlarr_applications !=
       arr_desired_reconciliation_fingerprints.prowlarr_applications }}
```

The Servarr client predicate uses the same form with `servarr_sabnzbd`. Indexers use `prowlarr_indexers` and must refuse duplicates before their mutation loop.

- [ ] **Step 2: Strengthen post-read verification**

Extend `roles/arr/tasks/verify.yml` and `roles/downloaders/tasks/verify.yml` to rebuild the same projections and require equality, not existence-only assertions. Credential-bearing bodies remain `no_log: true`.

- [ ] **Step 3: Run every mutation scenario**

Run: `ruby tests/media_acquisition_reconciliation_test.rb`

Expected: every owned-field mutant produces one repair, stable complete state produces no reported change, duplicate identity refuses before mutation, and secret text is absent from stdout/stderr.

- [ ] **Step 4: Commit**

```bash
git add roles/arr/tasks roles/downloaders/tasks tests/media_acquisition_reconciliation_test.rb
git commit -m "fix: reconcile complete acquisition relationships"
```

### Task 4: Make Configarr and Bazarr idempotent

**Files:**
- Modify: `roles/arr/tasks/configarr.yml`
- Modify: `roles/arr/tasks/reconcile_bazarr.yml`
- Modify: `roles/arr/tasks/verify.yml`
- Modify: `tests/configarr_job_test.rb`
- Modify: `tests/media_acquisition_reconciliation_test.rb`
- Test: `tests/media_acquisition_reconciliation_test.rb`

- [ ] **Step 1: Pre-read Configarr-owned state**

Move the Configarr GET/readback before the job. Build desired/current projections
for the named `HD Bluray + WEB 1080p` quality profile, the complete quality
definitions returned for Radarr and Sonarr, the `NAS Repack or Proper` custom
format and its score, and the Radarr/Sonarr naming booleans and format strings
declared in the bundled Configarr YAML. Normalize nested arrays by stable name
or quality order as appropriate, compute `arr_configarr_owned_state_current`,
and set:

```yaml
arr_configarr_run_required: >-
  {{ arr_configarr_owned_state_current != arr_configarr_owned_state_desired or
     arr_installed_reconciliation_fingerprints.configarr !=
       arr_desired_reconciliation_fingerprints.configarr }}
```

Run the one-shot only when this fact is true; keep its failure checks and set `changed_when: true`. Always perform the post-read assertion, including on a skipped stable job.

- [ ] **Step 2: Gate Bazarr provider writes**

Build readable current/desired provider projections. When the API masks settings, submit the complete desired provider body safely but set `changed_when` from projection or fingerprint drift:

```yaml
  changed_when: >-
    arr_bazarr_provider_projection_current[item.name] | default({}) !=
      arr_bazarr_provider_projection_desired[item.name] or
    arr_installed_reconciliation_fingerprints.bazarr_providers !=
      arr_desired_reconciliation_fingerprints.bazarr_providers
```

- [ ] **Step 3: Verify RED/GREEN behavior**

Run:

```bash
ruby tests/configarr_job_test.rb
ruby tests/media_acquisition_reconciliation_test.rb
ruby tests/media_acquisition_phase1_test.rb
```

Expected: a stable run skips Configarr, Bazarr unchanged resubmission reports no change, and changed desired inputs repair then record fingerprints.

- [ ] **Step 4: Commit**

```bash
git add roles/arr/tasks tests/configarr_job_test.rb tests/media_acquisition_reconciliation_test.rb
git commit -m "fix: make acquisition reconciliation idempotent"
```

### Task 5: Require a second normal enabled convergence

**Files:**
- Modify: `tests/integration.sh:1615-1655`
- Modify: `tests/policy_ci_test.rb`
- Modify: `tests/integration_suite_test.sh`
- Test: `tests/integration_suite_test.sh`

- [ ] **Step 1: Add the failing lifecycle assertion**

Require Arr and downloader suite bodies to invoke a second normal tagged play and parse the recap for `changed=0`; check mode remains afterward.

- [ ] **Step 2: Add the second convergence helper**

Inside the integration runner add:

```sh
run_enabled_idempotence() {
  idempotence_tags=$1
  idempotence_output=/tmp/media-acquisition-idempotence.txt
  run_play --tags "$idempotence_tags" >"$idempotence_output"
  grep -Eq 'changed=0[[:space:]]+unreachable=0[[:space:]]+failed=0' "$idempotence_output" || {
    cat "$idempotence_output" >&2
    printf '%s\n' 'enabled media acquisition convergence was not idempotent' >&2
    exit 1
  }
}
```

Call `run_enabled_idempotence arr` in the Arr suite and `run_enabled_idempotence arr,downloaders` in the downloader suite before check mode.

- [ ] **Step 3: Verify and commit**

Run:

```bash
tests/integration_suite_test.sh
ruby tests/policy_ci_test.rb
tests/integration.sh --describe-suite arr
tests/integration.sh --describe-suite downloaders
```

Expected: suite contracts prove the second normal convergence and correct tags.

```bash
git add tests/integration.sh tests/integration_suite_test.sh tests/policy_ci_test.rb
git commit -m "test: require enabled acquisition idempotence"
```
