#!/usr/bin/env ruby
# The runtime half of the AdGuard Home service contract: what only a deployed
# AdGuard can answer.
#
# usage: adguard-runtime.rb
#
# Takes no arguments. Its whole input is the environment
# tests/contracts/adguard.sh exports. On failure it writes one
# `AdGuard contract failed: ...` line to stderr and exits 1.
#
# WHAT THIS PROVES THAT AN HTTP 200 DOES NOT. /control/status reporting
# `running` and `protection_enabled` is the floor and it is asserted here, but a
# resolver that answers its own status page is not the same claim as a resolver
# that filters. So this program puts two real DNS questions on the wire: a name
# the declared blocklist carries, which must come back blocked, and a name no
# blocklist carries, which must come back with a real address. Both are asked of
# the deployed listener over the published port.
#
# WHY THE DNS QUERIES GO OVER TCP. Measured on Docker Desktop for Mac: a UDP
# publication of a container port does not carry a query from the host to the
# container -- `dig +notcp` times out where `dig +tcp` against the same
# publication answers in milliseconds. TCP works on both Docker Desktop and a
# Linux daemon, so it is the portable choice, and RFC 7766 requires every
# resolver to serve it. Do not "fix" this back to UDP: the compose file still
# publishes both, and it is the transport this program uses that would change,
# not what AdGuard listens on.
require "json"
require "net/http"
require "open3"
require "socket"
require "uri"
require "yaml"

BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_ADGUARD_PORT'), 10)}")
DNS_PORT = Integer(ENV.fetch("PLATFORM_ADGUARD_DNS_PORT"), 10)
CONTAINER = ENV.fetch("PLATFORM_ADGUARD_CONTAINER")
CONFIG = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "adguard", "conf", "AdGuardHome.yaml")

# The three budgets this program can spend waiting, and the only three numbers
# in it a caller may need to lower. Every default is the deployment's own.
#
# They are environment inputs from the first draft rather than after the fact,
# for the reason #319 and #485 both record: a caller that must reach the refusal
# one of these deadlines guards has to sit out the whole budget to get there, and
# tests/adguard_contract_test.rb has such a row per deadline. Two checks became
# the `static` gate's floor that way, and both fixes were retrofits.
READY_TIMEOUT_SECONDS =
  Integer(ENV.fetch("PLATFORM_ADGUARD_READY_TIMEOUT_SECONDS", "120"), 10)
# The declared filter lists are downloaded after the daemon starts serving, so
# this is a poll rather than a read. Measured against v0.107.79: filter_1, about
# 178,000 rules and 4.2 MB, landed roughly ten seconds after start.
FILTER_POLL_TIMEOUT_SECONDS =
  Integer(ENV.fetch("PLATFORM_ADGUARD_FILTER_POLL_TIMEOUT_SECONDS", "120"), 10)
# One DNS exchange, not the whole proof. A resolver that has answered its status
# page and has its rules loaded either answers a question promptly or is broken.
DNS_TIMEOUT_SECONDS =
  Integer(ENV.fetch("PLATFORM_ADGUARD_DNS_TIMEOUT_SECONDS", "10"), 10)

# The two names the pair of DNS questions is asked about. Both are stable
# entries rather than sampled ones: filter_1 carries an explicit
# `||doubleclick.net^` rule, and example.com is reserved by RFC 2606 and appears
# on no blocklist. They are environment inputs so that a lane whose upstream
# resolution is unavailable can point the allowed probe somewhere it controls.
BLOCKED_NAME = ENV.fetch("PLATFORM_ADGUARD_BLOCKED_NAME", "doubleclick.net")
ALLOWED_NAME = ENV.fetch("PLATFORM_ADGUARD_ALLOWED_NAME", "example.com")

def fail_contract(message)
  warn "AdGuard contract failed: #{message}"
  exit 1
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def request(path, credentials: nil)
  http_request = Net::HTTP::Get.new(URI.join(BASE, path))
  http_request.basic_auth(*credentials) if credentials
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(http_request) }
end

def json_body(response, what)
  JSON.parse(response.body)
rescue JSON::ParserError
  fail_contract("AdGuard answered #{what} with something that is not JSON")
end

# /login.html is the one route AdGuard serves without credentials; everything
# under /control answers 401. Waiting on it is what lets the anonymous refusal
# below mean "protected" rather than "not up yet".
def wait_for_login_page
  deadline = now + READY_TIMEOUT_SECONDS
  loop do
    begin
      return if request("/login.html").code == "200"
    rescue StandardError
      nil
    end
    fail_contract("AdGuard never served its login page") if now > deadline

    sleep 2
  end
end

# A DNS query built by hand and sent over TCP, because Ruby's stdlib resolver
# cannot be pointed at a particular port and transport together. Returns the A
# records in the answer as dotted-quad strings, which is all this contract asks
# of a response.
def resolve_a(name)
  message = dns_question(name)
  payload = nil
  socket = nil
  begin
    socket = Socket.tcp("127.0.0.1", DNS_PORT, connect_timeout: DNS_TIMEOUT_SECONDS)
    socket.write([message.bytesize].pack("n") + message)
    length = read_exactly(socket, 2).unpack1("n")
    payload = read_exactly(socket, length)
  rescue StandardError => error
    fail_contract("the DNS query for #{name} failed on 127.0.0.1:#{DNS_PORT}: #{error.class}")
  ensure
    socket&.close
  end
  dns_answers(payload, name)
end

def dns_question(name)
  header = [rand(0..0xffff), 0x0100, 1, 0, 0, 0].pack("n6")
  qname = name.split(".").map { |label| [label.bytesize].pack("C") + label }.join + "\0"
  header + qname + [1, 1].pack("n2")
end

def read_exactly(socket, count)
  buffer = +""
  deadline = now + DNS_TIMEOUT_SECONDS
  while buffer.bytesize < count
    raise IOError, "timed out" if now > deadline

    chunk = socket.read(count - buffer.bytesize)
    raise IOError, "short read" if chunk.nil? || chunk.empty?

    buffer << chunk
  end
  buffer
end

# Walks a response far enough to collect its A records. Names inside a response
# may be compressed to a two-byte pointer, so every name is skipped through the
# same routine rather than assumed to be a literal.
def dns_answers(payload, name)
  fail_contract("the DNS answer for #{name} was truncated") if payload.bytesize < 12

  answer_count = payload[6, 2].unpack1("n")
  offset = skip_name(payload, 12) + 4
  addresses = []
  answer_count.times do
    offset = skip_name(payload, offset)
    type, _klass, _ttl, rdlength = payload[offset, 10].unpack("nnNn")
    offset += 10
    addresses << payload[offset, 4].unpack("C4").join(".") if type == 1 && rdlength == 4
    offset += rdlength
  end
  addresses
end

def skip_name(payload, offset)
  loop do
    length = payload.getbyte(offset)
    return offset + 2 if length.nil? || (length & 0xC0) == 0xC0
    return offset + 1 if length.zero?

    offset += 1 + length
  end
end

wait_for_login_page

# Anonymous first, and before any credential is presented: AdGuard's `users: []`
# disables authentication completely, and an instance in that state hands the
# ability to rewrite any DNS answer on the network to whoever can reach the port.
fail_contract("AdGuard served its control API to an anonymous request") unless
  request("/control/status").code == "401"

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
credentials = [
  vault.fetch("vault_adguard_admin_username"), vault.fetch("vault_adguard_admin_password")
]

fail_contract("AdGuard accepted a wrong password") unless
  request("/control/status", credentials: [credentials.first, "contract-wrong-password"])
  .code == "401"

status_response = request("/control/status", credentials: credentials)
fail_contract("AdGuard refused the vault-authored administrator") unless
  status_response.code == "200"
status = json_body(status_response, "/control/status")
fail_contract("AdGuard did not report itself running") unless status["running"] == true
fail_contract("AdGuard reported protection disabled") unless status["protection_enabled"] == true

# The declared lists, and the poll that waits for them to arrive. rules_count is
# the reading that separates "the list is declared" from "the list is loaded":
# a list that never downloaded is present with zero rules and blocks nothing.
filters = nil
filter_deadline = now + FILTER_POLL_TIMEOUT_SECONDS
loop do
  document = json_body(request("/control/filtering/status", credentials: credentials),
                       "/control/filtering/status")
  fail_contract("AdGuard reported filtering disabled") unless document["enabled"] == true

  filters = Array(document["filters"]).select { |filter| filter["enabled"] }
  break if !filters.empty? && filters.all? { |filter| filter["rules_count"].to_i.positive? }

  fail_contract("AdGuard's declared filter lists never reported any rules") if now > filter_deadline

  sleep 3
end

# The behavioural half, and the reason this contract exists rather than a status
# assertion. AdGuard's default blocking mode answers a blocked A query with
# 0.0.0.0, so the two questions below are distinguished by their answers rather
# than by a status code.
blocked = resolve_a(BLOCKED_NAME)
fail_contract("#{BLOCKED_NAME} resolved to #{blocked.inspect} rather than being blocked") unless
  blocked.empty? || blocked.all? { |address| address == "0.0.0.0" }

allowed = resolve_a(ALLOWED_NAME)
fail_contract("#{ALLOWED_NAME} did not resolve through AdGuard") if allowed.empty?
fail_contract("#{ALLOWED_NAME} was blocked, so this instance is filtering more than it declared") if
  allowed.any? { |address| address == "0.0.0.0" }

state, _error, docker_status = Open3.capture3(
  "docker", "inspect", CONTAINER, "--format", "{{.State.Health.Status}}"
)
fail_contract("the AdGuard container could not be inspected") unless docker_status.success?
fail_contract("the AdGuard container is not healthy") unless state.strip == "healthy"

# The configuration is Ansible's, not the daemon's, and it holds the
# administrator's bcrypt hash. AdGuard's own permcheck pass chmods it to 0600 at
# every start, so anything wider here is a file the daemon has not looked at.
fail_contract("AdGuard's configuration is not in the declared configuration root") unless
  File.file?(CONFIG)
fail_contract("AdGuard's configuration is not mode 0600") unless
  (File.stat(CONFIG).mode & 0o777) == 0o600

puts "adguard contract: exclusive administrator, loaded filter lists, and a resolver that " \
     "blocks #{BLOCKED_NAME} while answering #{ALLOWED_NAME}"
