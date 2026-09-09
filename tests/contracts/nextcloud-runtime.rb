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
# The one budget here that is not a timeout, and nothing waits on it: it is how
# old an installation may be before "no background job mode has been recorded"
# stops meaning "the sidecar's schedule has not fired yet" and starts meaning
# "the sidecar has never run". assert_background_jobs_belong_to_the_sidecar
# below is the single call site and records the arithmetic behind the default.
CRON_GRACE_SECONDS = Integer(ENV.fetch("PLATFORM_NEXTCLOUD_CRON_GRACE_SECONDS", "900"), 10)

MODE = ARGV.fetch(0, "run")
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_NEXTCLOUD_PORT'), 10)}")
APPLICATION = ENV.fetch("PLATFORM_NEXTCLOUD_CONTAINER")
CRON = ENV.fetch("PLATFORM_NEXTCLOUD_CRON_CONTAINER")
DATABASE = ENV.fetch("PLATFORM_NEXTCLOUD_DB_CONTAINER")
CACHE = ENV.fetch("PLATFORM_NEXTCLOUD_CACHE_CONTAINER")
# Never a real credential: it is the negative control for the administrator
# exchange, and it has to be a value nothing could have authored.
WRONG_PASSWORD = "nextcloud-contract-password-that-was-never-authored"
# Handed to `occ config:app:get` as --default-value so that a key which has
# never been written arrives as a value this program can recognise rather than
# as an exit code carrying no output at all. It has to be a string nothing could
# have stored in oc_appconfig, for the same reason WRONG_PASSWORD does.
UNSET_APP_CONFIG = "nextcloud-contract-app-config-never-written"
# The crontab busybox crond reads inside the sidecar. It ships in the image
# rather than in the shared volume, so this is the sidecar's own copy and not
# the application container's.
CRON_CRONTAB_PATH = "/var/spool/cron/crontabs/www-data"

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
  # Open3.capture3 reads the two pipes on threads of its own, and a Timeout
  # closes those pipes underneath them: each thread then dies of IOError and Ruby
  # prints its backtrace on stderr, immediately above the refusal below.
  # Measured against a docker that sleeps past its budget -- two backtraces and
  # then the sentence. A diagnostic standing next to a backtrace is what #352 was
  # about, so the report is switched off for the duration of the call and
  # restored afterwards; it governs threads created while it is off, which is
  # exactly capture3's two.
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

# The first non-empty line of a stream, bounded. A refusal is one line, and a
# docker error can be a paragraph.
def first_line(stream)
  line = stream.to_s.lines.map(&:strip).find { |candidate| !candidate.empty? }
  return nil if line.nil?

  line.length > 160 ? "#{line[0, 160]}..." : line
end

# Why a failed call needs saying more than its stderr does. The first CI run of
# this lane refused with `the background job mode census failed: ` -- a sentence
# that ends at its colon and names nothing -- because the message interpolated
# the first line of stderr alone and there was no stderr:
# core/Command/Config/App/GetConfig.php returns 1 from its
# AppConfigUnknownKeyException branch, printing nothing on either stream, for an
# app config key that has never been written. Measured against the pinned image:
# `occ config:app:get core backgroundjobs_mode` on a fresh install answers
# exit 1 with both streams empty.
#
# So every failure mode gets a distinguishable clause: the exit status always,
# then stderr if there is any, then stdout if the command put its complaint on
# the wrong stream, and otherwise the fact that it said nothing at all -- which
# is a diagnosis rather than a hole, because it is what sends a reader to the
# command's own exit codes. A call that never returned is not routed here: the
# Timeout rescue in `docker` names the label and the budget it blew.
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

# occ, as the account that owns the installation. Running it as root writes
# root-owned files into /var/www/html that the next request cannot read, which is
# a way of breaking the stack while asserting things about it.
def occ(*arguments, label:)
  stdout, stderr, status = docker(
    "exec", "--user", "www-data", APPLICATION, "php", "occ", *arguments,
    label: label, budget: OCC_TIMEOUT_SECONDS
  )
  fail_contract("#{label} failed (#{diagnosis(stdout, stderr, status)})") unless status.success?
  stdout.strip
end

# An oc_appconfig read whose "this key has never been written" is a value rather
# than a silent exit 1. Without --default-value that state and a broken occ are
# the same exit code with the same empty output, and no message can tell a reader
# which of the two it met.
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
#
# What this proves is that the list is not empty and that it holds 127.0.0.1. It
# deliberately does not compare the list against what roles/nextcloud declares,
# because it cannot: nextcloud_trusted_domains is a Jinja template over
# platform_public_host and nextcloud_additional_trusted_domains, and rendering it
# needs an inventory and a variable context this runtime half has neither of --
# it holds an HTTP port, a container name and a vault, and nothing that would
# resolve that default. So the one entry asserted is the one whose absence has a
# consequence right here: without 127.0.0.1 the server answers HTTP 400 to every
# request, and roles/nextcloud's own verification -- and every assertion above --
# would have been refused rather than served. That makes this as much a statement
# about why they could run at all as it is a check.
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

# The schedule the sidecar will run cron.php from, read out of the container that
# would run it. crond takes no argument naming a job, so the crontab is the only
# place this claim exists; the compose file's `entrypoint: /cron.sh` says which
# program starts, not what it has to do.
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

# The installation's own age, from the timestamp Nextcloud writes at install.
# Read through refusals rather than through Ruby's own exceptions, for the reason
# #352 recorded: a backtrace is not a diagnostic.
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

# The cron sidecar, proved by what it did rather than by its being up -- as far
# as a fresh converge permits that to be proved at all, which is the whole
# subtlety here and the reason this reads longer than the one value it started
# as.
#
# Nextcloud does not record a background job mode until cron.php runs:
# CronService::runCli writes `cron` into oc_appconfig, and until then the key is
# absent and every reader falls back to the `ajax` default in code. Measured
# against the pinned image on a fresh install, `occ config:app:get core
# backgroundjobs_mode` answers exit 1 with both streams empty, and after one
# `php -f /var/www/html/cron.php` in the sidecar it answers `cron`.
#
# **So "the sidecar has run" is not a property a fresh converge can be asked
# for.** The sidecar is `*/5 * * * * php -f cron.php` under busybox crond, so the
# first run lands at the next wall-clock five-minute boundary after the container
# starts -- and that container starts only once the application reports healthy,
# which is when the install finished. The failing CI run is exactly that: a stack
# created at 21:43 and a contract that reached this line at 21:43:48, with the
# earliest possible fire at 21:45.
#
# Waiting for it was considered and rejected. tests/run_contracts.rb spawns this
# contract with a 60-second default and a 300-second cap, and the wait needed is
# up to 300 seconds of schedule plus the run itself, measured at 37 seconds cold
# -- a budget that cannot fit inside the ceiling its own caller enforces. The
# lane cannot supply the time either: it runs this contract between converge 1
# and the idempotence reconverge, so what it sees is always a stack about a
# minute old. Executing cron.php from here instead would settle it, and is
# refused for a different reason: `run` mode restarts nothing, stops nothing and
# drops nothing, and running the job queue is a larger action than any of those.
#
# What is asserted instead is the true property, in three parts, and only the
# first is the one this function used to claim:
#
#   * a recorded mode of `cron` is the sidecar having run, and passes;
#   * a recorded mode that is anything else -- `ajax`, `webcron`, `none` -- is a
#     deliberate setting that ignores the sidecar, and is refused, because
#     nothing writes those values by accident;
#   * no recorded mode is the fresh-converge state, and is accepted only while
#     the installation is younger than CRON_GRACE_SECONDS *and* the sidecar's own
#     crontab schedules cron.php. Past that age the schedule has had its chance
#     and the absence is the failure the fourth container exists to prevent.
#
# The 900-second default is 300 seconds of worst-case schedule with room for a
# slow first run and a slow converge; on the NAS, where an installation is days
# old, every path but the first is a refusal, so the original claim is intact
# exactly where it can be made. In CI the third bullet is the only branch ever
# taken, which is what makes the crontab assertion load-bearing there rather than
# a nicety: it is the whole difference between "a fourth container is up" and
# "the container that is up will run background jobs".
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

# What this platform refuses to serve out of Nextcloud, and the service that
# serves it instead. One entry, and #500's own scope is the derivation: "Photos,
# documents and media are already covered by Immich, Paperless and
# Jellyfin/Audiobookshelf/Komga".
#
# It is a property of THIS PLATFORM rather than of an inventory, which is the
# whole reason it is assertable from here at all. roles/nextcloud's own list is a
# Jinja expression over two role variables, and this program holds an HTTP port,
# four container names and a vault -- nothing that would render it. Threading the
# rendered list in through tests/contracts/nextcloud.sh was considered and
# refused for the reason assert_trusted_domains records: it would make this
# assert what the role says rather than what the platform requires, and a role
# that dropped an entry would take the contract with it.
OVERLAPPING_APPS = { "photos" => "Immich" }.freeze

UNPARSEABLE_CENSUS =
  "Nextcloud's application census answered with a body that is not JSON, so this run learned " \
  "nothing about which apps are enabled. `occ app:list --output=json` writes one compact " \
  "document and nothing else; a body that is not one is occ having failed before it got there."


def assert_platform_app_policy
  raw = occ("app:list", "--output=json", label: "the application census")
  # Refused rather than rescued to an empty set, and the difference is the whole
  # assertion. `[]` contains no photos, so a census this program could not read
  # would satisfy every check below -- it would pass exactly when it had learned
  # nothing, which is the vacuous shape this repository keeps closing.
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
    "roles/nextcloud/tasks/reconcile_apps.yml disables it on every converge, so this is either " \
    "that stage never having run or occ upgrade having re-enabled it since."
  ) unless overlapping.empty?

  # Kept as an observation rather than promoted. This is the ON-side drift
  # detector the off-set policy deliberately does not cover: re-asserting what
  # must be off says nothing about `occ upgrade` disabling something that should
  # have stayed on, and a lane that starts reporting 43 apps where it reported 50
  # is that. Asserting a count instead would pin a number the image owns.
  observe("the shipped app set currently enables #{enabled.length} apps: #{enabled.join(' ')}")
  enabled
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
