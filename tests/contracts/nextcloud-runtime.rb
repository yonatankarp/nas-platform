#!/usr/bin/env ruby
# Runtime half of the Nextcloud contract, against the deployed four-container
# stack and the encrypted vault. usage: nextcloud-runtime.rb MODE (only `run`,
# which a registry sweep reaches, so it restarts, stops and drops nothing);
# inputs come from the environment tests/contracts/nextcloud.sh exports.
require "json"
require "net/http"
require "open3"
require "timeout"
require "uri"
require "yaml"

# Every budget is an environment input so a caller facing a dead port can shorten it.
READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_READY_TIMEOUT_SECONDS", "180"), 10)
DOCKER_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_DOCKER_TIMEOUT_SECONDS", "60"), 10)
# occ boots the whole application first, so it gets its own budget.
OCC_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_OCC_TIMEOUT_SECONDS", "120"), 10)
HTTP_OPEN_TIMEOUT = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_HTTP_OPEN_TIMEOUT_SECONDS", "10"), 10)
HTTP_READ_TIMEOUT = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_HTTP_READ_TIMEOUT_SECONDS", "30"), 10)
POLL_INTERVAL_SECONDS = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_POLL_INTERVAL_SECONDS", "2"), 10)
# Not a timeout: the age past which "no background job mode recorded" means the
# sidecar never ran (see assert_background_jobs_belong_to_the_sidecar).
CRON_GRACE_SECONDS = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_CRON_GRACE_SECONDS", "900"), 10)

MODE = ARGV.fetch(0, "run")
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_NEXTCLOUD_PORT'), 10)}")
APPLICATION = ENV.fetch("PLATFORM_NEXTCLOUD_CONTAINER")
CRON = ENV.fetch("PLATFORM_NEXTCLOUD_CRON_CONTAINER")
DATABASE = ENV.fetch("PLATFORM_NEXTCLOUD_DB_CONTAINER")
CACHE = ENV.fetch("PLATFORM_NEXTCLOUD_CACHE_CONTAINER")
# The negative control; a value nothing could have authored.
WRONG_PASSWORD = "nextcloud-contract-password-that-was-never-authored"
# --default-value for an unwritten key, which otherwise exits 1 with no output.
UNSET_APP_CONFIG = "nextcloud-contract-app-config-never-written"
# The sidecar's own crontab, shipped in the image.
CRON_CRONTAB_PATH = "/var/spool/cron/crontabs/www-data"

# One line, always: tests/nextcloud_contract_test.rb matches refusals per line.
def fail_contract(message)
  warn "Nextcloud contract failed: #{message}"
  exit 1
end

# Reported, never asserted: the shipped app set is the image's default (#500).
def observe(message)
  puts "nextcloud contract observation: #{message}"
end

# Bounded, and a failure to run docker is a diagnostic rather than a backtrace.
def docker(*argv, label:, budget: DOCKER_TIMEOUT_SECONDS)
  # A Timeout closes capture3's pipes under its reader threads, which then print
  # IOError backtraces beside the refusal (#352); silence them for this call.
  reported = Thread.report_on_exception
  Thread.report_on_exception = false
  begin
    Timeout.timeout(budget) { Open3.capture3("docker", *argv) }
  ensure
    Thread.report_on_exception = reported
  end
rescue Timeout::Error
  fail_contract("#{label} did not finish within #{budget}s")
rescue SystemCallError => error
  fail_contract("#{label} could not run docker at all: #{error.class}")
end

def first_line(stream)
  line = stream.to_s.lines.map(&:strip).find { |candidate| !candidate.empty? }
  return nil if line.nil?

  line.length > 160 ? "#{line[0, 160]}..." : line
end

# Name exit status, then stderr, then stdout, else "said nothing": occ
# config:app:get exits 1 with both streams empty for an unwritten key.
def diagnosis(stdout, stderr, status)
  code = status.exitstatus.nil? ? "signal #{status.termsig}" : "exit #{status.exitstatus}"
  if (line = first_line(stderr))
    "#{code}, stderr: #{line}"
  elsif (line = first_line(stdout))
    "#{code}, nothing on stderr, stdout: #{line}"
  else
    "#{code}, no output on stdout or stderr"
  end
end

# As the installation's owner: root would write files the next request cannot read.
def occ(*arguments, label:)
  stdout, stderr, status = docker(
    "exec", "--user", "www-data", APPLICATION, "php", "occ", *arguments,
    label: label, budget: OCC_TIMEOUT_SECONDS
  )
  fail_contract("#{label} failed (#{diagnosis(stdout, stderr, status)})") unless status.success?
  stdout.strip
end

def app_config(key, label:)
  value = occ("config:app:get", "core", key, "--default-value=#{UNSET_APP_CONFIG}", label: label)
  value == UNSET_APP_CONFIG ? nil : value
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

# /status.php boots the server and queries oc_appconfig, so it is also the
# database probe: with the cluster gone it answers 500 with an empty body.
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

# THE LANDMINE: the installer ignores a DB account that can create roles (postgres
# always grants SUPERUSER) and mints oc_admin, unless NC_setup_create_db_user=false
# is honoured. Only a running install can prove it; read via occ, not config.php.
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

# Both directions, over OCS: it answers 401 (not a login page) to a wrong password.
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

# Asserts only a non-empty list containing 127.0.0.1: the declared list is a
# template this half cannot render, and without 127.0.0.1 every request is a 400.
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

# crond takes no job argument, so the crontab is the only place the schedule exists.
def cron_sidecar_schedule
  stdout, stderr, status = docker("exec", CRON, "cat", CRON_CRONTAB_PATH,
                                  label: "the cron sidecar schedule census")
  fail_contract(
    "the Nextcloud cron sidecar's crontab #{CRON_CRONTAB_PATH} could not be read " \
    "(#{diagnosis(stdout, stderr, status)})"
  ) unless status.success?

  schedule = stdout.lines.map(&:strip).find { |line| line.include?("cron.php") }
  fail_contract(
    "the Nextcloud cron sidecar's crontab #{CRON_CRONTAB_PATH} schedules no cron.php, so nothing " \
    "in that container will ever run a background job however healthy it reports"
  ) if schedule.nil?
  schedule
end

# Read through refusals, not Ruby exceptions (#352).
def installation_age_seconds
  recorded = app_config("installedat", label: "the installation age census")
  fail_contract(
    "Nextcloud records no core|installedat, so the absence of a background job mode cannot be " \
    "told apart from a cron sidecar that has never run"
  ) if recorded.nil?

  installed = begin
    Float(recorded)
  rescue ArgumentError, TypeError
    fail_contract("Nextcloud records core|installedat as #{recorded.inspect}, which is not a timestamp")
  end
  (Time.now.to_f - installed).round
end

# The background job mode is recorded only after cron.php first runs, and the
# first */5 tick can land after this contract runs on a fresh converge. So:
# `cron` passes; any other recorded mode is refused; no mode is accepted only while
# the install is younger than CRON_GRACE_SECONDS and the crontab schedules cron.php.
def assert_background_jobs_belong_to_the_sidecar
  mode = app_config("backgroundjobs_mode", label: "the background job mode census")
  return "a cron sidecar that has run" if mode == "cron"

  fail_contract(
    "Nextcloud still runs background jobs in #{mode.inspect} mode rather than cron, so the " \
    "sidecar's cron.php is not what runs them. The AJAX default fires only when a browser " \
    "requests a page, which on an idle instance is never, and it is the reason this stack " \
    "carries a fourth container. Recover with occ background:cron."
  ) unless mode.nil?

  schedule = cron_sidecar_schedule
  age = installation_age_seconds
  fail_contract(
    "Nextcloud has recorded no background job mode #{age}s after it was installed, which is past " \
    "the #{CRON_GRACE_SECONDS}s this contract allows a #{schedule.inspect} schedule to reach its " \
    "first run: the cron sidecar has never executed cron.php. Read the sidecar's log -- crond " \
    "runs the job as www-data and a job that fails leaves the mode unwritten."
  ) if age > CRON_GRACE_SECONDS

  "a cron sidecar scheduled as #{schedule.inspect}, #{age}s into an installation whose first " \
    "run is still ahead of it"
end

# A property of this platform, not the inventory (#500): the role's list is a
# template this program cannot render, and asserting it would echo the role.
OVERLAPPING_APPS = { "photos" => "Immich" }.freeze

UNPARSEABLE_CENSUS =
  "Nextcloud's application census answered with a body that is not JSON, so this run learned " \
  "nothing about which apps are enabled. `occ app:list --output=json` writes one compact " \
  "document and nothing else; a body that is not one is occ having failed before it got there."


def assert_platform_app_policy
  raw = occ("app:list", "--output=json", label: "the application census")
  # Refused rather than rescued to []: an empty set would satisfy every check below.
  document = begin
    JSON.parse(raw)
  rescue JSON::ParserError
    fail_contract(UNPARSEABLE_CENSUS)
  end
  enabled = document.fetch("enabled", {}).keys.sort
  fail_contract(
    "Nextcloud's application census reports no enabled application at all, which no " \
    "installation can be in: core/shipped.json holds fourteen alwaysEnabled apps that cannot " \
    "be turned off. Read this as a census that failed rather than as a policy that succeeded."
  ) if enabled.empty?

  overlapping = OVERLAPPING_APPS.keys.select { |app| enabled.include?(app) }
  fail_contract(
    "Nextcloud still enables #{overlapping.join(', ')}, which this platform already serves from " \
    "#{overlapping.map { |app| OVERLAPPING_APPS.fetch(app) }.uniq.join(', ')}. " \
    "roles/nextcloud/tasks/reconcile_apps.yml disables it on every converge, so this is that " \
    "stage never having run, an operator having enabled it in the admin interface since, or a " \
    "reinstall onto an empty data volume. Not an image bump: that file records why occ upgrade " \
    "cannot re-enable an app this platform disabled."
  ) unless overlapping.empty?

  # An observation, not an assertion: an app count is the image's to choose, but a
  # drop after `occ upgrade` shows up here.
  observe("the shipped app set currently enables #{enabled.length} apps: #{enabled.join(' ')}")
  nil
end

def run_mode(credentials)
  census
  status = assert_status_endpoint
  assert_vault_owns_the_database(credentials)
  assert_trusted_domains
  assert_administrator(credentials)
  cron = assert_background_jobs_belong_to_the_sidecar
  assert_platform_app_policy
  puts "nextcloud contract: four healthy containers, an installed #{status['versionstring']} " \
       "serving its status endpoint, the vault's own database account rather than a minted " \
       "one, the reconciled trusted domains, an administrator that authenticates, " \
       "no application this platform serves elsewhere, and #{cron}"
end

MODES = %w[run].freeze
fail_contract("unknown mode: #{MODE}") unless MODES.include?(MODE)

document = vault
# Fetched through a refusal, not KeyError (#352).
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
