#!/usr/bin/env ruby
# Turn AdGuard's protection off through its own control API, which is the drift
# the Mac lane's reconcile repairs.
#
# usage: 95-adguard.rb   (no arguments; every input is an environment variable)
#
# tests/mac/hooks/drift/95-adguard.sh is the hook this belongs to. It runs this
# program and then insists the AdGuard contract refuses the drifted deployment.
# Only the mutation lives here.
#
# WHY THIS SETTING. roles/adguard owns the whole of AdGuardHome.yaml -- the
# service has no second configuration surface -- so any setting the web
# interface can change is a candidate. `protection_enabled` is the one worth
# drifting because it is the setting that turns the service into a plain
# forwarder while leaving every status endpoint answering 200, and because the
# contract carries a fixed diagnostic for exactly it. It is also the setting an
# operator is most likely to reach for by hand ("just for a minute") and then
# leave, which is the drift this platform exists to take back.
#
# THE EDIT GOES THROUGH THE API RATHER THAN THE FILE, and that is the whole
# mechanism rather than a preference. AdGuard holds its configuration in memory
# and rewrites the file from it; an edit written straight to AdGuardHome.yaml
# would change nothing the running daemon does, the contract would pass, and
# this hook would fail claiming the contract accepted drift when nothing had
# drifted. Going through the API is what makes the daemon persist the change
# into the file, which is in turn what makes
# roles/adguard/tasks/deploy.yml's template task see a difference and its
# "Restart AdGuard Home onto a reverted configuration" task fire. That task's
# comment describes this exact scenario -- "reverting drift made in the web
# interface" -- so what this hook proves is a path the role was written for.
#
# The persisted half is asserted here rather than assumed, because it is the
# half the repair depends on: a daemon that accepted the change in memory and
# never wrote it would leave the reconcile with nothing to revert and this whole
# hook would then be proving that a restart re-reads an unchanged file.
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_ADGUARD_PORT'), 10)}")
CONFIG = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "adguard", "conf", "AdGuardHome.yaml")
PERSIST_TIMEOUT_SECONDS =
  Integer(ENV.fetch("PLATFORM_ADGUARD_DRIFT_PERSIST_TIMEOUT_SECONDS", "20"), 10)

def refuse(message)
  warn "adguard drift: #{message}"
  exit 1
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_MAC_VAULT_PASSWORD_FILE"), ENV.fetch("PLATFORM_MAC_VAULT_FILE")
)
refuse("the encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
# Overwritten rather than left for the garbage collector, exactly as
# tests/contracts/adguard-runtime.rb overwrites its own copy: this program's
# stderr is captured into a report directory by the hook above it.
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
CREDENTIALS = [
  vault.fetch("vault_adguard_admin_username"), vault.fetch("vault_adguard_admin_password")
].freeze

def call(request)
  request.basic_auth(*CREDENTIALS)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(request) }
rescue StandardError => error
  refuse("#{request.method} #{request.path} did not reach AdGuard: #{error.class}")
end

def protection_reported
  response = call(Net::HTTP::Get.new(URI.join(BASE, "/control/status")))
  refuse("AdGuard answered /control/status with #{response.code}") unless response.code == "200"
  begin
    JSON.parse(response.body).fetch("protection_enabled")
  rescue JSON::ParserError, KeyError
    refuse("AdGuard's /control/status does not report protection_enabled")
  end
end

refuse("the deployed instance already has protection off, so this lane is not drifting anything") unless
  protection_reported == true

# Two routes express this one setting and which of them a build answers is
# upstream's business, not this lane's. /control/protection is what the web
# interface's own switch calls; /control/dns_config carries the same field as
# part of the DNS section. The outcome is what is asserted below, so a build that
# has retired either route still drifts as long as the other one lands -- and a
# build that has retired both refuses here by name rather than leaving the
# contract to fail for a reason that has nothing to do with drift.
post = Net::HTTP::Post.new(URI.join(BASE, "/control/protection"))
post["Content-Type"] = "application/json"
post.body = JSON.generate("enabled" => false)
response = call(post)
unless response.code.start_with?("2")
  fallback = Net::HTTP::Post.new(URI.join(BASE, "/control/dns_config"))
  fallback["Content-Type"] = "application/json"
  fallback.body = JSON.generate("protection_enabled" => false)
  response = call(fallback)
  refuse("neither /control/protection nor /control/dns_config accepted the hand edit " \
         "(#{response.code}); this AdGuard exposes neither route under the name this lane " \
         "knows") unless response.code.start_with?("2")
end

refuse("the hand edit did not reach the running daemon") unless protection_reported == false

# The daemon writes its configuration back on a change rather than on a timer,
# but it does so after answering, so this is a short poll rather than a read.
deadline = now + PERSIST_TIMEOUT_SECONDS
loop do
  document = begin
    YAML.safe_load_file(CONFIG)
  rescue StandardError
    nil
  end
  persisted = document.is_a?(Hash) ? document.dig("filtering", "protection_enabled") : nil
  # Older layouts carried the field under `dns:`. Either position is the same
  # drift and the template renders whichever this image writes, so both are read.
  persisted = document.dig("dns", "protection_enabled") if
    persisted.nil? && document.is_a?(Hash)
  break if persisted == false

  refuse("AdGuard accepted the hand edit but never wrote it into #{CONFIG}, so the converge " \
         "would find the declared document already in place and revert nothing") if now > deadline

  sleep 2
end

puts "adguard drift: protection turned off by hand and persisted into the platform's own " \
     "configuration file"
