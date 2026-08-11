# Manual Validation Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make fresh and adoption deployments converge on the approved Audiobookshelf, Beszel, Dozzle, Immich, Jellyfin, Komga, ntfy, and Paperless state; refresh four pinned images; and add a resumable fresh-Mac manual-validation handoff.

**Architecture:** Extend each service's existing supported-API reconciler with explicit owned fields and authoritative read-back checks. Keep secrets in the external encrypted vault, keep user preference policy in normal inventory, preserve unrelated adoption state, and fail before mutation on ambiguous or unsupported state. Use service contracts and Mac drift/adoption fixtures as the acceptance boundary, with the runner stopping after `verify` only when explicitly requested.

**Tech Stack:** Ansible, Docker Compose, Bash, Ruby contract tests, Python API probes, service REST APIs

---

## Task 1: Extend the vault and normal-inventory contracts

**Files:**
- Modify: `inventory/group_vars/all/vault.yml.example`
- Modify: `templates/vault-plain.yml.j2`
- Modify: `tests/generate-ephemeral-vault.sh`
- Modify: `roles/vault_contract/meta/argument_specs.yml`
- Modify: `roles/vault_contract/tasks/main.yml`
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `roles/immich/defaults/main.yml`
- Modify: `roles/immich/meta/argument_specs.yml`
- Modify: `tests/managed_users_vault_test.rb`
- Modify: `tests/policy_test.rb`

- [ ] **Step 1: Add failing schema tests**

Require the two OpenSubtitles secrets everywhere the vault key set is declared, require `vault_jellyfin_admin_username` to be `Yonatan`, keep Immich vault entries limited to identity fields, and assert that every managed Immich user is non-admin.

```ruby
EXPECTED_VAULT_KEYS.concat(%w[
  vault_jellyfin_opensubtitles_username
  vault_jellyfin_opensubtitles_password
])

check(failures,
      vault_contract.include?('vault_jellyfin_admin_username == "Yonatan"'),
      "Jellyfin administrator username must have exact approved casing")
check(failures,
      immich_fields == %w[email name password quota_size],
      "Immich preference policy must not enter the encrypted user records")
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `ruby tests/managed_users_vault_test.rb && ruby tests/policy_test.rb`

Expected: nonzero exit with missing OpenSubtitles keys and missing Immich preference-profile policy.

- [ ] **Step 3: Declare the secret and preference schemas**

Add required non-placeholder OpenSubtitles username/password fields to the vault example, plain template, ephemeral generator, and vault contract. Define the approved `standard` Immich profile in normal inventory, plus empty mappings for per-email profile selection and leaf overrides.

```yaml
immich_managed_user_preference_profile_default: standard
immich_managed_user_preference_profile_by_email: {}
immich_managed_user_preference_overrides: {}
immich_managed_user_preference_profiles:
  standard:
    albums: {defaultAssetOrder: desc}
    avatar: {color: primary}
    cast: {gCastEnabled: false}
    download: {archiveSize: 4294967296, includeEmbeddedVideos: false}
    emailNotifications: {enabled: true, albumInvite: true, albumUpdate: true}
    folders: {enabled: false, sidebarWeb: false}
    memories: {enabled: true, duration: 5}
    people: {enabled: true, sidebarWeb: false, minimumFaces: 3}
    purchase:
      showSupportBadge: true
      hideBuyButtonUntil: "2022-02-12T00:00:00.000Z"
    ratings: {enabled: false}
    recentlyAdded: {sidebarWeb: false}
    sharedLinks: {enabled: true, sidebarWeb: false}
    tags: {enabled: false, sidebarWeb: false}
```

- [ ] **Step 4: Validate preference inputs before service mutation**

In the Immich argument spec and early assertions, reject unknown profile names, override emails absent from `vault_managed_users.immich`, administrator fields, and keys outside the pinned v3.1.0 preference schema. Do not add preference fields to encrypted managed-user records.

- [ ] **Step 5: Verify GREEN**

Run: `ruby tests/managed_users_vault_test.rb && ruby tests/policy_test.rb && ./tests/validate-docs.sh`

Expected: all commands exit 0.

- [ ] **Step 6: Commit**

```sh
git add inventory/group_vars/all templates/vault-plain.yml.j2 tests/generate-ephemeral-vault.sh roles/vault_contract roles/immich/defaults/main.yml roles/immich/meta/argument_specs.yml tests/managed_users_vault_test.rb tests/policy_test.rb
git commit -m "feat: define managed preference and plugin secrets"
```

## Task 2: Refresh and lock the selected container images

**Files:**
- Modify: `services/dozzle/compose.yml`
- Modify: `services/komga/compose.yml`
- Modify: `services/paperless-ngx/compose.yml`
- Modify: every Compose file containing `tinymediamanager/tinymediamanager`
- Modify: `tests/policy_test.rb`

- [ ] **Step 1: Add failing exact-reference assertions**

Require these complete tag-plus-index-digest references and reject the superseded versions:

```text
amir20/dozzle:v10.7.1@sha256:a8441e9d2928cc7b30d0023f5eedbb87ef6e234d87f3be02662bd8f417955b8b
gotson/komga:1.26.1@sha256:e109902ebebb8a05f633f48d84a2ac7bb1334bf0f6fbc17262a333082c7de44d
gotenberg/gotenberg:8.35.0@sha256:a16a14e1f18a71405624bc028e90d4ef50ea774c352b303639c10bf7b141f760
tinymediamanager/tinymediamanager:5.3.1@sha256:bada62a398e3aabe7a67b0e081c40dc08ce74aa86b7ba63e0a34a1bf278146a4
```

- [ ] **Step 2: Run policy and verify RED**

Run: `ruby tests/policy_test.rb`

Expected: nonzero exit naming all four stale image lines.

- [ ] **Step 3: Update every effective image reference**

Change the four selected image lines, including all tinyMediaManager Mac/integration/adoption occurrences returned by:

Run: `rg -l 'tinymediamanager/tinymediamanager' services tests inventory`

- [ ] **Step 4: Reconfirm registry architecture coverage**

Run all four `docker buildx imagetools inspect IMAGE:TAG` commands and confirm each index contains `linux/amd64` and `linux/arm64` and still resolves to the digest above.

- [ ] **Step 5: Render and statically verify the affected services**

Run:

```sh
docker compose -f services/dozzle/compose.yml config >/dev/null
docker compose -f services/komga/compose.yml config >/dev/null
docker compose -f services/paperless-ngx/compose.yml config >/dev/null
ruby tests/policy_test.rb
tests/contracts/dozzle.sh static
tests/contracts/komga.sh static
tests/contracts/paperless.sh static
tests/mac/run-tinymediamanager-contract.sh static
```

Expected: all commands exit 0.

- [ ] **Step 6: Commit**

```sh
git add services tests/policy_test.rb
git commit -m "chore: refresh selected container images"
```

## Task 3: Make Dozzle grouping independent of Compose names

**Files:**
- Modify: `services/beszel/compose.yml`
- Modify: `services/dozzle/compose.yml`
- Modify: `services/immich/compose.yml`
- Modify: `services/paperless-ngx/compose.yml`
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/dozzle_quality_test.rb`
- Modify: `tests/mac/hooks/drift/20-dozzle.sh`
- Modify: `tests/mac/hooks/verify/20-dozzle.sh`

- [ ] **Step 1: Add a failing effective-label contract**

Render each multi-container stack and assert every service has exactly its stable label while single-container services have none.

```ruby
expected = {
  "beszel" => "beszel",
  "dozzle" => "dozzle",
  "immich" => "immich",
  "paperless-ngx" => "paperless"
}
```

- [ ] **Step 2: Verify RED**

Run: `ruby tests/dozzle_quality_test.rb && tests/contracts/dozzle.sh static`

Expected: nonzero exit because effective containers lack `dev.dozzle.group`.

- [ ] **Step 3: Label every member of each multi-container stack**

Add the supported label under every service in the four base Compose files so overlays inherit it.

```yaml
labels:
  dev.dozzle.group: immich
```

Use `beszel`, `dozzle`, `immich`, or `paperless` according to the containing stack. Do not change project or container names.

- [ ] **Step 4: Cover drift and runtime verification**

Have the drift hook remove or corrupt one managed label and add an unrelated sentinel label. Compose owns the complete declared label map, so use the sentinel only to prove full-map reconciliation: verify reconciliation restores the group label and removes the out-of-band sentinel. Inspect effective Docker labels rather than the source YAML alone.

- [ ] **Step 5: Verify GREEN and commit**

Run: `ruby tests/dozzle_quality_test.rb && tests/contracts/dozzle.sh static && tests/mac/dozzle-drift-hook-test.sh`

```sh
git add services/beszel services/dozzle services/immich services/paperless-ngx tests/contracts/dozzle.sh tests/dozzle_quality_test.rb tests/mac/hooks tests/mac/dozzle-drift-hook-test.sh
git commit -m "feat: declare stable Dozzle container groups"
```

## Task 4: Reconcile Audiobookshelf server settings and automatic backups

**Files:**
- Modify: `roles/audiobookshelf/defaults/main.yml`
- Modify: `roles/audiobookshelf/meta/argument_specs.yml`
- Modify: `roles/audiobookshelf/tasks/main.yml`
- Modify: `services/audiobookshelf/compose.yml`
- Modify: `services/audiobookshelf/compose.mac.yml`
- Modify: `services/audiobookshelf/compose.adoption.yml`
- Modify: `tests/contracts/audiobookshelf.sh`
- Modify: `tests/mac/hooks/drift/30-audiobookshelf.sh`
- Modify: `tests/mac/hooks/verify/30-audiobookshelf.sh`
- Modify: `tests/mac/audiobookshelf-drift-hook-test.sh`

- [ ] **Step 1: Add failing static and API assertions**

Require the `/metadata/backups` mount, the owned settings map from the approved design, cron `0 3 * * *`, retention `7`, and API verification through `/api/settings`.

- [ ] **Step 2: Verify RED**

Run: `tests/contracts/audiobookshelf.sh static && tests/mac/audiobookshelf-drift-hook-test.sh`

Expected: nonzero exit naming missing server settings and backup mount/policy.

- [ ] **Step 3: Declare the exact owned state**

Define a single defaults map containing the approved booleans plus `google`, `1`, `dd/MM/yyyy`, `HH:mm`, and `en-us`. Define:

```yaml
audiobookshelf_backup_cron: "0 3 * * *"
audiobookshelf_backup_retention: 7
audiobookshelf_backup_container_path: /metadata/backups
audiobookshelf_backup_host_path: /volume1/Docker/audiobookshelf/backups
```

Map the same container path to disposable state roots in Mac and adoption overlays.

- [ ] **Step 4: Implement read/merge/patch/read-back**

Authenticate with the existing admin flow, GET `/api/settings`, compare only owned leaves, PATCH only on drift, and re-read. Reject a missing or changed schema before mutation. Preserve unowned keys.

- [ ] **Step 5: Add drift and adoption coverage**

Drift one boolean, backup retention, and backup schedule while preserving an unrelated sentinel. Verify both fresh and adoption reconcilers restore owned values without replacing the whole settings document.

- [ ] **Step 6: Verify and commit**

Run:

```sh
ansible-playbook --syntax-check site.yml
tests/contracts/audiobookshelf.sh static
tests/mac/audiobookshelf-drift-hook-test.sh
```

```sh
git add roles/audiobookshelf services/audiobookshelf tests/contracts/audiobookshelf.sh tests/mac
git commit -m "feat: manage Audiobookshelf server and backup settings"
```

## Task 5: Verify Beszel telemetry by platform capability

**Files:**
- Modify: `roles/beszel/defaults/main.yml`
- Modify: `roles/beszel/meta/argument_specs.yml`
- Modify: `roles/beszel/tasks/main.yml`
- Modify: `roles/beszel/vars/main.yml`
- Modify: `tests/contracts/beszel.sh`
- Modify: `tests/mac/hooks/verify/10-beszel.sh`
- Modify: `tests/mac/hooks/drift/10-beszel.sh`

- [ ] **Step 1: Add failing category-specific assertions**

Require recent nonempty Core, Disk, and Containers samples on Mac. Require Core, Disk, GPU, and Containers plus `/dev/dri/renderD128` on AS6704T. A healthy agent alone must not satisfy the contract.

- [ ] **Step 2: Verify RED**

Run: `tests/contracts/beszel.sh static`

Expected: nonzero exit because persisted telemetry categories are not checked.

- [ ] **Step 3: Add explicit capability defaults**

```yaml
beszel_required_telemetry_categories:
  - core
  - disk
  - containers
beszel_require_gpu_telemetry: false
```

Override the NAS policy to append `gpu` and require the render device. Keep the Intel agent image, socket proxy, and existing capacity mounts.

- [ ] **Step 4: Poll persisted telemetry**

Use Beszel's authenticated API to poll boundedly until each required category has a recent timestamp and nonempty category-specific fields. Report category and safe record identifiers on failure; do not print tokens.

- [ ] **Step 5: Verify Mac and NAS static policy, then commit**

Run: `tests/contracts/beszel.sh static && ansible-playbook --syntax-check site.yml`

```sh
git add roles/beszel tests/contracts/beszel.sh tests/mac/hooks
git commit -m "feat: verify Beszel platform telemetry"
```

## Task 6: Apply Immich managed-user preference profiles

**Files:**
- Modify: `roles/immich/tasks/managed_users.yml`
- Modify: `tests/database_managed_users_test.rb`
- Modify: `tests/contracts/immich.sh`
- Modify: `tests/mac/hooks/drift/70-immich.sh`
- Modify: `tests/mac/hooks/verify/70-immich.sh`
- Modify: `tests/mac/hooks/fixtures-seed/70-immich.sh`

- [ ] **Step 1: Add failing profile-selection and preservation tests**

Cover default `standard`, an explicit profile-by-email selection, recursive per-email leaf overrides, rejection of unknown keys/admin fields, and preservation of an unowned sentinel preference.

- [ ] **Step 2: Verify RED**

Run: `ruby tests/database_managed_users_test.rb && tests/contracts/immich.sh static`

Expected: nonzero exit because managed preferences are not reconciled.

- [ ] **Step 3: Build each user's desired owned leaf map**

For each encrypted managed user, select the configured profile or `standard`, recursively merge that user's overrides, and assert the target user is not an administrator. Keep identity/password/name/quota handling unchanged.

- [ ] **Step 4: Implement admin API reconciliation**

Authenticate once as the primary admin; GET the target user's preference document, compare only declared leaves, PATCH the merged owned leaves only on drift, and GET again to verify. Fail on zero/multiple user matches or unsupported response schema.

- [ ] **Step 5: Exercise drift and adoption preservation**

Seed an unrelated preference sentinel, mutate multiple owned leaves, and prove reconciliation restores all profile leaves without deleting the sentinel or changing non-admin status.

- [ ] **Step 6: Verify and commit**

Run:

```sh
ruby tests/database_managed_users_test.rb
tests/contracts/immich.sh static
ansible-playbook --syntax-check site.yml
```

```sh
git add roles/immich tests/database_managed_users_test.rb tests/contracts/immich.sh tests/mac/hooks
git commit -m "feat: reconcile Immich user preferences"
```

## Task 7: Reconcile Jellyfin identity, branding, and libraries

**Files:**
- Add: `roles/jellyfin/files/yonatan-avatar.jpeg`
- Modify: `roles/jellyfin/defaults/main.yml`
- Modify: `roles/jellyfin/meta/argument_specs.yml`
- Modify: `roles/jellyfin/tasks/main.yml`
- Modify: `roles/jellyfin/vars/main.yml`
- Modify: `tests/media_managed_users_test.rb`
- Modify: `tests/contracts/jellyfin.sh`
- Modify: `tests/mac/hooks/fixtures-seed/60-jellyfin.sh`
- Modify: `tests/mac/hooks/drift/60-jellyfin.sh`
- Modify: `tests/mac/hooks/verify/60-jellyfin.sh`

- [ ] **Step 1: Add failing identity, image, server, and library assertions**

Require exact admin name `Yonatan`, server name `Yonflix 2.0`, avatar bytes matching the repository asset, Movies at `/media/Movies`, Shows at `/media/Series`, and no requirement to create Collections.

- [ ] **Step 2: Verify RED**

Run: `ruby tests/media_managed_users_test.rb && tests/contracts/jellyfin.sh static`

Expected: nonzero exit naming the lowercase username, missing avatar, server name, and Shows library.

- [ ] **Step 3: Add the approved avatar asset**

Copy `/Users/yonatankarp-rudin/Documents/upscale.jpeg` byte-for-byte to `roles/jellyfin/files/yonatan-avatar.jpeg`, then record its SHA-256 in the contract so runtime verification compares served bytes to the tracked asset.

- [ ] **Step 4: Reconcile identity and branding safely**

Match the existing primary administrator by its current unique ID or configured username; rename it in place to `Yonatan`. Fail if a separate `Yonatan` or multiple candidates exist. Set `ServerName` while preserving other server configuration. Upload `/UserImage?userId=...` only when the current image differs and verify the returned content hash.

- [ ] **Step 5: Reconcile two path-owned libraries**

```yaml
jellyfin_managed_libraries:
  - name: Movies
    collection_type: movies
    path: /media/Movies
  - name: Shows
    collection_type: tvshows
    path: /media/Series
```

Match by normalized path, rename/update in place, fail on duplicate paths or a desired name bound elsewhere, and preserve unrelated adoption libraries.

- [ ] **Step 6: Cover drift, adoption, and read-back**

Seed an unmanaged library and config sentinel. Drift the admin casing, image, server name, and one owned library. Verify repair preserves both sentinels and the library IDs.

- [ ] **Step 7: Verify and commit**

Run: `ruby tests/media_managed_users_test.rb && tests/contracts/jellyfin.sh static && ansible-playbook --syntax-check site.yml`

```sh
git add roles/jellyfin tests/media_managed_users_test.rb tests/contracts/jellyfin.sh tests/mac/hooks
git commit -m "feat: reconcile Jellyfin identity and libraries"
```

## Task 8: Configure Jellyfin hardware acceleration and plugins

**Files:**
- Modify: `services/jellyfin/compose.yml`
- Modify: `services/jellyfin/compose.mac.yml`
- Modify: `roles/jellyfin/defaults/main.yml`
- Modify: `roles/jellyfin/meta/argument_specs.yml`
- Modify: `roles/jellyfin/tasks/main.yml`
- Modify: `tests/contracts/jellyfin.sh`
- Modify: `tests/mac/hooks/drift/60-jellyfin.sh`
- Modify: `tests/mac/hooks/verify/60-jellyfin.sh`

- [ ] **Step 1: Add failing platform, repository, plugin, and credential assertions**

Require NAS QSV policy and render device, Mac acceleration `none`, the Jellyfin stable and Intro Skipper repository URLs, installed Intro Skipper and Open Subtitles plugins, and successful redacted OpenSubtitles credential validation.

- [ ] **Step 2: Verify RED**

Run: `tests/contracts/jellyfin.sh static`

Expected: nonzero exit naming missing encoding fields, repository, plugins, and OpenSubtitles configuration.

- [ ] **Step 3: Reconcile the platform encoding document**

On NAS, merge the owned `qsv` device/codecs/10-bit/hardware-encode/HEVC/low-power/VPP fields from the approved design into the named `encoding` configuration and preserve unrelated fields. Require `/dev/dri/renderD128` before mutation and run Jellyfin's FFmpeg device probe. On Mac, own `HardwareAccelerationType: none` and require no render device.

- [ ] **Step 4: Reconcile repository URLs and plugin presence**

Merge enabled repositories by normalized URL, preserving unrelated entries and failing on duplicates. Ensure:

```text
https://repo.jellyfin.org/releases/plugin/manifest-stable.json
https://intro-skipper.org/manifest.json
```

Install `Intro Skipper` and `Open Subtitles` only when absent, without a version argument. If installation reports restart required, restart Jellyfin once, wait healthy, reauthenticate, and re-read installed plugins.

- [ ] **Step 5: Configure and validate OpenSubtitles**

POST the two vault values to the installed plugin configuration endpoint, invoke its credential validation endpoint, and retain only boolean/status results. Never include either value or authorization headers in Ansible output or reports.

- [ ] **Step 6: Add idempotence and drift coverage**

Drift one owned encoding leaf and disable the Intro Skipper repo while preserving an unrelated repository and plugin. Verify repair does not pin/downgrade installed plugin versions and a second run reports zero changes.

- [ ] **Step 7: Verify and commit**

Run: `tests/contracts/jellyfin.sh static && ansible-playbook --syntax-check site.yml && ruby tests/policy_test.rb`

```sh
git add services/jellyfin roles/jellyfin tests/contracts/jellyfin.sh tests/mac/hooks tests/policy_test.rb
git commit -m "feat: manage Jellyfin acceleration and plugins"
```

## Task 9: Rename the Komga library by normalized root path

**Files:**
- Modify: `roles/komga/defaults/main.yml`
- Modify: `roles/komga/tasks/main.yml`
- Modify: `tests/contracts/komga.sh`
- Modify: `tests/mac/hooks/fixtures-seed/40-komga.sh`
- Modify: `tests/mac/hooks/drift/40-komga.sh`
- Modify: `tests/mac/hooks/verify/40-komga.sh`

- [ ] **Step 1: Add failing fresh/adoption assertions**

Require one `Comics` library at normalized root `/data`, forbid a second managed-root library, and assert adoption preserves the original library ID and unrelated libraries.

- [ ] **Step 2: Verify RED**

Run: `tests/contracts/komga.sh static`

Expected: nonzero exit because the desired library is still `Books` and matching is name-first.

- [ ] **Step 3: Implement path-first reconciliation**

Change the declared name to `Comics`. Normalize trailing slashes before matching `/data`; rename the unique path match in place. Fail before mutation on multiple path matches or a separate `Comics` at another path. Preserve the existing scanning and format settings.

- [ ] **Step 4: Verify and commit**

Run: `tests/contracts/komga.sh static && ansible-playbook --syntax-check site.yml`

```sh
git add roles/komga tests/contracts/komga.sh tests/mac/hooks
git commit -m "feat: reconcile Komga Comics library"
```

## Task 10: Synchronize ntfy account subscriptions

**Files:**
- Modify: `roles/ntfy/defaults/main.yml`
- Modify: `roles/ntfy/meta/argument_specs.yml`
- Modify: `roles/ntfy/tasks/managed_users.yml`
- Modify: `tests/config_managed_users_test.rb`
- Modify: `tests/ntfy_verify_execution_test.rb`
- Modify: `tests/mac/hooks/fixtures-recreate/15-ntfy.sh`
- Add: `tests/mac/hooks/verify/15-ntfy.sh`

- [ ] **Step 1: Add failing eligible-user subscription tests**

For every interactive managed ntfy user with read access to `nas-critical`, require exactly one account subscription with `base_url: ntfy_base_url` and `topic: nas-critical`. Cover preservation of unrelated subscriptions and exclusion of ineligible/noninteractive users.

- [ ] **Step 2: Verify RED**

Run: `ruby tests/config_managed_users_test.rb && ruby tests/ntfy_verify_execution_test.rb`

Expected: nonzero exit because only ACL state is currently reconciled.

- [ ] **Step 3: Add supported account reconciliation**

Authenticate as each eligible user, GET `/v1/account`, and POST `/v1/account/subscription` only when the exact pair is absent.

```yaml
base_url: "{{ ntfy_base_url }}"
topic: nas-critical
```

Treat one match as success, multiple matches as failure, and HTTP 409 as provisional: immediately re-read and accept it only if exactly one desired subscription now exists.

- [ ] **Step 4: Verify through each managed account**

The verify hook must authenticate each eligible account and inspect synchronized account state. It must not require browser notification permission or a device-specific Web Push endpoint.

- [ ] **Step 5: Verify and commit**

Run:

```sh
ruby tests/config_managed_users_test.rb
ruby tests/ntfy_verify_execution_test.rb
ansible-playbook --syntax-check site.yml
```

```sh
git add roles/ntfy tests/config_managed_users_test.rb tests/ntfy_verify_execution_test.rb tests/mac/hooks
git commit -m "feat: synchronize ntfy critical subscriptions"
```

## Task 11: Harden Paperless mail probing and document storage

**Files:**
- Modify: `roles/paperless_ngx/defaults/main.yml`
- Modify: `roles/paperless_ngx/meta/argument_specs.yml`
- Modify: `roles/paperless_ngx/tasks/main.yml`
- Modify: `services/paperless-ngx/compose.yml`
- Modify: `services/paperless-ngx/compose.mac.yml`
- Modify: `services/paperless-ngx/compose.adoption.yml`
- Modify: `tests/contracts/paperless.sh`
- Modify: `tests/mac/hooks/fixtures-seed/80-paperless.sh`
- Modify: `tests/mac/hooks/drift/80-paperless.sh`
- Modify: `tests/mac/hooks/verify/80-paperless.sh`

- [ ] **Step 1: Add failing mail-probe and effective-mount assertions**

Require the synchronous mail-test response as the credential signal; snapshot only the managed mail account/rule records before and after; forbid document-bearing mounts under `/volume1`; and require archive/originals, inbox, and export on the approved `/volume2/Documents/...` paths. Add no Paperless tag assertions.

- [ ] **Step 2: Verify RED**

Run: `tests/contracts/paperless.sh static`

Expected: nonzero exit because the current probe uses global task counts and effective document mounts are not fully enforced.

- [ ] **Step 3: Make the mail probe deterministic**

Read and normalize the uniquely matched managed mail account and rule before the test. Invoke the synchronous mail-account test, require its explicit success response, then re-read and compare those same records. Do not compare document counts or the global task table. Persist or repair the managed account/rule only after probe success.

- [ ] **Step 4: Enforce storage ownership in effective Compose**

Use:

```yaml
paperless_archive_host_path: /volume2/Documents/archive
paperless_consume_host_path: /volume2/Documents/inbox
paperless_export_host_path: /volume2/Documents/export
paperless_state_host_path: /volume1/Docker/paperless-ngx
```

Render the full Compose stack and inspect actual source/target pairs. Fail if originals/archive, consume, or export resolves under volume1. Keep PostgreSQL, Redis, app data, caches, and OCR models under the state root.

- [ ] **Step 5: Cover adoption and drift without tags**

Seed an unrelated account/rule and concurrent global task activity. Verify the managed records reconcile, unrelated records survive, and no test creates, merges, exports, or verifies Paperless tags.

- [ ] **Step 6: Verify and commit**

Run: `tests/contracts/paperless.sh static && ansible-playbook --syntax-check site.yml && ruby tests/policy_test.rb`

```sh
git add roles/paperless_ngx services/paperless-ngx tests/contracts/paperless.sh tests/mac/hooks tests/policy_test.rb
git commit -m "fix: make Paperless mail and storage reconciliation deterministic"
```

## Task 12: Add the resumable fresh-Mac manual-validation handoff

**Files:**
- Modify: `tests/mac/run.sh`
- Modify: `tests/mac/run-phase-status-test.sh`
- Modify: `tests/mac/adoption-runner-test.sh`
- Add: `tests/mac/manual-validation-runner-test.sh`
- Modify: `tests/policy_test.rb`

- [ ] **Step 1: Add failing CLI and handoff tests**

Test that `--manual-validation` is accepted only with `--lane fresh` and no selected `--phase`; that execution stops successfully after `verify`; that the sandbox is retained and the lock released; and that resume skips completed phases and starts with `idempotence`.

- [ ] **Step 2: Add output-safety assertions**

Feed recognizable fake passwords/tokens through the test vault and require that handoff output contains none of them. Require sandbox/report roots, every service URL, nonsecret primary and managed usernames, an exact same-vault `--sandbox` resume command, and an exact cleanup command.

- [ ] **Step 3: Verify RED**

Run: `tests/mac/manual-validation-runner-test.sh`

Expected: nonzero exit because the flag and handoff do not exist.

- [ ] **Step 4: Parse and validate the new option**

Add `--manual-validation` to usage and argument parsing. Reject it unless lane is `fresh`, phase selection is empty, and the invocation is a full run. Preserve the existing behavior when absent.

- [ ] **Step 5: Stop cleanly after verify**

After `verify` is durably marked passed, set the preserve-sandbox state, release the integration lock through the existing cleanup path, print the handoff, and exit 0 before `idempotence`. Do not mark later phases passed or run report/cleanup.

- [ ] **Step 6: Print an exact resumable handoff**

Construct the resume command from the canonicalized supplied vault paths and sandbox path:

```sh
tests/mac/run.sh \
  --lane fresh \
  --vault-file "$VAULT_FILE" \
  --vault-password-file "$VAULT_PASSWORD_FILE" \
  --sandbox "$SANDBOX_ROOT"
```

Print usernames only; tell the operator to retrieve passwords from the encrypted source. Print the existing explicit cleanup command for that exact sandbox.

- [ ] **Step 7: Verify and commit**

Run:

```sh
tests/mac/manual-validation-runner-test.sh
tests/mac/run-phase-status-test.sh
tests/mac/adoption-runner-test.sh
ruby tests/policy_test.rb
```

```sh
git add tests/mac/run.sh tests/mac/manual-validation-runner-test.sh tests/mac/run-phase-status-test.sh tests/mac/adoption-runner-test.sh tests/policy_test.rb
git commit -m "feat: add resumable Mac manual validation handoff"
```

## Task 13: Run repository and lane-level verification

**Files:**
- Modify only if a test exposes an implementation defect in an earlier task.
- Update: `docs/superpowers/plans/2026-08-11-manual-validation-corrections.md` (checkboxes only)

- [ ] **Step 1: Run formatting, policy, syntax, and static contracts**

```sh
git diff --check
./tests/validate-docs.sh
ruby tests/policy_test.rb
ruby tests/managed_users_vault_test.rb
ruby tests/database_managed_users_test.rb
ruby tests/media_managed_users_test.rb
ruby tests/config_managed_users_test.rb
ruby tests/ntfy_verify_execution_test.rb
ansible-playbook --syntax-check site.yml
tests/contracts/audiobookshelf.sh static
tests/contracts/beszel.sh static
tests/contracts/dozzle.sh static
tests/contracts/immich.sh static
tests/contracts/jellyfin.sh static
tests/contracts/komga.sh static
tests/contracts/paperless.sh static
tests/mac/run-tinymediamanager-contract.sh static
```

Expected: every command exits 0.

- [ ] **Step 2: Re-run focused runner tests**

```sh
tests/mac/manual-validation-runner-test.sh
tests/mac/run-phase-status-test.sh
tests/mac/adoption-runner-test.sh
```

Expected: every command exits 0 and no retained output contains a vault secret.

- [ ] **Step 3: Prepare the external deployment vault interactively**

Use `ansible-vault edit "$HOME/.config/nas-platform/vault.yml"` to change `vault_jellyfin_admin_username` to exact `Yonatan` and add real non-placeholder OpenSubtitles credentials. Do not copy decrypted values into the repository, shell history, logs, or plan. Run the vault contract with `--vault-password-file "$HOME/.config/nas-platform/vault-password"` before deployment.

- [ ] **Step 4: Run the fresh proof to the manual handoff**

```sh
tests/mac/run.sh \
  --lane fresh \
  --manual-validation \
  --vault-file "$HOME/.config/nas-platform/vault.yml" \
  --vault-password-file "$HOME/.config/nas-platform/vault-password"
```

Expected: deploy, seed, and verify pass; the runner exits 0 with the sandbox retained, lock released, URLs/usernames shown, and exact resume/cleanup commands printed.

- [ ] **Step 5: Perform the operator checkpoint**

Log in as every printed primary and managed user and manually validate the approved UI state. Keep the sandbox unchanged until acceptance. This is the one intentional human checkpoint.

- [ ] **Step 6: Resume the fresh proof**

Run the exact printed command with the same vault inputs and `--sandbox`. Expected: completed phases are skipped; idempotence, drift, reconcile, recreate, persistence, report, and cleanup pass.

- [ ] **Step 7: Run the adoption proof**

Run the repository's full adoption lane with the same external vault inputs. Expected: all owned state converges, seeded unmanaged sentinels survive, and all phases pass.

- [ ] **Step 8: Inspect final state and commit any verification-only corrections**

Run `git status --short`, `git diff --check`, and inspect every diff. If verification required no changes, do not create an empty commit. If it exposed a defect, fix it in its owning task's files, rerun the affected focused test plus Steps 1, 2, 6, and 7, then commit without a `Co-Authored-By` trailer.
