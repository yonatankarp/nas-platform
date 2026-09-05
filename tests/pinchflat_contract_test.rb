#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Pinchflat service contract's two Ruby programs.
#
# Until #147 both lived in `<<'RUBY'` heredocs inside tests/contracts/pinchflat.sh.
# `sh -n` reads a quoted heredoc as opaque text, so the only thing that ever
# executed either one was an integration lane with Docker, a converged Pinchflat
# and a real vault. tests/contracts/pinchflat-static.rb and
# tests/contracts/pinchflat-runtime.rb are files now, so both are reachable here.
#
# Three layers, because the contract has three kinds of property:
#
#   Static -- build a fixture repository from the files the contract reads,
#   break exactly one thing in it, and require the program to name that thing.
#   The assertion text is the interface: a guard that fails for the wrong reason
#   has stopped guarding what it names, so every row pins the exact diagnostic.
#
#   Runtime -- serve the interface from an HTTP fixture and put `docker` and
#   `ansible-vault` stubs on PATH, so the health, identity and persistence
#   outcomes can each be moved one at a time. This half had no test at all.
#
#   Wrapper -- tests/contracts/pinchflat.sh is what turns a mode into an
#   invocation. Its rows prove the mode guard, that both programs are actually
#   reached, and that neither can consume the caller's stdin.
#
# Run with --self-test to plant a regression in each program and prove the rows
# above detect it.

require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

require_relative "http_fixture_support"
require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)
# The prefix every refusal this file judges has to carry. Matching the
# fragment alone accepted a backtrace or an echoed argument as a refusal.
DIAGNOSTIC_PREFIX = "Pinchflat contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "pinchflat.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "pinchflat-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "pinchflat-runtime.rb")

# Exactly what the static half reads, plus the shared flatten_tasks it requires
# through PLATFORM_CONTRACT_REPO_DIR. A fixture holding only these is the proof
# that the list the contract declares is the list it actually needs.
FIXTURE_FILES = %w[
  roles/pinchflat/defaults/main.yml
  roles/pinchflat/meta/argument_specs.yml
  roles/pinchflat/tasks/main.yml
  roles/pinchflat/templates/env.j2
  services/pinchflat/compose.yml
  services/pinchflat/compose.mac.yml
  services/pinchflat/compose.integration.yml
  tests/policy_support.rb
].freeze

USERNAME = "nasadmin"
PASSWORD = "contract-fixture-password"

def build_fixture_repository(root)
  FIXTURE_FILES.each do |relative|
    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(ROOT, relative), destination)
  end
end

def edit_yaml(root, relative)
  path = File.join(root, relative)
  document = YAML.safe_load_file(path, aliases: true)
  yield document
  File.write(path, YAML.dump(document))
end

def edit_text(root, relative)
  path = File.join(root, relative)
  File.write(path, yield(File.read(path)))
end

# Reaches a task wherever it sits, a block's rescue and always paths included,
# because that is the shape the contract's own flatten_tasks reads.
def each_task(document, &block)
  Array(document).each do |task|
    next unless task.is_a?(Hash)

    block.call(task)
    %w[block rescue always].each { |key| each_task(task[key], &block) if task.key?(key) }
  end
end

def mutate_tasks(root, &block)
  path = File.join(root, "roles/pinchflat/tasks/main.yml")
  document = YAML.safe_load_file(path, aliases: true)
  each_task(document, &block)
  File.write(path, YAML.dump(document))
end

STATIC_ROWS = [
  {
    name: "an intact repository",
    break: ->(_root) {},
    expects: nil
  },
  {
    name: "a declared file that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "services/pinchflat/compose.mac.yml")) },
    expects: "missing services/pinchflat/compose.mac.yml"
  },
  {
    name: "a seat on the shared control network",
    break: lambda { |root|
      edit_yaml(root, "services/pinchflat/compose.yml") do |document|
        document["services"]["pinchflat"]["networks"] = ["media_control"]
      end
    },
    expects: "Pinchflat must not join the shared media control network"
  },
  {
    name: "a container that is not the platform identity",
    break: lambda { |root|
      edit_yaml(root, "services/pinchflat/compose.yml") do |document|
        document["services"]["pinchflat"]["user"] = "1000:1000"
      end
    },
    expects: "Pinchflat must run as the shared platform identity"
  },
  {
    name: "a dropped umask",
    break: lambda { |root|
      edit_yaml(root, "services/pinchflat/compose.yml") do |document|
        document["services"]["pinchflat"]["environment"].delete("UMASK")
      end
    },
    expects: "Pinchflat must declare the platform umask"
  },
  {
    name: "a credential that deployment no longer requires",
    break: lambda { |root|
      edit_yaml(root, "services/pinchflat/compose.yml") do |document|
        document["services"]["pinchflat"]["environment"]["BASIC_AUTH_PASSWORD"] =
          "${PINCHFLAT_BASIC_AUTH_PASSWORD}"
      end
    },
    expects: "Pinchflat must require BASIC_AUTH_PASSWORD from the rendered environment"
  },
  {
    name: "a mount beyond the three it is allowed",
    break: lambda { |root|
      edit_yaml(root, "services/pinchflat/compose.yml") do |document|
        document["services"]["pinchflat"]["volumes"] << "${NAS_MEDIA_ROOT:?}:/media"
      end
    },
    expects: "Pinchflat must mount exactly its config, library and extractor"
  },
  {
    name: "a drifted container port",
    break: lambda { |root|
      edit_yaml(root, "services/pinchflat/compose.yml") do |document|
        document["services"]["pinchflat"]["ports"] = ["8945:8080"]
      end
    },
    expects: "Pinchflat must publish the catalog web UI port"
  },
  {
    name: "a Mac override republishing the wrong container port",
    break: lambda { |root|
      edit_yaml(root, "services/pinchflat/compose.mac.yml") do |document|
        document["services"]["pinchflat"]["ports"] = ["${PINCHFLAT_HOST_PORT:?}:8080"]
      end
    },
    expects: "the Mac override must republish the web UI on the harness port"
  },
  {
    name: "a moved YouTube library root",
    break: lambda { |root|
      edit_yaml(root, "roles/pinchflat/defaults/main.yml") do |document|
        document["pinchflat_downloads_host_path"] = "{{ nas_media_root }}/Media/Video"
      end
    },
    expects: "Pinchflat must write the declared YouTube library root"
  },
  {
    name: "a moved config root",
    break: lambda { |root|
      edit_yaml(root, "roles/pinchflat/defaults/main.yml") do |document|
        document["pinchflat_config_host_path"] = "{{ nas_docker_root }}/pinchflat"
      end
    },
    expects: "Pinchflat must keep its state in the declared config root"
  },
  {
    name: "the CPU set rendered twice",
    break: lambda { |root|
      edit_text(root, "roles/pinchflat/templates/env.j2") do |source|
        "#{source}PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}\n"
      end
    },
    expects: "Pinchflat env must render the CPU set exactly once"
  },
  # The row the line-oriented environment read exists for: a commented-out sample
  # of the right assignment satisfies a substring search while the live line
  # beside it exports something else entirely.
  {
    name: "the vault identity surviving only in a comment",
    break: lambda { |root|
      edit_text(root, "roles/pinchflat/templates/env.j2") do |source|
        source.sub(
          "PINCHFLAT_BASIC_AUTH_USERNAME={{ vault_pinchflat_admin_username }}",
          "# PINCHFLAT_BASIC_AUTH_USERNAME={{ vault_pinchflat_admin_username }}\n" \
          "PINCHFLAT_BASIC_AUTH_USERNAME=admin"
        )
      end
    },
    expects: "Pinchflat env must carry only the vault-authored identity"
  },
  {
    name: "a role that tears the stack down instead of deploying it",
    break: lambda { |root|
      mutate_tasks(root) do |task|
        task["community.docker.docker_compose_v2"]["state"] = "absent" if
          task.key?("community.docker.docker_compose_v2")
      end
    },
    expects: "Pinchflat must deploy through docker_compose_v2"
  },
  {
    name: "a CPU policy check pointed at another service",
    break: lambda { |root|
      mutate_tasks(root) do |task|
        task["vars"]["container_cpu_service_name"] = "other" if
          task.dig("vars", "container_cpu_service_name") == "pinchflat"
      end
    },
    expects: "Pinchflat must verify its effective project CPU policy"
  },
  {
    name: "a task naming the credential without no_log",
    break: lambda { |root|
      mutate_tasks(root) do |task|
        task.delete("no_log") if task.to_s.match?(/vault_pinchflat_admin_password/)
      end
    },
    expects: "every Pinchflat task naming the credential must use no_log"
  },
  {
    name: "a world-readable environment file",
    break: lambda { |root|
      mutate_tasks(root) do |task|
        task["ansible.builtin.template"]["mode"] = "0644" if
          task.dig("ansible.builtin.template", "src") == "env.j2"
      end
    },
    expects: "the Pinchflat environment render must be redacted and private"
  },
  {
    name: "a health probe on the wrong endpoint",
    break: lambda { |root|
      mutate_tasks(root) do |task|
        uri = task["ansible.builtin.uri"]
        uri["url"] = "{{ pinchflat_api }}/health" if
          uri.is_a?(Hash) && uri["url"] == "{{ pinchflat_api }}/healthcheck"
      end
    },
    expects: "Pinchflat verification must read its unauthenticated health endpoint"
  },
  {
    name: "an administrator probe that stopped sending its credential",
    break: lambda { |root|
      mutate_tasks(root) do |task|
        uri = task["ansible.builtin.uri"]
        uri.delete("force_basic_auth") if
          uri.is_a?(Hash) && uri["url_password"] == "{{ vault_pinchflat_admin_password }}"
      end
    },
    expects: "Pinchflat verification must authenticate as the vault administrator"
  },
  {
    name: "an anonymous probe that quietly authenticates",
    break: lambda { |root|
      mutate_tasks(root) do |task|
        uri = task["ansible.builtin.uri"]
        uri["url_password"] = "{{ vault_pinchflat_admin_password }}" if
          uri.is_a?(Hash) && uri["url"] == "{{ pinchflat_api }}/" && !uri.key?("url_password")
      end
    },
    expects: "Pinchflat verification must probe the interface anonymously"
  },
  {
    name: "an interface probe that fails inside the redacted request",
    break: lambda { |root|
      mutate_tasks(root) do |task|
        uri = task["ansible.builtin.uri"]
        next unless uri.is_a?(Hash) && uri["url"] == "{{ pinchflat_api }}/"

        uri["status_code"] = 200
        task["failed_when"] = false
      end
    },
    expects: "must accept any status and defer to the assertion"
  },
  {
    name: "an outcome assertion that stopped pinning the refusal",
    break: lambda { |root|
      mutate_tasks(root) do |task|
        assertion = task["ansible.builtin.assert"]
        next unless assertion.is_a?(Hash)

        assertion["that"] = Array(assertion["that"]).reject do |value|
          value.include?("pinchflat_verify_anonymous.status")
        end
      end
    },
    expects: "Pinchflat verification must assert its exact health and access outcomes"
  },
  {
    name: "a redacted diagnosis",
    break: lambda { |root|
      mutate_tasks(root) { |task| task["no_log"] = true if task.key?("ansible.builtin.assert") }
    },
    expects: "the Pinchflat outcome assertion must stay readable"
  },
  {
    name: "a verification read that claims a change",
    break: lambda { |root|
      mutate_tasks(root) do |task|
        task.delete("changed_when") if
          Array(task["tags"]).include?("platform_verify_pinchflat") &&
          task.key?("ansible.builtin.uri")
      end
    },
    expects: "Pinchflat verification reads must not claim a change"
  }
].freeze

# The three moving parts of the runtime half that are not the HTTP interface:
# what Docker reports about the container, what ansible-vault decrypts, and
# whether the database landed beneath the declared config root.
RUNTIME_DEFAULTS = {
  docker_status: "healthy",
  docker_exit: 0,
  vault_exit: 0,
  database: true,
  health_body: '{"status":"ok"}',
  anonymous_status: 401,
  wrong_password_status: 401,
  authenticated_status: 200
}.freeze

RUNTIME_ROWS = [
  {
    name: "a healthy, exclusively authenticated, persisted Pinchflat",
    given: {},
    expects: nil
  },
  {
    name: "a health endpoint answering something other than JSON",
    given: { health_body: "<html>starting</html>" },
    expects: "Pinchflat health endpoint did not answer JSON"
  },
  {
    name: "a health endpoint reporting an unhealthy status",
    given: { health_body: '{"status":"degraded"}' },
    expects: "Pinchflat did not report a healthy status"
  },
  {
    name: "a container Docker cannot inspect",
    given: { docker_exit: 1 },
    expects: "the Pinchflat container could not be inspected"
  },
  {
    name: "a container Docker calls unhealthy",
    given: { docker_status: "starting" },
    expects: "the Pinchflat container is not healthy"
  },
  {
    name: "a vault that will not open",
    given: { vault_exit: 2 },
    expects: "encrypted vault could not be read"
  },
  {
    name: "an interface served to an anonymous request",
    given: { anonymous_status: 200 },
    expects: "Pinchflat served its interface to an anonymous request"
  },
  {
    name: "an interface served to a wrong password",
    given: { wrong_password_status: 200 },
    expects: "Pinchflat served its interface to a wrong password"
  },
  {
    name: "an interface refusing the vault administrator",
    given: { authenticated_status: 401 },
    expects: "Pinchflat refused the vault-authored administrator"
  },
  {
    name: "state that did not land in the declared config root",
    given: { database: false },
    expects: "Pinchflat did not persist its database in the declared config root"
  }
].freeze

def write_stub(path, body)
  File.write(path, body)
  File.chmod(0o755, path)
end

def build_runtime_sandbox(root, options)
  bin = File.join(root, "bin")
  FileUtils.mkdir_p(bin)
  write_stub(File.join(bin, "docker"), <<~SH)
    #!/bin/sh
    printf '%s\\n' '#{options.fetch(:docker_status)}'
    exit #{options.fetch(:docker_exit)}
  SH
  File.write(File.join(root, "vault-plain.yml"), YAML.dump(
                                                   "vault_pinchflat_admin_username" => USERNAME,
                                                   "vault_pinchflat_admin_password" => PASSWORD
                                                 ))
  write_stub(File.join(bin, "ansible-vault"), <<~SH)
    #!/bin/sh
    cat '#{File.join(root, 'vault-plain.yml')}'
    exit #{options.fetch(:vault_exit)}
  SH
  File.write(File.join(root, "vault.yml"), "$ANSIBLE_VAULT;1.1;AES256\n0000\n")
  File.write(File.join(root, "vault-password"), "fixture\n")
  if options.fetch(:database)
    database = File.join(root, "docker", "pinchflat", "config", "db", "pinchflat.db")
    FileUtils.mkdir_p(File.dirname(database))
    File.write(database, "SQLite format 3\0")
  end
  bin
end

# Answers the three interface outcomes the runtime half asserts, keyed by the
# credential each request carries, so a row moves exactly one of them.
def runtime_responder(options)
  expected = "Basic #{["#{USERNAME}:#{PASSWORD}"].pack('m0')}"
  lambda do |_method, target, headers, _body|
    next [200, options.fetch(:health_body)] if target == "/healthcheck"

    authorization = headers["authorization"].to_s
    status = if authorization.empty?
               options.fetch(:anonymous_status)
             elsif authorization == expected
               options.fetch(:authenticated_status)
             else
               options.fetch(:wrong_password_status)
             end
    [status, "<html></html>", "text/html"]
  end
end

def static_failures(program, rows = STATIC_ROWS)
  rows.each_with_object([]) do |row, failures|
    Dir.mktmpdir("nas-platform-pinchflat-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root }, RbConfig.ruby, program, root
      )
      failures.concat(judge("static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                            prefix: DIAGNOSTIC_PREFIX))
    end
  end
end

def runtime_failures(program, rows = RUNTIME_ROWS)
  rows.each_with_object([]) do |row, failures|
    options = RUNTIME_DEFAULTS.merge(row.fetch(:given))
    Dir.mktmpdir("nas-platform-pinchflat-runtime.") do |raw|
      root = File.realpath(raw)
      bin = build_runtime_sandbox(root, options)
      HttpFixtureSupport.with_http_fixture(
        lambda do |port|
          stdout, stderr, status = Open3.capture3(
            {
              "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
              "PLATFORM_PINCHFLAT_PORT" => port.to_s,
              "PLATFORM_PINCHFLAT_CONTAINER" => "fixture-pinchflat",
              "PLATFORM_DOCKER_ROOT" => File.join(root, "docker"),
              "PLATFORM_CONTRACT_VAULT_FILE" => File.join(root, "vault.yml"),
              "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "vault-password")
            },
            RbConfig.ruby, program
          )
          failures.concat(judge("runtime: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                                prefix: DIAGNOSTIC_PREFIX))
        end,
        &runtime_responder(options)
      )
    end
  end
end

# --- wrapper layer ---------------------------------------------------------
#
# tests/contracts/pinchflat.sh resolves its two programs from its own checkout
# rather than from the tree it is inspecting, so a copy of the three files into
# a throwaway tests/contracts/ is a whole working contract. That is what lets a
# row point PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise
# the real wrapper. The copy is laid into a fixture repository so it is also a
# valid tree to inspect, which is what the unset-variable row needs.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-pinchflat-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    {
      "pinchflat.sh" => wrapper,
      "pinchflat-static.rb" => static,
      "pinchflat-runtime.rb" => runtime
    }.each do |name, content|
      destination = File.join(contracts, name)
      File.write(destination, content)
      File.chmod(0o755, destination)
    end
    yield File.join(contracts, "pinchflat.sh"), root
  end
end

# Reports what the program saw on stdin and what the caller still has, which is
# the only way the redirect is observable: neither real program reads stdin, so
# the redirect is what keeps that true rather than something that changes an
# outcome today.
STDIN_PROBE = <<~'PROBE'
  warn "probe read #{$stdin.read.inspect}"
  exit 1
PROBE

def stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(static: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT },
      "/bin/sh", "-c", "#{contract.shellescape} static; printf 'left:'; cat",
      stdin_data: "caller-payload\n"
    )
    output = stdout + stderr
    failures << "stdin: the probing shell itself failed: #{output.strip}" unless status.success?
    failures << "stdin: the static program was handed the caller's input: #{output.strip.inspect}" unless
      output.include?('probe read ""')
    failures << "stdin: the caller's input did not survive the contract: #{output.strip.inspect}" unless
      output.include?("left:caller-payload")
  end
  failures
end

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "seed-fixture-only"
    )
    failures << "wrapper: an unknown mode was accepted" if status.success?
    failures << "wrapper: an unknown mode was refused with exit #{status.exitstatus}, wanted 2" unless
      status.exitstatus == 2
    failures << "wrapper: an unknown mode was refused without its diagnostic" unless
      (stdout + stderr).include?("pinchflat contract accepts only static or run")

    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "static"
    )
    failures << "wrapper: static mode failed against this repository: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?("pinchflat static contract: authenticated YouTube writer ownership holds")

    # The row that proves the wrapper still runs the static program at all: the
    # tree under inspection is broken, the wrapper's own checkout is not.
    Dir.mktmpdir("nas-platform-pinchflat-broken.") do |raw|
      broken = File.realpath(raw)
      build_fixture_repository(broken)
      FileUtils.rm(File.join(broken, "services/pinchflat/compose.mac.yml"))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => broken }, contract, "static"
      )
      failures << "wrapper: static mode passed against a broken repository" if status.success?
      failures << "wrapper: static mode did not report the broken repository" unless
        (stdout + stderr).include?("missing services/pinchflat/compose.mac.yml")
    end
  end

  # The branch every deployment actually takes. Neither tests/integration.sh nor
  # run_contracts.rb --execute sets PLATFORM_CONTRACT_REPO_DIR, and
  # tests/mac/run.sh:42 refuses to start when it is set, so the default is the
  # only path in production -- and it is the one where resolving the programs
  # from the script's own checkout is load-bearing rather than shadowed.
  with_contract_copy do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: static mode failed with no repository named: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?("pinchflat static contract: authenticated YouTube writer ownership holds")

    # ... and it read that checkout rather than some other tree: break the copy
    # and the same unset invocation must now refuse.
    FileUtils.rm(File.join(copy_root, "services/pinchflat/compose.mac.yml"))
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("missing services/pinchflat/compose.mac.yml")
  end
  failures
end

# --- planted regressions ---------------------------------------------------

PROGRAM_MUTATIONS = [
  {
    label: "a declared file no longer having to exist",
    program: :static,
    from: 'failures << "missing #{relative}" unless File.file?(File.join(root, relative))',
    to: "failures << relative if false",
    rows: ["a declared file that is gone"],
    # The existence sweep is also what keeps the reads below it from meeting an
    # absent file, so removing it does not merely accept the repository: it
    # crashes on the first YAML load. The row still refuses, and now says why in
    # a stack trace instead of a sentence, which is the regression.
    detects: "refused for the wrong reason"
  },
  {
    label: "the shared network check",
    program: :static,
    from: 'compose.key?("networks") || service.key?("networks")',
    to: "false",
    rows: ["a seat on the shared control network"]
  },
  {
    label: "the platform identity check",
    program: :static,
    from: 'service["user"] == "${NAS_UID:?}:${NAS_GID:?}"',
    to: "true",
    rows: ["a container that is not the platform identity"]
  },
  {
    label: "the required-credential check",
    program: :static,
    from: 'service.dig("environment", name) == expected',
    to: "true",
    rows: ["a credential that deployment no longer requires"]
  },
  {
    # Restores the substring search the line-oriented read replaced, which is the
    # form a commented-out sample satisfies while the live line exports something
    # else.
    label: "the line-oriented environment read",
    program: :static,
    from: "].all? { |assignment| env_assignments.include?(assignment) }",
    to: '].all? { |name, value| File.read(File.join(root, "roles/pinchflat/templates/env.j2"))' \
        '.include?("#{name}=#{value}") }',
    rows: ["the vault identity surviving only in a comment"]
  },
  {
    label: "the credential redaction check",
    program: :static,
    from: 'credential_tasks.length >= 2 && credential_tasks.all? { |task| task["no_log"] == true }',
    to: "true",
    rows: ["a task naming the credential without no_log"]
  },
  {
    label: "the refusal half of the outcome assertion",
    program: :static,
    from: 'value.include?("pinchflat_verify_anonymous.status") && value.include?("401")',
    to: "true",
    rows: ["an outcome assertion that stopped pinning the refusal"]
  },
  {
    label: "the idempotence check on verification reads",
    program: :static,
    from: '(task["changed_when"] == false && task["check_mode"] == false)',
    to: "true",
    rows: ["a verification read that claims a change"]
  },
  {
    label: "the healthy-status check",
    program: :runtime,
    from: 'unless document == { "status" => "ok" }',
    to: "unless true",
    rows: ["a health endpoint reporting an unhealthy status"]
  },
  {
    label: "the container health check",
    program: :runtime,
    from: 'unless state.strip == "healthy"',
    to: "unless true",
    rows: ["a container Docker calls unhealthy"]
  },
  {
    label: "the anonymous refusal check",
    program: :runtime,
    from: 'request("/").code == "401"',
    to: "true",
    rows: ["an interface served to an anonymous request"]
  },
  {
    label: "the wrong-password refusal check",
    program: :runtime,
    from: 'request("/", credentials: [credentials.first, "contract-wrong-password"]).code == "401"',
    to: "true",
    rows: ["an interface served to a wrong password"]
  },
  {
    label: "the persisted-state check",
    program: :runtime,
    from: "File.file?(DATABASE) && File.size?(DATABASE)",
    to: "true",
    rows: ["state that did not land in the declared config root"]
  }
].freeze

def plant(source, mutation)
  from = mutation.fetch(:from)
  occurrences = mutation.fetch(:occurrences, 1)
  found = source.scan(from).length
  abort "self-test could not plant #{mutation.fetch(:label)}: expected #{occurrences} " \
       "match(es) of #{from.inspect}, found #{found}" unless found == occurrences

  planted = occurrences == 1 ? source.sub(from, mutation.fetch(:to)) : source.gsub(from, mutation.fetch(:to))
  abort "self-test planted nothing for #{mutation.fetch(:label)}" if planted == source
  planted
end

def with_mutant(mutation)
  canonical = mutation.fetch(:program) == :static ? STATIC_PROGRAM : RUNTIME_PROGRAM
  Dir.mktmpdir("nas-platform-pinchflat-mutant.") do |directory|
    path = File.join(directory, File.basename(canonical))
    File.write(path, plant(File.read(canonical), mutation))
    File.chmod(0o755, path)
    yield path
  end
end

def rows_named(rows, names)
  selected = rows.select { |row| names.include?(row.fetch(:name)) }
  abort "self-test names a row that does not exist: #{names.inspect}" unless
    selected.length == names.length

  selected
end

if ARGV.include?("--self-test")
  PROGRAM_MUTATIONS.each do |mutation|
    with_mutant(mutation) do |mutant|
      caught = if mutation.fetch(:program) == :static
                 static_failures(mutant, rows_named(STATIC_ROWS, mutation.fetch(:rows)))
               else
                 runtime_failures(mutant, rows_named(RUNTIME_ROWS, mutation.fetch(:rows)))
               end
      abort "self-test failed: removing #{mutation.fetch(:label)} was accepted" if caught.empty?
      detects = mutation.fetch(:detects, "accepted what it must refuse")
      next if caught.all? { |failure| failure.include?(detects) }

      abort "self-test failed: removing #{mutation.fetch(:label)} was caught by the wrong " \
            "assertion: #{caught.join(' | ')}"
    end
  end

  # The redirect's own regression. Neither real program reads stdin, so dropping
  # `</dev/null` changes no outcome today -- which is exactly why it needs a
  # program that does read, and why the rule cannot be proven by the contract
  # passing.
  unredirected = File.read(CONTRACT).sub(
    'ruby "$contract_repo_dir/tests/contracts/pinchflat-static.rb" "$repo_dir" </dev/null',
    'ruby "$contract_repo_dir/tests/contracts/pinchflat-static.rb" "$repo_dir"'
  )
  abort "self-test could not plant a dropped stdin redirect" if unredirected == File.read(CONTRACT)
  leaked = stdin_failures(wrapper_source: unredirected)
  abort "self-test failed: a dropped stdin redirect was accepted" if leaked.empty?

  puts "pinchflat contract: self-test detects #{PROGRAM_MUTATIONS.length + 1} planted regressions"
  exit
end

failures = static_failures(STATIC_PROGRAM) + runtime_failures(RUNTIME_PROGRAM) +
           wrapper_failures + stdin_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Pinchflat contract violation(s)"
end

puts "pinchflat contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime " \
     "properties hold, and the wrapper reaches both programs with an empty stdin"
