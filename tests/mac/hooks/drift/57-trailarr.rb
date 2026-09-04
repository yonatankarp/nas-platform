#!/usr/bin/env ruby
# Turn Trailarr's create_missing_folders on by hand, which is the drift the Mac
# lane's reconcile repairs.
#
# usage: 57-trailarr.rb   (no arguments; every input is an environment variable)
#
# tests/mac/hooks/drift/57-trailarr.sh is the hook this belongs to. It requires
# PLATFORM_TRAILARR_PORT, PLATFORM_MAC_VAULT_FILE and
# PLATFORM_MAC_VAULT_PASSWORD_FILE, runs this program, then runs verify.yml
# alone and insists it refuses the deployment with a fixed diagnostic. Only the
# mutation lives here, and the hook's comment records why a settings toggle is
# the one drift no other hook would notice.
#
# The settings route reports failure with HTTP 200 and prose in the body, which
# is why the toggle is confirmed by reading it back rather than by its status.
#
# It ran from a `<<'RUBY'` heredoc in that hook until #315, opened as a bare
# `ruby -` with no `-r` preloads, where nothing syntax-checked it, no linter
# reached it and no reader could open it. The body below is byte-identical to
# what that heredoc rendered, its own requires included, and the hook resolves
# it from its own checkout rather than from any tree under inspection.
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
