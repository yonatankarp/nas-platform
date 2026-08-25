# NAS Controller Requests Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a newly merged revision repair the NAS controller virtual environment with the `requests` dependency before Ansible preflight runs.

**Architecture:** Keep `controller-requirements.txt` as the single Python dependency input consumed by the production poller's existing pre-Ansible tooling synchronization. Pin `requests` there at the integration-tested version, teach Renovate to track the controller occurrence, and enforce both pins with repository policy tests.

**Tech Stack:** Python virtual environments and pip, Ruby policy tests, Renovate regex managers, Ansible preflight, GitHub Actions.

---

### Task 1: Reproduce the split controller and integration dependency pins

**Files:**
- Modify: `tests/renovate_policy_test.rb`
- Test: `tests/renovate_policy_test.rb`

- [ ] **Step 1: Add a failing pin-parity and controller-manager regression**

After the existing integration-harness custom-manager assertions, add:

```ruby
controller_requirements_path = File.join(ROOT, "controller-requirements.txt")
controller_lines = File.readlines(controller_requirements_path, chomp: true)
controller_requests_pins = controller_lines.filter_map do |line|
  line.match(/\Arequests==(?<version>\d+\.\d+\.\d+)\z/)&.[](:version)
end
integration_requests_match = File.read(HARNESS_PATH).match(
  /^requests_version=(?<version>\d+\.\d+\.\d+)$/
)

check(failures, controller_requests_pins.length == 1,
      "controller-requirements.txt must contain exactly one requests pin")
check(failures, !integration_requests_match.nil?,
      "tests/integration.sh must contain exactly one requests_version pin")
check(failures,
      controller_requests_pins.first == integration_requests_match&.[](:version),
      "controller and integration requests pins must match")

controller_managers = Array(config["customManagers"]).select do |manager|
  Array(manager["managerFilePatterns"]).any? do |pattern|
    body = pattern.sub(%r{\A/}, "").sub(%r{/\z}, "")
    Regexp.new(body).match?("controller-requirements.txt")
  end
end
controller_match_strings = controller_managers
                           .flat_map { |manager| Array(manager["matchStrings"]) }
                           .map { |source| Regexp.new(source) }
controller_lines.grep(/\A[a-z][a-z0-9-]*==\d+\.\d+\.\d+\z/).each do |line|
  check(failures, controller_match_strings.any? { |pattern| pattern.match?(line) },
        "no Renovate custom manager tracks the controller pin #{line.inspect}")
end
```

- [ ] **Step 2: Run the regression and verify the missing dependency is detected**

Run:

```bash
ruby tests/renovate_policy_test.rb
```

Expected: FAIL, including `controller-requirements.txt must contain exactly one requests pin` and `controller and integration requests pins must match`.

- [ ] **Step 3: Commit the independently useful failing regression**

```bash
git add -- tests/renovate_policy_test.rb
git commit -m "test: require NAS controller requests pin"
```

### Task 2: Bootstrap requests through the candidate requirements

**Files:**
- Modify: `controller-requirements.txt`
- Modify: `renovate.json`
- Test: `tests/renovate_policy_test.rb`

- [ ] **Step 1: Add the integration-tested requests pin to the controller input**

Make `controller-requirements.txt` contain:

```text
ansible-core==2.21.3
ansible-lint==26.8.0
requests==2.34.2
```

- [ ] **Step 2: Extend the controller requirements Renovate manager**

In the custom manager whose `managerFilePatterns` is
`/^controller-requirements\\.txt$/`, update its description and match expression
to cover all three controller dependencies:

```json
{
  "description": "Python tooling pinned in controller-requirements.txt, which the operator guide and production poller install from.",
  "customType": "regex",
  "managerFilePatterns": [
    "/^controller-requirements\\.txt$/"
  ],
  "matchStrings": [
    "(?<depName>ansible-core|ansible-lint|requests)==(?<currentValue>[0-9]+\\.[0-9]+\\.[0-9]+)"
  ],
  "datasourceTemplate": "pypi"
}
```

- [ ] **Step 3: Run the focused regression and verify it passes**

Run:

```bash
ruby tests/renovate_policy_test.rb
```

Expected: PASS with `renovate policy: all checks passed`.

- [ ] **Step 4: Prove the production poller retains pre-Ansible tooling order**

Run:

```bash
python3 tests/production_auto_deploy_test.py
tests/target_docker_dependency_preflight_test.sh
```

Expected: the Python test suite reports `OK`; the shell test reports
`target Docker dependency preflight: missing requests refuses before mutation`.

- [ ] **Step 5: Commit the bootstrap fix**

```bash
git add -- controller-requirements.txt renovate.json
git commit -m "fix: bootstrap requests in NAS controller"
```

### Task 3: Verify and publish the deployable PR revision

**Files:**
- Verify: `controller-requirements.txt`
- Verify: `renovate.json`
- Verify: `tests/renovate_policy_test.rb`

- [ ] **Step 1: Run repository-wide policy validation**

```bash
tests/validate-policy.sh
```

Expected: exit 0 with `policy validation: all 90 checks passed`.

- [ ] **Step 2: Run Ansible syntax validation**

```bash
ansible-playbook --syntax-check site.yml
ansible-playbook --syntax-check verify.yml
```

Expected: both commands exit 0 and identify their playbook.

- [ ] **Step 3: Audit the final branch**

```bash
git diff --check origin/main...HEAD
git status --short
git log --format='%B' origin/main..HEAD | rg -i '^Co-Authored-By:' && exit 1 || true
```

Expected: no diff errors, an empty status, and no `Co-Authored-By` trailers.

- [ ] **Step 4: Push the updated PR branch**

```bash
git push origin feat/media-acquisition-phase-1
```

Expected: GitHub updates PR #95 to the local HEAD.

- [ ] **Step 5: Monitor PR checks to completion**

```bash
gh pr checks 95 --watch --interval 30
```

Expected: every required GitHub check completes successfully. Do not merge the
PR as part of this plan.
