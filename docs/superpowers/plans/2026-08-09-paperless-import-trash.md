# Paperless Portable Import Trash Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Paperless portable-export contract hard-delete its exported fixtures before importing them back, so Paperless 3.0.5 does not encounter occupied media paths.

**Architecture:** Keep the existing API-driven mutation, then use Paperless's authenticated trash API to hard-delete exactly the three exported document IDs before invoking `document_importer`. Protect the sequencing with the repository policy test and retain the existing post-deletion API polling.

**Tech Stack:** Ruby contract harness, Paperless-ngx REST API, repository policy tests

---

### Task 1: Require hard deletion before portable import

**Files:**
- Modify: `tests/policy_test.rb`
- Modify: `tests/contracts/paperless.sh`

- [ ] **Step 1: Write the failing policy assertion**

Add a policy check requiring `tests/contracts/paperless.sh` to collect the exported document IDs, soft-delete them, call `POST /api/trash/` with `action: empty` for those IDs, and only then invoke `document_importer`.

```ruby
check(failures,
      paperless_contract.match?(%r{
        document_ids\s*=\s*\[.*?
        request\(\s*"post",\s*"/api/trash/".*?
        "action"\s*=>\s*"empty".*?
        "documents"\s*=>\s*document_ids.*?
        document_importer
      }mx),
      "Paperless portable import must empty its exported fixtures from trash first")
```

- [ ] **Step 2: Run the policy test and verify RED**

Run: `ruby tests/policy_test.rb`

Expected: exit 1 with `Paperless portable import must empty its exported fixtures from trash first`.

- [ ] **Step 3: Hard-delete only the exported fixtures**

Replace the inline deletion iteration with an ID list, preserve the existing per-document `DELETE` calls, and synchronously empty those IDs from trash before the importer runs.

```ruby
document_ids = [pdf_document, image_document, office_document].map { |document| document.fetch("id") }
document_ids.each do |document_id|
  request("delete", "/api/documents/#{document_id}/", token: token, expected: [204])
end
request(
  "post", "/api/trash/", token: token,
  body: { "action" => "empty", "documents" => document_ids }, expected: [200]
)
```

- [ ] **Step 4: Run focused verification and verify GREEN**

Run: `ruby tests/policy_test.rb && tests/contracts/paperless.sh static`

Expected: exit 0 with `policy: all properties hold` and `Paperless static contract passed`.

- [ ] **Step 5: Run repository verification**

Run the workflow's local syntax, policy, lint, and playbook-syntax checks available from the repository, then inspect `git diff --check` and the final diff.

- [ ] **Step 6: Commit and push**

Commit the focused regression and fix without a `Co-Authored-By` trailer, push `agent/task-13-paperless`, and monitor the resulting PR #3 CI run to completion.

### Task 2: Reload the webserver after the importer rebuilds Tantivy

**Files:**
- Modify: `tests/policy_test.rb`
- Modify: `tests/contracts/paperless.sh`

- [ ] **Step 1: Write the failing sequencing assertion**

Require the contract to restart the Paperless webserver after `document_importer`, wait for the container healthcheck, and only then query the restored fixtures through search.

- [ ] **Step 2: Run the policy test and verify RED**

Run: `ruby tests/policy_test.rb`

Expected: exit 1 with `Paperless portable import must reload and health-check the webserver search index`.

- [ ] **Step 3: Restart and health-check the webserver**

Add a bounded Docker health polling helper. After the importer succeeds, restart only `WEBSERVER`, wait until its Docker health status is `healthy`, and then continue with the existing search and checksum assertions.

- [ ] **Step 4: Run focused and repository verification**

Run: `ruby tests/policy_test.rb && tests/contracts/paperless.sh static`, followed by the workflow's shell syntax, lint, and playbook syntax checks.

- [ ] **Step 5: Commit, push, and monitor**

Commit without a `Co-Authored-By` trailer, push `agent/task-13-paperless`, and monitor PR #3 CI to completion.

### Task 3: Read recovery catalogue checksums from API v3 versions

**Files:**
- Modify: `tests/policy_test.rb`
- Modify: `tests/mac/snapshot-paperless.sh`

- [x] **Step 1: Write the failing snapshot policy assertion**

Require the snapshot catalogue to derive checksums from the root entry in each document's `versions` array.

- [x] **Step 2: Run the policy test and verify RED**

Run: `ruby tests/policy_test.rb`

Expected: exit 1 with `Paperless snapshot catalogue must use API v3 root-version checksums`.

- [x] **Step 3: Add root-version checksum extraction**

Add `document_checksum(document)` to the snapshot Ruby program, fail closed when the root checksum is absent, and use it from `catalogue`.

- [x] **Step 4: Run focused and repository verification**

Run the Paperless static contract, snapshot self-test, shell syntax, policy, Ansible lint, and playbook syntax checks.

- [ ] **Step 5: Commit, push, and monitor**

Commit without a `Co-Authored-By` trailer, push `agent/task-13-paperless`, and monitor PR #3 CI to completion.

### Task 4: Include the Paperless snapshot in policy mutation fixtures

**Files:**
- Modify: `tests/policy_manifest_test.rb`

- [x] **Step 1: Reproduce the isolated-fixture failure**

Run `ruby tests/policy_manifest_test.rb` and confirm its mutation sandboxes fail because `tests/mac/snapshot-paperless.sh` is absent.

- [x] **Step 2: Copy the snapshot into every mutation fixture**

Add the snapshot script to `BASE_FIXTURE_PATHS` so the policy can inspect it in isolated test repositories.

- [ ] **Step 3: Validate, commit, push, and monitor**

Run the full policy entrypoint and portable validation suite, commit without a `Co-Authored-By` trailer, push, and monitor PR #3 CI.
