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

mkdir -p "$test_root/docker" "$test_root/fixtures" "$test_root/media" "$test_root/reports"

mac_preconverge_hook=$repo_dir/tests/mac/hooks/pre-converge/30-audiobookshelf.sh
test -x "$mac_preconverge_hook" || {
  printf '%s\n' 'Audiobookshelf audio test failed: Mac pre-deployment fixture hook is absent' >&2
  exit 1
}

preseed_status=0
preseed_output=$(
  PLATFORM_MAC_VAULT_FILE="$test_root/unused-vault.yml" \
  PLATFORM_MAC_VAULT_PASSWORD_FILE="$test_root/unused-vault-password" \
  PLATFORM_DOCKER_ROOT="$test_root/docker" \
  PLATFORM_MEDIA_ROOT="$test_root/media" \
  PLATFORM_FIXTURE_ROOT="$test_root/fixtures" \
  PLATFORM_REPORT_ROOT="$test_root/reports" \
  PLATFORM_PROJECT_NAME=audiobookshelf-audio-test \
  PLATFORM_NTFY_PORT=18080 \
  PLATFORM_AUDIOBOOKSHELF_PORT=13378 \
    "$mac_preconverge_hook" 2>&1
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

fixture_directory=$test_root/media/Media/Audiobooks/task-9-contract-book
fixture_path=$fixture_directory/task-9-contract-book.wav
cover_path=$fixture_directory/cover.png
test -f "$fixture_path" && test ! -L "$fixture_path" || {
  printf '%s\n' 'Audiobookshelf audio test failed: pre-deployment fixture is absent' >&2
  exit 1
}
test -f "$cover_path" && test ! -L "$cover_path" || {
  printf '%s\n' 'Audiobookshelf audio test failed: deterministic local cover is absent' >&2
  exit 1
}
ruby -rpathname - "$test_root/media" "$fixture_directory" "$fixture_path" "$cover_path" <<'RUBY'
media_root, fixture_directory, fixture_path, cover_path = ARGV.map { |path| Pathname.new(path).realpath }
expected_directory = media_root.join("Media/Audiobooks/task-9-contract-book")
abort "Audiobookshelf audio test failed: Mac fixture escaped its media root" unless
  fixture_directory == expected_directory &&
    [fixture_path, cover_path].all? { |path| path.dirname == expected_directory }
RUBY
first_fixture_digest=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$fixture_path")
first_cover_digest=$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$cover_path")
test "$first_fixture_digest" = 8c26df165039d50a36a4bfa7306a053b889a7582128ad318ec5b19ab5eb04f4a &&
  test "$first_cover_digest" = 431ced6916a2a21a156e38701afe55bbd7f88969fbbfc56d7fe099d47f265460 || {
  printf '%s\n' 'Audiobookshelf audio test failed: Mac pre-deployment fixture bytes differ' >&2
  exit 1
}

second_preseed_output=$(
  PLATFORM_MAC_VAULT_FILE="$test_root/unused-vault.yml" \
  PLATFORM_MAC_VAULT_PASSWORD_FILE="$test_root/unused-vault-password" \
  PLATFORM_DOCKER_ROOT="$test_root/docker" \
  PLATFORM_MEDIA_ROOT="$test_root/media" \
  PLATFORM_FIXTURE_ROOT="$test_root/fixtures" \
  PLATFORM_REPORT_ROOT="$test_root/reports" \
  PLATFORM_PROJECT_NAME=audiobookshelf-audio-test \
  PLATFORM_NTFY_PORT=18080 \
  PLATFORM_AUDIOBOOKSHELF_PORT=13378 \
    "$mac_preconverge_hook" 2>&1
)
grep -Fqx 'Audiobookshelf media fixture prepared before deployment' <<<"$second_preseed_output" || {
  printf '%s\n' "$second_preseed_output" >&2
  printf '%s\n' 'Audiobookshelf audio test failed: repeated Mac pre-deployment hook omitted its marker' >&2
  exit 1
}
test "$first_fixture_digest" = \
  "$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$fixture_path")" &&
  test "$first_cover_digest" = \
    "$(ruby -rdigest -e 'print Digest::SHA256.file(ARGV.fetch(0)).hexdigest' "$cover_path")" || {
  printf '%s\n' 'Audiobookshelf audio test failed: repeated Mac pre-deployment hook changed fixture bytes' >&2
  exit 1
}

preseed_line=$(grep -nF '"$repo_dir/tests/contracts/audiobookshelf.sh" seed-fixture-only' \
  "$repo_dir/tests/integration.sh" | cut -d: -f1)
deploy_line=$(grep -nF 'docker run --rm' "$repo_dir/tests/integration.sh" | head -1 | cut -d: -f1)
if [ -z "$preseed_line" ] || [ -z "$deploy_line" ] || [ "$preseed_line" -ge "$deploy_line" ]; then
  printf '%s\n' 'Audiobookshelf audio test failed: fixture is not prepared before deployment' >&2
  exit 1
fi

if grep -Eq 'request\([[:space:]]*"post",[[:space:]]*"/api/libraries/.*/scan"' \
    "$repo_dir/tests/contracts/audiobookshelf.sh"; then
  printf '%s\n' 'Audiobookshelf audio test failed: contract still owns a library scan' >&2
  exit 1
fi

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
