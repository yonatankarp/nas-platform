#!/bin/sh
set -eu
set +x

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

validate_lexical_path() {
  path=$1
  label=$2
  case $path in
    /*) ;;
    *) die "$label must be absolute" ;;
  esac
  case $path in
    /) ;;
    */|*//*|*/./*|*/../*|*/.|*/..) die "$label must be lexically normalized" ;;
  esac
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
temporary_parent_input=${TMPDIR:-/tmp}
case $temporary_parent_input in
  /) ;;
  *//) die 'temporary parent must be lexically normalized' ;;
  */) temporary_parent_input=${temporary_parent_input%/} ;;
esac
validate_lexical_path "$temporary_parent_input" 'temporary parent'
[ -d "$temporary_parent_input" ] || die 'temporary parent is unavailable'
[ ! -L "$temporary_parent_input" ] || die 'refusing symlink temporary parent'
temporary_parent=$(CDPATH= cd -- "$temporary_parent_input" && pwd -P)
kernel_name=$(uname -s)

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
  validate_lexical_path "$requested" 'vault directory'
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

# Credential groups a target may legitimately leave undeclared, and which this
# generator can therefore be asked not to stand in for.
#
# A group qualifies because `inventory/group_vars/all/main.yml` carries every key
# in it as an empty string and `OPTIONAL_KEY_GROUPS` in
# filter_plugins/vault_credential_schema.py suppresses that group's shape rules
# when all of them are empty. Both halves are what make the undeclared state
# valid rather than a failed converge, and tests/policy_vault_test.rb pins this
# list against the filter's tuple so a group added there cannot be missed here.
#
# The reason this exists at all: a fixture that supplies a credential can never
# catch a bug about that credential's absence. Standing in for all six Usenet
# provider values unconditionally is what let #274 merge with every lane green
# and then fail the NAS's next converge in `vault_contract`, before any service
# could deploy (#295).
optional_credential_groups='usenet'

# Which of them this run leaves undeclared. Set by --undeclared.
undeclared_credential_groups=

optional_credential_group_known() {
  for known_group in $optional_credential_groups; do
    [ "$1" != "$known_group" ] || return 0
  done
  return 1
}

credential_group_is_undeclared() {
  for undeclared_group in $undeclared_credential_groups; do
    [ "$1" != "$undeclared_group" ] || return 0
  done
  return 1
}

select_undeclared_credential_groups() {
  requested=$1
  [ -n "$requested" ] || die '--undeclared requires at least one credential group'
  case $requested in
    ,*|*,|*,,*) die 'malformed undeclared credential group list' ;;
  esac
  # Split on the comma with `tr` rather than by reassigning IFS, so nothing has
  # to be restored around the validation the loop body performs. `set -f` is
  # still needed: an unquoted expansion is what splits the list, and a group
  # spelled `*` would otherwise reach the known-group check as a directory
  # listing rather than as the one word it is.
  set -f
  for requested_group in $(printf '%s' "$requested" | tr ',' ' '); do
    set +f
    optional_credential_group_known "$requested_group" ||
      die "unknown optional credential group: $requested_group"
    if credential_group_is_undeclared "$requested_group"; then
      die "repeated optional credential group: $requested_group"
    fi
    undeclared_credential_groups="${undeclared_credential_groups:+$undeclared_credential_groups }$requested_group"
    set -f
  done
  set +f
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

# Bazarr's settings form is POSTed the Radarr and Sonarr API keys, and Bazarr
# 1.6.0 casts every submitted value with int() unless the last dash-segment of
# its key is one of app/config.py's str_keys -- `apikey` is not one. dynaconf
# then validates the whole schema, so a key of only decimal digits fails
# `is_type_of str` and the request is answered 406 for as long as that key is
# deployed. A hex draw with no a-f in it is about one in 3e-7, so redrawing a
# bounded number of times is certain in practice and cannot hang; exhausting the
# bound is reported rather than papered over. Only these two keys need it: no
# other vault credential reaches that cast.
random_api_key() {
  attempt=0
  while [ "$attempt" -lt 8 ]; do
    candidate_key=$(openssl rand -hex 16 2>/dev/null)
    case $candidate_key in
      *[abcdef]*)
        printf '%s' "$candidate_key"
        return 0
        ;;
    esac
    attempt=$((attempt + 1))
  done
  return 1
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

generate_vault() (
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
  ntfy_deploy_password=$(random_password)
  dozzle_admin_password=$(random_password)
  trailarr_admin_password=$(random_password)
  ntfy_seerr_password=$(random_password)
  managed_dozzle_password=$(random_password)
  managed_ntfy_password=$(random_password)
  radarr_api_key=$(random_api_key) || die 'failed to generate a Radarr API key'
  sonarr_api_key=$(random_api_key) || die 'failed to generate a Sonarr API key'

  # The Usenet provider group, computed before the heredoc because it is the one
  # group whose values depend on --undeclared. Each key name appears exactly once
  # below: tests/policy_vault_test.rb refuses a duplicate vault key in this file,
  # so a declared and an undeclared arm each spelling the pair is not available
  # -- only the values may branch.
  #
  # The group is two keys rather than six because four of the provider's values
  # are not credentials and are no longer vault-authored (#298). Those four are
  # operator policy in inventory, so a lane declares them the way it declares any
  # other inventory value -- tests/integration_controller.sh passes
  # `media_usenet_provider` explicitly -- and this generator has nothing to say
  # about them. What it still owns is the account behind the host.
  #
  # Undeclared is two empty strings rather than two omitted lines.
  # roles/vault_contract declares both required and this generator's own
  # --self-test validates the vault with no group_vars in play, so an omitted key
  # would have nothing to satisfy that requirement. An empty string is also the
  # exact value a real undeclared target sees, because
  # inventory/group_vars/all/main.yml supplies one there.
  usenet_server_username=ephemeral-usenet-username
  usenet_server_password=$(random_password)
  if credential_group_is_undeclared usenet; then
    usenet_server_username=
    usenet_server_password=
  fi
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
vault_dozzle_alert_relay_token: '$(openssl rand -hex 32 2>/dev/null)'
vault_immich_admin_email: ephemeral-admin@example.invalid
vault_immich_admin_password: '$(random_password)'
vault_immich_db_name: immich
vault_immich_db_username: immich
vault_immich_db_password: '$(random_password)'
vault_jellyfin_admin_username: Yonatan
vault_jellyfin_admin_password: '$(random_password)'
vault_jellyfin_opensubtitles_username: ephemeral-opensubtitles-user
vault_jellyfin_opensubtitles_password: '$(random_password)'
vault_komga_admin_email: ephemeral-admin@example.invalid
vault_komga_admin_password: '$(random_password)'
vault_arr_radarr_api_key: '$radarr_api_key'
vault_arr_radarr_admin_username: nasadmin
vault_arr_radarr_admin_password: '$(random_password)'
vault_arr_sonarr_api_key: '$sonarr_api_key'
vault_arr_sonarr_admin_username: nasadmin
vault_arr_sonarr_admin_password: '$(random_password)'
vault_arr_prowlarr_api_key: '$(openssl rand -hex 16 2>/dev/null)'
vault_arr_prowlarr_admin_username: nasadmin
vault_arr_prowlarr_admin_password: '$(random_password)'
vault_arr_bazarr_api_key: '$(openssl rand -hex 16 2>/dev/null)'
vault_arr_bazarr_admin_username: nasadmin
vault_arr_bazarr_admin_password: '$(random_password)'
vault_downloaders_sabnzbd_api_key: '$(openssl rand -hex 16 2>/dev/null)'
vault_downloaders_sabnzbd_admin_username: nasadmin
vault_downloaders_sabnzbd_admin_password: '$(random_password)'
vault_downloaders_sabnzbd_server_username: '$usenet_server_username'
vault_downloaders_sabnzbd_server_password: '$usenet_server_password'
vault_bindery_api_key: '$(openssl rand -hex 16 2>/dev/null)'
vault_bindery_admin_username: nasadmin
vault_bindery_admin_password: '$(random_password)'
vault_kapowarr_admin_username: nasadmin
vault_kapowarr_admin_password: '$(random_password)'
vault_kapowarr_comicvine_api_key: ephemeral-comicvine-api-key
vault_pinchflat_admin_username: nasadmin
vault_pinchflat_admin_password: '$(random_password)'
vault_trailarr_api_key: '$(openssl rand -hex 16 2>/dev/null)'
vault_trailarr_admin_username: nasadmin
vault_trailarr_admin_password: '$trailarr_admin_password'
vault_trailarr_admin_password_hash: '$(bcrypt_password "$trailarr_admin_password")'
vault_seerr_api_key: '$(openssl rand -hex 16 2>/dev/null)'
vault_ntfy_admin_user: ephemeral-admin
vault_ntfy_admin_password: '$ntfy_admin_password'
vault_ntfy_admin_password_hash: '$(bcrypt_password "$ntfy_admin_password")'
vault_ntfy_dozzle_password_hash: '$(bcrypt_password "$ntfy_dozzle_password")'
vault_ntfy_dozzle_token: '$(random_token)'
vault_ntfy_beszel_password_hash: '$(bcrypt_password "$ntfy_beszel_password")'
vault_ntfy_beszel_token: '$(random_token)'
vault_ntfy_deploy_password_hash: '$(bcrypt_password "$ntfy_deploy_password")'
vault_ntfy_deploy_token: '$(random_token)'
vault_ntfy_seerr_password_hash: '$(bcrypt_password "$ntfy_seerr_password")'
vault_ntfy_seerr_token: '$(random_token)'
vault_paperless_admin_username: ephemeral-admin
vault_paperless_admin_password: '$(random_password)'
vault_paperless_admin_email: ephemeral-admin@example.invalid
vault_paperless_db_name: ephemeral-paperless-db
vault_paperless_db_username: ephemeral-paperless-db-user
vault_paperless_db_password: '$(random_password)'
vault_paperless_django_secret_key: '$(openssl rand -hex 32 2>/dev/null)'
vault_paperless_gmail_account: ephemeral@example.invalid
vault_paperless_gmail_app_password: '$(random_password)'
vault_managed_users:
  audiobookshelf:
    - username: reader-ephemeral-example-invalid
      password: '$(random_password)'
      type: user
      is_active: true
      permissions:
        flags:
          accessAllLibraries: false
        librariesAccessible: []
        itemTagsSelected: []
  beszel:
    - email: reader@beszel.ephemeral.example.invalid
      password: '$(random_password)'
      role: user
      verified: true
  dozzle:
    - username: reader-ephemeral-example-invalid
      password: '$managed_dozzle_password'
      password_hash: '$(bcrypt_password "$managed_dozzle_password")'
      email: reader@dozzle.ephemeral.example.invalid
      name: Synthetic Ephemeral Reader
      filter: ""
      roles: none
  immich:
    - email: reader@immich.ephemeral.example.invalid
      password: '$(random_password)'
      name: Synthetic Ephemeral Reader
      quota_size: 10737418240
  jellyfin:
    - username: reader-ephemeral-example-invalid
      password: '$(random_password)'
      policy:
        IsAdministrator: false
        EnableAllFolders: false
  komga:
    - email: reader@komga.ephemeral.example.invalid
      password: '$(random_password)'
      roles: [PAGE_STREAMING]
  ntfy:
    - username: reader-ephemeral-example-invalid
      password: '$managed_ntfy_password'
      password_hash: '$(bcrypt_password "$managed_ntfy_password")'
      role: user
      access:
        - topic: nas-critical
          permission: read-only
      tokens: []
  paperless_ngx:
    - username: reader-ephemeral-example-invalid
      password: '$(random_password)'
      email: reader@paperless.ephemeral.example.invalid
      is_active: true
      is_staff: false
      is_superuser: false
      groups: []
EOF
  chmod 0600 "$plain"
  ansible-vault encrypt --vault-password-file "$password_file" \
    --output "$output" "$plain" >/dev/null 2>&1 || die 'failed to encrypt ephemeral vault'
  chmod 0600 "$output"
  rm -f -- "$plain" "$private_key" "$private_key.pub"
  trap - EXIT HUP INT TERM
)

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

self_test_fixture_directory=
self_test_trap_marker=
self_test_cleanup_on_exit() {
  self_test_exit_status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$self_test_fixture_directory" ] &&
     [ -d "$self_test_fixture_directory" ] &&
     ! cleanup_vault "$self_test_fixture_directory" >/dev/null 2>&1; then
    [ "$self_test_exit_status" -ne 0 ] || self_test_exit_status=1
  fi
  if [ -n "$self_test_trap_marker" ] && [ -f "$self_test_trap_marker" ] &&
     [ ! -L "$self_test_trap_marker" ]; then
    rm -f -- "$self_test_trap_marker"
  fi
  exit "$self_test_exit_status"
}

self_test() {
  directory=$(mktemp -d "$temporary_parent_input/nas-platform-vault.XXXXXX")
  self_test_fixture_directory=$directory
  trap self_test_cleanup_on_exit EXIT
  trap 'exit 130' HUP INT TERM
  trap_marker="$temporary_parent_input/nas-platform-vault.trap.$$"
  self_test_trap_marker=$trap_marker
  (
    trap ': > "$trap_marker"' EXIT
    generate_vault "$directory/vault.yml" "$directory/password"
    [ "$(file_mode "$directory/vault.yml")" = 600 ] ||
      die 'self-test found an unsafe vault mode'
    [ "$(file_mode "$directory/password")" = 600 ] ||
      die 'self-test found an unsafe password mode'
    grep -q '^\$ANSIBLE_VAULT;' "$directory/vault.yml" ||
      die 'self-test did not produce an encrypted vault'
    ansible-vault view --vault-password-file "$directory/password" "$directory/vault.yml" \
      >/dev/null 2>&1 || die 'self-test could not decrypt the generated vault'
    ansible-playbook -i localhost, -c local "$repo_dir/validate-vault.yml" \
      --vault-password-file "$directory/password" \
      -e @"$directory/vault.yml" \
      -e platform_vault_file="$directory/vault.yml" \
      >/dev/null 2>&1 || die 'self-test generated a vault outside the shared contract'
    cleanup_vault "$directory"
  )
  self_test_fixture_directory=
  trap - EXIT HUP INT TERM
  [ -f "$trap_marker" ] || die 'self-test generation did not preserve its caller trap'
  rm -f -- "$trap_marker"
  self_test_trap_marker=

  # The undeclared shape, proved here rather than only in the integration lane
  # that consumes it: it is the state issue #295 found nothing converged, and a
  # break in it would otherwise be visible only after a Docker suite has run.
  # Both halves are asserted -- that all six values really are empty, and that
  # the resulting vault still satisfies the shared credential contract, which is
  # what OPTIONAL_KEY_GROUPS in filter_plugins/vault_credential_schema.py exists
  # to make true.
  undeclared_directory=$(mktemp -d "$temporary_parent_input/nas-platform-vault.XXXXXX")
  self_test_fixture_directory=$undeclared_directory
  trap self_test_cleanup_on_exit EXIT
  trap 'exit 130' HUP INT TERM
  (
    "$0" --undeclared usenet \
      --output "$undeclared_directory/vault.yml" \
      --password-file "$undeclared_directory/password" ||
      die 'self-test could not generate an undeclared vault'
    undeclared_view=$(ansible-vault view \
      --vault-password-file "$undeclared_directory/password" \
      "$undeclared_directory/vault.yml" 2>/dev/null) ||
      die 'self-test could not decrypt the undeclared vault'
    for undeclared_key in username password; do
      printf '%s\n' "$undeclared_view" |
        grep -qx "vault_downloaders_sabnzbd_server_$undeclared_key: ''" ||
        die 'self-test undeclared vault still declares a Usenet provider'
    done
    ansible-playbook -i localhost, -c local "$repo_dir/validate-vault.yml" \
      --vault-password-file "$undeclared_directory/password" \
      -e @"$undeclared_directory/vault.yml" \
      -e platform_vault_file="$undeclared_directory/vault.yml" \
      >/dev/null 2>&1 ||
      die 'self-test undeclared vault fell outside the shared contract'
    cleanup_vault "$undeclared_directory"
  )
  self_test_fixture_directory=
  trap - EXIT HUP INT TERM

  refusal_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
  # Each malformed list is quoted so the trailing and leading commas read as
  # part of the value rather than as separators a reader has to squint at.
  for refused_groups in '' unknown-group 'usenet,usenet' 'usenet,' ',usenet'; do
    if "$0" --undeclared "$refused_groups" \
        --output "$refusal_directory/vault.yml" \
        --password-file "$refusal_directory/password" >/dev/null 2>&1; then
      die 'self-test accepted an invalid undeclared credential group list'
    fi
    [ -z "$(find "$refusal_directory" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
      die 'self-test undeclared-group refusal left credential material'
  done
  cleanup_vault "$refusal_directory"

  validation_parent=$(mktemp -d "$temporary_parent/nas-platform-vault-validation.XXXXXX")
  validation_tools=$(mktemp -d "$temporary_parent/nas-platform-vault-validation-tools.XXXXXX")
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$validation_tools/ansible-playbook"
  chmod 0755 "$validation_tools/ansible-playbook"
  if TMPDIR="$validation_parent" PATH="$validation_tools:$PATH" \
      "$0" --self-test >/dev/null 2>&1; then
    die 'self-test mid-validation fixture unexpectedly succeeded'
  fi
  [ -z "$(find "$validation_parent" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    die 'self-test mid-validation failure left credential material'
  rmdir -- "$validation_parent"
  rm -f -- "$validation_tools/ansible-playbook"
  rmdir -- "$validation_tools"

  existing_vault_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
  : > "$existing_vault_directory/vault.yml"
  if "$0" --output "$existing_vault_directory/vault.yml" \
      --password-file "$existing_vault_directory/password" >/dev/null 2>&1; then
    die 'self-test generation accepted a pre-existing output'
  fi
  [ -f "$existing_vault_directory/vault.yml" ] &&
    [ ! -e "$existing_vault_directory/password" ] ||
    die 'self-test pre-existing output refusal mutated credential material'
  rm -f -- "$existing_vault_directory/vault.yml"
  cleanup_vault "$existing_vault_directory"

  existing_password_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
  : > "$existing_password_directory/password"
  if "$0" --output "$existing_password_directory/vault.yml" \
      --password-file "$existing_password_directory/password" >/dev/null 2>&1; then
    die 'self-test generation accepted a pre-existing password output'
  fi
  [ -f "$existing_password_directory/password" ] &&
    [ ! -e "$existing_password_directory/vault.yml" ] ||
    die 'self-test pre-existing password refusal mutated credential material'
  rm -f -- "$existing_password_directory/password"
  cleanup_vault "$existing_password_directory"

  vault_symlink_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
  ln -s /dev/null "$vault_symlink_directory/vault.yml"
  if "$0" --output "$vault_symlink_directory/vault.yml" \
      --password-file "$vault_symlink_directory/password" >/dev/null 2>&1; then
    die 'self-test generation accepted a vault output symlink'
  fi
  [ -L "$vault_symlink_directory/vault.yml" ] &&
    [ ! -e "$vault_symlink_directory/password" ] ||
    die 'self-test vault symlink refusal mutated credential material'
  rm -f -- "$vault_symlink_directory/vault.yml"
  cleanup_vault "$vault_symlink_directory"

  password_symlink_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
  ln -s /dev/null "$password_symlink_directory/password"
  if "$0" --output "$password_symlink_directory/vault.yml" \
      --password-file "$password_symlink_directory/password" >/dev/null 2>&1; then
    die 'self-test generation accepted a password output symlink'
  fi
  [ -L "$password_symlink_directory/password" ] &&
    [ ! -e "$password_symlink_directory/vault.yml" ] ||
    die 'self-test password symlink refusal mutated credential material'
  rm -f -- "$password_symlink_directory/password"
  cleanup_vault "$password_symlink_directory"

  unexpected_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
  : > "$unexpected_directory/unexpected"
  if "$0" --output "$unexpected_directory/vault.yml" \
      --password-file "$unexpected_directory/password" >/dev/null 2>&1; then
    die 'self-test generation accepted an unexpected entry'
  fi
  [ -f "$unexpected_directory/unexpected" ] &&
    [ ! -e "$unexpected_directory/vault.yml" ] &&
    [ ! -e "$unexpected_directory/password" ] ||
    die 'self-test unexpected-entry refusal mutated credential material'
  rm -f -- "$unexpected_directory/unexpected"
  cleanup_vault "$unexpected_directory"

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
  if "$0" --cleanup "$alias_path/" >/dev/null 2>&1; then
    die 'self-test cleanup accepted a trailing-slash symlink alias'
  fi
  [ -d "$canonical_directory" ] ||
    die 'self-test trailing-slash symlink refusal did not preserve its target'
  rm -f -- "$alias_path"

  lexical_component="$temporary_parent/nas-platform-vault.lexical.$$"
  mkdir "$lexical_component"
  for lexical_alias in \
    "$canonical_directory/." \
    "$temporary_parent//$(basename -- "$canonical_directory")" \
    "$lexical_component/../$(basename -- "$canonical_directory")"
  do
    if "$0" --cleanup "$lexical_alias" >/dev/null 2>&1; then
      die 'self-test cleanup accepted a non-normalized lexical alias'
    fi
    [ -d "$canonical_directory" ] ||
      die 'self-test lexical-alias refusal did not preserve its target'
  done
  rmdir -- "$lexical_component"
  cleanup_vault "$canonical_directory"

  trailing_slash_parent=$(mktemp -d "$temporary_parent/nas-platform-vault-tmp-parent.XXXXXX")
  trailing_slash_directory=$(mktemp -d "$trailing_slash_parent/nas-platform-vault.XXXXXX")
  if ! TMPDIR="$trailing_slash_parent/" "$0" --cleanup "$trailing_slash_directory" \
      >/dev/null 2>&1; then
    rmdir -- "$trailing_slash_directory" "$trailing_slash_parent"
    die 'self-test rejected an ordinary temporary parent with one trailing slash'
  fi
  rmdir -- "$trailing_slash_parent"

  tmpdir_alias="$temporary_parent/nas-platform-vault.tmpalias.$$"
  ln -s "$temporary_parent" "$tmpdir_alias"
  if TMPDIR="$tmpdir_alias" "$0" --self-test >/dev/null 2>&1; then
    die 'self-test accepted a symlink temporary parent'
  fi
  if TMPDIR="$tmpdir_alias/" "$0" --self-test >/dev/null 2>&1; then
    die 'self-test accepted a trailing-slash symlink temporary parent'
  fi
  rm -f -- "$tmpdir_alias"

  in_repo_directory=$(mktemp -d "$repo_dir/nas-platform-vault.XXXXXX")
  if TMPDIR="$repo_dir" "$0" --output "$in_repo_directory/vault.yml" \
      --password-file "$in_repo_directory/password" >/dev/null 2>&1; then
    die 'self-test generation accepted an in-repository directory'
  fi
  [ -z "$(find "$in_repo_directory" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    die 'self-test in-repository refusal left credential material'
  rmdir -- "$in_repo_directory"

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

  if [ "$(id -u)" -eq 0 ]; then
    foreign_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
    chown 65534 "$foreign_directory"
    if "$0" --output "$foreign_directory/vault.yml" \
        --password-file "$foreign_directory/password" >/dev/null 2>&1; then
      die 'self-test generation accepted a foreign-owned directory'
    fi
    [ -z "$(find "$foreign_directory" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
      die 'self-test foreign-ownership refusal left credential material'
    chown 0 "$foreign_directory"
    cleanup_vault "$foreign_directory"
  fi

  failure_directory=$(mktemp -d "$temporary_parent/nas-platform-vault.XXXXXX")
  fake_bin=$(mktemp -d "$temporary_parent/nas-platform-vault-tools.XXXXXX")
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$fake_bin/ansible-vault"
  chmod 0755 "$fake_bin/ansible-vault"
  if PATH="$fake_bin:$PATH" "$0" --output "$failure_directory/vault.yml" \
      --password-file "$failure_directory/password" >/dev/null 2>&1; then
    die 'self-test failure fixture unexpectedly generated credentials'
  fi
  [ -z "$(find "$failure_directory" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    die 'self-test failed generation left credential material'
  cleanup_vault "$failure_directory"
  rm -rf -- "$fake_bin"
}

case ${1:-} in
  --output)
    [ "$#" -eq 4 ] && [ "$3" = --password-file ] ||
      die 'usage: generate-ephemeral-vault.sh --output PATH --password-file PATH'
    generate_vault "$2" "$4"
    ;;
  --undeclared)
    [ "$#" -eq 6 ] && [ "$3" = --output ] && [ "$5" = --password-file ] ||
      die 'usage: generate-ephemeral-vault.sh --undeclared GROUP[,GROUP] --output PATH --password-file PATH'
    select_undeclared_credential_groups "$2"
    generate_vault "$4" "$6"
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
    die 'usage: generate-ephemeral-vault.sh [--undeclared GROUP[,GROUP]] --output PATH --password-file PATH | --cleanup DIRECTORY | --self-test'
    ;;
esac
