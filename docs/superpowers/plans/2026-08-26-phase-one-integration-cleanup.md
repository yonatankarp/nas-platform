# Phase One Integration Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Namespace Arr/downloader integration resources and delete them only when exact Compose ownership labels prove sandbox ownership.

**Architecture:** Derive one lowercase project namespace from the validated sandbox suffix and pass it through the existing platform project interface. Integration overrides name only the new Arr/downloader containers; cleanup discovers their projects by exact labels and refuses name/label mismatches while preserving unrelated production-named resources.

**Tech Stack:** POSIX shell, Docker Compose labels, Ruby/shell policy fixtures, GitHub CLI.

---

### Task 1: Prove unsafe fixed-name cleanup

**Files:**
- Create: `tests/sandbox_cleanup_acquisition_ownership_test.sh`
- Modify: `tests/validate-policy.sh`
- Modify: `tests/policy_ci_test.rb`
- Modify: `tests/policy_mutation_support.rb`
- Test: `tests/sandbox_cleanup_acquisition_ownership_test.sh`

- [ ] **Step 1: Create unrelated-resource sentinels**

Source `tests/sandbox_cleanup.sh` and use its exact
`cleanup_sandbox_image` digest for disposable containers. Create containers
named `radarr` and `sabnzbd`, networks named `arr_default` and
`downloaders_default`, record their IDs, call cleanup for a valid
`nas-platform-integration.XXXXXX` directory, and require all four IDs still
exist unchanged. Use `trap` cleanup so the fixture removes only the IDs it
created even when an assertion fails.

It must separately seed containers and networks with exact expected labels:

```text
com.docker.compose.project=nas-platform-integration-a1b2c3-arr
com.docker.compose.project=nas-platform-integration-a1b2c3-downloaders
```

and exact namespace-derived names, then require cleanup removes them. A correct
name with a wrong/missing project label and a correct label with an unexpected
name must make cleanup fail without deletion. Include an interrupted Configarr
one-shot fixture whose name matches
`nas-platform-integration-a1b2c3-arr-configarr-run-[a-z0-9]+`, service label is
`configarr`, and one-off label is `True`; cleanup must remove it only when all
three identity checks match.

- [ ] **Step 2: Run the test and confirm RED**

Run: `tests/sandbox_cleanup_acquisition_ownership_test.sh`

Expected: FAIL because current cleanup deletes the unrelated production-named sentinels.

- [ ] **Step 3: Register and commit the RED test**

Add the exact test command to `tests/validate-policy.sh`, require it in `tests/policy_ci_test.rb`, and copy it in `tests/policy_mutation_support.rb`.

```bash
git add tests/sandbox_cleanup_acquisition_ownership_test.sh tests/validate-policy.sh tests/policy_ci_test.rb tests/policy_mutation_support.rb
git commit -m "test: expose acquisition cleanup ownership"
```

### Task 2: Derive the disposable project namespace

**Files:**
- Modify: `tests/integration.sh:420-450,830-930`
- Modify: `services/arr/compose.integration.yml`
- Modify: `services/downloaders/compose.integration.yml`
- Modify: `tests/policy_integration_test.rb`
- Modify: `tests/integration_suite_test.sh`
- Test: `tests/integration_suite_test.sh`

- [ ] **Step 1: Pin namespace derivation**

After sandbox validation, derive:

```sh
integration_suffix=${sandbox##*.}
integration_suffix=$(printf '%s' "$integration_suffix" | tr '[:upper:]' '[:lower:]')
integration_project_namespace=nas-platform-integration-$integration_suffix
```

Require the result to match `nas-platform-integration-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]`, then add this exact extra var in `run_play`:

```sh
-e platform_project_name="$integration_project_namespace"
```

- [ ] **Step 2: Namespace the new integration containers**

Use the established Mac naming pattern in Arr:

```yaml
services:
  radarr:
    container_name: ${PLATFORM_PROJECT_NAME:?}-radarr
  sonarr:
    container_name: ${PLATFORM_PROJECT_NAME:?}-sonarr
  prowlarr:
    container_name: ${PLATFORM_PROJECT_NAME:?}-prowlarr
  bazarr:
    container_name: ${PLATFORM_PROJECT_NAME:?}-bazarr
  configarr: {}
```

And downloaders:

```yaml
services:
  sabnzbd:
    container_name: ${PLATFORM_PROJECT_NAME:?}-sabnzbd
  unpackerr:
    container_name: ${PLATFORM_PROJECT_NAME:?}-unpackerr
```

- [ ] **Step 3: Verify and commit**

Run:

```bash
tests/integration_suite_test.sh
ruby tests/policy_integration_test.rb
env PLATFORM_PROJECT_NAME=nas-platform-integration-a1b2c3 \
  PLATFORM_MEDIA_NETWORK=nas-platform-integration-a1b2c3-media-control \
  PLATFORM_CONTAINER_CPUSET=0 NAS_UID=2345 NAS_GID=3456 TZ=UTC \
  MEDIA_ROOT=/tmp/media RADARR_CONFIG_PATH=/tmp/radarr \
  SONARR_CONFIG_PATH=/tmp/sonarr PROWLARR_CONFIG_PATH=/tmp/prowlarr \
  BAZARR_CONFIG_PATH=/tmp/bazarr CONFIGARR_CONFIG_PATH=/tmp/configarr.yml \
  CONFIGARR_SECRETS_PATH=/tmp/configarr-secrets.yml \
  CONFIGARR_REPOS_PATH=/tmp/configarr-repos \
  docker compose --project-name nas-platform-integration-a1b2c3-arr \
    -f services/arr/compose.yml -f services/arr/compose.integration.yml \
    config --quiet
env PLATFORM_PROJECT_NAME=nas-platform-integration-a1b2c3 \
  PLATFORM_MEDIA_NETWORK=nas-platform-integration-a1b2c3-media-control \
  PLATFORM_CONTAINER_CPUSET=0 NAS_UID=2345 NAS_GID=3456 TZ=UTC \
  SABNZBD_CONFIG_PATH=/tmp/sabnzbd MEDIA_ACQUISITION_PATH=/tmp/media \
  BOOKS_ACQUISITION_PATH=/tmp/books SABNZBD_API_KEY=fixture \
  RADARR_API_KEY=fixture SONARR_API_KEY=fixture \
  docker compose --project-name nas-platform-integration-a1b2c3-downloaders \
    -f services/downloaders/compose.yml \
    -f services/downloaders/compose.integration.yml config --quiet
```

Expected: all commands exit 0 and effective container names begin with the disposable namespace.

```bash
git add tests/integration.sh services/arr/compose.integration.yml services/downloaders/compose.integration.yml tests/policy_integration_test.rb tests/integration_suite_test.sh
git commit -m "fix: namespace acquisition integration resources"
```

### Task 3: Delete only exact labelled sandbox resources

**Files:**
- Modify: `tests/sandbox_cleanup.sh:1-180`
- Modify: `tests/sandbox_cleanup_acquisition_ownership_test.sh`
- Modify: `tests/policy_mac_test.rb`
- Test: `tests/sandbox_cleanup_acquisition_ownership_test.sh`

- [ ] **Step 1: Remove unsafe global names**

Delete Arr/downloader names from `cleanup_sandbox_containers` and delete `arr_default downloaders_default` from `cleanup_sandbox_networks`.

- [ ] **Step 2: Add exact project cleanup**

Derive the namespace from the validated sandbox name. For each suffix `arr` and `downloaders`, query resources only by exact Compose project label:

```sh
cleanup_project=$cleanup_project_namespace-$cleanup_project_kind
docker ps -aq --filter "label=com.docker.compose.project=$cleanup_project"
docker network ls -q --filter "label=com.docker.compose.project=$cleanup_project"
```

First inspect the six exact permanent container names and the two exact default
network names. If one exists without the exact expected project label, refuse.
Then collect every ID carrying either exact project label. Before deleting any
of them, inspect the complete collected set and require:

- `com.docker.compose.project` equals the exact project;
- a permanent container name is exactly one of
  `${cleanup_project_namespace}-{radarr,sonarr,prowlarr,bazarr,sabnzbd,unpackerr}`
  in its corresponding project; or an Arr Configarr one-shot has service label
  `configarr`, one-off label `True`, and the strict generated name
  `${cleanup_project_namespace}-arr-configarr-run-[a-z0-9]+`;
- network name equals `${cleanup_project}_default` and its
  `com.docker.compose.network` label equals `default`.

Any mismatch prints a refusal and returns nonzero before deleting any collected
resource. Only after every ID passes preflight may cleanup call `docker rm -f`
or `docker network rm`.

- [ ] **Step 3: Run ownership and regression tests**

Run:

```bash
tests/sandbox_cleanup_acquisition_ownership_test.sh
ruby tests/policy_mac_test.rb
tests/integration_lock_test.sh
git diff --check
```

Expected: unrelated fixed-name resources survive, exact labelled resources are removed, and mismatch fixtures refuse without deletion.

- [ ] **Step 4: Commit**

```bash
git add tests/sandbox_cleanup.sh tests/sandbox_cleanup_acquisition_ownership_test.sh tests/policy_mac_test.rb
git commit -m "fix: scope acquisition integration cleanup"
```

### Task 4: Correct documentation and create follow-up issues

**Files:**
- Modify: `docs/superpowers/plans/2026-08-25-phase-one-ci-portability.md:449-450`
- External: GitHub issues in `yonatankarp/nas-platform`

- [ ] **Step 1: Correct targeted-suite commands**

Replace the two commands with:

```sh
tests/integration.sh --suite arr site.yml
tests/integration.sh --suite downloaders site.yml
```

- [ ] **Step 2: Check for duplicate follow-up issues**

Run:

```bash
gh issue list --repo yonatankarp/nas-platform --state all --search 'hardcoded UID GID Audiobookshelf Jellyfin Komga'
gh issue list --repo yonatankarp/nas-platform --state all --search 'integration cleanup fixed names ownership labels'
```

Expected: reuse an existing matching issue if present; otherwise create one per concern.

- [ ] **Step 3: Create the legacy identity issue when absent**

```bash
gh issue create --repo yonatankarp/nas-platform \
  --title 'Migrate legacy reader containers to the platform filesystem identity' \
  --body $'Audiobookshelf, Jellyfin, and Komga still embed `1000:100` in canonical Compose while newer direct-user services consume `${NAS_UID:?}:${NAS_GID:?}`.\n\nScope:\n- verify each image supports an arbitrary numeric UID/GID;\n- switch all three to the shared platform identity without changing NAS media ownership;\n- add effective-Compose tests with non-default IDs;\n- prove NAS and Mac read-only media access and service-state writes.'
```

- [ ] **Step 4: Create the legacy cleanup issue when absent**

```bash
gh issue create --repo yonatankarp/nas-platform \
  --title 'Namespace legacy integration resources and clean up by ownership labels' \
  --body $'The integration harness still cleans several pre-existing service containers by fixed production names. PR #95 scopes newly added Arr/downloader resources, but the remaining services need the same derived project namespace and exact Compose-label cleanup.\n\nAcceptance:\n- no unconditional fixed-name container or network deletion;\n- exact sandbox-derived project names;\n- label and name validation before removal;\n- unrelated same-name resources survive cleanup fixtures.'
```

- [ ] **Step 5: Commit documentation**

```bash
git add docs/superpowers/plans/2026-08-25-phase-one-ci-portability.md
git commit -m "docs: correct acquisition suite commands"
```

### Task 5: Run targeted live acceptance

**Files:**
- Verify only: all files changed by the three hardening plans

- [ ] **Step 1: Run focused policy**

Run:

```bash
ruby tests/media_acquisition_phase1_test.rb
ruby tests/configarr_job_test.rb
ruby tests/media_acquisition_reconciliation_test.rb
tests/sandbox_cleanup_acquisition_ownership_test.sh
ruby tests/policy_test.rb
ruby tests/policy_ci_test.rb
ruby tests/policy_manifest_test.rb
../../.venv/bin/ansible-lint --strict
../../.venv/bin/ansible-playbook site.yml --syntax-check
```

Expected: every command exits 0.

- [ ] **Step 2: Run correctly targeted live suites**

Run sequentially:

```bash
tests/integration.sh --suite arr site.yml
tests/integration.sh --suite downloaders site.yml
```

Expected: both exit 0, include runtime verification, and their second normal enabled convergence reports `changed=0`.

- [ ] **Step 3: Check branch integrity**

Run:

```bash
git diff --check origin/main..HEAD
git status --short --branch
git log --format='%H%n%B%n---' origin/main..HEAD
```

Expected: clean worktree, no whitespace errors, and no `Co-Authored-By` trailers.
