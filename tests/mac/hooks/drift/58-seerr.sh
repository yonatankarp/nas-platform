#!/bin/sh
# Seerr's drift is one toggle in the web interface, and it is the toggle the
# whole permission design rests on. newPlexLogin ships true, and with it true
# any Jellyfin user who signs in is silently created in Seerr holding
# defaultPermissions — which is how "newly discovered Jellyfin users do not
# inherit these permissions automatically" stops being true without anybody
# deleting a rule or editing a file.
#
# It is chosen over the other candidates because it is invisible: nothing about
# the running service looks different afterwards, no container restarts, and
# the only place it shows is a field in the anonymous public settings. A hook
# that toggled a Radarr row instead would be caught by the arr reconcile
# anyway.
#
# The lane requires that verification alone refuses the drifted deployment, and
# leaves it drifted for the reconcile phase to repair by converging: the role
# compares the declared subset of the main settings and posts on drift.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_SEERR_PORT:?PLATFORM_SEERR_PORT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/seerr-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

PLATFORM_SEERR_PORT=$PLATFORM_SEERR_PORT \
PLATFORM_MAC_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_MAC_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  ruby - <<'RUBY'
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_SEERR_PORT'), 10)}")

def request(message)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 20) { |http| http.request(message) }
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_MAC_VAULT_PASSWORD_FILE"), ENV.fetch("PLATFORM_MAC_VAULT_FILE")
)
abort "seerr drift: encrypted vault could not be read" unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
key = vault.fetch("vault_seerr_api_key")

public_settings = JSON.parse(request(Net::HTTP::Get.new(URI.join(BASE, "/api/v1/settings/public"))).body)
abort "seerr drift: the deployed sign-in policy is not the platform's" unless
  public_settings["newPlexLogin"] == false

# POST /api/v1/settings/main is a deep merge, so this changes exactly the one
# field and leaves the API key and everything else beside it intact.
toggle = Net::HTTP::Post.new(
  URI.join(BASE, "/api/v1/settings/main"), "X-Api-Key" => key, "Content-Type" => "application/json"
)
toggle.body = JSON.dump("newPlexLogin" => true)
abort "seerr drift: the hand-made setting was refused" unless request(toggle).code == "200"

confirmed = JSON.parse(request(Net::HTTP::Get.new(URI.join(BASE, "/api/v1/settings/public"))).body)
abort "seerr drift: the hand-made setting was not applied" unless
  confirmed["newPlexLogin"] == true
RUBY

if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_seerr >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Seerr sign-in policy drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'sign-in policy' "$expected_failure" || {
  printf '%s\n' 'Seerr verification refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'Seerr drift: the hand-made sign-in policy is rejected until the platform reconverges'
