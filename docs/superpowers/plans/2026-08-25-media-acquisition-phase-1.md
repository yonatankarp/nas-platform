# Media Acquisition Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate the approved movies, series, subtitles, and Usenet acquisition slice with Radarr, Sonarr, Prowlarr, Bazarr, Configarr, SABnzbd, and Unpackerr while preserving the existing-library adoption and replacement-retirement gates.

**Architecture:** Promote only `arr` and `downloaders` from the Phase 0 catalog. Compose owns immutable long-running and one-shot container definitions; Ansible bootstraps deterministic API keys, reconciles stable application connections, applies repository-owned profiles through a synchronous Configarr job, and refuses fresh critical state beside nonempty libraries unless the one-run adoption input is supplied. Runtime acceptance remains deliberately separate: provider/indexer choice, the controlled rename, proof downloads, and Open Subtitles removal happen only after an operator records the corresponding handoff evidence.

**Tech Stack:** Ansible Core, `community.docker.docker_compose_v2`, Servarr v3 APIs, SABnzbd API, Configarr/TRaSH configuration, Docker Compose, Ruby and POSIX shell contract tests.

---

## Scope and safety boundaries

- Start from synchronized `origin/main`, which already contains Phase 0.
- Implement only Phase 1. Bindery, Kapowarr, Pinchflat, Trailarr, Seerr, Gluetun, and qBittorrent remain planned and inert.
- Keep Mac and default NAS transport inputs false. An operator explicitly sets `media_usenet_enabled: true` for a target.
- Never invent Usenet providers, indexers, subtitle languages, or provider credentials. Declare typed operator inputs and verify configured values without checking secrets into source.
- Keep automatic monitoring, automatic search, and library-wide rename disabled. The repository may configure naming and quality profiles, but runtime adoption and rename remain explicit operator actions.
- Do not remove Jellyfin Open Subtitles declarations in this code-only slice. Removal requires the design's NAS proof that Bazarr produced the required sidecars. Document the exact follow-up gate.
- Do not delete preserved tinyMediaManager state or media. Phase 0 already removed its repository declarations after the accepted retirement checkpoint.

## File map

- Create `services/arr/compose.yml`, `compose.mac.yml`, and `compose.integration.yml` for Radarr, Sonarr, Prowlarr, and Bazarr.
- Create `services/arr/compose.jobs.yml` for the Configarr one-shot job.
- Create `services/downloaders/compose.yml`, `compose.mac.yml`, and `compose.integration.yml` for SABnzbd and Unpackerr only; torrent services remain absent until Phase 5.
- Create focused roles `roles/arr/` and `roles/downloaders/`, splitting bootstrap, reconciliation, Configarr execution, and verification into named task files.
- Create repository-owned Configarr input under `roles/arr/files/configarr/` and render only the API-key secret file into the private runtime tree.
- Modify the catalog, manifest, inventory defaults, site/verify order, deployment bundle, port allocation, exact CPU/service maps, Dozzle expectations, service contracts, selective CI, Mac lifecycle hooks, and operator docs.
- Add focused behavior tests for activation, adoption guards, role structure, job semantics, and retirement gating instead of expanding the Phase 0 foundation test into a Phase 1 monolith.

### Task 1: Promote the two projects and define activation inputs

**Files:**
- Modify: `config/media-acquisition.yml`
- Modify: `services/manifest.yml`
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `inventory/group_vars/mac_hosts/main.yml`
- Modify: `inventory/group_vars/nas_hosts/main.yml`
- Create: `tests/media_acquisition_phase1_test.rb`
- Modify: `tests/validate-policy.sh`

- [ ] **Step 1: Write the failing catalog and inventory test**

Create a strict YAML test that asserts:

```ruby
expected_status = {
  "arr" => "implemented",
  "downloaders" => "implemented",
  "bindery" => "planned",
  "kapowarr" => "planned",
  "pinchflat" => "planned",
  "trailarr" => "planned",
  "seerr" => "planned"
}

expected_status.each do |name, status|
  check(failures, catalog.dig("projects", name, "status") == status,
        "#{name} catalog status must be #{status}")
  manifest_entry = manifest.fetch("services").find { |entry| entry["name"] == name }
  check(failures, manifest_entry&.fetch("status") == status,
        "#{name} manifest status must be #{status}")
end

check(failures, all_vars["media_acquisition_adopt_existing_libraries"] == false,
      "adoption must default false")
check(failures, all_vars["media_arr_automatic_monitoring_enabled"] == false,
      "automatic monitoring must default false")
check(failures, all_vars["media_arr_automatic_rename_enabled"] == false,
      "automatic rename must default false")
check(failures, all_vars["media_bazarr_handoff_accepted"] == false,
      "Bazarr handoff must default false")
```

Also require `media_usenet_enabled` and `media_torrent_enabled` to remain false in both host groups.

- [ ] **Step 2: Run RED**

Run: `ruby tests/media_acquisition_phase1_test.rb`

Expected: FAIL because both projects are still planned and the Phase 1 inputs do not exist.

- [ ] **Step 3: Implement the minimal activation model**

Set only the two project statuses to `implemented`. Add these nonsecret defaults:

```yaml
media_acquisition_adopt_existing_libraries: false
media_arr_automatic_monitoring_enabled: false
media_arr_automatic_rename_enabled: false
media_bazarr_handoff_accepted: false
media_arr_indexers: []
media_bazarr_languages: []
media_bazarr_providers: []
```

The empty lists are valid deployment inputs; they make provider selection operator-owned and keep unattended acquisition inert until configured.

- [ ] **Step 4: Register and run GREEN**

Add `ruby tests/media_acquisition_phase1_test.rb` to `tests/validate-policy.sh`, then run it directly.

Expected: `media acquisition phase 1: activation contract holds`.

- [ ] **Step 5: Commit**

```sh
git add config/media-acquisition.yml services/manifest.yml inventory/group_vars tests/media_acquisition_phase1_test.rb tests/validate-policy.sh
git commit -m "feat: activate media acquisition phase one"
```

### Task 2: Define immutable Compose projects and one-shot policy

**Files:**
- Create: `services/arr/compose.yml`
- Create: `services/arr/compose.mac.yml`
- Create: `services/arr/compose.integration.yml`
- Create: `services/arr/compose.jobs.yml`
- Create: `services/downloaders/compose.yml`
- Create: `services/downloaders/compose.mac.yml`
- Create: `services/downloaders/compose.integration.yml`
- Modify: `renovate.json`
- Modify: `tests/media_acquisition_phase1_test.rb`
- Modify: `tests/policy_test.rb`
- Modify: `tests/policy_manifest_test.rb`

- [ ] **Step 1: Add failing structural assertions**

Assert exact long-running service sets, external-network membership, resource policy, mount views, and Configarr's separate job class:

```ruby
check(failures, arr_compose.fetch("services").keys.sort == %w[bazarr prowlarr radarr sonarr],
      "arr long-running service set drifted")
check(failures, downloader_compose.fetch("services").keys.sort == %w[sabnzbd unpackerr],
      "Phase 1 downloader service set drifted")
check(failures, jobs.fetch("services").keys == ["configarr"],
      "Configarr must be the only job service")
check(failures, !jobs.dig("services", "configarr").key?("restart"),
      "Configarr must not restart")
check(failures, jobs.dig("services", "configarr", "ports").nil?,
      "Configarr must publish no ports")
check(failures, jobs.dig("services", "configarr", "profiles") == ["jobs"],
      "Configarr must stay behind the jobs profile")
```

For every long-running service assert a tagged digest, `cpuset`, exact CPU ceiling, `unless-stopped`, bounded `json-file` logging, Dozzle name, and meaningful healthcheck. Assert Radarr/Sonarr/Bazarr mount the full Media share at `/data/media`; SABnzbd mounts only the two `.acquisition` parents; Unpackerr mounts the same parents and runs as `1000:100` with no port.

- [ ] **Step 2: Run RED**

Run: `ruby tests/media_acquisition_phase1_test.rb`

Expected: FAIL because no Phase 1 Compose sources exist.

- [ ] **Step 3: Add minimal immutable Compose definitions**

Use stable, human-readable tags plus manifest-list digests. Each LinuxServer container receives:

```yaml
environment:
  PUID: ${NAS_UID:?}
  PGID: ${NAS_GID:?}
  UMASK: "022"
  TZ: ${TZ:?}
```

Use service DNS on `${PLATFORM_MEDIA_NETWORK:?}`. Keep Configarr separate:

```yaml
services:
  configarr:
    profiles: [jobs]
    user: "1000:100"
    cpuset: ${PLATFORM_CONTAINER_CPUSET:?}
    cpus: 0.5
    volumes:
      - ${CONFIGARR_CONFIG_PATH:?}:/app/config/config.yml:ro
      - ${CONFIGARR_SECRETS_PATH:?}:/app/config/secrets.yml:ro
```

The Mac and integration overlays only isolate names/ports and substitute test fixtures; they do not weaken mount, identity, or service-set contracts.

- [ ] **Step 4: Run GREEN and mutation coverage**

Run:

```sh
ruby tests/media_acquisition_phase1_test.rb
ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
```

Expected: all pass, including mutations for a daemonized Configarr, a published Unpackerr port, a reader write mount, and a torrent service leaking into Phase 1.

- [ ] **Step 5: Commit**

```sh
git add services/arr services/downloaders renovate.json tests
git commit -m "feat: define phase one acquisition containers"
```

### Task 3: Implement critical-state and one-run adoption guards

**Files:**
- Create: `roles/arr/defaults/main.yml`
- Create: `roles/arr/meta/argument_specs.yml`
- Create: `roles/arr/tasks/state_guard.yml`
- Create: `roles/downloaders/defaults/main.yml`
- Create: `roles/downloaders/meta/argument_specs.yml`
- Create: `roles/downloaders/tasks/state_guard.yml`
- Create: `tests/media_acquisition_adoption_test.rb`
- Modify: `tests/validate-policy.sh`

- [ ] **Step 1: Write failing guard behavior fixtures**

Run each task file with temporary config/library trees and assert this matrix:

```ruby
cases = {
  [false, false, false] => :allow, # no state, empty library, normal fresh run
  [false, true,  false] => :allow, # preserved state beside content
  [true,  false, false] => :refuse,
  [true,  false, true]  => :allow  # explicit one-run adoption
}
```

Here the tuple is `[library_nonempty, critical_state_present, adopt_input]`. Also assert the input is consumed as a play variable only: neither role writes it to disk nor mutates inventory.

- [ ] **Step 2: Run RED**

Run: `ruby tests/media_acquisition_adoption_test.rb`

Expected: FAIL because the roles and guard task files do not exist.

- [ ] **Step 3: Implement read-only guards**

Use bounded `ansible.builtin.find` calls for Movies and Series plus explicit sentinel files (`radarr.db`, `sonarr.db`, `prowlarr.db`, Bazarr `db/bazarr.db`, and `sabnzbd.ini`). Assert before rendering bootstrap state or starting containers:

```yaml
- name: Refuse silent Arr fresh initialization beside existing libraries
  ansible.builtin.assert:
    that:
      - >-
        not arr_existing_library_content or
        arr_critical_state_present or
        media_acquisition_adopt_existing_libraries | bool
    fail_msg: >-
      Existing Movies or Series content was found without preserved Arr critical state.
      Restore state or rerun this convergence once with
      media_acquisition_adopt_existing_libraries=true.
```

Do not change ownership recursively and do not inspect file content.

- [ ] **Step 4: Run GREEN**

Run: `ruby tests/media_acquisition_adoption_test.rb`

Expected: all matrix cases pass with redacted output.

- [ ] **Step 5: Commit**

```sh
git add roles/arr roles/downloaders tests/media_acquisition_adoption_test.rb tests/validate-policy.sh
git commit -m "feat: guard acquisition state adoption"
```

### Task 4: Deploy and reconcile SABnzbd and Unpackerr

**Files:**
- Create: `roles/downloaders/tasks/main.yml`
- Create: `roles/downloaders/tasks/reconcile_sabnzbd.yml`
- Create: `roles/downloaders/tasks/verify.yml`
- Create: `roles/downloaders/templates/env.j2`
- Create: `roles/downloaders/templates/sabnzbd.ini.j2`
- Create: `tests/contracts/downloaders.sh`
- Modify: `tests/contracts/registry.yml`
- Modify: `tests/expected/downloaders.yml`
- Modify: `tests/media_acquisition_phase1_test.rb`

- [ ] **Step 1: Write the failing downloader contract**

Require transport gating, private bootstrap, the five exact categories, bounded cache/concurrency settings, no provider invention, Unpackerr's two Arr endpoints, and API read-back. The expected categories are:

```ruby
{
  "movies" => "/data/media/.acquisition/usenet/movies",
  "series" => "/data/media/.acquisition/usenet/series",
  "ebooks" => "/data/books/.acquisition/usenet/ebooks",
  "audiobooks" => "/data/media/.acquisition/usenet/audiobooks",
  "comics" => "/data/books/.acquisition/usenet/comics"
}
```

Assert `no_log: true` on every credential-bearing template/API task and `container_cpu` checks for both services.

- [ ] **Step 2: Run RED**

Run: `tests/contracts/downloaders.sh static`

Expected: FAIL because the implemented contract and role do not exist.

- [ ] **Step 3: Implement minimal convergence**

When `media_usenet_enabled` is false, stop/remove the Phase 1 project without touching config or payload paths. When true:

1. run the state guard;
2. render private `.env` and first-start `sabnzbd.ini` only when the INI is absent;
3. deploy and wait;
4. reconcile stable owned settings and categories through SABnzbd's API using `vault_downloaders_sabnzbd_api_key`;
5. verify category paths, cache/concurrency bounds, authentication, and effective CPU policy;
6. report deployment through ntfy.

Unpackerr receives only Radarr/Sonarr URLs and API keys, paths, `UN_FILE_MODE=0644`, `UN_DIR_MODE=0755`, bounded retry/parallel settings, and no published port.

- [ ] **Step 4: Run GREEN**

Run:

```sh
tests/contracts/downloaders.sh static
ruby tests/media_acquisition_phase1_test.rb
```

Expected: both pass.

- [ ] **Step 5: Commit**

```sh
git add roles/downloaders tests/contracts tests/expected/downloaders.yml tests/media_acquisition_phase1_test.rb
git commit -m "feat: deploy phase one usenet downloaders"
```

### Task 5: Deploy Arr and reconcile service connections

**Files:**
- Create: `roles/arr/tasks/main.yml`
- Create: `roles/arr/tasks/bootstrap.yml`
- Create: `roles/arr/tasks/reconcile_servarr.yml`
- Create: `roles/arr/tasks/reconcile_prowlarr.yml`
- Create: `roles/arr/tasks/reconcile_bazarr.yml`
- Create: `roles/arr/tasks/verify.yml`
- Create: `roles/arr/templates/env.j2`
- Create: `roles/arr/templates/config.xml.j2`
- Create: `roles/arr/templates/bazarr-config.yml.j2`
- Create: `tests/contracts/arr.sh`
- Modify: `tests/contracts/registry.yml`
- Modify: `tests/expected/arr.yml`

- [ ] **Step 1: Write failing Arr structure and API contracts**

Require:

- deterministic pre-start API keys without scraping generated state;
- authentication enabled with the four declared administrator pairs;
- exact `/data/media/Movies` and `/data/media/Series` root folders;
- rename and automatic monitoring false by default;
- SABnzbd clients in Radarr/Sonarr with categories `movies` and `series`;
- Prowlarr applications for Radarr/Sonarr with full sync and no Prowlarr download client;
- Bazarr connected to both Arr APIs with identical paths and no remote mapping;
- operator lists for Prowlarr indexers and Bazarr language/provider settings;
- CPU verification for all four daemons.

- [ ] **Step 2: Run RED**

Run: `tests/contracts/arr.sh static`

Expected: FAIL because the Arr role and implemented contract do not exist.

- [ ] **Step 3: Implement idempotent reconciliation**

Start only when `media_usenet_enabled` is true. Seed `config.xml` only for absent Servarr config, then use `X-Api-Key` API calls to read complete resources, validate schemas, preserve unowned fields, and create/update only the owned connection objects. Refuse ambiguous duplicate names or URLs before mutation. Keep API payloads under `no_log: true`.

Root reconciliation must never trigger import, search, monitoring, or rename. Adoption mode permits the initial root creation beside content; it does not persist or enable automation.

For operator-defined indexers/providers, validate each object has a unique stable name/type and secret references are already vault-backed variables. Empty lists are accepted and verified as no repository-owned provider configuration.

- [ ] **Step 4: Run GREEN**

Run:

```sh
tests/contracts/arr.sh static
ruby tests/media_acquisition_phase1_test.rb
```

Expected: both pass.

- [ ] **Step 5: Commit**

```sh
git add roles/arr tests/contracts tests/expected/arr.yml
git commit -m "feat: reconcile phase one arr services"
```

### Task 6: Run Configarr synchronously and verify owned profiles

**Files:**
- Create: `roles/arr/files/configarr/config.yml`
- Create: `roles/arr/templates/configarr-secrets.yml.j2`
- Create: `roles/arr/tasks/configarr.yml`
- Create: `tests/configarr_job_test.rb`
- Modify: `roles/arr/tasks/main.yml`
- Modify: `tests/contracts/arr.sh`
- Modify: `tests/validate-policy.sh`

- [ ] **Step 1: Write failing job execution tests**

Assert `community.docker.docker_compose_v2_run` uses `service: configarr`, the `jobs` profile file, cleanup/removal, bounded captured output, and failure on a nonzero result. Assert the repository config names one Radarr and one Sonarr 1080p profile, includes naming, quality definitions, and custom formats, and uses only `!secret` API-key references.

- [ ] **Step 2: Run RED**

Run: `ruby tests/configarr_job_test.rb`

Expected: FAIL because no Configarr configuration or task exists.

- [ ] **Step 3: Implement the synchronous job**

Render `secrets.yml` mode `0600` in the runtime directory, invoke the one-shot job with cleanup, mark the task changed only on a successful sync, and sanitize output to a bounded status summary. Afterward, read Radarr/Sonarr quality profiles, naming config, and custom formats through their APIs and assert the declared `HD Bluray + WEB 1080p` profile exists. Do not schedule Configarr as a daemon.

- [ ] **Step 4: Run GREEN**

Run:

```sh
ruby tests/configarr_job_test.rb
tests/contracts/arr.sh static
```

Expected: both pass.

- [ ] **Step 5: Commit**

```sh
git add roles/arr tests/configarr_job_test.rb tests/contracts/arr.sh tests/validate-policy.sh
git commit -m "feat: apply declarative arr profiles"
```

### Task 7: Integrate deployment, verification, monitoring, ports, and CI

**Files:**
- Modify: `site.yml`
- Modify: `verify.yml`
- Modify: `roles/deployment_bundle/tasks/inputs.yml`
- Modify: `roles/deployment_bundle/templates/manifest.yml.j2`
- Modify: `roles/production_auto_deploy/defaults/main.yml`
- Modify: `tests/policy_test.rb`
- Modify: `tests/policy_deployment_test.rb`
- Modify: `tests/policy_beszel_test.rb`
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/ci/classify_changes.rb`
- Modify: `tests/ci/classify_changes_test.rb`
- Modify: `tests/ci/workflow_test.rb`
- Modify: `tests/integration.sh`
- Modify: `tests/integration_suite_test.sh`
- Modify: `tests/mac/run.sh`
- Modify: `tests/mac/cleanup.sh`
- Modify: `tests/mac/config-isolation.sh`
- Create: `tests/mac/hooks/verify/16-media-acquisition-phase1.sh`
- Create: `tests/mac/hooks/drift/16-media-acquisition-phase1.sh`

- [ ] **Step 1: Write failing routing and lifecycle expectations**

Require role order `arr` then `downloaders` after readers and before Jellyfin, inert tagged verification except for `platform_verify_arr`/`platform_verify_downloaders`, exact ports 7878/8989/9696/6767/8085, exact active services conditioned on Usenet, and two service-owned CI suites. Add Mac allocations for all five published ports and ensure cleanup scopes only the current project names.

- [ ] **Step 2: Run RED**

Run:

```sh
ruby tests/ci/classify_changes_test.rb
tests/integration_suite_test.sh
ruby tests/policy_test.rb
```

Expected: failures naming missing Phase 1 suites, tags, ports, service maps, and playbook roles.

- [ ] **Step 3: Implement repository integration**

Add exact routing:

```ruby
"arr" => %w[host_prep deployment_bundle ntfy arr],
"downloaders" => %w[host_prep deployment_bundle ntfy arr downloaders]
```

The `arr` and `downloaders` suites use ephemeral vault credentials and test overlays; they do not contact real providers. Their workflow contracts prove bootstrap, API wiring, idempotence, check mode, state persistence, recreation, drift repair, redaction, and the guard refusal/adoption pair.

- [ ] **Step 4: Run GREEN**

Run:

```sh
ruby tests/ci/classify_changes_test.rb
tests/integration_suite_test.sh
ruby tests/policy_test.rb
ruby tests/policy_deployment_test.rb
ruby tests/policy_beszel_test.rb
```

Expected: all pass.

- [ ] **Step 5: Commit**

```sh
git add site.yml verify.yml roles tests
git commit -m "ci: verify phase one acquisition services"
```

### Task 8: Document operator handoff and retain the Open Subtitles gate

**Files:**
- Modify: `README.md`
- Modify: `docs/getting-started.md`
- Modify: `docs/getting-started-mac.md`
- Modify: `docs/getting-started-nas.md`
- Modify: `docs/secrets.md`
- Create: `docs/media-acquisition-phase1.md`
- Modify: `tests/docs_links_test.rb`
- Modify: `tests/secrets_docs_test.rb`
- Modify: `tests/media_acquisition_phase1_test.rb`

- [ ] **Step 1: Write failing documentation gate assertions**

Require the operator guide to name:

1. enabling Usenet for one target;
2. supplying provider/indexer and Bazarr preferences outside source control;
3. using `media_acquisition_adopt_existing_libraries=true` for one convergence only;
4. matching/reviewing existing Movies and Series before enabling rename/monitoring;
5. proving one movie, episode, and required-language subtitle sidecar;
6. recording Bazarr handoff evidence before deleting Open Subtitles declarations;
7. rollback order: stop Radarr/Sonarr writers before any legacy writer is restored.

- [ ] **Step 2: Run RED**

Run: `ruby tests/media_acquisition_phase1_test.rb`

Expected: FAIL because the Phase 1 operator guide does not exist.

- [ ] **Step 3: Add bounded operator instructions**

Document exact commands for tagged convergence and verification, expected safe defaults, manual acceptance evidence, and failure recovery. State clearly that code completion does not claim provider connectivity, content acquisition, NAS ACL correctness, or Open Subtitles retirement.

- [ ] **Step 4: Run GREEN**

Run:

```sh
ruby tests/media_acquisition_phase1_test.rb
ruby tests/docs_links_test.rb
ruby tests/secrets_docs_test.rb
```

Expected: all pass.

- [ ] **Step 5: Commit**

```sh
git add README.md docs tests
git commit -m "docs: add phase one acquisition handoff"
```

### Task 9: Final verification and review

**Files:**
- Modify only defects revealed by verification.

- [ ] **Step 1: Run targeted static contracts**

```sh
ruby tests/media_acquisition_phase1_test.rb
ruby tests/media_acquisition_adoption_test.rb
ruby tests/configarr_job_test.rb
tests/contracts/arr.sh static
tests/contracts/downloaders.sh static
```

Expected: all pass.

- [ ] **Step 2: Run the full static ladder**

```sh
ruby tests/policy_test.rb
tests/validate-policy.sh
ansible-lint --strict
git diff --check origin/main...HEAD
```

Expected: all pass with no lint or whitespace defects.

- [ ] **Step 3: Run service-owned integration suites**

```sh
tests/integration.sh --suite arr site.yml
tests/integration.sh --suite downloaders site.yml
```

Expected: both pass using fixtures and no real provider traffic.

- [ ] **Step 4: Run the disposable Mac lane when Docker is available**

```sh
tests/mac/run.sh --lane fresh --vault-file "$PLATFORM_TEST_VAULT" \
  --vault-password-file "$PLATFORM_TEST_VAULT_PASSWORD_FILE"
```

Expected: first converge, reconverge, check mode, drift repair, persistence, recreation, adoption guard, and reporting pass. If the required vault paths are not supplied in the environment, report this as an unrun operator lane rather than fabricating success.

- [ ] **Step 5: Review the final diff**

Confirm only `arr` and `downloaders` are activated, no secret values appear, no provider choice was invented, no reader mount became writable, torrent services remain planned, and Open Subtitles remains until NAS handoff evidence exists.

- [ ] **Step 6: Commit verification fixes**

```sh
git add -A
git commit -m "fix: close phase one verification gaps"
```

Omit this commit when verification required no changes.
