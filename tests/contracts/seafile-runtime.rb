#!/usr/bin/env ruby
# The runtime half of the Seafile service contract: what can only be decided
# against a deployed three-container stack, its bind mount and the encrypted
# vault.
#
# usage: seafile-runtime.rb MODE
#
# MODE is `run`, `restart-persistence`, `restore-rehearsal-seed` or
# `restore-rehearsal-assert`, and everything else arrives in the environment,
# exported by tests/contracts/seafile.sh: PLATFORM_SEAFILE_PORT, the three
# container names, PLATFORM_DOCKER_ROOT, PLATFORM_CONTRACT_VAULT_FILE and
# PLATFORM_CONTRACT_VAULT_PASSWORD_FILE.
#
# `run` is what a registry sweep reaches -- tests/run_contracts.rb spawns every
# registered contract with no argument at all, under a 60-second cap -- so it is
# cheap and touches nothing. The other three restart, stop or drop things and
# are invoked only by the seafile lane, which is the whole reason they are modes
# of their own rather than more work inside the first.
#
# Every claim this program settles was an inference until it ran. PR 1 shipped
# Seafile switched off, so nothing had ever started one of these containers.
#
require "digest/sha2"
require "json"
require "net/http"
require "open3"
require "stringio"
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
def docker(*argv, label:, budget: DOCKER_TIMEOUT_SECONDS)
  Timeout.timeout(budget) { Open3.capture3("docker", *argv) }
rescue Timeout::Error
  fail_contract("#{label} did not finish within #{budget}s")
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

# This waits on a fresh verdict rather than a stale one, which is not obvious
# from the loop: `docker restart` returns only after the start, and the start
# resets health to `starting` -- measured on Docker 29.7.2, where six inspects
# straight after a restart all reported `starting` and healthy came back only
# once a new probe had run. Demanding more of it -- a health-log entry stamped
# after State.StartedAt, say -- would buy nothing this does not already have,
# and wait_for_server and the token exchange after it carry the phase anyway.
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
# (c) roles/seafile probes root over TCP so that only root@% -- the account the
# image creates with CREATE USER ... IDENTIFIED BY -- can answer, and only a
# matching password gets in. Asserted here: the platform's own credential
# authenticates over TCP and answers as root, and a password nothing authored
# does not. Observed and never asserted: what the same wrong password does over
# the container's own socket, where MariaDB's unix_socket plugin would authorise
# root@localhost by uid and ignore the password entirely. That plugin default is
# a Debian/Ubuntu packaging decision rather than a documented property of
# docker.io/library/mariadb -- this lane has since measured it absent from the
# image -- so asserting either outcome would fail this lane for something the
# repository does not control, while the TCP assertions pin the choice.
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

# --- the restore rehearsal ---------------------------------------------------
#
# (f) A backup nobody has restored is a hypothesis, and for this service it is a
# hypothesis with a specific way of being false: Seafile stores content as
# content-addressed blocks and keeps the mapping from blocks back to filenames,
# libraries and owners only in the database, so a restore that puts the schemas
# back and cannot resolve a filename into bytes is the failure mode the whole
# backup exists to prevent. Nothing short of downloading a file proves it did
# not happen.
#
# Two modes rather than one, on the precedent tests/contracts/immich.sh set with
# its clean-restore-seed / clean-restore-assert pair, because roles/seafile has
# to run BETWEEN them: the seed uploads a file, the lane converges the role with
# seafile_pre_upgrade_backup_force so THIS PLATFORM'S backup is what gets taken,
# and the assert restores that backup. A rehearsal that dumped its own database
# with its own command would prove the rehearsal rather than the platform.
#
# Neither mode is reachable from a registry sweep, which spawns every contract
# with no argument at all under a 60-second cap.
REHEARSAL_LIBRARY = "nas-platform-restore-rehearsal"
REHEARSAL_FILE = "restore-rehearsal.txt"
# Fixed rather than generated, and that is what lets the two modes share no
# state: the assert looks the library up by name and compares the download
# against this constant, so there is no file between them to lose or to leave
# behind.
REHEARSAL_CONTENT = "nas-platform seafile restore rehearsal payload\n"
BACKUP_ROOT = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "seafile", "backups")
RESTORE_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_SEAFILE_RESTORE_TIMEOUT_SECONDS", "300"), 10)
# Its own budget rather than DOCKER_TIMEOUT_SECONDS, and the number is derived
# from the deployment rather than picked: services/seafile/compose.yml gives the
# server stop_grace_period: 1m, so Docker sends SIGKILL at 60 seconds and
# `docker stop` returns just after -- exactly where the shared 60-second docker
# budget expires. A stop that hit the grace period would race its own timeout and
# fail as "did not finish", which is the #319 shape: a hardcoded wait that
# becomes a failure nobody changed anything to cause. 120 is that period plus the
# same again.
STOP_TIMEOUT_SECONDS = Integer(ENV.fetch("PLATFORM_SEAFILE_STOP_TIMEOUT_SECONDS", "120"), 10)

# Every link Seafile hands a client is built from SEAFILE_SERVER_HOSTNAME, which
# is the address a human types and not one this contract can reach from inside
# the sandbox. Only the path and query survive; the coordinate is this
# program's own.
def local_url(value, label)
  target = begin
    URI.parse(value.to_s)
  rescue URI::InvalidURIError
    fail_contract("Seafile answered #{label} with something that is not a URL")
  end
  fail_contract("Seafile answered #{label} with no path") if target.path.to_s.empty?
  URI.join(BASE, target.request_uri)
end

def api(request, token, label)
  request["Authorization"] = "Token #{token}"
  response = http(request, label)
  fail_contract("Seafile answered #{label} with HTTP #{response.code}") unless
    response.code.start_with?("2")
  response
end

def administrator_token(credentials, label)
  code, token = token_exchange(
    credentials.fetch("email"), credentials.fetch("password"), label
  )
  # Written as a refusal on the negation rather than as `unless code == "200" &&
  # !token.empty?`, which is the assertion in assert_administrator_token above.
  # The two say the same thing about different callers, and a self-test plant
  # that matched both would prove neither.
  fail_contract("Seafile did not issue an API token for the vault administrator (HTTP #{code})") if
    code != "200" || token.to_s.empty?
  token
end

def rehearsal_library(token, label)
  response = api(Net::HTTP::Get.new(URI.join(BASE, "/api2/repos/")), token, label)
  libraries = begin
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    fail_contract("Seafile answered #{label} with something that is not JSON")
  end
  fail_contract("Seafile answered #{label} with something that is not a list") unless
    libraries.is_a?(Array)

  match = libraries.find { |entry| entry.is_a?(Hash) && entry["name"] == REHEARSAL_LIBRARY }
  match && (match["id"] || match["repo_id"]).to_s
end

def seed_mode(credentials)
  census
  token = administrator_token(credentials, "the seed token exchange")

  # Created only if it is not already there, so the seed is safe to run twice
  # against a sandbox somebody kept.
  library = rehearsal_library(token, "the library census")
  if library.nil? || library.empty?
    request = Net::HTTP::Post.new(URI.join(BASE, "/api2/repos/"))
    request.set_form_data("name" => REHEARSAL_LIBRARY)
    created = api(request, token, "the library creation")
    body = begin
      JSON.parse(created.body.to_s)
    rescue JSON::ParserError
      {}
    end
    library = (body["repo_id"] || body["id"]).to_s
    library = rehearsal_library(token, "the library census after creation") if library.empty?
  end
  fail_contract("Seafile did not create the rehearsal library #{REHEARSAL_LIBRARY}") if
    library.nil? || library.empty?

  # set_form's multipart form is Ruby's own rather than hand-rolled, which
  # matters more here than anywhere else in this file: seafhttp is strict about
  # the boundary and a malformed body would fail as a Seafile error rather than
  # as this program's.
  link = api(
    Net::HTTP::Get.new(URI.join(BASE, "/api2/repos/#{library}/upload-link/")),
    token, "the upload link request"
  )
  upload = Net::HTTP::Post.new(local_url(JSON.parse(link.body.to_s), "the upload link"))
  upload.set_form(
    [["parent_dir", "/"],
     ["replace", "1"],
     ["file", StringIO.new(REHEARSAL_CONTENT),
      { filename: REHEARSAL_FILE, content_type: "text/plain" }]],
    "multipart/form-data"
  )
  api(upload, token, "the rehearsal upload")

  # Downloaded back before the mode reports success, because an upload that
  # answered 200 and stored nothing would make the assert mode fail against a
  # backup that was never wrong.
  fail_contract("the rehearsal file did not read back as uploaded") unless
    download_rehearsal_file(token, library, "the seed download") == REHEARSAL_CONTENT

  puts "seafile contract: the restore rehearsal seeded #{REHEARSAL_FILE} into " \
       "#{REHEARSAL_LIBRARY} and read it back"
end

def download_rehearsal_file(token, library, label)
  link = api(
    Net::HTTP::Get.new(URI.join(BASE, "/api2/repos/#{library}/file/?p=/#{REHEARSAL_FILE}&reuse=1")),
    token, "#{label} link request"
  )
  content = api(Net::HTTP::Get.new(local_url(JSON.parse(link.body.to_s), "#{label} link")),
                token, label)
  content.body.to_s
end

# The newest backup this platform took, found the way an operator finds it. It
# is not created here and must not be: the whole point of the rehearsal is that
# roles/seafile's own backup is the thing being restored.
def newest_backup
  fail_contract("this platform took no Seafile backup under #{BACKUP_ROOT}") unless
    Dir.exist?(BACKUP_ROOT)

  # The backup root is mode 0700 and owned by the host's root, which is the whole
  # point of it, so a contract running as somebody else is a case worth naming
  # rather than crashing on -- host_seafevents above takes the same care for the
  # same reason.
  newest = begin
    Dir.children(BACKUP_ROOT).select { |name| File.directory?(File.join(BACKUP_ROOT, name)) }
       .sort.last
  rescue SystemCallError => error
    fail_contract("the Seafile backup root #{BACKUP_ROOT} could not be read: #{error.class}")
  end
  fail_contract("this platform took no Seafile backup under #{BACKUP_ROOT}") if newest.nil?
  File.join(BACKUP_ROOT, newest)
end

def assert_backup_shape(backup)
  dump = File.join(backup, "databases.sql")
  fail_contract("the Seafile backup at #{backup} carries no databases.sql") unless File.file?(dump)
  fail_contract("the Seafile backup at #{backup} carries an empty databases.sql") unless
    File.size(dump).positive?
  fail_contract("the Seafile backup at #{backup} carries no manifest") unless
    File.file?(File.join(backup, "MANIFEST.txt"))
  # The security requirement, proved against a real backup rather than against
  # the role that claims it. /scripts/start.py writes the administrator password
  # to conf/admin.txt in plaintext on every container start, so a backup that
  # swept conf/ blindly would keep that plaintext for as long as the backup is
  # kept.
  fail_contract("the Seafile backup at #{backup} preserved the plaintext administrator handoff") if
    File.exist?(File.join(backup, "conf", "admin.txt"))
  # Not an empty directory either: a conf/ backup that copied nothing would
  # satisfy the exclusion above by copying nothing at all.
  preserved = Dir.exist?(File.join(backup, "conf")) ? Dir.children(File.join(backup, "conf")) : []
  fail_contract("the Seafile backup at #{backup} preserved no configuration at all") if preserved.empty?
  observe("the Seafile backup at #{backup} preserved #{preserved.sort.join(', ')}")
  dump
end

DROP_SCRIPT = <<~'SH'
  exec env MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb --protocol=tcp --host=db --port=3306 \
    --user=root --batch --execute="drop database ccnet_db; drop database seafile_db; drop database seahub_db"
SH
# Reads its statements from stdin rather than from argv, and that is the whole
# reason this is a script rather than an --execute. The account recreation below
# carries the vault's own database password, and an --execute would put it in
# the argv of `docker exec` where the host's process table can read it.
RESTORE_SCRIPT = <<~'SH'
  exec env MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb --protocol=tcp --host=db --port=3306 \
    --user=root --batch
SH

def sql_literal(value)
  "'#{value.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")}'"
end

def database_sql(script, payload, label)
  stdout, stderr, status = begin
    Timeout.timeout(RESTORE_TIMEOUT_SECONDS) do
      Open3.capture3("docker", "exec", "-i", DATABASE, "sh", "-ec", script, stdin_data: payload)
    end
  rescue Timeout::Error
    fail_contract("#{label} did not finish within #{RESTORE_TIMEOUT_SECONDS}s")
  rescue SystemCallError => error
    fail_contract("#{label} could not run docker at all: #{error.class}")
  end
  [stdout, stderr, status]
end

def restore_rehearsal_mode(credentials)
  census
  backup = newest_backup
  dump = assert_backup_shape(backup)

  token = administrator_token(credentials, "the pre-restore token exchange")
  library = rehearsal_library(token, "the pre-restore library census")
  fail_contract(
    "#{REHEARSAL_LIBRARY} is not on this server, so the seed mode has not run and there is " \
    "nothing this rehearsal could prove"
  ) if library.nil? || library.empty?

  _out, _err, dropped = docker(
    "exec", DATABASE, "sh", "-ec", DROP_SCRIPT, label: "the rehearsal database drop"
  )
  fail_contract("the three Seafile databases could not be dropped") unless dropped.success?

  # THE NEGATIVE CONTROL, and without it every assertion after the restore is
  # vacuous: a rehearsal that never actually broke anything reports a successful
  # restore of a server that was working the whole time.
  code, issued = token_exchange(
    credentials.fetch("email"), credentials.fetch("password"), "the dropped-database token exchange"
  )
  fail_contract(
    "Seafile issued an API token with ccnet_db, seafile_db and seahub_db dropped, so this " \
    "rehearsal is not testing what it claims to"
  ) if code == "200" && !issued.to_s.empty?

  _stop_out, _stop_err, stopped = docker(
    "stop", SERVER, label: "the pre-restore server stop", budget: STOP_TIMEOUT_SECONDS
  )
  fail_contract("the Seafile server container #{SERVER} could not be stopped") unless stopped.success?

  # Step 2 of docs/getting-started-nas.md's "Recover Seafile". --databases means
  # the dump carries its own CREATE DATABASE and USE statements, so this
  # recreates the three schemas that were just dropped.
  dump_body = begin
    File.binread(dump)
  rescue SystemCallError => error
    fail_contract("the Seafile dump at #{dump} could not be read: #{error.class}")
  end
  _restore_out, restore_err, restored = database_sql(
    RESTORE_SCRIPT, dump_body, "the rehearsal database restore"
  )
  fail_contract("the Seafile backup would not restore: #{restore_err.to_s.lines.first.to_s.strip}") unless
    restored.success?

  # Step 3 of the same procedure, the case where the MariaDB data directory
  # itself was lost. It is a no-op here -- a db-level grant survives DROP
  # DATABASE on this image -- and it is rehearsed anyway, because a documented
  # recovery step nobody has ever executed is the other half of the hypothesis
  # this mode exists to remove. Fed through stdin so the vault's own database
  # password never reaches the host's process table.
  account = <<~SQL
    CREATE USER IF NOT EXISTS #{sql_literal(credentials.fetch('db_username'))}@'%'
      IDENTIFIED BY #{sql_literal(credentials.fetch('db_password'))};
    GRANT ALL PRIVILEGES ON ccnet_db.* TO #{sql_literal(credentials.fetch('db_username'))}@'%';
    GRANT ALL PRIVILEGES ON seafile_db.* TO #{sql_literal(credentials.fetch('db_username'))}@'%';
    GRANT ALL PRIVILEGES ON seahub_db.* TO #{sql_literal(credentials.fetch('db_username'))}@'%';
    FLUSH PRIVILEGES;
  SQL
  _account_out, account_err, granted = database_sql(
    RESTORE_SCRIPT, account, "the rehearsal account recreation"
  )
  account.replace("\0" * account.bytesize)
  fail_contract(
    "the documented Seafile account recreation would not run: " \
    "#{account_err.to_s.lines.first.to_s.strip}"
  ) unless granted.success?

  _start_out, _start_err, started = docker("start", SERVER, label: "the post-restore server start")
  fail_contract("the Seafile server container #{SERVER} could not be started again") unless
    started.success?
  wait_for_health(SERVER, RESTART_TIMEOUT_SECONDS, "the post-restore start")
  wait_for_server("its API after the restore")

  restored_token = administrator_token(credentials, "the post-restore token exchange")
  restored_library = rehearsal_library(restored_token, "the post-restore library census")
  fail_contract("#{REHEARSAL_LIBRARY} did not come back from the restored database") if
    restored_library.nil? || restored_library.empty?

  # The claim this mode exists for. Downloading resolves a filename through
  # seahub and seaf-server into content-addressed blocks on disk, so bytes that
  # come back identical are the coupling working end to end: the blocks were
  # never in the backup, and the database that names them was rebuilt from it.
  content = download_rehearsal_file(restored_token, restored_library, "the post-restore download")
  fail_contract(
    "#{REHEARSAL_FILE} came back from the restored database as #{content.bytesize} bytes that do " \
    "not match what was uploaded, so the restored database does not resolve its blocks"
  ) unless content == REHEARSAL_CONTENT

  puts "seafile contract: #{backup} restored the three databases this platform dumped, the " \
       "documented account recreation ran, and #{REHEARSAL_FILE} downloaded back byte for byte " \
       "from blocks no backup ever carried"
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

MODES = %w[run restart-persistence restore-rehearsal-seed restore-rehearsal-assert].freeze
fail_contract("unknown mode: #{MODE}") unless MODES.include?(MODE)

document = vault
# The database pair is read for one caller only -- the restore rehearsal's
# account recreation, which is step 3 of the documented recovery -- and it is
# read here rather than there so that every mode fails the same way on a vault
# that is missing a key: at the top, naming the vault, rather than halfway
# through a restore.
#
# Fetched through a refusal rather than through Ruby's own KeyError, for the
# reason #352 recorded: a backtrace is not a diagnostic, and a row asserting
# "this must be refused" would accept one.
credentials = {
  "email" => "vault_seafile_admin_email",
  "password" => "vault_seafile_admin_password",
  "db_username" => "vault_seafile_db_username",
  "db_password" => "vault_seafile_db_password"
}.transform_values do |key|
  fail_contract("the encrypted vault carries no #{key}") unless document.key?(key)
  document.fetch(key)
end
case MODE
when "run" then run_mode(credentials)
when "restart-persistence" then restart_persistence_mode(credentials)
when "restore-rehearsal-seed" then seed_mode(credentials)
else restore_rehearsal_mode(credentials)
end
