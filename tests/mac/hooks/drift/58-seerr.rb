#!/usr/bin/env ruby
# Turn Seerr's newPlexLogin on by hand, which is the drift the Mac lane's
# reconcile repairs.
#
# usage: 58-seerr.rb   (no arguments; every input is an environment variable)
#
# tests/mac/hooks/drift/58-seerr.sh is the hook this belongs to. It requires
# PLATFORM_SEERR_PORT, PLATFORM_MAC_VAULT_FILE and
# PLATFORM_MAC_VAULT_PASSWORD_FILE, runs this program, then runs verify.yml
# alone and insists it refuses the deployment with a fixed diagnostic. Only the
# mutation lives here, and the hook's comment records why this toggle is the one
# the whole permission design rests on.
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
