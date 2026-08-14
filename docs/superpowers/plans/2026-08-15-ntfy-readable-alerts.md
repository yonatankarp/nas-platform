# Ntfy Readable Stateful Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace raw JSON notifications with readable Markdown alerts and emit recovery only for a container previously observed unhealthy.

**Architecture:** Add a small private alert relay to the Dozzle stack. Dozzle sends a versioned event envelope to it; the relay authenticates the request, tracks unhealthy container identities in an atomically replaced state file, and publishes ntfy's structured JSON format at the server root. Ntfy mobile account registration and Paperless recovery remain out of scope.

**Tech Stack:** Python 3.13 standard library, Docker Compose, Dozzle 10.7.1 webhooks, ntfy HTTP publish API, unittest, Ruby/POSIX contracts.

---

## File structure

- Create `services/dozzle/alert_relay.py`: authenticated event normalization, state transitions, Markdown rendering, and ntfy publishing.
- Create `tests/dozzle_alert_relay_test.py`: focused unit and HTTP tests.
- Modify `services/dozzle/compose.yml`: run the relay privately with hardened settings and persistent state.
- Modify `roles/dozzle/defaults/main.yml`: send the versioned event envelope to the relay.
- Modify `roles/dozzle/templates/env.j2`: render relay URL/topic/token inputs without logging secrets.
- Modify `roles/dozzle/tasks/main.yml`: prepare and verify relay state/runtime wiring.
- Modify `services/dozzle/compose.adoption.yml`: keep both services on the selected protected Dozzle state root.
- Modify `tests/contracts/dozzle.sh`, `tests/dozzle_quality_test.rb`, and `tests/integration.sh`: protect static, mutation, and real event behavior.
- Modify `tests/validate-policy.sh` and `tests/policy_test.rb`: register the relay unit suite exactly once.

### Task 1: Specify the relay as failing unit tests

**Files:**
- Create: `tests/dozzle_alert_relay_test.py`

- [ ] **Step 1: Test authentication and schema rejection**

Use temporary state and a local fake ntfy server. Require 401 for missing/wrong bearer tokens and 400 for unknown schema versions, missing identity fields, invalid event combinations, oversized fields, control characters, and unknown keys. Rejected input must neither publish nor change state.

- [ ] **Step 2: Test exact notification rendering**

Require structured JSON with these fields:

```json
{
  "topic": "nas-critical",
  "title": "Unhealthy · paperless_webserver",
  "message": "**Host:** `nas`\n**Container:** `paperless_webserver`\n**Status:** `unhealthy`",
  "priority": 5,
  "tags": ["rotating_light", "warning"],
  "markdown": true
}
```

Cover `Recovered · immich_server`, `Unexpected exit · service`, and `Out of memory · service`, including exit code where applicable. Assert the upstream request targets `/`, uses `Content-Type: application/json`, and carries the ntfy bearer token.

- [ ] **Step 3: Test transition semantics**

Prove:

```text
healthy with empty state -> 204, no publish
unhealthy -> publish and add (host, container-id)
repeat unhealthy -> publish, state remains one key
healthy after unhealthy -> publish recovery and remove key
repeat healthy -> no publish
unexpected exit or OOM -> always publish, state unchanged
```

Also prove state is atomically replaced with mode `0600`, corrupt/unsafe/symlink state fails closed, and an upstream failure does not commit the proposed transition.

- [ ] **Step 4: Run RED**

```bash
python3 -m unittest -v tests/dozzle_alert_relay_test.py
```

Expected: nonzero because `services/dozzle/alert_relay.py` does not exist.

- [ ] **Step 5: Commit tests**

```bash
git add tests/dozzle_alert_relay_test.py
git commit -m "test: specify readable stateful alerts"
```

### Task 2: Implement the standard-library relay

**Files:**
- Create: `services/dozzle/alert_relay.py`

- [ ] **Step 1: Implement strict configuration and request handling**

Read required values from `ALERT_RELAY_TOKEN`, `NTFY_PUBLISH_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`, and `ALERT_STATE_PATH`. Start `ThreadingHTTPServer` on `0.0.0.0:8081`; expose only `GET /healthz` and `POST /alerts`. Compare bearer tokens with `hmac.compare_digest`, cap bodies at 16 KiB, and use strict UTF-8 JSON decoding.

- [ ] **Step 2: Define the versioned envelope**

Accept exactly:

```json
{
  "version": 1,
  "rule": "Unhealthy",
  "containerId": "safe-docker-id",
  "container": "paperless_webserver",
  "host": "nas",
  "event": "health_status",
  "healthStatus": "unhealthy",
  "exitCode": "",
  "timestamp": "2026-08-15T01:22:13Z"
}
```

Normalize only the four approved rules. Escape Markdown metacharacters and limit displayed values before rendering.

- [ ] **Step 3: Implement safe state transitions**

Store versioned JSON containing sorted `host\0container-id` keys. Open the state directory without following symlinks, reject group/world-writable files or wrong ownership, lock across read/publish/replace, `fsync` the temporary file and directory, and replace only after ntfy returns 2xx.

- [ ] **Step 4: Run unit GREEN**

```bash
python3 -m unittest -v tests/dozzle_alert_relay_test.py
```

- [ ] **Step 5: Commit relay implementation**

```bash
git add services/dozzle/alert_relay.py
git commit -m "feat: add stateful ntfy alert relay"
```

### Task 3: Harden and wire the relay container

**Files:**
- Modify: `services/dozzle/compose.yml`
- Modify: `roles/dozzle/templates/env.j2`
- Modify: `roles/dozzle/tasks/main.yml`
- Modify: `services/dozzle/compose.adoption.yml`
- Modify: `tests/contracts/dozzle.sh`

- [ ] **Step 1: Extend the static contract first**

Require exactly `alert-relay`, `dozzle`, and `socket-proxy`. Require the relay to use pinned multi-architecture `python:3.13-alpine`, NAS UID/GID, no published port, no Docker socket, read-only root, `/tmp` tmpfs, `no-new-privileges`, a health check, the tracked script mounted read-only, and only its state directory writable.

- [ ] **Step 2: Reuse protected Dozzle state storage**

Keep state in the already declared critical Dozzle data root. Update the role to include the tracked relay script in deployment target validation, validate `dozzle_state_root`, and render that selected normal/adoption root into the protected environment as `DOZZLE_STATE_ROOT`.

- [ ] **Step 3: Add the service**

Mount:

```yaml
- ${PLATFORM_CURRENT_DIR:?}/services/dozzle/alert_relay.py:/app/alert_relay.py:ro
- ${DOZZLE_STATE_ROOT:?}:/state
```

Run `python /app/alert_relay.py` with `ALERT_STATE_PATH=/state/alert-relay.json`; pass only required environment variables; add a loopback `/healthz` probe. Make Dozzle depend on relay health as well as socket-proxy health. Update `compose.adoption.yml` so both Dozzle and the relay mount the same selected legacy state root.

- [ ] **Step 4: Render runtime inputs safely**

Add `PLATFORM_CURRENT_DIR`, relay token, ntfy root publish URL, topic, and ntfy token to the protected `.env`. Keep template and task output `no_log: true`; never place tokens in Compose labels or command arguments.

- [ ] **Step 5: Run static GREEN and commit**

```bash
PATH="$PWD/.venv/bin:$PATH" tests/contracts/dozzle.sh static
PATH="$PWD/.venv/bin:$PATH" ansible-playbook -i inventory/hosts.yml site.yml --syntax-check
```

```bash
git add services/dozzle/compose.yml services/dozzle/compose.adoption.yml roles/dozzle/templates/env.j2 roles/dozzle/tasks/main.yml tests/contracts/dozzle.sh
git commit -m "feat: deploy hardened alert relay"
```

### Task 4: Send meaningful events and prove recovery correlation

**Files:**
- Modify: `roles/dozzle/defaults/main.yml`
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/dozzle_quality_test.rb`
- Modify: `tests/integration.sh`
- Modify: `tests/validate-policy.sh`
- Modify: `tests/policy_test.rb`

- [ ] **Step 1: Point the dispatcher at the private relay**

Set the webhook URL to `http://alert-relay:8081/alerts`. Keep the existing authorization header and render the exact version-1 keys from supported Dozzle template fields. Do not put ntfy's topic/title/message wrapper in the Dozzle template; the relay owns presentation.

- [ ] **Step 2: Mutation-protect the transport**

Reject direct topic-path publishing, direct ntfy root publishing from Dozzle, missing relay authorization, missing version/identity/status fields, an externally published relay port, writable root, and Docker socket access.

- [ ] **Step 3: Replace the notify integration scenario**

Use the real Dozzle/relay/ntfy chain to prove:

1. a disposable container becomes unhealthy and produces readable structured JSON;
2. its later healthy event produces one recovery;
3. an unrelated startup healthy event produces nothing;
4. a nonzero disposable exit produces `Unexpected exit` with exit code;
5. no received ntfy body displays the JSON envelope as message text.

- [ ] **Step 4: Run the focused and integration suite**

Register `python3 -m unittest -v tests/dozzle_alert_relay_test.py` exactly once in `tests/validate-policy.sh` and protect that registration in `tests/policy_test.rb`, then run:

```bash
python3 -m unittest -v tests/dozzle_alert_relay_test.py
PATH="$PWD/.venv/bin:$PATH" tests/contracts/dozzle.sh static
PATH="$PWD/.venv/bin:$PATH" tests/integration.sh --suite dozzle
PATH="$PWD/.venv/bin:$PATH" tests/validate-policy.sh
git diff --check
```

Expected: all exit 0 and the captured ntfy payloads have Markdown enabled with human-readable titles.

- [ ] **Step 5: Commit completed proof**

```bash
git add roles/dozzle/defaults/main.yml tests/contracts/dozzle.sh tests/dozzle_quality_test.rb tests/integration.sh tests/validate-policy.sh tests/policy_test.rb
git commit -m "test: prove readable correlated ntfy alerts"
```
