#!/usr/bin/env ruby
# frozen_string_literal: true

# What roles/vaultwarden/tasks/serve.yml does, proved by running it.
#
# WHY THIS FILE EXISTS. That stage places the tailnet HTTPS front Bitwarden
# clients require, and until #547's review it had no test of any kind: `grep -rl
# tailscale tests/` returned nothing across 253 lines of task file. The only
# host that takes its present-Tailscale branch is the NAS, which no lane
# reaches, so every property of the branch that actually runs in production was
# resting on reading. That is precisely what it cost -- the case defect the
# `case_variant` row below pins was in the shipped file and no check could have
# said so.
#
# HOW IT RUNS THE REAL THING. Each case writes a one-task driver playbook that
# includes the shipped tasks/serve.yml unmodified, points
# vaultwarden_tailscale_binary at a stub CLI, and runs ansible-playbook against
# localhost. Nothing here re-implements the stage; the stub only decides what
# `tailscale serve status --json` says and records the argv of any mutation, so
# a case's verdict is the stage's own behaviour.
#
# WHAT IS PROVED BY RUNNING VERSUS ASSUMED, stated because the distinction
# matters here more than usual. Proved: everything the stub can answer, which is
# every branch of the stage. Assumed: the exact bytes a real `tailscale serve
# status --json` emits. The stub's configured shapes were taken from tailscale
# 1.102.2's documented Web/Handlers/Proxy structure, and the unconfigured shape
# is modelled as `No serve config` on stderr at rc 1. A reading of tailscale's
# own runServeStatus suggests an unconfigured host under --json emits `null` at
# rc 0 instead, which would make the stage's 'no serve config' string branch
# dead code already covered by its rc == 0 term. THAT IS PLAUSIBLE AND
# UNCONFIRMED -- nobody has run the real binary against this -- so the branch
# stays, this file exercises both shapes, and `unconfigured_null` is the row
# that will still pass if the reading is right.

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

# The node's own name as tailscaled holds it: lowercased, because that is what
# Self.DNSName carries. Cases vary only the operator's exported spelling.
NODE_NAME = "as6704t-4043.tail4e1ae8.ts.net"
SHOUTY_NAME = "AS6704T-4043.Tail4e1ae8.ts.net"
SERVE_PORT = 8086

# A stub `tailscale`. It answers `serve status --json` from TS_STATE and appends
# the argv of anything else to TS_LOG, so a placement is observable as a line
# rather than inferred from Ansible's own changed flag.
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
      unconfigured_null)    printf 'null\\n'; exit 0 ;;
      refuses)              printf 'flag provided but not defined: -json\\n' >&2; exit 2 ;;
    esac
  fi
  printf 'MUTATE %s\\n' "$*" >> "$TS_LOG"
  exit 0
SH

# A server that answers /alive, so the stage's reachability probe -- which is a
# real HTTP request to vaultwarden_domain -- has something to reach. Without it
# every case would end at that assertion and no case could say anything about
# the placement before it.
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

# One case: run the shipped stage and report what it did.
def run_serve(state:, public_host: NODE_NAME, node_key: NODE_NAME, gate: true,
              binary: :stub, check_mode: false, alive: true, serve_tasks: SERVE_TASKS)
  stub_server = AliveStub.new(answer: alive)
  Dir.mktmpdir("nas-platform-vaultwarden-serve-") do |directory|
    log = File.join(directory, "mutations.log")
    File.write(log, "")
    stub = File.join(directory, "tailscale")
    File.write(stub, STUB, mode: "w", perm: 0o700)
    resolved = binary == :stub ? stub : ""
    playbook = File.join(directory, "driver.yml")
    File.write(playbook, YAML.dump([{
      "hosts" => "localhost", "gather_facts" => false,
      "vars" => {
        "platform_public_host" => public_host,
        "vaultwarden_port" => SERVE_PORT,
        "vaultwarden_domain" => "http://127.0.0.1:#{stub_server.port}",
        "vaultwarden_tailscale_serve_port" => 443,
        "vaultwarden_deployment_enabled" => gate,
        "vaultwarden_tailscale_binary" => resolved,
        # Empty, so a case asking for the absent path finds nothing anywhere
        # rather than finding whatever this machine happens to have installed.
        "vaultwarden_tailscale_binary_candidates" => [],
        "platform_readiness_retries" => 1,
        "platform_readiness_delay" => 0
      },
      "tasks" => [{ "ansible.builtin.include_tasks" => serve_tasks }]
    }]), mode: "w", perm: 0o600)
    arguments = ["ansible-playbook", "-i", "localhost,", "-c", "local", playbook]
    arguments += ["--check"] if check_mode
    stdout, stderr, status = Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1", "TS_STATE" => state.to_s, "TS_KEY" => node_key, "TS_LOG" => log },
      *arguments, chdir: ROOT
    )
    { "ok" => status.success?, "output" => "#{stdout}\n#{stderr}",
      "mutations" => File.read(log).lines.map(&:strip).reject(&:empty?) }
  end
ensure
  stub_server&.close
end

# Each row states the whole outcome: did the run succeed, what argv did the
# stage hand the CLI, and which report did it print. `mutations` is exact rather
# than a count, because "it placed a front" and "it placed the RIGHT front" are
# different claims and only the argv carries the second.
PLACEMENT = "MUTATE serve --bg --yes #{SERVE_PORT}"
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
             "through ntfy every five minutes, forever, with nothing wrong",
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
             "--json emits null at rc 0. Unconfirmed against the real binary, " \
             "which is why both shapes are rows here rather than one",
    "run" => { state: :unconfigured_null }, "ok" => true, "mutations" => [PLACEMENT] },
  { "name" => "cli_refuses",
    "why" => "a client whose command shape no longer matches these arguments is " \
             "a real fault on the one host that matters, so it fails by name " \
             "rather than being read as a host that simply is not serving",
    "run" => { state: :refuses }, "ok" => false, "mutations" => [],
    "says" => "did not report an absent serve configuration" },
  { "name" => "binary_absent",
    "why" => "the path every CI lane, the Mac lane and a workstation take. It " \
             "reports and continues: failing here would turn all of them red " \
             "for a facility they are not meant to have",
    "run" => { state: :fronted, binary: :absent }, "ok" => true, "mutations" => [],
    "says" => "No Tailscale client was found at any of" },
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
  { "name" => "unreachable_front",
    "why" => "Serve accepts the configuration whether or not the tailnet has " \
             "HTTPS certificates enabled, and that console setting is the one " \
             "thing no check in this repository can read -- so the front is " \
             "proved by using it, and the refusal names the setting",
    "run" => { state: :fronted, alive: false }, "ok" => false, "mutations" => [],
    "says" => "ENABLED FOR THE TAILNET" }
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
  problems
end

# The plants. Each is a one-edit regression in the shipped stage that a reader
# could plausibly make, and the rows it must break. A checker that reports a
# clean tree proves nothing until it has been shown a defect it is supposed to
# find -- CLAUDE.md records what believing an unproven AST checker cost.
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
  { "name" => "the unreachable front stops being refused",
    "from" => "          - vaultwarden_serve_reachability.status | default(0) | int == 200\n",
    "to" => "          - true\n",
    "breaks" => %w[unreachable_front] }
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
# A floor under the roster, because every list here is walked rather than
# counted: a CASES that emptied would report success having run nothing.
check_floor(failures, CASES.length, 12, "Vaultwarden Serve cases")
check_floor(failures, MUTATIONS.length, 6, "Vaultwarden Serve plants")
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
