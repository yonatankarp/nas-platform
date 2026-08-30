#!/bin/sh
# Kapowarr's drift is its identity, and unlike Pinchflat's it does not live in a
# file the platform renders: the application hashes both halves with a salt it
# generated at first start and keeps in its own database. The only hand edit
# that can be reproduced from outside is the one a person actually makes in the
# web interface — clearing the login — and it is also the dangerous one, because
# an unprotected Kapowarr hands its API key, and with it every route that
# renames or deletes comics, to anyone who can reach the port.
#
# The lane then requires that verification alone refuses the drifted deployment,
# and leaves it drifted for the reconcile phase to repair by converging.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_KAPOWARR_PORT:?PLATFORM_KAPOWARR_PORT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/kapowarr-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

PLATFORM_KAPOWARR_PORT=$PLATFORM_KAPOWARR_PORT \
PLATFORM_MAC_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_MAC_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  ruby - <<'RUBY'
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

base = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_KAPOWARR_PORT'), 10)}")

def post(base, path, payload)
  request = Net::HTTP::Post.new(URI.join(base, path), "Content-Type" => "application/json")
  request.body = JSON.generate(payload)
  Net::HTTP.start(base.host, base.port, read_timeout: 15) { |http| http.request(request) }
end

def put(base, path, payload)
  request = Net::HTTP::Put.new(URI.join(base, path), "Content-Type" => "application/json")
  request.body = JSON.generate(payload)
  Net::HTTP.start(base.host, base.port, read_timeout: 15) { |http| http.request(request) }
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_MAC_VAULT_PASSWORD_FILE"), ENV.fetch("PLATFORM_MAC_VAULT_FILE")
)
abort "kapowarr drift: encrypted vault could not be read" unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)

login = post(base, "/api/auth",
             "username" => vault.fetch("vault_kapowarr_admin_username"),
             "password" => vault.fetch("vault_kapowarr_admin_password"))
abort "kapowarr drift: the deployed identity is not the vault's" unless login.code == "200"
api_key = JSON.parse(login.body).fetch("result").fetch("api_key")

cleared = put(base, "/api/settings?api_key=#{api_key}",
              "auth_username" => "", "auth_password" => "")
abort "kapowarr drift: the login could not be cleared" unless cleared.code == "200"
RUBY

if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_kapowarr >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Kapowarr identity drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'no longer accepts exactly the vault-authored' "$expected_failure" || {
  printf '%s\n' 'Kapowarr verification refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'Kapowarr drift: the cleared login is rejected until the platform reconverges'
