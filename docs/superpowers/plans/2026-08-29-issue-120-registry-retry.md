# Issue 120 Registry Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make integration image pre-pulls honor registry retry hints while using a wider, jittered, bounded exponential retry policy.

**Architecture:** Keep the existing serial pre-pull seam and enrich `pull_image` with three focused helpers: validated retry settings, parsing of Docker's `retry-after` duration, and random jitter. Drive the production shell path through deterministic `docker`, `sleep`, and `od` stubs so the policy is tested without real delays or registry access.

**Tech Stack:** POSIX shell, Docker CLI, Ruby-backed repository policy tests, GitHub Actions.

---

### Task 1: Specify server-aware delay behavior with deterministic shell fixtures

**Files:**
- Modify: `tests/integration_suite_test.sh`
- Test: `tests/integration_suite_test.sh`

- [ ] **Step 1: Extend the pre-pull fixture to observe delays and control jitter**

Beside `pull_log`, declare `sleep_log=$prepull_bin/sleep.log`. Extend `cleanup` to remove
`$prepull_bin/docker`, `$prepull_bin/sleep`, `$prepull_bin/od`, `$pull_log`, and
`$sleep_log` before removing `$prepull_bin`.

Change the failing `docker pull` diagnostic to use a test-controlled duration:

```sh
printf 'toomanyrequests: retry-after: %s, allowed: 44000/minute\n' \
  "${STUB_RETRY_AFTER:-218.093us}" >&2
```

Create executable `sleep` and `od` stubs after the Docker stub:

```sh
cat > "$prepull_bin/sleep" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "${1:?}" >> "${STUB_SLEEP_LOG:?}"
EOF

cat > "$prepull_bin/od" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "${STUB_RANDOM_VALUE:-0}"
EOF

chmod +x "$prepull_bin/docker" "$prepull_bin/sleep" "$prepull_bin/od"
```

- [ ] **Step 2: Make `run_prepull` pass deterministic policy inputs**

Reset both logs on every run. Pass `STUB_SLEEP_LOG`, `STUB_RETRY_AFTER`, and
`STUB_RANDOM_VALUE` from optional `PREPULL_*` controls, while retaining the
existing attempt and initial-delay arguments:

```sh
: > "$pull_log"
: > "$sleep_log"
prepull_status=0
PATH="$prepull_bin:$PATH" \
  STUB_PULL_LOG=$pull_log \
  STUB_SLEEP_LOG=$sleep_log \
  STUB_PULL_REFUSALS=$prepull_refusals \
  STUB_RETRY_AFTER=${PREPULL_RETRY_AFTER:-218.093us} \
  STUB_RANDOM_VALUE=${PREPULL_RANDOM_VALUE:-0} \
  INTEGRATION_PREPULL_ONLY=1 \
  INTEGRATION_IMAGE_PULL_ATTEMPTS=$prepull_attempts \
  INTEGRATION_IMAGE_PULL_DELAY=${PREPULL_DELAY:-1} \
  INTEGRATION_IMAGE_PULL_MAX_DELAY=${PREPULL_MAX_DELAY:-60} \
  "$integration" "$@" >/dev/null 2>&1 || prepull_status=$?
```

Add this helper beside `assert_pull_count`:

```sh
assert_sleep_log() {
  expected=$1
  actual=$(cat "$sleep_log")
  [ "$expected" = "$actual" ] ||
    prepull_fail "expected sleeps [$expected], saw [$actual]"
}
```

- [ ] **Step 3: Add failing behavior assertions**

After the immediate-success foundation case, require no sleep. Then add isolated
foundation cases with resets after each one:

```sh
run_prepull 0 6 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "an answering registry failed"
assert_sleep_log ""

PREPULL_RETRY_AFTER=584.244µs PREPULL_RANDOM_VALUE=0 PREPULL_DELAY=5 \
  run_prepull 2 6 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "microsecond retry hint failed"
assert_sleep_log "6
11"
unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY

PREPULL_RETRY_AFTER=45s PREPULL_RANDOM_VALUE=3 PREPULL_DELAY=5 \
  run_prepull 1 6 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "long retry hint failed"
assert_sleep_log "49"
unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY

PREPULL_RETRY_AFTER=invalid PREPULL_RANDOM_VALUE=0 PREPULL_DELAY=10 \
  PREPULL_MAX_DELAY=40 run_prepull 5 6 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "widened retry budget failed"
assert_sleep_log "11
21
41
41
41"
unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY PREPULL_MAX_DELAY

run_prepull 5 malformed --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "malformed attempt budget removed the safe default"
assert_pull_count "$runner_image" 6
```

Keep the existing exhausted-budget and zero-attempt-floor cases. The malformed
attempt case above proves the safe default is six rather than four.

- [ ] **Step 4: Run the focused test and confirm the new contract fails**

Run:

```bash
tests/integration_suite_test.sh
```

Expected: FAIL because the current production script does not emit the expected
jittered delays, does not honor the 45-second hint, caps the default at four
attempts, and has no maximum-delay setting.

- [ ] **Step 5: Commit the independently useful failing regression**

```bash
git add -- tests/integration_suite_test.sh
git commit -m "test: specify registry-aware image pull retries"
```

### Task 2: Implement bounded exponential retry, registry hints, and jitter

**Files:**
- Modify: `tests/integration.sh`
- Test: `tests/integration_suite_test.sh`

- [ ] **Step 1: Widen and validate the retry settings**

Change the default attempt count to six. Keep the current five-second initial
delay and add a sixty-second maximum local delay:

```sh
image_pull_attempts=${INTEGRATION_IMAGE_PULL_ATTEMPTS:-6}
case $image_pull_attempts in
  ''|*[!0123456789]*) image_pull_attempts=6 ;;
esac
[ "$image_pull_attempts" -ge 2 ] || image_pull_attempts=2

image_pull_delay=${INTEGRATION_IMAGE_PULL_DELAY:-5}
case $image_pull_delay in
  ''|*[!0123456789]*) image_pull_delay=5 ;;
esac
[ "$image_pull_delay" -ge 1 ] || image_pull_delay=1

image_pull_max_delay=${INTEGRATION_IMAGE_PULL_MAX_DELAY:-60}
case $image_pull_max_delay in
  ''|*[!0123456789]*) image_pull_max_delay=60 ;;
esac
[ "$image_pull_max_delay" -ge "$image_pull_delay" ] ||
  image_pull_max_delay=$image_pull_delay
```

- [ ] **Step 2: Add the duration parser and jitter helper**

Add `retry_after_seconds`, which finds the first `retry-after:` token, accepts a
plain number as seconds or the suffixes `ns`, `us`, `µs`, `ms`, `s`, and `m`,
converts the value to seconds, rounds any positive fraction up to one whole
second, prints the integer result, and prints nothing for malformed input:

```sh
retry_after_seconds() {
  awk '
    {
      marker = "retry-after:"
      marker_at = index($0, marker)
      if (!marker_at) next
      token = substr($0, marker_at + length(marker))
      sub(/^[[:space:]]*/, "", token)
      sub(/[,[:space:]].*$/, "", token)

      unit = ""
      if (token ~ /ns$/) unit = "ns"
      else if (token ~ /us$/) unit = "us"
      else if (token ~ /µs$/) unit = "µs"
      else if (token ~ /ms$/) unit = "ms"
      else if (token ~ /s$/) unit = "s"
      else if (token ~ /m$/) unit = "m"

      value = unit == "" ? token : substr(token, 1, length(token) - length(unit))
      if (value !~ /^[0-9]+([.][0-9]+)?$/) next

      seconds = value + 0
      if (unit == "ns") seconds /= 1000000000
      else if (unit == "us" || unit == "µs") seconds /= 1000000
      else if (unit == "ms") seconds /= 1000
      else if (unit == "m") seconds *= 60

      rounded = int(seconds)
      if (seconds > rounded) rounded++
      if (seconds > 0 && rounded < 1) rounded = 1
      print rounded
      exit
    }
  '
}
```

Add `image_pull_jitter`:

```sh
image_pull_jitter() {
  jitter_base=$1
  jitter_limit=$((jitter_base / 4))
  [ "$jitter_limit" -ge 1 ] || jitter_limit=1
  jitter_entropy=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
  case $jitter_entropy in
    ''|*[!0123456789]*) jitter_entropy=$$ ;;
  esac
  printf '%s\n' $((jitter_entropy % jitter_limit + 1))
}
```

The single POSIX `awk` program keeps unit conversion and ceiling out of shell
arithmetic.

- [ ] **Step 3: Capture the Docker diagnostic and calculate each wait**

At the start of `pull_image`, create a diagnostic file with:

```sh
pull_error=$(mktemp "${TMPDIR:-/tmp}/nas-platform-pull-error.XXXXXX")
```

Redirect each pull's stderr to that file, replay it to stderr, and remove the
file before every return:

```sh
if docker pull "$pull_target" 2> "$pull_error"; then
  cat "$pull_error" >&2
  rm -f "$pull_error"
  return 0
fi
cat "$pull_error" >&2
if [ "$pull_attempt" -ge "$image_pull_attempts" ]; then
  rm -f "$pull_error"
  printf 'could not pull %s in %s attempt(s)\n' \
    "$pull_target" "$pull_attempt" >&2
  return 1
fi
```

On a retry, calculate and sleep for the server-aware jittered delay:

```sh
retry_after=$(retry_after_seconds < "$pull_error")
retry_delay=$pull_delay
case $retry_after in
  ''|*[!0123456789]*) ;;
  *) [ "$retry_after" -le "$retry_delay" ] || retry_delay=$retry_after ;;
esac
jitter=$(image_pull_jitter "$retry_delay")
retry_delay=$((retry_delay + jitter))
printf 'pull of %s failed, retrying in %ss (attempt %s of %s)\n' \
  "$pull_target" "$retry_delay" "$pull_attempt" "$image_pull_attempts" >&2
sleep "$retry_delay"
pull_attempt=$((pull_attempt + 1))
pull_delay=$((pull_delay * 2))
[ "$pull_delay" -le "$image_pull_max_delay" ] ||
  pull_delay=$image_pull_max_delay
: > "$pull_error"
```

Truncate the diagnostic file before the next attempt. Preserve the existing
failure message and stop before later images once the budget is exhausted.

- [ ] **Step 4: Run the retry contract and verify it passes**

Run:

```bash
tests/integration_suite_test.sh
```

Expected: PASS with `integration suite dispatch and image pre-pull tests passed`.

- [ ] **Step 5: Run the surrounding CI policy tests**

```bash
ruby tests/policy_ci_test.rb
ruby tests/ci/workflow_test.rb
```

Expected: both exit 0 with their existing success messages.

- [ ] **Step 6: Commit the implementation**

```bash
git add -- tests/integration.sh
git commit -m "fix: harden integration image pull retries"
```

### Task 3: Verify and publish issue #120

**Files:**
- Verify: `tests/integration.sh`
- Verify: `tests/integration_suite_test.sh`
- Verify: `docs/superpowers/specs/2026-08-29-issue-120-registry-retry-design.md`
- Verify: `docs/superpowers/plans/2026-08-29-issue-120-registry-retry.md`

- [ ] **Step 1: Run repository policy validation**

```bash
tests/validate-policy.sh
```

Expected: exit 0 and every registered policy check reports success.

- [ ] **Step 2: Audit the final branch**

```bash
git diff --check origin/main...HEAD
git status --short
git log --format='%B' origin/main..HEAD | rg -i '^Co-Authored-By:' && exit 1 || true
```

Expected: no whitespace errors, an empty worktree, and no `Co-Authored-By`
trailers.

- [ ] **Step 3: Push the dedicated issue branch**

```bash
git push -u origin fix/issue-120-registry-retries
```

Expected: the remote branch is created at the verified local HEAD.

- [ ] **Step 4: Open one draft PR for issue #120**

Create a draft PR from `fix/issue-120-registry-retries` to `main`. Summarize the
server-aware backoff, widened budget, jitter, and deterministic coverage. Include
`Closes #120`, list the exact verification commands, and state that workflow
authentication is intentionally handled by a separate change.
