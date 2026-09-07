#!/usr/bin/env ruby
# The runtime half of the Seafile service contract: what can only be decided
# against a deployed three-container stack, its bind mount and the encrypted
# vault.
#
# usage: seafile-runtime.rb MODE
#
# MODE is `run` or `restart-persistence`, and everything else arrives in the
# environment, exported by tests/contracts/seafile.sh: PLATFORM_SEAFILE_PORT,
# the three container names, PLATFORM_DOCKER_ROOT, PLATFORM_CONTRACT_VAULT_FILE
# and PLATFORM_CONTRACT_VAULT_PASSWORD_FILE.
#
# `run` is what a registry sweep reaches -- tests/run_contracts.rb spawns every
# registered contract with no argument at all, under a 60-second cap -- so it is
# cheap and touches nothing. `restart-persistence` restarts the server and is
# invoked only by the seafile lane, which is the whole reason it is a second
# mode rather than more work inside the first.
#
# Every claim this program settles was an inference until it ran. PR 1 shipped
# Seafile switched off, so nothing had ever started one of these containers.
#
require "digest/sha2"
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
READY_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_SEAFILE_READY_TIMEOUT_SECONDS", "180"), 10)
RESTART_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_SEAFILE_RESTART_TIMEOUT_SECONDS", "180"), 10)
DOCKER_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_SEAFILE_DOCKER_TIMEOUT_SECONDS", "60"), 10)
HTTP_OPEN_TIMEOUT = Integer(ENV.fetch("PLATFORM_SEAFILE_HTTP_OPEN_TIMEOUT_SECONDS", "10"), 10)
HTTP_READ_TIMEOUT = Integer(ENV.fetch("PLATFORM_SEAFILE_HTTP_READ_TIMEOUT_SECONDS", "30"), 10)
# A sleep rather than a deadline, which is why callers that want it gone set it
# to 0: seahub writes its cache asynchronously to the request it is serving, so
# the second commandstats read is taken a moment after the token exchange.
CACHE_SETTLE_SECONDS = Integer(ENV.fetch("PLATFORM_SEAFILE_CACHE_SETTLE_SECONDS", "5"), 10)
POLL_INTERVAL_SECONDS = Integer(ENV.fetch("PLATFORM_SEAFILE_POLL_INTERVAL_SECONDS", "2"), 10)

MODE = ARGV.fetch(0, "run")
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_SEAFILE_PORT'), 10)}")
SERVER = ENV.fetch("PLATFORM_SEAFILE_CONTAINER")
DATABASE = ENV.fetch("PLATFORM_SEAFILE_DB_CONTAINER")
CACHE = ENV.fetch("PLATFORM_SEAFILE_CACHE_CONTAINER")
# /shared is the bind mount and the server lays out /shared/seafile/conf/. The
# host side is roles/seafile's own derivation of the same file, and R2 requires
# the two to be one file rather than two that happen to look alike.
CONTAINER_SEAFEVENTS = "/shared/seafile/conf/seafevents.conf"
HOST_SEAFEVENTS = File.join(
  ENV.fetch("PLATFORM_DOCKER_ROOT"), "seafile", "data", "seafile", "conf", "seafevents.conf"
)
# Never a real credential: it is the negative control for the database probe and
# for the token exchange, and it has to be a value nothing could have authored.
WRONG_PASSWORD = "seafile-contract-password-that-was-never-authored"

# One line, always. tests/seafile_contract_test.rb judges a refusal by finding
# its fragment on a line that starts with this prefix, so a message wrapped onto
# a second line puts half of itself where no row can ever see it.
def fail_contract(message)
  warn "Seafile contract failed: #{message}"
  exit 1
end

# Reported, never asserted. Two things in this contract are observations rather
# than assertions and both are recorded here as one-liners the lane's transcript
# carries: what MariaDB's own socket does with a wrong password (a Debian
# packaging default, not a property of docker.io/library/mariadb, so failing a
# lane on it would fail it for something this repository does not control), and
# what the seafevents sections this platform does not own currently say.
def observe(message)
  puts "seafile contract observation: #{message}"
end

# Every docker call is bounded and every failure to *make* the call is a
# contract diagnostic rather than a backtrace: a lane that cannot run docker at
# all must say so in the sentence a reader is looking for.
def docker(*argv, label:)
  Timeout.timeout(DOCKER_TIMEOUT_SECONDS) { Open3.capture3("docker", *argv) }
rescue Timeout::Error
  fail_contract("#{label} did not finish within #{DOCKER_TIMEOUT_SECONDS}s")
rescue SystemCallError => error
  fail_contract("#{label} could not run docker at all: #{error.class}")
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
  { "server" => SERVER, "database" => DATABASE, "cache" => CACHE }.each do |role, container|
    state, health = container_state(container, "the #{role} container inspection")
    fail_contract("the Seafile #{role} container #{container} could not be inspected") if state.nil?
    fail_contract("the Seafile #{role} container #{container} is #{state}, not running") unless
      state == "running"
    fail_contract("the Seafile #{role} container #{container} is #{health}, not healthy") unless
      health == "healthy"
  end
end

def wait_for_health(container, budget, label)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget
  loop do
    _state, health = container_state(container, label)
    return if health == "healthy"
    fail_contract("#{container} did not become healthy again within #{budget}s after #{label}") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep POLL_INTERVAL_SECONDS
  end
end

def http(request, label)
  Net::HTTP.start(BASE.host, BASE.port,
                  open_timeout: HTTP_OPEN_TIMEOUT, read_timeout: HTTP_READ_TIMEOUT) do |connection|
    connection.request(request)
  end
rescue StandardError => error
  fail_contract("#{label} could not reach Seafile at #{BASE}: #{error.class}")
end

# GET /api2/ping/ answers a constant from a view that touches nothing, which is
# wrong for verification and exactly right here: this loop is asking whether
# nginx and seahub are serving at all, not whether the databases answer.
def wait_for_server(label)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = Net::HTTP.start(
        BASE.host, BASE.port, open_timeout: HTTP_OPEN_TIMEOUT, read_timeout: HTTP_READ_TIMEOUT
      ) { |connection| connection.request(Net::HTTP::Get.new(URI.join(BASE, "/api2/ping/"))) }
      return if response.code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Seafile never served #{label} within #{READY_TIMEOUT_SECONDS}s") if
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

# --- the event configuration ------------------------------------------------
#
# The section-bounded read, spelled the way roles/seafile spells it. `enabled` is
# not a unique key in this document -- upstream carries one under [AUDIT] and one
# under [SEAHUB EMAIL] -- and [^\[]*? is what keeps the match inside one section,
# a section header being the only thing in this grammar that opens with a
# bracket.
INDEX_FILES_ENABLED = /^\[INDEX FILES\][^\[]*?^enabled\s*=\s*([^\r\n]*)/m
ANY_SECTION_ENABLED = /^\[([^\]]+)\][^\[]*?^enabled\s*=\s*([^\r\n]*)/m

def host_seafevents
  fail_contract("the Seafile event configuration did not land on the host at #{HOST_SEAFEVENTS}") unless
    File.file?(HOST_SEAFEVENTS)

  # The server writes this file as root inside a bind mount, so a contract
  # running as somebody else is a case worth naming rather than crashing on.
  begin
    File.binread(HOST_SEAFEVENTS)
  rescue SystemCallError => error
    fail_contract("the Seafile event configuration at #{HOST_SEAFEVENTS} could not be read: #{error.class}")
  end
end

def index_files_enabled(content, where)
  match = content.match(INDEX_FILES_ENABLED)
  fail_contract(
    "#{where} carries no [INDEX FILES] enabled key, so this platform is managing nothing there"
  ) if match.nil?

  match[1].strip
end

# (a) The path claim, which until this ran was read out of the image rather than
# observed: bootstrap.py moves the generated conf/ to /shared/seafile/conf and
# create_data_links.sh re-establishes the symlink on every later start. Proving
# the two copies are byte-identical proves both the container-side layout and
# that roles/seafile's own derivation reaches the same file.
def assert_seafevents_path
  stdout, _stderr, status = docker(
    "exec", SERVER, "cat", CONTAINER_SEAFEVENTS, label: "the container-side event configuration read"
  )
  fail_contract("Seafile does not keep its event configuration at #{CONTAINER_SEAFEVENTS}") unless
    status.success?

  inside = stdout.b
  outside = host_seafevents.b
  fail_contract("the container and host copies of seafevents.conf are not the same file") unless
    Digest::SHA256.hexdigest(inside) == Digest::SHA256.hexdigest(outside)
  outside
end

def assert_index_files_disabled(content, where)
  current = index_files_enabled(content, where)
  fail_contract("Seafile file indexing is #{current} in #{where}, and this platform requires false") unless
    current == "false"
  # Reported rather than asserted, and the reason is the same one the socket
  # observation below carries: what upstream's own generator writes under
  # [AUDIT] and [SEAHUB EMAIL] is not this repository's to control, so a lane
  # failing on it would fail for something nobody here can fix. The property
  # that IS this platform's -- that the repair is bounded to one section rather
  # than applied per line -- is asserted by tests/contracts/seafile-static.rb
  # against the role's own pattern, where breaking it is a repository change.
  others = content.scan(ANY_SECTION_ENABLED).reject { |section, _value| section == "INDEX FILES" }
  observe(
    "seafevents.conf sections this platform does not own report enabled as " \
    "#{others.map { |section, value| "[#{section}] #{value.strip}" }.join(', ')}"
  ) unless others.empty?
end

# --- the database credential classification ---------------------------------
#
# (c) roles/seafile probes root over TCP because MariaDB installs root@localhost
# able to authenticate through the unix_socket plugin, which authorises by the
# connecting process's uid and ignores the password. Asserted here: the platform's
# own credential authenticates over TCP and answers as root, and a password
# nothing authored does not. Observed and never asserted: what the same wrong
# password does over the container's own socket. That plugin default is a
# Debian/Ubuntu packaging decision rather than a documented property of
# docker.io/library/mariadb, so asserting it would fail this lane for something
# the repository does not control -- while the TCP assertions pin the choice
# either way.
TCP_IDENTITY_SCRIPT = <<~'SH'
  exec env MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb --protocol=tcp --host=db --port=3306 \
    --user=root --connect-timeout=15 --batch --skip-column-names \
    --execute="select substring_index(current_user(), '@', 1)"
SH
WRONG_TCP_SCRIPT = <<~'SH'
  exec env MYSQL_PWD="$1" mariadb --protocol=tcp --host=db --port=3306 \
    --user=root --connect-timeout=15 --batch --skip-column-names --execute="select 1"
SH
WRONG_SOCKET_SCRIPT = <<~'SH'
  exec env MYSQL_PWD="$1" mariadb --protocol=socket \
    --user=root --connect-timeout=15 --batch --skip-column-names --execute="select 1"
SH

def assert_database_credential
  stdout, _stderr, status = docker(
    "exec", DATABASE, "sh", "-ec", TCP_IDENTITY_SCRIPT, label: "the database identity probe"
  )
  fail_contract("the Seafile database refused over TCP the root credential this platform authored") unless
    status.success?
  fail_contract("the Seafile database answered as #{stdout.strip.inspect} rather than root") unless
    stdout.strip == "root"

  _out, _err, wrong_tcp = docker(
    "exec", DATABASE, "sh", "-ec", WRONG_TCP_SCRIPT, "seafile-contract", WRONG_PASSWORD,
    label: "the negative database probe"
  )
  fail_contract("the Seafile database accepted over TCP a root password nothing ever wrote") if
    wrong_tcp.success?

  _socket_out, _socket_err, wrong_socket = docker(
    "exec", DATABASE, "sh", "-ec", WRONG_SOCKET_SCRIPT, "seafile-contract", WRONG_PASSWORD,
    label: "the socket observation"
  )
  observe(
    if wrong_socket.success?
      "root authenticated over the container's own unix socket with a password nothing wrote, " \
        "which is the false positive the TCP form in roles/seafile/tasks/deploy.yml avoids"
    else
      "root over the container's own unix socket was refused the wrong password, so this image " \
        "does not install the unix_socket plugin for root"
    end
  )
end

# --- the administrator token exchange ---------------------------------------
#
# (d) POST /api2/auth-token/ is the one endpoint on the unauthenticated surface
# that cannot answer without the databases: it authenticates against ccnet_db and
# seahub_db and then get-or-creates the token row in seahub_db.
def token_exchange(username, password, label)
  request = Net::HTTP::Post.new(URI.join(BASE, "/api2/auth-token/"))
  request.set_form_data("username" => username, "password" => password)
  response = http(request, label)
  token = begin
    JSON.parse(response.body.to_s)["token"]
  rescue JSON::ParserError
    nil
  end
  [response.code, token.to_s]
end

def assert_administrator_token(credentials, label)
  code, token = token_exchange(
    credentials.fetch("email"), credentials.fetch("password"), "#{label} token exchange"
  )
  fail_contract("Seafile did not issue an API token for the vault administrator #{label} (HTTP #{code})") unless
    code == "200" && !token.empty?

  wrong_code, wrong_token = token_exchange(
    credentials.fetch("email"), "#{credentials.fetch('password')}-#{WRONG_PASSWORD}",
    "#{label} negative token exchange"
  )
  fail_contract("Seafile issued an API token for a password the vault never authored") if
    wrong_code == "200" && !wrong_token.empty?
end

# --- the cache ---------------------------------------------------------------
#
# (e) Seafile's own documentation never mentions Valkey; that it serves as the
# Redis cache was a protocol inference until this ran. INFO commandstats reports
# a family only once that family has been called, and the only two clients this
# container has are the health check -- which runs `ping` and nothing else -- and
# Seafile. So a family other than ping appearing at all is the proof.
CACHE_INFO_SCRIPT = <<~'SH'
  exec valkey-cli --no-auth-warning -a "$VALKEY_PASSWORD" INFO commandstats
SH
# Every command the health check, this contract's own connection and a bare
# client handshake can produce on their own. Anything outside this set was
# issued by Seafile doing cache work.
#
# Compared against the family name with any subcommand cut off, and that is
# load-bearing rather than tidy: INFO reports subcommands as their own families
# -- `client|setinfo`, `config|get`, `command|docs` -- and valkey-cli itself
# sends CLIENT SETINFO on connect. Matching the bare names alone would leave
# this contract's own census registering a family the filter does not remove,
# so the assertion below would pass on a deployment where Seafile never touched
# the cache at all: (e) reported as settled having settled nothing.
CACHE_HOUSEKEEPING = %w[ping auth info command hello client config subscribe].freeze

def cache_command_families(label)
  stdout, _stderr, status = docker(
    "exec", CACHE, "sh", "-ec", CACHE_INFO_SCRIPT, label: label
  )
  fail_contract("the Seafile cache did not answer INFO commandstats") unless status.success?

  stdout.scan(/^cmdstat_([a-z|._-]+):calls=(\d+)/).to_h { |name, calls| [name, Integer(calls, 10)] }
end

def assert_cache_is_serving(before, after)
  families = after.reject { |name, _calls| CACHE_HOUSEKEEPING.include?(name.split("|").first) }
  fail_contract(
    "Seafile is not using the Valkey cache: the only command families the cache has served are " \
    "#{after.keys.sort.join(', ')}"
  ) if families.empty?

  # Growth across the token exchange is reported rather than asserted. What
  # settles (e) is that a non-housekeeping family has been served at all; whether
  # one particular request path touches the cache is Seafile's business and a
  # release that caches that path differently is not a deployment defect.
  grown = families.map { |name, calls| "#{name} #{before.fetch(name, 0)}->#{calls}" }
  observe("the Seafile cache served #{grown.join(', ')} across the administrator token exchange")
end

# --- modes -------------------------------------------------------------------

def run_mode(credentials)
  census
  content = assert_seafevents_path
  assert_index_files_disabled(content, "the deployed seafevents.conf")
  assert_database_credential
  before = cache_command_families("the cache command census")
  assert_administrator_token(credentials, "the deployed server's")
  sleep CACHE_SETTLE_SECONDS if CACHE_SETTLE_SECONDS.positive?
  assert_cache_is_serving(before, cache_command_families("the cache command census after the exchange"))
  puts "seafile contract: three healthy containers, the platform-owned event configuration, " \
       "the TCP-only database credential, an administrator token and a Valkey-backed cache hold"
end

# (b) The highest-stakes claim in this service, and the only one that can be
# settled by watching a restart. roles/seafile repairs [INDEX FILES] and then
# restarts the server onto the repaired file. That converges only if Seafile
# writes the key on its first run alone -- which is what the image says: pro.py
# setup is reached through bootstrap.py's init_seafile_server(), and that returns
# early once /shared/seafile/seafile-data exists. If the derivation is wrong, run
# 1 and run 2 disagree for ever and the platform's hard idempotence requirement
# is broken by construction.
def restart_persistence_mode(credentials)
  before = index_files_enabled(host_seafevents, "seafevents.conf before the restart")
  fail_contract(
    "Seafile file indexing is #{before} before the restart, so the reconciliation this mode " \
    "exists to test has not run"
  ) unless before == "false"

  _out, _err, status = docker("restart", SERVER, label: "the server restart")
  fail_contract("the Seafile server container #{SERVER} could not be restarted") unless status.success?
  wait_for_health(SERVER, RESTART_TIMEOUT_SECONDS, "the server restart")

  after = index_files_enabled(host_seafevents, "seafevents.conf after the restart")
  fail_contract(
    "Seafile rewrote [INDEX FILES] enabled to #{after} on start, so the repair-then-restart in " \
    "roles/seafile/tasks/reconcile_seafevents.yml can never converge: the repair must move into a " \
    "start-time mechanism the server cannot undo, or file indexing must be switched off another way"
  ) unless after == "false"

  # Not decoration: a server that came back unable to reach its databases would
  # otherwise let the lane's second converge blame itself for this restart.
  wait_for_server("its API after the restart")
  assert_administrator_token(credentials, "the restarted server's")
  puts "seafile contract: the platform-owned [INDEX FILES] setting survives a server restart and " \
       "the administrator still authenticates against the databases"
end

fail_contract("unknown mode: #{MODE}") unless %w[run restart-persistence].include?(MODE)

document = vault
credentials = {
  "email" => document.fetch("vault_seafile_admin_email"),
  "password" => document.fetch("vault_seafile_admin_password")
}
case MODE
when "run" then run_mode(credentials)
else restart_persistence_mode(credentials)
end
