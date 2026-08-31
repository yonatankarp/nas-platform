#!/usr/bin/env ruby
# Validate and execute every registered service contract.

require "open3"
require "rbconfig"
require "pathname"
require "timeout"
require "yaml"
require_relative "policy_support"

include PolicySupport
include TestScaffold

arguments = ARGV.dup
# Static validation is the safe default; service probes run only when the
# post-converge integration lifecycle explicitly requests --execute.
mode = arguments.first&.start_with?("--") ? arguments.shift : "--validate-only"
unless %w[--validate-only --execute].include?(mode) && arguments.length <= 1
  abort "usage: run_contracts.rb [--validate-only|--execute] [repository-root]"
end

ROOT = File.expand_path(arguments.fetch(0, File.expand_path("..", __dir__)))
CONTRACT_ROOT = File.join(ROOT, "tests", "contracts")
REGISTRY_PATH = File.join(CONTRACT_ROOT, "registry.yml")
MANIFEST_PATH = File.join(ROOT, "services", "manifest.yml")
CONTRACT_ENV_NAMES = %w[
  PLATFORM_KIND PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE PLATFORM_DOCKER_ROOT
  PLATFORM_MEDIA_ROOT PLATFORM_FIXTURE_ROOT PLATFORM_REPORT_ROOT
].freeze
failures = []

def owned_contract?(path)
  owned_file?(path, CONTRACT_ROOT) && symlink_free_below?(ROOT, path)
end

def load_strict_yaml(path, label, failures)
  duplicate_yaml_keys(Psych.parse_stream(File.read(path))).uniq.each do |key|
    check(failures, false, "#{label} contains duplicate mapping key #{key}")
  end
  YAML.safe_load_file(path)
rescue Errno::ENOENT
  check(failures, false, "#{label} is missing")
  nil
rescue Psych::Exception => e
  check(failures, false, "#{label} is malformed: #{e.message.lines.first.strip}")
  nil
end

registry_owned = owned_file?(REGISTRY_PATH, CONTRACT_ROOT) && symlink_free_below?(ROOT, REGISTRY_PATH)
check(failures, registry_owned, "contract registry must be a regular non-symlink file")
registry = registry_owned ? load_strict_yaml(REGISTRY_PATH, "contract registry", failures) : nil

check(failures, registry.is_a?(Hash), "contract registry top level must be a mapping")
check(failures, registry.is_a?(Hash) && registry.keys == ["contracts"],
      "contract registry must contain exactly a contracts list")
entries = registry.is_a?(Hash) ? registry["contracts"] : nil
check(failures, entries.is_a?(Array), "contract registry must contain a contracts list")
entries = [] unless entries.is_a?(Array)

services_root = File.join(ROOT, "services")
manifest_owned = owned_file?(MANIFEST_PATH, services_root) && symlink_free_below?(ROOT, MANIFEST_PATH)
check(failures, manifest_owned, "service manifest must be a regular non-symlink file")
manifest = manifest_owned ? load_strict_yaml(MANIFEST_PATH, "service manifest", failures) : nil
manifest_entries = manifest.is_a?(Hash) ? manifest["services"] : nil
check(failures, manifest_entries.is_a?(Array), "service manifest must contain a services list")
manifest_entries = [] unless manifest_entries.is_a?(Array)
service_statuses = {}
manifest_entries.each do |entry|
  valid = entry.is_a?(Hash) && entry["name"].is_a?(String) && entry["status"].is_a?(String)
  check(failures, valid, "service manifest entries require string name and status")
  if valid
    check(failures, %w[planned implemented accepted].include?(entry["status"]),
          "#{entry['name']}: service manifest status is invalid")
    check(failures, !service_statuses.key?(entry["name"]),
          "service manifest names must be unique")
    service_statuses[entry["name"]] = entry["status"]
  end
end

entries.each do |entry|
  unless entry.is_a?(Hash)
    check(failures, false, "each contract registry entry must be a mapping")
    next
  end
  check(failures, entry.keys.sort == %w[path service],
        "contract registry entries require exactly service and path")
  check(failures, entry["service"].is_a?(String) && !entry["service"].empty?,
        "contract registry service must be a nonempty string")
  check(failures, entry["path"].is_a?(String) && !entry["path"].empty?,
        "contract registry path must be a nonempty string")

  service = entry["service"]
  next unless service.is_a?(String) && entry["path"].is_a?(String)

  check(failures, service_statuses.key?(service), "#{service}: contract service is not declared in manifest")
  check(failures, %w[implemented accepted].include?(service_statuses[service]),
        "#{service}: contract service must be implemented or accepted")
  basename = contract_basename(service)
  canonical_path = "tests/contracts/#{basename}.sh"
  check(failures, entry["path"] == canonical_path,
        "#{service}: contract must use canonical path #{canonical_path}")
end

%w[service path].each do |field|
  values = entries.filter_map { |entry| entry[field] if entry.is_a?(Hash) }
  duplicates = values.tally.select { |_value, count| count > 1 }.keys
  check(failures, duplicates.empty?, "contract registry #{field} values must be unique")
end

entries.each do |entry|
  next unless entry.is_a?(Hash) && entry["path"].is_a?(String)

  relative_path = Pathname.new(entry["path"])
  expected_parent = Pathname.new("tests/contracts")
  check(failures, relative_path.cleanpath == relative_path && relative_path.dirname == expected_parent &&
                  relative_path.extname == ".sh",
        "#{entry['service']}: contract path must be directly beneath tests/contracts")
  path = File.expand_path(entry["path"], ROOT)
  check(failures, owned_contract?(path),
        "#{entry['service']}: contract must be a regular non-symlink file")
  check(failures, File.executable?(path) && File.size?(path),
        "#{entry['service']}: contract must be executable and nonempty") if owned_contract?(path)
end

unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} contract registry violation(s)"
end

# A contract is a thin shell wrapper around embedded Ruby: across the registered
# contracts the Ruby outweighs the shell roughly twenty to one. `sh -n` treats a
# quoted heredoc as opaque text, so on its own it proves only that the wrapper
# parses, and a Ruby syntax error inside a heredoc survived validation entirely
# until it was reached by an actual integration run. Each heredoc body is therefore
# parsed as Ruby here too, which is the only static check that ever sees it.
def ruby_heredoc_bodies(source)
  bodies = []
  current = nil
  source.each_line do |line|
    if current
      if line.chomp == "RUBY"
        bodies << current
        current = nil
      else
        current << line
      end
    elsif line.include?("<<'RUBY'")
      current = +""
    end
  end
  # An unterminated heredoc is itself a defect worth reporting rather than dropping.
  bodies << current if current
  bodies
end

entries.each do |entry|
  path = File.expand_path(entry.fetch("path"), ROOT)
  _stdout, _stderr, syntax = Open3.capture3("sh", "-n", path)
  unless syntax.success?
    warn "FAIL #{entry.fetch('service')} #{entry.fetch('path')}: contract shell syntax is invalid"
    exit 1
  end

  ruby_heredoc_bodies(File.read(path)).each_with_index do |body, index|
    _out, err, ruby_syntax = Open3.capture3(RbConfig.ruby, "-c", stdin_data: body)
    next if ruby_syntax.success?

    warn "FAIL #{entry.fetch('service')} #{entry.fetch('path')}: " \
         "embedded Ruby block #{index + 1} has invalid syntax"
    warn err.lines.first(3).map { |l| "  #{l.rstrip}" }.join("\n")
    exit 1
  end
end

# The same defect, one file over. Issue #147 promotes each of those heredoc
# bodies to a Ruby file beside its caller, invoked with arguments, and a file is
# no more visible to `sh -n` than a heredoc was. Without the sweep below the
# extraction would silently retire the only static check that ever reads the
# code, so both shapes are parsed here and both stay legal.
#
# Two properties of the sibling shape an extraction has to preserve, recorded
# here because this is the file whoever writes one will be reading:
#
#   * A heredoc consumes the caller's stdin by construction. A sibling program
#     does not, so it must be invoked with `</dev/null` or it reads the stdin of
#     whatever invoked the contract. tests/mac/run.sh:225-236 is the worked
#     example, and tests/run_contracts_test.rb exercises both outcomes rather
#     than this file policing the wrapper's text: the invocations already span
#     continuation lines, and a line-shaped rule would dictate their layout.
#   * The heredocs run under `-ryaml -rjson -rpathname -rdigest` preloads. The
#     sibling form carries them verbatim -- `ruby -ryaml program.rb "$@"` -- and
#     that form never consults the shebang, which is why no execute bit is
#     required below. The library at tests/contracts/support is mode 0644 today.
#
# A program is found two ways because either way alone leaves a hole. The glob
# reaches one no contract names in full, such as the `-r` preload
# tests/contracts/support/beszel_telemetry, whose path carries no extension. The
# reference scan reaches the opposite case, a path a contract names that does not
# exist, which a glob can never notice. It skips a commented-out line so a
# retired invocation does not keep demanding its program, but a path named
# anywhere else, a trailing comment included, is read as a reference.
def ruby_program_references(source)
  source.each_line.reject { |line| line.lstrip.start_with?("#") }
        .flat_map { |line| line.scan(%r{tests/contracts/[A-Za-z0-9_./-]+\.rb}) }
        .map { |reference| Pathname.new(reference).cleanpath.to_s }
        .uniq
end

referenced_programs = {}
entries.each do |entry|
  source = File.read(File.expand_path(entry.fetch("path"), ROOT))
  ruby_program_references(source).each { |reference| referenced_programs[reference] ||= entry }
end

referenced_programs.each do |reference, entry|
  next if File.exist?(File.expand_path(reference, ROOT))

  warn "FAIL #{entry.fetch('service')} #{entry.fetch('path')}: " \
       "sibling Ruby program #{reference} is missing"
  exit 1
end

globbed_programs = Dir.glob("**/*.rb", base: CONTRACT_ROOT).map { |name| "tests/contracts/#{name}" }
(globbed_programs | referenced_programs.keys).sort.each do |relative|
  path = File.expand_path(relative, ROOT)
  unless owned_contract?(path) && File.size?(path)
    warn "FAIL #{relative}: sibling Ruby program must be a nonempty regular non-symlink file"
    exit 1
  end

  _out, err, ruby_syntax = Open3.capture3(RbConfig.ruby, "-c", path)
  next if ruby_syntax.success?

  warn "FAIL #{relative}: sibling Ruby program has invalid syntax"
  warn err.lines.first(3).map { |l| "  #{l.rstrip}" }.join("\n")
  exit 1
end

if mode == "--validate-only"
  puts "contracts: all registered contracts validated"
  exit 0
end

timeout_text = ENV.fetch("CONTRACT_TIMEOUT_SECONDS", "60")
unless timeout_text.match?(/\A(?:\d+(?:\.\d+)?|\.\d+)\z/) && timeout_text.to_f.positive? && timeout_text.to_f <= 300
  abort "CONTRACT_TIMEOUT_SECONDS must be greater than 0 and at most 300"
end
contract_timeout = timeout_text.to_f

missing_contract_env = CONTRACT_ENV_NAMES.reject { |name| ENV[name].is_a?(String) && !ENV[name].empty? }
unless missing_contract_env.empty?
  abort "contract environment ABI is missing required names: #{missing_contract_env.join(', ')}"
end
unless ENV["PLATFORM_KIND"] == "integration" &&
       (CONTRACT_ENV_NAMES - ["PLATFORM_KIND"]).all? { |name| Pathname.new(ENV.fetch(name)).absolute? }
  abort "contract environment ABI has invalid kind or non-absolute paths"
end
contract_environment = CONTRACT_ENV_NAMES.to_h { |name| [name, ENV.fetch(name)] }

entries.each do |entry|
  path = File.expand_path(entry.fetch("path"), ROOT)
  pid = Process.spawn(contract_environment, path, chdir: ROOT, pgroup: true,
                      out: File::NULL, err: File::NULL)
  execution = nil
  timed_out = false
  begin
    Timeout.timeout(contract_timeout) { _waited, execution = Process.wait2(pid) }
  rescue Timeout::Error
    timed_out = true
    begin
      Process.kill("TERM", -pid)
    rescue Errno::ESRCH
      nil
    end
    reaped = false
    begin
      Timeout.timeout(1) do
        Process.wait(pid)
        reaped = true
      end
    rescue Timeout::Error
      nil
    rescue Errno::ECHILD
      reaped = true
    end
    begin
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end
    Process.wait(pid) unless reaped
  end

  if timed_out
    warn "FAIL #{entry.fetch('service')} #{entry.fetch('path')}: contract timed out"
    exit 1
  end
  next if execution&.success?

  warn "FAIL #{entry.fetch('service')} #{entry.fetch('path')}: contract failed with exit #{execution&.exitstatus}"
  exit execution&.exitstatus || 1
end

puts "contracts: all registered contracts passed"
