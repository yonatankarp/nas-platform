#!/usr/bin/env ruby
# The runtime half of the Nextcloud service contract: what can only be decided
# against a deployed four-container stack, its bind mount and the encrypted
# vault.
#
# usage: nextcloud-runtime.rb MODE
#
# MODE is `run`, and everything else arrives in the environment, exported by
# tests/contracts/nextcloud.sh: PLATFORM_NEXTCLOUD_PORT, the four container
# names, PLATFORM_DOCKER_ROOT, PLATFORM_CONTRACT_VAULT_FILE and
# PLATFORM_CONTRACT_VAULT_PASSWORD_FILE.
#
# `run` is what a registry sweep reaches -- tests/run_contracts.rb spawns every
# registered contract with no argument at all, under a 60-second cap -- so it
# restarts nothing, stops nothing and drops nothing. The wrapper beside this file
# records why there is no second mode.
#
# Every claim this program settles was an inference until it ran. This stack
# ships switched off, so nothing had ever started one of these containers.
require "json"
require "net/http"
require "open3"
require "timeout"
require "uri"
require "yaml"

# Every budget is an environment input, on the first lines of the file, and each
# one is used at an explicit call site. CLAUDE.md records the `static` job's time
# budget being blown four times, and the fourth was exactly this shape: a
# self-test whose planted regression let an invocation through to a runtime half
# that then spent its whole readiness budget against a port nothing was
# listening on. A budget that cannot be shortened by its caller is a wait nobody
# can remove.
READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_READY_TIMEOUT_SECONDS", "180"), 10)
DOCKER_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_DOCKER_TIMEOUT_SECONDS", "60"), 10)
# occ boots the whole application before it prints anything, so it is the slowest
# call this contract makes and it gets a budget of its own rather than sharing
# the plain docker one.
OCC_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_OCC_TIMEOUT_SECONDS", "120"), 10)
HTTP_OPEN_TIMEOUT = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_HTTP_OPEN_TIMEOUT_SECONDS", "10"), 10)
HTTP_READ_TIMEOUT = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_HTTP_READ_TIMEOUT_SECONDS", "30"), 10)
POLL_INTERVAL_SECONDS = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_POLL_INTERVAL_SECONDS", "2"), 10)

MODE = ARGV.fetch(0, "run")
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_NEXTCLOUD_PORT'), 10)}")
APPLICATION = ENV.fetch("PLATFORM_NEXTCLOUD_CONTAINER")
CRON = ENV.fetch("PLATFORM_NEXTCLOUD_CRON_CONTAINER")
DATABASE = ENV.fetch("PLATFORM_NEXTCLOUD_DB_CONTAINER")
CACHE = ENV.fetch("PLATFORM_NEXTCLOUD_CACHE_CONTAINER")
# Never a real credential: it is the negative control for the administrator
# exchange, and it has to be a value nothing could have authored.
WRONG_PASSWORD = "nextcloud-contract-password-that-was-never-authored"

# One line, always. tests/nextcloud_contract_test.rb judges a refusal by finding
# its fragment on a line that starts with this prefix, so a message wrapped onto
# a second line puts half of itself where no row can ever see it.
def fail_contract(message)
  warn "Nextcloud contract failed: #{message}"
  exit 1
end

# Reported, never asserted. What the shipped app set currently is depends on the
# image's own default, which this platform pins but does not choose, so a lane
# must not fail on it -- #500 leaves the app policy to a later phase and this
# line is what will inform it.
def observe(message)
  puts "nextcloud contract observation: #{message}"
end

# Every docker call is bounded and every failure to *make* the call is a
# contract diagnostic rather than a backtrace: a lane that cannot run docker at
# all must say so in the sentence a reader is looking for.
def docker(*argv, label:, budget: DOCKER_TIMEOUT_SECONDS)
  Timeout.timeout(budget) { Open3.capture3("docker", *argv) }
rescue Timeout::Error
  fail_contract("#{label} did not finish within #{budget}s")
rescue SystemCallError => error
  fail_contract("#{label} could not run docker at all: #{error.class}")
end

# occ, as the account that owns the installation. Running it as root writes
# root-owned files into /var/www/html that the next request cannot read, which is
# a way of breaking the stack while asserting things about it.
def occ(*arguments, label:)
  stdout, stderr, status = docker(
    "exec", "--user", "www-data", APPLICATION, "php", "occ", *arguments,
    label: label, budget: OCC_TIMEOUT_SECONDS
  )
  fail_contract("#{label} failed: #{stderr.lines.first.to_s.strip}") unless status.success?
  stdout.strip
end

def container_state(container, label)
  stdout, _stderr, status = docker(
    "inspect", "--format", "{{.State.Status}} {{.State.Health.Status}}", container, label: label
  )
  return [nil, nil] unless status.success?

  state, health = stdout.strip.split(" ", 2)
  [state, health]
end

def census
  {
    "application" => APPLICATION, "cron" => CRON,
    "database" => DATABASE, "cache" => CACHE
  }.each do |role, container|
    state, health = container_state(container, "the #{role} container inspection")
    fail_contract("the Nextcloud #{role} container #{container} could not be inspected") if state.nil?
    fail_contract("the Nextcloud #{role} container #{container} is #{state}, not running") unless
      state == "running"
    fail_contract("the Nextcloud #{role} container #{container} is #{health}, not healthy") unless
      health == "healthy"
  end
end

def http(request, label)
  Net::HTTP.start(BASE.host, BASE.port,
                  open_timeout: HTTP_OPEN_TIMEOUT, read_timeout: HTTP_READ_TIMEOUT) do |connection|
    connection.request(request)
  end
rescue StandardError => error
  fail_contract("#{label} could not reach Nextcloud at #{BASE}: #{error.class}")
end

# /status.php is the readiness probe AND the database probe, which is unusual
# enough to be worth stating: it is not a static file. It requires lib/base.php,
# and OC::init boots the server, which builds the memcache factory, which calls
# AppConfig#getAppInstalledVersions -- a query against oc_appconfig. With the
# cluster gone apache answers and this returns HTTP 500 with a zero-byte body.
def wait_for_server(label)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = Net::HTTP.start(
        BASE.host, BASE.port, open_timeout: HTTP_OPEN_TIMEOUT, read_timeout: HTTP_READ_TIMEOUT
      ) { |connection| connection.request(Net::HTTP::Get.new(URI.join(BASE, "/status.php"))) }
      return response if response.code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Nextcloud never served #{label} within #{READY_TIMEOUT_SECONDS}s") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep POLL_INTERVAL_SECONDS
  end
end

def vault
  stdout, stderr, status = begin
    Open3.capture3(
      "ansible-vault", "view", "--vault-password-file",
      ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"), ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
    )
  rescue SystemCallError
    fail_contract("the encrypted vault could not be read")
  end
  fail_contract("the encrypted vault could not be read") unless status.success?

  document = YAML.safe_load(stdout)
  stdout.replace("\0" * stdout.bytesize)
  stderr.replace("\0" * stderr.bytesize)
  document
end

def assert_status_endpoint
  response = wait_for_server("its status endpoint")
  document = begin
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    fail_contract("Nextcloud's status endpoint answered 200 with a body that is not JSON")
  end
  fail_contract("Nextcloud reports itself not installed") unless document["installed"] == true
  fail_contract("Nextcloud is in maintenance mode") if document["maintenance"] == true
  fail_contract("Nextcloud reports a database upgrade it has not finished") if
    document["needsDbUpgrade"] == true
  document
end

# --- the landmine, settled against a running installation --------------------
#
# THE claim this contract exists for. Nextcloud's installer ignores the database
# account it is handed whenever that account can create roles -- and the postgres
# image always grants POSTGRES_USER SUPERUSER, so it always can. Left alone,
# lib/private/Setup/PostgreSQL.php mints `oc_admin` with a password of its own
# and writes it into config.php, and the vault's account becomes a thing nothing
# uses. services/nextcloud/compose.yml sets NC_setup_create_db_user=false to
# refuse that.
#
# Nothing static can prove the refusal WORKED -- the environment variable being
# present is not the installer having honoured it -- and nothing can prove it
# afterwards either, because the install branch runs once and never again. This
# is the only place the claim can be settled, and it has to be settled on a stack
# whose first converge has already happened.
#
# Read through occ rather than off config.php: the README warns that "merely
# viewing your config.php will not give you an accurate view of your running
# config", and the NC_ overrides this stack pushes are precisely values that
# never reach that file.
def assert_vault_owns_the_database(credentials)
  live_user = occ("config:system:get", "dbuser", label: "the database account census")
  fail_contract(
    "Nextcloud is connecting to its database as #{live_user}, not as the vault's own account. " \
    "That is the installer having minted its own role, which means " \
    "NC_setup_create_db_user was not false on the FIRST converge -- and it cannot be repaired " \
    "by setting it now, because the install branch only runs while the installation is empty. " \
    "The recovery is occ config:system:set dbuser and dbpassword, then dropping the stray role."
  ) unless live_user == credentials.fetch("db_username")

  live_name = occ("config:system:get", "dbname", label: "the database name census")
  fail_contract("Nextcloud is using database #{live_name}, not the vault's own") unless
    live_name == credentials.fetch("db_name")
end

# The administrator credential, in both directions. The positive half proves the
# account the vault names exists and authenticates; the negative half is what
# keeps the positive one from passing against a server that authorises anything.
# OCS rather than the web login form: it takes basic auth, and it answers 401
# rather than 200-with-a-login-page for a wrong password, which is the difference
# an assertion can read.
def assert_administrator(credentials)
  request = Net::HTTP::Get.new(URI.join(BASE, "/ocs/v2.php/cloud/user?format=json"))
  request.basic_auth(credentials.fetch("username"), credentials.fetch("password"))
  request["OCS-APIRequest"] = "true"
  response = http(request, "the administrator exchange")
  fail_contract(
    "Nextcloud did not accept the vault administrator (HTTP #{response.code}). A 401 is a " \
    "password the server does not hold -- rotating it in the vault does not reach oc_users, " \
    "which is what roles/nextcloud/tasks/reconcile_admin.yml repairs with occ. A 400 is the " \
    "Host header not being in trusted_domains."
  ) unless response.code == "200"

  wrong = Net::HTTP::Get.new(URI.join(BASE, "/ocs/v2.php/cloud/user?format=json"))
  wrong.basic_auth(credentials.fetch("username"), WRONG_PASSWORD)
  wrong["OCS-APIRequest"] = "true"
  refusal = http(wrong, "the negative administrator exchange")
  fail_contract("Nextcloud authorised a password the vault never authored") if refusal.code == "200"
end

# The trusted domain list, read back from the server the reconciliation wrote to.
# Every entry roles/nextcloud declares must be present, and 127.0.0.1 must be
# among them or this contract's own requests would have been answered 400 -- so
# this is partly a statement about why the assertions above could run at all.
def assert_trusted_domains
  live = occ("config:system:get", "trusted_domains", label: "the trusted domain census")
             .lines.map(&:strip).reject(&:empty?)
  fail_contract("Nextcloud trusts no domain this platform can name") if live.empty?
  fail_contract(
    "Nextcloud does not trust 127.0.0.1, so roles/nextcloud's own verification would be " \
    "answered HTTP 400 rather than served"
  ) unless live.include?("127.0.0.1")
  live
end

# The cron sidecar, proved by what it did rather than by its being up. Nextcloud
# runs background jobs in `ajax` mode until cron.php is executed for the first
# time, at which point it records `cron` in oc_appconfig. So this single value
# separates "a fourth container is running" from "the background job runner this
# platform added a container for has actually run", which is the whole reason the
# sidecar exists.
def assert_cron_has_run
  mode = occ("config:app:get", "core", "backgroundjobs_mode", label: "the background job mode census")
  fail_contract(
    "Nextcloud still runs background jobs in #{mode} mode, so the cron sidecar has never " \
    "executed cron.php. The AJAX default fires only when a browser requests a page, which on " \
    "an idle instance is never, and it is the reason this stack carries a fourth container."
  ) unless mode == "cron"
end

def run_mode(credentials)
  census
  status = assert_status_endpoint
  assert_vault_owns_the_database(credentials)
  assert_trusted_domains
  assert_administrator(credentials)
  assert_cron_has_run
  apps = occ("app:list", "--output=json", label: "the application census")
  enabled = begin
    JSON.parse(apps).fetch("enabled", {}).keys.sort
  rescue JSON::ParserError, KeyError
    []
  end
  observe("the shipped app set currently enables #{enabled.length} apps: #{enabled.join(' ')}")
  puts "nextcloud contract: four healthy containers, an installed #{status['versionstring']} " \
       "serving its status endpoint, the vault's own database account rather than a minted " \
       "one, the reconciled trusted domains, an administrator that authenticates and a cron " \
       "sidecar that has run"
end

MODES = %w[run].freeze
fail_contract("unknown mode: #{MODE}") unless MODES.include?(MODE)

document = vault
# Fetched through a refusal rather than through Ruby's own KeyError, for the
# reason #352 recorded: a backtrace is not a diagnostic, and a row asserting
# "this must be refused" would accept one.
credentials = {
  "username" => "vault_nextcloud_admin_username",
  "password" => "vault_nextcloud_admin_password",
  "db_name" => "vault_nextcloud_db_name",
  "db_username" => "vault_nextcloud_db_username"
}.transform_values do |key|
  fail_contract("the encrypted vault carries no #{key}") unless document.key?(key)
  document.fetch(key)
end
run_mode(credentials)
