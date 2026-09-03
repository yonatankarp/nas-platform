#!/usr/bin/env ruby
# The runtime half of the Bindery service contract: what can only be decided
# against a deployed Bindery, its SQLite database and the encrypted vault.
#
# usage: bindery-runtime.rb
#
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = 120
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_BINDERY_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_BINDERY_CONTAINER")
USENET = ENV.fetch("PLATFORM_BINDERY_USENET") == "true"
# Bindery's whole state is one SQLite database beneath the declared config root.
# It is what has to survive a container recreation, and its absence is what a
# wrongly owned or wrongly mounted config bind looks like.
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
# The image is distroless and has no shell, so this is also the proof that the
# probe is the binary's own subcommand rather than a CMD-SHELL that can never run.
fail_contract("the Bindery container is not healthy") unless state.strip == "healthy"

# The first-run setup route is anonymous until any user exists and answers 409
# to everyone afterwards. A 200 here would mean the platform had left the
# administrator account open to whoever reached the port first, permanently.
setup = post("/api/v1/auth/setup",
             "username" => "contract-should-never-win", "password" => "contract-password")
fail_contract("Bindery left its first-run setup open") unless setup.code == "409"

auth_status = parsed(get("/api/v1/auth/status"), "auth status")
# local-only grants administrator to every private-network peer with no
# credential, and an administrator may read the API key in clear.
fail_contract("Bindery does not enforce authentication") unless auth_status["mode"] == "enabled"
fail_contract("Bindery still reports first-run setup as required") if auth_status["setupRequired"]

# The refusal probe is a credential-free read of a protected route. It is never
# a wrong password: the login limiter records five failures per fifteen minutes
# per IP and then answers 429 to the correct password too.
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

# The seed is honoured only while the stored key is absent, so a deployment that
# converged is holding exactly the key the vault authored.
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
# Two roots, not one: an audiobook root that fell back to the ebook root is the
# single-library collapse the design forbids, and it looks identical everywhere
# else.
fail_contract("Bindery does not own exactly the declared ebook and audiobook roots") unless
  declared.sort == LIBRARY_ROOTS.sort

# The image is distroless, starts as no one privileged and has no shell, so it
# cannot repair a wrongly owned directory. This is where that becomes a named
# failure rather than a permission-denied import weeks later.
storage = parsed(get("/api/v1/system/storage", key_headers), "storage")
%w[download library audiobook audiobook-download].each do |name|
  entry = storage.fetch("dirs", []).find { |dir| dir["name"] == name }
  fail_contract("Bindery reports no #{name} directory") if entry.nil?
  fail_contract("Bindery cannot write its #{name} directory at #{entry['path']}") unless
    entry["exists"] && entry["writable"]
end
# Bindery links a probe file from each staging root into the library it feeds and
# reports whether it worked. rename(2) and link(2) refuse to cross a mount
# boundary even when both sides are one filesystem, so mounting a library and its
# staging directory separately makes every import a full byte copy while every
# other reading above stays identical. The reason string is the diagnosis.
unless storage["hardlinkable"] == true
  reason = storage.fetch("hardlinkReason", "no reason reported")
  fail_contract("Bindery cannot hardlink from its staging roots into its libraries: #{reason}")
end

settings = parsed(get("/api/v1/setting", key_headers), "settings")
   .to_h { |entry| [entry.fetch("key"), entry.fetch("value")] }
# The auto-grab kill switch fails open, so an absent row means unattended
# grabbing is on.
{ "autoGrab.enabled" => "false", "telemetry.enabled" => "false" }.each do |key, value|
  fail_contract("Bindery does not pin #{key} to #{value}") unless settings[key] == value
end

instances = parsed(get("/api/v1/prowlarr", key_headers), "prowlarr instances")
clients = parsed(get("/api/v1/downloadclient", key_headers), "download clients")
# A repeated create answers 201 and adds a second row rather than failing, so
# the count is the property that a converged reconciliation has to hold.
fail_contract("Bindery holds duplicate Prowlarr instances") if instances.length > 1
fail_contract("Bindery holds duplicate download clients") if clients.length > 1

if USENET
  instance = instances.first
  fail_contract("Bindery declared no Prowlarr instance") if instance.nil?
  fail_contract("Bindery does not reach Prowlarr by its control-network alias") unless
    instance["url"] == "http://prowlarr:9696"
  # Credentials are write-only in every response, so a stored key can be proved
  # present and never proved correct.
  fail_contract("Bindery stored no Prowlarr credential") unless instance["apiKeyConfigured"]
  fail_contract("Bindery disabled its Prowlarr instance") unless instance["enabled"]

  client = clients.first
  fail_contract("Bindery declared no download client") if client.nil?
  fail_contract("Bindery does not reach SABnzbd by its control-network alias") unless
    client["type"] == "sabnzbd" && client["host"] == "sabnzbd" && client["port"] == 8080
  fail_contract("Bindery stored no SABnzbd credential") unless client["apiKeyConfigured"]
  # One client serves both libraries only because the two categories differ.
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
