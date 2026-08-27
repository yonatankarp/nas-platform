# Phase One CI Portability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PR #95's Configarr lint and Linux Arr/downloader integration lanes pass without weakening production NAS media ownership.

**Architecture:** Treat Configarr's tagged YAML as one exact opaque application payload in Ansible lint while retaining its dedicated contract test. Mark the exact media-acquisition writer directories in the central storage inventory, then let `host_prep` apply and verify `nas_uid:nas_gid` only inside the six-character disposable integration sandbox selected by all four test-boundary guards; production declarations remain ownerless.

**Tech Stack:** Ansible Core, ansible-lint, Ruby contract tests, POSIX shell integration harness, Docker Compose, GitHub Actions.

---

### Task 1: Bound Ansible lint around the Configarr application payload

**Files:**
- Modify: `tests/ci/workflow_test.rb:11-59`
- Modify: `.ansible-lint:1-9`
- Test: `tests/ci/workflow_test.rb`
- Test: `tests/configarr_job_test.rb`

- [ ] **Step 1: Write the failing lint-boundary regression**

Add the exact payload path beside `ANSIBLE_LINT_PATH`, then require it while rejecting directory-wide Arr exclusions:

```ruby
CONFIGARR_APPLICATION_YAML = "roles/arr/files/configarr/config.yml"
BROAD_ARR_LINT_EXCLUSIONS = %w[
  roles/arr/
  roles/arr/files/
  roles/arr/files/configarr/
].freeze
```

Immediately after the existing `services/` assertion, add:

```ruby
check(failures, ansible_lint_excludes.include?(CONFIGARR_APPLICATION_YAML),
      "ansible-lint must exclude only the Configarr application YAML with !secret tags")
check(failures, (ansible_lint_excludes & BROAD_ARR_LINT_EXCLUSIONS).empty?,
      "ansible-lint must not exclude an Arr directory: #{ansible_lint_excludes.inspect}")
```

- [ ] **Step 2: Run the workflow regression and confirm RED**

Run: `ruby tests/ci/workflow_test.rb`

Expected: FAIL with `ansible-lint must exclude only the Configarr application YAML with !secret tags`.

- [ ] **Step 3: Add the narrow Configarr exclusion**

Extend `.ansible-lint` without changing `skip_list`:

```yaml
exclude_paths:
  - services/
  # Configarr application YAML uses Configarr's !secret loader tag. Its exact
  # payload contract is validated by tests/configarr_job_test.rb.
  - roles/arr/files/configarr/config.yml
```

- [ ] **Step 4: Verify lint policy and the application payload contract**

Run: `ruby tests/ci/workflow_test.rb`

Expected: `CI workflow contract: all checks passed`.

Run: `ruby tests/configarr_job_test.rb`

Expected: `configarr job: synchronous declarative profile contract holds`.

Run: `../../.venv/bin/ansible-lint --strict`

Expected: exit 0 with no Configarr `!secret` load failure.

- [ ] **Step 5: Commit the lint fix**

```bash
git add .ansible-lint tests/ci/workflow_test.rb
git commit -m "fix: bound Configarr application linting"
```

### Task 2: Declare the exact integration-writer storage set

**Files:**
- Modify: `tests/media_acquisition_foundation_test.rb:157-188,473-490`
- Modify: `inventory/group_vars/all/main.yml:145-208`
- Test: `tests/media_acquisition_foundation_test.rb`

- [ ] **Step 1: Write the failing exact-writer-set regression**

Add the exact set beside `EXPECTED_STORAGE`:

```ruby
EXPECTED_INTEGRATION_WRITERS = Set[
  "{{ nas_media_root }}/Media/Movies",
  "{{ nas_media_root }}/Media/Series",
  "{{ nas_media_root }}/Media/.acquisition/usenet/movies",
  "{{ nas_media_root }}/Media/.acquisition/usenet/series",
  "{{ nas_media_root }}/Media/.acquisition/usenet/audiobooks",
  "{{ nas_media_root }}/Media/.acquisition/torrents/movies",
  "{{ nas_media_root }}/Media/.acquisition/torrents/series",
  "{{ nas_media_root }}/Media/.acquisition/torrents/audiobooks",
  "{{ nas_media_root }}/Books/.acquisition/usenet/ebooks",
  "{{ nas_media_root }}/Books/.acquisition/usenet/comics",
  "{{ nas_media_root }}/Books/.acquisition/torrents/ebooks",
  "{{ nas_media_root }}/Books/.acquisition/torrents/comics"
].freeze
```

After loading `acquisition_storage`, add:

```ruby
integration_writers = acquisition_storage.select do |entry|
  entry["media_acquisition_writer"] == true
end
actual_integration_writers = integration_writers.map { |entry| entry.fetch("path") }.to_set
failures << "media acquisition integration writers differ from the exact writable set" unless
  actual_integration_writers == EXPECTED_INTEGRATION_WRITERS
failures << "integration writer declarations must remain ownerless for production NAS storage" if
  integration_writers.any? { |entry| entry.key?("owner") || entry.key?("group") }
```

- [ ] **Step 2: Run the storage contract and confirm RED**

Run: `ruby tests/media_acquisition_foundation_test.rb`

Expected: FAIL with `media acquisition integration writers differ from the exact writable set`.

- [ ] **Step 3: Mark only the twelve writer directories**

Add `media_acquisition_writer: true` to the existing `nas_storage` mappings for exactly these paths, leaving every mapping free of `owner` and `group`:

```yaml
  - path: "{{ nas_media_root }}/Media/Movies"
    mode: "0755"
    recovery: user
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Media/Series"
    mode: "0755"
    recovery: user
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Media/.acquisition/usenet/movies"
    mode: "0755"
    recovery: cache
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Media/.acquisition/usenet/series"
    mode: "0755"
    recovery: cache
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Media/.acquisition/usenet/audiobooks"
    mode: "0755"
    recovery: cache
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Media/.acquisition/torrents/movies"
    mode: "0755"
    recovery: cache
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Media/.acquisition/torrents/series"
    mode: "0755"
    recovery: cache
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Media/.acquisition/torrents/audiobooks"
    mode: "0755"
    recovery: cache
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Books/.acquisition/usenet/ebooks"
    mode: "0755"
    recovery: cache
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Books/.acquisition/usenet/comics"
    mode: "0755"
    recovery: cache
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Books/.acquisition/torrents/ebooks"
    mode: "0755"
    recovery: cache
    media_acquisition_foundation: true
    media_acquisition_writer: true
  - path: "{{ nas_media_root }}/Books/.acquisition/torrents/comics"
    mode: "0755"
    recovery: cache
    media_acquisition_foundation: true
    media_acquisition_writer: true
```

Do not mark final libraries `Media/Audiobooks`, `Media/YouTube`, `Books`, `Books/Ebooks`, or `Books/Comics`.

- [ ] **Step 4: Verify the exact writer declaration**

Run: `ruby tests/media_acquisition_foundation_test.rb`

Expected: `media acquisition foundation: inert catalog and port policy hold`.

- [ ] **Step 5: Commit the writer inventory**

```bash
git add inventory/group_vars/all/main.yml tests/media_acquisition_foundation_test.rb
git commit -m "feat: declare integration media writers"
```

### Task 3: Scope and verify synthetic writer ownership in host preparation

**Files:**
- Modify: `tests/media_acquisition_foundation_test.rb:512-633`
- Modify: `roles/host_prep/meta/argument_specs.yml:8-53`
- Modify: `roles/host_prep/tasks/main.yml:72-139`
- Test: `tests/media_acquisition_foundation_test.rb`

- [ ] **Step 1: Write the failing host-prep boundary regression**

After the existing host-prep network checks, load the tasks named below and require all four activation guards, pre-mutation ordering, marker-only ownership, and numeric post-convergence verification:

```ruby
writer_mode = host_prep.find { |task| task["name"] == "Select synthetic integration writer ownership" }
writer_boundary = host_prep.find { |task| task["name"] == "Require the exact integration media sandbox" }
directory_task = host_prep.find { |task| task["name"] == "Create service state directories" }
writer_inspection = host_prep.find { |task| task["name"] == "Inspect synthetic integration writer directories" }
writer_assertion = host_prep.find { |task| task["name"] == "Require synthetic integration writer ownership" }

requested_expression = writer_mode&.dig(
  "ansible.builtin.set_fact", "host_prep_integration_writer_requested"
).to_s
enabled_expression = writer_mode&.dig(
  "ansible.builtin.set_fact", "host_prep_integration_writer_enabled"
).to_s
failures << "synthetic writer mode must require NAS integration test selection" unless
  requested_expression.include?("platform_kind == 'nas'") &&
    requested_expression.include?("platform_compose_kind == 'integration'") &&
    requested_expression.include?("deployment_bundle_test_mode | bool")
failures << "synthetic writer mode must require the exact six-character sandbox suffix" unless
  enabled_expression.include?("host_prep_integration_writer_requested | bool") &&
    enabled_expression.include?("nas-platform-integration[.][A-Za-z0-9]{6}/volume2$")
failures << "synthetic writer sandbox refusal must precede directory ownership changes" unless
  writer_boundary && directory_task && host_prep.index(writer_boundary) < host_prep.index(directory_task) &&
    writer_boundary["when"] == "host_prep_integration_writer_requested | bool" &&
    Array(writer_boundary.dig("ansible.builtin.assert", "that")).include?(
      "host_prep_integration_writer_enabled | bool"
    )

owner_expression = directory_task&.dig("ansible.builtin.file", "owner").to_s
group_expression = directory_task&.dig("ansible.builtin.file", "group").to_s
failures << "host preparation must claim only marked synthetic writer paths" unless
  owner_expression.include?("host_prep_integration_writer_enabled | bool") &&
    owner_expression.include?("item.media_acquisition_writer | default(false) | bool") &&
    owner_expression.include?("nas_uid") &&
    group_expression.include?("host_prep_integration_writer_enabled | bool") &&
    group_expression.include?("item.media_acquisition_writer | default(false) | bool") &&
    group_expression.include?("nas_gid")

writer_conditions = Array(writer_assertion&.dig("ansible.builtin.assert", "that"))
failures << "host preparation must verify synthetic writer identity and mode" unless
  writer_inspection&.dig("ansible.builtin.stat", "follow") == false &&
    writer_inspection&.fetch("when", nil) == "host_prep_integration_writer_enabled | bool" &&
    writer_assertion&.fetch("when", nil) == "host_prep_integration_writer_enabled | bool" &&
    %w[item.stat.exists item.stat.isdir].all? { |condition| writer_conditions.include?(condition) } &&
    writer_conditions.include?("not item.stat.islnk") &&
    writer_conditions.include?("item.stat.uid == (nas_uid | int)") &&
    writer_conditions.include?("item.stat.gid == (nas_gid | int)") &&
    writer_conditions.include?("item.stat.mode == item.item.mode")
```

Extend the argument-spec checks:

```ruby
failures << "host_prep must expose integration ownership inputs" unless
  host_prep_options["platform_compose_kind"] == { "type" => "str", "required" => true } &&
    host_prep_options["deployment_bundle_test_mode"] == { "type" => "bool", "default" => false } &&
    host_prep_options["nas_uid"] == { "type" => "raw", "required" => true } &&
    host_prep_options["nas_gid"] == { "type" => "raw", "required" => true }
failures << "host_prep must accept only a boolean writer marker" unless
  host_prep_options.dig("nas_storage", "options", "media_acquisition_writer") == {
    "type" => "bool", "required" => false
  }
```

- [ ] **Step 2: Run the host-prep contract and confirm RED**

Run: `ruby tests/media_acquisition_foundation_test.rb`

Expected: FAIL with the synthetic writer mode, ownership, verification, and argument-spec messages.

- [ ] **Step 3: Declare the host-prep inputs**

Add these options to `roles/host_prep/meta/argument_specs.yml` while retaining every existing option:

```yaml
      deployment_bundle_test_mode:
        type: bool
        default: false
      platform_compose_kind:
        type: str
        required: true
      nas_uid:
        type: raw
        required: true
      nas_gid:
        type: raw
        required: true
```

Add this child option under `nas_storage.options`:

```yaml
          media_acquisition_writer:
            type: bool
            required: false
            description: Marks a path writable only in the disposable integration sandbox.
```

- [ ] **Step 4: Derive and fail closed on the four-part integration boundary**

Insert this block after `Refuse to claim ownership of NAS-managed user files` and before any `ansible.builtin.file` task:

```yaml
- name: Select synthetic integration writer ownership
  ansible.builtin.set_fact:
    host_prep_integration_writer_requested: >-
      {{ platform_kind == 'nas' and
         platform_compose_kind == 'integration' and
         (deployment_bundle_test_mode | bool) }}
    host_prep_integration_writer_enabled: >-
      {{ (platform_kind == 'nas') and
         (platform_compose_kind == 'integration') and
         (deployment_bundle_test_mode | bool) and
         (nas_media_root is match('^.*/nas-platform-integration[.][A-Za-z0-9]{6}/volume2$')) }}
  changed_when: false

- name: Require the exact integration media sandbox
  ansible.builtin.assert:
    that:
      - host_prep_integration_writer_enabled | bool
    fail_msg: >-
      Refusing synthetic media writer ownership outside the exact disposable
      nas-platform-integration.XXXXXX/volume2 sandbox.
  when: host_prep_integration_writer_requested | bool
```

- [ ] **Step 5: Apply ownership only to marked integration writers**

Replace only the `owner` and `group` expressions in `Create service state directories`:

```yaml
    owner: >-
      {{ nas_uid
         if (host_prep_integration_writer_enabled | bool) and
            (item.media_acquisition_writer | default(false) | bool)
         else item.owner
         if (platform_kind == 'nas' or (platform_manage_linux_ownership | bool)) and item.owner is defined
         else omit }}
    group: >-
      {{ nas_gid
         if (host_prep_integration_writer_enabled | bool) and
            (item.media_acquisition_writer | default(false) | bool)
         else item.group
         if (platform_kind == 'nas' or (platform_manage_linux_ownership | bool)) and item.group is defined
         else omit }}
```

- [ ] **Step 6: Verify numeric writer ownership after convergence**

Append these tasks immediately after `Create service state directories`:

```yaml
- name: Inspect synthetic integration writer directories
  ansible.builtin.stat:
    path: "{{ item.path }}"
    follow: false
  loop: >-
    {{ nas_storage |
       selectattr('media_acquisition_writer', 'defined') |
       selectattr('media_acquisition_writer', 'equalto', true) |
       list }}
  loop_control:
    label: "{{ item.path }}"
  register: host_prep_integration_writer_stats
  changed_when: false
  when: host_prep_integration_writer_enabled | bool

- name: Require synthetic integration writer ownership
  ansible.builtin.assert:
    that:
      - item.stat.exists
      - item.stat.isdir
      - not item.stat.islnk
      - item.stat.uid == (nas_uid | int)
      - item.stat.gid == (nas_gid | int)
      - item.stat.mode == item.item.mode
    fail_msg: >-
      Synthetic integration writer path differs from the application identity:
      {{ item.item.path }}.
  loop: "{{ host_prep_integration_writer_stats.results }}"
  loop_control:
    label: "{{ item.item.path }}"
  changed_when: false
  when: host_prep_integration_writer_enabled | bool
```

- [ ] **Step 7: Verify the host-prep contract and syntax**

Run: `ruby tests/media_acquisition_foundation_test.rb`

Expected: `media acquisition foundation: inert catalog and port policy hold`.

Run: `../../.venv/bin/ansible-playbook site.yml --syntax-check`

Expected: exit 0 and `playbook: site.yml`.

- [ ] **Step 8: Commit the scoped ownership fix**

```bash
git add roles/host_prep/meta/argument_specs.yml roles/host_prep/tasks/main.yml tests/media_acquisition_foundation_test.rb
git commit -m "fix: prepare writable integration media paths"
```

### Task 4: Prove the PR is deployable and publish the repair

**Files:**
- Verify only: all files changed by Tasks 1-3

- [ ] **Step 1: Run the focused static regressions**

Run:

```bash
ruby tests/ci/workflow_test.rb
ruby tests/configarr_job_test.rb
ruby tests/media_acquisition_foundation_test.rb
../../.venv/bin/ansible-lint --strict
../../.venv/bin/ansible-playbook site.yml --syntax-check
```

Expected: every command exits 0; lint reports no Configarr loader failure.

- [ ] **Step 2: Reproduce the formerly failing live suites on Linux-capable Docker**

Run:

```bash
tests/integration.sh --suite arr site.yml
tests/integration.sh --suite downloaders site.yml
```

Expected: both suites exit 0; Radarr and Sonarr root-folder creation returns success, and downloader convergence completes.

- [ ] **Step 3: Check branch integrity and commit trailers**

Run:

```bash
git status --short
git log --format='%H%n%B%n---' origin/main..HEAD
```

Expected: the worktree is clean, intended commits are present, and no commit contains `Co-Authored-By`.

- [ ] **Step 4: Push the repair to PR #95**

Run: `git push origin feat/media-acquisition-phase-1`

Expected: the remote branch advances from `35b6b74` through the portability commits without force-pushing.

- [ ] **Step 5: Watch the authoritative GitHub checks**

Run: `gh pr checks 95 --watch --interval 15`

Expected: `static`, `arr`, `downloaders`, and aggregate `validate` change from their run `32881823852` failures to passing, with the remaining matrix lanes also green.
