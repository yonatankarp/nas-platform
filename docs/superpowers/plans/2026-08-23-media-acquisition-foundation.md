# Media Acquisition Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permanently remove every tinyMediaManager repository declaration after its successful NAS retirement checkpoint, and install the inert Phase 0 network, storage, credentials, immutable contracts, and CI scaffolding without starting an acquisition container.

**Architecture:** Record the seven approved lifecycle projects as `planned` entries and describe their exact service, CPU, port, profile, and job classes in strict `config/media-acquisition.yml`. `host_prep` creates the project-derived external bridge and classified NAS directories while both transport flags remain false; no acquisition role or Compose tree exists until its later implementation phase. Permanent tinyMediaManager cleanup deletes repository declarations only, never preserved NAS state or media.

**Tech Stack:** Ansible Core, `community.docker.docker_network`, strict YAML, Ruby mutation/property tests, POSIX shell contracts, Docker Desktop/NAS inventories, immutable deployment bundles.

---

## Scope and dependency order

The operator confirmed the transitional release reached the NAS: tinyMediaManager is absent, its state was preserved, Movies and Series remain readable, and the retirement report was recorded. This is release two of the approved retirement.

This is Phase 0 only. It must not create acquisition project trees below
`roles/` or `services/` for arr, downloaders, bindery, kapowarr, pinchflat,
trailarr, or seerr; start an acquisition container; enable Usenet/torrents;
download content; remove Jellyfin Open Subtitles; or choose providers,
indexers, accounts, or subtitle languages.

Tasks are sequential: cleanup → catalog/roster → credential parity → encrypted
vault migration → network/storage/readers → standalone lifecycle proof →
immutable bundle → static contracts → CI → docs/final verification.

## Approved-design coverage

| Approved Phase 0 requirement | Implemented and proved by |
|---|---|
| Permanent tinyMediaManager source/declaration cleanup after NAS evidence | Tasks 1 and 10 |
| Seven lifecycle projects remain visible but inert | Tasks 2, 8, and 9 |
| Exact service, CPU, structured port, torrent-profile, identity, ownership, and Configarr job classes | Tasks 2 and 8 |
| Project-derived external bridge; Jellyfin and Audiobookshelf join it | Tasks 5 and 6 |
| Acquisition cache paths, retained Books parent, final libraries, and future critical state | Tasks 5 and 6 |
| Initial arr/SAB credential parity and protected ciphertext migration | Tasks 3 and 4 |
| Immutable release input and checksum | Task 7 |
| Site/verify tags, static contracts, selective suites, Mac/NAS proofs | Tasks 5, 6, 8, 9, and 10 |
| No service source, transport enablement, download, provider/account/language decision, or Open Subtitles removal | Tasks 2, 3, 5, 8, and 10 |

## File map

- Delete `roles/tinymediamanager/`, `services/tinymediamanager/`, its contract/expectation/fixture, Mac runner, and four lifecycle hooks.
- Modify every active manifest, inventory, vault, playbook, CI, integration, Mac, monitoring, policy, and current operator-documentation reference. Historical superpowers plans/specs remain unchanged.
- Create `config/media-acquisition.yml`, `tests/media_acquisition_foundation_test.rb`, seven planned expectation files, and seven foundation-only contract scripts.
- Create `scripts/migrate-media-acquisition-vault.py` and
  `tests/media_acquisition_vault_migration_test.py`; update only the ciphertext
  in the tracked `inventory/group_vars/all/vault.yml`.
- Keep the fifteen-key contract identical in
  `filter_plugins/vault_credential_schema.py`,
  `roles/vault_contract/meta/argument_specs.yml`,
  `roles/vault_contract/tasks/main.yml`,
  `inventory/group_vars/all/vault.yml.example`,
  `templates/vault-plain.yml.j2`, `generate-secrets.yml`,
  `tests/generate-ephemeral-vault.sh`, `docs/secrets.md`, and the encrypted
  production vault.
- Modify host-prep/preflight/site/verify for the bridge, disabled transports, storage, and read-only verification.
- Modify deployment-bundle tasks/template/verifier to copy and checksum the catalog.
- Modify classifier/integration/workflow contracts for seven foundation-only suites.

## Official implementation references

These upstream sources justify the declared interfaces while keeping image
selection and live configuration in their later phases:

- [SABnzbd General settings](https://sabnzbd.org/wiki/configuration/5.0/general)
  documents container-side port 8080; the platform reserves collision-free
  host port 8085.
- [Bazarr settings](https://wiki.bazarr.media/Additional-Configuration/Settings/)
  documents port 6767 and its all-interface bind convention.
- [Seerr Docker installation](https://docs.seerr.dev/getting-started/docker/),
  [Kapowarr general settings](https://github.com/Casvt/Kapowarr/blob/main/docs/src/settings/general.md),
  [Bindery deployment](https://github.com/vavallee/bindery/blob/main/docs/DEPLOYMENT.md),
  [Pinchflat installation](https://github.com/kieraneglin/pinchflat/wiki/Installation),
  and [Trailarr Docker Compose installation](https://nandyalu.github.io/trailarr/getting-started/02-installation/docker-compose/)
  support ports 5055, 5656, 8787, 8945, and 7889 respectively.
- [qBittorrent's official container documentation](https://github.com/qbittorrent/docker-qbittorrent-nox)
  documents the web and TCP/UDP peer endpoint model, while the
  [Gluetun port-mapping guide](https://github.com/qdm12/gluetun-wiki/blob/main/setup/port-mapping.md)
  requires a container sharing Gluetun's network namespace to publish through
  Gluetun.
- [Prowlarr's quick-start guide](https://wiki.servarr.com/en/prowlarr/quick-start-guide)
  explains that download clients are needed only for direct Prowlarr searches;
  this slice therefore configures SABnzbd directly in Radarr/Sonarr and gives
  Prowlarr no download client.

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
- Modify: `services/manifest.yml`, `config/managed-user-capabilities.yml`, `inventory/group_vars/all/main.yml`, `inventory/group_vars/mac_hosts/main.yml`
- Modify: `site.yml`, `verify.yml`, `roles/production_auto_deploy/defaults/main.yml`
- Modify: `filter_plugins/vault_credential_schema.py`, `roles/vault_contract/meta/argument_specs.yml`, `roles/vault_contract/tasks/main.yml`
- Modify: `inventory/group_vars/all/vault.yml.example`, `templates/vault-plain.yml.j2`, `generate-secrets.yml`, `tests/generate-ephemeral-vault.sh`
- Modify: `tests/ci/classify_changes.rb`, `tests/ci/classify_changes_test.rb`, `tests/ci/workflow_test.rb`, `tests/integration.sh`, `tests/integration_suite_test.sh`
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
- Create: `tests/expected/arr.yml`, `tests/expected/downloaders.yml`, `tests/expected/bindery.yml`, `tests/expected/kapowarr.yml`, `tests/expected/pinchflat.yml`, `tests/expected/trailarr.yml`, `tests/expected/seerr.yml`
- Modify: `services/manifest.yml`
- Modify: `tests/policy_support.rb`, `tests/policy_test.rb`, `tests/policy_manifest_test.rb`, `tests/policy_mutation_support.rb`, `tests/validate-policy.sh`

- [ ] **Step 1: Write the failing strict catalog test**

Use one-document, alias/anchor/duplicate-key-safe YAML loading. Define this
constructor in the test so every port object has the same exact seven fields:

```ruby
def ui_port(port, container_port: port, published_by:)
  [{
    "purpose" => "web_ui", "protocol" => "tcp",
    "bind_address" => "0.0.0.0", "exposure" => "lan_mesh",
    "host_port" => port, "container_port" => container_port,
    "published_by" => published_by
  }]
end

EXPECTED = {
  "schema" => 1, "enabled" => false,
  "network" => { "logical_name" => "media-control", "driver" => "bridge" },
  "filesystem_identity" => {
    "uid_environment" => "NAS_UID", "gid_environment" => "NAS_GID", "umask" => "022"
  },
  "configuration_ownership" => {
    "configarr" => %w[
      radarr_naming sonarr_naming radarr_quality sonarr_quality
      radarr_custom_formats sonarr_custom_formats
    ],
    "ansible" => {
      "prowlarr" => %w[
        authentication radarr_application sonarr_application full_sync
        operator_selected_indexers verification
      ],
      "radarr_sonarr" => ["sabnzbd_download_client"],
      "prowlarr_download_clients" => []
    }
  },
  "projects" => {
    "arr" => { "role" => "arr", "status" => "planned", "services" => {
      "radarr" => { "class" => "long_running", "cpus" => 1.0,
                    "host_ports" => ui_port(7878, published_by: "radarr") },
      "sonarr" => { "class" => "long_running", "cpus" => 1.0,
                    "host_ports" => ui_port(8989, published_by: "sonarr") },
      "prowlarr" => { "class" => "long_running", "cpus" => 0.5,
                      "host_ports" => ui_port(9696, published_by: "prowlarr") },
      "bazarr" => { "class" => "long_running", "cpus" => 1.0,
                    "host_ports" => ui_port(6767, published_by: "bazarr") },
      "configarr" => { "class" => "one_shot", "cpus" => 0.5, "host_ports" => [],
                       "compose_profile" => "jobs" }
    } },
    "downloaders" => { "role" => "downloaders", "status" => "planned", "services" => {
      "sabnzbd" => { "class" => "long_running", "cpus" => 2.0,
                     "host_ports" => ui_port(8085, container_port: 8080,
                                             published_by: "sabnzbd") },
      "unpackerr" => { "class" => "long_running", "cpus" => 1.0, "host_ports" => [] },
      "gluetun" => { "class" => "long_running", "cpus" => 0.5, "host_ports" => [],
                     "compose_profile" => "torrent" },
      "qbittorrent" => { "class" => "long_running", "cpus" => 1.5,
                         "compose_profile" => "torrent", "host_ports" => [
        { "purpose" => "web_ui", "protocol" => "tcp", "bind_address" => "0.0.0.0",
          "exposure" => "lan_mesh", "host_port" => 8082, "container_port" => 8082,
          "published_by" => "gluetun" },
        { "purpose" => "peer", "protocol" => "tcp", "bind_address" => "0.0.0.0",
          "exposure" => "lan_mesh", "host_port" => 6881, "container_port" => 6881,
          "published_by" => "gluetun" },
        { "purpose" => "peer", "protocol" => "udp", "bind_address" => "0.0.0.0",
          "exposure" => "lan_mesh", "host_port" => 6881, "container_port" => 6881,
          "published_by" => "gluetun" }
      ] }
    } },
    "bindery" => { "role" => "bindery", "status" => "planned", "services" => {
      "bindery" => { "class" => "long_running", "cpus" => 1.0,
                     "host_ports" => ui_port(8787, published_by: "bindery") } } },
    "kapowarr" => { "role" => "kapowarr", "status" => "planned", "services" => {
      "kapowarr" => { "class" => "long_running", "cpus" => 1.0,
                      "host_ports" => ui_port(5656, published_by: "kapowarr") } } },
    "pinchflat" => { "role" => "pinchflat", "status" => "planned", "services" => {
      "pinchflat" => { "class" => "long_running", "cpus" => 1.0,
                       "host_ports" => ui_port(8945, published_by: "pinchflat") } } },
    "trailarr" => { "role" => "trailarr", "status" => "planned", "services" => {
      "trailarr" => { "class" => "long_running", "cpus" => 1.0,
                      "host_ports" => ui_port(7889, published_by: "trailarr") } } },
    "seerr" => { "role" => "seerr", "status" => "planned", "services" => {
      "seerr" => { "class" => "long_running", "cpus" => 1.0,
                   "host_ports" => ui_port(5055, published_by: "seerr") } } }
  }
}.freeze
```

Require Configarr as sole one-shot and all future role/service directories
absent. Internal dependencies use control-network names; host publications are
only LAN/mesh UI access. The qBittorrent logical endpoints are published by the
shared Gluetun network namespace; Gluetun itself owns no logical port. A host
collision is the tuple `[bind_address, host_port, protocol]`, so TCP and UDP
6881 coexist but a second TCP 6881 does not. Exhaustively compare against every
literal existing canonical host publication after Task 1: 13378, 8090, 8080,
8081, 2283, 8096, 25600, 2586, and 8000 on `0.0.0.0`, plus the loopback-only
2375, 3000, 5432, 6379, and 9998 publications. Parse these from canonical
Compose/default inputs and fail if a new existing publication is not included
in the comparison. Mutate enabled, every field of
every port object, missing/extra ports, TCP/UDP collisions, collision with an
existing publication, ownership lists, Configarr class/profile, manifest
status, extra project, duplicate YAML key, and premature Compose source.

The Phase 5 VPN provider and any provider-assigned dynamic forwarded peer port
remain undecided. `lan_mesh` never means router/WAN forwarding; this platform
adds no router rule or public ingress.

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
  - vault_arr_radarr_admin_username
  - vault_arr_radarr_admin_password
  - vault_arr_sonarr_api_key
  - vault_arr_sonarr_admin_username
  - vault_arr_sonarr_admin_password
  - vault_arr_prowlarr_api_key
  - vault_arr_prowlarr_admin_username
  - vault_arr_prowlarr_admin_password
  - vault_arr_bazarr_api_key
  - vault_arr_bazarr_admin_username
  - vault_arr_bazarr_admin_password
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
  - vault_downloaders_sabnzbd_api_key
  - vault_downloaders_sabnzbd_admin_username
  - vault_downloaders_sabnzbd_admin_password
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

### Task 3: Add complete first-slice vault schema and generation parity

**Files:**
- Modify: `filter_plugins/vault_credential_schema.py`
- Modify: `inventory/group_vars/all/vault.yml.example`
- Modify: `roles/vault_contract/meta/argument_specs.yml`, `roles/vault_contract/tasks/main.yml`
- Modify: `templates/vault-plain.yml.j2`, `generate-secrets.yml`, `tests/generate-ephemeral-vault.sh`
- Modify: `tests/policy_vault_test.rb`, `tests/vault_credential_schema_test.py`, `tests/secrets_docs_test.rb`, `docs/secrets.md`

- [ ] **Step 1: Write RED key/shape mutations**

Require:

```ruby
FOUNDATION_KEYS = %w[
  vault_arr_radarr_api_key vault_arr_radarr_admin_username vault_arr_radarr_admin_password
  vault_arr_sonarr_api_key vault_arr_sonarr_admin_username vault_arr_sonarr_admin_password
  vault_arr_prowlarr_api_key vault_arr_prowlarr_admin_username vault_arr_prowlarr_admin_password
  vault_arr_bazarr_api_key vault_arr_bazarr_admin_username vault_arr_bazarr_admin_password
  vault_downloaders_sabnzbd_api_key
  vault_downloaders_sabnzbd_admin_username vault_downloaders_sabnzbd_admin_password
].freeze
```

The final set is exactly fifteen keys—five API keys, four arr
username/password pairs, and one SAB username/password pair. API keys are
distinct lowercase hexadecimal length
32. Usernames and strong generated passwords are `NONEMPTY`; do not impose an
unsupported fixed lexical shape on passwords. Mutate short/uppercase/nonhex,
duplicate API keys, duplicate passwords, empty usernames/passwords,
missing/extra keys, and removal from the `no_log` mapping.

- [ ] **Step 2: Run RED**

```sh
ruby tests/policy_vault_test.rb
```

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/vault_credential_schema_test.py
```

Expected: FAIL naming fifteen keys.

- [ ] **Step 3: Add schema and sanitized examples**

Add `HEX_32 = re.compile(r"^[0-9a-f]{32}$")`; five `PATTERN` rules and
ten `NONEMPTY` rules directly in `CREDENTIAL_RULES`. Extend the filter's
distinct groups without weakening the existing ntfy token group:

```python
DISTINCT_KEY_GROUPS = (
    ("vault_ntfy_dozzle_token", "vault_ntfy_beszel_token", "vault_ntfy_deploy_token"),
    ("vault_arr_radarr_api_key", "vault_arr_sonarr_api_key",
     "vault_arr_prowlarr_api_key", "vault_arr_bazarr_api_key",
     "vault_downloaders_sabnzbd_api_key"),
    ("vault_arr_radarr_admin_password", "vault_arr_sonarr_admin_password",
     "vault_arr_prowlarr_admin_password", "vault_arr_bazarr_admin_password",
     "vault_downloaders_sabnzbd_admin_password"),
)
```

Iterate each group with the current equality-based uniqueness behavior so all
five API keys differ and all five administrator passwords differ. Add fifteen
required string options and mapping entries;
all tasks stay `no_log: true`. Sanitized examples use the distinct valid API
values `00000000000000000000000000000000`,
`11111111111111111111111111111111`,
`22222222222222222222222222222222`,
`33333333333333333333333333333333`, and
`44444444444444444444444444444444`, plus `nasadmin`,
and these distinct values: `example-radarr-password`,
`example-sonarr-password`, `example-prowlarr-password`,
`example-bazarr-password`, and `example-sabnzbd-password`.

- [ ] **Step 4: Generate distinct values**

```yaml
arr_radarr_api_key: "{{ lookup('password', '/dev/null chars=hexdigits length=32') | lower }}"
arr_radarr_admin_username: nasadmin
arr_radarr_admin_password: "{{ lookup('password', password_spec) }}"
arr_sonarr_api_key: "{{ lookup('password', '/dev/null chars=hexdigits length=32') | lower }}"
arr_sonarr_admin_username: nasadmin
arr_sonarr_admin_password: "{{ lookup('password', password_spec) }}"
arr_prowlarr_api_key: "{{ lookup('password', '/dev/null chars=hexdigits length=32') | lower }}"
arr_prowlarr_admin_username: nasadmin
arr_prowlarr_admin_password: "{{ lookup('password', password_spec) }}"
arr_bazarr_api_key: "{{ lookup('password', '/dev/null chars=hexdigits length=32') | lower }}"
arr_bazarr_admin_username: nasadmin
arr_bazarr_admin_password: "{{ lookup('password', password_spec) }}"
downloaders_sabnzbd_api_key: "{{ lookup('password', '/dev/null chars=hexdigits length=32') | lower }}"
downloaders_sabnzbd_admin_username: nasadmin
downloaders_sabnzbd_admin_password: "{{ lookup('password', password_spec) }}"
```

Render in `vault-plain.yml.j2`; ephemeral API keys call `openssl rand -hex 16`
separately and passwords call the existing strong password generator
separately. The shared `nasadmin` username follows current platform convention;
passwords never cross services. Configarr gets no credential—it consumes the
four arr API keys. Phase 1 will choose pinned-image-supported preseed/bootstrap
mechanics and any required password hashes; this task does not invent those
formats. Add no provider/indexer/account/language/ComicVine/Seerr/VPN fields.

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
git commit -m "feat: add acquisition foundation credential schema"
```

### Task 4: Migrate the tracked encrypted vault without plaintext artifacts

**Files:**
- Create: `scripts/migrate-media-acquisition-vault.py`
- Create: `tests/media_acquisition_vault_migration_test.py`
- Modify: `tests/validate-policy.sh`
- Modify: `inventory/group_vars/all/vault.yml` (ciphertext only)
- Modify: `docs/secrets.md`

- [ ] **Step 1: Write the failing in-memory migration tests**

Create encrypted temporary fixtures and run the migrator as a subprocess with
captured output. Test all of these independently: safe full migration; all
fifteen keys already present, with the legacy
`vault_tinymediamanager_password` absent, is an idempotent no-op; partial new
key set, both legacy and new keys, or neither legacy nor new keys fails without
changing ciphertext; malformed YAML; wrong password; symlinked vault;
symlinked password; vault mode other than `0644`; password mode other than
`0600`; vault outside
the repository target; duplicate generated API/password values injected by a
test seam; encryption failure; and atomic replacement failure. Snapshot the
temporary directory before/after and require that every created regular file
starts with `$ANSIBLE_VAULT;`; scan captured stdout/stderr and filenames for all
fixture secrets.

Run RED independently:

```sh
ansible_python=$(ansible-playbook --version |
  sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p')
[ -x "$ansible_python" ]
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" \
  tests/media_acquisition_vault_migration_test.py
```

Expected: FAIL because `scripts/migrate-media-acquisition-vault.py` is absent.

- [ ] **Step 2: Implement a memory-only ciphertext migration**

The script accepts only:

```text
--vault inventory/group_vars/all/vault.yml
--vault-password-file ABSOLUTE_PATH
```

Use `lstat`, reject symlinks/non-regular files, require vault mode `0644` and
password-file mode `0600`, and
require the vault's resolved path to equal the tracked repository path. Read the
password and ciphertext into byte arrays, then use Ansible's in-process vault
API so plaintext never becomes a command argument, environment value, pipe,
stdout, stderr, or filesystem entry:

```python
from ansible.constants import DEFAULT_VAULT_ID_MATCH
from ansible.parsing.vault import VaultLib, VaultSecret

secret = VaultSecret(password_bytes.rstrip(b"\r\n"))
vault = VaultLib([(DEFAULT_VAULT_ID_MATCH, secret)])
plain_bytes = vault.decrypt(ciphertext)
document = yaml.safe_load(plain_bytes)
```

Reject a non-mapping or any ambiguous key state. The only migratable state has
`vault_tinymediamanager_password` present and all fifteen new keys absent; the
only idempotent state has all fifteen new keys present and the legacy key
absent. For the migratable state, remove only the legacy tMM vault key in
memory, add the shared username `nasadmin`, five independently generated
`secrets.token_hex(16)` API keys, and five independently generated
`secrets.token_urlsafe(32)` passwords.
Loop until both distinct groups have exact cardinality five. Validate the
result through the repository's `vault_credential_errors` filter before
encryption. Serialize only in memory, then encrypt in memory:

```python
new_ciphertext = vault.encrypt(
    yaml.safe_dump(document, sort_keys=False).encode("utf-8"),
    secret,
    vault_id=DEFAULT_VAULT_ID_MATCH,
)
```

Create a mode-0600 temporary file beside the tracked vault with
`O_CREAT|O_EXCL|O_NOFOLLOW`, write **only** `new_ciphertext`, `fsync` the file,
re-open and decrypt it in memory, compare the full parsed document, atomically
`os.replace`, then `fsync` the parent. On any failure unlink only the validated
temporary ciphertext path. Success is silent; failures name only a field or
safety property, never a value. Zero/delete plaintext byte buffers in `finally`
where Python permits, while documenting that process-memory erasure cannot be
guaranteed by the runtime.

- [ ] **Step 3: Prove migration behavior GREEN**

```sh
ansible_python=$(ansible-playbook --version |
  sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p')
[ -x "$ansible_python" ]
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" \
  tests/media_acquisition_vault_migration_test.py
```

Expected: all migration, no-disclosure, atomicity, and idempotence cases pass.

- [ ] **Step 4: Migrate the real protected ciphertext**

Require the operator's existing external password file; do not create/copy it:

```sh
: "${PLATFORM_VAULT_PASSWORD_FILE:?set the existing protected vault password file}"
ansible_python=$(ansible-playbook --version |
  sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p')
[ -x "$ansible_python" ]
"$ansible_python" scripts/migrate-media-acquisition-vault.py \
  --vault inventory/group_vars/all/vault.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
```

Expected: no stdout/stderr, and only encrypted
`inventory/group_vars/all/vault.yml` changes. Never use `ansible-vault edit`,
`view`, shell command substitution, a plaintext editor, or a decrypted temp
file for this migration.

- [ ] **Step 5: Validate encrypted schema and Mac consumption**

Run each command independently:

```sh
ansible-playbook validate-vault.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
```

```sh
tests/validate-policy.sh
```

```sh
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:=$PLATFORM_VAULT_PASSWORD_FILE}"
tests/mac/run.sh --lane fresh \
  --vault-file inventory/group_vars/all/vault.yml \
  --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE"
```

The Mac runner's existing protected-input copy remains ciphertext and its
private manual-validation scratch is cleaned by its existing trap. Add a policy
assertion that the migration test is in `tests/validate-policy.sh`; add docs
that this one reviewed migration supersedes the ordinary editor workflow.

- [ ] **Step 6: Commit only code, tests, docs, and ciphertext**

```sh
git add scripts/migrate-media-acquisition-vault.py \
  tests/media_acquisition_vault_migration_test.py tests/validate-policy.sh \
  docs/secrets.md inventory/group_vars/all/vault.yml
git diff --cached --numstat -- inventory/group_vars/all/vault.yml
git commit -m "chore: migrate encrypted acquisition credentials"
```

Expected: the vault diff is opaque ciphertext, no plaintext secret appears in
`git diff`, the legacy tMM key is absent after in-memory validation, and no
password/decrypted/temp file is tracked. This deletes no preserved tMM state or
media on the NAS.

### Task 5: Create the control network and classified storage

**Files:**
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `inventory/group_vars/nas_hosts/main.yml`, `inventory/group_vars/mac_hosts/main.yml`
- Modify: `roles/preflight/meta/argument_specs.yml`
- Modify: `roles/host_prep/meta/argument_specs.yml`, `roles/host_prep/tasks/main.yml`
- Modify: `services/audiobookshelf/compose.yml`, `roles/audiobookshelf/meta/argument_specs.yml`, `roles/audiobookshelf/templates/env.j2`, `tests/contracts/audiobookshelf.sh`
- Modify: `services/jellyfin/compose.yml`, `roles/jellyfin/meta/argument_specs.yml`, `roles/jellyfin/templates/env.j2`, `tests/contracts/jellyfin.sh`
- Modify: `tests/media_acquisition_foundation_test.rb`, `tests/policy_platform_test.rb`, `tests/policy_manifest_test.rb`
- Modify: `site.yml`

- [ ] **Step 1: Add failing host assertions**

Require this exact path/recovery map. Every matching `nas_storage` entry has
mode `0755` and `media_acquisition_foundation: true`:

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
  "{{ nas_media_root }}/Books" => "user",
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
and parsed bridge creation. Media paths have no owner/group;
critical Docker paths use `nas_uid`/`nas_gid`. Mutate recovery/ownership/missing
leaf/foundation marker/true flag/constant Mac name/driver/broad deletion.

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
    labels:
      nas.platform.purpose: media-control
      nas.platform.project: >-
        {{ platform_project_name | default('nas-platform', true) }}
    state: present
```

Require the network string in argument specs and both exact labels in the
foundation tests. NAS cleanup never deletes it; Mac cleanup removes only a network whose exact name
and project/purpose labels match the validated disposable namespace.

- [ ] **Step 5: Add storage leaves**

Replace tMM storage with `EXPECTED_STORAGE`, reusing Movies/Series/Audiobooks
entries. Retain the `{{ nas_media_root }}/Books` user-recovery parent through
Phase 2 because Komga still mounts that exact parent; add Ebooks/Comics leaves
beside it. Mutation-test that deleting the parent fails while
`services/komga/compose.yml` still mounts Books. Critical app roots use
owner/group identity; media cache/user roots do not. Configarr is repository
input, Unpackerr is stateless configuration, and Gluetun has no persistent app
state, so those three intentionally receive no critical directory. Never
recursively chown.

Add optional boolean `media_acquisition_foundation` to the host-prep storage
argument schema. Set it to true on exactly these 28 entries; this marker lets
standalone verification select the authoritative inventory entries without a
second directory list.

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

- [ ] **Step 7: Add the site foundation tag**

Add `media_acquisition_foundation` to the existing host_prep site role tags.
This selects network and directory convergence, not any planned service role.

- [ ] **Step 8: Verify and commit**

```sh
ruby tests/media_acquisition_foundation_test.rb
ruby tests/policy_platform_test.rb
ruby tests/policy_manifest_test.rb
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ansible-playbook -i inventory/mac.yml site.yml --syntax-check
ansible-lint --strict roles/host_prep site.yml
git add inventory roles/host_prep roles/audiobookshelf roles/jellyfin \
  services/audiobookshelf services/jellyfin site.yml tests
git commit -m "feat: add inert media acquisition host foundation"
```

### Task 6: Add standalone verification and Mac lifecycle evidence

**Files:**
- Create: `roles/host_prep/tasks/verify_media_acquisition.yml`
- Modify: `verify.yml`
- Create: `tests/media_acquisition_foundation_verifier_test.rb`
- Create: `tests/mac/media-acquisition-foundation-hook-test.sh`
- Create: `tests/mac/media-acquisition-foundation-report-test.rb`
- Create: `tests/mac/media-acquisition-foundation-cleanup-test.sh`
- Create: `tests/mac/hooks/drift/15-media-acquisition-foundation.sh`
- Create: `tests/mac/hooks/verify/15-media-acquisition-foundation.sh`
- Modify: `tests/mac/hook-coverage-test.sh`, `tests/mac/run.sh`, `tests/mac/verify.sh`, `tests/mac/report.rb`, `tests/mac/cleanup.sh`
- Modify: `tests/media_acquisition_foundation_test.rb`, `tests/policy_mac_test.rb`, `tests/policy_manifest_test.rb`, `tests/validate-policy.sh`

- [ ] **Step 1: Write RED tests before every lifecycle mutation**

Create all four focused tests first. The Ruby verifier test parses
`verify.yml` and the new tasks file, requires a read-only include and exact
storage/classification, stat, transport, network-driver, and reader-membership
assertions, then mutation-tests a missing leaf and either reader absent from the
exact network. The hook test requires the Mac runner to execute that verifier,
requires drift to remove/recreate only the project-derived bridge and one empty
acquisition leaf, and requires a second verification to pass. The report test
requires the four bounded fields and rejects vault values, recursive listings,
or a claim that NAS ACLs were proved. The cleanup test accepts only
`$PLATFORM_PROJECT_NAME-media-control`, and rejects an empty project name,
`media-control`, prefix/suffix deception, symlinked state, an unrelated network,
or any broad Docker prune command.

Run each RED command independently:

```sh
ruby tests/media_acquisition_foundation_verifier_test.rb
```

```sh
tests/mac/media-acquisition-foundation-hook-test.sh
```

```sh
ruby tests/mac/media-acquisition-foundation-report-test.rb
```

```sh
tests/mac/media-acquisition-foundation-cleanup-test.sh
```

Expected: each fails because its corresponding verifier, runner/drift,
report, or cleanup behavior is absent. Add all four commands to
`tests/validate-policy.sh` before changing any implementation file.

- [ ] **Step 2: Implement the standalone read-only verifier**

`roles/host_prep/tasks/verify_media_acquisition.yml` must:

```yaml
---
- name: Select the declared media acquisition foundation storage
  ansible.builtin.set_fact:
    media_acquisition_foundation_storage: >-
      {{ nas_storage |
         selectattr('media_acquisition_foundation', 'defined') |
         selectattr('media_acquisition_foundation', 'equalto', true) | list }}
  changed_when: false
  tags: [platform_verify_media_acquisition_foundation]

- name: Inspect every media acquisition foundation path
  ansible.builtin.stat:
    path: "{{ item.path }}"
    follow: false
  loop: "{{ media_acquisition_foundation_storage }}"
  register: media_acquisition_foundation_path_info
  changed_when: false
  tags: [platform_verify_media_acquisition_foundation]

- name: Inspect the external media control network
  community.docker.docker_network_info:
    name: "{{ platform_media_control_network }}"
  register: media_acquisition_network
  changed_when: false
  tags: [platform_verify_media_acquisition_foundation]

- name: Inspect required reader containers
  community.docker.docker_container_info:
    name: "{{ item }}"
  loop:
    - "{{ audiobookshelf_container_name }}"
    - "{{ jellyfin_container_name }}"
  register: media_acquisition_reader_info
  changed_when: false
  tags: [platform_verify_media_acquisition_foundation]
```

Follow with parsed assertions that every inventory entry matches the exact
expected path/recovery/mode/owner split; every stat exists, is a directory, and
is not a symlink; the network exists with bridge driver and exact name; both
reader containers exist; and each reader's
`container.NetworkSettings.Networks.keys()` contains exactly the declared
control-network membership in addition to its own Compose default network.
Require the keys to equal the exact two expected network names, not merely
contain the control network. Assert both transports false. No task in this file may mutate or use a planned
service role. `verify.yml` includes only this `tasks_from` file under
`platform_verify_media_acquisition_foundation`, never host_prep main.

Append this read-only role entry to `verify.yml`:

```yaml
    - role: host_prep
      tasks_from: verify_media_acquisition
      tags: [never, platform_verify_media_acquisition_foundation]
```

Use these bounded assertions after the inspection tasks (the static foundation
test owns the exact 28-path list from Task 5, and the standalone verifier proves
that exact marked inventory reached the host):

```yaml
- name: Verify the declared foundation storage contract
  ansible.builtin.assert:
    that:
      - media_acquisition_foundation_storage | length == 28
      - media_acquisition_foundation_storage | map(attribute='path') | unique | length == 28
      - media_acquisition_foundation_storage | selectattr('recovery', 'equalto', 'cache') | list | length == 10
      - media_acquisition_foundation_storage | selectattr('recovery', 'equalto', 'user') | list | length == 7
      - media_acquisition_foundation_storage | selectattr('recovery', 'equalto', 'critical') | list | length == 11
      - media_acquisition_foundation_storage | selectattr('mode', 'equalto', '0755') | list | length == 28
      - media_acquisition_foundation_path_info.results | length == 28
      - media_acquisition_foundation_path_info.results | map(attribute='stat.exists') | select('equalto', false) | list | length == 0
      - media_acquisition_foundation_path_info.results | map(attribute='stat.isdir') | select('equalto', false) | list | length == 0
      - media_acquisition_foundation_path_info.results | map(attribute='stat.islnk') | select('equalto', true) | list | length == 0
      - not (media_usenet_enabled | bool)
      - not (media_torrent_enabled | bool)
  changed_when: false
  tags: [platform_verify_media_acquisition_foundation]

- name: Verify the media control network and exact reader memberships
  ansible.builtin.assert:
    that:
      - media_acquisition_network.exists
      - media_acquisition_network.network.Name == platform_media_control_network
      - media_acquisition_network.network.Driver == 'bridge'
      - media_acquisition_network.network.Labels['nas.platform.purpose'] == 'media-control'
      - media_acquisition_network.network.Labels['nas.platform.project'] == (platform_project_name | default('nas-platform', true))
      - media_acquisition_reader_info.results | length == 2
      - media_acquisition_reader_info.results[0].exists
      - media_acquisition_reader_info.results[1].exists
      - (media_acquisition_reader_info.results[0].container.NetworkSettings.Networks.keys() | list | sort) == ([audiobookshelf_compose_project_name ~ '_default', platform_media_control_network] | sort)
      - (media_acquisition_reader_info.results[1].container.NetworkSettings.Networks.keys() | list | sort) == ([jellyfin_compose_project_name ~ '_default', platform_media_control_network] | sort)
  changed_when: false
  tags: [platform_verify_media_acquisition_foundation]
```

- [ ] **Step 3: Implement isolated drift and verify hooks**

The exact files are:

```text
tests/mac/hooks/drift/15-media-acquisition-foundation.sh
tests/mac/hooks/verify/15-media-acquisition-foundation.sh
```

The drift hook validates the disposable namespace, removes only
`$PLATFORM_PROJECT_NAME-media-control`, and removes only the seeded empty
`$PLATFORM_MEDIA_ROOT/Media/.acquisition/usenet/movies` leaf after proving it is
an owned real empty directory. The verify hook runs the standalone Ansible tag,
checks reader membership through `docker inspect`, verifies all 28 classified
paths without enumerating contents, and proves no catalog container name
exists. Register both with hook coverage.

- [ ] **Step 4: Implement bounded reporting and cleanup**

Emit exactly:

```text
MEDIA_ACQUISITION_FOUNDATION: network present, bridge driver, isolated project name
MEDIA_ACQUISITION_STORAGE: 28 exact classified paths present
MEDIA_ACQUISITION_TRANSPORTS: usenet=false torrent=false
MEDIA_ACQUISITION_CONTAINERS: none declared or started
```

Cleanup derives the one permitted network from a validated nonempty
`PLATFORM_PROJECT_NAME`, inspects its labels/name before removal, refuses all
lookalikes, and verifies no project-owned container/network remains. It never
uses `docker system prune`, `docker network prune`, a glob, or a name supplied
by catalog/user input.

- [ ] **Step 5: Prove every focused test GREEN**

Run independently:

```sh
ruby tests/media_acquisition_foundation_verifier_test.rb
```

```sh
tests/mac/media-acquisition-foundation-hook-test.sh
```

```sh
ruby tests/mac/media-acquisition-foundation-report-test.rb
```

```sh
tests/mac/media-acquisition-foundation-cleanup-test.sh
```

```sh
ruby tests/media_acquisition_foundation_test.rb
```

```sh
ruby tests/policy_mac_test.rb
```

Expected: all pass, including missing-leaf, reader-membership, drift-repair,
report-redaction, exact cleanup, and deceptive-name refusal cases.

- [ ] **Step 6: Run syntax/lint and commit**

```sh
ansible-playbook -i inventory/local.yml verify.yml --syntax-check
```

```sh
ansible-playbook -i inventory/mac.yml verify.yml --syntax-check
```

```sh
ansible-lint --strict roles/host_prep verify.yml
```

```sh
git add roles/host_prep/tasks/verify_media_acquisition.yml verify.yml \
  tests/mac tests/media_acquisition_foundation_test.rb \
  tests/media_acquisition_foundation_verifier_test.rb tests/policy_mac_test.rb \
  tests/policy_manifest_test.rb tests/validate-policy.sh
git commit -m "test: prove media acquisition foundation lifecycle"
```

### Task 7: Ship the catalog in the immutable release

**Files:**
- Modify: `roles/deployment_bundle/tasks/inputs.yml`, `roles/deployment_bundle/tasks/main.yml`
- Modify: `roles/deployment_bundle/templates/manifest.yml.j2`
- Modify: `tests/verify_deployment_manifest.rb`
- Modify: `tests/policy_deployment_test.rb`, `tests/policy_manifest_test.rb`

- [ ] **Step 1: Add RED immutable-input mutations**

Require pre-mutation validation, mode-0644 copy to `config/media-acquisition.yml`, and exact checksum. Mutate validation, destination, mode, checksum, and one staged byte.

- [ ] **Step 2: Run RED**

Run independently:

```sh
ruby tests/policy_deployment_test.rb
```

```sh
ruby tests/policy_manifest_test.rb
```

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

### Task 8: Enforce one-shot and no-enable behavior through static contracts

**Files:**
- Create: `tests/contracts/arr-foundation.sh`, `tests/contracts/downloaders-foundation.sh`, `tests/contracts/bindery-foundation.sh`, `tests/contracts/kapowarr-foundation.sh`, `tests/contracts/pinchflat-foundation.sh`, `tests/contracts/trailarr-foundation.sh`, `tests/contracts/seerr-foundation.sh`
- Modify: `tests/media_acquisition_foundation_test.rb`, `tests/policy_test.rb`, `tests/policy_manifest_test.rb`

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

### Task 9: Add selective service-owned foundation CI suites

**Files:**
- Modify: `tests/ci/classify_changes.rb`, `tests/ci/classify_changes_test.rb`, `tests/ci/workflow_test.rb`
- Modify: `tests/integration.sh`, `tests/integration_suite_test.sh`, `tests/policy_ci_test.rb`

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

### Task 10: Document and verify the Phase 0 release

**Files:**
- Modify: `README.md`, `docs/getting-started.md`, `docs/getting-started-mac.md`, `docs/getting-started-nas.md`, `docs/adding-a-service.md`
- Modify: `tests/docs_links_test.rb`, `tests/secrets_docs_test.rb`
- Modify: `tests/mac/manual-review.md`, `tests/mac/run.sh`, `tests/mac/verify.sh`, `tests/mac/report.rb`

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

Require NAS manual ACL acceptance: ordinary SMB users cannot access either
`.acquisition` tree. Mac docs say Docker Desktop cannot prove ACLs. Extend
`tests/media_acquisition_foundation_test.rb` to parse
`roles/jellyfin/defaults/main.yml`, require `Open Subtitles` in
`jellyfin_plugins`, and mutation-test deleting that list item. Also require all
seven planned role and Compose directories to remain absent and mutation-test
creating one, so documentation cannot mask premature implementation.

- [ ] **Step 2: Run RED**

Run independently:

```sh
ruby tests/media_acquisition_foundation_test.rb
```

```sh
ruby tests/docs_links_test.rb
```

```sh
ruby tests/secrets_docs_test.rb
```

Expected: the foundation mutation test fails until the Open Subtitles retention
guard is added; the documentation tests fail on transitional/missing
foundation prose.

- [ ] **Step 3: Update docs without scope creep**

Document planned projects, false flags, network naming, recovery classes, ACL check, generated keys. Do not add provider/account/language, Phase 1 app config, image choices, or start commands. Keep Open Subtitles. Keep historical records unchanged.

- [ ] **Step 4: Add bounded Mac evidence**

```text
MEDIA_ACQUISITION_FOUNDATION: network present, bridge driver, isolated project name
MEDIA_ACQUISITION_STORAGE: 28 exact classified paths present
MEDIA_ACQUISITION_TRANSPORTS: usenet=false torrent=false
MEDIA_ACQUISITION_CONTAINERS: none declared or started
```

No secrets/recursive listing. Drift recreates one missing network/empty leaf. Cleanup proves zero owned containers/networks.

- [ ] **Step 5: Focused verification**

```sh
git diff --check
git diff --check origin/main...HEAD
```

```sh
ansible_python=$(ansible-playbook --version |
  sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p')
[ -x "$ansible_python" ]
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" \
  tests/media_acquisition_vault_migration_test.py
```

```sh
ruby tests/media_acquisition_foundation_verifier_test.rb
```

```sh
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
: "${PLATFORM_VAULT_PASSWORD_FILE:?set the protected vault password file}"
tests/validate-policy.sh
ansible-playbook -i inventory/local.yml validate-vault.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
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

- [ ] **Step 9: Commit documentation corrections**

```sh
git add README.md docs tests/mac tests/docs_links_test.rb \
  tests/secrets_docs_test.rb tests/media_acquisition_foundation_test.rb
git commit -m "docs: document media acquisition foundation"
```

- [ ] **Step 10: Inspect the completed branch**

```sh
git status --short
git diff --stat origin/main...HEAD
git log --oneline origin/main..HEAD
git log --format='%h %s%n%b' origin/main..HEAD | grep -i 'Co-Authored-By' && exit 1 || true
git grep -inE 'tinymediamanager|tinyMediaManager' -- \
  ':(exclude)docs/superpowers/plans/**' \
  ':(exclude)docs/superpowers/specs/**'
```

Expected: clean; no trailers; grep empty.

Do not push. Phase 1 later creates real arr/downloaders sources, promotes only those entries, enables Usenet on selected NAS host, and uses the one-convergence adoption input. Open Subtitles remains until Bazarr sidecars pass acceptance.
