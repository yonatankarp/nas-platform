# Komga Health Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Compose and Ansible consider Komga ready only when its own health actuator reports `UP`.

**Architecture:** Add a container-local health check using the `curl` binary already present in pinned Komga 1.26.1. Keep Compose's process health as the first gate, then add an explicit Ansible API assertion before any claim or reconciliation request.

**Tech Stack:** Docker Compose, Komga 1.26.1 Spring actuator API, Ansible `uri`, Ruby/POSIX contract tests.

---

## File structure

- Modify `services/komga/compose.yml`: add the container health check.
- Modify `roles/komga/defaults/main.yml`: define readiness timing.
- Modify `roles/komga/tasks/main.yml`: wait for exact API readiness before claim handling.
- Modify `tests/contracts/komga.sh`: enforce static and runtime health behavior.

### Task 1: Write the failing health contract

**Files:**
- Modify: `tests/contracts/komga.sh`

- [ ] **Step 1: Require the effective health check**

Assert that `services.komga.healthcheck` exists, calls only loopback port 25600, checks `/actuator/health`, requires the JSON status to be `UP`, and has finite interval, timeout, retries, and start period values.

- [ ] **Step 2: Require readiness before claim handling**

Parse `roles/komga/tasks/main.yml` and require an `ansible.builtin.uri` GET of `{{ komga_api }}/actuator/health` after Compose deployment and before `Read Komga claim status`. Require `status_code: [200]`, `return_content: true`, a finite `until`, and `changed_when: false`.

- [ ] **Step 3: Extend live verification**

In verify mode, require Docker health `healthy`, then fetch `/actuator/health` and require exact JSON `status == "UP"` before authenticated library assertions.

- [ ] **Step 4: Run RED and commit it**

```bash
PATH="$PWD/.venv/bin:$PATH" tests/contracts/komga.sh static
```

Expected: nonzero because the Compose service has no health check.

```bash
git add tests/contracts/komga.sh
git commit -m "test: require Komga application health"
```

### Task 2: Implement both readiness gates

**Files:**
- Modify: `services/komga/compose.yml`
- Modify: `roles/komga/defaults/main.yml`
- Modify: `roles/komga/tasks/main.yml`

- [ ] **Step 1: Add the container-local probe**

Add:

```yaml
healthcheck:
  test:
    - CMD-SHELL
    - >-
      curl --fail --silent --show-error http://127.0.0.1:25600/actuator/health |
      grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"'
  interval: 30s
  timeout: 10s
  retries: 5
  start_period: 60s
```

- [ ] **Step 2: Add role timing defaults**

```yaml
komga_health_retries: 60
komga_health_delay: 3
```

- [ ] **Step 3: Add exact API readiness**

Immediately after Compose deployment and before claim status:

```yaml
- name: Wait for Komga application health
  ansible.builtin.uri:
    url: "{{ komga_api }}/actuator/health"
    method: GET
    status_code: [200]
    return_content: true
  register: komga_health
  until:
    - komga_health.json is mapping
    - komga_health.json.status | default('') == 'UP'
  retries: "{{ komga_health_retries }}"
  delay: "{{ komga_health_delay }}"
  changed_when: false
  check_mode: false
```

- [ ] **Step 4: Run focused GREEN checks**

```bash
PATH="$PWD/.venv/bin:$PATH" tests/contracts/komga.sh static
PATH="$PWD/.venv/bin:$PATH" ansible-playbook -i inventory/hosts.yml site.yml --syntax-check
```

Expected: both exit 0.

- [ ] **Step 5: Commit implementation**

```bash
git add services/komga/compose.yml roles/komga/defaults/main.yml roles/komga/tasks/main.yml
git commit -m "fix: add Komga application health check"
```

### Task 3: Verify runtime behavior

- [ ] **Step 1: Run the media integration lane**

```bash
PATH="$PWD/.venv/bin:$PATH" tests/integration.sh --suite media
```

Expected: Komga reaches Docker `healthy`, the actuator returns `UP`, and claim/library reconciliation still passes.

- [ ] **Step 2: Run policy and formatting checks**

```bash
PATH="$PWD/.venv/bin:$PATH" tests/validate-policy.sh
git diff --check
```

- [ ] **Step 3: Commit any runtime-contract adjustment**

```bash
git add tests/contracts/komga.sh tests/integration.sh
git commit -m "test: prove Komga health gating"
```
