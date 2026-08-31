#!/bin/sh
# Trailarr's drift is the one this whole role exists for, and it is a single
# click in the web interface: a settings toggle. Every global setting the
# application holds is a live os.getenv read, and every settings mutation is
# persisted into /config/.env, which scripts/start.sh sources with
# `set -o allexport` over the container environment at every start. So a toggle
# made by hand does not merely change the running process — it wins permanently,
# against the value Compose declares, on every restart from then on. Nothing
# else in this platform behaves that way, and no other hook would notice.
#
# create_missing_folders is the toggle chosen, because turning it on is the
# thing that makes Trailarr a creator of library directories inside trees Radarr
# and Sonarr own, and because the settings route reports failure with HTTP 200
# and prose in the body — so the hook reads the value back rather than trusting
# the status.
#
# The lane requires that verification alone refuses the drifted deployment, and
# leaves it drifted for the reconcile phase to repair by converging: the role
# removes the line and restarts, and the declared value returns.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_TRAILARR_PORT:?PLATFORM_TRAILARR_PORT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/trailarr-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

PLATFORM_TRAILARR_PORT=$PLATFORM_TRAILARR_PORT \
PLATFORM_MAC_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_MAC_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  ruby - <<'RUBY'
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_TRAILARR_PORT'), 10)}")

def request(message)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(message) }
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_MAC_VAULT_PASSWORD_FILE"), ENV.fetch("PLATFORM_MAC_VAULT_FILE")
)
abort "trailarr drift: encrypted vault could not be read" unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
key = vault.fetch("vault_trailarr_api_key")

settings = request(Net::HTTP::Get.new(URI.join(BASE, "/api/v1/settings/"), "X-API-KEY" => key))
abort "trailarr drift: the declared settings could not be read" unless settings.code == "200"
abort "trailarr drift: the deployed settings are not the platform's" unless
  JSON.parse(settings.body)["create_missing_folders"] == false

toggle = Net::HTTP::Put.new(
  URI.join(BASE, "/api/v1/settings/update"),
  "X-API-KEY" => key, "Content-Type" => "application/json"
)
toggle.body = JSON.dump("key" => "create_missing_folders", "value" => "true")
request(toggle)

# The route answers 200 with prose on failure, so the drift is confirmed by
# reading it back rather than by the status code.
confirmed = request(Net::HTTP::Get.new(URI.join(BASE, "/api/v1/settings/"), "X-API-KEY" => key))
abort "trailarr drift: the hand-made setting was not applied" unless
  confirmed.code == "200" && JSON.parse(confirmed.body)["create_missing_folders"] == true
RUBY

if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_trailarr >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Trailarr settings drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'declared settings to exactly the vault-authored identity' "$expected_failure" || {
  printf '%s\n' 'Trailarr verification refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'Trailarr drift: the hand-made setting is rejected until the platform reconverges'
