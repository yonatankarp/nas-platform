#!/usr/bin/env ruby
# Clear the Kapowarr login: the drift 55-kapowarr.sh verifies is refused (#315).
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
