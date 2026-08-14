#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/audiobookshelf-audio-test.XXXXXX")

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  case "$test_root" in
    "${TMPDIR:-/tmp}"/audiobookshelf-audio-test.??????)
      find "$test_root" -depth -delete
      ;;
  esac
  exit "$status"
}

trap cleanup EXIT HUP INT TERM

mkdir -p "$test_root/media" "$test_root/reports"

preseed_status=0
preseed_output=$(
  PLATFORM_MEDIA_ROOT="$test_root/media" \
  PLATFORM_REPORT_ROOT="$test_root/reports" \
  PLATFORM_AUDIOBOOKSHELF_PORT=13378 \
    "$repo_dir/tests/contracts/audiobookshelf.sh" seed-fixture-only 2>&1
) || preseed_status=$?

if [ "$preseed_status" -ne 0 ]; then
  printf '%s\n' "$preseed_output" >&2
  exit "$preseed_status"
fi

grep -Fqx 'Audiobookshelf media fixture prepared before deployment' <<<"$preseed_output" || {
  printf '%s\n' "$preseed_output" >&2
  printf '%s\n' 'Audiobookshelf audio test failed: pre-deployment fixture marker is absent' >&2
  exit 1
}

test -f "$test_root/media/Media/Audiobooks/task-9-contract-book/task-9-contract-book.wav" || {
  printf '%s\n' 'Audiobookshelf audio test failed: pre-deployment fixture is absent' >&2
  exit 1
}
test -f "$test_root/media/Media/Audiobooks/task-9-contract-book/cover.png" || {
  printf '%s\n' 'Audiobookshelf audio test failed: deterministic local cover is absent' >&2
  exit 1
}

preseed_line=$(grep -nF 'run_audiobookshelf_contract seed-fixture-only' \
  "$repo_dir/tests/integration.sh" | cut -d: -f1)
deploy_line=$(grep -nF "printf 'FRESH_ROOT_OK: clean deployment root converged" \
  "$repo_dir/tests/integration.sh" | cut -d: -f1)
if [ -z "$preseed_line" ] || [ -z "$deploy_line" ] || [ "$preseed_line" -ge "$deploy_line" ]; then
  printf '%s\n' 'Audiobookshelf audio test failed: fixture is not prepared before deployment' >&2
  exit 1
fi

grep -Fq 'next_fixture_scan_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10' \
  "$repo_dir/tests/contracts/audiobookshelf.sh" || {
  printf '%s\n' 'Audiobookshelf audio test failed: bounded fixture rescan is absent' >&2
  exit 1
}

test_status=0
output=$(
  PLATFORM_MEDIA_ROOT="$test_root/media" \
  PLATFORM_REPORT_ROOT="$test_root/reports" \
  PLATFORM_AUDIOBOOKSHELF_PORT=13378 \
    "$repo_dir/tests/contracts/audiobookshelf.sh" audio-self-test 2>&1
) || test_status=$?

if [ "$test_status" -ne 0 ]; then
  printf '%s\n' "$output" >&2
  exit "$test_status"
fi

grep -Fqx 'Audiobookshelf audio and diagnostic self-test passed' <<<"$output" || {
  printf '%s\n' "$output" >&2
  printf '%s\n' 'Audiobookshelf audio test failed: self-test marker is absent' >&2
  exit 1
}

redaction_status=0
redaction_output=$(
  PLATFORM_MEDIA_ROOT="$test_root/media" \
  PLATFORM_REPORT_ROOT="$test_root/reports" \
  PLATFORM_AUDIOBOOKSHELF_PORT=13378 \
    "$repo_dir/tests/contracts/audiobookshelf.sh" secret-redaction-self-test 2>&1
) || redaction_status=$?

if [ "$redaction_status" -ne 0 ]; then
  printf '%s\n' "$redaction_output" >&2
  exit "$redaction_status"
fi

grep -Fqx 'Audiobookshelf diagnostic secret redaction self-test passed' <<<"$redaction_output" || {
  printf '%s\n' "$redaction_output" >&2
  printf '%s\n' 'Audiobookshelf audio test failed: secret redaction marker is absent' >&2
  exit 1
}

selection_status=0
selection_output=$(
  PLATFORM_MEDIA_ROOT="$test_root/media" \
  PLATFORM_REPORT_ROOT="$test_root/reports" \
  PLATFORM_AUDIOBOOKSHELF_PORT=13378 \
    "$repo_dir/tests/contracts/audiobookshelf.sh" administrator-selection-self-test 2>&1
) || selection_status=$?

if [ "$selection_status" -ne 0 ]; then
  printf '%s\n' "$selection_output" >&2
  exit "$selection_status"
fi

grep -Fqx 'Audiobookshelf administrator selection self-test passed' <<<"$selection_output" || {
  printf '%s\n' "$selection_output" >&2
  printf '%s\n' 'Audiobookshelf audio test failed: administrator selection marker is absent' >&2
  exit 1
}

budget_status=0
budget_output=$(
  PLATFORM_MEDIA_ROOT="$test_root/media" \
  PLATFORM_REPORT_ROOT="$test_root/reports" \
  PLATFORM_AUDIOBOOKSHELF_PORT=13378 \
    "$repo_dir/tests/contracts/audiobookshelf.sh" authentication-budget-self-test 2>&1
) || budget_status=$?

if [ "$budget_status" -ne 0 ]; then
  printf '%s\n' "$budget_output" >&2
  exit "$budget_status"
fi

grep -Fqx 'Audiobookshelf authentication budget self-test passed' <<<"$budget_output" || {
  printf '%s\n' "$budget_output" >&2
  printf '%s\n' 'Audiobookshelf audio test failed: authentication budget marker is absent' >&2
  exit 1
}

printf '%s\n' 'Audiobookshelf audio contract test passed'
