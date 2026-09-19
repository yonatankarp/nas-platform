#!/usr/bin/env ruby
# The upgrade lane's seed-and-verify half for Kapowarr: a value written into
# Kapowarr's own store through its own HTTP API while the BASE pin is serving,
# and read back once the head pin has opened and migrated that store.
#
# usage: kapowarr-upgrade.rb (seed|verify)
#
# WHY THE API KEY, WHICH IS NOT THE OBVIOUS CHOICE.
#
# The seed has to be a real row, it has to survive the SECOND converge, and its
# request shape has to be known to work at the pinned version. Kapowarr's
# surface is unusually hostile to all three at once:
#
#   * Volumes are the natural payload and they need a ComicVine key, which
#     roles/kapowarr deliberately refuses to take on because it cannot be proved
#     in any disposable lane.
#   * A second root folder is refused by the role itself -- "Refuse a Kapowarr
#     deployment still holding a superseded library root" -- so seeding one
#     would red the upgrade converge for a reason that has nothing to do with
#     the migration.
#   * Every settings key the role declares is written back on the next converge,
#     so a surviving value and a re-written one would be indistinguishable.
#
# What is left is the one value in this service that the application generates
# and the platform provably does not author. docs/dossier-kapowarr.md records it:
# `PUT /api/settings {"api_key": ...}` is refused with InvalidSettingModification
# naming `POST /settings/api_key` instead, that route rotates the key to a new
# random value, `POST /api/auth` returns the current one on a successful login,
# and "only an explicit rotation changes it" -- all Confirmed against a running
# container at this pin.
#
# So the seed rotates the key, and the verify asserts the rotated value is still
# what a login returns. A store that was rebuilt rather than migrated cannot
# reproduce it: the value is random, it is not in the vault, and nothing in this
# platform can put it back.
#
# The rotation is also SELF-VALIDATING, which is what lets this program depend on
# no response shape at all. It reads the key by logging in, rotates, logs in
# again, and refuses unless the value actually changed. A route that answered a
# status this program did not expect, or that has moved at some future pin,
# fails there and says so, rather than recording a key that was never rotated.
#
# WHAT IS RECORDED IS A DIGEST, NOT THE KEY. The key authorizes every route that
# renames or deletes comics, and the record file outlives both container
# invocations inside the sandbox. A SHA-256 compares exactly as well.
#
# WHAT VERIFY PROVES, AND WHAT IT DOES NOT. It proves one row the base image
# wrote is still readable after the head image opened the store. It does not
# prove anything about the rows this seeder did not write, and it cannot -- that
# is the second of the three limits issue #773 states, narrowed rather than
# closed.

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_KAPOWARR_READY_TIMEOUT", "120"), 10)
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_KAPOWARR_PORT'), 10)}")
# tests/integration.sh creates $sandbox/reports at mode 0777 and run_contract
# exports it as PLATFORM_REPORT_ROOT, so this directory exists for the one
# caller there is. The mkdir below is still taken: nothing that runs outside a
# real lane exercises this write, so a caller that set the variable somewhere
# else would find out only after a full base converge.
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

# The same gate the runtime contract uses. An upgrade converge returns as soon as
# Compose reports the container healthy, and the API is reachable a moment later.
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

# The only way to obtain the key. An authentication exchange rather than a
# configuration read-back, which is why roles/kapowarr uses it too.
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
  # The rotation's own status is reported rather than asserted: what makes the
  # seed valid is that the stored value moved, and a route that answered
  # something unexpected shows up here as a key that did not.
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
