#!/usr/bin/env ruby
# Focused execution checks for the machine-readable service contract registry.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
failures = []

def run_registry(registry:, contracts: {}, mode: "--validate-only", env: {}, manifest: nil, setup: nil)
  Dir.mktmpdir("nas-platform-contracts-") do |root|
    services_root = File.join(root, "services")
    FileUtils.mkdir_p(services_root)
    manifest ||= YAML.dump(
      "services" => [
        { "name" => "ntfy", "status" => "implemented" },
        { "name" => "paperless-ngx", "status" => "planned" }
      ]
    )
    File.write(File.join(services_root, "manifest.yml"), manifest)
    contract_root = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contract_root)
    File.write(File.join(contract_root, "registry.yml"), registry)
    contracts.each do |name, body|
      path = File.join(contract_root, name)
      if body.is_a?(Hash) && body.key?(:symlink)
        File.symlink(body.fetch(:symlink), path)
      else
        File.write(path, body)
        File.chmod(0o755, path)
      end
    end
    setup&.call(root)
    command = [RbConfig.ruby, File.join(ROOT, "tests", "run_contracts.rb")]
    command << mode if mode
    command << root
    stdout, stderr, status = Open3.capture3(env, *command)
    observation = block_given? ? yield(root) : nil
    [stdout + stderr, status, observation]
  end
end

def check(failures, condition, message)
  failures << message unless condition
end

registry = YAML.dump(
  "contracts" => [{ "service" => "ntfy", "path" => "tests/contracts/ntfy.sh" }]
)

output, status = run_registry(
  registry: registry,
  contracts: {
    "ntfy.sh" => <<~'SH'
      #!/bin/sh
      endpoint=http://127.0.0.1/ntfy/health
      probe() {
        printf '%s\n' "$endpoint" >/dev/null
      }
      probe
    SH
  }
)
check(failures, status.success?, "validate-only rejected helper contract: #{output.lines.first&.strip}")

marker_contract = <<~'SH'
  #!/bin/sh
  pwd -P > contract-ran.txt
SH
output, status, marker = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => marker_contract },
  mode: nil
) { |root| File.exist?(File.join(root, "contract-ran.txt")) }
check(failures, status.success? && !marker, "default mode must validate without execution")

output, status, marker = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => marker_contract },
  mode: "--execute"
) do |root|
  marker = File.join(root, "contract-ran.txt")
  File.file?(marker) && File.read(marker).strip == File.realpath(root)
end
check(failures, status.success? && marker, "execute mode did not run contract from repository root")

output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\nif then\n" }
)
check(failures, !status.success? && output.include?("shell syntax"),
      "syntax-invalid contract was not rejected clearly")

output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\necho SECRET_STDOUT\necho SECRET_STDERR >&2\nexit 7\n" },
  mode: "--execute"
)
check(failures, !status.success? && output.include?("contract failed") &&
                !output.include?("SECRET_STDOUT") && !output.include?("SECRET_STDERR"),
      "nonzero contract execution was not propagated")

output, status, descendant = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\nsleep 30 &\necho $! > descendant.pid\nwait\n" },
  mode: "--execute",
  env: { "CONTRACT_TIMEOUT_SECONDS" => "0.2" }
) do |root|
  pid_path = File.join(root, "descendant.pid")
  next false unless File.file?(pid_path)

  pid = Integer(File.read(pid_path))
  20.times do
    begin
      Process.kill(0, pid)
      sleep 0.05
    rescue Errno::ESRCH
      break
    end
  end
  begin
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
check(failures, !status.success? && output.include?("timed out") && !descendant,
      "timed out contract did not terminate its descendant process group")

output, status = run_registry(
  registry: registry,
  contracts: {
    "shared.sh" => "#!/bin/sh\ntrue\n",
    "ntfy.sh" => { symlink: "shared.sh" }
  }
)
check(failures, !status.success? && output.include?("regular non-symlink file"),
      "symlink contract was not rejected")

duplicate_registry = <<~YAML
  ---
  contracts:
    - service: ntfy
      service: beszel
      path: tests/contracts/ntfy.sh
YAML
output, status = run_registry(registry: duplicate_registry)
check(failures, !status.success? && output.include?("duplicate mapping key service"),
      "duplicate registry key was not rejected clearly")

schema_error_registry = YAML.dump("contracts" => [], "name" => "not registration")
output, status = run_registry(registry: schema_error_registry)
check(failures, !status.success? && output.include?("exactly a contracts list"),
      "extra registry schema keys were not rejected")

planned_registry = YAML.dump(
  "contracts" => [{ "service" => "paperless-ngx", "path" => "tests/contracts/paperless.sh" }]
)
output, status = run_registry(
  registry: planned_registry,
  contracts: { "paperless.sh" => "#!/bin/sh\ntrue\n" }
)
check(failures, !status.success? && output.include?("implemented or accepted"),
      "planned service contract was accepted")

wrong_path_registry = YAML.dump(
  "contracts" => [{ "service" => "ntfy", "path" => "tests/contracts/wrong.sh" }]
)
output, status = run_registry(
  registry: wrong_path_registry,
  contracts: { "wrong.sh" => "#!/bin/sh\ntrue\n" }
)
check(failures, !status.success? && output.include?("canonical path"),
      "wrong contract basename was accepted")

unknown_registry = YAML.dump(
  "contracts" => [{ "service" => "unknown", "path" => "tests/contracts/unknown.sh" }]
)
output, status = run_registry(
  registry: unknown_registry,
  contracts: { "unknown.sh" => "#!/bin/sh\ntrue\n" }
)
check(failures, !status.success? && output.include?("not declared in manifest"),
      "unknown service contract was accepted")

output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\ntrue\n" },
  mode: "--execute",
  env: { "CONTRACT_TIMEOUT_SECONDS" => "unbounded" }
)
check(failures, !status.success? && output.include?("CONTRACT_TIMEOUT_SECONDS"),
      "invalid contract timeout was accepted")

sentinel_path = nil
traversal_registry = YAML.dump(
  "contracts" => [{ "service" => "ntfy", "path" => "../sentinel-contract.sh" }]
)
output, status, sentinel = run_registry(
  registry: traversal_registry,
  setup: lambda do |root|
    sentinel_path = File.join(File.dirname(root), "sentinel-contract.sh")
    File.write(sentinel_path, "DO_NOT_TOUCH")
  end
) { File.read(sentinel_path) }
File.unlink(sentinel_path) if sentinel_path && File.exist?(sentinel_path)
check(failures, !status.success? && sentinel == "DO_NOT_TOUCH",
      "traversal registry path touched a sentinel outside the fixture")

if failures.empty?
  puts "contracts: all registry checks hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} contract registry regression(s)"
end
