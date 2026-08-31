#!/usr/bin/env ruby
# Focused execution checks for the machine-readable service contract registry.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

failures = []

def run_registry(registry:, contracts: {}, mode: "--validate-only", env: {}, manifest: nil, setup: nil,
                 contract_abi: true)
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
      FileUtils.mkdir_p(File.dirname(path))
      if body.is_a?(Hash) && body.key?(:symlink)
        File.symlink(body.fetch(:symlink), path)
      else
        # A sibling program invoked as `ruby program.rb` never consults its
        # shebang, so the mode is the caller's to state rather than a constant.
        content = body.is_a?(Hash) ? body.fetch(:content) : body
        File.write(path, content)
        File.chmod(body.is_a?(Hash) ? body.fetch(:mode, 0o755) : 0o755, path)
      end
    end
    setup&.call(root)
    command = [RbConfig.ruby, File.join(ROOT, "tests", "run_contracts.rb")]
    command << mode if mode
    command << root
    if mode == "--execute" && contract_abi
      env = env.merge(
        "PLATFORM_KIND" => "integration",
        "PLATFORM_CONTRACT_VAULT_FILE" => File.join(root, "sandbox-vault.yml"),
        "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "sandbox-vault-password"),
        "PLATFORM_DOCKER_ROOT" => File.join(root, "volume1", "Docker"),
        "PLATFORM_MEDIA_ROOT" => File.join(root, "volume2"),
        "PLATFORM_FIXTURE_ROOT" => File.join(root, "fixtures"),
        "PLATFORM_REPORT_ROOT" => File.join(root, "reports")
      )
      %w[volume1/Docker volume2 fixtures reports].each do |directory|
        FileUtils.mkdir_p(File.join(root, directory))
      end
      File.write(File.join(root, "sandbox-vault.yml"), "placeholder")
      File.write(File.join(root, "sandbox-vault-password"), "placeholder")
    end
    stdout, stderr, status = Open3.capture3(env, *command)
    observation = block_given? ? yield(root) : nil
    [stdout + stderr, status, observation]
  end
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

abi_contract = <<~'SH'
  #!/bin/sh
  {
    for name in PLATFORM_KIND PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE \
      PLATFORM_DOCKER_ROOT \
      PLATFORM_MEDIA_ROOT PLATFORM_FIXTURE_ROOT PLATFORM_REPORT_ROOT; do
      eval "value=\${$name-}"
      test -n "$value"
      printf '%s=present\n' "$name"
    done
  } > "$PLATFORM_REPORT_ROOT/abi-markers.txt"
SH
output, status, markers = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => abi_contract },
  mode: "--execute"
) do |root|
  File.read(File.join(root, "reports", "abi-markers.txt"))
end
check(failures, status.success? && markers.lines.length == 7 && markers.lines.all? { |line| line.end_with?("=present\n") },
      "execute mode did not propagate the contract environment ABI")

secret_abi_value = "/tmp/ABI_SECRET_VALUE"
output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\ntrue\n" },
  mode: "--execute",
  contract_abi: false,
  env: { "PLATFORM_DOCKER_ROOT" => secret_abi_value }
)
check(failures, !status.success? && output.include?("contract environment ABI") &&
                !output.include?(secret_abi_value),
      "missing contract ABI was accepted or leaked values")

output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\nif then\n" }
)
check(failures, !status.success? && output.include?("shell syntax"),
      "syntax-invalid contract was not rejected clearly")

# A contract is mostly Ruby inside a quoted heredoc, and `sh -n` treats that body as
# opaque text, so the wrapper parsing proves nothing about the code that does the work.
# This is the only static check that reads it; without it a broken contract surfaces
# only when an integration run reaches it.
output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\nruby - <<'RUBY'\ndef broken(\nRUBY\n" }
)
check(failures, !status.success? && output.include?("embedded Ruby block 1 has invalid syntax"),
      "contract with syntax-invalid embedded Ruby was not rejected clearly")

# The wrapper is valid shell and the Ruby is valid Ruby, so this must pass: the check
# has to reject broken bodies without rejecting working contracts.
output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\nruby - <<'RUBY'\nputs \"ok\"\nRUBY\n" }
)
check(failures, status.success?,
      "contract with valid embedded Ruby was rejected: #{output.lines.first&.strip}")

# The other legal shape: the Ruby lives in a file beside the contract and is
# invoked with arguments. Issue #147 moves ~9,800 lines into that shape, so the
# checks below are what keep it as well covered as the heredoc it replaces.
#
# This one fixture pins the four properties an extracted program depends on, and
# it is deliberately the mode-0644 form: `ruby -rjson program.rb` never consults
# a shebang, so requiring an execute bit would have outlawed the only invocation
# that can carry the `-r` preloads the heredocs run under.
sibling_probe = <<~'RUBY'
  #!/usr/bin/env ruby
  # Fixture standing in for tests/contracts/<name>_static.rb.
  abort "preload was not carried" unless defined?(JSON)
  abort "sibling consumed the caller stdin" unless $stdin.read.empty?
  File.write(File.join(ENV.fetch("PLATFORM_REPORT_ROOT"), "probe.txt"), "#{ARGV.join(',')}\n")
RUBY
sibling_contract = <<~'SH'
  #!/bin/sh
  set -eu
  printf 'caller-stdin\n' > "$PLATFORM_REPORT_ROOT/caller-stdin.txt"
  {
    ruby -rjson tests/contracts/ntfy_probe.rb alpha beta </dev/null
    read -r survivor
    printf '%s\n' "$survivor" >> "$PLATFORM_REPORT_ROOT/probe.txt"
  } < "$PLATFORM_REPORT_ROOT/caller-stdin.txt"
SH
output, status, probe = run_registry(
  registry: registry,
  contracts: {
    "ntfy.sh" => sibling_contract,
    "ntfy_probe.rb" => { content: sibling_probe, mode: 0o644 }
  },
  mode: "--execute"
) do |root|
  path = File.join(root, "reports", "probe.txt")
  File.file?(path) ? File.read(path) : nil
end
check(failures, status.success? && probe == "alpha,beta\ncaller-stdin\n",
      "sibling Ruby program was not run with its arguments, preloads and an empty stdin: " \
      "#{probe.inspect} #{output.lines.first&.strip}")

# The trap the sibling shape introduces, demonstrated rather than legislated: a
# heredoc exhausts the caller's stdin by construction, a sibling program inherits
# it, so an invocation missing `</dev/null` eats input the contract still needs.
# tests/mac/run.sh:225-236 carries the same redirect for the same reason. The
# harness does not grep the wrapper for it -- these invocations already span
# continuation lines, and a line-shaped rule would dictate their layout.
output, status, probe = run_registry(
  registry: registry,
  contracts: {
    "ntfy.sh" => sibling_contract.sub(" </dev/null", ""),
    "ntfy_probe.rb" => { content: sibling_probe, mode: 0o644 }
  },
  mode: "--execute"
) do |root|
  File.exist?(File.join(root, "reports", "probe.txt"))
end
check(failures, !status.success? && output.include?("contract failed") && !probe,
      "sibling Ruby program invoked without </dev/null did not consume the caller stdin")

# A file is no more visible to `sh -n` than a heredoc was, so extraction must not
# retire the static parse. This is the check that lets the later PRs move code.
output, status = run_registry(
  registry: registry,
  contracts: {
    "ntfy.sh" => "#!/bin/sh\nruby tests/contracts/ntfy_static.rb \"$1\" </dev/null\n",
    "ntfy_static.rb" => "def broken(\n"
  }
)
check(failures, !status.success? &&
                output.include?("tests/contracts/ntfy_static.rb: sibling Ruby program has invalid syntax"),
      "contract with a syntax-invalid sibling Ruby program was not rejected clearly")

# Both shapes are legal at once, which is what makes the extraction incremental:
# a contract keeps its remaining heredocs while one half moves out.
output, status = run_registry(
  registry: registry,
  contracts: {
    "ntfy.sh" => "#!/bin/sh\nruby - <<'RUBY'\nputs \"ok\"\nRUBY\n" \
                 "ruby -ryaml tests/contracts/ntfy_static.rb \"$1\" </dev/null\n",
    "ntfy_static.rb" => "puts ARGV.inspect\n"
  }
)
check(failures, status.success?,
      "contract mixing a heredoc and a sibling Ruby program was rejected: #{output.lines.first&.strip}")

# A glob can never notice a path that is named but absent, which is what a typo
# in an extracted invocation looks like.
output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\nruby tests/contracts/ntfy_absent.rb </dev/null\n" }
)
check(failures, !status.success? &&
                output.include?("sibling Ruby program tests/contracts/ntfy_absent.rb is missing"),
      "contract naming an absent sibling Ruby program was accepted")

output, status = run_registry(
  registry: registry,
  contracts: {
    "ntfy.sh" => "#!/bin/sh\nruby tests/contracts/ntfy_static.rb </dev/null\n",
    "ntfy_probe.rb" => "puts 1\n",
    "ntfy_static.rb" => { symlink: "ntfy_probe.rb" }
  }
)
check(failures, !status.success? && output.include?("nonempty regular non-symlink file"),
      "symlinked sibling Ruby program was accepted")

# And the opposite hole: a program no contract names in full. The `-r` preload at
# tests/contracts/support/beszel_telemetry is loaded without its extension, so a
# reference scan alone would never reach it and it would keep the zero static
# coverage the heredocs had.
output, status = run_registry(
  registry: registry,
  contracts: {
    "ntfy.sh" => "#!/bin/sh\ntrue\n",
    "support/helper.rb" => { content: "def dangling(\n", mode: 0o644 }
  }
)
check(failures, !status.success? &&
                output.include?("tests/contracts/support/helper.rb: sibling Ruby program has invalid syntax"),
      "unreferenced sibling Ruby library was not parsed")

# The shape neither sweep sees: no heredoc and no sibling, which is what the
# four *-foundation.sh contracts are. Both new loops run over nothing, and a
# contract that was already legal has to stay legal.
output, status = run_registry(
  registry: registry,
  contracts: { "ntfy.sh" => "#!/bin/sh\n# see tests/contracts/ntfy_retired.rb\nexec true\n" }
)
check(failures, status.success?,
      "contract with neither a heredoc nor a sibling Ruby program was rejected: " \
      "#{output.lines.first&.strip}")

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

report(failures, "contracts: all registry checks hold", "contract registry regression(s)")
