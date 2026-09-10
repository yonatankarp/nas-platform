#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the AdGuard Home service contract's two Ruby programs.
#
# Three layers, because the contract has three kinds of property:
#
#   Static -- build a fixture repository from the files the contract reads,
#   break exactly one thing in it, and require the program to name that thing.
#   The assertion text is the interface: a guard that fails for the wrong reason
#   has stopped guarding what it names, so every row pins the exact diagnostic.
#
#   Runtime -- serve the control API from an HTTP fixture AND the resolver from
#   a DNS fixture, with `docker` and `ansible-vault` stubs on PATH, so every
#   outcome the contract distinguishes can be moved one at a time. The DNS half
#   is what makes the behavioural claim testable at all: the contract's whole
#   reason for existing is that it resolves a blocked name and an unblocked one,
#   and a row that could not move those answers would leave that untested.
#
#   Wrapper -- tests/contracts/adguard.sh is what turns a mode into an
#   invocation. Its rows prove the mode guard, that both programs are reached,
#   and that neither can consume the caller's stdin.
#
# EVERY WAITING ROW SETS ITS OWN BUDGET, and that is the whole reason the
# contract takes its deadlines from the environment. Two rows here -- a login
# page that never answers and a filter list that never loads -- can only reach
# the refusal they name by sitting out a deadline. At the deployment's own
# numbers that is 120 seconds each, twice, which is how
# tests/seerr_contract_test.rb and tests/beszel_contract_test.rb each became the
# `static` gate's floor (#319, #485). Both were retrofits; this is not.
#
# Run with --self-test to plant a regression in each program and prove the rows
# above detect it.

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "yaml"

require_relative "case_pool_support"
require_relative "http_fixture_support"
require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)
# The prefix every refusal this file judges has to carry. Matching the fragment
# alone would accept a backtrace or an echoed argument as a refusal.
DIAGNOSTIC_PREFIX = "AdGuard contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "adguard.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "adguard-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "adguard-runtime.rb")

# Exactly what the static half reads, plus the shared flatten_tasks it requires
# through PLATFORM_CONTRACT_REPO_DIR. A fixture holding only these is the proof
# that the list the contract declares is the list it actually needs.
FIXTURE_FILES = %w[
  roles/adguard/defaults/main.yml
  roles/adguard/meta/argument_specs.yml
  roles/adguard/tasks/main.yml
  roles/adguard/tasks/deploy.yml
  roles/adguard/tasks/report.yml
  roles/adguard/tasks/verify.yml
  roles/adguard/templates/env.j2
  roles/adguard/templates/AdGuardHome.yaml.j2
  services/adguard/compose.yml
  services/adguard/compose.mac.yml
  services/adguard/compose.integration.yml
  tests/expected/adguard.yml
  tests/contracts/adguard.sh
  tests/integration_controller_lib.sh
  inventory/group_vars/all/main.yml
  tests/policy_support.rb
].freeze

USERNAME = "nasadmin"
PASSWORD = "contract-fixture-password"
BLOCKED_NAME = "doubleclick.net"
ALLOWED_NAME = "example.com"
ALLOWED_ADDRESS = "93.184.216.34"

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
# because that is the shape the contract's own reader walks.
def each_task(document, &block)
  Array(document).each do |task|
    next unless task.is_a?(Hash)

    block.call(task)
    %w[block rescue always].each { |key| each_task(task[key], &block) if task.key?(key) }
  end
end

def mutate_tasks(root, file, &block)
  path = File.join(root, "roles/adguard/tasks/#{file}.yml")
  document = YAML.safe_load_file(path, aliases: true)
  each_task(document, &block)
  File.write(path, YAML.dump(document))
end

# --- static layer -----------------------------------------------------------

STATIC_ROWS = [
  {
    name: "an intact repository",
    break: ->(_root) {},
    expects: nil
  },
  {
    name: "a declared file that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "services/adguard/compose.mac.yml")) },
    expects: "missing services/adguard/compose.mac.yml"
  },
  {
    name: "a container running as root",
    break: lambda { |root|
      edit_yaml(root, "services/adguard/compose.yml") do |document|
        document["services"]["adguard"].delete("user")
      end
    },
    expects: "AdGuard must run as the shared platform identity"
  },
  {
    name: "a DNS listener that would need root inside the container",
    break: lambda { |root|
      edit_yaml(root, "services/adguard/compose.yml") do |document|
        document["services"]["adguard"]["ports"] = ["8083:3000", "53:53/tcp", "53:53/udp"]
      end
    },
    expects: "AdGuard must publish host 53/tcp to the unprivileged in-container listener"
  },
  {
    name: "a sandbox override that appends publications instead of replacing them",
    break: lambda { |root|
      edit_text(root, "services/adguard/compose.integration.yml") do |source|
        source.sub("ports: !override", "ports:")
      end
    },
    expects: "must REPLACE the production publications"
  },
  {
    name: "an override that stopped reading the rendered host port",
    break: lambda { |root|
      edit_text(root, "services/adguard/compose.integration.yml") do |source|
        source.gsub("${ADGUARD_DNS_HOST_PORT:?}", "${ADGUARD_RESOLVER_PORT:?}")
      end
    },
    expects: "must publish ${ADGUARD_DNS_HOST_PORT:?} rather than a "
  },
  {
    name: "an override publishing a literal host port beside the rendered ones",
    break: lambda { |root|
      edit_text(root, "services/adguard/compose.integration.yml") do |source|
        "#{source}      - \"18084:3000\"\n"
      end
    },
    expects: "publishes literal host port(s)"
  },
  {
    # An administrator that is not the vault's, rather than `users: []`, and the
    # difference is only about what this row can prove: an empty list drops the
    # password line too, so two assertions fire and the row could no longer say
    # which one was doing the work. The assertion it exercises is the same one
    # that refuses `users: []`, which is the defect the message describes.
    name: "an administrator the vault did not author",
    break: lambda { |root|
      edit_text(root, "roles/adguard/templates/AdGuardHome.yaml.j2") do |source|
        source.sub("  - name: {{ vault_adguard_admin_username }}\n", "  - name: admin\n")
      end
    },
    expects: "must declare a nonempty users list"
  },
  {
    name: "protection switched off in the rendered configuration",
    break: lambda { |root|
      edit_text(root, "roles/adguard/templates/AdGuardHome.yaml.j2") do |source|
        source.sub("protection_enabled: true", "protection_enabled: false")
      end
    },
    expects: "must declare protection and filtering on"
  },
  {
    name: "AdGuard's own DHCP server switched on",
    break: lambda { |root|
      edit_text(root, "roles/adguard/templates/AdGuardHome.yaml.j2") do |source|
        source.sub(/^dhcp:\n  enabled: false\n/, "dhcp:\n  enabled: true\n")
      end
    },
    expects: "must leave AdGuard's DHCP server off"
  },
  {
    # The regression the whole "expanded form" argument exists against: a
    # template trimmed back to the settings a human cares about is rewritten by
    # the daemon on first start and reports a change on every converge after it.
    name: "a configuration template trimmed towards the minimal document",
    #
    # Drops only the lines no other assertion reads -- plain two-space scalars
    # carrying no Jinja and no asserted marker -- so what this row moves is the
    # document's size and nothing else. Truncating it instead took the upstream
    # loop and the DHCP block with it, and five other assertions fired first.
    break: lambda { |root|
      edit_text(root, "roles/adguard/templates/AdGuardHome.yaml.j2") do |source|
        keep = /\{\{|\{%|enabled: false|protection_enabled|filtering_enabled/
        source.lines.reject { |line| line.match?(/^  [a-z_0-9]+: \S/) && !line.match?(keep) }.join
      end
    },
    expects: "has been trimmed towards a minimal document"
  },
  {
    name: "a hash computed at converge time",
    break: lambda { |root|
      mutate_tasks(root, "deploy") do |task|
        template = task["ansible.builtin.template"]
        next unless template.is_a?(Hash) && template["src"] == "AdGuardHome.yaml.j2"

        task["vars"] = {
          "adguard_rendered_hash" => "{{ vault_adguard_admin_password | password_hash('bcrypt') }}"
        }
      end
    },
    expects: "must not hash the administrator password at converge time"
  },
  {
    name: "a role that repoints the host resolver",
    break: lambda { |root|
      path = File.join(root, "roles/adguard/tasks/deploy.yml")
      document = YAML.safe_load_file(path, aliases: true)
      document << {
        "name" => "Point the host at AdGuard",
        "ansible.builtin.lineinfile" => {
          "path" => "/etc/resolv.conf", "line" => "nameserver 127.0.0.1"
        }
      }
      File.write(path, YAML.dump(document))
    },
    expects: "it must never touch the host resolver"
  },
  {
    name: "a deployment that ignores the gate",
    # The gate comes off the block that WRAPS the plain deployment and off the
    # deployment itself, and off nothing else. Ansible applies a block's `when`
    # to every task inside it, so stripping only the inner task leaves the
    # deployment gated and the row passes for the wrong reason -- which is what
    # it did on its first run. Stripping every gate in the file would instead be
    # caught by the teardown assertion, so the self-test could not tell which
    # check was doing the work.
    break: lambda { |root|
      path = File.join(root, "roles/adguard/tasks/deploy.yml")
      document = YAML.safe_load_file(path, aliases: true)
      ungate = lambda do |task|
        task["when"] = Array(task["when"]).reject { |gate| gate.to_s.include?("deployment_enabled") }
        task.delete("when") if Array(task["when"]).empty?
      end
      document.each do |task|
        next unless task.is_a?(Hash)

        plain = Array(task["block"]).find do |inner|
          compose = inner.is_a?(Hash) ? inner["community.docker.docker_compose_v2"] : nil
          compose.is_a?(Hash) && compose["state"] == "present" && !compose.key?("recreate")
        end
        next unless plain

        ungate.call(task)
        ungate.call(plain)
      end
      File.write(path, YAML.dump(document))
    },
    expects: "must carry \"adguard_deployment_enabled | bool\""
  },
  {
    # The teardown stays and loses its gate, rather than being deleted. A deleted
    # task is refused by the count beside this assertion, which would let the
    # self-test's planted regression pass unnoticed.
    name: "a teardown that no longer answers to the gate",
    break: lambda { |root|
      mutate_tasks(root, "deploy") do |task|
        next unless task.dig("community.docker.docker_compose_v2", "state") == "absent"

        task["when"] = ["ansible_check_mode | bool"]
      end
    },
    expects: "must converge a disabled deployment to `state: absent`"
  },
  {
    name: "a plaintext upstream",
    break: lambda { |root|
      edit_yaml(root, "roles/adguard/defaults/main.yml") do |document|
        document["adguard_upstream_dns"] = ["9.9.9.9"]
      end
    },
    expects: "every declared upstream must be DNS-over-TLS"
  },
  {
    name: "a bootstrap resolver named rather than addressed",
    break: lambda { |root|
      edit_yaml(root, "roles/adguard/defaults/main.yml") do |document|
        document["adguard_bootstrap_dns"] = ["tls://dns.quad9.net"]
      end
    },
    expects: "bootstrap resolvers must be plain addresses"
  },
  {
    name: "a gate that ships on",
    break: lambda { |root|
      edit_yaml(root, "roles/adguard/defaults/main.yml") do |document|
        document["adguard_deployment_enabled"] = true
      end
    },
    expects: "must ship the deployment gate off"
  },
  {
    name: "a verification that reads the status page without asserting it",
    break: lambda { |root|
      mutate_tasks(root, "verify") do |task|
        assertion = task["ansible.builtin.assert"]
        next unless assertion.is_a?(Hash)

        assertion["that"] = Array(assertion["that"]).reject do |condition|
          condition.to_s.include?("protection_enabled")
        end
      end
    },
    expects: "must assert protection_enabled"
  },
  {
    name: "a verification that stopped proving filtering behaviourally",
    break: lambda { |root|
      mutate_tasks(root, "verify") do |task|
        assertion = task["ansible.builtin.assert"]
        next unless assertion.is_a?(Hash)

        assertion["that"] = Array(assertion["that"]).reject do |condition|
          condition.to_s.include?("FilteredBlackList")
        end
      end
    },
    expects: "must prove filtering behaviourally"
  },
  {
    name: "a vault credential the role stopped requiring",
    break: lambda { |root|
      edit_yaml(root, "roles/adguard/meta/argument_specs.yml") do |document|
        document["argument_specs"]["main"]["options"]["vault_adguard_admin_password_hash"]["required"] =
          false
      end
    },
    expects: "must require vault_adguard_admin_password_hash"
  },
  {
    name: "a privileged container",
    break: lambda { |root|
      edit_yaml(root, "services/adguard/compose.yml") do |document|
        document["services"]["adguard"]["privileged"] = true
      end
    },
    expects: "AdGuard must not be privileged"
  },
  {
    name: "a container that may acquire privilege after it starts",
    break: lambda { |root|
      edit_yaml(root, "services/adguard/compose.yml") do |document|
        document["services"]["adguard"].delete("security_opt")
      end
    },
    expects: "must refuse privilege escalation"
  },
  {
    name: "an image pinned by tag alone",
    break: lambda { |root|
      edit_yaml(root, "services/adguard/compose.yml") do |document|
        document["services"]["adguard"]["image"] =
          document["services"]["adguard"]["image"].split("@").first
      end
    },
    expects: "must carry both a version tag and a manifest digest"
  },
  {
    name: "a sandbox container left with its production name",
    break: lambda { |root|
      edit_text(root, "services/adguard/compose.mac.yml") do |source|
        source.sub("${PLATFORM_PROJECT_NAME:?}-adguard", "adguard")
      end
    },
    expects: "must give the container the sandbox's namespaced name"
  },
  {
    # THE ROW THE LANE FAILURE WAS ABOUT. The sandbox republished the web
    # interface somewhere else and roles/adguard was never told, so the readiness
    # wait polled 8083, took `Connection refused` twenty times and failed. The
    # converge has to be handed the same value the override publishes.
    name: "a converge that keeps the production port while the sandbox moves",
    break: lambda { |root|
      edit_text(root, "tests/integration_controller_lib.sh") do |source|
        source.gsub(/^\s*-e adguard_port="\$integration_adguard_port" \\\n/, "")
      end
    },
    expects: 'must converge with -e adguard_port="$integration_adguard_port"'
  },
  {
    # The other half of the same agreement: the contract has to look where the
    # deployment was told to listen, and a literal is how those two drift.
    name: "a lane handing the contract a literal port",
    break: lambda { |root|
      edit_text(root, "tests/integration_controller_lib.sh") do |source|
        source.sub('PLATFORM_ADGUARD_PORT="$integration_adguard_port"',
                   "PLATFORM_ADGUARD_PORT=18084")
      end
    },
    expects: 'must hand the contract PLATFORM_ADGUARD_PORT="$integration_adguard_port"'
  },
  {
    name: "a lane that went back to the privileged port the resolver stub forbids",
    break: lambda { |root|
      edit_text(root, "tests/integration_controller_lib.sh") do |source|
        source.sub("integration_adguard_dns_port=15353", "integration_adguard_dns_port=53")
      end
    },
    expects: "at or below 1024"
  },
  {
    # Claim 1 of this program's own header, which had no row until it was
    # reviewed. An undeclared variable rather than the clear password, so that
    # only the stored-hash assertion can fire and the row can say which
    # assertion did the work.
    name: "a rendered configuration that stopped carrying the stored hash",
    break: lambda { |root|
      edit_text(root, "roles/adguard/templates/AdGuardHome.yaml.j2") do |source|
        source.sub("password: {{ vault_adguard_admin_password_hash }}",
                   "password: {{ adguard_admin_digest }}")
      end
    },
    expects: "must render the STORED bcrypt hash"
  },
  {
    # Claim 2 of the header. The clear value is added BESIDE the hash rather
    # than in place of it, for the same reason: swapping them fires the
    # stored-hash assertion as well and the row could no longer name its own.
    # What the assertion forbids is the clear password reaching the rendered
    # file in any form, and this puts it there.
    name: "a rendered configuration carrying the clear administrator password",
    break: lambda { |root|
      edit_text(root, "roles/adguard/templates/AdGuardHome.yaml.j2") do |source|
        source.sub("password: {{ vault_adguard_admin_password_hash }}\n",
                   "password: {{ vault_adguard_admin_password_hash }}\n" \
                   "    plain_password: {{ vault_adguard_admin_password }}\n")
      end
    },
    expects: "must not carry the clear administrator password"
  },
  {
    name: "an environment that renders a literal instead of the role's port",
    break: lambda { |root|
      edit_text(root, "roles/adguard/templates/env.j2") do |source|
        source.sub(/^ADGUARD_DNS_HOST_PORT=.*\n/, "ADGUARD_DNS_HOST_PORT=53\n")
      end
    },
    expects: "must render ADGUARD_DNS_HOST_PORT from adguard_dns_port"
  },
  {
    name: "a verification task that lost its tag",
    break: lambda { |root|
      mutate_tasks(root, "verify") do |task|
        task.delete("tags") if task["ansible.builtin.assert"].is_a?(Hash)
      end
    },
    expects: "must carry the platform_verify_adguard tag"
  },
  {
    name: "a role that stopped reading the status endpoint",
    break: lambda { |root|
      mutate_tasks(root, "verify") do |task|
        uri = task["ansible.builtin.uri"]
        next unless uri.is_a?(Hash) && uri["url"].to_s.include?("/control/status")

        uri["url"] = uri["url"].sub("/control/status", "/control/dns_info")
      end
    },
    expects: "must read /control/status"
  },
  {
    name: "protection on and no list to enforce",
    break: lambda { |root|
      edit_yaml(root, "roles/adguard/defaults/main.yml") do |document|
        document["adguard_filters"] = []
      end
    },
    expects: "at least one filter list must be declared"
  },
  {
    name: "an expectation file pinning the wrong vault keys",
    break: lambda { |root|
      edit_yaml(root, "tests/expected/adguard.yml") do |document|
        document["vault_keys"] = document["vault_keys"].reject { |key| key.end_with?("_hash") }
      end
    },
    expects: "must pin exactly the vault keys roles/adguard requires"
  },
  {
    name: "a wrapper defaulting to a port the platform moved away from",
    break: lambda { |root|
      edit_text(root, "tests/contracts/adguard.sh") do |source|
        source.sub("PLATFORM_ADGUARD_PORT:=8083", "PLATFORM_ADGUARD_PORT:=8080")
      end
    },
    expects: "must default PLATFORM_ADGUARD_PORT to adguard_port"
  },
  {
    name: "a working directory declared wider than permcheck leaves it",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/main.yml") do |document|
        document["nas_storage"].each do |entry|
          entry["mode"] = "0755" if entry["path"].to_s.end_with?("/adguard/work")
        end
      end
    },
    expects: "must be declared mode 0700"
  },
  {
    name: "an inventory with no operator decision in it",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/main.yml") do |document|
        document.delete("adguard_deployment_enabled")
      end
    },
    expects: "must carry the operator's adguard_deployment_enabled decision"
  },
  {
    name: "a web interface published somewhere the role does not declare",
    break: lambda { |root|
      edit_yaml(root, "services/adguard/compose.yml") do |document|
        document["services"]["adguard"]["ports"] = document["services"]["adguard"]["ports"]
                                                   .map { |entry| entry.sub("8083:", "8084:") }
      end
    },
    expects: "must publish its web interface on the host port the role declares"
  },
  {
    name: "a fourth publication nobody declared",
    break: lambda { |root|
      edit_yaml(root, "services/adguard/compose.yml") do |document|
        document["services"]["adguard"]["ports"] << "8443:443"
      end
    },
    expects: "must publish DNS on exactly the web port and the two 53 entries"
  },
  {
    name: "a second container in the stack",
    break: lambda { |root|
      edit_yaml(root, "services/adguard/compose.yml") do |document|
        document["services"]["sidecar"] = document["services"]["adguard"]
      end
    },
    expects: "must declare exactly the adguard service"
  },
  {
    name: "a gate the role does not require",
    break: lambda { |root|
      edit_yaml(root, "roles/adguard/meta/argument_specs.yml") do |document|
        document["argument_specs"]["main"]["options"]["adguard_deployment_enabled"]["required"] =
          false
      end
    },
    expects: "must be a required bool in the role's argument spec"
  },
  {
    name: "upstreams written into the template rather than declared",
    break: lambda { |root|
      edit_text(root, "roles/adguard/templates/AdGuardHome.yaml.j2") do |source|
        source.sub(/\{% for adguard_upstream in adguard_upstream_dns %\}\n.*?\{% endfor %\}\n/m,
                   "    - tls://dns.quad9.net\n")
      end
    },
    expects: "must render the declared upstreams and bootstrap resolvers"
  },
  {
    name: "filter lists written into the template rather than declared",
    break: lambda { |root|
      edit_text(root, "roles/adguard/templates/AdGuardHome.yaml.j2") do |source|
        source.sub("{% for adguard_filter in adguard_filters %}", "{% if true %}")
      end
    },
    expects: "must render the declared filter lists"
  },
  {
    name: "a listening port written into the template rather than declared",
    break: lambda { |root|
      edit_text(root, "roles/adguard/templates/AdGuardHome.yaml.j2") do |source|
        source.sub("port: {{ adguard_dns_container_port }}", "port: 5353")
      end
    },
    expects: "must take its listening port from the role"
  },
  {
    name: "a storage declaration the platform lost",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/main.yml") do |document|
        document["nas_storage"].reject! { |entry| entry["path"].to_s.end_with?("/adguard/conf") }
      end
    },
    expects: "nas_storage must declare the AdGuard conf directory"
  },
  {
    name: "regenerable state classed as irreplaceable",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/main.yml") do |document|
        document["nas_storage"].each do |entry|
          entry["recovery"] = "critical" if entry["path"].to_s.end_with?("/adguard/work")
        end
      end
    },
    expects: "must be recovery: cache"
  },
  {
    name: "an expectation file naming another role",
    break: lambda { |root|
      edit_yaml(root, "tests/expected/adguard.yml") do |document|
        document["role"] = "adguard_home"
      end
    },
    expects: "must name the adguard role"
  },
  {
    # A lane that decides nothing leaves the role on the production defaults, so
    # the sandbox tries to publish the privileged 53 on a runner already
    # resolving through it.
    name: "a lane that declares neither port",
    break: lambda { |root|
      edit_text(root, "tests/integration_controller_lib.sh") do |source|
        source.gsub(/^integration_adguard_(dns_)?port=\d+\n/, "")
      end
    },
    expects: "must declare integration_adguard_port"
  },
  {
    name: "a url that hardcodes the production port",
    break: lambda { |root|
      edit_yaml(root, "roles/adguard/defaults/main.yml") do |document|
        document["adguard_url"] = "http://127.0.0.1:8083"
      end
    },
    expects: "adguard_url must derive from adguard_port"
  },
  {
    # The class rather than the instance: the readiness wait is what failed, but
    # tasks/verify.yml and everything after it addresses the service too, and a
    # literal in any of them is a reader no lane can redirect.
    name: "a task that addresses the service at a literal port",
    break: lambda { |root|
      path = File.join(root, "roles/adguard/tasks/verify.yml")
      document = YAML.safe_load_file(path, aliases: true)
      document << {
        "name" => "Verify AdGuard Home the quick way",
        "tags" => ["platform_verify_adguard"],
        "ansible.builtin.uri" => { "url" => "http://127.0.0.1:8083/control/status" }
      }
      File.write(path, YAML.dump(document))
    },
    expects: "addresses the service at a literal port"
  }
].freeze

def static_failures(program, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-adguard-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root }, RbConfig.ruby, program, root
      )
      collected.concat(judge("static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr,
                             status, prefix: DIAGNOSTIC_PREFIX))
    end
  end
  failures
end

# --- the DNS fixture --------------------------------------------------------
#
# A loopback TCP resolver that answers exactly what a row tells it to. It parses
# the question far enough to read the name and then writes an answer built here,
# which is what lets a row move a single verdict -- blocked to answering, or
# answering to blocked -- without touching anything else.
#
# TCP only, because that is the transport the contract uses and the reason it
# uses it is recorded there.
module DnsFixture
  module_function

  # Serves one loopback DNS fixture for the duration of +client+, which is
  # called with the port. +answers+ maps a query name to the list of dotted-quad
  # addresses to answer with; a name that is absent is answered with an empty
  # answer section, which is what a resolver that knows nothing looks like.
  def with_fixture(answers, client)
    server = TCPServer.new("127.0.0.1", 0)
    shutdown_reader, shutdown_writer = IO.pipe
    thread = Thread.new do
      Thread.current.report_on_exception = false
      loop do
        ready = IO.select([server, shutdown_reader], nil, nil, 0.05)
        next unless ready
        break if ready.first.include?(shutdown_reader)

        socket = server.accept
        begin
          serve(socket, answers)
        rescue StandardError
          nil
        ensure
          socket.close unless socket.closed?
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end
    begin
      client.call(server.addr[1])
    ensure
      shutdown_writer.write(".")
      thread.join(10)
      thread.kill if thread.alive?
      [server, shutdown_reader, shutdown_writer].each { |io| io.close unless io.closed? }
    end
  end

  def serve(socket, answers)
    length = socket.read(2)&.unpack1("n")
    return unless length

    message = socket.read(length)
    return unless message && message.bytesize >= 12

    name, question_end = read_name(message, 12)
    question = message[12...(question_end + 4)]
    addresses = answers.fetch(name, [])
    body = addresses.map do |address|
      [0xC00C, 1, 1, 60, 4].pack("nnnNn") + address.split(".").map(&:to_i).pack("C4")
    end.join
    header = [message[0, 2].unpack1("n"), 0x8180, 1, addresses.length, 0, 0].pack("n6")
    response = header + question + body
    socket.write([response.bytesize].pack("n") + response)
  end

  def read_name(message, offset)
    labels = []
    loop do
      length = message.getbyte(offset)
      break if length.nil? || length.zero?

      labels << message[offset + 1, length]
      offset += 1 + length
    end
    [labels.join("."), offset + 1]
  end
end

# --- runtime layer ----------------------------------------------------------

RUNTIME_DEFAULTS = {
  login_status: 200,
  anonymous_status: 401,
  wrong_password_status: 401,
  running: true,
  protection_enabled: true,
  filtering_enabled: true,
  rules_count: 177_896,
  blocked_addresses: ["0.0.0.0"],
  allowed_addresses: [ALLOWED_ADDRESS],
  container_health: "healthy",
  config_mode: 0o600,
  config_present: true,
  budgets: {}
}.freeze

def build_runtime_sandbox(root, options)
  bin = File.join(root, "bin")
  FileUtils.mkdir_p(bin)
  File.write(File.join(bin, "docker"), <<~SH)
    #!/bin/sh
    printf '%s\\n' '#{options.fetch(:container_health)}'
  SH
  File.write(File.join(bin, "ansible-vault"), <<~SH)
    #!/bin/sh
    printf '%s\\n' 'vault_adguard_admin_username: #{USERNAME}' \\
      'vault_adguard_admin_password: #{PASSWORD}'
  SH
  [File.join(bin, "docker"), File.join(bin, "ansible-vault")].each { |path| File.chmod(0o755, path) }

  configuration = File.join(root, "docker", "adguard", "conf", "AdGuardHome.yaml")
  if options.fetch(:config_present)
    FileUtils.mkdir_p(File.dirname(configuration))
    File.write(configuration, "schema_version: 34\n")
    File.chmod(options.fetch(:config_mode), configuration)
  end
  File.write(File.join(root, "vault.yml"), "$ANSIBLE_VAULT;1.1;AES256\nfixture\n")
  File.write(File.join(root, "vault-password"), "fixture\n")
  bin
end

def runtime_responder(options)
  lambda do |_method, target, headers, _body|
    return [options.fetch(:login_status), "<html></html>", "text/html"] if
      target.start_with?("/login.html")

    authorization = headers["authorization"].to_s
    expected = "Basic #{["#{USERNAME}:#{PASSWORD}"].pack('m0')}"
    wrong = "Basic #{["#{USERNAME}:contract-wrong-password"].pack('m0')}"
    return [options.fetch(:anonymous_status), JSON.generate("open" => true)] if authorization.empty?
    return [options.fetch(:wrong_password_status), JSON.generate("open" => true)] if
      authorization == wrong
    return [401, JSON.generate("refused" => true)] unless authorization == expected

    if target.start_with?("/control/status")
      [200, JSON.generate("running" => options.fetch(:running),
                          "protection_enabled" => options.fetch(:protection_enabled),
                          "dns_port" => 5353)]
    elsif target.start_with?("/control/filtering/status")
      [200, JSON.generate(
        "enabled" => options.fetch(:filtering_enabled),
        "filters" => [{ "enabled" => true, "id" => 1, "rules_count" => options.fetch(:rules_count),
                        "url" => "https://example.invalid/filter_1.txt" }]
      )]
    else
      [404, JSON.generate("missing" => true)]
    end
  end
end

RUNTIME_ROWS = [
  { name: "an intact deployment", given: {}, expects: nil },
  {
    name: "a login page that never answers",
    # Two seconds rather than the deployment's 120. This row can only reach the
    # refusal it names by sitting out the whole budget, which is exactly the cost
    # #319 and #485 had to remove from two other contract tests afterwards.
    given: { login_status: 503, budgets: { "PLATFORM_ADGUARD_READY_TIMEOUT_SECONDS" => "2" } },
    expects: "AdGuard never served its login page"
  },
  {
    name: "a control API served to an anonymous request",
    given: { anonymous_status: 200 },
    expects: "served its control API to an anonymous request"
  },
  {
    name: "a control API that accepts a wrong password",
    given: { wrong_password_status: 200 },
    expects: "accepted a wrong password"
  },
  {
    name: "a resolver that is not running",
    given: { running: false },
    expects: "did not report itself running"
  },
  {
    name: "a resolver with protection disabled",
    given: { protection_enabled: false },
    expects: "reported protection disabled"
  },
  {
    name: "a resolver with filtering disabled",
    given: { filtering_enabled: false },
    expects: "reported filtering disabled"
  },
  {
    name: "a declared filter list that never downloaded",
    given: { rules_count: 0,
             budgets: { "PLATFORM_ADGUARD_FILTER_POLL_TIMEOUT_SECONDS" => "2" } },
    expects: "declared filter lists never reported any rules"
  },
  {
    name: "a blocked name that resolves anyway",
    given: { blocked_addresses: ["203.0.113.7"] },
    expects: "rather than being blocked"
  },
  {
    name: "an unblocked name that does not resolve",
    given: { allowed_addresses: [] },
    expects: "did not resolve through AdGuard"
  },
  {
    name: "an unblocked name that is blocked",
    given: { allowed_addresses: ["0.0.0.0"] },
    expects: "filtering more than it declared"
  },
  {
    name: "a container Docker calls unhealthy",
    given: { container_health: "unhealthy" },
    expects: "the AdGuard container is not healthy"
  },
  {
    name: "a configuration that is not in the declared root",
    given: { config_present: false },
    expects: "not in the declared configuration root"
  },
  {
    name: "a configuration readable beyond its owner",
    given: { config_mode: 0o644 },
    expects: "not mode 0600"
  }
].freeze

def runtime_failures(program, rows = RUNTIME_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    options = RUNTIME_DEFAULTS.merge(row.fetch(:given))
    Dir.mktmpdir("nas-platform-adguard-runtime.") do |raw|
      root = File.realpath(raw)
      bin = build_runtime_sandbox(root, options)
      answers = {}
      answers[BLOCKED_NAME] = options.fetch(:blocked_addresses)
      answers[ALLOWED_NAME] = options.fetch(:allowed_addresses)
      DnsFixture.with_fixture(answers, lambda do |dns_port|
        HttpFixtureSupport.with_http_fixture(
          lambda do |http_port|
            environment = {
              "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
              "PLATFORM_ADGUARD_PORT" => http_port.to_s,
              "PLATFORM_ADGUARD_DNS_PORT" => dns_port.to_s,
              "PLATFORM_ADGUARD_CONTAINER" => "fixture-adguard",
              "PLATFORM_DOCKER_ROOT" => File.join(root, "docker"),
              "PLATFORM_CONTRACT_VAULT_FILE" => File.join(root, "vault.yml"),
              "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "vault-password")
            }.merge(options.fetch(:budgets))
            stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, program)
            collected.concat(judge("runtime: #{row.fetch(:name)}", row.fetch(:expects), stdout,
                                   stderr, status, prefix: DIAGNOSTIC_PREFIX))
          end,
          &runtime_responder(options)
        )
      end)
    end
  end
  failures
end

# --- wrapper layer ----------------------------------------------------------
#
# tests/contracts/adguard.sh resolves its two programs from its own checkout
# rather than from the tree it is inspecting, so a copy of the three files into a
# throwaway tests/contracts/ is a whole working contract.

def with_contract_copy(static: File.read(STATIC_PROGRAM), wrapper: File.read(CONTRACT),
                       runtime: File.read(RUNTIME_PROGRAM))
  Dir.mktmpdir("nas-platform-adguard-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    {
      "adguard.sh" => wrapper,
      "adguard-static.rb" => static,
      "adguard-runtime.rb" => runtime
    }.each do |name, content|
      destination = File.join(contracts, name)
      File.write(destination, content)
      File.chmod(0o755, destination)
    end
    yield root, File.join(contracts, "adguard.sh")
  end
end

def wrapper_failures
  failures = []
  with_contract_copy do |root, wrapper|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => root }, "sh", wrapper, "sometimes"
    )
    failures << "wrapper: an unknown mode was accepted" if status.success?
    failures << "wrapper: an unknown mode was refused without saying so: " \
                "#{(stdout + stderr).strip.inspect}" unless
      (stdout + stderr).include?("adguard contract accepts only static or run")

    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => root }, "sh", wrapper, "static"
    )
    failures << "wrapper: the static mode did not pass: #{(stdout + stderr).strip.inspect}" unless
      status.success? && stdout.include?("adguard static contract:")

    # The runtime mode must refuse before it connects to anything when the
    # environment it needs is absent, rather than reaching for a port some other
    # service happens to hold.
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => root, "PLATFORM_CONTRACT_VAULT_FILE" => "",
        "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => "", "PLATFORM_MAC_VAULT_FILE" => "",
        "PLATFORM_MAC_VAULT_PASSWORD_FILE" => "", "PLATFORM_DOCKER_ROOT" => "" },
      "sh", wrapper, "run"
    )
    failures << "wrapper: the runtime mode ran with no vault" if status.success?
    failures << "wrapper: the runtime mode did not name the missing input: " \
                "#{(stdout + stderr).strip.inspect}" unless
      (stdout + stderr).include?("PLATFORM_CONTRACT_VAULT_FILE is required")
  end
  failures
end

# --- the wrapper's runtime environment ------------------------------------
#
# THE BLOCK NO PASSING TEST EXECUTED until this was reviewed. The rows above
# reach adguard-runtime.rb directly, and the one wrapper row that asks for `run`
# blanks the vault variables so the script refuses at the first `:?` and never
# reaches the port defaults or the container-name derivation below them. Those
# three lines are the whole of the contract's production environment -- what a
# converged NAS is probed on when nothing exports anything -- so they are worth
# more than a syntax check.
#
# The runtime half is replaced by a program that prints what it was handed, so
# what these rows judge is the wrapper's own arithmetic rather than a real
# AdGuard.
STUB_RUNTIME = <<~'RUBY'
  #!/usr/bin/env ruby
  %w[PLATFORM_ADGUARD_PORT PLATFORM_ADGUARD_DNS_PORT PLATFORM_ADGUARD_CONTAINER
     PLATFORM_CONTRACT_VAULT_FILE PLATFORM_DOCKER_ROOT].each do |name|
    puts "#{name}=#{ENV.fetch(name, '<unset>')}"
  end
RUBY

WRAPPER_ENVIRONMENT_ROWS = [
  {
    name: "production, where nothing exports anything",
    given: {},
    expects: {
      "PLATFORM_ADGUARD_PORT" => "8083",
      "PLATFORM_ADGUARD_DNS_PORT" => "53",
      "PLATFORM_ADGUARD_CONTAINER" => "adguard"
    }
  },
  {
    name: "a disposable lane, which namespaces the container and moves both ports",
    given: {
      "PLATFORM_PROJECT_NAME" => "nas-sandbox",
      "PLATFORM_ADGUARD_PORT" => "18083",
      "PLATFORM_ADGUARD_DNS_PORT" => "15353"
    },
    expects: {
      "PLATFORM_ADGUARD_PORT" => "18083",
      "PLATFORM_ADGUARD_DNS_PORT" => "15353",
      "PLATFORM_ADGUARD_CONTAINER" => "nas-sandbox-adguard"
    }
  }
].freeze

def wrapper_environment_failures(wrapper_source: File.read(CONTRACT), rows: WRAPPER_ENVIRONMENT_ROWS)
  failures = []
  rows.each do |row|
    with_contract_copy(runtime: STUB_RUNTIME, wrapper: wrapper_source) do |root, wrapper|
      # Every name this block reads is set or explicitly unset, so the row cannot
      # pass on something the developer's own shell happened to export.
      environment = {
        "PLATFORM_CONTRACT_REPO_DIR" => root,
        "PLATFORM_CONTRACT_VAULT_FILE" => File.join(root, "vault.yml"),
        "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "vault-password"),
        "PLATFORM_DOCKER_ROOT" => File.join(root, "docker"),
        "PLATFORM_MAC_VAULT_FILE" => nil,
        "PLATFORM_MAC_VAULT_PASSWORD_FILE" => nil,
        "PLATFORM_PROJECT_NAME" => nil,
        "PLATFORM_ADGUARD_PORT" => nil,
        "PLATFORM_ADGUARD_DNS_PORT" => nil
      }.merge(row.fetch(:given))
      stdout, stderr, status = Open3.capture3(environment, "sh", wrapper, "run")
      unless status.success?
        failures << "wrapper environment: #{row.fetch(:name)}: the wrapper never reached the " \
                    "runtime half: #{(stdout + stderr).strip.inspect}"
        next
      end
      row.fetch(:expects).each do |name, value|
        next if stdout.include?("#{name}=#{value}\n")

        failures << "wrapper environment: #{row.fetch(:name)}: #{name} reached the runtime half " \
                    "as #{stdout[/^#{name}=(.*)$/, 1].inspect}, not #{value.inspect}"
      end
    end
  end
  failures
end

# The redirect's own regression. Neither real program reads stdin, so dropping
# `</dev/null` changes no outcome today -- which is exactly why it needs a
# program that does read, and why the rule cannot be proven by the contract
# passing.
def stdin_failures(wrapper_source: File.read(CONTRACT))
  greedy = "#!/usr/bin/env ruby\nleaked = $stdin.read.to_s.bytesize\n" \
           "warn \"AdGuard contract failed: consumed \#{leaked} bytes of the caller's stdin\" " \
           "if leaked.positive?\n"
  failures = []
  with_contract_copy(static: greedy, wrapper: wrapper_source) do |root, wrapper|
    stdout, stderr, _status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => root }, "sh", wrapper, "static",
      stdin_data: "x" * 4096
    )
    failures << "stdin: the static program consumed the caller's stdin" if
      (stdout + stderr).include?("consumed")
  end
  failures
end

# --- planted regressions ----------------------------------------------------

PROGRAM_MUTATIONS = [
  {
    label: "a declared file no longer having to exist",
    program: :static,
    from: 'failures << "missing #{relative}" unless File.file?(File.join(root, relative))',
    to: "failures << relative if false",
    rows: ["a declared file that is gone"],
    # The existence sweep is also what keeps the reads below it from meeting an
    # absent file, so removing it does not merely accept the repository: it
    # crashes on the first read. The row still refuses, and now says why in a
    # stack trace instead of a sentence, which is the regression.
    detects: "refused for the wrong reason"
  },
  {
    label: "the platform identity check",
    program: :static,
    from: 'spec["user"] == "${NAS_UID:?}:${NAS_GID:?}"',
    to: "true",
    rows: ["a container running as root"]
  },
  {
    label: "the unprivileged in-container listener check",
    program: :static,
    from: 'published.include?("53:5353/#{protocol}")',
    to: "true",
    rows: ["a DNS listener that would need root inside the container"]
  },
  {
    label: "the override-replaces-publications check",
    program: :static,
    from: 'source.include?("ports: !override")',
    to: "true",
    rows: ["a sandbox override that appends publications instead of replacing them"]
  },
  {
    label: "the rendered-publication check",
    program: :static,
    from: 'source.include?("${#{name}:?}")',
    to: "true",
    rows: ["an override that stopped reading the rendered host port"]
  },
  {
    label: "the literal-publication check",
    program: :static,
    from: "literal_publications.empty?",
    to: "true",
    rows: ["an override publishing a literal host port beside the rendered ones"]
  },
  {
    label: "the nonempty users check",
    program: :static,
    from: 'template.match?(/^users:\n  - name: \{\{ vault_adguard_admin_username \}\}\n/)',
    to: "true",
    rows: ["an administrator the vault did not author"]
  },
  {
    label: "the protection and filtering check",
    program: :static,
    from: 'template.include?("protection_enabled: true") && template.include?("filtering_enabled: true")',
    to: "true",
    rows: ["protection switched off in the rendered configuration"]
  },
  {
    label: "the DHCP-off check",
    program: :static,
    from: 'template.match?(/^dhcp:\n  enabled: false\n/)',
    to: "true",
    rows: ["AdGuard's own DHCP server switched on"]
  },
  {
    label: "the expanded-document floor",
    program: :static,
    from: "template.lines.length > 150",
    to: "true",
    rows: ["a configuration template trimmed towards the minimal document"]
  },
  {
    label: "the stored-hash check",
    program: :static,
    from: 'hashing_expressions.any? { |value| value.include?("password_hash(") } ||',
    to: "false ||",
    rows: ["a hash computed at converge time"]
  },
  {
    label: "the host resolver check",
    program: :static,
    from: 'writes.any? { |destination| destination.include?("resolv.conf") || destination.start_with?("/etc") }',
    to: "false",
    rows: ["a role that repoints the host resolver"]
  },
  {
    label: "the deployment gate check",
    program: :static,
    from: "deployments.all? { |_task, gates| gates.include?(GATE) }",
    to: "true",
    rows: ["a deployment that ignores the gate"]
  },
  {
    label: "the teardown check",
    program: :static,
    from: 'teardown.first.last.include?("not adguard_deployment_enabled | bool")',
    to: "true",
    rows: ["a teardown that no longer answers to the gate"]
  },
  {
    label: "the DNS-over-TLS upstream check",
    program: :static,
    from: 'Array(defaults["adguard_upstream_dns"]).all? { |upstream| upstream.to_s.start_with?("tls://") }',
    to: "true",
    rows: ["a plaintext upstream"]
  },
  {
    label: "the verification reading check",
    program: :static,
    from: "conditions_text.include?(reading)",
    to: "true",
    rows: ["a verification that reads the status page without asserting it"]
  },
  {
    label: "the running check",
    program: :runtime,
    from: 'unless status["running"] == true',
    to: "unless true",
    rows: ["a resolver that is not running"]
  },
  {
    label: "the protection check",
    program: :runtime,
    from: 'unless status["protection_enabled"] == true',
    to: "unless true",
    rows: ["a resolver with protection disabled"]
  },
  {
    label: "the anonymous refusal check",
    program: :runtime,
    from: 'request("/control/status").code == "401"',
    to: "true",
    rows: ["a control API served to an anonymous request"]
  },
  {
    label: "the wrong-password refusal check",
    program: :runtime,
    from: 'fail_contract("AdGuard accepted a wrong password") unless',
    to: 'fail_contract("AdGuard accepted a wrong password") if false &&',
    rows: ["a control API that accepts a wrong password"]
  },
  {
    label: "the loaded-rules check",
    program: :runtime,
    from: "filters.all? { |filter| filter[\"rules_count\"].to_i.positive? }",
    to: "true",
    rows: ["a declared filter list that never downloaded"]
  },
  {
    label: "the blocked-name check",
    program: :runtime,
    from: 'blocked.empty? || blocked.all? { |address| address == "0.0.0.0" }',
    to: "true",
    rows: ["a blocked name that resolves anyway"]
  },
  {
    label: "the unblocked-name check",
    program: :runtime,
    from: 'fail_contract("#{ALLOWED_NAME} did not resolve through AdGuard") if allowed.empty?',
    to: "nil",
    rows: ["an unblocked name that does not resolve"]
  },
  {
    label: "the over-blocking check",
    program: :runtime,
    from: 'allowed.any? { |address| address == "0.0.0.0" }',
    to: "false",
    rows: ["an unblocked name that is blocked"]
  },
  {
    label: "the container health check",
    program: :runtime,
    from: 'unless state.strip == "healthy"',
    to: "unless true",
    rows: ["a container Docker calls unhealthy"]
  },
  {
    label: "the configuration mode check",
    program: :runtime,
    from: "(File.stat(CONFIG).mode & 0o777) == 0o600",
    to: "true",
    rows: ["a configuration readable beyond its owner"]
  },
  # --- the rows that had no planted regression until this file was reviewed ---
  #
  # `judge` accepts a refusal when ANY line carries the prefix and the fragment,
  # so a row with no mutation behind it can pass while a different assertion is
  # doing the work. Each of the seven below now has one. The two `expects: nil`
  # rows -- an intact repository and an intact deployment -- have none and can
  # have none: they assert success, and there is no check to remove that would
  # make success wrong.
  {
    label: "the plain-address bootstrap check",
    program: :static,
    from: 'Array(defaults["adguard_bootstrap_dns"]).none? { |address| address.to_s.include?("://") }',
    to: "true",
    rows: ["a bootstrap resolver named rather than addressed"]
  },
  {
    label: "the gate-ships-off check",
    program: :static,
    from: 'defaults["adguard_deployment_enabled"] == false',
    to: "true",
    rows: ["a gate that ships on"]
  },
  {
    label: "the behavioural verification check",
    program: :static,
    from: 'conditions_text.include?("FilteredBlackList") && conditions_text.include?("NotFiltered")',
    to: "true",
    rows: ["a verification that stopped proving filtering behaviourally"]
  },
  {
    label: "the required-credential check",
    program: :static,
    from: 'options.dig(key, "required") == true && options.dig(key, "type") == "str"',
    to: "true",
    rows: ["a vault credential the role stopped requiring"]
  },
  {
    label: "the readiness check",
    program: :runtime,
    from: 'return if request("/login.html").code == "200"',
    to: "return if true",
    rows: ["a login page that never answers"]
  },
  {
    label: "the filtering-enabled check",
    program: :runtime,
    from: 'unless document["enabled"] == true',
    to: "unless true",
    rows: ["a resolver with filtering disabled"]
  },
  {
    label: "the configuration-present check",
    program: :runtime,
    from: "File.file?(CONFIG)",
    to: "true",
    rows: ["a configuration that is not in the declared root"],
    # That check is also what keeps the mode read below it from meeting an absent
    # file, so removing it does not merely accept the deployment: it crashes on
    # the stat. The row still refuses, and now says why in a backtrace instead of
    # a sentence, which is the regression.
    detects: "refused for the wrong reason"
  },
  # --- the assertions the new rows above reach ---
  {
    label: "the privileged-container check",
    program: :static,
    from: 'if spec["privileged"]',
    to: "if false",
    rows: ["a privileged container"]
  },
  {
    label: "the privilege-escalation check",
    program: :static,
    from: 'Array(spec["security_opt"]).include?("no-new-privileges:true")',
    to: "true",
    rows: ["a container that may acquire privilege after it starts"]
  },
  {
    label: "the image pin check",
    program: :static,
    from: 'spec["image"].to_s.match?(IMAGE_PIN)',
    to: "true",
    rows: ["an image pinned by tag alone"]
  },
  {
    label: "the namespaced container check",
    program: :static,
    from: 'source.include?("${PLATFORM_PROJECT_NAME:?}-adguard")',
    to: "true",
    rows: ["a sandbox container left with its production name"]
  },
  {
    label: "the converge-is-told check",
    program: :static,
    from: 'lane_source.include?("-e #{variable}=\"$#{lane_variable}\"")',
    to: "true",
    rows: ["a converge that keeps the production port while the sandbox moves"]
  },
  {
    label: "the contract-is-told-the-same check",
    program: :static,
    from: 'lane_source.include?("#{platform_name}=\"$#{lane_variable}\"")',
    to: "true",
    rows: ["a lane handing the contract a literal port"]
  },
  {
    label: "the unprivileged-lane-port check",
    program: :static,
    from: "declared > PRIVILEGED_PORT_CEILING",
    to: "true",
    rows: ["a lane that went back to the privileged port the resolver stub forbids"]
  },
  {
    label: "the stored-hash check",
    program: :static,
    from: 'template.include?("password: {{ vault_adguard_admin_password_hash }}")',
    to: "true",
    rows: ["a rendered configuration that stopped carrying the stored hash"]
  },
  {
    label: "the clear-password check",
    program: :static,
    from: 'template.include?("vault_adguard_admin_password }}")',
    to: "false",
    rows: ["a rendered configuration carrying the clear administrator password"]
  },
  {
    label: "the rendered port check",
    program: :static,
    from: 'env_source.include?("#{name}={{ #{variable} }}")',
    to: "true",
    rows: ["an environment that renders a literal instead of the role's port"]
  },
  {
    label: "the verification tag check",
    program: :static,
    from: 'verify.all? { |task| Array(task["tags"]).include?("platform_verify_adguard") }',
    to: "true",
    rows: ["a verification task that lost its tag"]
  },
  {
    label: "the status-endpoint read check",
    program: :static,
    from: "if status_reads.empty?",
    to: "if false",
    rows: ["a role that stopped reading the status endpoint"]
  },
  {
    label: "the declared-filter-list check",
    program: :static,
    from: 'Array(defaults["adguard_filters"]).empty?',
    to: "false",
    rows: ["protection on and no list to enforce"]
  },
  {
    label: "the pinned vault key check",
    program: :static,
    from: 'Array(expectations["vault_keys"]).sort == VAULT_CREDENTIALS.sort',
    to: "true",
    rows: ["an expectation file pinning the wrong vault keys"]
  },
  {
    label: "the wrapper default port check",
    program: :static,
    from: "fallback == defaults[variable]",
    to: "true",
    rows: ["a wrapper defaulting to a port the platform moved away from"]
  },
  {
    label: "the declared storage mode check",
    program: :static,
    from: 'entry["mode"] == mode',
    to: "true",
    rows: ["a working directory declared wider than permcheck leaves it"]
  },
  {
    label: "the operator decision check",
    program: :static,
    from: 'inventory.key?("adguard_deployment_enabled")',
    to: "true",
    rows: ["an inventory with no operator decision in it"]
  },
  {
    label: "the declared web publication check",
    program: :static,
    from: 'published.include?("8083:3000")',
    to: "true",
    rows: ["a web interface published somewhere the role does not declare"]
  },
  {
    label: "the exact-publication-count check",
    program: :static,
    from: "published.length == 3",
    to: "true",
    rows: ["a fourth publication nobody declared"]
  },
  {
    label: "the single-container check",
    program: :static,
    from: 'services.is_a?(Hash) && services.keys == %w[adguard]',
    to: "true",
    rows: ["a second container in the stack"]
  },
  {
    label: "the required-gate argument check",
    program: :static,
    from: 'options.dig("adguard_deployment_enabled", "required") == true',
    to: "true",
    rows: ["a gate the role does not require"]
  },
  {
    label: "the declared-upstream rendering check",
    program: :static,
    from: 'template.include?("{% for adguard_upstream in adguard_upstream_dns %}") &&',
    to: "true ||",
    rows: ["upstreams written into the template rather than declared"]
  },
  {
    label: "the declared-filter rendering check",
    program: :static,
    from: 'template.include?("{% for adguard_filter in adguard_filters %}")',
    to: "true",
    rows: ["filter lists written into the template rather than declared"]
  },
  {
    label: "the declared listening port check",
    program: :static,
    from: 'template.include?("port: {{ adguard_dns_container_port }}")',
    to: "true",
    rows: ["a listening port written into the template rather than declared"]
  },
  {
    label: "the declared storage check",
    program: :static,
    from: "if entry.nil?\n    next if entry.nil?",
    to: "if false\n    next if entry.nil?",
    rows: ["a storage declaration the platform lost"]
  },
  {
    label: "the recovery class check",
    program: :static,
    from: 'entry["recovery"] == "cache"',
    to: "true",
    rows: ["regenerable state classed as irreplaceable"]
  },
  {
    label: "the expectation role check",
    program: :static,
    from: 'expectations["role"] == "adguard"',
    to: "true",
    rows: ["an expectation file naming another role"]
  },
  {
    label: "the lane declaration check",
    program: :static,
    from: "if declared.nil?\n    next if declared.nil?",
    to: "if false\n    next if declared.nil?",
    rows: ["a lane that declares neither port"]
  },
  {
    label: "the derived-url check",
    program: :static,
    from: 'defaults["adguard_url"].to_s.include?("{{ adguard_port }}")',
    to: "true",
    rows: ["a url that hardcodes the production port"]
  },
  {
    label: "the literal-address sweep",
    program: :static,
    from: "literal_addresses.empty?",
    to: "true",
    rows: ["a task that addresses the service at a literal port"]
  }
].freeze

def plant(source, mutation)
  from = mutation.fetch(:from)
  found = source.scan(from).length
  abort "self-test could not plant #{mutation.fetch(:label)}: expected 1 match of " \
        "#{from.inspect}, found #{found}" unless found == 1

  planted = source.sub(from, mutation.fetch(:to))
  abort "self-test planted nothing for #{mutation.fetch(:label)}" if planted == source
  planted
end

def with_mutant(mutation)
  canonical = mutation.fetch(:program) == :static ? STATIC_PROGRAM : RUNTIME_PROGRAM
  Dir.mktmpdir("nas-platform-adguard-mutant.") do |directory|
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
  self_test_failures = []
  in_parallel_cases(self_test_failures, PROGRAM_MUTATIONS) do |mutation, collected|
    with_mutant(mutation) do |mutant|
      caught = if mutation.fetch(:program) == :static
                 static_failures(mutant, rows_named(STATIC_ROWS, mutation.fetch(:rows)))
               else
                 runtime_failures(mutant, rows_named(RUNTIME_ROWS, mutation.fetch(:rows)))
               end
      if caught.empty?
        collected << "removing #{mutation.fetch(:label)} was accepted"
        next
      end
      detects = mutation.fetch(:detects, "accepted what it must refuse")
      next if caught.all? { |failure| failure.include?(detects) }

      collected << "removing #{mutation.fetch(:label)} was caught by the wrong assertion: " \
                   "#{caught.join(' | ')}"
    end
  end

  unredirected = File.read(CONTRACT).sub(
    'ruby "$contract_repo_dir/tests/contracts/adguard-static.rb" "$repo_dir" </dev/null',
    'ruby "$contract_repo_dir/tests/contracts/adguard-static.rb" "$repo_dir"'
  )
  self_test_failures << "self-test could not plant a dropped stdin redirect" if
    unredirected == File.read(CONTRACT)
  self_test_failures << "a dropped stdin redirect was accepted" if
    stdin_failures(wrapper_source: unredirected).empty?

  # The wrapper's own regression, and the one the new environment rows exist for.
  # The derivation is what tells a production probe from a sandbox probe, and a
  # wrapper that hardcodes the production name reads a container the sandbox
  # never created -- which is a `docker inspect` failure blamed on AdGuard.
  unnamespaced = File.read(CONTRACT).sub(
    "PLATFORM_ADGUARD_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}adguard",
    "PLATFORM_ADGUARD_CONTAINER=adguard"
  )
  self_test_failures << "self-test could not plant a dropped container namespace" if
    unnamespaced == File.read(CONTRACT)
  self_test_failures << "a container name that ignores the sandbox namespace was accepted" if
    wrapper_environment_failures(wrapper_source: unnamespaced).empty?

  # And the production half of the same block, which a wrapper could satisfy by
  # requiring the ports rather than defaulting them -- green in every lane,
  # because every lane exports them, and refusing on the NAS where nothing does.
  undefaulted = File.read(CONTRACT).sub(
    ': "${PLATFORM_ADGUARD_PORT:=8083}"',
    ': "${PLATFORM_ADGUARD_PORT:?PLATFORM_ADGUARD_PORT is required}"'
  )
  self_test_failures << "self-test could not plant a dropped production port default" if
    undefaulted == File.read(CONTRACT)
  self_test_failures << "a wrapper with no production port default was accepted" if
    wrapper_environment_failures(wrapper_source: undefaulted).empty?

  unless self_test_failures.empty?
    self_test_failures.each { |failure| warn "FAIL #{failure}" }
    abort "#{self_test_failures.length} AdGuard contract self-test failure(s)"
  end

  # The three beyond PROGRAM_MUTATIONS are the wrapper's own: a dropped stdin
  # redirect, a dropped container namespace and a dropped production port default.
  puts "adguard contract: self-test detects #{PROGRAM_MUTATIONS.length + 3} planted regressions"
  exit
end

failures = static_failures(STATIC_PROGRAM) + runtime_failures(RUNTIME_PROGRAM) +
           wrapper_failures + wrapper_environment_failures + stdin_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} AdGuard contract violation(s)"
end

puts "adguard contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime " \
     "properties hold, the wrapper hands the runtime half the right environment in " \
     "#{WRAPPER_ENVIRONMENT_ROWS.length} deployments, and it reaches both programs with an " \
     "empty stdin"
