#!/usr/bin/env ruby
# The runtime half of the Komga service contract: everything that needs a
# served Komga, an encrypted vault and a container to inspect.
#
# usage: komga-runtime.rb MODE [ARGS...]
#
# Every input arrives in the environment tests/contracts/komga.sh exports.
# Run it through that wrapper rather than directly.
require "json"
require "fileutils"
require "net/http"
require "open3"
require "pathname"
require "timeout"
require "uri"
require "yaml"
require "zlib"

MODE = ARGV.fetch(0)
FIXTURE_SCAN_TIMEOUT_SECONDS = 240
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_KOMGA_PORT'), 10)}")
KOMGA_CONTAINER = ENV.fetch("PLATFORM_KOMGA_CONTAINER")
DOCKER_HEALTH_REQUIRED = { "true" => true, "false" => false }.fetch(
  ENV.fetch("PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED")
)
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
LIBRARY_NAME = "Comics"
COMICS_ROOT = "/data/Comics"
EBOOKS_ROOT = "/data/Ebooks"
# The exact two-library model. The pre-migration state this lane can install is
# one Comics library at /data, which is the state the role refuses to repoint
# without komga_library_root_migration_allowed.
LIBRARY_MODEL = [
  { "name" => "Comics", "root" => COMICS_ROOT },
  { "name" => "Ebooks", "root" => EBOOKS_ROOT }
].freeze
LEGACY_LIBRARY_ROOT = "/data"
LEGACY_LIBRARY_NAME = "Books"
UNRELATED_LIBRARY_NAME = "Komga Contract Reference"
UNRELATED_LIBRARY_ROOT = "/config/.nas-platform-unmanaged"
LIBRARY_FILESYSTEM_ROOT = Pathname.new(
  ENV.fetch("PLATFORM_KOMGA_LIBRARY_PATH", MEDIA_ROOT.join("Books").to_s)
).expand_path
FIXTURE_RELATIVE = Pathname.new("Comics/task-10-contract-comic/Task 10 Contract Comic.cbz")
FIXTURE_PATH = LIBRARY_FILESYSTEM_ROOT.join(FIXTURE_RELATIVE)
FIXTURE_LIBRARY_URL = "/data/Comics/task-10-contract-comic/Task 10 Contract Comic.cbz"
STATE_PATH = REPORT_ROOT.join("komga-persistence.json")
MANAGED_SETTINGS = {
  "scanInterval" => "HOURLY",
  "scanDirectoryExclusions" => [".acquisition"],
  "scanOnStartup" => false,
  "scanCbx" => true,
  "scanPdf" => true,
  "scanEpub" => true,
  "repairExtensions" => false,
  "convertToCbz" => false,
  "emptyTrashAfterScan" => false,
  "hashFiles" => true,
  "hashPages" => false,
  "hashKoreader" => false,
  "analyzeDimensions" => true
}.freeze

def fail_contract(message)
  warn "Komga contract failed: #{message}"
  exit 1
end

def normalized_library_root(value)
  return nil unless value.is_a?(String)

  value.sub(%r{/+\z}, "")
end

def safe_library_id?(value)
  value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/)
end

def resolve_library(libraries, expected_name, expected_root)
  fail_contract("library listing schema differs") unless libraries.is_a?(Array)
  root_matches = libraries.select do |entry|
    entry.is_a?(Hash) && normalized_library_root(entry["root"]) == expected_root
  end
  name_matches = libraries.select do |entry|
    entry.is_a?(Hash) && entry["name"].is_a?(String) && entry["name"] == expected_name
  end
  candidates = root_matches + name_matches
  fail_contract("managed library candidate schema differs") unless candidates.all? do |entry|
    entry["name"].is_a?(String) && !entry.fetch("name").empty? &&
      entry["root"].is_a?(String) && !entry.fetch("root").empty? && safe_library_id?(entry["id"])
  end
  fail_contract("managed library root is absent or duplicated") unless root_matches.length == 1
  fail_contract("managed library name is absent, duplicated, or bound elsewhere") unless
    name_matches.length == 1 && name_matches.fetch(0).fetch("id") == root_matches.fetch(0).fetch("id")
  root_matches.fetch(0)
end

def endpoint(path)
  URI.join(BASE.to_s, path)
end

def request(method, path, basic: nil, body: nil, expected: [200])
  uri = endpoint(path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request.basic_auth(*basic) if basic
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
    http.request(request)
  end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless
    expected.include?(response.code.to_i)
  parsed = response.body.to_s.empty? ? nil : JSON.parse(response.body)
  [response, parsed]
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

def wait_for_api
  deadline = Time.now + 120
  loop do
    uri = endpoint("/actuator/health")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    payload = JSON.parse(response.body)
    return if response.code.to_i == 200 && payload.is_a?(Hash) && payload["status"] == "UP"
  rescue JSON::ParserError, SystemCallError, Timeout::Error
    fail_contract("Komga API did not become ready") if Time.now >= deadline
    sleep 1
  else
    fail_contract("Komga API did not become ready") if Time.now >= deadline
    sleep 1
  end
end

def wait_for_container_health
  deadline = Time.now + 180
  loop do
    stdout, _stderr, status = Open3.capture3(
      "docker", "inspect", "--format", "{{.State.Health.Status}}", KOMGA_CONTAINER
    )
    return if status.success? && stdout.strip == "healthy"
    fail_contract("#{KOMGA_CONTAINER} did not become healthy") if Time.now >= deadline
    sleep 2
  end
end

def require_absent_container_healthcheck
  stdout, _stderr, status = Open3.capture3(
    "docker", "inspect", "--format",
    "{{if .State.Health}}present{{else}}absent{{end}}", KOMGA_CONTAINER
  )
  fail_contract("#{KOMGA_CONTAINER} unexpectedly defines a Docker healthcheck") unless
    status.success? && stdout.strip == "absent"
end

def png_bytes
  signature = "\x89PNG\r\n\x1a\n".b
  chunk = lambda do |kind, data|
    [data.bytesize].pack("N") + kind + data + [Zlib.crc32(kind + data)].pack("N")
  end
  raw = "\x00".b + [255, 255, 255, 255].pack("C4")
  signature + chunk.call("IHDR", [1, 1, 8, 6, 0, 0, 0].pack("NNCCCCC")) +
    chunk.call("IDAT", Zlib.deflate(raw)) + chunk.call("IEND", "".b)
end

def zip_single_file(name, contents)
  crc = Zlib.crc32(contents)
  local = [0x04034b50, 20, 0, 0, 0, 0, crc, contents.bytesize, contents.bytesize,
           name.bytesize, 0].pack("VvvvvvVVVvv") + name + contents
  central = [0x02014b50, 20, 20, 0, 0, 0, 0, crc, contents.bytesize, contents.bytesize,
             name.bytesize, 0, 0, 0, 0, 0, 0].pack("VvvvvvvVVVvvvvvVV") + name
  local + central + [0x06054b50, 0, 0, 1, 1, central.bytesize, local.bytesize, 0].pack("VvvvvVVv")
end

def seed_fixture
  directory = FIXTURE_PATH.dirname
  directory.mkpath
  bytes = zip_single_file("001.png", png_bytes)
  if FIXTURE_PATH.exist?
    fail_contract("comic fixture bytes drifted") unless FIXTURE_PATH.file? && FIXTURE_PATH.binread == bytes
  else
    FIXTURE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) }
  end
end

if MODE == "seed-fixture-only"
  seed_fixture
  puts "Komga comic fixture prepared before deployment"
  exit 0
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
credentials = [vault.fetch("vault_komga_admin_email"), vault.fetch("vault_komga_admin_password")]

if DOCKER_HEALTH_REQUIRED
  wait_for_container_health
else
  require_absent_container_healthcheck
end
wait_for_api
request("get", "/api/v2/users/me", basic: [credentials.first, "contract-wrong-password"], expected: [401])
_me_response, me = request("get", "/api/v2/users/me", basic: credentials)
fail_contract("vault administrator identity or role differs") unless
  me.fetch("email") == credentials.first && Array(me.fetch("roles")).include?("ADMIN")

_libraries_response, libraries = request("get", "/api/v1/libraries", basic: credentials)

# Collapse the converged model back to the single pre-migration library, so the
# lane can prove that a plain converge refuses the root move and that the run
# carrying komga_library_root_migration_allowed completes it.
if MODE == "migration-legacy"
  comics = resolve_library(libraries, LIBRARY_NAME, COMICS_ROOT)
  ebooks = resolve_library(libraries, "Ebooks", EBOOKS_ROOT)
  request(
    "delete", "/api/v1/libraries/#{ebooks.fetch('id')}", basic: credentials, expected: [204]
  )
  request(
    "patch", "/api/v1/libraries/#{comics.fetch('id')}", basic: credentials,
    body: { "root" => LEGACY_LIBRARY_ROOT, "scanInterval" => "DISABLED",
            "scanDirectoryExclusions" => [] },
    expected: [204]
  )
  File.write(REPORT_ROOT.join("komga-migration-legacy-id").to_s, comics.fetch("id"))
  puts "Komga pre-migration single-library state installed"
  exit
end

if MODE == "migration-legacy-verify"
  legacy = resolve_library(libraries, LIBRARY_NAME, LEGACY_LIBRARY_ROOT)
  fail_contract("the pre-migration library was not installed") unless
    legacy.fetch("scanInterval") == "DISABLED"
  fail_contract("the Ebooks library survived the pre-migration collapse") if
    libraries.any? { |entry| entry.is_a?(Hash) && entry["name"] == "Ebooks" }
  puts "Komga pre-migration single-library state is present"
  exit
end

comics_name = MODE == "drift-verify" ? LEGACY_LIBRARY_NAME : LIBRARY_NAME
library = resolve_library(libraries, comics_name, COMICS_ROOT)
if MODE == "drift-verify"
  fail_contract("Komga drift fixture was not installed") unless
    library.fetch("name") == LEGACY_LIBRARY_NAME && library.fetch("scanOnStartup") == true
  puts "Komga library drift is present"
  exit
end

ebooks_library = resolve_library(libraries, "Ebooks", EBOOKS_ROOT)
LIBRARY_MODEL.zip([library, ebooks_library]).each do |expected, actual|
  fail_contract("managed library #{expected.fetch('name')} is not at its declared root") unless
    actual.fetch("name") == expected.fetch("name") &&
    normalized_library_root(actual.fetch("root")) == expected.fetch("root")
  MANAGED_SETTINGS.each do |key, value|
    fail_contract("managed library setting #{key} differs on #{expected.fetch('name')}") unless
      actual.fetch(key) == value
  end
end

if MODE == "drift"
  request(
    "patch", "/api/v1/libraries/#{library.fetch('id')}", basic: credentials,
    body: { "name" => LEGACY_LIBRARY_NAME, "scanOnStartup" => true }, expected: [204]
  )
  puts "Komga library drift installed"
  exit
end

if MODE == "migration-verify"
  legacy_id_path = REPORT_ROOT.join("komga-migration-legacy-id")
  fail_contract("the pre-migration library identifier was not recorded") unless
    legacy_id_path.file? && !legacy_id_path.symlink?
  fail_contract("the migration replaced the Comics library instead of repointing it") unless
    library.fetch("id") == legacy_id_path.read.strip
  legacy_id_path.unlink
  puts "Komga library root migration completed in place"
  exit
end

if MODE == "run"
  puts "Komga login and library contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

if MODE == "seed"
  seed_fixture unless ENV.fetch("PLATFORM_KOMGA_FIXTURE_PRESEEDED") == "true"
  request("post", "/api/v1/libraries/#{library.fetch('id')}/scan", basic: credentials, expected: [202])
end

deadline = Time.now + FIXTURE_SCAN_TIMEOUT_SECONDS
books = nil
loop do
  _books_response, payload = request(
    "get", "/api/v1/books?unpaged=true&library_id=#{URI.encode_www_form_component(library.fetch('id'))}",
    basic: credentials
  )
  books = payload.fetch("content")
  break if books.any? { |book| book.fetch("url", "") == FIXTURE_LIBRARY_URL }
  fail_contract("comic fixture was not scanned") if Time.now >= deadline
  sleep 2
end

library_state = {
  "libraries" => [library, ebooks_library].map do |entry|
    {
      "id" => entry.fetch("id"),
      "name" => entry.fetch("name"),
      "root" => normalized_library_root(entry.fetch("root")),
      "settings" => entry.reject { |key, _value| %w[id name root unavailable].include?(key) }
                         .sort.to_h
    }
  end,
  "unrelated" => libraries.filter_map do |entry|
    next unless entry.is_a?(Hash) && entry["name"] == UNRELATED_LIBRARY_NAME

    { "id" => entry.fetch("id"), "name" => entry.fetch("name"), "root" => entry.fetch("root") }
  end
}
case MODE
when "seed"
  fail_contract("report root is unavailable or unsafe") unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace Komga persistence artifact") if STATE_PATH.exist? || STATE_PATH.symlink?
  STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(library_state))
  end
  puts "Komga fixture, library identity, and settings seeded"
when "assert-persistence"
  fail_contract("Komga persistence artifact is unavailable or unsafe") unless STATE_PATH.file? && !STATE_PATH.symlink?
  snapshot = JSON.parse(STATE_PATH.binread)
  fail_contract("Komga managed library identifiers changed across recreation") unless
    snapshot.fetch("libraries").map { |entry| entry.fetch("id") } ==
      library_state.fetch("libraries").map { |entry| entry.fetch("id") }
  fail_contract("Komga managed library names, roots or settings changed across recreation") unless
    snapshot.fetch("libraries") == library_state.fetch("libraries")
  snapshot.fetch("unrelated").each do |expected|
    fail_contract("unrelated Komga library did not survive recreation") unless
      libraries.any? do |entry|
        entry.is_a?(Hash) && entry.values_at("id", "name", "root") ==
          expected.values_at("id", "name", "root")
      end
  end
  puts "Komga library ID, settings, unrelated state, and scanned comic persisted"
end
