#!/bin/sh
set -eu
set +x

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-redaction.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
# The image generate-secrets.yml resolves its bcrypt hasher from, read the way
# the play reads it, so the stub can refuse a hasher run against any other image.
FAKE_DOCKER_HASHER_IMAGE=$(ruby -ryaml -e '
  puts YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true).dig("services", "nextcloud", "image")
' "$repo_dir/services/nextcloud/compose.yml")
export FAKE_DOCKER_HASHER_IMAGE

cat > "$fake_bin/docker" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
  "version --format json")
    printf '{}\n'
    ;;
  "run --rm -i --entrypoint php "*)
    # Exactly the argv generate-secrets.yml's hasher task runs: the pinned image,
    # then one PHP script that bcrypts the line it reads from stdin. The password
    # arrives on stdin and is never echoed on success.
    if [ "$#" -ne 8 ] || [ "$6" != "$FAKE_DOCKER_HASHER_IMAGE" ] || [ "$7" != -r ]; then
      printf 'unexpected fake docker invocation\n' >&2
      exit 1
    fi
    case "$8" in
      *'password_hash(rtrim(fgets(STDIN), "\n"), PASSWORD_BCRYPT)'*) ;;
      *)
        printf 'unexpected fake docker invocation\n' >&2
        exit 1
        ;;
    esac
    password=$(cat)
    if [ "${FAKE_DOCKER_HASH_FAILURE:-false}" = true ]; then
      # A failing hasher that repeats its input on both streams: the task's
      # no_log is the only thing standing between that and the Ansible output.
      printf 'SENTINEL_GENERATED_HASH_FAILURE %s\n' "$password"
      printf 'SENTINEL_GENERATED_HASH_FAILURE %s\n' "$password" >&2
      exit 1
    fi
    printf '%s\n' "$password" >> "$FAKE_DOCKER_STATE/hashed-passwords"
    hash_count_file="$FAKE_DOCKER_STATE/hash-count"
    hash_count=0
    [ ! -f "$hash_count_file" ] || hash_count=$(cat "$hash_count_file")
    hash_count=$((hash_count + 1))
    printf '%s\n' "$hash_count" > "$hash_count_file"
    # A valid-shaped $2y$ bcrypt, distinct per invocation.
    printf '$2y$12$%053d\n' "$hash_count"
    ;;
  *)
    printf 'unexpected fake docker invocation\n' >&2
    exit 1
    ;;
esac
EOF
chmod 0755 "$fake_bin/docker"

relay_token=$(printf 'feed%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)

assert_no_sentinel() {
  output=$1
  if grep -F -e SENTINEL_GENERATED_PASSWORD -e SENTINEL_GENERATED_HASH \
      -e '$2y$12$0000000000' -e "$relay_token" -e 'OPENSSH PRIVATE KEY' \
      "$output" >/dev/null; then
    printf 'generated credential appeared in Ansible output\n' >&2
    exit 1
  fi
}

success_dir="$test_root/success"
mkdir -p "$success_dir" "$success_dir/state"
# All three of the play's vault paths are redirected into the sandbox, not only
# the two it writes and refuses on: vault_retired_path defaults into the real
# checkout, so leaving it would make this fixture's verdict depend on whether the
# operator happens to have a stray inventory/group_vars/all/vault.yml there. What
# that guard does is tests/secrets_docs_test.rb's subject; this fixture's is
# redaction.
set +e
PATH="$fake_bin:$PATH" FAKE_DOCKER_STATE="$success_dir/state" \
  ansible-playbook -i localhost, -c local "$repo_dir/generate-secrets.yml" --diff \
    -e generate_brand_new_platform=true \
    -e vault_plain_path="$success_dir/vault-plain.yml" \
    -e vault_external_path="$success_dir/vault.yml" \
    -e vault_retired_path="$success_dir/retired-vault.yml" \
    -e audiobookshelf_admin_password=SENTINEL_GENERATED_PASSWORD \
    -e dozzle_admin_password=SENTINEL_GENERATED_PASSWORD_DOZZLE \
    -e trailarr_admin_password=SENTINEL_GENERATED_PASSWORD_TRAILARR \
    -e dozzle_alert_relay_token="$relay_token" \
    >"$success_dir/output" 2>&1
success_status=$?
set -e
assert_no_sentinel "$success_dir/output"
if [ "$success_status" -ne 0 ]; then
  cat "$success_dir/output" >&2
  exit "$success_status"
fi
# The passwords reached the hasher on stdin, one per administrator, so the
# redaction above was proved over a run that really handled them.
if [ "$(cat "$success_dir/state/hashed-passwords" 2>/dev/null)" != "$(printf '%s\n%s' SENTINEL_GENERATED_PASSWORD_DOZZLE SENTINEL_GENERATED_PASSWORD_TRAILARR)" ]; then
  printf 'the bcrypt hasher did not receive both administrator passwords on stdin\n' >&2
  exit 1
fi
grep -F '$2y$12$00000000000000000000000000000000000000000000000000001' \
  "$success_dir/vault-plain.yml" >/dev/null || {
  printf 'the generated vault does not carry the hasher output\n' >&2
  exit 1
}

failure_dir="$test_root/failure"
mkdir -p "$failure_dir" "$failure_dir/state"
if PATH="$fake_bin:$PATH" FAKE_DOCKER_STATE="$failure_dir/state" \
    FAKE_DOCKER_HASH_FAILURE=true \
    ansible-playbook -i localhost, -c local "$repo_dir/generate-secrets.yml" --diff \
      -e generate_brand_new_platform=true \
      -e vault_plain_path="$failure_dir/vault-plain.yml" \
      -e vault_external_path="$failure_dir/vault.yml" \
      -e vault_retired_path="$failure_dir/retired-vault.yml" \
      -e audiobookshelf_admin_password=SENTINEL_GENERATED_PASSWORD \
      -e dozzle_admin_password=SENTINEL_GENERATED_PASSWORD_DOZZLE \
      -e trailarr_admin_password=SENTINEL_GENERATED_PASSWORD_TRAILARR \
      -e dozzle_alert_relay_token="$relay_token" \
      >"$failure_dir/output" 2>&1; then
  printf 'secret generator failure fixture unexpectedly succeeded\n' >&2
  exit 1
fi
assert_no_sentinel "$failure_dir/output"
# The failure must be the hasher's own, or the fixture proved redaction over a
# run that never reached it.
grep -F 'TASK [Hash the administrator passwords with the pinned bcrypt hasher]' \
  "$failure_dir/output" >/dev/null || {
  cat "$failure_dir/output" >&2
  printf 'secret generator failure fixture did not fail at the hasher\n' >&2
  exit 1
}
