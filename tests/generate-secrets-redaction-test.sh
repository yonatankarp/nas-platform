#!/bin/sh
set -eu
set +x

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-redaction.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/docker" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
  "version --format json")
    printf '{}\n'
    ;;
  *" user hash")
    cat >/dev/null
    printf '%s\n' '$2b$12$00000000000000000000000000000000000000000000000000000'
    ;;
  *" token generate")
    if [ "${FAKE_DOCKER_TOKEN_FAILURE:-false}" = true ]; then
      printf '%s\n' 'SENTINEL_GENERATED_TOKEN_FAILURE'
      exit 1
    fi
    token_count_file="$FAKE_DOCKER_STATE/token-count"
    token_count=0
    [ ! -f "$token_count_file" ] || token_count=$(cat "$token_count_file")
    token_count=$((token_count + 1))
    printf '%s\n' "$token_count" > "$token_count_file"
    # A distinct token per invocation: the playbook asserts that every generated
    # publisher token is unique, so repeating one fails the run. There is one arm
    # per publisher the playbook generates for, and the fallback refuses rather
    # than repeating the last token -- a repeat would fail the run anyway, but as
    # an unexplained credential-shape assertion rather than as the missing stub
    # arm it actually is.
    case "$token_count" in
      1) printf 'tk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
      2) printf 'tk_bbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
      3) printf 'tk_ccccccccccccccccccccccccccccc\n' ;;
      4) printf 'tk_ddddddddddddddddddddddddddddd\n' ;;
      *)
        printf 'fake docker: no distinct token defined for invocation %s\n' \
          "$token_count" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'unexpected fake docker invocation\n' >&2
    exit 1
    ;;
esac
EOF
chmod 0755 "$fake_bin/docker"

assert_no_sentinel() {
  output=$1
  if grep -F -e SENTINEL_GENERATED_PASSWORD -e SENTINEL_GENERATED_TOKEN \
      -e tk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaa -e tk_bbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
      -e tk_ccccccccccccccccccccccccccccc -e tk_ddddddddddddddddddddddddddddd \
      "$output" >/dev/null; then
    printf 'generated credential appeared in Ansible output\n' >&2
    exit 1
  fi
}

success_dir="$test_root/success"
mkdir -p "$success_dir" "$success_dir/state"
set +e
PATH="$fake_bin:$PATH" FAKE_DOCKER_STATE="$success_dir/state" \
  ansible-playbook -i localhost, -c local "$repo_dir/generate-secrets.yml" --diff \
    -e generate_brand_new_platform=true \
    -e vault_plain_path="$success_dir/vault-plain.yml" \
    -e vault_encrypted_path="$success_dir/vault.yml" \
    -e audiobookshelf_admin_password=SENTINEL_GENERATED_PASSWORD \
    >"$success_dir/output" 2>&1
success_status=$?
set -e
assert_no_sentinel "$success_dir/output"
if [ "$success_status" -ne 0 ]; then
  cat "$success_dir/output" >&2
  exit "$success_status"
fi

failure_dir="$test_root/failure"
mkdir -p "$failure_dir" "$failure_dir/state"
if PATH="$fake_bin:$PATH" FAKE_DOCKER_STATE="$failure_dir/state" \
    FAKE_DOCKER_TOKEN_FAILURE=true \
    ansible-playbook -i localhost, -c local "$repo_dir/generate-secrets.yml" --diff \
      -e generate_brand_new_platform=true \
      -e vault_plain_path="$failure_dir/vault-plain.yml" \
      -e vault_encrypted_path="$failure_dir/vault.yml" \
      -e audiobookshelf_admin_password=SENTINEL_GENERATED_PASSWORD \
      >"$failure_dir/output" 2>&1; then
  printf 'secret generator failure fixture unexpectedly succeeded\n' >&2
  exit 1
fi
assert_no_sentinel "$failure_dir/output"
