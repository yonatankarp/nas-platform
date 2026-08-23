# Media Acquisition Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permanently remove every tinyMediaManager repository declaration after its successful NAS retirement checkpoint, and install the inert Phase 0 network, storage, credentials, immutable contracts, and CI scaffolding without starting an acquisition container.

**Architecture:** Record the seven approved lifecycle projects as `planned` entries and describe their exact service, CPU, port, profile, and job classes in strict `config/media-acquisition.yml`. `host_prep` creates the project-derived external bridge and classified NAS directories while both transport flags remain false; no acquisition role or Compose tree exists until its later implementation phase. Permanent tinyMediaManager cleanup deletes repository declarations only, never preserved NAS state or media.

**Tech Stack:** Ansible Core, `community.docker.docker_network`, strict YAML, Ruby mutation/property tests, POSIX shell contracts, Docker Desktop/NAS inventories, immutable deployment bundles.

---

## Scope and dependency order

The operator confirmed the transitional release reached the NAS: tinyMediaManager is absent, its state was preserved, Movies and Series remain readable, and the retirement report was recorded. This is release two of the approved retirement.

This is Phase 0 only. It must not create `roles/{arr,downloaders,bindery,kapowarr,pinchflat,trailarr,seerr}` or `services/{arr,downloaders,bindery,kapowarr,pinchflat,trailarr,seerr}`; start an acquisition container; enable Usenet/torrents; download content; remove Jellyfin Open Subtitles; or choose providers, indexers, accounts, or subtitle languages.

Tasks are sequential: cleanup → catalog/roster → credentials → network/storage → immutable bundle → static contracts → CI → docs/final verification.

## Approved-design coverage

| Approved Phase 0 requirement | Implemented and proved by |
|---|---|
| Permanent tinyMediaManager source/declaration cleanup after NAS evidence | Tasks 1 and 8 |
| Seven lifecycle projects remain visible but inert | Tasks 2, 6, and 7 |
| Exact service, CPU, port, torrent-profile, identity, and Configarr job classes | Tasks 2 and 6 |
| Project-derived external bridge; Jellyfin and Audiobookshelf join it | Task 4 |
| Acquisition cache paths, final user libraries, and future critical app state | Task 4 |
| Deterministic initial arr/SAB credentials with full vault parity | Task 3 |
| Immutable release input and checksum | Task 5 |
| Site/verify tags, static contracts, selective suites, Mac/NAS proofs | Tasks 4, 6, 7, and 8 |
| No service source, transport enablement, download, provider/account/language decision, or Open Subtitles removal | Tasks 2, 3, 6, and 8 |

## File map

- Delete `roles/tinymediamanager/`, `services/tinymediamanager/`, its contract/expectation/fixture, Mac runner, and four lifecycle hooks.
- Modify every active manifest, inventory, vault, playbook, CI, integration, Mac, monitoring, policy, and current operator-documentation reference. Historical superpowers plans/specs remain unchanged.
- Create `config/media-acquisition.yml`, `tests/media_acquisition_foundation_test.rb`, seven planned expectation files, and seven foundation-only contract scripts.
- Modify host-prep/preflight/site/verify for the bridge, disabled transports, storage, and read-only verification.
- Modify deployment-bundle tasks/template/verifier to copy and checksum the catalog.
- Modify classifier/integration/workflow contracts for seven foundation-only suites.

### Task 1: Permanently delete tinyMediaManager declarations and lifecycle coverage

**Files:**
- Delete: `roles/tinymediamanager/defaults/main.yml`
- Delete: `roles/tinymediamanager/meta/argument_specs.yml`
- Delete: `roles/tinymediamanager/tasks/main.yml`
- Delete: `roles/tinymediamanager/templates/env.j2`
- Delete: `services/tinymediamanager/compose.yml`
- Delete: `services/tinymediamanager/compose.mac.yml`
- Delete: `services/tinymediamanager/compose.integration.yml`
- Delete: `tests/contracts/tinymediamanager.sh`
- Delete: `tests/expected/tinymediamanager.yml`
- Delete: `tests/tinymediamanager_retirement_fixture.yml`
- Delete: `tests/tinymediamanager_retirement_inspection_test.rb`
- Delete: `tests/mac/run-tinymediamanager-contract.sh`
- Delete: `tests/mac/hooks/drift/50-tinymediamanager.sh`
- Delete: `tests/mac/hooks/fixtures-recreate/50-tinymediamanager.sh`
- Delete: `tests/mac/hooks/pre-converge/50-tinymediamanager.sh`
- Delete: `tests/mac/hooks/verify/50-tinymediamanager.sh`
- Modify: `services/manifest.yml`, `config/managed-user-capabilities.yml`, `inventory/group_vars/{all,mac_hosts}/main.yml`
- Modify: `site.yml`, `verify.yml`, `roles/production_auto_deploy/defaults/main.yml`
- Modify: `filter_plugins/vault_credential_schema.py`, `roles/vault_contract/{meta/argument_specs.yml,tasks/main.yml}`
- Modify: `inventory/group_vars/all/vault.yml.example`, `templates/vault-plain.yml.j2`, `generate-secrets.yml`, `tests/generate-ephemeral-vault.sh`
- Modify: `tests/ci/{classify_changes.rb,classify_changes_test.rb,workflow_test.rb}`, `tests/{integration.sh,integration_suite_test.sh}`
- Modify: `tests/mac/cleanup.sh`, `tests/mac/config-isolation.sh`, `tests/mac/dozzle-drift-hook-test.sh`, `tests/mac/hook-coverage-test.sh`
- Modify: `tests/mac/hooks/fixtures-persistence/00-services.sh`, `tests/mac/hooks/fixtures-seed/00-services.sh`
- Modify: `tests/mac/integration-context-test.sh`, `tests/mac/lib.sh`, `tests/mac/manual-review.md`, `tests/mac/manual-validation-handoff.rb`
- Modify: `tests/mac/manual-validation-runner-test.sh`, `tests/mac/report.rb`, `tests/mac/run-contract.sh`, `tests/mac/run-phase-status-test.sh`, `tests/mac/run.sh`, `tests/mac/verify.sh`
- Modify: `tests/contracts/dozzle.sh`, `tests/contracts/registry.yml`, `tests/dozzle_quality_test.rb`
- Modify: `tests/managed_user_capabilities_test.rb`, `tests/policy_beszel_test.rb`, `tests/policy_deployment_test.rb`, `tests/policy_manifest_test.rb`
- Modify: `tests/policy_mutation_support.rb`, `tests/policy_platform_test.rb`, `tests/policy_support.rb`, `tests/policy_test.rb`, `tests/policy_vault_test.rb`
- Modify: `tests/sandbox_cleanup.sh`, `tests/secrets_docs_test.rb`, `tests/vault_credential_schema_test.py`, `tests/docs_links_test.rb`
- Modify: `README.md`, `docs/adding-a-service.md`, `docs/getting-started.md`, `docs/getting-started-mac.md`, `docs/getting-started-nas.md`, `docs/secrets.md`

- [ ] **Step 1: Add the failing cleanup policy**

Add to `tests/policy_test.rb`:

```ruby
active_tmm_files = Dir.glob(File.join(ROOT, "**", "*"), File::FNM_DOTMATCH).filter_map do |path|
  next unless File.file?(path)
  relative = path.delete_prefix("#{ROOT}/")
  next if relative.start_with?("docs/superpowers/plans/", "docs/superpowers/specs/")
  relative if File.binread(path).match?(/tinymediamanager/i)
end
check(failures, active_tmm_files.empty?,
      "active repository declarations still mention tinyMediaManager: #{active_tmm_files.join(', ')}")
check(failures, !File.exist?(File.join(ROOT, "roles", "tinymediamanager")) &&
                !File.exist?(File.join(ROOT, "services", "tinymediamanager")),
      "tinyMediaManager role and Compose sources must be deleted after the NAS checkpoint")
```

Mutation-test a recreated role and a current README mention. Exempt only the
historical decision-record trees, not all docs.

- [ ] **Step 2: Run RED**

Run: `ruby tests/policy_test.rb`

Expected: FAIL listing active declarations.

- [ ] **Step 3: Delete all owned source and plumbing**

Use `apply_patch` deletion patches. Remove tMM from manifest/roster, managed-user matrix, site/verify, auto-deploy tag, vault filter/example/spec/mapping/templates/generators, CI, integration, Mac allocations/hooks/reports/cleanup, Dozzle expectations, registry, and policy fixtures. Never add a task addressing `{{ nas_docker_root }}/tinymediamanager/data` or media.

Temporary roster:

```ruby
EXPECTED_SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx
].freeze
```

- [ ] **Step 4: Replace transitional current prose**

Current docs say the checkpoint completed and declarations were removed. Delete active restore/start/authenticate/verify instructions. Keep historical plans/specs byte-exact.

- [ ] **Step 5: Verify cleanup**

```sh
ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
ruby tests/policy_vault_test.rb
ruby tests/managed_user_capabilities_test.rb
ruby tests/secrets_docs_test.rb
tests/integration_suite_test.sh
git grep -inE 'tinymediamanager|tinyMediaManager' -- \
  ':(exclude)docs/superpowers/plans/**' \
  ':(exclude)docs/superpowers/specs/**'
git diff --check
```

Expected: tests pass; grep prints nothing/exits 1; no destructive state/media task.

- [ ] **Step 6: Commit**

```sh
git add -A
git commit -m "chore: remove retired tinymediamanager declarations"
```

### Task 2: Define the inert acquisition catalog and planned roster

**Files:**
- Create: `config/media-acquisition.yml`
- Create: `tests/media_acquisition_foundation_test.rb`
- Create: `tests/expected/{arr,downloaders,bindery,kapowarr,pinchflat,trailarr,seerr}.yml`
- Modify: `services/manifest.yml`
- Modify: `tests/{policy_support.rb,policy_test.rb,policy_manifest_test.rb,policy_mutation_support.rb,validate-policy.sh}`

- [ ] **Step 1: Write the failing strict catalog test**

Use one-document, alias/anchor/duplicate-key-safe YAML loading and compare to:

```ruby
EXPECTED = {
  "schema" => 1, "enabled" => false,
  "network" => { "logical_name" => "media-control", "driver" => "bridge" },
  "filesystem_identity" => {
    "uid_environment" => "NAS_UID", "gid_environment" => "NAS_GID", "umask" => "022"
  },
  "projects" => {
    "arr" => { "role" => "arr", "status" => "planned", "services" => {
      "radarr" => { "class" => "long_running", "cpus" => 1.0, "host_port" => 7878 },
      "sonarr" => { "class" => "long_running", "cpus" => 1.0, "host_port" => 8989 },
      "prowlarr" => { "class" => "long_running", "cpus" => 0.5, "host_port" => 9696 },
      "bazarr" => { "class" => "long_running", "cpus" => 1.0, "host_port" => 6767 },
      "configarr" => { "class" => "one_shot", "cpus" => 0.5, "host_port" => nil,
                       "compose_profile" => "jobs" }
    } },
    "downloaders" => { "role" => "downloaders", "status" => "planned", "services" => {
      "sabnzbd" => { "class" => "long_running", "cpus" => 2.0, "host_port" => 8085 },
      "unpackerr" => { "class" => "long_running", "cpus" => 1.0, "host_port" => nil },
      "gluetun" => { "class" => "long_running", "cpus" => 0.5, "host_port" => 8082,
                     "compose_profile" => "torrent" },
      "qbittorrent" => { "class" => "long_running", "cpus" => 1.5, "host_port" => nil,
                         "compose_profile" => "torrent" }
    } },
    "bindery" => { "role" => "bindery", "status" => "planned", "services" => {
      "bindery" => { "class" => "long_running", "cpus" => 1.0, "host_port" => 3000 } } },
    "kapowarr" => { "role" => "kapowarr", "status" => "planned", "services" => {
      "kapowarr" => { "class" => "long_running", "cpus" => 1.0, "host_port" => 5656 } } },
    "pinchflat" => { "role" => "pinchflat", "status" => "planned", "services" => {
      "pinchflat" => { "class" => "long_running", "cpus" => 1.0, "host_port" => 8945 } } },
    "trailarr" => { "role" => "trailarr", "status" => "planned", "services" => {
      "trailarr" => { "class" => "long_running", "cpus" => 1.0, "host_port" => 7889 } } },
    "seerr" => { "role" => "seerr", "status" => "planned", "services" => {
      "seerr" => { "class" => "long_running", "cpus" => 1.0, "host_port" => 5055 } } }
  }
}.freeze
```

Require Configarr as sole one-shot and all future role/service directories absent. Mutation-test enabled, every CPU/port, Configarr class/profile, manifest status, extra project, duplicate key, and premature `services/arr/compose.yml`.

- [ ] **Step 2: Run RED**

Run: `ruby tests/media_acquisition_foundation_test.rb`

Expected: FAIL because catalog is absent.

- [ ] **Step 3: Add catalog and seven planned manifest entries**

Create YAML equivalent to `EXPECTED`. Append seven matching `status: planned` entries. Extend the pinned roster. Compare managed-user capabilities only with implemented/accepted entries; planned projects must not invent user APIs.

- [ ] **Step 4: Add exact expectations**

`tests/expected/arr.yml`:

```yaml
---
role: arr
container_cpus:
  radarr: 1.0
  sonarr: 1.0
  prowlarr: 0.5
  bazarr: 1.0
  configarr: 0.5
vault_keys:
  - vault_arr_radarr_api_key
  - vault_arr_sonarr_api_key
  - vault_arr_prowlarr_api_key
  - vault_arr_bazarr_api_key
```

`tests/expected/downloaders.yml`:

```yaml
---
role: downloaders
container_cpus:
  sabnzbd: 2.0
  unpackerr: 1.0
  gluetun: 0.5
  qbittorrent: 1.5
vault_keys:
  - vault_downloaders_sabnzbd_username
  - vault_downloaders_sabnzbd_password
  - vault_downloaders_sabnzbd_api_key
```

The other five files use their exact single-container CPU and `vault_keys: []`. Pass status into `pinned_service_expectations`; empty vault arrays are valid only for planned entries. Mutation-test an implemented empty list.

- [ ] **Step 5: Register and verify**

Add `ruby tests/media_acquisition_foundation_test.rb` to `tests/validate-policy.sh`.

```sh
ruby tests/media_acquisition_foundation_test.rb
ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
```

Expected: pass; seven planned entries; no acquisition source tree.

- [ ] **Step 6: Commit**

```sh
git add config/media-acquisition.yml services/manifest.yml tests
git commit -m "test: define media acquisition foundation contract"
```

### Task 3: Add deterministic first-slice vault plumbing

**Files:**
- Modify: `filter_plugins/vault_credential_schema.py`
- Modify: `inventory/group_vars/all/vault.yml.example`
- Modify: `roles/vault_contract/{meta/argument_specs.yml,tasks/main.yml}`
- Modify: `templates/vault-plain.yml.j2`, `generate-secrets.yml`, `tests/generate-ephemeral-vault.sh`
- Modify: `tests/{policy_vault_test.rb,vault_credential_schema_test.py,secrets_docs_test.rb}`, `docs/secrets.md`

- [ ] **Step 1: Write RED key/shape mutations**

Require:

```ruby
FOUNDATION_KEYS = %w[
  vault_arr_radarr_api_key vault_arr_sonarr_api_key
  vault_arr_prowlarr_api_key vault_arr_bazarr_api_key
  vault_downloaders_sabnzbd_username vault_downloaders_sabnzbd_password
  vault_downloaders_sabnzbd_api_key
].freeze
```

API keys: lowercase hexadecimal length 64. Username/password: nonempty. Mutate short/uppercase/missing/duplicate values and removal from the no-log mapping.

- [ ] **Step 2: Run RED**

```sh
ruby tests/policy_vault_test.rb
PYTHONDONTWRITEBYTECODE=1 python3 tests/vault_credential_schema_test.py
```

Expected: FAIL naming seven keys.

- [ ] **Step 3: Add schema and sanitized examples**

Add `HEX_64 = re.compile(r"^[0-9a-f]{64}$")`; five `PATTERN` and two `NONEMPTY` rules directly in `CREDENTIAL_RULES`. Add required string options and mapping entries; all tasks stay `no_log: true`. Examples are 64 zeroes, `example-sabnzbd-admin`, and `example-password`.

- [ ] **Step 4: Generate distinct values**

```yaml
arr_radarr_api_key: "{{ lookup('password', '/dev/null chars=hexdigits length=64') | lower }}"
arr_sonarr_api_key: "{{ lookup('password', '/dev/null chars=hexdigits length=64') | lower }}"
arr_prowlarr_api_key: "{{ lookup('password', '/dev/null chars=hexdigits length=64') | lower }}"
arr_bazarr_api_key: "{{ lookup('password', '/dev/null chars=hexdigits length=64') | lower }}"
downloaders_sabnzbd_username: nasadmin
downloaders_sabnzbd_password: "{{ lookup('password', password_spec) }}"
downloaders_sabnzbd_api_key: "{{ lookup('password', '/dev/null chars=hexdigits length=64') | lower }}"
```

Render in `vault-plain.yml.j2`; ephemeral API keys call `openssl rand -hex 32` separately. Add no provider/indexer/account/language/ComicVine/Seerr/VPN fields.

- [ ] **Step 5: Document and verify**

```sh
ruby tests/policy_vault_test.rb
PYTHONDONTWRITEBYTECODE=1 python3 tests/vault_credential_schema_test.py
ruby tests/secrets_docs_test.rb
tests/generate-ephemeral-vault.sh --self-test
ansible-playbook generate-secrets.yml --syntax-check
```

Expected: pass; self-test silent.

- [ ] **Step 6: Commit**

```sh
git add filter_plugins inventory/group_vars/all/vault.yml.example roles/vault_contract \
  templates generate-secrets.yml tests/generate-ephemeral-vault.sh \
  tests/policy_vault_test.rb tests/vault_credential_schema_test.py \
  tests/secrets_docs_test.rb docs/secrets.md
git commit -m "feat: add acquisition foundation credentials"
```

### Task 4: Create the control network and classified storage

**Files:**
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `inventory/group_vars/{nas_hosts,mac_hosts}/main.yml`
- Modify: `roles/preflight/meta/argument_specs.yml`
- Modify: `roles/host_prep/{meta/argument_specs.yml,tasks/main.yml}`
- Create: `roles/host_prep/tasks/verify_media_acquisition.yml`
- Modify: `services/audiobookshelf/compose.yml`, `roles/audiobookshelf/{meta/argument_specs.yml,templates/env.j2}`, `tests/contracts/audiobookshelf.sh`
- Modify: `services/jellyfin/compose.yml`, `roles/jellyfin/{meta/argument_specs.yml,templates/env.j2}`, `tests/contracts/jellyfin.sh`
- Modify: `tests/{media_acquisition_foundation_test.rb,policy_platform_test.rb,policy_manifest_test.rb}`
- Modify: `tests/mac/{run.sh,cleanup.sh}`, `site.yml`, `verify.yml`

- [ ] **Step 1: Add failing host assertions**

Require exact mode-0755, owner/group-free paths:

```ruby
EXPECTED_STORAGE = {
  "{{ nas_media_root }}/Media/.acquisition/usenet/movies" => "cache",
  "{{ nas_media_root }}/Media/.acquisition/usenet/series" => "cache",
  "{{ nas_media_root }}/Media/.acquisition/usenet/audiobooks" => "cache",
  "{{ nas_media_root }}/Media/.acquisition/torrents/movies" => "cache",
  "{{ nas_media_root }}/Media/.acquisition/torrents/series" => "cache",
  "{{ nas_media_root }}/Media/.acquisition/torrents/audiobooks" => "cache",
  "{{ nas_media_root }}/Books/.acquisition/usenet/ebooks" => "cache",
  "{{ nas_media_root }}/Books/.acquisition/usenet/comics" => "cache",
  "{{ nas_media_root }}/Books/.acquisition/torrents/ebooks" => "cache",
  "{{ nas_media_root }}/Books/.acquisition/torrents/comics" => "cache",
  "{{ nas_media_root }}/Media/Movies" => "user",
  "{{ nas_media_root }}/Media/Series" => "user",
  "{{ nas_media_root }}/Media/Audiobooks" => "user",
  "{{ nas_media_root }}/Media/YouTube" => "user",
  "{{ nas_media_root }}/Books/Ebooks" => "user",
  "{{ nas_media_root }}/Books/Comics" => "user",
  "{{ nas_docker_root }}/radarr/config" => "critical",
  "{{ nas_docker_root }}/sonarr/config" => "critical",
  "{{ nas_docker_root }}/prowlarr/config" => "critical",
  "{{ nas_docker_root }}/bazarr/config" => "critical",
  "{{ nas_docker_root }}/sabnzbd/config" => "critical",
  "{{ nas_docker_root }}/qbittorrent/config" => "critical",
  "{{ nas_docker_root }}/bindery/config" => "critical",
  "{{ nas_docker_root }}/kapowarr/config" => "critical",
  "{{ nas_docker_root }}/pinchflat/config" => "critical",
  "{{ nas_docker_root }}/trailarr/config" => "critical",
  "{{ nas_docker_root }}/seerr/config" => "critical"
}.freeze
```

Require literal false transports in both host groups, derived network identity,
parsed bridge creation, and read-only verifier. Media paths have no owner/group;
critical Docker paths use `nas_uid`/`nas_gid`. Mutate recovery/ownership/missing
leaf/true flag/constant Mac name/driver/broad deletion.

- [ ] **Step 2: Run RED**

```sh
ruby tests/media_acquisition_foundation_test.rb
ruby tests/policy_platform_test.rb
```

Expected: FAIL for flags/network/paths.

- [ ] **Step 3: Add disabled host inputs**

Both host groups:

```yaml
media_usenet_enabled: false
media_torrent_enabled: false
```

Add both to host-scoped variables and required boolean preflight arguments, not shared group vars.

- [ ] **Step 4: Add derived bridge**

Shared inventory:

```yaml
platform_media_control_network: >-
  {{ (platform_project_name ~ '-media-control')
     if platform_project_name | default('') | length > 0 else 'media-control' }}
```

Host prep after containment validation:

```yaml
- name: Create the external media control network
  community.docker.docker_network:
    name: "{{ platform_media_control_network }}"
    driver: bridge
    state: present
```

Require network string in argument specs. NAS cleanup never deletes it; Mac cleanup removes only validated disposable prefix.

- [ ] **Step 5: Add storage leaves**

Replace tMM storage and broad Books declaration with `EXPECTED_STORAGE`, reusing
Movies/Series/Audiobooks entries. Critical app roots use owner/group identity;
media cache/user roots do not. Never recursively chown.

- [ ] **Step 6: Join the existing API readers to the bridge**

Add this exact network to both canonical Compose files:

```yaml
networks:
  media-control:
    external: true
    name: ${PLATFORM_MEDIA_NETWORK:?}
```

Add `networks: [media-control]` to Jellyfin and Audiobookshelf without changing
ports or read-only mounts. Render exactly
`PLATFORM_MEDIA_NETWORK={{ platform_media_control_network }}` in each env
template and require the input in both role argument specs. Extend each
service-owned contract to require the external network and environment
assignment. Mutation-test an internal network, a constant NAS-only name, and a
writable reader media mount.

- [ ] **Step 7: Add site/verify tags**

Create:

```yaml
---
- name: Inspect the external media control network
  community.docker.docker_network_info:
    name: "{{ platform_media_control_network }}"
  register: media_acquisition_network
  changed_when: false
  tags: [platform_verify_media_acquisition_foundation]

- name: Verify the inert media acquisition foundation
  ansible.builtin.assert:
    that:
      - media_acquisition_network.exists
      - media_acquisition_network.network.Driver == 'bridge'
      - not (media_usenet_enabled | bool)
      - not (media_torrent_enabled | bool)
    fail_msg: The media acquisition foundation differs from its disabled declaration.
  tags: [platform_verify_media_acquisition_foundation]
```

Add `media_acquisition_foundation` to host_prep site tags. `verify.yml` includes only `tasks_from: verify_media_acquisition` under the platform verification tag, never host_prep main.

- [ ] **Step 8: Verify and commit**

```sh
ruby tests/media_acquisition_foundation_test.rb
ruby tests/policy_platform_test.rb
ruby tests/policy_manifest_test.rb
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ansible-playbook -i inventory/local.yml verify.yml --syntax-check
ansible-playbook -i inventory/mac.yml site.yml --syntax-check
ansible-playbook -i inventory/mac.yml verify.yml --syntax-check
ansible-lint --strict roles/host_prep site.yml verify.yml
git add inventory roles/host_prep roles/audiobookshelf roles/jellyfin \
  services/audiobookshelf services/jellyfin site.yml verify.yml tests
git commit -m "feat: add inert media acquisition host foundation"
```

### Task 5: Ship the catalog in the immutable release

**Files:**
- Modify: `roles/deployment_bundle/tasks/{inputs.yml,main.yml}`
- Modify: `roles/deployment_bundle/templates/manifest.yml.j2`
- Modify: `tests/verify_deployment_manifest.rb`
- Modify: `tests/{policy_deployment_test.rb,policy_manifest_test.rb}`

- [ ] **Step 1: Add RED immutable-input mutations**

Require pre-mutation validation, mode-0644 copy to `config/media-acquisition.yml`, and exact checksum. Mutate validation, destination, mode, checksum, and one staged byte.

- [ ] **Step 2: Run RED**

Run: `ruby tests/policy_deployment_test.rb && ruby tests/policy_manifest_test.rb`

Expected: FAIL because catalog is not bundled.

- [ ] **Step 3: Validate and copy**

```yaml
- name: Validate the media acquisition catalog before parsing it
  ansible.builtin.include_tasks: controller_input.yml
  vars:
    deployment_controller_input_path: "{{ playbook_dir }}/config/media-acquisition.yml"
    deployment_controller_input_allow_missing: false
```

Create staging `config` mode 0755, then:

```yaml
- name: Copy the media acquisition catalog from the controller
  ansible.builtin.copy:
    src: "{{ playbook_dir }}/config/media-acquisition.yml"
    dest: "{{ deployment_bundle_staging_dir }}/config/media-acquisition.yml"
    mode: "0644"
  changed_when: false
  when: not ansible_check_mode
```

- [ ] **Step 4: Bind checksum**

Before `services:`:

```yaml
platform_inputs:
  - path: config/media-acquisition.yml
    mode: "0644"
    checksum_sha256: {{ (lookup('file', playbook_dir ~ '/config/media-acquisition.yml', rstrip=false) | hash('sha256')) | to_json }}
```

Verifier requires exact list/digest. Planned projects stay out of deployed services.

- [ ] **Step 5: Verify and commit**

```sh
ruby tests/policy_deployment_test.rb
ruby tests/policy_manifest_test.rb
ansible-playbook -i inventory/local.yml site.yml --syntax-check
git add roles/deployment_bundle tests/verify_deployment_manifest.rb \
  tests/policy_deployment_test.rb tests/policy_manifest_test.rb
git commit -m "feat: ship media acquisition foundation contract"
```

### Task 6: Enforce one-shot and no-enable behavior through static contracts

**Files:**
- Create: `tests/contracts/{arr,downloaders,bindery,kapowarr,pinchflat,trailarr,seerr}-foundation.sh`
- Modify: `tests/{media_acquisition_foundation_test.rb,policy_test.rb,policy_manifest_test.rb}`

- [ ] **Step 1: Create red service-owned wrappers**

Every file uses this identical basename-derived implementation, so there is no
project-name placeholder to drift between copies:

```sh
#!/bin/sh
set -eu
set +x
project=$(basename -- "$0" -foundation.sh)
case $project in
  arr|downloaders|bindery|kapowarr|pinchflat|trailarr|seerr) ;;
  *) printf '%s\n' 'unknown acquisition foundation contract' >&2; exit 2 ;;
esac
mode=${1:-static}
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
[ "$mode" = static ] || { printf '%s\n' "$project foundation contract accepts only static" >&2; exit 2; }
ruby "$repo_dir/tests/media_acquisition_foundation_test.rb" --project "$project"
```

Add strict `--project NAME` parsing/exact selected checks. Do not register planned scripts in runtime registry.

- [ ] **Step 2: Pin job set**

```ruby
ACQUISITION_JOB_SERVICES = Set["configarr"].freeze
```

Require equality with parsed one-shot services. Mutation-test filename/project exemptions, second job, missing `jobs` profile, published job port, and daemon exemption. Phase 1 may exempt this set only from restart/health/Dozzle-event rules, never digest/cpuset/CPU/logging/volumes.

- [ ] **Step 3: Verify RED then GREEN**

First `tests/contracts/arr-foundation.sh static` fails before CLI/executable support. Then:

```sh
for project in arr downloaders bindery kapowarr pinchflat trailarr seerr; do
  "tests/contracts/$project-foundation.sh" static
done
ruby tests/media_acquisition_foundation_test.rb
ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
```

Expected: seven passes; premature source/promotion rejected.

- [ ] **Step 4: Commit**

```sh
git add tests/contracts/*-foundation.sh tests/media_acquisition_foundation_test.rb \
  tests/policy_test.rb tests/policy_manifest_test.rb
git commit -m "test: enforce inert acquisition service contracts"
```

### Task 7: Add selective service-owned foundation CI suites

**Files:**
- Modify: `tests/ci/{classify_changes.rb,classify_changes_test.rb,workflow_test.rb}`
- Modify: `tests/{integration.sh,integration_suite_test.sh,policy_ci_test.rb}`

- [ ] **Step 1: Write RED routing expectations**

Insert `arr downloaders bindery kapowarr pinchflat trailarr seerr` after foundation/before smoke. Future-owned paths select `static,<project>,idempotence_check`, not smoke. Every suite uses only `host_prep,deployment_bundle,media_acquisition_foundation` plus its static contract. Catalog/host-foundation changes select all seven.

- [ ] **Step 2: Run RED**

```sh
ruby tests/ci/classify_changes_test.rb
tests/integration_suite_test.sh
ruby tests/ci/workflow_test.rb
```

Expected: FAIL naming suites.

- [ ] **Step 3: Add lanes/routing**

Each acquisition `SERVICE_TAGS` value:

```ruby
%w[host_prep deployment_bundle media_acquisition_foundation]
```

Map role/service/expectation/contract paths. Catalog and host verifier select all seven. Remove tMM from outputs.

- [ ] **Step 4: Add integration cases**

Add seven `--list-suites` names, fixed tags, zero image sources, and matching static contract call. Test no planned suite pulls/starts an acquisition image.

- [ ] **Step 5: Update matrix and verify**

```ruby
INTEGRATION_SUITES = %w[
  foundation arr downloaders bindery kapowarr pinchflat trailarr seerr smoke
  beszel dozzle audiobookshelf komga jellyfin immich paperless idempotence-check
].freeze
```

```sh
ruby tests/ci/classify_changes_test.rb
tests/integration_suite_test.sh
ruby tests/ci/workflow_test.rb
ruby tests/policy_ci_test.rb
for suite in arr downloaders bindery kapowarr pinchflat trailarr seerr; do
  tests/integration.sh --suite "$suite" site.yml
done
```

Expected: pass; no acquisition image pull/start.

- [ ] **Step 6: Commit**

```sh
git add tests/ci tests/integration.sh tests/integration_suite_test.sh tests/policy_ci_test.rb
git commit -m "ci: add media acquisition foundation suites"
```

### Task 8: Document and verify the Phase 0 release

**Files:**
- Modify: `README.md`, `docs/getting-started.md`, `docs/getting-started-mac.md`, `docs/getting-started-nas.md`, `docs/adding-a-service.md`
- Modify: `tests/{docs_links_test.rb,secrets_docs_test.rb}`
- Modify: `tests/mac/{manual-review.md,run.sh,verify.sh,report.rb}`

- [ ] **Step 1: Write RED documentation contracts**

Current docs must state:

```text
The production retirement checkpoint passed and the retired metadata manager's repository declarations are removed.
Phase 0 creates only the media-control network, acquisition/final directories, immutable contracts, and CI scaffolding.
All seven acquisition projects remain planned; media_usenet_enabled and media_torrent_enabled are false.
No acquisition container is deployed and no download is attempted.
Jellyfin Open Subtitles remains until Bazarr is proved in Phase 1.
The preserved former metadata-manager state is outside repository management and is not deleted by this release.
```

Require NAS manual ACL acceptance: ordinary SMB users cannot access either `.acquisition` tree. Mac docs say Docker Desktop cannot prove ACLs.

- [ ] **Step 2: Run RED**

Run: `ruby tests/docs_links_test.rb && ruby tests/secrets_docs_test.rb`

Expected: FAIL on transitional/missing foundation prose.

- [ ] **Step 3: Update docs without scope creep**

Document planned projects, false flags, network naming, recovery classes, ACL check, generated keys. Do not add provider/account/language, Phase 1 app config, image choices, or start commands. Keep Open Subtitles. Keep historical records unchanged.

- [ ] **Step 4: Add bounded Mac evidence**

```text
MEDIA_ACQUISITION_FOUNDATION: network present, bridge driver, isolated project name
MEDIA_ACQUISITION_STORAGE: 27 exact classified paths present
MEDIA_ACQUISITION_TRANSPORTS: usenet=false torrent=false
MEDIA_ACQUISITION_CONTAINERS: none declared or started
```

No secrets/recursive listing. Drift recreates one missing network/empty leaf. Cleanup proves zero owned containers/networks.

- [ ] **Step 5: Focused verification**

```sh
git diff --check origin/main...HEAD
ruby tests/media_acquisition_foundation_test.rb
ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
ruby tests/policy_deployment_test.rb
ruby tests/policy_vault_test.rb
ruby tests/policy_platform_test.rb
ruby tests/ci/classify_changes_test.rb
ruby tests/ci/workflow_test.rb
tests/integration_suite_test.sh
ruby tests/docs_links_test.rb
ruby tests/secrets_docs_test.rb
```

Expected: all pass.

- [ ] **Step 6: Full static verification**

```sh
tests/validate-policy.sh
ansible-lint --strict
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ansible-playbook -i inventory/local.yml verify.yml --syntax-check
ansible-playbook -i inventory/mac.yml site.yml --syntax-check
ansible-playbook -i inventory/mac.yml verify.yml --syntax-check
ansible-playbook generate-secrets.yml --syntax-check
```

Expected: all pass.

- [ ] **Step 7: Run all foundation integration lanes**

```sh
for suite in arr downloaders bindery kapowarr pinchflat trailarr seerr; do
  tests/integration.sh --suite "$suite" site.yml
done
```

Expected: foundation only; no acquisition image.

- [ ] **Step 8: Run disposable Mac lifecycle**

```sh
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?set the disposable vault password file}"
tests/mac/run.sh --lane fresh \
  --vault-file inventory/group_vars/all/vault.yml \
  --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE"
```

Expected: network/paths created; reconverge/check mode clean; drift repaired; existing state persists; no acquisition container; cleanup zero owned resources.

- [ ] **Step 9: Inspect and commit documentation corrections**

```sh
git status --short
git diff --stat origin/main...HEAD
git log --oneline origin/main..HEAD
git log --format='%h %s%n%b' origin/main..HEAD | grep -i 'Co-Authored-By' && exit 1 || true
git grep -inE 'tinymediamanager|tinyMediaManager' -- \
  ':(exclude)docs/superpowers/plans/**' \
  ':(exclude)docs/superpowers/specs/**'
```

Expected: clean after final commit; no trailers; grep empty. If needed:

```sh
git add README.md docs tests/mac tests/docs_links_test.rb tests/secrets_docs_test.rb
git commit -m "docs: document media acquisition foundation"
```

Do not push. Phase 1 later creates real arr/downloaders sources, promotes only those entries, enables Usenet on selected NAS host, and uses the one-convergence adoption input. Open Subtitles remains until Bazarr sidecars pass acceptance.
