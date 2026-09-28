#!/usr/bin/env ruby
# The upgrade lane's seed-and-verify half for Kapowarr (#773).
#
# usage: kapowarr-upgrade.rb (seed|verify)
#
# The seed rotates the application-generated API key and verify asserts a login
# still returns it: the only value in this store the platform cannot author, so a
# rebuilt store cannot reproduce it. Every other table is out of reach (ComicVine,
# the exact root-folder list, declared settings rewritten each converge, unprobed
# shapes); docs/dossier-kapowarr.md records the routes. The rotation is
# self-validating, and only a SHA-256 of the key is recorded.

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_KAPOWARR_READY_TIMEOUT", "120"), 10)
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_KAPOWARR_PORT'), 10)}")
RECORD = File.join(ENV.fetch("PLATFORM_REPORT_ROOT"), "upgrade-kapowarr.json")

def fail_contract(message)
  warn "Kapowarr upgrade contract failed: #{message}"
  exit 1
end

mode = ARGV[0]
fail_contract("expected seed or verify, got #{mode.inspect}") unless
  %w[seed verify].include?(mode)

def get(path)
  request = Net::HTTP::Get.new(URI.join(BASE, path))
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(request) }
end

def post(path, payload)
  request = Net::HTTP::Post.new(URI.join(BASE, path), "Content-Type" => "application/json")
  request.body = JSON.generate(payload)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(request) }
end

# An upgrade converge returns on healthy, a moment before the API answers.
def wait_for_readiness
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      return if get("/api/public").code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Kapowarr never answered its public endpoint") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

def vault_identity
  yaml, error, status = Open3.capture3(
    "ansible-vault", "view", "--vault-password-file",
    ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
    ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
  )
  fail_contract("encrypted vault could not be read") unless status.success?
  vault = YAML.safe_load(yaml)
  yaml.replace("\0" * yaml.bytesize)
  error.replace("\0" * error.bytesize)
  [vault.fetch("vault_kapowarr_admin_username"), vault.fetch("vault_kapowarr_admin_password")]
end

def login(username, password)
  response = post("/api/auth", "username" => username, "password" => password)
  fail_contract("Kapowarr refused the vault-authored administrator (HTTP #{response.code})") unless
    response.code == "200"
  key = JSON.parse(response.body).dig("result", "api_key")
  fail_contract("Kapowarr returned no API key to the vault administrator") unless
    key.is_a?(String) && key.match?(/\A[0-9a-f]{32}\z/)
  key
rescue JSON::ParserError
  fail_contract("Kapowarr did not answer JSON to a login")
end

wait_for_readiness
username, password = vault_identity
key = login(username, password)

case mode
when "seed"
  rotation = post("/api/settings/api_key?api_key=#{key}", {})
  rotated = login(username, password)
  # The rotation's status is not asserted; the stored value moving is the proof.
  fail_contract(
    "Kapowarr did not rotate its API key (the rotation answered HTTP #{rotation.code} and a " \
    "fresh login returned the same value), so this lane would have nothing the base image " \
    "wrote that the head image has to carry"
  ) if rotated == key
  FileUtils.mkdir_p(File.dirname(RECORD))
  File.write(RECORD, JSON.generate("api_key_sha256" => Digest::SHA256.hexdigest(rotated)))
  File.chmod(0o600, RECORD)
  puts "kapowarr upgrade seed: application API key rotated and recorded by digest"
when "verify"
  fail_contract("no Kapowarr upgrade seed record at #{RECORD}") unless File.file?(RECORD)

  expected = JSON.parse(File.read(RECORD)).fetch("api_key_sha256")
  observed = Digest::SHA256.hexdigest(key)
  fail_contract(
    "the API key the base image stored did not survive the migration: a login against the " \
    "head image returns a different value, so Kapowarr's config store was rebuilt rather " \
    "than migrated"
  ) unless observed == expected
  puts "kapowarr upgrade verify: the rotated application API key survived the migration"
end
