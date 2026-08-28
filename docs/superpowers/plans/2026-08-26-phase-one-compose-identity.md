# Phase One Compose Identity and Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore canonical Configarr Compose policy and make Configarr and Unpackerr consume the platform UID/GID without numeric literals.

**Architecture:** Move the profiled Configarr one-shot into the canonical Arr Compose file so the ordinary policy and deployment pipeline owns it. Resolve direct-user identity from `NAS_UID` and `NAS_GID`, and prove effective Compose output with non-default IDs.

**Tech Stack:** Docker Compose, Ansible, Ruby policy tests, YAML.

---

### Task 1: Pin dynamic direct-user identity

**Files:**
- Modify: `tests/media_acquisition_phase1_test.rb:1-190`
- Modify: `services/downloaders/compose.yml:45-58`
- Test: `tests/media_acquisition_phase1_test.rb`

- [ ] **Step 1: Write the failing identity contract**

Require `open3`, add an effective-Compose helper, and replace literal assertions with dynamic identity assertions:

```ruby
require "open3"

def effective_compose(relative, environment)
  stdout, stderr, status = Open3.capture3(
    environment, "docker", "compose", "-f", relative, "config", "--format", "json",
    chdir: ROOT
  )
  raise "#{relative} effective Compose failed: #{stderr.lines.first&.strip}" unless status.success?

  JSON.parse(stdout)
end
```

Add `require "json"` and these checks after loading the Compose documents:

```ruby
check(failures, downloaders_compose.dig("services", "unpackerr", "user") ==
                "${NAS_UID:?}:${NAS_GID:?}",
      "Unpackerr must consume the platform filesystem identity")
check(failures, !File.read(File.join(ROOT, "services/downloaders/compose.yml")).include?('user: "1000:100"'),
      "downloaders Compose must not embed the current NAS identity")

effective_downloaders = effective_compose(
  "services/downloaders/compose.yml",
  {
    "NAS_UID" => "2345", "NAS_GID" => "3456", "TZ" => "UTC",
    "PLATFORM_CONTAINER_CPUSET" => "0", "PLATFORM_MEDIA_NETWORK" => "fixture-media",
    "SABNZBD_CONFIG_PATH" => "/tmp/sabnzbd", "MEDIA_ACQUISITION_PATH" => "/tmp/media",
    "BOOKS_ACQUISITION_PATH" => "/tmp/books", "SABNZBD_API_KEY" => "fixture",
    "RADARR_API_KEY" => "fixture", "SONARR_API_KEY" => "fixture"
  }
)
check(failures, effective_downloaders.dig("services", "unpackerr", "user") == "2345:3456",
      "effective Unpackerr identity must follow non-default NAS_UID:NAS_GID")
```

- [ ] **Step 2: Run the contract and confirm RED**

Run: `ruby tests/media_acquisition_phase1_test.rb`

Expected: FAIL with `Unpackerr must consume the platform filesystem identity`.

- [ ] **Step 3: Use the platform identity for Unpackerr**

Change only the Unpackerr declaration:

```yaml
    user: "${NAS_UID:?}:${NAS_GID:?}"
```

- [ ] **Step 4: Verify and commit**

Run: `ruby tests/media_acquisition_phase1_test.rb`

Expected: `media acquisition phase 1: activation contract holds`.

```bash
git add services/downloaders/compose.yml tests/media_acquisition_phase1_test.rb
git commit -m "fix: derive acquisition container identity"
```

### Task 2: Return Configarr to canonical Arr Compose

**Files:**
- Modify: `services/arr/compose.yml:1-110`
- Delete: `services/arr/compose.jobs.yml`
- Modify: `roles/arr/tasks/configarr.yml:11-20`
- Modify: `roles/arr/tasks/main.yml:10-20`
- Modify: `roles/deployment_bundle/tasks/main.yml:60-75,210-225`
- Modify: `roles/deployment_bundle/tasks/inputs.yml:50-65`
- Modify: `tests/configarr_job_test.rb:10-100`
- Modify: `tests/media_acquisition_phase1_test.rb:95-185`
- Modify: `tests/policy_test.rb:715-760`
- Modify: `tests/verify_deployment_manifest.rb:35-48`
- Modify: `tests/integration.sh:335-350`
- Modify: `tests/integration_suite_test.sh:625-675`
- Test: `tests/configarr_job_test.rb`
- Test: `tests/media_acquisition_phase1_test.rb`

- [ ] **Step 1: Write the failing canonical-job tests**

Load Configarr from canonical Arr Compose and reject the exception file:

```ruby
arr_compose = YAML.safe_load_file(File.join(ROOT, "services/arr/compose.yml"), aliases: true)
configarr = arr_compose.dig("services", "configarr") || {}
check(failures, !File.exist?(File.join(ROOT, "services/arr/compose.jobs.yml")),
      "Configarr must not escape canonical Arr Compose")
check(failures, configarr["profiles"] == ["jobs"], "Configarr must use only the jobs profile")
check(failures, configarr["user"] == "${NAS_UID:?}:${NAS_GID:?}",
      "Configarr must consume the platform filesystem identity")
check(failures, configarr["logging"] == {
        "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
      }, "Configarr logging must be bounded")
check(failures, !configarr.key?("restart") && !configarr.key?("ports"),
      "Configarr must remain a non-restarting unpublished one-shot")
```

Change the run-task assertion to require exactly the canonical platform files:

```ruby
check(failures, run["files"] == "{{ platform_service_compose_files['arr'] }}",
      "Configarr must run from the canonical deployed Compose set")
```

- [ ] **Step 2: Run the two contracts and confirm RED**

Run: `ruby tests/configarr_job_test.rb && ruby tests/media_acquisition_phase1_test.rb`

Expected: both fail because Configarr remains in `compose.jobs.yml`.

- [ ] **Step 3: Add the canonical job definition**

Add a job extension after `x-service-defaults`:

```yaml
x-job-defaults: &job-defaults
  cpuset: ${PLATFORM_CONTAINER_CPUSET:?}
  logging: *default-logging
  networks:
    - media-control
```

Add Configarr under canonical `services`:

```yaml
  configarr:
    <<: *job-defaults
    profiles: [jobs]
    image: ghcr.io/raydak-labs/configarr:1.28.0@sha256:008d8659ff35f63fbcc20b860b33ba7cc49e8d7458a6ec446810ec4d783ef017
    user: "${NAS_UID:?}:${NAS_GID:?}"
    cpus: 0.5
    environment:
      GIT_CONFIG_COUNT: "2"
      GIT_CONFIG_KEY_0: safe.directory
      GIT_CONFIG_VALUE_0: /app/repos/trash-guides
      GIT_CONFIG_KEY_1: safe.directory
      GIT_CONFIG_VALUE_1: /app/repos/recyclarr-config
    volumes:
      - ${CONFIGARR_CONFIG_PATH:?}:/app/config/config.yml:ro
      - ${CONFIGARR_SECRETS_PATH:?}:/app/config/secrets.yml:ro
      - ${CONFIGARR_REPOS_PATH:?}:/app/repos
```

Delete `services/arr/compose.jobs.yml`.

- [ ] **Step 4: Remove the deployment exception**

Use only canonical files in `roles/arr/tasks/configarr.yml`:

```yaml
    files: "{{ platform_service_compose_files['arr'] }}"
```

Remove `compose.jobs.yml` from Arr target validation, deployment-bundle source inspection/copying, input validation, manifest verification, and integration image enumeration. Configarr's image will now be discovered by the ordinary canonical Compose image reader.

In `tests/policy_test.rb`, make the exact canonical service set include both
long-running and profiled catalog services. Keep the existing job-specific
assertions so Configarr is still required to use only `profiles: [jobs]`, while
the common CPU, digest, logging, privilege, and volume policy now applies to it
from canonical Compose.

- [ ] **Step 5: Verify policy and deployment contracts**

Run:

```bash
ruby tests/configarr_job_test.rb
ruby tests/media_acquisition_phase1_test.rb
ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
ruby tests/verify_deployment_manifest.rb --self-test
tests/integration_suite_test.sh
../../.venv/bin/ansible-playbook site.yml --syntax-check
```

Expected: every command exits 0; Configarr is found in canonical Compose and no source references `compose.jobs.yml`.

- [ ] **Step 6: Commit canonical Configarr**

```bash
git add services/arr roles/arr roles/deployment_bundle tests
git commit -m "fix: restore canonical Configarr policy"
```

### Task 3: Prove arbitrary effective Configarr identity

**Files:**
- Modify: `tests/media_acquisition_phase1_test.rb`
- Test: `tests/media_acquisition_phase1_test.rb`

- [ ] **Step 1: Extend effective Compose coverage**

Resolve canonical Arr Compose with non-default identity:

```ruby
effective_arr = effective_compose(
  "services/arr/compose.yml",
  {
    "NAS_UID" => "2345", "NAS_GID" => "3456", "TZ" => "UTC",
    "PLATFORM_CONTAINER_CPUSET" => "0", "PLATFORM_MEDIA_NETWORK" => "fixture-media",
    "MEDIA_ROOT" => "/tmp/media", "RADARR_CONFIG_PATH" => "/tmp/radarr",
    "SONARR_CONFIG_PATH" => "/tmp/sonarr", "PROWLARR_CONFIG_PATH" => "/tmp/prowlarr",
    "BAZARR_CONFIG_PATH" => "/tmp/bazarr", "CONFIGARR_CONFIG_PATH" => "/tmp/configarr.yml",
    "CONFIGARR_SECRETS_PATH" => "/tmp/configarr-secrets.yml",
    "CONFIGARR_REPOS_PATH" => "/tmp/configarr-repos"
  }
)
check(failures, effective_arr.dig("services", "configarr", "user") == "2345:3456",
      "effective Configarr identity must follow non-default NAS_UID:NAS_GID")
```

- [ ] **Step 2: Run the full focused policy set**

Run:

```bash
ruby tests/media_acquisition_phase1_test.rb
ruby tests/configarr_job_test.rb
ruby tests/policy_test.rb
../../.venv/bin/ansible-lint --strict
git diff --check origin/main..HEAD
```

Expected: all commands exit 0 and neither acquisition Compose source contains `user: "1000:100"`.

- [ ] **Step 3: Commit any test-only refinement**

If Step 1 was not included in Task 2's commit:

```bash
git add tests/media_acquisition_phase1_test.rb
git commit -m "test: verify effective acquisition identity"
```
