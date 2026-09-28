#!/usr/bin/env ruby
# frozen_string_literal: true

# What roles/vaultwarden/tasks/serve.yml does, proved by running it: each case
# includes the shipped stage against a stub tailscale CLI. The stub's output shapes
# are assumed; `{}` at rc 0 is what a real unconfigured host emits (1.102.3).

require "etc"
require "fileutils"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)
SERVE_TASKS = File.join(ROOT, "roles", "vaultwarden", "tasks", "serve.yml")

# Lowercased, as Self.DNSName carries it; cases vary only the operator's spelling.
NODE_NAME = "as6704t-4043.tail4e1ae8.ts.net"
SHOUTY_NAME = "AS6704T-4043.Tail4e1ae8.ts.net"
SERVE_PORT = 8086

# Taken from the process rather than $USER, which a caller may have exported.
ACCOUNT = Etc.getpwuid(Process.uid).name

# A stub `tailscale`: answers `serve status --json` from TS_STATE, logs any other
# argv to TS_LOG (before TS_DENY decides how it fails). The `operator` text is real
# tailscale 1.102.2 stderr; `daemon` deliberately shares no word with it.
STUB = <<~SH
  #!/bin/sh
  if [ "$1" = serve ] && [ "$2" = status ]; then
    case "$TS_STATE" in
      fronted)
        printf '{"TCP":{"443":{"HTTPS":true}},"Web":{"%s:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:#{SERVE_PORT}"}}}}}\\n' "$TS_KEY"
        exit 0 ;;
      localhost_spelling)
        printf '{"TCP":{"443":{"HTTPS":true}},"Web":{"%s:443":{"Handlers":{"/":{"Proxy":"http://localhost:#{SERVE_PORT}"}}}}}\\n' "$TS_KEY"
        exit 0 ;;
      drifted)
        printf '{"TCP":{"443":{"HTTPS":true}},"Web":{"%s:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:11434"}}}}}\\n' "$TS_KEY"
        exit 0 ;;
      unconfigured_message) printf 'No serve config\\n' >&2; exit 1 ;;
      unconfigured_null)    printf 'null\n'; exit 0 ;;
      unconfigured_empty)   printf '{}\n'; exit 0 ;;
      refuses)              printf 'flag provided but not defined: -json\\n' >&2; exit 2 ;;
    esac
  fi
  printf 'MUTATE %s\\n' "$*" >> "$TS_LOG"
  case "$TS_DENY" in
    operator)
      printf "sending serve config: Access denied: serve config denied\\n\\nUse 'sudo tailscale serve --bg --yes #{SERVE_PORT}'.\\nTo not require root, use 'sudo tailscale set --operator=\\$USER' once.\\n" >&2
      exit 1 ;;
    daemon)
      printf 'failed to connect to local tailscaled; is it running?\\n' >&2
      exit 1 ;;
  esac
  exit 0
SH

# Answers /alive so the stage's reachability probe has something to reach.
class AliveStub
  attr_reader :port

  def initialize(answer: true)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      loop do
        session = begin
          @server.accept
        rescue IOError, Errno::EBADF
          break
        end
        begin
          session.gets
          body = answer ? %("2026-09-10T00:00:00Z") : "no"
          status = answer ? "200 OK" : "503 Service Unavailable"
          session.print("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\n" \
                        "Content-Type: application/json\r\nConnection: close\r\n\r\n#{body}")
        rescue StandardError
          nil
        ensure
          session.close rescue nil
        end
      end
    end
  end

  def close
    @server.close rescue nil
    @thread.kill
  end
end

def run_serve(state:, public_host: NODE_NAME, node_key: NODE_NAME, gate: true,
              binary: :stub, check_mode: false, alive: true, deny: "",
              gather: false, tags: nil, candidates: [], serve_tasks: SERVE_TASKS)
  stub_server = AliveStub.new(answer: alive)
  Dir.mktmpdir("nas-platform-vaultwarden-serve-") do |directory|
    log = File.join(directory, "mutations.log")
    File.write(log, "")
    stub = File.join(directory, "tailscale")
    File.write(stub, STUB, mode: "w", perm: 0o700)
    resolved = binary == :stub ? stub : ""
    playbook = File.join(directory, "driver.yml")
    # Facts only for the operator-denial row, which resolves ansible_facts['user_id'].
    File.write(playbook, YAML.dump([{
      "hosts" => "localhost", "gather_facts" => gather,
      "vars" => {
        "platform_public_host" => public_host,
        "vaultwarden_port" => SERVE_PORT,
        "vaultwarden_domain" => "http://127.0.0.1:#{stub_server.port}",
        "vaultwarden_tailscale_serve_port" => 443,
        "vaultwarden_deployment_enabled" => gate,
        "vaultwarden_tailscale_binary" => resolved,
        # Empty so an absent-path case finds nothing on this machine; `candidates: :stub`
        # lists only the stub, for the discovery case with the binary unset.
        "vaultwarden_tailscale_binary_candidates" => candidates == :stub ? [stub] : candidates,
        "platform_readiness_retries" => 1,
        "platform_readiness_delay" => 0
      },
      # `always` on the include: a dynamic include's tags never reach its tasks, so
      # tag selection is made by the stage's own task tags.
      "tasks" => [{ "ansible.builtin.include_tasks" => serve_tasks, "tags" => ["always"] }]
    }]), mode: "w", perm: 0o600)
    arguments = ["ansible-playbook", "-i", "localhost,", "-c", "local", playbook]
    arguments += ["--check"] if check_mode
    arguments += ["--tags", tags] if tags
    stdout, stderr, status = Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1", "TS_STATE" => state.to_s, "TS_KEY" => node_key,
        "TS_DENY" => deny.to_s, "TS_LOG" => log },
      *arguments, chdir: ROOT
    )
    { "ok" => status.success?, "output" => "#{stdout}\n#{stderr}",
      "mutations" => File.read(log).lines.map(&:strip).reject(&:empty?) }
  end
ensure
  stub_server&.close
end

# `mutations` is the exact argv, since only it shows the RIGHT front was placed.
PLACEMENT = "MUTATE serve --bg --yes #{SERVE_PORT}"
VERIFY_TAG = "platform_verify_vaultwarden"
CASES = [
  { "name" => "already_fronted",
    "why" => "the declared front is in place, so the stage must place nothing: " \
             "tailscaled holds this state, so a blind invocation would claim a " \
             "change on every converge and break idempotence",
    "run" => { state: :fronted }, "ok" => true, "mutations" => [] },
  { "name" => "case_variant",
    "why" => "THE DEFECT THIS FILE WAS WRITTEN FOR. tailscaled lowercases " \
             "Self.DNSName and PLATFORM_PUBLIC_HOST is a raw environment " \
             "lookup, so an operator's capitalisation must not make the stage " \
             "re-place an identical front -- which would converge and page " \
             "through Pushover every five minutes, forever, with nothing wrong",
    "run" => { state: :fronted, public_host: SHOUTY_NAME }, "ok" => true, "mutations" => [] },
  { "name" => "recorded_key_variant",
    "why" => "the other side of the same normalisation. tailscaled is believed " \
             "to hold Self.DNSName lowercased, which would make lowering the " \
             "RECORDED keys redundant -- so this row supplies a shouty recorded " \
             "key and makes it load-bearing instead. The stage does not depend " \
             "on that belief being right, and this is what says so: without " \
             "this row the self-test showed the document-side lowering could be " \
             "deleted with every case still green",
    "run" => { state: :fronted, node_key: SHOUTY_NAME }, "ok" => true, "mutations" => [] },
  { "name" => "localhost_spelling",
    "why" => "the CLI records the target it resolved rather than the one it was " \
             "handed, so the loopback spelling must not read as drift either",
    "run" => { state: :localhost_spelling }, "ok" => true, "mutations" => [] },
  { "name" => "drifted",
    "why" => "a front pointing somewhere else is repaired, and repaired to this " \
             "service's own port",
    "run" => { state: :drifted }, "ok" => true, "mutations" => [PLACEMENT] },
  { "name" => "unconfigured_message",
    "why" => "a host with no serve configuration is a state, not an error, and " \
             "the front is placed",
    "run" => { state: :unconfigured_message }, "ok" => true, "mutations" => [PLACEMENT] },
  { "name" => "unconfigured_null",
    "why" => "the same host under the reading of runServeStatus that says " \
             "--json emits null at rc 0. No build has been observed doing this " \
             "-- see unconfigured_empty below for what one really does -- and " \
             "the row stays because the stage must survive whichever build App " \
             "Central ships to the NAS",
    "run" => { state: :unconfigured_null }, "ok" => true, "mutations" => [PLACEMENT] },
  { "name" => "unconfigured_empty",
    "why" => "THE SHAPE THE REAL CLIENT EMITS, measured on 1.102.3: an " \
             "unconfigured host answers `{}` at rc 0. The two rows above were " \
             "both guesses at this state, and the stage is right for the same " \
             "reason on all three -- an empty document has no proxy to find, so " \
             "the front is placed",
    "run" => { state: :unconfigured_empty }, "ok" => true, "mutations" => [PLACEMENT] },
  { "name" => "cli_refuses",
    "why" => "a client whose command shape no longer matches these arguments is " \
             "a real fault on the one host that matters, so it fails by name " \
             "rather than being read as a host that simply is not serving",
    "run" => { state: :refuses }, "ok" => false, "mutations" => [],
    "says" => "did not report an absent serve configuration" },
  { "name" => "binary_absent",
    "why" => "the path every CI lane, the Mac lane and a workstation take. It " \
             "reports and continues: failing here would turn all of them red " \
             "for a facility they are not meant to have. It is also the Mac " \
             "lane's exact configuration rather than an approximation of it: " \
             "the driver above passes an EMPTY candidate list, which is what " \
             "tests/mac/lib.sh requests, because the first default candidate is " \
             "a path a Mac can really have and a disposable sandbox must not " \
             "reach an operator's own tailnet through it",
    "run" => { state: :fronted, binary: :absent }, "ok" => true, "mutations" => [],
    "says" => "No Tailscale client was found at any path, because this run was given no candidates" },
  { "name" => "gate_off",
    "why" => "with the stack dark the stage reads and reports but places " \
             "nothing, and leaves an existing entry alone because Serve state " \
             "belongs to the tailnet node rather than to this stack",
    "run" => { state: :unconfigured_message, gate: false }, "ok" => true, "mutations" => [],
    "says" => "there is no Vaultwarden to front" },
  { "name" => "check_mode",
    "why" => "a `command` task is skipped under --check, which CLAUDE.md names " \
             "as the bug class the integration suite exists to catch, so the " \
             "reviewer is told what a live run would do instead of reading a " \
             "green skip",
    "run" => { state: :unconfigured_message, check_mode: true }, "ok" => true,
    "mutations" => [], "says" => "A live run would" },
  { "name" => "operator_denied",
    "why" => "THE FAILURE THIS ROW WAS ADDED FOR, taken from the live NAS on " \
             "2026-09-11. Writing serve configuration is privileged and the " \
             "deploy account had not been granted the operator role, so the " \
             "converge died at site.yml's last role on a raw rc=1, readable " \
             "only because tailscale's own stderr happens to name the remedy. " \
             "The stage now names it in platform terms, and resolves the " \
             "account to grant from the run's own facts rather than writing a " \
             "name down -- which is why this row gathers them and expects its " \
             "own account in the message. The placement is still attempted, " \
             "which is what the mutation line records",
    "run" => { state: :unconfigured_empty, deny: :operator, gather: true },
    "ok" => false, "mutations" => [PLACEMENT],
    "says" => "sudo tailscale set --operator=#{ACCOUNT}" },
  { "name" => "placement_other_failure",
    "why" => "THE OTHER HALF, AND THE ONE THAT KEEPS THE FIRST HONEST. A " \
             "denial has a known remedy and an arbitrary failure does not, so " \
             "reporting every non-zero exit as `grant the operator` would send " \
             "a reader to a host act that fixes nothing -- the guard that " \
             "reintroduces the bug through another door. A tailscaled that is " \
             "not running must therefore fail with its own output intact and " \
             "must not mention the operator at all",
    "run" => { state: :unconfigured_empty, deny: :daemon },
    "ok" => false, "mutations" => [PLACEMENT],
    "says" => "failed to connect to local tailscaled",
    "says_not" => "--operator=" },
  { "name" => "unreachable_front",
    "why" => "Serve accepts the configuration whether or not the tailnet has " \
             "HTTPS certificates enabled, and that console setting is the one " \
             "thing no check in this repository can read -- so the front is " \
             "proved by using it, and the refusal names the setting",
    "run" => { state: :fronted, alive: false }, "ok" => false, "mutations" => [],
    "says" => "ENABLED FOR THE TAILNET" },
  # verify.yml lists this role under [never], so these rows run under
  # --tags platform_verify_vaultwarden (#610).
  { "name" => "verify_unreachable_front",
    "why" => "the monitor itself: under verification the probe of the HTTPS " \
             "front must run and a non-200 must fail. It is the failing stub on " \
             "purpose, because a tag selection that selected nothing also exits 0",
    "run" => { state: :fronted, alive: false, tags: VERIFY_TAG }, "ok" => false,
    "mutations" => [], "says" => "ENABLED FOR THE TAILNET" },
  { "name" => "verify_places_nothing",
    "why" => "verification must never write: a host whose Serve configuration " \
             "differs gets no placement from verify.yml, only the probe, which " \
             "here answers 200",
    "run" => { state: :drifted, tags: VERIFY_TAG }, "ok" => true, "mutations" => [] },
  { "name" => "verify_binary_absent",
    "why" => "the absence path again, under verification. The Mac lane runs " \
             "verify.yml with this tag and an empty candidate list, so the " \
             "discovery the probe depends on must be selected too, or the " \
             "report meets an undefined vaultwarden_tailscale_path",
    "run" => { state: :fronted, binary: :absent, tags: VERIFY_TAG }, "ok" => true,
    "mutations" => [],
    "says" => "No Tailscale client was found at any path, because this run was given no candidates" },
  { "name" => "verify_check_mode",
    "why" => "a review under verification probes nothing and fails nothing, " \
             "the same as a review of the converge",
    "run" => { state: :fronted, alive: false, tags: VERIFY_TAG, check_mode: true },
    "ok" => true, "mutations" => [] },
  { "name" => "verify_discovered_unreachable_front",
    "why" => "PRODUCTION'S SHAPE, which every other row skips: they set " \
             "vaultwarden_tailscale_binary, and that short-circuits the Locate " \
             "task. The NAS leaves it empty, so under verification the client " \
             "is found only if Locate is selected too -- without it the run " \
             "reports no Tailscale client, exits 0 and never probes",
    "run" => { state: :fronted, binary: :absent, candidates: :stub, alive: false,
               tags: VERIFY_TAG },
    "ok" => false, "mutations" => [], "says" => "ENABLED FOR THE TAILNET" }
].freeze

def case_problems(row, serve_tasks: SERVE_TASKS)
  result = run_serve(**row.fetch("run"), serve_tasks: serve_tasks)
  problems = []
  if result.fetch("ok") != row.fetch("ok")
    problems << "#{row.fetch('name')}: expected the run to " \
                "#{row.fetch('ok') ? 'succeed' : 'fail'} and it did not"
  end
  if result.fetch("mutations") != row.fetch("mutations")
    problems << "#{row.fetch('name')}: expected the stage to hand the CLI " \
                "#{row.fetch('mutations').inspect} and it handed it " \
                "#{result.fetch('mutations').inspect}"
  end
  says = row["says"]
  if says && !result.fetch("output").include?(says)
    problems << "#{row.fetch('name')}: the run never said #{says.inspect}"
  end
  # Proves the operator is NOT blamed for an unrelated failure.
  says_not = row["says_not"]
  if says_not && result.fetch("output").include?(says_not)
    problems << "#{row.fetch('name')}: the run said #{says_not.inspect}, which " \
                "this failure is not a case of"
  end
  problems
end

# Plants: one-edit regressions in the shipped stage, and the rows each must break.
MUTATIONS = [
  { "name" => "the Serve lookup stops normalising case",
    "from" => "[(platform_public_host ~ ':' ~ vaultwarden_tailscale_serve_port) | lower]",
    "to" => "[platform_public_host ~ ':' ~ vaultwarden_tailscale_serve_port]",
    "breaks" => %w[case_variant] },
  { "name" => "the recorded Serve keys stop being normalised",
    "from" => "| map(attribute='key') | map('lower') | list",
    "to" => "| map(attribute='key') | list",
    "breaks" => %w[recorded_key_variant] },
  { "name" => "the placement stops reading the current configuration first",
    "from" => "        - not vaultwarden_serve_fronted\n",
    "to" => "",
    "breaks" => %w[already_fronted case_variant localhost_spelling] },
  { "name" => "an unusable client is read as a host that is not serving",
    "from" => "          - vaultwarden_serve_status.rc == 0 or vaultwarden_serve_unconfigured\n",
    "to" => "          - true\n",
    "breaks" => %w[cli_refuses] },
  { "name" => "the loopback spellings stop being treated as one",
    "from" => "is match('^http://(127\\.0\\.0\\.1|localhost):' ~ vaultwarden_port ~ '/?$')",
    "to" => "is match('^http://127\\.0\\.0\\.1:' ~ vaultwarden_port ~ '/?$')",
    "breaks" => %w[localhost_spelling] },
  # Planted in both directions: too narrow loses the refusal, too wide blames the operator.
  { "name" => "the operator denial is no longer told apart from any other failure",
    "from" => "        - >-\n          'serve config denied'\n" \
              "          not in (vaultwarden_serve_placed.stderr | default('', true) | lower)\n" \
              "          and 'access denied'\n" \
              "          not in (vaultwarden_serve_placed.stderr | default('', true) | lower)\n",
    "to" => "        - true\n",
    "breaks" => %w[operator_denied] },
  { "name" => "every placement failure is reported as a missing operator grant",
    "from" => "        - >-\n          'serve config denied'\n" \
              "          not in (vaultwarden_serve_placed.stderr | default('', true) | lower)\n" \
              "          and 'access denied'\n" \
              "          not in (vaultwarden_serve_placed.stderr | default('', true) | lower)\n",
    "to" => "        - false\n",
    "breaks" => %w[placement_other_failure] },
  { "name" => "the unreachable front stops being refused",
    "from" => "          - vaultwarden_serve_reachability.status | default(0) | int == 200\n",
    "to" => "          - true\n",
    "breaks" => %w[unreachable_front] },
  # The verify.yml selection, planted in all three ways it can be lost.
  { "name" => "the tailnet assertion is no longer selected by verification",
    "from" => "    - name: Require Vaultwarden reachable over the tailnet HTTPS front\n" \
              "      tags: [platform_verify_vaultwarden]\n",
    "to" => "    - name: Require Vaultwarden reachable over the tailnet HTTPS front\n",
    "breaks" => %w[verify_unreachable_front] },
  { "name" => "the client discovery is no longer selected by verification",
    "from" => "- name: Resolve the Tailscale client this host holds\n" \
              "  tags: [platform_verify_vaultwarden]\n",
    "to" => "- name: Resolve the Tailscale client this host holds\n",
    "breaks" => %w[verify_binary_absent verify_places_nothing] },
  { "name" => "the client search is no longer selected by verification",
    "from" => "- name: Locate the Tailscale client on this host\n" \
              "  tags: [platform_verify_vaultwarden]\n",
    "to" => "- name: Locate the Tailscale client on this host\n",
    "breaks" => %w[verify_discovered_unreachable_front] },
  { "name" => "the placement becomes reachable from verification",
    "from" => "    - name: Place the Tailscale Serve front for Vaultwarden\n",
    "to" => "    - name: Place the Tailscale Serve front for Vaultwarden\n" \
            "      tags: [platform_verify_vaultwarden]\n",
    "breaks" => %w[verify_places_nothing] }
].freeze

def self_test_problems
  source = File.read(SERVE_TASKS)
  problems = []
  MUTATIONS.each do |mutation|
    unless source.include?(mutation.fetch("from"))
      problems << "the plant #{mutation.fetch('name').inspect} no longer matches the stage; " \
                  "re-anchor it rather than deleting it"
      next
    end
    Dir.mktmpdir("nas-platform-vaultwarden-serve-plant-") do |directory|
      planted = File.join(directory, "serve.yml")
      File.write(planted, source.sub(mutation.fetch("from"), mutation.fetch("to")),
                 mode: "w", perm: 0o600)
      undetected = mutation.fetch("breaks").reject do |name|
        row = CASES.find { |candidate| candidate.fetch("name") == name }
        !case_problems(row, serve_tasks: planted).empty?
      end
      unless undetected.empty?
        problems << "planting #{mutation.fetch('name').inspect} left " \
                    "#{undetected.inspect} passing, so those rows assert nothing"
      end
      puts "plant detected: #{mutation.fetch('name')} (by #{mutation.fetch('breaks').join(', ')})"
    end
  end
  problems
end

failures = []
# Floor under the roster, so an emptied CASES cannot report success.
check_floor(failures, CASES.length, 20, "Vaultwarden Serve cases")
check_floor(failures, MUTATIONS.length, 12, "Vaultwarden Serve plants")
check(failures, File.file?(SERVE_TASKS),
      "roles/vaultwarden/tasks/serve.yml must exist for this check to have a subject")

if ARGV.include?("--self-test")
  self_test_problems.each { |problem| failures << problem }
else
  CASES.each { |row| case_problems(row).each { |problem| failures << problem } }
end

report(failures,
       ARGV.include?("--self-test") ?
         "Vaultwarden Serve: all #{MUTATIONS.length} planted regressions are detected" :
         "Vaultwarden Serve: all #{CASES.length} behaviours of the shipped stage hold",
       "Vaultwarden Serve violation(s)")
