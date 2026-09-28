#!/usr/bin/env ruby
# Remove Bindery's audiobook root folder: the drift 56-bindery.sh verifies is refused (#315).
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
