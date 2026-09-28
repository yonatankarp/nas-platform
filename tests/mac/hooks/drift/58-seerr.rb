#!/usr/bin/env ruby
# Turn Seerr's newPlexLogin on: the drift 58-seerr.sh verifies is refused (#315).
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
