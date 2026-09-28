#!/usr/bin/env ruby
# frozen_string_literal: true

# What roles/dozzle/tasks/serve.yml does, proved by running it: the Tailscale
# Serve TCP forward golem's Dozzle agent reaches the alert relay through.
#
# The same method as tests/vaultwarden_serve_test.rb, whose header carries the
# argument: each case includes the shipped stage unmodified in a one-task driver
# playbook, points dozzle_tailscale_binary at a stub CLI, and reads back the
# argv of any mutation. Only the NAS takes the present-Tailscale branch and no
# lane reaches it, so this is the only place that branch runs before merge.
#
# The stub's configured shape is tailscale 1.102.2's, read from its source:
# ipn.ServeConfig's `TCP map[uint16]*TCPPortHandler` marshals the port as a
# string key and TCPForward as host:port, and a bare-port target expands to
# 127.0.0.1 (ipn/serve.go ExpandProxyTargetValue). `{}` at rc 0 is what an
# unconfigured 1.102.3 was measured to emit.

require "etc"
require "open3"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)
SERVE_TASKS = File.join(ROOT, "roles", "dozzle", "tasks", "serve.yml")
RELAY_PORT = 8081
ACCOUNT = Etc.getpwuid(Process.uid).name
VAULTWARDEN_WEB = '"Web":{"nas.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8086"}}}}'

STUB = <<~SH
  #!/bin/sh
  if [ "$1" = serve ] && [ "$2" = status ]; then
    case "$TS_STATE" in
      forwarded)
        printf '{"TCP":{"443":{"HTTPS":true},"#{RELAY_PORT}":{"TCPForward":"127.0.0.1:#{RELAY_PORT}"}},%s}\\n' '#{VAULTWARDEN_WEB}'
        exit 0 ;;
      localhost_spelling)
        printf '{"TCP":{"#{RELAY_PORT}":{"TCPForward":"localhost:#{RELAY_PORT}"}}}\\n'
        exit 0 ;;
      drifted)
        printf '{"TCP":{"#{RELAY_PORT}":{"TCPForward":"127.0.0.1:9999"}}}\\n'
        exit 0 ;;
      web_only)
        printf '{"TCP":{"443":{"HTTPS":true}},%s}\\n' '#{VAULTWARDEN_WEB}'
        exit 0 ;;
      unconfigured_empty) printf '{}\\n'; exit 0 ;;
      refuses) printf 'flag provided but not defined: -json\\n' >&2; exit 2 ;;
    esac
  fi
  printf 'MUTATE %s\\n' "$*" >> "$TS_LOG"
  case "$TS_DENY" in
    operator)
      printf 'sending serve config: Access denied: serve config denied\\n' >&2
      exit 1 ;;
    daemon)
      printf 'failed to connect to local tailscaled; is it running?\\n' >&2
      exit 1 ;;
  esac
  exit 0
SH

def run_serve(state:, binary: :stub, check_mode: false, deny: "", gather: false,
              serve_tasks: SERVE_TASKS)
  Dir.mktmpdir("nas-platform-dozzle-serve-") do |directory|
    log = File.join(directory, "mutations.log")
    File.write(log, "")
    stub = File.join(directory, "tailscale")
    File.write(stub, STUB, mode: "w", perm: 0o700)
    playbook = File.join(directory, "driver.yml")
    File.write(playbook, YAML.dump([{
      "hosts" => "localhost", "gather_facts" => gather,
      "vars" => {
        "dozzle_alert_relay_port" => RELAY_PORT,
        "dozzle_tailscale_binary" => binary == :stub ? stub : "",
        # Empty, so the absent case finds nothing rather than whatever this
        # machine has installed -- which is also the Mac lane's configuration.
        "dozzle_tailscale_binary_candidates" => []
      },
      "tasks" => [{ "ansible.builtin.include_tasks" => serve_tasks }]
    }]), mode: "w", perm: 0o600)
    arguments = ["ansible-playbook", "-i", "localhost,", "-c", "local", playbook]
    arguments << "--check" if check_mode
    stdout, stderr, status = Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1", "TS_STATE" => state.to_s, "TS_DENY" => deny.to_s, "TS_LOG" => log },
      *arguments, chdir: ROOT
    )
    { "ok" => status.success?, "output" => "#{stdout}\n#{stderr}",
      "mutations" => File.read(log).lines.map(&:strip).reject(&:empty?) }
  end
end

PLACEMENT = "MUTATE serve --bg --yes --tcp #{RELAY_PORT} #{RELAY_PORT}"
CASES = [
  { "name" => "already_forwarded", "run" => { state: :forwarded }, "ok" => true, "mutations" => [],
    "why" => "tailscaled holds this state, so placing it again would claim a change every converge" },
  { "name" => "localhost_spelling", "run" => { state: :localhost_spelling }, "ok" => true, "mutations" => [],
    "why" => "a forward placed as tcp://localhost:<port> records that spelling and is the same forward" },
  { "name" => "vaultwarden_only", "run" => { state: :web_only }, "ok" => true, "mutations" => [PLACEMENT],
    "why" => "the NAS as it is before this change: Vaultwarden's HTTPS front and no forward yet" },
  { "name" => "unconfigured", "run" => { state: :unconfigured_empty }, "ok" => true, "mutations" => [PLACEMENT],
    "why" => "an unconfigured host answers {} and gets the forward" },
  { "name" => "drifted", "run" => { state: :drifted }, "ok" => true, "mutations" => [PLACEMENT],
    "why" => "a forward to another port is repaired to the relay's" },
  { "name" => "cli_refuses", "run" => { state: :refuses }, "ok" => false, "mutations" => [],
    "says" => "did not report an absent serve configuration",
    "why" => "a client whose command shape changed fails by name rather than reading as unconfigured" },
  { "name" => "binary_absent", "run" => { state: :forwarded, binary: :absent }, "ok" => true, "mutations" => [],
    "says" => "No Tailscale client was found at any path",
    "why" => "every CI lane and the Mac lane take this path and must stay green" },
  { "name" => "check_mode", "run" => { state: :unconfigured_empty, check_mode: true }, "ok" => true,
    "mutations" => [], "says" => "A live run would run",
    "why" => "a command task is skipped under --check, so the reviewer is told what a live run does" },
  { "name" => "operator_denied", "run" => { state: :unconfigured_empty, deny: :operator, gather: true },
    "ok" => false, "mutations" => [PLACEMENT], "says" => "sudo tailscale set --operator=#{ACCOUNT}",
    "why" => "the denial has one remedy, named in platform terms with the run's own account" },
  { "name" => "other_failure", "run" => { state: :unconfigured_empty, deny: :daemon },
    "ok" => false, "mutations" => [PLACEMENT], "says" => "failed to connect to local tailscaled",
    "says_not" => "--operator=",
    "why" => "any other failure keeps the client's own output and blames no grant" }
].freeze

def case_problems(row, serve_tasks: SERVE_TASKS)
  result = run_serve(**row.fetch("run"), serve_tasks: serve_tasks)
  name = row.fetch("name")
  problems = []
  problems << "#{name}: expected the run to #{row.fetch('ok') ? 'succeed' : 'fail'} (#{row.fetch('why')})" if
    result.fetch("ok") != row.fetch("ok")
  problems << "#{name}: expected #{row.fetch('mutations').inspect}, the stage handed the CLI " \
              "#{result.fetch('mutations').inspect}" if result.fetch("mutations") != row.fetch("mutations")
  problems << "#{name}: the run never said #{row['says'].inspect}" if
    row["says"] && !result.fetch("output").include?(row["says"])
  problems << "#{name}: the run said #{row['says_not'].inspect}" if
    row["says_not"] && result.fetch("output").include?(row["says_not"])
  problems
end

# Plants: each a one-edit regression the rows named must catch.
MUTATIONS = [
  { "name" => "the placement stops reading the current configuration first",
    "from" => "        - not dozzle_serve_forwarded\n", "to" => "",
    "breaks" => %w[already_forwarded localhost_spelling] },
  { "name" => "the forward targets the wildcard rather than loopback",
    "from" => "          - \"{{ dozzle_alert_relay_port }}\"\n      register: dozzle_serve_placed\n",
    "to" => "          - \"tcp://0.0.0.0:{{ dozzle_alert_relay_port }}\"\n      register: dozzle_serve_placed\n",
    "breaks" => %w[unconfigured] },
  { "name" => "every placement failure is reported as a missing operator grant",
    "from" => "        - >-\n          'serve config denied'\n" \
              "          not in (dozzle_serve_placed.stderr | default('', true) | lower)\n" \
              "          and 'access denied'\n" \
              "          not in (dozzle_serve_placed.stderr | default('', true) | lower)\n",
    "to" => "        - false\n",
    "breaks" => %w[other_failure] }
].freeze

failures = []
check_floor(failures, CASES.length, 10, "Dozzle Serve cases")
check(failures, File.file?(SERVE_TASKS), "roles/dozzle/tasks/serve.yml must exist for this check to have a subject")
CASES.each { |row| failures.concat(case_problems(row)) }

source = File.read(SERVE_TASKS)
MUTATIONS.each do |mutation|
  unless source.include?(mutation.fetch("from"))
    failures << "the plant #{mutation.fetch('name').inspect} no longer matches the stage; re-anchor it"
    next
  end
  Dir.mktmpdir("nas-platform-dozzle-serve-plant-") do |directory|
    planted = File.join(directory, "serve.yml")
    File.write(planted, source.sub(mutation.fetch("from"), mutation.fetch("to")), mode: "w", perm: 0o600)
    undetected = mutation.fetch("breaks").select do |name|
      case_problems(CASES.find { |row| row.fetch("name") == name }, serve_tasks: planted).empty?
    end
    failures << "planting #{mutation.fetch('name').inspect} left #{undetected.inspect} passing" unless undetected.empty?
  end
end

report(failures,
       "Dozzle Serve: all #{CASES.length} behaviours hold and all #{MUTATIONS.length} plants are detected",
       "Dozzle Serve violation(s)")
