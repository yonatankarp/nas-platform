#!/usr/bin/env ruby
# Focused execution checks for the machine-readable service contract registry.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
failures = []

def run_registry(registry:, contracts: {})
  Dir.mktmpdir("nas-platform-contracts-") do |root|
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
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, File.join(ROOT, "tests", "run_contracts.rb"), root
    )
    [stdout + stderr, status]
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
check(failures, status.success?, "valid registered helper contract failed: #{output.lines.first&.strip}")

output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\nif then\n" }
)
check(failures, !status.success? && output.include?("shell syntax"),
      "syntax-invalid contract was not rejected clearly")

output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\nexit 7\n" }
)
check(failures, !status.success? && output.include?("contract failed"),
      "nonzero contract execution was not propagated")

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

if failures.empty?
  puts "contracts: all registry checks hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} contract registry regression(s)"
end
