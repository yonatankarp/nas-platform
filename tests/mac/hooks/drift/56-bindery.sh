#!/bin/sh
# Bindery's drift is a destination root, and it is the hand edit a person
# actually makes: the web interface offers a delete button beside every root
# folder, and removing the audiobook one is invisible everywhere else — the
# container stays healthy, the administrator still logs in, and imports simply
# fall back to the ebook library, which is the single-library collapse the
# design forbids.
#
# The identity is deliberately not the drift here. Bindery answers 500 to a
# duplicate user, refuses to delete its last administrator, and its login
# limiter answers 429 to the correct password after five failures, so a drifted
# identity is not a state a converge may repair by rewriting. A root folder is:
# the role reads the declared roots and creates only the missing ones.
#
# The lane requires that verification alone refuses the drifted deployment, and
# leaves it drifted for the reconcile phase to repair by converging.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_BINDERY_PORT:?PLATFORM_BINDERY_PORT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/bindery-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

PLATFORM_BINDERY_PORT=$PLATFORM_BINDERY_PORT \
PLATFORM_MAC_VAULT_FILE=$PLATFORM_MAC_VAULT_FILE \
PLATFORM_MAC_VAULT_PASSWORD_FILE=$PLATFORM_MAC_VAULT_PASSWORD_FILE \
  ruby - <<'RUBY'
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_BINDERY_PORT'), 10)}")
AUDIOBOOK_ROOT = "/data/media/Audiobooks"

def request(message)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(message) }
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_MAC_VAULT_PASSWORD_FILE"), ENV.fetch("PLATFORM_MAC_VAULT_FILE")
)
abort "bindery drift: encrypted vault could not be read" unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
headers = { "X-Api-Key" => vault.fetch("vault_bindery_api_key") }

listing = request(Net::HTTP::Get.new(URI.join(BASE, "/api/v1/rootfolder"), headers))
abort "bindery drift: the declared roots could not be read" unless listing.code == "200"
audiobook = JSON.parse(listing.body).find { |entry| entry["path"] == AUDIOBOOK_ROOT }
abort "bindery drift: the deployed audiobook root is not the platform's" if audiobook.nil?

removed = request(
  Net::HTTP::Delete.new(URI.join(BASE, "/api/v1/rootfolder/#{audiobook.fetch('id')}"), headers)
)
abort "bindery drift: the audiobook root could not be removed" unless removed.code == "204"
RUBY

if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_bindery >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Bindery destination root drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'owns exactly the declared ebook and audiobook destination roots' "$expected_failure" || {
  printf '%s\n' 'Bindery verification refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'Bindery drift: the removed audiobook root is rejected until the platform reconverges'
