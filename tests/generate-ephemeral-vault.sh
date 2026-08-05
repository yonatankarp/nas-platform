#!/bin/sh
set -eu
set +x

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
temporary_parent_input=${TMPDIR:-/tmp}
temporary_parent=$(CDPATH= cd -- "$temporary_parent_input" && pwd -P)
kernel_name=$(uname -s)

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

owner_id() {
  if [ "$kernel_name" = Darwin ]; then
    stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

file_mode() {
  if [ "$kernel_name" = Darwin ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

validate_owned_directory() {
  requested=$1
  [ -d "$requested" ] || die 'refusing unsafe vault directory'
  [ ! -L "$requested" ] || die 'refusing symlink vault directory'
  physical=$(CDPATH= cd -- "$requested" 2>/dev/null && pwd -P) ||
    die 'refusing unresolved vault directory'
  [ "$(dirname -- "$physical")" = "$temporary_parent" ] ||
    die 'vault directory must be directly under the temporary parent'
  case $(basename -- "$physical") in
    nas-platform-vault.??????) ;;
    *) die 'vault directory does not use the owned temporary prefix' ;;
  esac
  [ "$(owner_id "$physical")" = "$(id -u)" ] ||
    die 'vault directory is not owned by the current user'
  [ "$(file_mode "$physical")" = 700 ] ||
    die 'vault directory must have mode 0700'
  case "$physical/" in
    "$repo_dir/"*) die 'refusing to write ephemeral credentials inside the repository' ;;
  esac
  printf '%s\n' "$physical"
}

validate_output_path() {
  candidate=$1
  directory=$2
  expected_name=$3
  candidate_parent=$(CDPATH= cd -- "$(dirname -- "$candidate")" 2>/dev/null && pwd -P) ||
    die 'credential output parent cannot be resolved'
  [ "$candidate_parent" = "$directory" ] ||
    die 'credential output must be directly inside the validated directory'
  [ "$(basename -- "$candidate")" = "$expected_name" ] ||
    die 'credential output has an unexpected filename'
  [ ! -e "$candidate" ] && [ ! -L "$candidate" ] ||
    die 'refusing to overwrite ephemeral credential material'
}

random_password() {
  openssl rand -base64 24 2>/dev/null | tr -d '\n'
}

bcrypt_password() {
  password=$1
  printf '%s\n' "$password" |
    htpasswd -nBC 10 -i ephemeral 2>/dev/null | cut -d: -f2
}

random_token() {
  printf 'tk_%s' "$(openssl rand -hex 15 2>/dev/null | cut -c1-29)"
}

random_uuid() {
  hex=$(openssl rand -hex 16 2>/dev/null)
  printf '%s-%s-4%s-a%s-%s' \
    "$(printf '%s' "$hex" | cut -c1-8)" \
    "$(printf '%s' "$hex" | cut -c9-12)" \
    "$(printf '%s' "$hex" | cut -c14-16)" \
    "$(printf '%s' "$hex" | cut -c18-20)" \
    "$(printf '%s' "$hex" | cut -c21-32)"
}

generate_vault() {
  output=$1
  password_file=$2
  directory=$(validate_owned_directory "$(dirname -- "$output")")
  [ "$directory" = "$(validate_owned_directory "$(dirname -- "$password_file")")" ] ||
    die 'vault and password outputs must share one validated directory'
  validate_output_path "$output" "$directory" vault.yml
  validate_output_path "$password_file" "$directory" password
  [ -z "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    die 'vault directory must be empty before generation'

  command -v ansible-vault >/dev/null 2>&1 || die 'ansible-vault is required'
  command -v ansible-playbook >/dev/null 2>&1 || die 'ansible-playbook is required'
  command -v htpasswd >/dev/null 2>&1 || die 'htpasswd is required'
  command -v openssl >/dev/null 2>&1 || die 'openssl is required'
  command -v ssh-keygen >/dev/null 2>&1 || die 'ssh-keygen is required'

  umask 077
  plain="$directory/vault-plain.yml"
  private_key="$directory/.beszel-key"
  trap 'rm -f -- "$plain" "$private_key" "$private_key.pub" "$password_file" "$output"' EXIT
  trap 'exit 1' HUP INT TERM

  vault_password=$(random_password)
  printf '%s\n' "$vault_password" > "$password_file"
  chmod 0600 "$password_file"

  ntfy_admin_password=$(random_password)
  ntfy_dozzle_password=$(random_password)
  ntfy_beszel_password=$(random_password)
  dozzle_admin_password=$(random_password)
  ssh-keygen -q -t ed25519 -N '' -C 'ephemeral beszel hub' -f "$private_key" \
    >/dev/null 2>&1 || die 'failed to generate ephemeral key material'

  cat > "$plain" <<EOF
---
vault_audiobookshelf_admin_username: ephemeral-admin
vault_audiobookshelf_admin_password: '$(random_password)'
vault_beszel_superuser_email: ephemeral-admin@example.invalid
vault_beszel_superuser_password: '$(random_password)'
vault_beszel_app_user_email: ephemeral-user@example.invalid
vault_beszel_app_user_password: '$(random_password)'
vault_beszel_agent_key: '$(awk '{print $1, $2}' "$private_key.pub")'
vault_beszel_universal_token: '$(random_uuid)'
vault_beszel_hub_private_key: |
$(sed 's/^/  /' "$private_key")
vault_dozzle_admin_username: ephemeral-admin
vault_dozzle_admin_password: '$dozzle_admin_password'
vault_dozzle_admin_password_hash: '$(bcrypt_password "$dozzle_admin_password")'
vault_immich_admin_email: ephemeral-admin@example.invalid
vault_immich_admin_password: '$(random_password)'
vault_immich_db_name: immich
vault_immich_db_username: immich
vault_immich_db_password: '$(random_password)'
vault_jellyfin_admin_username: ephemeral-admin
vault_jellyfin_admin_password: '$(random_password)'
vault_komga_admin_email: ephemeral-admin@example.invalid
vault_komga_admin_password: '$(random_password)'
vault_ntfy_admin_user: ephemeral-admin
vault_ntfy_admin_password: '$ntfy_admin_password'
vault_ntfy_admin_password_hash: '$(bcrypt_password "$ntfy_admin_password")'
vault_ntfy_dozzle_password_hash: '$(bcrypt_password "$ntfy_dozzle_password")'
vault_ntfy_dozzle_token: '$(random_token)'
vault_ntfy_beszel_password_hash: '$(bcrypt_password "$ntfy_beszel_password")'
vault_ntfy_beszel_token: '$(random_token)'
vault_paperless_admin_username: ephemeral-admin
vault_paperless_admin_password: '$(random_password)'
vault_paperless_admin_email: ephemeral-admin@example.invalid
vault_paperless_db_name: paperless
vault_paperless_db_username: paperless
vault_paperless_db_password: '$(random_password)'
vault_paperless_django_secret_key: '$(openssl rand -hex 32 2>/dev/null)'
vault_paperless_gmail_account: ephemeral@example.invalid
vault_paperless_gmail_app_password: '$(random_password)'
vault_paperless_mail_account_name: ephemeral-gmail
vault_paperless_mail_rule_name: ephemeral-inbox
vault_tinymediamanager_password: '$(random_password)'
EOF
  chmod 0600 "$plain"
  ansible-vault encrypt --vault-password-file "$password_file" \
    --output "$output" "$plain" >/dev/null 2>&1 || die 'failed to encrypt ephemeral vault'
  chmod 0600 "$output"
  rm -f -- "$plain" "$private_key" "$private_key.pub"
  trap - EXIT HUP INT TERM
}

cleanup_vault() {
  directory=$(validate_owned_directory "$1")
  unexpected=$(find "$directory" -mindepth 1 -maxdepth 1 \
    ! -name vault.yml ! -name password -print -quit)
  [ -z "$unexpected" ] || die 'refusing cleanup because the vault directory has unexpected entries'
  [ ! -L "$directory/vault.yml" ] && [ ! -L "$directory/password" ] ||
    die 'refusing cleanup of symlink credential material'
  rm -f -- "$directory/vault.yml" "$directory/password" >/dev/null 2>&1 ||
    die 'failed to remove ephemeral credential material safely'
  rmdir -- "$directory" >/dev/null 2>&1 || die 'failed to remove the empty vault directory'
}

self_test() {
  directory=$(mktemp -d "$temporary_parent_input/nas-platform-vault.XXXXXX")
  generate_vault "$directory/vault.yml" "$directory/password"
  [ "$(file_mode "$directory/vault.yml")" = 600 ] ||
    die 'self-test found an unsafe vault mode'
  [ "$(file_mode "$directory/password")" = 600 ] ||
    die 'self-test found an unsafe password mode'
  grep -q '^\$ANSIBLE_VAULT;' "$directory/vault.yml" ||
    die 'self-test did not produce an encrypted vault'
  ansible-vault view --vault-password-file "$directory/password" "$directory/vault.yml" \
    >/dev/null 2>&1 || die 'self-test could not decrypt the generated vault'
  ansible-playbook "$repo_dir/validate-vault.yml" \
    --vault-password-file "$directory/password" \
    -e @"$directory/vault.yml" \
    -e platform_vault_file="$directory/vault.yml" \
    >/dev/null 2>&1 || die 'self-test generated a vault outside the shared contract'
  cleanup_vault "$directory"

  preservation_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
  preservation_directory=$(CDPATH= cd -- "$preservation_directory" && pwd -P)
  : > "$preservation_directory/unexpected"
  if "$0" --cleanup "$preservation_directory" >/dev/null 2>&1; then
    die 'self-test cleanup accepted an unexpected entry'
  fi
  [ -f "$preservation_directory/unexpected" ] ||
    die 'self-test cleanup did not preserve an unsafe directory'
  rm -f -- "$preservation_directory/unexpected"
  cleanup_vault "$preservation_directory"

  canonical_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
  canonical_directory=$(CDPATH= cd -- "$canonical_directory" && pwd -P)
  alias_path="$temporary_parent/nas-platform-vault.alias0"
  ln -s "$canonical_directory" "$alias_path"
  if "$0" --cleanup "$alias_path" >/dev/null 2>&1; then
    die 'self-test cleanup accepted a symlink directory'
  fi
  [ -d "$canonical_directory" ] || die 'self-test symlink refusal did not preserve its target'
  rm -f -- "$alias_path"
  cleanup_vault "$canonical_directory"

  open_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
  open_directory=$(CDPATH= cd -- "$open_directory" && pwd -P)
  chmod 0777 "$open_directory"
  if "$0" --output "$open_directory/vault.yml" \
      --password-file "$open_directory/password" >/dev/null 2>&1; then
    die 'self-test generation accepted a world-writable directory'
  fi
  [ -z "$(find "$open_directory" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    die 'self-test unsafe-directory refusal left credential material'
  chmod 0700 "$open_directory"
  cleanup_vault "$open_directory"
}

case ${1:-} in
  --output)
    [ "$#" -eq 4 ] && [ "$3" = --password-file ] ||
      die 'usage: generate-ephemeral-vault.sh --output PATH --password-file PATH'
    generate_vault "$2" "$4"
    ;;
  --cleanup)
    [ "$#" -eq 2 ] || die 'usage: generate-ephemeral-vault.sh --cleanup DIRECTORY'
    cleanup_vault "$2"
    ;;
  --self-test)
    [ "$#" -eq 1 ] || die 'usage: generate-ephemeral-vault.sh --self-test'
    self_test
    ;;
  *)
    die 'usage: generate-ephemeral-vault.sh --output PATH --password-file PATH | --cleanup DIRECTORY | --self-test'
    ;;
esac
