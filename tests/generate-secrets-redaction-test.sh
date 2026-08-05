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
    if [ "$token_count" -eq 1 ]; then
      printf 'tk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    else
      printf 'tk_bbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
    fi
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
      "$output" >/dev/null; then
    printf 'generated credential appeared in Ansible output\n' >&2
    exit 1
  fi
}

success_dir="$test_root/success"
mkdir -p "$success_dir" "$success_dir/state"
PATH="$fake_bin:$PATH" FAKE_DOCKER_STATE="$success_dir/state" \
  ansible-playbook "$repo_dir/generate-secrets.yml" --diff \
    -e generate_brand_new_platform=true \
    -e vault_plain_path="$success_dir/vault-plain.yml" \
    -e vault_encrypted_path="$success_dir/vault.yml" \
    -e audiobookshelf_admin_password=SENTINEL_GENERATED_PASSWORD \
    >"$success_dir/output" 2>&1
assert_no_sentinel "$success_dir/output"

failure_dir="$test_root/failure"
mkdir -p "$failure_dir" "$failure_dir/state"
if PATH="$fake_bin:$PATH" FAKE_DOCKER_STATE="$failure_dir/state" \
    FAKE_DOCKER_TOKEN_FAILURE=true \
    ansible-playbook "$repo_dir/generate-secrets.yml" --diff \
      -e generate_brand_new_platform=true \
      -e vault_plain_path="$failure_dir/vault-plain.yml" \
      -e vault_encrypted_path="$failure_dir/vault.yml" \
      -e audiobookshelf_admin_password=SENTINEL_GENERATED_PASSWORD \
      >"$failure_dir/output" 2>&1; then
  printf 'secret generator failure fixture unexpectedly succeeded\n' >&2
  exit 1
fi
assert_no_sentinel "$failure_dir/output"
