# Audiobookshelf Initial Scan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a clean deployment populate the managed Audiobookshelf library before convergence succeeds, without repeatedly scanning an unchanged existing library.

**Architecture:** Treat library creation and folder-binding repair as the events that require a scan. The role will start one scan, poll the supported task and library-item APIs with bounded diagnostics, and accept a genuinely empty source. The integration contract will place its fixture before deployment and stop starting scans itself.

**Tech Stack:** Ansible Core, Audiobookshelf 2.36.0 HTTP API, Ruby/POSIX contract tests, Docker Compose integration harness.

---

## File structure

- Modify `roles/audiobookshelf/defaults/main.yml`: define bounded scan timing.
- Modify `roles/audiobookshelf/tasks/main.yml`: classify folder-binding changes, trigger the initial scan, and wait for completion.
- Modify `tests/contracts/audiobookshelf.sh`: require role-owned scanning and remove test-owned rescans.
- Create `tests/audiobookshelf_initial_scan_test.rb`: mutation-protect scan ordering and guards.
- Modify `tests/validate-policy.sh` and `tests/policy_test.rb`: register and mutation-protect the focused test.

### Task 1: Capture the missing role-owned scan

**Files:**
- Modify: `tests/contracts/audiobookshelf.sh`
- Create: `tests/audiobookshelf_initial_scan_test.rb`

- [ ] **Step 1: Require the deployment role to own initial discovery**

In static mode, require one `POST` task whose URL is exactly:

```yaml
url: "{{ audiobookshelf_api }}/api/libraries/{{ audiobookshelf_current_library.id }}/scan"
method: POST
status_code: [200]
```

Require it to run only when the library was created or its folder paths changed, and require the scan task to appear after create/repair but before the `platform_verify_audiobookshelf` section.

- [ ] **Step 2: Make the runtime fixture exist before convergence**

Move `seed_fixture` into the integration setup that runs before the Audiobookshelf role. Delete both direct calls to:

```ruby
request("post", "/api/libraries/#{library_id}/scan", token: token, expected: [200])
```

Keep the bounded item polling and playback verification. The fixture must only become visible if the role scans it.

- [ ] **Step 3: Add mutation probes**

Add temporary-copy mutations proving static mode rejects a missing scan, an unconditional scan, a scan before library reconciliation, and a polling loop without a finite retry count.

- [ ] **Step 4: Run RED**

```bash
PATH="$PWD/.venv/bin:$PATH" tests/contracts/audiobookshelf.sh static
PATH="$PWD/.venv/bin:$PATH" ruby tests/audiobookshelf_initial_scan_test.rb
```

Expected: nonzero because the role has no scan task yet.

- [ ] **Step 5: Commit the failing contract**

```bash
git add tests/contracts/audiobookshelf.sh tests/audiobookshelf_initial_scan_test.rb
git commit -m "test: require Audiobookshelf initial scan"
```

### Task 2: Trigger and bound the initial scan

**Files:**
- Modify: `roles/audiobookshelf/defaults/main.yml`
- Modify: `roles/audiobookshelf/tasks/main.yml`

- [ ] **Step 1: Add scan timing defaults**

```yaml
audiobookshelf_initial_scan_retries: 60
audiobookshelf_initial_scan_delay: 2
```

- [ ] **Step 2: Separate folder repair from other library drift**

Resolve a boolean before the PATCH:

```yaml
audiobookshelf_library_folder_repair_required: >-
  {{ audiobookshelf_existing_library | length > 0 and
     audiobookshelf_existing_library_paths !=
       (audiobookshelf_library_folders | map(attribute='path') | list) }}
audiobookshelf_initial_scan_required: >-
  {{ audiobookshelf_library_create_required | bool or
     audiobookshelf_library_folder_repair_required | bool }}
```

Preserve the existing full repair decision for media type, provider, icon, and settings.

- [ ] **Step 3: Start exactly one scan**

After create/repair, POST to the current safe library ID with the reconcile token. Mark the task changed and redact the authorization header with `no_log: true`.

- [ ] **Step 4: Wait for terminal scan state**

Poll `GET /api/tasks` until no task for the managed library reports a running/pending scan state, using the timing defaults. Then read `GET /api/libraries/{id}/items?limit=1&minified=1` and require a supported response shape. Do not require a nonzero result: an empty source is valid. On timeout, report only library ID, sanitized task names/statuses, and elapsed retry count.

- [ ] **Step 5: Preserve check mode**

Emit `AUDIOBOOKSHELF_PLAN_INITIAL_SCAN` when check mode predicts create or folder repair. Make no API mutation in check mode.

- [ ] **Step 6: Run focused GREEN checks**

```bash
PATH="$PWD/.venv/bin:$PATH" tests/contracts/audiobookshelf.sh static
PATH="$PWD/.venv/bin:$PATH" ruby tests/audiobookshelf_initial_scan_test.rb
PATH="$PWD/.venv/bin:$PATH" ansible-playbook -i inventory/hosts.yml site.yml --syntax-check
```

Expected: all exit 0.

- [ ] **Step 7: Commit the role change**

```bash
git add roles/audiobookshelf/defaults/main.yml roles/audiobookshelf/tasks/main.yml
git commit -m "fix: scan new Audiobookshelf libraries"
```

### Task 3: Prove clean deployment and idempotence

**Files:**
- Modify: `tests/contracts/audiobookshelf.sh`
- Modify: `tests/integration.sh` only if fixture staging needs suite-level wiring.
- Modify: `tests/validate-policy.sh`
- Modify: `tests/policy_test.rb`

- [ ] **Step 1: Run the clean deployment proof**

```bash
PATH="$PWD/.venv/bin:$PATH" tests/integration.sh --suite audiobookshelf
```

Expected: the pre-existing audio fixture is indexed and byte/range playback matches without any contract-triggered scan.

- [ ] **Step 2: Prove the second convergence does not scan**

Record the server task history before a second role run, converge again, and require no new library scan plus zero Ansible changes.

- [ ] **Step 3: Run repository policy checks**

Register `ruby tests/audiobookshelf_initial_scan_test.rb` exactly once in `tests/validate-policy.sh` and protect that registration in `tests/policy_test.rb`, then run:

```bash
PATH="$PWD/.venv/bin:$PATH" tests/validate-policy.sh
git diff --check
```

- [ ] **Step 4: Commit the completed behavioral proof**

```bash
git add tests/contracts/audiobookshelf.sh tests/integration.sh tests/audiobookshelf_initial_scan_test.rb tests/validate-policy.sh tests/policy_test.rb
git commit -m "test: prove Audiobookshelf clean deployment discovery"
```
