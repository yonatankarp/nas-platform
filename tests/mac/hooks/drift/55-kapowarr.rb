#!/usr/bin/env ruby
# Clear the Kapowarr login, which is the drift the Mac lane's reconcile repairs.
#
# usage: 55-kapowarr.rb   (no arguments; every input is an environment variable)
#
# tests/mac/hooks/drift/55-kapowarr.sh is the hook this belongs to. It requires
# PLATFORM_KAPOWARR_PORT, PLATFORM_MAC_VAULT_FILE and
# PLATFORM_MAC_VAULT_PASSWORD_FILE, runs this program, then runs verify.yml
# alone and insists it refuses the deployment with a fixed diagnostic. Only the
# mutation lives here.
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
