#!/usr/bin/env ruby
# Runtime half of the Bindery contract: deployed Bindery, its SQLite database
# and the encrypted vault. usage: bindery-runtime.rb
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = 120
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_BINDERY_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_BINDERY_CONTAINER")
USENET = ENV.fetch("PLATFORM_BINDERY_USENET") == "true"
# The whole state; absent means a wrongly owned or mounted config bind.
DATABASE = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "bindery", "config", "bindery.db")
LIBRARY_ROOTS = ["/data/books/Ebooks", "/data/media/Audiobooks"].freeze

def fail_contract(message)
  warn "Bindery contract failed: #{message}"
  exit 1
end

def request(message)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(message) }
end

def get(path, headers = {})
  request(Net::HTTP::Get.new(URI.join(BASE, path), headers))
end

def post(path, payload, headers = {})
  message = Net::HTTP::Post.new(URI.join(BASE, path),
                                headers.merge("Content-Type" => "application/json"))
  message.body = JSON.generate(payload)
  request(message)
end

def parsed(response, what)
  JSON.parse(response.body)
rescue JSON::ParserError
  fail_contract("Bindery did not answer JSON for #{what}")
end

def wait_for_readiness
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = get("/api/v1/health")
      return response if response.code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Bindery never answered its health endpoint") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

health = parsed(wait_for_readiness, "health")
fail_contract("Bindery did not report itself healthy") unless health["status"] == "ok"

state, _error, status = Open3.capture3(
  "docker", "inspect", CONTAINER, "--format", "{{.State.Health.Status}}"
)
fail_contract("the Bindery container could not be inspected") unless status.success?
# Distroless with no shell, so healthy also proves the probe is the binary's own.
fail_contract("the Bindery container is not healthy") unless state.strip == "healthy"

# Setup is anonymous until a user exists, then 409; 200 means the admin was left open.
setup = post("/api/v1/auth/setup",
             "username" => "contract-should-never-win", "password" => "contract-password")
fail_contract("Bindery left its first-run setup open") unless setup.code == "409"

auth_status = parsed(get("/api/v1/auth/status"), "auth status")
# local-only grants admin to every private-network peer without a credential.
fail_contract("Bindery does not enforce authentication") unless auth_status["mode"] == "enabled"
fail_contract("Bindery still reports first-run setup as required") if auth_status["setupRequired"]

# Never a wrong password: the login limiter would then 429 the correct one too.
fail_contract("Bindery served a protected route to an unauthenticated caller") unless
  get("/api/v1/rootfolder").code == "401"
fail_contract("Bindery served its OPDS catalogue to an unauthenticated caller") unless
  get("/opds/").code == "401"

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
username = vault.fetch("vault_bindery_admin_username")
password = vault.fetch("vault_bindery_admin_password")
seeded_key = vault.fetch("vault_bindery_api_key")

login = post("/api/v1/auth/login", "username" => username, "password" => password)
fail_contract("Bindery refused the vault-authored administrator") unless login.code == "200"
cookie = login.get_fields("set-cookie").to_a.map { |value| value.split(";", 2).first }.join("; ")
fail_contract("Bindery issued no session to the vault administrator") if cookie.empty?

# The seed applies only while no key is stored.
config = parsed(get("/api/v1/auth/config", "Cookie" => cookie), "auth config")
fail_contract("Bindery is not holding the vault-authored API key") unless
  config["apiKey"] == seeded_key
key_headers = { "X-Api-Key" => seeded_key }

users = parsed(get("/api/v1/auth/users", key_headers), "users")
administrators = users.select { |user| user["username"] == username && user["role"] == "admin" }
fail_contract("Bindery does not hold exactly one vault-authored administrator") unless
  administrators.length == 1

roots = get("/api/v1/rootfolder", key_headers)
fail_contract("Bindery refused to list its destination roots") unless roots.code == "200"
declared = parsed(roots, "root folders").map { |entry| entry.fetch("path") }
# Two roots: a fallback to one is the forbidden single-library collapse.
fail_contract("Bindery does not own exactly the declared ebook and audiobook roots") unless
  declared.sort == LIBRARY_ROOTS.sort

# Distroless and unprivileged, it cannot repair ownership; fail here by name.
storage = parsed(get("/api/v1/system/storage", key_headers), "storage")
%w[download library audiobook audiobook-download].each do |name|
  entry = storage.fetch("dirs", []).find { |dir| dir["name"] == name }
  fail_contract("Bindery reports no #{name} directory") if entry.nil?
  fail_contract("Bindery cannot write its #{name} directory at #{entry['path']}") unless
    entry["exists"] && entry["writable"]
end
# link(2) refuses to cross a mount boundary, so separate mounts turn every import
# into a full copy; the reason string is the diagnosis.
unless storage["hardlinkable"] == true
  reason = storage.fetch("hardlinkReason", "no reason reported")
  fail_contract("Bindery cannot hardlink from its staging roots into its libraries: #{reason}")
end

settings = parsed(get("/api/v1/setting", key_headers), "settings")
   .to_h { |entry| [entry.fetch("key"), entry.fetch("value")] }
# Written to revert a manual disable; an absent row already reads as enabled.
{ "autoGrab.enabled" => "true", "telemetry.enabled" => "false" }.each do |key, value|
  fail_contract("Bindery does not pin #{key} to #{value}") unless settings[key] == value
end

instances = parsed(get("/api/v1/prowlarr", key_headers), "prowlarr instances")
clients = parsed(get("/api/v1/downloadclient", key_headers), "download clients")
# A repeated create adds a second row rather than failing.
fail_contract("Bindery holds duplicate Prowlarr instances") if instances.length > 1
fail_contract("Bindery holds duplicate download clients") if clients.length > 1

if USENET
  instance = instances.first
  fail_contract("Bindery declared no Prowlarr instance") if instance.nil?
  fail_contract("Bindery does not reach Prowlarr by its control-network alias") unless
    instance["url"] == "http://prowlarr:9696"
  # Credentials are write-only: presence is provable, correctness is not.
  fail_contract("Bindery stored no Prowlarr credential") unless instance["apiKeyConfigured"]
  fail_contract("Bindery disabled its Prowlarr instance") unless instance["enabled"]

  client = clients.first
  fail_contract("Bindery declared no download client") if client.nil?
  fail_contract("Bindery does not reach SABnzbd by its control-network alias") unless
    client["type"] == "sabnzbd" && client["host"] == "sabnzbd" && client["port"] == 8080
  fail_contract("Bindery stored no SABnzbd credential") unless client["apiKeyConfigured"]
  fail_contract("Bindery collapsed its ebook and audiobook download categories") unless
    client["category"] == "ebooks" && client["categoryAudiobook"] == "audiobooks"
  fail_contract("Bindery disabled its download client") unless client["enabled"]
else
  fail_contract("Bindery declared a Prowlarr instance with the transport disabled") unless
    instances.empty?
  fail_contract("Bindery declared a download client with the transport disabled") unless
    clients.empty?
end

fail_contract("Bindery did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

puts "bindery contract: health, closed first-run setup, exclusive administrator identity, " \
     "two-root ownership, writable storage, pinned settings and persisted state hold"
