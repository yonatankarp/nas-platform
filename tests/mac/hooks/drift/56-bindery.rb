#!/usr/bin/env ruby
# Remove Bindery's audiobook destination root, which is the drift the Mac lane's
# reconcile repairs.
#
# usage: 56-bindery.rb   (no arguments; every input is an environment variable)
#
# tests/mac/hooks/drift/56-bindery.sh is the hook this belongs to. It requires
# PLATFORM_BINDERY_PORT, PLATFORM_MAC_VAULT_FILE and
# PLATFORM_MAC_VAULT_PASSWORD_FILE, runs this program, then runs verify.yml
# alone and insists it refuses the deployment with a fixed diagnostic. Only the
# mutation lives here, and the hook's comment records why a root folder is the
# drift rather than the identity.
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
