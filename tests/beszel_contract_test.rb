#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Beszel service contract's three Ruby programs (static, telemetry
# fixtures, runtime) and of tests/contracts/beszel.sh, layer by layer. Each row pins the
# exact diagnostic. --self-test plants a regression per guard and proves a row detects it.

require "fileutils"
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "shellwords"
require "time"
require "tmpdir"
require "uri"
require "yaml"

require_relative "case_pool_support"
require_relative "http_fixture_support"
require_relative "policy_support"
require_relative "contract_test_support"

include HttpFixtureSupport
include TestScaffold
include ContractTestSupport

ROOT = File.expand_path("..", __dir__)
# The prefix every refusal this file judges has to carry. Matching the
# fragment alone accepted a backtrace or an echoed argument as a refusal.
DIAGNOSTIC_PREFIX = "Beszel contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "beszel.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "beszel-static.rb")
FIXTURES_PROGRAM = File.join(ROOT, "tests", "contracts", "beszel-telemetry-fixtures.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "beszel-runtime.rb")

STATIC_SUCCESS = "Beszel static contract passed"

# Exactly what the static program reads. The wrapper is listed because the static
# half reads its own text unconditionally.
FIXTURE_FILES = %w[
  roles/beszel/defaults/main.yml
  roles/beszel/vars/main.yml
  roles/beszel/tasks/main.yml
  roles/beszel/tasks/deploy.yml
  roles/beszel/tasks/superuser.yml
  roles/beszel/tasks/application_user.yml
  roles/beszel/tasks/managed_users.yml
  roles/beszel/tasks/configure.yml
  roles/beszel/tasks/alert.yml
  roles/beszel/meta/argument_specs.yml
  roles/beszel/templates/env.j2
  roles/dozzle/templates/env.j2
  inventory/group_vars/all/service_dozzle.yml
  services/beszel/compose.yml
  inventory/group_vars/nas_hosts/main.yml
  inventory/group_vars/mac_hosts/main.yml
  tests/mac/hooks/verify/10-beszel.sh
  tests/mac/hooks/drift/10-beszel.sh
  library/beszel_telemetry_probe.py
  module_utils/beszel_telemetry.py
  tests/policy_support.rb
  tests/http_fixture_support.rb
  tests/contracts/support/beszel_telemetry.rb
  tests/contracts/beszel.sh
].freeze

def build_fixture_repository(root, omit: [])
  FIXTURE_FILES.each do |relative|
    next if omit.include?(relative)

    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(ROOT, relative), destination)
  end
  root
end

# Every substitution states its expected match count: a bare `sub` cannot tell a
# replacement that planted nothing from one that worked.
def mutate_text(root, relative, pattern, replacement, occurrences: 1)
  path = File.join(root, relative)
  body = File.read(path)
  found = body.scan(pattern).length
  raise "#{relative}: expected #{occurrences} match(es) of #{pattern.inspect}, " \
        "found #{found}" unless found == occurrences

  File.write(path, occurrences == 1 ? body.sub(pattern, replacement) : body.gsub(pattern, replacement))
end

def mutate_yaml(root, relative)
  path = File.join(root, relative)
  document = YAML.safe_load_file(path, aliases: true)
  yield document
  File.write(path, YAML.dump(document))
end

# ---------------------------------------------------------------------------
# Static layer
# ---------------------------------------------------------------------------

# The drift hook's refusal anchor; the prefix comes from TASK_REFUSAL_PREFIX so an
# ansible-core rewording moves one literal.
GUARD_DIAGNOSTIC = "Managed application user is absent or differs from the verified admin contract."
DRIFT_ANCHOR = "#{HttpFixtureSupport::TASK_REFUSAL_PREFIX}#{GUARD_DIAGNOSTIC}".freeze
DRIFT_ANCHOR_DIAGNOSTIC =
  "Mac drift hook does not anchor on the managed application user guard's own refusal"

STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  {
    name: "a hub that lost the default network beside the alert relay bridge",
    break: lambda { |root|
      mutate_text(root, "services/beszel/compose.yml",
                  "    networks:\n      - default\n      - alert-bridge\n",
                  "    networks:\n      - alert-bridge\n")
    },
    expects: "hub must join default and the external alert-relay bridge"
  },
  # The resolved-root sentinel lives in the self-read layer: its plant is in the wrapper.
  {
    name: "defaults that infer platform telemetry instead of requiring it",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "beszel_require_gpu_telemetry: false",
                  "beszel_require_gpu_telemetry: true")
    },
    expects: "defaults must not silently infer platform telemetry"
  },
  {
    name: "default categories that are no longer closed",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "beszel_required_telemetry_categories: []",
                  "beszel_required_telemetry_categories: [core]")
    },
    expects: "defaults must not silently infer platform telemetry"
  },
  {
    name: "a freshness window that is not three one-minute samples",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "beszel_telemetry_freshness_seconds: 180",
                  "beszel_telemetry_freshness_seconds: 240")
    },
    expects: "freshness must cover exactly three one-minute samples"
  },
  {
    name: "a drifted telemetry polling timeout",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "beszel_telemetry_poll_timeout_seconds: 90",
                  "beszel_telemetry_poll_timeout_seconds: 91")
    },
    expects: "telemetry polling timeout differs"
  },
  {
    # Every recovery would ring at priority 1 again: the direct URL #558 shipped.
    name: "a notification webhook still sending to Pushover directly",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "generic://alert-relay:{{ dozzle_alert_relay_port }}/beszel?disabletls=yes&template=json&@Authorization={{\n" \
                  "  ('Bearer ' ~ vault_dozzle_alert_relay_token) | urlencode }}",
                  "pushover://shoutrrr:{{ vault_pushover_alerts_token }}@{{ vault_pushover_user_key }}/?priority=1")
    },
    expects: "notification webhook still sends to pushover:// directly instead of through the relay"
  },
  {
    # The relay answers /alerts with Dozzle's envelope rules, so Beszel's
    # two-key body would be refused with 400.
    name: "a notification webhook that is not the relay's /beszel route",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "/beszel?disabletls=yes", "/alerts?disabletls=yes")
    },
    expects: "notification webhook is not the alert relay's /beszel route with the relay token"
  },
  {
    # A publishing credential in Beszel's database, and a 401 from the relay.
    name: "a notification webhook naming the Containers token instead of the relay token",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "vault_dozzle_alert_relay_token) | urlencode",
                  "vault_pushover_containers_token) | urlencode")
    },
    expects: "notification webhook does not authenticate with vault_dozzle_alert_relay_token"
  },
  {
    # No bearer header: the relay refuses every Beszel alert with 401.
    name: "a notification webhook without the Authorization header",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "&@Authorization={{\n  ('Bearer ' ~ vault_dozzle_alert_relay_token) | urlencode }}", "")
    },
    expects: "notification webhook carries no @Authorization header for the relay"
  },
  {
    # #598's shape: the diagnostic reports [REDACTED] for the correct webhook.
    name: "a webhook scheme summary still matching ^pushover://",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/configure.yml",
                  "select('match', '^generic://')", "select('match', '^pushover://')")
    },
    expects: "webhook scheme summary does not match the relay URL's generic:// scheme"
  },
  {
    # Every "Open in Beszel" button disappears, and nothing else changes.
    name: "a relay link base that diverges from Beszel's APP_URL",
    break: lambda { |root|
      mutate_text(root, "roles/dozzle/templates/env.j2",
                  "BESZEL_LINK_BASE={{ beszel_app_url }}",
                  "BESZEL_LINK_BASE={{ dozzle_alert_relay_link_base }}")
    },
    expects: "Beszel's APP_URL and the relay's BESZEL_LINK_BASE are not both beszel_app_url"
  },
  {
    name: "a Beszel APP_URL that diverges from the relay's link base",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/templates/env.j2",
                  "BESZEL_APP_URL={{ beszel_app_url }}",
                  "BESZEL_APP_URL=http://{{ platform_public_host }}:{{ beszel_port }}")
    },
    expects: "Beszel's APP_URL and the relay's BESZEL_LINK_BASE are not both beszel_app_url"
  },
  {
    # Planted with different spacing, so a literal-expression comparison would miss it.
    name: "effective categories inferred from the GPU input again",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/vars/main.yml",
                  "beszel_effective_required_telemetry_categories: >-\n" \
                  "  {{ ['core', 'disk', 'containers']\n",
                  "beszel_effective_required_telemetry_categories: >-\n" \
                  "  {{ (['gpu'] if beszel_require_gpu_telemetry|bool else []) +\n" \
                  "     ['core', 'disk', 'containers']\n")
    },
    expects: "effective categories must use explicit inventory policy"
  },
  {
    name: "effective categories that are not derived at all",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/vars/main.yml",
                  "beszel_effective_required_telemetry_categories: >-",
                  "beszel_effective_required_telemetry_category_set: >-")
    },
    expects: "effective categories must use explicit inventory policy"
  },
  {
    name: "derived retry arithmetic reintroduced beside the deadline",
    break: lambda { |root|
      path = File.join(root, "roles/beszel/vars/main.yml")
      File.write(path, "#{File.read(path)}beszel_telemetry_poll_retries: >-\n" \
                       "  {{ (beszel_telemetry_poll_timeout_seconds | int) // 3 }}\n")
    },
    expects: "telemetry polling must not use derived retry arithmetic"
  },
  {
    name: "retry arithmetic hidden inside another derived value",
    break: lambda { |root|
      path = File.join(root, "roles/beszel/vars/main.yml")
      File.write(path, "#{File.read(path)}beszel_poll_budget: >-\n" \
                       "  {{ beszel_telemetry_poll_retries | default(3) }}\n")
    },
    expects: "telemetry polling must not use derived retry arithmetic"
  }
].concat(
  # All five typed inputs: the check loop names each by its own variable.
  {
    "beszel_required_telemetry_categories" => %w[list str],
    "beszel_require_gpu_telemetry" => %w[bool str],
    "beszel_telemetry_freshness_seconds" => %w[int str],
    "beszel_telemetry_poll_timeout_seconds" => %w[int str],
    "beszel_telemetry_request_timeout_seconds" => %w[int str]
  }.map do |name, (from, to)|
    {
      name: "#{name} declared as #{to} rather than #{from}",
      break: lambda { |root|
        mutate_text(root, "roles/beszel/meta/argument_specs.yml",
                    "      #{name}:\n        type: #{from}\n",
                    "      #{name}:\n        type: #{to}\n")
      },
      expects: "#{name} argument validation is absent"
    }
  end
).concat(
  # Renamed rather than deleted: a name surviving only in a comment must not count.
  {
    "Require the selected Beszel telemetry capability" => "roles/beszel/tasks/deploy.yml",
    "Poll persisted Beszel telemetry collections" => "roles/beszel/tasks/configure.yml",
    "Require exactly one managed Beszel system for telemetry" => "roles/beszel/tasks/configure.yml",
    "Resolve persisted Beszel telemetry evidence" => "roles/beszel/tasks/configure.yml",
    "Verify persisted Beszel telemetry categories" => "roles/beszel/tasks/configure.yml"
  }.map do |task, file|
    {
      name: "the #{task.downcase} task surviving only under another name",
      break: ->(root) { mutate_text(root, file, "name: #{task}", "name: #{task} (retired)") },
      expects: "missing #{task}"
    }
  end
).concat([
  {
    name: "a telemetry poll that no longer suppresses authenticated results",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/configure.yml",
                  "      register: beszel_telemetry_probe_result\n" \
                  "      check_mode: false\n      no_log: true\n",
                  "      register: beszel_telemetry_probe_result\n" \
                  "      check_mode: false\n      no_log: false\n")
    },
    expects: "persisted telemetry poll must suppress authenticated results"
  },
  {
    name: "a telemetry poll that is not one deadline-aware probe",
    break: lambda { |root|
      mutate_yaml(root, "roles/beszel/tasks/configure.yml") do |document|
        task = find_task(document, "Poll persisted Beszel telemetry collections")
        task["ansible.builtin.uri"] = task.delete("beszel_telemetry_probe")
      end
    },
    expects: "persisted telemetry poll must use one deadline-aware probe"
  },
  {
    name: "a telemetry probe invoked without authentication",
    break: lambda { |root|
      mutate_yaml(root, "roles/beszel/tasks/configure.yml") do |document|
        find_task(document, "Poll persisted Beszel telemetry collections")
          .fetch("beszel_telemetry_probe").delete("auth_token")
      end
    },
    expects: "persisted telemetry probe is not authenticated"
  },
  {
    name: "a telemetry probe that no longer receives the total deadline",
    break: lambda { |root|
      mutate_yaml(root, "roles/beszel/tasks/configure.yml") do |document|
        find_task(document, "Poll persisted Beszel telemetry collections")
          .fetch("beszel_telemetry_probe").delete("delay_seconds")
      end
    },
    expects: "persisted telemetry probe does not receive the total deadline"
  },
  {
    name: "a probe implementation without its polling entry point",
    break: lambda { |root|
      mutate_text(root, "library/beszel_telemetry_probe.py",
                  "poll_telemetry", "poll_platform_telemetry", occurrences: 3)
    },
    expects: "deadline probe implementation is absent"
  },
  {
    name: "a probe support module that no longer fetches container stats",
    break: lambda { |root|
      mutate_text(root, "module_utils/beszel_telemetry.py",
                  'fetcher("container_stats"', 'fetcher("container_statistics"')
    },
    expects: "deadline probe implementation is absent"
  },
  {
    name: "a role that treats live health as persisted telemetry",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/configure.yml",
                  "      register: beszel_telemetry_probe_result\n",
                  "      register: beszel_live_health_result\n")
    },
    expects: "role treats live health as persisted telemetry"
  },
  {
    # The probe registers its result but nothing consumes it.
    name: "probe evidence that no task consumes",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/configure.yml",
                  "beszel_telemetry_probe_result.evidence.", "beszel_unread_evidence.",
                  # Stated count: a reading that stops landing is an edit here.
                  occurrences: 5)
    },
    expects: "role treats live health as persisted telemetry"
  },
  {
    name: "a NAS Intel agent from some other publisher",
    break: lambda { |root|
      mutate_text(root, "services/beszel/compose.yml",
                  "ghcr.io/henrygd/beszel/beszel-agent-intel:",
                  "docker.io/henrygd/beszel-agent-intel:")
    },
    expects: "NAS Intel agent image differs"
  },
  {
    # Present but not the platform's device. Deleting the key instead is a bare
    # KeyError with no sentence to assert, so it stays unpinned.
    name: "an Intel agent bound to some other render device",
    break: lambda { |root|
      mutate_yaml(root, "services/beszel/compose.yml") do |document|
        # Only the render entry moves: replacing the whole list would also drop
        # the S.M.A.R.T. slots, which is a different refusal.
        document.fetch("services").fetch("agent-intel").fetch("devices")[0] =
          "${NAS_RENDER_DEVICE:?}:/dev/dri/card0"
      end
    },
    expects: "NAS Intel render device differs"
  },
  {
    name: "an inventory render device path the compose definition cannot use",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/nas_hosts/main.yml",
                  "platform_render_device_path: /dev/dri/renderD128",
                  "platform_render_device_path: /dev/dri/renderD129")
    },
    expects: "NAS Intel render device differs"
  },
  {
    # Deleted from Compose rather than added to inventory: a longer inventory list
    # would also trip the slot guard and hide this check.
    name: "an inventory SATA disk with no Compose slot",
    break: lambda { |root|
      mutate_yaml(root, "services/beszel/compose.yml") do |document|
        document.fetch("services").fetch("agent-intel").fetch("devices")
                .reject! { |device| device.include?("NAS_SMART_SATA_DEVICE_3") }
      end
    },
    expects: "NAS Intel S.M.A.R.T. device slots differ from inventory"
  },
  {
    name: "an NVMe slot mapped read-write",
    break: lambda { |root|
      mutate_text(root, "services/beszel/compose.yml",
                  "${NAS_SMART_NVME_NAMESPACE_2:?}:/dev/nvme1:r",
                  "${NAS_SMART_NVME_NAMESPACE_2:?}:/dev/nvme1")
    },
    expects: "NAS Intel S.M.A.R.T. device slots differ from inventory"
  },
  {
    name: "an Intel agent without the NVMe passthrough capability",
    break: lambda { |root|
      mutate_yaml(root, "services/beszel/compose.yml") do |document|
        document.fetch("services").fetch("agent-intel").fetch("cap_add").delete("CAP_SYS_ADMIN")
      end
    },
    expects: "NAS Intel agent lacks the S.M.A.R.T. capabilities"
  },
  {
    name: "a role slot guard that no longer counts the NVMe disks",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/deploy.yml",
                  "platform_smart_nvme_namespaces | length == 2)",
                  "platform_smart_nvme_namespaces | length >= 0)")
    },
    expects: "role does not pin the S.M.A.R.T. slot count to Compose"
  },
  {
    # Under --check a stat that does not really run reports every device absent,
    # so the diff an operator reads would show every slot going to /dev/null.
    name: "a device presence stat that is skipped under --check",
    break: lambda { |root|
      mutate_yaml(root, "roles/beszel/tasks/deploy.yml") do |document|
        find_task(document, "Look for each declared S.M.A.R.T. device node on this host").delete("check_mode")
      end
    },
    expects: "role does not tolerate an absent S.M.A.R.T. device"
  },
  {
    # The failure the tolerance exists to remove: one pulled disk failing every
    # five-minute tick and blocking every deploy behind it.
    name: "an absent S.M.A.R.T. device that fails the deploy",
    break: lambda { |root|
      mutate_yaml(root, "roles/beszel/tasks/deploy.yml") do |document|
        task = find_task(document, "Warn about declared S.M.A.R.T. devices absent from this host")
        task["ansible.builtin.fail"] = task.delete("ansible.builtin.debug")
      end
    },
    expects: "role does not tolerate an absent S.M.A.R.T. device"
  },
  {
    # The other way to lose the tolerance: the slot bypasses the presence check
    # and renders the declared path whether or not the node is there.
    name: "an env slot that renders the declared path unchecked",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/templates/env.j2",
                  "{{ beszel_smart_rendered_slots['NAS_SMART_NVME_NAMESPACE_1'] | default('/dev/null') }}",
                  "{{ platform_smart_nvme_namespaces[0] | default('/dev/null') }}")
    },
    expects: "env template renders a S.M.A.R.T. slot without the presence check"
  },
  {
    name: "a portable agent that lost a capacity mount",
    break: lambda { |root|
      mutate_yaml(root, "services/beszel/compose.yml") do |document|
        document.fetch("services").fetch("agent-portable").fetch("volumes")
                .reject! { |mount| mount.include?("/extra-filesystems/volume2") }
      end
    },
    expects: "agent capacity mounts differ"
  },
  {
    name: "an Intel agent that lost a capacity mount",
    break: lambda { |root|
      mutate_yaml(root, "services/beszel/compose.yml") do |document|
        document.fetch("services").fetch("agent-intel").fetch("volumes")
                .reject! { |mount| mount.include?("/extra-filesystems/volume1") }
      end
    },
    expects: "agent capacity mounts differ"
  },
  {
    name: "a socket proxy with a writable Docker socket",
    break: lambda { |root|
      mutate_text(root, "services/beszel/compose.yml",
                  "/var/run/docker.sock:/var/run/docker.sock:ro",
                  "/var/run/docker.sock:/var/run/docker.sock")
    },
    expects: "socket proxy is absent"
  },
  {
    name: "a Mac host declaring the Intel agent",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/mac_hosts/main.yml",
                  "platform_beszel_agent_kind: portable",
                  "platform_beszel_agent_kind: intel")
    },
    expects: "Mac must use portable telemetry without a render device"
  },
  {
    name: "a Mac host that claims GPU telemetry",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/mac_hosts/main.yml",
                  "beszel_require_gpu_telemetry: false",
                  "beszel_require_gpu_telemetry: true")
    },
    expects: "Mac must use portable telemetry without a render device"
  },
  {
    name: "a NAS host that stopped requiring GPU telemetry",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/nas_hosts/main.yml",
                  "beszel_require_gpu_telemetry: true",
                  "beszel_require_gpu_telemetry: false")
    },
    expects: "NAS telemetry policy must explicitly require GPU"
  },
  {
    name: "a NAS category list that no longer names gpu",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/nas_hosts/main.yml",
                  "  - containers\n  - gpu\n", "  - containers\n")
    },
    expects: "NAS telemetry policy must explicitly require GPU"
  },
  {
    name: "a Mac verify hook that skips the persisted telemetry proof",
    break: lambda { |root|
      mutate_text(root, "tests/mac/hooks/verify/10-beszel.sh",
                  '"$mac_hook_dir/../../run-beszel-contract.sh" verify',
                  '"$mac_hook_dir/../../run-beszel-contract.sh" notify')
    },
    expects: "Mac verification does not execute persisted telemetry proof"
  },
  {
    name: "a Mac drift hook that skips category rejection semantics",
    break: lambda { |root|
      mutate_text(root, "tests/mac/hooks/drift/10-beszel.sh",
                  'ruby "$mac_script_dir/../beszel_telemetry_probe_test.rb"', "true")
    },
    expects: "Mac drift hook does not execute category rejection semantics"
  },
  # The static half derives the anchor from the role's fail_msg and the prefix, so
  # each end is broken separately.
  {
    name: "a Mac drift hook with no refusal anchor",
    break: lambda { |root|
      mutate_text(root, "tests/mac/hooks/drift/10-beszel.sh",
                  %("#{DRIFT_ANCHOR}"), '"PLAY [nas]"')
    },
    expects: DRIFT_ANCHOR_DIAGNOSTIC
  },
  {
    name: "a Mac drift hook whose refusal anchor survives only in a comment",
    break: lambda { |root|
      mutate_text(root, "tests/mac/hooks/drift/10-beszel.sh",
                  %("#{DRIFT_ANCHOR}"), '"PLAY [nas]"')
      File.write(File.join(root, "tests/mac/hooks/drift/10-beszel.sh"),
                 "# #{DRIFT_ANCHOR}\n", mode: "a")
    },
    expects: DRIFT_ANCHOR_DIAGNOSTIC
  },
  {
    name: "a role guard reworded without its hook",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/application_user.yml",
                  GUARD_DIAGNOSTIC, "Managed application user does not meet its contract.")
    },
    expects: DRIFT_ANCHOR_DIAGNOSTIC
  },
  {
    name: "a role guard that refuses without saying why",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/application_user.yml",
                  "fail_msg: #{GUARD_DIAGNOSTIC}", 'fail_msg: ""')
    },
    expects: "the managed application user guard states no diagnostic to anchor on"
  },
  {
    name: "a role guard that censors the diagnostic its hook reads",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/application_user.yml",
                  "    fail_msg: #{GUARD_DIAGNOSTIC}\n  when: not ansible_check_mode\n",
                  "    fail_msg: #{GUARD_DIAGNOSTIC}\n  no_log: true\n  when: not ansible_check_mode\n")
    },
    expects: "the managed application user guard censors the diagnostic the hook reads"
  },
  {
    name: "a role guard dropped from the verification tag",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/application_user.yml",
                  "- name: Verify the managed application user contract\n  tags: [platform_verify_beszel]\n",
                  "- name: Verify the managed application user contract\n")
    },
    expects: "the managed application user guard is not selected by the verification tag"
  },
  {
    name: "a renamed managed application user guard",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/application_user.yml",
                  "Verify the managed application user contract",
                  "Verify the managed application account contract")
    },
    expects: "the managed application user guard is absent or ambiguous"
  }
]).freeze

def find_task(document, name)
  found = nil
  walk = lambda do |node|
    case node
    when Hash
      found ||= node if node["name"] == name
      node.each_value { |value| walk.call(value) }
    when Array then node.each { |value| walk.call(value) }
    end
  end
  walk.call(document)
  raise "the fixture has no task named #{name.inspect}" unless found

  found
end

def static_failures(program = STATIC_PROGRAM, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-beszel-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root },
        RbConfig.ruby, "-ryaml", program, root, in: "/dev/null"
      )
      collected.concat(judge("static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                             prefix: DIAGNOSTIC_PREFIX))
    end
  end
  failures
end

# The static program reads these with no File.file? guard, so a missing one is an
# ENOENT/LoadError, not a diagnostic; this layer only asserts removal is noticed.
# Measured exceptions: three stage files static_role_tasks tolerates, and the support lib.
UNREAD_BY_STATIC = %w[
  roles/beszel/tasks/superuser.yml
  roles/beszel/tasks/managed_users.yml
  roles/beszel/tasks/alert.yml
  tests/contracts/support/beszel_telemetry.rb
  inventory/group_vars/all/service_dozzle.yml
].freeze

def missing_file_failures(program = STATIC_PROGRAM)
  failures = []
  in_parallel_cases(failures, FIXTURE_FILES) do |relative, collected|
    Dir.mktmpdir("nas-platform-beszel-missing.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root, omit: [relative])
      _out, _err, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root },
        RbConfig.ruby, "-ryaml", program, root, in: "/dev/null"
      )
      expected_success = UNREAD_BY_STATIC.include?(relative)
      if status.success? != expected_success
        collected << "missing-file: removing #{relative} " \
                     "#{status.success? ? 'was accepted' : 'was refused'}, " \
                     "wanted the opposite"
      end
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Fixtures layer (telemetry-fixtures)
# ---------------------------------------------------------------------------

NOW = Time.utc(2026, 8, 12, 12, 0, 0)

def telemetry_fixture
  {
    "now" => NOW.iso8601(3),
    "system" => { "id" => "system-safe-id", "status" => "up" },
    "system_stats" => {
      "id" => "system-stats-safe-id", "system" => "system-safe-id", "type" => "1m",
      "created" => (NOW - 60).iso8601(3),
      "stats" => { "cpu" => 0.0, "m" => 8.0, "mu" => 2.0, "mp" => 25.0,
                   "d" => 100.0, "du" => 40.0, "dp" => 40.0,
                   "g" => { "0" => { "n" => "Intel", "u" => 0.0 } } }
    },
    "container_stats" => {
      "id" => "container-stats-safe-id", "system" => "system-safe-id", "type" => "1m",
      "created" => (NOW - 60).iso8601(3),
      "stats" => [{ "n" => "beszel", "c" => 0.0, "m" => 0.1 }]
    }
  }
end

# The fixture program aborts under its own prefix, not DIAGNOSTIC_PREFIX.
FIXTURES_DIAGNOSTIC_PREFIX = "Beszel telemetry fixture failed: "

FIXTURES_ROWS = [
  { name: "a complete Mac triple", platform: "mac", mutate: ->(_data) {},
    expects: nil, wants: "Beszel telemetry fixture passed (mac)" },
  { name: "a complete NAS triple", platform: "nas", mutate: ->(_data) {},
    expects: nil, wants: "Beszel telemetry fixture passed (nas)" },
  { name: "a platform the contract does not support", platform: "linux",
    mutate: ->(_data) {}, expects: "unknown platform" },
  { name: "the empty platform", platform: "", mutate: ->(_data) {},
    expects: "unknown platform" },
  { name: "a NAS triple with no GPU sample", platform: "nas",
    mutate: ->(data) { data.fetch("system_stats").fetch("stats").delete("g") },
    expects: "categories=gpu" },
  { name: "a sample older than the freshness window", platform: "mac",
    mutate: ->(data) { data.fetch("system_stats")["created"] = (NOW - 181).iso8601(3) },
    expects: "categories=core,disk" },
  { name: "a sample belonging to another system", platform: "mac",
    mutate: ->(data) { data.fetch("system_stats")["system"] = "another-system" },
    expects: "record IDs=system_stats:system-stats-safe-id" },
  { name: "an empty container sample", platform: "mac",
    mutate: ->(data) { data.fetch("container_stats")["stats"] = [] },
    expects: "categories=containers" },
  {
    # The health-only row also proves the fixture half never echoes the payload:
    # the token planted here must not reach the diagnostic.
    name: "a healthy system with no persisted records at all", platform: "mac",
    mutate: lambda { |data|
      data.delete("system_stats")
      data.delete("container_stats")
      data["token"] = "beszel-contract-sensitive-token"
    },
    expects: "categories=core,disk,containers",
    refuses_to_leak: "beszel-contract-sensitive-token"
  },
  # A missing clock raises from Hash#fetch, so it is asked for as a crash.
  { name: "a fixture with no recorded clock", platform: "mac",
    mutate: ->(data) { data.delete("now") },
    expects: nil, expects_crash: 'key not found: "now"' }
].freeze

def fixtures_failures(program = FIXTURES_PROGRAM, rows = FIXTURES_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    label = "fixtures: #{row.fetch(:name)}"
    Dir.mktmpdir("nas-platform-beszel-fixtures.") do |raw|
      sandbox = File.realpath(raw)
      payload = telemetry_fixture
      row.fetch(:mutate).call(payload)
      path = File.join(sandbox, "fixture.json")
      File.write(path, JSON.generate(payload), mode: "w", perm: 0o600)
      # No vault environment: the wrapper reaches this program before its ${VAR:?}
      # checks, and tests/beszel_telemetry_probe_test.rb depends on that.
      stdout, stderr, status = Open3.capture3(
        { "PATH" => ENV.fetch("PATH") },
        RbConfig.ruby, "-rjson",
        "-r#{File.join(ROOT, 'tests/contracts/support/beszel_telemetry')}",
        program, row.fetch(:platform), path, in: "/dev/null", unsetenv_others: true
      )
      collected.concat(judge(label, row.fetch(:expects), stdout, stderr, status,
                             prefix: FIXTURES_DIAGNOSTIC_PREFIX,
                             expects_crash: row[:expects_crash]))
      output = stdout + stderr
      if row[:wants] && !output.include?(row.fetch(:wants))
        collected << "#{label}: did not report #{row.fetch(:wants).inspect}, " \
                     "got #{output.strip.inspect}"
      end
      if row[:refuses_to_leak] && output.include?(row.fetch(:refuses_to_leak))
        collected << "#{label}: the diagnostic echoed the fixture payload"
      end
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Runtime layer
# ---------------------------------------------------------------------------
#
# Beszel's PocketBase API as one HTTP fixture. The *managed* webhook (Pushover via the
# relay) is compared, never delivered; the notification proof sends its own shoutrrr
# generic URL, proving hub dispatch, not that the stored URL is deliverable.

SUPER_EMAIL = "beszel-super@example.invalid"
SUPER_PASSWORD = "beszel-contract-superuser-password"
APP_EMAIL = "beszel-app@example.invalid"
APP_PASSWORD = "beszel-contract-app-password"
UNIVERSAL_TOKEN = "33333333-3333-4333-a333-333333333333"
PUSHOVER_TOKEN = "beszel-contract-pushover-token"
# Deliberately not hex: exercises URL encoding; the literal below is what Ansible's
# urlencode rendered for it.
RELAY_TOKEN = "relay+tok/en=a&b%c"
PUSHOVER_USER_KEY = "beszel-contract-pushover-user-key"
ADMIN_TOKEN = "beszel-contract-admin-token"
APP_TOKEN = "beszel-contract-app-session-token"
SYSTEM_NAME = "ASUSTOR-AS6704T"
DECOY_NAME = "00-contract-decoy"
WRONG_OWNER_EMAIL = "wrong-owner-fixture@example.invalid"
CALLBACK_HOST = "beszel-callback.example.invalid"
DRIFT_TOKEN = "11111111-1111-4111-a111-111111111111"
DRIFT_WEBHOOK =
  "https://sentinel-user:sentinel-password@example.invalid/hook?api_key=sentinel-query-key"
# Pinned, not derived: reading beszel_alerts here too would move both sides at once.
# alert_pin_failures holds this literal against the defaults.
MANAGED_ALERTS = { "Status" => [0, 0], "CPU" => [90, 10],
                   "Memory" => [90, 10], "Disk" => [85, 10],
                   "Temperature" => [88, 15] }.freeze

# Compared over the union of names: walking the pin would miss a deleted alert.
def alert_pin_failures(root = ROOT)
  declared = YAML.safe_load_file(File.join(root, "roles/beszel/defaults/main.yml"))
                 .fetch("beszel_alerts")
                 .to_h { |alert| [alert.fetch("name"), [alert.fetch("value"), alert.fetch("min")]] }
  (MANAGED_ALERTS.keys | declared.keys).filter_map do |name|
    next if MANAGED_ALERTS[name] == declared[name]

    "alert pin: #{name} is pinned at #{MANAGED_ALERTS[name].inspect} but " \
      "roles/beszel/defaults/main.yml declares #{declared[name].inspect}"
  end
end

DELIVERED_MESSAGE = "This is a notification from Beszel."

VAULT = {
  "vault_beszel_superuser_email" => SUPER_EMAIL,
  "vault_beszel_superuser_password" => SUPER_PASSWORD,
  "vault_beszel_app_user_email" => APP_EMAIL,
  "vault_beszel_app_user_password" => APP_PASSWORD,
  "vault_beszel_universal_token" => UNIVERSAL_TOKEN,
  "vault_pushover_alerts_token" => PUSHOVER_TOKEN,
  "vault_pushover_user_key" => PUSHOVER_USER_KEY,
  "vault_dozzle_alert_relay_token" => RELAY_TOKEN
}.freeze

# The header is the bytes Ansible rendered for RELAY_TOKEN, so the program's encoder
# is judged against Jinja, not itself.
def expected_webhook(header = "Bearer%20relay%2Btok/en%3Da%26b%25c")
  "generic://alert-relay:8081/beszel?disabletls=yes&template=json&@Authorization=#{header}"
end

# Modelled on Beszel 0.19.0's SendShoutrrrAlert / shoutrrr generic: only `generic`,
# `disabletls` and CALLBACK_HOST reach the recorder; failures return the hub's `err`
# string, nil is a delivery. Two-second timeouts bound a recorder that never answers.
def deliver_test_notification(url, state)
  uri = URI(url.to_s)
  return "unknown service" unless uri.scheme == "generic"
  return "tls: first record does not look like a TLS handshake" unless
    %w[true 1 yes y].include?(URI.decode_www_form(uri.query.to_s).to_h["disabletls"].to_s.downcase)
  return "dial tcp: lookup #{uri.host}: no such host" unless uri.host == CALLBACK_HOST

  # Measured on a real 0.19.0 hub: template=json sends {message,title} as JSON and
  # @key query params become decoded headers; without a template, text/plain.
  params = URI.decode_www_form(uri.query.to_s)
  headers = params.select { |key, _value| key.start_with?("@") }
                  .to_h { |key, value| [key.delete_prefix("@"), value] }
  headers.delete("Authorization") if state.fetch(:delivered_without_authorization, false)
  message = "#{state.fetch(:delivered_message, DELIVERED_MESSAGE)}\n\nhttp://beszel.example.invalid"
  if params.to_h["template"] == "json"
    envelope = { "message" => message, "title" => "Test Alert" }
    envelope["priority"] = "2" if state.fetch(:delivered_extra_key, false)
    body = JSON.generate(envelope)
    headers["Content-Type"] = "application/json"
  else
    body = "Test Alert\n\n#{message}"
    headers["Content-Type"] = "text/plain"
  end
  response = Net::HTTP.start("127.0.0.1", uri.port, open_timeout: 2, read_timeout: 2) do |http|
    http.post(uri.path.empty? ? "/" : uri.path, body, headers)
  end
  "server returned unexpected response status code: #{response.code}" if response.code.to_i >= 400
rescue URI::InvalidURIError, SystemCallError, Timeout::Error => error
  "sending HTTP request: #{error.class}"
end

def converged_state
  {
    users: [{ "id" => "app-user", "email" => APP_EMAIL, "verified" => true,
              "role" => "admin" }],
    systems: [{ "id" => "managed-system", "name" => SYSTEM_NAME, "users" => ["app-user"] }],
    universal_tokens: [{ "id" => "token-record", "user" => "app-user",
                         "token" => UNIVERSAL_TOKEN }],
    user_settings: [{ "id" => "settings-record", "user" => "app-user" }],
    alerts: MANAGED_ALERTS.map.with_index do |(name, (value, duration)), index|
      { "id" => "alert-#{index}", "user" => "app-user", "system" => "managed-system",
        "name" => name, "value" => value, "min" => duration }
    end
  }
end

def telemetry_records(state, collection)
  return state.fetch(collection) if state.key?(collection)

  created = (Time.now.utc - 60).iso8601(3)
  case collection
  when :system_stats
    [{ "id" => "system-stats-record", "system" => "managed-system", "type" => "1m",
       "created" => created,
       "stats" => { "cpu" => 1.0, "m" => 8.0, "mu" => 2.0, "mp" => 25.0,
                    "d" => 100.0, "du" => 40.0, "dp" => 40.0,
                    "g" => { "0" => { "n" => "Intel", "u" => 3.0 } } } }]
  else
    [{ "id" => "container-stats-record", "system" => "managed-system", "type" => "1m",
       "created" => created,
       "stats" => [{ "n" => "hub", "c" => 0.5, "m" => 0.2 }] }]
  end
end

# Evaluates the `field = <json>` && filter the program sends, so a row cannot pass on
# a filter it never sent.
def matches_filter?(record, filter)
  return true if filter.nil? || filter.empty?

  filter.split(" && ").all? do |clause|
    field, raw = clause.split(" = ", 2)
    return false if raw.nil?

    record[field.strip] == JSON.parse("[#{raw}]").fetch(0)
  end
end

def hub_responder(state)
  lambda do |method, target, headers, body|
    path, query = target.split("?", 2)
    params = query ? URI.decode_www_form(query).to_h : {}
    authorized = headers.fetch("authorization", "") == ADMIN_TOKEN ||
                 headers.fetch("authorization", "") == APP_TOKEN
    payload = body.to_s.empty? ? {} : (JSON.parse(body) rescue {})

    if method == "POST" && path == "/api/collections/_superusers/auth-with-password"
      next [400, JSON.generate("message" => "failed")] unless
        payload["identity"] == SUPER_EMAIL && payload["password"] == SUPER_PASSWORD

      next [200, JSON.generate("token" => ADMIN_TOKEN)]
    end
    if method == "POST" && path == "/api/collections/users/auth-with-password"
      next [400, JSON.generate("message" => "failed")] unless
        payload["identity"] == APP_EMAIL && payload["password"] == APP_PASSWORD

      next [200, JSON.generate("token" => APP_TOKEN)]
    end
    if method == "POST" && path == "/api/beszel/test-notification"
      next [401, JSON.generate("message" => "unauthorized")] unless authorized
      next [200, state.fetch(:notification_body)] if state.key?(:notification_body)

      failure = deliver_test_notification(payload["url"], state) unless
        state.fetch(:notification_never_delivers, false)
      next [200, JSON.generate("err" => state.fetch(:notification_err, failure || false))]
    end

    # The socket proxy's Docker API ping, served by the same fixture, unauthenticated
    # as the proxy is. run_runtime points PLATFORM_BESZEL_SOCKET_PROXY_PORT here.
    if method == "GET" && path == "/_ping"
      next [state.fetch(:ping_status, 200), state.fetch(:ping_body, "OK")]
    end
    next [401, JSON.generate("message" => "unauthorized")] unless authorized

    if method == "GET" && (collection = path[%r{\A/api/collections/([a-z_]+)/records\z}, 1])
      next [200, state.fetch(:malformed_records)] if state.key?(:malformed_records)
      next [state.fetch(:records_status), JSON.generate("items" => [])] if
        state.key?(:records_status)

      key = collection.to_sym
      if %i[system_stats container_stats].include?(key) && state.key?(:telemetry_status)
        next [state.fetch(:telemetry_status), JSON.generate("items" => [])]
      end

      records = %i[system_stats container_stats].include?(key) ?
        telemetry_records(state, key) : state.fetch(key, [])
      items = records.select { |record| matches_filter?(record, params["filter"]) }
      next [200, JSON.generate("items" => items,
                               "totalItems" => items.length,
                               "totalPages" => state.fetch(:total_pages, 1))]
    end
    if method == "POST" && (collection = path[%r{\A/api/collections/([a-z_]+)/records\z}, 1])
      key = collection.to_sym
      created = payload.merge("id" => "created-#{key}-#{state.fetch(key, []).length}")
      (state[key] ||= []) << created
      next [200, JSON.generate(created)]
    end
    if (match = path.match(%r{\A/api/collections/([a-z_]+)/records/([^/]+)\z}))
      key = match[1].to_sym
      records = state.fetch(key, [])
      entry = records.find { |record| record["id"] == match[2] }
      next [404, JSON.generate("message" => "no such record")] unless entry

      if method == "PATCH"
        entry.merge!(payload)
        next [200, JSON.generate(entry)]
      end
      if method == "DELETE"
        records.delete(entry)
        next [204, nil, nil]
      end
    end
    [500, JSON.generate("message" => "unexpected #{method} #{target}")]
  end
end

def write_stub(directory, name, body)
  path = File.join(directory, name)
  File.write(path, body)
  File.chmod(0o755, path)
  path
end

def with_runtime_sandbox(state)
  Dir.mktmpdir("nas-platform-beszel-runtime.") do |raw|
    sandbox = File.realpath(raw)
    bin = File.join(sandbox, "bin")
    report = File.join(sandbox, "report")
    FileUtils.mkdir_p([bin, report])
    vault = File.join(sandbox, "vault.yml")
    File.write(vault, YAML.dump(state.fetch(:vault, VAULT)), mode: "w", perm: 0o600)
    File.write(File.join(sandbox, "password"), "unused-by-the-stub\n")
    write_stub(bin, "ansible-vault", if state.fetch(:vault_refuses, false)
                                       "#!/bin/sh\nprintf 'refused\\n' >&2\nexit 1\n"
                                     else
                                       "#!/bin/sh\nexec cat #{vault.shellescape}\n"
                                     end)
    yield(sandbox: sandbox, bin: bin, report: report, vault: vault,
          password: File.join(sandbox, "password"))
  end
end

def run_runtime(program, mode, state, paths, extra_env: {})
  environment = {
    "PATH" => "#{paths.fetch(:bin)}:#{ENV.fetch('PATH')}",
    "PLATFORM_CONTRACT_REPO_DIR" => state.fetch(:inspected_root, ROOT),
    "PLATFORM_CONTRACT_VAULT_FILE" => paths.fetch(:vault),
    "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => paths.fetch(:password),
    "PLATFORM_REPORT_ROOT" => paths.fetch(:report),
    "PLATFORM_BESZEL_PORT" => state.fetch(:hub_port).to_s,
    "PLATFORM_KIND" => state.fetch(:platform_kind, "nas"),
    "PLATFORM_BESZEL_SOCKET_PROXY_PORT" => state.fetch(:ping_port, state.fetch(:hub_port)).to_s,
    "PLATFORM_CALLBACK_HOST" => CALLBACK_HOST
  }.merge(extra_env)
  Open3.capture3(environment, RbConfig.ruby, program, mode, in: "/dev/null")
end

RUNTIME_ROWS = [
  { name: "a converged platform in verify mode", mode: "verify", expects: nil },
  { name: "a vault that cannot be decrypted", mode: "verify",
    state: { vault_refuses: true }, expects: "encrypted vault could not be read" },
  { name: "a superuser identity the vault does not hold", mode: "verify",
    state: { vault: VAULT.merge("vault_beszel_superuser_password" => "wrong") },
    expects: "POST /api/collections/_superusers/auth-with-password returned HTTP 400" },
  { name: "an identity read that exceeds one complete page", mode: "verify",
    state: { total_pages: 2 },
    expects: "users filtered identity exceeds one complete page" },
  { name: "an identity read that is not JSON", mode: "verify",
    state: { malformed_records: "not json at all" },
    expects: "returned malformed JSON" },
  { name: "an identity read the hub refuses", mode: "verify",
    state: { records_status: 503 },
    expects: "returned HTTP 503" },
  { name: "no managed application user at all", mode: "verify",
    state: { users: [] }, expects: "managed application user is absent" },
  { name: "two application users with the managed identity", mode: "verify",
    state: { users: [{ "id" => "app-user", "email" => APP_EMAIL, "verified" => true,
                       "role" => "admin" },
                     { "id" => "app-user-2", "email" => APP_EMAIL, "verified" => true,
                       "role" => "admin" }] },
    expects: "duplicate managed application user IDs: app-user,app-user-2" },
  {
    # The top-level ownership refusal, which every mode except
    # remove-duplicate is subject to.
    name: "a same-name system outside the managed user relation", mode: "verify",
    state: { systems: [{ "id" => "managed-system", "name" => SYSTEM_NAME,
                         "users" => ["app-user"] },
                       { "id" => "squatter", "name" => SYSTEM_NAME,
                         "users" => ["someone-else"] }] },
    expects: "same-name wrong-owner system IDs: squatter"
  },
  { name: "an application user that is not a verified admin", mode: "verify",
    state: { users: [{ "id" => "app-user", "email" => APP_EMAIL, "verified" => true,
                       "role" => "user" }] },
    expects: "managed user is not verified admin" },
  { name: "an unverified application user", mode: "verify",
    state: { users: [{ "id" => "app-user", "email" => APP_EMAIL, "verified" => false,
                       "role" => "admin" }] },
    expects: "managed user is not verified admin" },
  { name: "a universal token that is not the vault's", mode: "verify",
    state: { universal_tokens: [{ "id" => "token-record", "user" => "app-user",
                                  "token" => "44444444-4444-4444-a444-444444444444" }] },
    expects: "managed universal token differs from encrypted vault" },
  { name: "no universal token for the managed user", mode: "verify",
    state: { universal_tokens: [] },
    expects: "managed universal token is absent" },
  # The managed relay route with a token the relay does not hold: well formed,
  # and refused with 401 on every alert, which is the silence nobody reads.
  { name: "a relay webhook carrying a token other than the relay's",
    mode: "verify",
    state: { webhooks: [expected_webhook("Bearer%20other-token")] },
    expects: "managed relay webhook differs" },
  # The direct Pushover URL a hand edit or a stale hub would still hold: it
  # delivers, and rings every recovery at priority 1.
  { name: "a webhook still sending to Pushover directly", mode: "verify",
    state: { webhooks: ["pushover://shoutrrr:#{PUSHOVER_TOKEN}@#{PUSHOVER_USER_KEY}/?priority=1"] },
    expects: "managed relay webhook differs" },
  # The header unencoded: Beszel stores it, and shoutrrr would read the query
  # apart at `&` and `=` inside the token.
  { name: "a relay webhook whose header was not URL-encoded", mode: "verify",
    state: { webhooks: [expected_webhook("Bearer relay+tok/en=a&b%c")] },
    expects: "managed relay webhook differs" },
  {
    # PocketBase returns a JSON column as a string on some routes; this is that branch.
    name: "settings served as a JSON string rather than an object", mode: "verify",
    settings_as_string: true, expects: nil
  },
  { name: "a drifted managed alert threshold", mode: "verify",
    alerts: lambda {
      converged_state.fetch(:alerts).map do |alert|
        alert.fetch("name") == "Disk" ? alert.merge("value" => 95) : alert
      end
    },
    expects: "managed Disk alert differs" },
  { name: "a managed alert that is absent", mode: "verify",
    alerts: -> { converged_state.fetch(:alerts).reject { |a| a.fetch("name") == "Memory" } },
    expects: "managed Memory alert is absent" },
  # Defaults declare one alert more than the hub serves; appended so a deleted entry
  # cannot crash this row ahead of the pin's own diagnostic.
  { name: "an alert the inspected defaults added", mode: "verify",
    inspected_defaults: lambda { |document|
      document.fetch("beszel_alerts") << { "name" => "Bandwidth", "value" => 100, "min" => 10 }
    },
    expects: "managed Bandwidth alert is absent" },
  { name: "managed alerts attached to the decoy system", mode: "verify",
    state: { systems: [{ "id" => "managed-system", "name" => SYSTEM_NAME,
                         "users" => ["app-user"] },
                       { "id" => "decoy", "name" => DECOY_NAME, "users" => ["app-user"] }] },
    alerts: lambda {
      converged_state.fetch(:alerts) +
        [{ "id" => "decoy-alert", "user" => "app-user", "system" => "decoy",
           "name" => "CPU", "value" => 90, "min" => 10 }]
    },
    expects: "managed alerts were attached to the decoy system" },
  { name: "a telemetry read the hub will not authorize", mode: "verify",
    state: { telemetry_status: 403 },
    expects: "telemetry request was not authorized" },
  { name: "a telemetry read the hub answers with 404", mode: "verify",
    state: { telemetry_status: 404 },
    expects: "telemetry request returned HTTP 404" },
  {
    # Never-ready telemetry: asserts termination and the sentence, not the budget, which
    # is shortened via env so this row stops being the gate's floor (#485).
    name: "persisted telemetry that never becomes ready", mode: "verify",
    state: { system_stats: [] },
    env: { "PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS" => "6" },
    expects: "persisted telemetry unavailable or stale for system ID managed-system"
  },
  { name: "a converged Mac platform, whose policy requires no GPU sample",
    mode: "verify", state: { platform_kind: "mac" }, expects: nil },
  # Socket proxy loopback ping (#829): answering, nothing listening, and not Docker.
  { name: "a converged integration platform whose socket proxy answers on loopback",
    mode: "verify", state: { platform_kind: "integration" }, expects: nil },
  { name: "an integration platform whose socket proxy port is not published",
    mode: "verify", state: { platform_kind: "integration", ping_port: :refusing },
    expects: "is unreachable from the host: Errno::ECONNREFUSED" },
  { name: "an integration platform whose loopback port is not the Docker API",
    mode: "verify", state: { platform_kind: "integration", ping_status: 404, ping_body: "nope" },
    expects: "did not answer the Docker API ping" },
  # --- drift -------------------------------------------------------------
  { name: "the drift fixture install", mode: "drift", expects: nil,
    after: lambda { |_paths, collected, state|
      user = state.fetch(:users).fetch(0)
      collected << "runtime: drift did not demote the managed user" unless
        user.fetch("role") == "user"
      collected << "runtime: drift did not clear the verified prerequisite" unless
        user.fetch("verified") == true
      collected << "runtime: drift did not replace the universal token" unless
        state.fetch(:universal_tokens).fetch(0).fetch("token") == DRIFT_TOKEN
      settings = state.fetch(:user_settings).fetch(0).fetch("settings")
      collected << "runtime: drift did not install the sentinel webhook" unless
        settings.is_a?(Hash) && settings.fetch("webhooks") == [DRIFT_WEBHOOK]
      cpu = state.fetch(:alerts).find { |alert| alert.fetch("name") == "CPU" }
      collected << "runtime: drift did not lower the CPU alert" unless
        cpu.fetch("value") == 1 && cpu.fetch("min") == 1
      collected << "runtime: drift did not create the decoy system" unless
        state.fetch(:systems).any? { |system| system.fetch("name") == DECOY_NAME }
    } },
  { name: "a repeated drift install over its own decoy", mode: "drift",
    state: { systems: [{ "id" => "managed-system", "name" => SYSTEM_NAME,
                         "users" => ["app-user"] },
                       { "id" => "decoy", "name" => DECOY_NAME, "users" => ["app-user"] }] },
    expects: nil,
    after: lambda { |_paths, collected, state|
      decoys = state.fetch(:systems).count { |system| system.fetch("name") == DECOY_NAME }
      collected << "runtime: drift created a second decoy system" unless decoys == 1
    } },
  { name: "drift against a platform with no managed system", mode: "drift",
    state: { systems: [] }, expects: "managed system is absent" },
  { name: "drift against a platform with two managed settings records", mode: "drift",
    state: { user_settings: [{ "id" => "settings-a", "user" => "app-user" },
                             { "id" => "settings-b", "user" => "app-user" }] },
    expects: "duplicate managed user settings IDs: settings-a,settings-b" },
  # --- drift-verify ------------------------------------------------------
  { name: "drift verified against an installed drift", mode: "drift-verify",
    drift_first: true, expects: nil },
  { name: "drift verified against a converged platform", mode: "drift-verify",
    expects: "managed application user drift changed" },
  { name: "a drift whose universal token was repaired", mode: "drift-verify",
    drift_first: true,
    mutate_after_drift: lambda { |state|
      state.fetch(:universal_tokens).fetch(0)["token"] = UNIVERSAL_TOKEN
    },
    expects: "managed universal token drift changed" },
  { name: "a drift whose webhook was repaired", mode: "drift-verify",
    drift_first: true,
    mutate_after_drift: lambda { |state|
      state.fetch(:user_settings).fetch(0)["settings"] = { "webhooks" => [] }
    },
    expects: "managed webhook drift changed" },
  { name: "a drift whose CPU alert was repaired", mode: "drift-verify",
    drift_first: true,
    mutate_after_drift: lambda { |state|
      state.fetch(:alerts).find { |a| a.fetch("name") == "CPU" }.merge!("value" => 90,
                                                                        "min" => 10)
    },
    expects: "managed CPU alert drift changed" },
  { name: "a drift whose decoy system was removed", mode: "drift-verify",
    drift_first: true,
    mutate_after_drift: lambda { |state|
      state.fetch(:systems).reject! { |system| system.fetch("name") == DECOY_NAME }
    },
    expects: "decoy system drift changed" },
  # --- duplicate / wrong-owner / remove-duplicate ------------------------
  { name: "the duplicate-system fixture install", mode: "duplicate", expects: nil,
    after: lambda { |paths, collected, state|
      artifact = File.join(paths.fetch(:report), "beszel-duplicate-ids.txt")
      unless File.file?(artifact)
        collected << "runtime: duplicate wrote no evidence artifact"
        next
      end
      expected_mode = 0o600 & ~File.umask
      actual = File.stat(artifact).mode & 0o777
      collected << "runtime: duplicate wrote the evidence artifact " \
                   "#{format('%<m>04o', m: actual)}, wanted " \
                   "#{format('%<m>04o', m: expected_mode)}" unless actual == expected_mode
      ids = File.readlines(artifact, chomp: true)
      collected << "runtime: the evidence artifact does not keep the managed ID first" unless
        ids.first == "managed-system" && ids.length == 2
      collected << "runtime: duplicate did not create a same-name system" unless
        state.fetch(:systems).count { |s| s.fetch("name") == SYSTEM_NAME } == 2
    } },
  { name: "the wrong-owner fixture install", mode: "wrong-owner", expects: nil,
    after: lambda { |paths, collected, state|
      artifact = File.join(paths.fetch(:report), "beszel-duplicate-ids.txt")
      collected << "runtime: wrong-owner wrote no evidence artifact" unless File.file?(artifact)
      collected << "runtime: wrong-owner created no fixture user" unless
        state.fetch(:users).any? { |user| user.fetch("email") == WRONG_OWNER_EMAIL }
      squatters = state.fetch(:systems).reject do |system|
        Array(system["users"]).include?("app-user")
      end
      collected << "runtime: wrong-owner created no unowned same-name system" if squatters.empty?
    } },
  { name: "a wrong-owner install repeated over its own fixture user",
    mode: "wrong-owner",
    state: { users: [{ "id" => "app-user", "email" => APP_EMAIL, "verified" => true,
                       "role" => "admin" },
                     { "id" => "wrong-owner", "email" => WRONG_OWNER_EMAIL,
                       "verified" => true, "role" => "user" }] },
    expects: nil,
    after: lambda { |_paths, collected, state|
      count = state.fetch(:users).count { |user| user.fetch("email") == WRONG_OWNER_EMAIL }
      collected << "runtime: wrong-owner created a second fixture user" unless count == 1
    } },
  {
    # remove-duplicate is the one mode exempt from the top-level wrong-owner
    # refusal, which is what lets it clean up after the wrong-owner mode.
    name: "the removal of a wrong-owner fixture", mode: "remove-duplicate",
    wrong_owner_first: true, expects: nil,
    after: lambda { |paths, collected, state|
      collected << "runtime: removal left the evidence artifact behind" if
        File.exist?(File.join(paths.fetch(:report), "beszel-duplicate-ids.txt"))
      collected << "runtime: removal left more than the managed system" unless
        state.fetch(:systems).map { |s| s.fetch("id") } == ["managed-system"]
      collected << "runtime: removal left the wrong-owner fixture user" if
        state.fetch(:users).any? { |user| user.fetch("email") == WRONG_OWNER_EMAIL }
    } },
  { name: "a removal with no evidence artifact to act on", mode: "remove-duplicate",
    expects: nil,
    after: lambda { |_paths, collected, state|
      collected << "runtime: a removal with no evidence deleted a system" unless
        state.fetch(:systems).length == 1
    } },
  # --- notify ------------------------------------------------------------
  # The delivering hub judges the URL; each refusal lands in `err`.
  { name: "the notification proof against a delivering hub", mode: "notify",
    expects: nil },
  { name: "an application identity the vault does not hold", mode: "notify",
    state: { vault: VAULT.merge("vault_beszel_app_user_password" => "wrong") },
    expects: "POST /api/collections/users/auth-with-password returned HTTP 400" },
  { name: "a hub that reports the notification failed", mode: "notify",
    state: { notification_err: true },
    expects: "Beszel test notification reported delivery failure" },
  { name: "a hub whose notification answer is not JSON", mode: "notify",
    state: { notification_body: "not json at all" },
    expects: "returned malformed JSON" },
  {
    # Hub reports success but nothing arrives: asserts termination, with a shortened
    # deadline so this row does not become the gate's floor (#485).
    name: "a notification that never reaches the recorder", mode: "notify",
    state: { notification_never_delivers: true },
    env: { "PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS" => "4" },
    expects: "Beszel test notification did not reach the contract's recorder"
  },
  {
    # Something reached the recorder, but not Beszel's test message: a POST is
    # not proof of this notification. Sits out the same short deadline.
    name: "a delivery that does not carry Beszel's test message", mode: "notify",
    state: { delivered_message: "something else entirely" },
    env: { "PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS" => "4" },
    expects: "Beszel test notification did not reach the contract's recorder"
  },
  {
    # The transport the Dozzle alert relay's /beszel route depends on: a
    # delivery that lost the bearer header would be refused there with 401.
    name: "a delivery without the relay's bearer header", mode: "notify",
    state: { delivered_without_authorization: true },
    env: { "PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS" => "4" },
    expects: "Beszel test notification did not reach the contract's recorder"
  },
  {
    # Not the exact two-key envelope: the relay refuses it with 400.
    name: "a delivery that is not the relay's two-key JSON envelope", mode: "notify",
    state: { delivered_extra_key: true },
    env: { "PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS" => "4" },
    expects: "Beszel test notification did not reach the contract's recorder"
  }
].freeze

def prepare_state(row)
  state = converged_state
  state.merge!(row.fetch(:state, {}))
  state[:alerts] = row.fetch(:alerts).call if row[:alerts]
  state[:row] = row
  state[:ping_port] = refusing_port if state[:ping_port] == :refusing
  state
end

# Fills in what needs the hub's bound port.
def finalize_state(state)
  row = state.fetch(:row)
  webhooks = state.fetch(:webhooks, nil) || [expected_webhook]
  settings = { "webhooks" => webhooks }
  state.fetch(:user_settings).each do |record|
    record["settings"] = row.fetch(:settings_as_string, false) ? JSON.generate(settings) : settings
  end
  state
end

def runtime_failures(program = RUNTIME_PROGRAM, rows = RUNTIME_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    label = "runtime: #{row.fetch(:name)}"
    state = prepare_state(row)
    with_runtime_sandbox(state) do |paths|
      if row[:inspected_defaults]
        state[:inspected_root] = build_fixture_repository(File.join(paths.fetch(:sandbox), "inspected"))
        mutate_yaml(state.fetch(:inspected_root), "roles/beszel/defaults/main.yml", &row[:inspected_defaults])
      end
      with_http_fixture(lambda { |hub_port|
        state[:hub_port] = hub_port
        finalize_state(state)
        if row.fetch(:drift_first, false)
          _out, err, drifted = run_runtime(program, "drift", state, paths)
          collected << "#{label}: the drift this row builds on failed: #{err.strip}" unless
            drifted.success?
          row[:mutate_after_drift]&.call(state)
        end
        if row.fetch(:wrong_owner_first, false)
          _out, err, seeded = run_runtime(program, "wrong-owner", state, paths)
          collected << "#{label}: the wrong-owner install this row builds on failed: " \
                       "#{err.strip}" unless seeded.success?
        end
        # Only the judged run takes the row's env; the pre-runs just install a fixture.
        stdout, stderr, status = run_runtime(program, row.fetch(:mode), state, paths,
                                             extra_env: row.fetch(:env, {}))
        collected.concat(judge(label, row.fetch(:expects), stdout, stderr, status,
                               prefix: DIAGNOSTIC_PREFIX))
        # No credential may reach any output: the program decrypts a vault in memory.
        output = stdout + stderr
        [SUPER_PASSWORD, APP_PASSWORD, UNIVERSAL_TOKEN,
         PUSHOVER_TOKEN, PUSHOVER_USER_KEY, RELAY_TOKEN].each do |secret|
          collected << "#{label}: the diagnostic echoed a credential" if output.include?(secret)
        end
        after = row[:after]
        after&.call(paths, collected, state)
      }, &hub_responder(state))
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Budget layer
# ---------------------------------------------------------------------------
#
# The runtime program's two waits default to deployment values; the deadline rows
# override them, saving ~170s of gate wall time (#485). No other row asserts a budget
# value, so this pins both ends, and `ceiling` catches an override edited back to 90.
BUDGETS = {
  "PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS" => {
    default: "90",
    ceiling: 10,
    applied: "timeout_seconds: TELEMETRY_POLL_TIMEOUT_SECONDS",
    retired: "timeout_seconds: 90"
  },
  "PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS" => {
    default: "15",
    ceiling: 6,
    applied: "MONOTONIC) + NOTIFICATION_POLL_TIMEOUT_SECONDS",
    retired: "MONOTONIC) + 15"
  }
}.freeze

def budget_failures(runtime_source: File.read(RUNTIME_PROGRAM), rows: RUNTIME_ROWS)
  failures = []
  # A floor: both sweeps below pass vacuously on an empty hash.
  failures << "budgets: the budget set has shrunk to #{BUDGETS.length}; a wait was " \
              "dropped from the pin rather than from the program" if BUDGETS.length < 2
  BUDGETS.each do |name, budget|
    failures << "budgets: #{name} is not read with a production default of " \
                "#{budget.fetch(:default)}" unless
      runtime_source.include?(%(ENV.fetch("#{name}", "#{budget.fetch(:default)}")))
    failures << "budgets: the deadline #{name} sets is not spent through it" unless
      runtime_source.include?(budget.fetch(:applied)) &&
      !runtime_source.include?(budget.fetch(:retired))
  end
  overrides = rows.flat_map { |row| row.fetch(:env, {}).keys }
  (BUDGETS.keys - overrides).each do |name|
    failures << "budgets: no row overrides #{name}, so a row spends it in full"
  end
  (overrides - BUDGETS.keys).each do |name|
    failures << "budgets: a row overrides #{name}, which the program never reads"
  end
  rows.each do |row|
    row.fetch(:env, {}).each do |name, value|
      budget = BUDGETS[name]
      next if budget.nil?

      seconds = begin
                  Integer(value, 10)
                rescue ArgumentError, TypeError
                  nil
                end
      if seconds.nil?
        failures << "budgets: a row spends #{value.inspect} of #{name}, which is not a " \
                    "number of seconds"
        next
      end
      failures << "budgets: a row spends #{seconds}s of #{name}, over the " \
                  "#{budget.fetch(:ceiling)}s a row may spend" unless
        seconds <= budget.fetch(:ceiling)
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Wrapper layer
# ---------------------------------------------------------------------------
#
# The wrapper resolves all three programs from its own checkout, so copying the four
# files into a throwaway tests/contracts/ is a whole working contract.

def with_contract_copy(static: File.read(STATIC_PROGRAM),
                       fixtures: File.read(FIXTURES_PROGRAM),
                       runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT), &block)
  programs = { "static" => static, "telemetry-fixtures" => fixtures, "runtime" => runtime }
  with_contract_sandbox("beszel", wrapper, programs, &block)
end

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }, contract, "static"
    )
    failures << "wrapper: static mode failed against its own fixture: " \
                "#{(stdout + stderr).strip}" unless status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?(STATIC_SUCCESS)

    # The tree under inspection is broken, the wrapper's own checkout is not:
    # the row that proves the wrapper still runs the static program at all.
    Dir.mktmpdir("nas-platform-beszel-broken.") do |raw|
      broken = File.realpath(raw)
      build_fixture_repository(broken)
      FileUtils.rm(File.join(broken, "roles/beszel/meta/argument_specs.yml"))
      _out, _err, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => broken }, contract, "static"
      )
      failures << "wrapper: static mode passed against a broken repository" if status.success?
    end

    # Told apart by effect, not exit code: a ${VAR:?} refusal exits 1 under bash but
    # 2 under dash, the same as the guard. The guard is recognised by its silence.
    %w[bogus --help static-x telemetry_fixtures].each do |mode|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }, contract, mode
      )
      output = stdout + stderr
      failures << "wrapper: the mode guard accepted #{mode.inspect}" if status.success?
      failures << "wrapper: #{mode.inspect} produced a diagnostic, so it reached past the " \
                  "mode guard: #{output.strip.inspect}" unless output.strip.empty?
    end
    %w[verify drift drift-verify duplicate wrong-owner remove-duplicate notify].each do |mode|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }, contract, mode
      )
      output = stdout + stderr
      failures << "wrapper: #{mode.inspect} was accepted with no runtime environment" if
        status.success?
      failures << "wrapper: the mode guard refused #{mode.inspect}, which it dispatches: " \
                  "#{output.strip.inspect}" unless
        output.include?("PLATFORM_CONTRACT_VAULT_FILE: parameter")
    end

    # That 2 is the script's own status, so it is safe to assert; silence too.
    [[], %w[mac], %w[mac a b]].each do |extra|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root },
        contract, "telemetry-fixtures", *extra
      )
      failures << "wrapper: telemetry-fixtures accepted #{extra.length} argument(s)" unless
        status.exitstatus == 2
      failures << "wrapper: telemetry-fixtures with #{extra.length} argument(s) reached the " \
                  "program: #{(stdout + stderr).strip.inspect}" unless
        (stdout + stderr).strip.empty?
    end

    # ${VAR:?} wording differs between bash and dash; only the prefix is asserted.
    complete = {
      "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "vault.yml"),
      "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "password"),
      "PLATFORM_REPORT_ROOT" => copy_root
    }
    complete.each_key do |name|
      [nil, ""].each do |value|
        stdout, stderr, status = Open3.capture3(
          { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }.merge(complete).merge(name => value),
          contract, "verify"
        )
        output = stdout + stderr
        failures << "wrapper: verify was accepted with #{name} #{value.inspect}" if
          status.success?
        failures << "wrapper: #{name} #{value.inspect} did not name the unset variable: " \
                    "#{output.strip.inspect}" unless output.include?("#{name}: parameter")
        failures << "wrapper: #{name} #{value.inspect} printed the static success line" if
          stdout.include?(STATIC_SUCCESS)
      end
    end

    # Static exits before the runtime env checks, so the Mac hook runs it with no vault.
    stdout, _err, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
        "PLATFORM_CONTRACT_VAULT_FILE" => nil, "PLATFORM_REPORT_ROOT" => nil },
      contract, "static"
    )
    failures << "wrapper: static mode required the runtime environment" unless
      status.success? && stdout.include?(STATIC_SUCCESS)

    # The only place the wrapper's own fixtures invocation (-r preloads, "$2" "$3", exec
    # ahead of ${VAR:?}) is exercised. Every vault name is unset on purpose.
    fixture_path = File.join(copy_root, "beszel-contract-fixture.json")
    File.write(fixture_path, JSON.generate(telemetry_fixture), mode: "w", perm: 0o600)
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
        "PLATFORM_CONTRACT_VAULT_FILE" => nil,
        "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => nil,
        "PLATFORM_REPORT_ROOT" => nil },
      contract, "telemetry-fixtures", "mac", fixture_path
    )
    failures << "wrapper: telemetry-fixtures failed with no vault environment: " \
                "#{(stdout + stderr).strip}" unless status.success?
    failures << "wrapper: telemetry-fixtures did not report the property it proved" unless
      stdout.include?("Beszel telemetry fixture passed (mac)")
  end

  # The production path: nothing sets PLATFORM_CONTRACT_REPO_DIR there.
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: static mode failed with no repository named: " \
                "#{(stdout + stderr).strip}" unless status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?(STATIC_SUCCESS)

    FileUtils.rm(File.join(copy_root, "roles/beszel/meta/argument_specs.yml"))
    _out, _err, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
  end
  failures
end

# --- the one self-read guard -----------------------------------------------
#
# The static half greps the wrapper for the resolved-root export. The literal occurs
# twice, which is the shape an unscoped substitution mis-plants.
SELF_READ_ROWS = [
  {
    name: "a wrapper that stopped exporting its resolved repository root",
    from: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\nexport PLATFORM_CONTRACT_REPO_DIR\n",
    to: "",
    occurrences: 2,
    expects: "runtime contract does not export its resolved repository root"
  },
  {
    # One pair survives: proves the guard matches assignment immediately followed by export.
    name: "an export separated from the assignment it exports",
    from: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\nexport PLATFORM_CONTRACT_REPO_DIR\n" \
          "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\nexport PLATFORM_CONTRACT_REPO_DIR\n",
    to: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\n: interposed\n" \
        "export PLATFORM_CONTRACT_REPO_DIR\n",
    occurrences: 1,
    expects: "runtime contract does not export its resolved repository root"
  }
].freeze

def self_read_failures(wrapper_source: File.read(CONTRACT),
                       static_source: File.read(STATIC_PROGRAM))
  failures = []
  # A floor: an empty list would report "all 0 guards bite" and pass.
  failures << "self-read: the guard set has shrunk to #{SELF_READ_ROWS.length} row(s); " \
              "a guard was deleted without its property moving somewhere that can fail" if
    SELF_READ_ROWS.length < 2
  in_parallel_cases(failures, SELF_READ_ROWS) do |row, collected|
    occurrences = row.fetch(:occurrences)
    found = wrapper_source.scan(row.fetch(:from)).length
    if found != occurrences
      collected << "self-read: #{row.fetch(:name)}: expected #{occurrences} match(es) of " \
                   "#{row.fetch(:from).inspect} in the wrapper, found #{found}"
      next
    end
    planted = occurrences == 1 ? wrapper_source.sub(row.fetch(:from), row.fetch(:to))
                               : wrapper_source.gsub(row.fetch(:from), row.fetch(:to))
    with_contract_copy(wrapper: planted, static: static_source) do |contract, copy_root|
      # PLATFORM_CONTRACT_REPO_DIR is set here, so the row measures the sentinel alone.
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }, contract, "static"
      )
      collected.concat(judge("self-read: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                             prefix: DIAGNOSTIC_PREFIX))
    end
  end
  failures
end

# --- stdin -----------------------------------------------------------------
#
# No program reads stdin, so the probes report what each saw. Three probes, because
# two invocations are reached through `exec`.

# The self-read grep lives in the program here, so a replacing probe needs nothing.
def stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  [[:static, %w[static], { static: STDIN_PROBE }],
   [:fixtures, %w[telemetry-fixtures mac /nonexistent.json],
    { fixtures: STDIN_PROBE }],
   [:runtime, %w[verify], { runtime: STDIN_PROBE }]].each do |layer, argv, replacement|
    with_contract_copy(wrapper: wrapper_source, **replacement) do |contract, copy_root|
      environment = { "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
                      "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "vault.yml"),
                      "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "password"),
                      "PLATFORM_REPORT_ROOT" => copy_root }
      failures.concat(stdin_probe_failures(contract, argv, environment, prefix: "stdin (#{layer})"))
    end
  end
  failures
end

# --- two roots -------------------------------------------------------------
#
# Program paths resolve from the checkout; beszel-static.rb's require, the fixtures -r
# preload and beszel-runtime.rb's require (past the exec) resolve from the inspected tree.

def two_roots_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    # The tree keeps the wrapper (read unconditionally) and loses the three programs.
    Dir.mktmpdir("nas-platform-beszel-tworoots.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      failures << "two roots: an inspected tree with no sibling programs was refused, so a " \
                  "program is being resolved from it: #{(stdout + stderr).strip}" unless
        status.success?
      failures << "two roots: the contract did not report the property it proved" unless
        stdout.include?(STATIC_SUCCESS)
    end

    # Site 2.
    Dir.mktmpdir("nas-platform-beszel-support.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      File.write(File.join(inspected, "tests", "policy_support.rb"),
                 %(raise "inspected tree policy_support reached"\n))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      failures << "two roots: policy_support was not required out of the inspected tree" if
        status.success?
      failures << "two roots: policy_support was required from somewhere else: " \
                  "#{(stdout + stderr).strip.inspect}" unless
        (stdout + stderr).include?("inspected tree policy_support reached")
    end

    # Site 3: the -r preload path. The only site of its kind in #147 so far.
    Dir.mktmpdir("nas-platform-beszel-preload.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      File.write(File.join(inspected, "tests/contracts/support/beszel_telemetry.rb"),
                 %(raise "inspected tree telemetry preload reached"\n))
      fixture = File.join(inspected, "fixture.json")
      File.write(fixture, JSON.generate(telemetry_fixture))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected },
        contract, "telemetry-fixtures", "mac", fixture
      )
      failures << "two roots: the telemetry preload was not taken from the inspected tree" if
        status.success?
      failures << "two roots: the telemetry preload came from somewhere else: " \
                  "#{(stdout + stderr).strip.inspect}" unless
        (stdout + stderr).include?("inspected tree telemetry preload reached")
    end
  end
  failures
end

# --- runtime program root --------------------------------------------------
#
# The inspected tree is a separate fixture with no sibling programs, so a rerooted
# program path cannot resolve (#310: a shared root once reported the plant ACCEPTED).

def runtime_program_root_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-beszel-runtimeroot.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      File.write(File.join(inspected, "tests/contracts/support/beszel_telemetry.rb"),
                 %(raise "inspected tree runtime require reached"\n))
      with_runtime_sandbox({}) do |paths|
        stdout, stderr, status = Open3.capture3(
          { "PATH" => "#{paths.fetch(:bin)}:#{ENV.fetch('PATH')}",
            "PLATFORM_CONTRACT_REPO_DIR" => inspected,
            "PLATFORM_CONTRACT_VAULT_FILE" => paths.fetch(:vault),
            "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => paths.fetch(:password),
            "PLATFORM_REPORT_ROOT" => paths.fetch(:report) },
          contract, "verify"
        )
        output = stdout + stderr
        failures << "runtime program root: the runtime half was accepted against an " \
                    "inspected tree whose telemetry evaluator raises" if status.success?
        failures << "runtime program root: the runtime half did not require the evaluator " \
                    "out of the inspected tree: #{output.strip.inspect}" unless
          output.include?("inspected tree runtime require reached")
        failures << "runtime program root: the runtime program was resolved from the " \
                    "inspected tree, which holds no sibling programs" if
          output.include?("beszel-runtime.rb (LoadError)") ||
          output.include?("No such file or directory")
      end
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Planted regressions
# ---------------------------------------------------------------------------

# Judged by self_read_failures: the plant is in the program, the break in the wrapper.
SELF_READ_MUTATIONS = [
  { label: "the resolved-root export sentinel",
    from: 'refuse("runtime contract does not export its resolved repository root") unless',
    to: "nil unless",
    rows: SELF_READ_ROWS.map { |row| row.fetch(:name) } }
].freeze

STATIC_MUTATIONS = [
  { label: "the closed-telemetry defaults check",
    from: 'refuse("defaults must not silently infer platform telemetry") unless',
    to: "nil unless",
    rows: ["defaults that infer platform telemetry instead of requiring it",
           "default categories that are no longer closed"] },
  { label: "the freshness window check",
    from: 'refuse("freshness must cover exactly three one-minute samples") unless',
    to: "nil unless",
    rows: ["a freshness window that is not three one-minute samples"] },
  { label: "the polling timeout check",
    from: 'refuse("telemetry polling timeout differs") unless',
    to: "nil unless",
    rows: ["a drifted telemetry polling timeout"] },
  { label: "the explicit-inventory-policy check",
    from: 'refuse("effective categories must use explicit inventory policy") unless',
    to: "nil unless",
    rows: ["effective categories inferred from the GPU input again",
           "effective categories that are not derived at all"] },
  { label: "the derived retry arithmetic refusal",
    from: 'refuse("telemetry polling must not use derived retry arithmetic") if',
    to: "nil if",
    rows: ["derived retry arithmetic reintroduced beside the deadline",
           "retry arithmetic hidden inside another derived value"] },
  { label: "the argument validation loop",
    from: 'refuse("#{name} argument validation is absent") unless options.dig(name, "type") == type',
    to: "nil unless options.dig(name, \"type\") == type",
    rows: ["beszel_required_telemetry_categories declared as str rather than list",
           "beszel_require_gpu_telemetry declared as str rather than bool",
           "beszel_telemetry_freshness_seconds declared as str rather than int",
           "beszel_telemetry_poll_timeout_seconds declared as str rather than int",
           "beszel_telemetry_request_timeout_seconds declared as str rather than int"] },
  { label: "the required task existence loop",
    from: 'refuse("missing #{name}") unless role_task_names.include?(name)',
    to: "nil unless role_task_names.include?(name)",
    rows: ["the require the selected beszel telemetry capability task surviving only under another name",
           "the require exactly one managed beszel system for telemetry task surviving only under another name",
           "the resolve persisted beszel telemetry evidence task surviving only under another name",
           "the verify persisted beszel telemetry categories task surviving only under another name"] },
  { label: "the no_log requirement on the telemetry poll",
    from: 'refuse("persisted telemetry poll must suppress authenticated results") unless',
    to: "nil unless",
    rows: ["a telemetry poll that no longer suppresses authenticated results"] },
  { label: "the one-deadline-aware-probe check",
    from: 'refuse("persisted telemetry poll must use one deadline-aware probe") unless probe_args.is_a?(Hash)',
    to: "nil unless probe_args.is_a?(Hash)",
    rows: ["a telemetry poll that is not one deadline-aware probe"],
    # Cascade: the authentication sentence fires first once the shape check is gone.
    detects: "refused for the wrong reason" },
  { label: "the probe authentication check",
    from: 'refuse("persisted telemetry probe is not authenticated") unless probe_args&.key?("auth_token")',
    to: 'nil unless probe_args&.key?("auth_token")',
    rows: ["a telemetry probe invoked without authentication"] },
  { label: "the total-deadline check",
    from: 'refuse("persisted telemetry probe does not receive the total deadline") unless',
    to: "nil unless",
    rows: ["a telemetry probe that no longer receives the total deadline"] },
  { label: "the probe implementation check",
    from: 'refuse("deadline probe implementation is absent") unless',
    to: "nil unless",
    rows: ["a probe implementation without its polling entry point",
           "a probe support module that no longer fetches container stats"] },
  { label: "the persisted-evidence provenance check",
    from: 'refuse("role treats live health as persisted telemetry") unless',
    to: "nil unless",
    rows: ["a role that treats live health as persisted telemetry",
           "probe evidence that no task consumes"] },
  { label: "the Intel agent image check",
    from: 'refuse("NAS Intel agent image differs") unless',
    to: "nil unless",
    rows: ["a NAS Intel agent from some other publisher"] },
  { label: "the render device check",
    from: 'refuse("NAS Intel render device differs") unless',
    to: "nil unless",
    rows: ["an Intel agent bound to some other render device",
           "an inventory render device path the compose definition cannot use"] },
  { label: "the S.M.A.R.T. slot check",
    from: 'refuse("NAS Intel S.M.A.R.T. device slots differ from inventory") unless',
    to: "nil unless",
    rows: ["an inventory SATA disk with no Compose slot",
           "an NVMe slot mapped read-write"] },
  { label: "the S.M.A.R.T. capability check",
    from: 'refuse("NAS Intel agent lacks the S.M.A.R.T. capabilities") unless',
    to: "nil unless",
    rows: ["an Intel agent without the NVMe passthrough capability"] },
  { label: "the S.M.A.R.T. slot guard check",
    from: 'refuse("role does not pin the S.M.A.R.T. slot count to Compose") unless',
    to: "nil unless",
    rows: ["a role slot guard that no longer counts the NVMe disks"] },
{ label: "the absent S.M.A.R.T. device check",
  from: 'refuse("role does not tolerate an absent S.M.A.R.T. device") unless',
  to: "nil unless",
  rows: ["a device presence stat that is skipped under --check",
         "an absent S.M.A.R.T. device that fails the deploy"] },
{ label: "the S.M.A.R.T. env presence check",
  from: 'refuse("env template renders a S.M.A.R.T. slot without the presence check") unless',
  to: "nil unless",
  rows: ["an env slot that renders the declared path unchecked"] },
  { label: "the agent capacity mount check",
    from: 'refuse("agent capacity mounts differ") unless expected_mounts.all?',
    to: "nil unless expected_mounts.all?",
    rows: ["a portable agent that lost a capacity mount",
           "an Intel agent that lost a capacity mount"] },
  { label: "the read-only socket proxy check",
    from: 'refuse("socket proxy is absent") unless',
    to: "nil unless",
    rows: ["a socket proxy with a writable Docker socket"] },
  { label: "the Mac capability check",
    from: 'refuse("Mac must use portable telemetry without a render device") unless',
    to: "nil unless",
    rows: ["a Mac host declaring the Intel agent", "a Mac host that claims GPU telemetry"] },
  { label: "the NAS GPU policy check",
    from: 'refuse("NAS telemetry policy must explicitly require GPU") unless',
    to: "nil unless",
    rows: ["a NAS host that stopped requiring GPU telemetry",
           "a NAS category list that no longer names gpu"] },
  { label: "the Mac verify hook check",
    from: 'refuse("Mac verification does not execute persisted telemetry proof") unless',
    to: "nil unless",
    rows: ["a Mac verify hook that skips the persisted telemetry proof"] },
  { label: "the Mac drift hook check",
    from: 'refuse("Mac drift hook does not execute category rejection semantics") unless',
    to: "nil unless",
    rows: ["a Mac drift hook that skips category rejection semantics"] },
  { label: "the managed application user guard existence check",
    from: 'refuse("the managed application user guard is absent or ambiguous") unless app_user_guards.length == 1',
    to: "nil unless app_user_guards.length == 1",
    rows: ["a renamed managed application user guard"],
    # Cascade: the empty-diagnostic sentence fires first once this one is gone.
    detects: "refused for the wrong reason" },
  { label: "the guard diagnostic requirement",
    from: 'refuse("the managed application user guard states no diagnostic to anchor on") if guard_diagnostic.empty?',
    to: "nil if guard_diagnostic.empty?",
    # Not a cascade: the anchor check still finds the bare prefix, so the run passes.
    rows: ["a role guard that refuses without saying why"] },
  { label: "the guard censorship check",
    from: 'refuse("the managed application user guard censors the diagnostic the hook reads") if',
    to: "nil if",
    rows: ["a role guard that censors the diagnostic its hook reads"] },
  { label: "the guard verification tag check",
    from: 'refuse("the managed application user guard is not selected by the verification tag") unless',
    to: "nil unless",
    rows: ["a role guard dropped from the verification tag"] },
  { label: "the drift hook refusal anchor check",
    from: %(refuse("Mac drift hook does not anchor on the managed application user guard's own refusal") unless),
    to: "nil unless",
    rows: ["a Mac drift hook with no refusal anchor",
           "a Mac drift hook whose refusal anchor survives only in a comment",
           "a role guard reworded without its hook"] },
  {
    # A bare read of the role index would select none of the imported stages.
    label: "the static import splice",
    from: "role_tasks = flatten_tasks(PolicySupport.static_role_tasks(role_path))",
    to: "role_tasks = flatten_tasks(YAML.safe_load_file(role_path))",
    rows: ["an intact repository"],
    detects: "expected success"
  }
].freeze

FIXTURES_MUTATIONS = [
  { label: "the supported platform guard",
    from: 'abort "Beszel telemetry fixture failed: unknown platform" unless %w[mac nas].include?(platform)',
    to: "nil unless %w[mac nas].include?(platform)",
    rows: ["a platform the contract does not support", "the empty platform"],
    # Cascade: "linux" gets the base three and passes, so the row sees an acceptance.
    detects: "accepted what it must refuse" },
  { label: "the readiness refusal",
    from: 'abort "Beszel telemetry fixture failed: #{evidence.safe_failure}" unless evidence.ready?',
    to: "nil unless evidence.ready?",
    rows: ["a NAS triple with no GPU sample", "a sample older than the freshness window",
           "a sample belonging to another system", "an empty container sample",
           "a healthy system with no persisted records at all"] },
  { label: "the recorded clock requirement",
    from: 'now: Time.parse(fixture.fetch("now")).utc',
    to: 'now: Time.parse(fixture["now"] || "2026-08-12T12:00:00.000Z").utc',
    rows: ["a fixture with no recorded clock"],
    detects: "accepted what it must refuse" }
].freeze

RUNTIME_MUTATIONS = [
  { label: "the vault read status check",
    from: 'fail_contract("encrypted vault could not be read") unless status.success?',
    to: "nil unless status.success?",
    rows: ["a vault that cannot be decrypted"],
    detects: "refused for the wrong reason" },
  { label: "the complete-page requirement",
    from: 'fail_contract("#{collection} filtered identity exceeds one complete page") if response.fetch("totalPages", 0).to_i > 1',
    to: 'nil if response.fetch("totalPages", 0).to_i > 1',
    rows: ["an identity read that exceeds one complete page"],
    detects: "accepted what it must refuse" },
  { label: "the malformed JSON rescue",
    from: 'fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")',
    to: "raise",
    rows: ["an identity read that is not JSON"],
    detects: "refused for the wrong reason" },
  {
    label: "the expected status check in the JSON helper",
    from: "fail_contract(\"\#{method.upcase} \#{uri.path} returned HTTP \#{response.code}\") unless expected.include?(response.code.to_i)\n" \
          "  response.body.to_s.empty?",
    to: "nil unless expected.include?(response.code.to_i)\n  response.body.to_s.empty?",
    rows: ["an identity read the hub refuses",
           "a superuser identity the vault does not hold",
           "an application identity the vault does not hold"],
    detects: "refused for the wrong reason"
  },
  { label: "the exact-record absence check",
    from: 'fail_contract("#{description} is absent") if records.empty?',
    to: "nil if records.empty?",
    rows: ["no managed application user at all", "no universal token for the managed user",
           "drift against a platform with no managed system", "a managed alert that is absent"],
    detects: "refused for the wrong reason" },
  { label: "the exact-record duplicate check",
    from: "  if records.length > 1\n",
    to: "  if false\n",
    rows: ["two application users with the managed identity",
           "drift against a platform with two managed settings records"] },
  { label: "the same-name ownership refusal",
    from: 'unless wrong_owner_systems.empty? || MODE == "remove-duplicate"',
    to: "if false",
    rows: ["a same-name system outside the managed user relation"] },
  { label: "the verified-admin check",
    from: 'fail_contract("managed user is not verified admin") unless',
    to: "nil unless",
    rows: ["an application user that is not a verified admin",
           "an unverified application user"] },
  { label: "the universal token comparison",
    from: 'fail_contract("managed universal token differs from encrypted vault") unless',
    to: "nil unless",
    rows: ["a universal token that is not the vault's"] },
  { label: "the managed webhook comparison",
    from: 'fail_contract("managed relay webhook differs") unless',
    to: "nil unless",
    rows: ["a relay webhook carrying a token other than the relay's",
           "a webhook still sending to Pushover directly",
           "a relay webhook whose header was not URL-encoded"] },
  { label: "the managed alert comparison",
    from: 'fail_contract("managed #{name} alert differs") unless',
    to: "nil unless",
    rows: ["a drifted managed alert threshold"] },
  { label: "the managed alerts' read of the inspected defaults",
    from: %(YAML.safe_load_file(File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "roles/beszel/defaults/main.yml"))\n) +
          %(                     .fetch("beszel_alerts")),
    to: %([{ "name" => "Temperature", "value" => 88, "min" => 15 }]),
    rows: ["an alert the inspected defaults added"] },
  { label: "the decoy alert refusal",
    from: 'fail_contract("managed alerts were attached to the decoy system") unless',
    to: "nil unless",
    rows: ["managed alerts attached to the decoy system"] },
  { label: "the non-retryable telemetry rescue",
    from: "rescue BeszelTelemetry::NonRetryableFetchError => error\n  fail_contract(error.message)",
    to: "rescue BeszelTelemetry::NonRetryableFetchError => error\n  nil",
    rows: ["a telemetry read the hub will not authorize",
           "a telemetry read the hub answers with 404"],
    detects: "accepted what it must refuse" },
  { label: "the persisted telemetry readiness refusal",
    from: "  unless evidence.ready?\n    fail_contract(evidence.safe_failure)\n  end",
    to: "  nil unless evidence.ready?",
    rows: ["persisted telemetry that never becomes ready"],
    detects: "accepted what it must refuse" },
  { label: "the drift role patch",
    from: 'body: { role: "user" })',
    to: "body: {})",
    rows: ["the drift fixture install"],
    detects: "drift did not demote the managed user" },
  { label: "the drift universal token patch",
    from: 'body: { token: "11111111-1111-4111-a111-111111111111" })',
    to: "body: {})",
    rows: ["the drift fixture install"],
    detects: "drift did not replace the universal token" },
  { label: "the drift decoy creation",
    from: "  decoy_systems = records(\"systems\", admin_token, equality(\"name\", DECOY_NAME))\n  unless decoy_systems.any?",
    to: "  decoy_systems = records(\"systems\", admin_token, equality(\"name\", DECOY_NAME))\n  if false",
    rows: ["the drift fixture install"],
    detects: "drift did not create the decoy system" },
  { label: "the drift user readback",
    from: 'fail_contract("managed application user drift changed") unless',
    to: "nil unless",
    rows: ["drift verified against a converged platform"],
    detects: "refused for the wrong reason" },
  { label: "the drift token readback",
    from: 'fail_contract("managed universal token drift changed") unless',
    to: "nil unless",
    rows: ["a drift whose universal token was repaired"] },
  { label: "the drift webhook readback",
    from: 'fail_contract("managed webhook drift changed") unless',
    to: "nil unless",
    rows: ["a drift whose webhook was repaired"] },
  { label: "the drift alert readback",
    from: 'fail_contract("managed CPU alert drift changed") unless',
    to: "nil unless",
    rows: ["a drift whose CPU alert was repaired"] },
  { label: "the drift decoy readback",
    from: 'fail_contract("decoy system drift changed") unless',
    to: "nil unless",
    rows: ["a drift whose decoy system was removed"] },
  { label: "the duplicate evidence write",
    from: "    mode: \"w\",\n    perm: 0o600\n  )\nwhen \"wrong-owner\"",
    to: "    mode: \"w\"\n  )\nwhen \"wrong-owner\"",
    rows: ["the duplicate-system fixture install"],
    detects: "wrote the evidence artifact" },
  { label: "the wrong-owner fixture user reuse",
    from: "  wrong_owner_user = if wrong_owner_users.empty?",
    to: "  wrong_owner_user = if true",
    rows: ["a wrong-owner install repeated over its own fixture user"],
    detects: "created a second fixture user" },
  { label: "the removal's kept identifier",
    from: "    keep_id = ids.first",
    to: "    keep_id = ids.last",
    rows: ["the removal of a wrong-owner fixture"],
    detects: "removal left more than the managed system" },
  { label: "the removal's evidence cleanup",
    from: "    File.unlink(DUPLICATE_EVIDENCE)",
    to: "    nil",
    rows: ["the removal of a wrong-owner fixture"],
    detects: "removal left the evidence artifact behind" },
  { label: "the delivery failure check",
    from: 'fail_contract("Beszel test notification reported delivery failure") unless notification["err"] == false',
    to: 'nil unless notification["err"] == false',
    rows: ["a hub that reports the notification failed"],
    detects: "accepted what it must refuse" },
  { label: "the recorder poll deadline",
    from: %(fail_contract("Beszel test notification did not reach the contract's recorder") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline),
    to: "nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline",
    rows: [],
    # Removing the deadline makes an unbounded poll; the two rows reaching it assert it.
    skip: "removing the deadline makes the row hang rather than fail"
  },
  { label: "the recorder requirement",
    from: %(break if received.any? { |record| record["body"].include?("This is a notification from Beszel.") && relay_envelope?(record) }),
    to: "break",
    rows: ["a notification that never reaches the recorder",
           "a delivery that does not carry Beszel's test message",
           "a delivery without the relay's bearer header",
           "a delivery that is not the relay's two-key JSON envelope"] },
  { label: "the relay transport requirement",
    from: %( && relay_envelope?(record) }),
    to: " }",
    rows: ["a delivery without the relay's bearer header",
           "a delivery that is not the relay's two-key JSON envelope"] },
  { label: "the test message match",
    from: %(record["body"].include?("This is a notification from Beszel.")),
    to: "true",
    rows: ["a delivery that does not carry Beszel's test message"] },
  # Each plant must land on the `err` refusal by name, not just fail.
  { label: "the notification URL the proof sends",
    from: "body: { url: notification_url })",
    to: 'body: { url: "generic://elsewhere.invalid/beszel-contract?disabletls=yes" })',
    rows: ["the notification proof against a delivering hub"],
    detects: "Beszel test notification reported delivery failure" },
  { label: "the plain-http selection",
    from: "/beszel-contract?disabletls=yes&",
    to: "/beszel-contract?",
    rows: ["the notification proof against a delivering hub"],
    detects: "Beszel test notification reported delivery failure" },
  { label: "the callback host in the URL",
    from: 'generic://#{CALLBACK_HOST}:',
    to: "generic://127.0.0.1:",
    rows: ["the notification proof against a delivering hub"],
    detects: "Beszel test notification reported delivery failure" },
  { label: "the recorder port in the URL",
    from: ':#{recorder.addr[1]}/beszel-contract',
    to: ":1/beszel-contract",
    rows: ["the notification proof against a delivering hub"],
    detects: "Beszel test notification reported delivery failure" }
].freeze

# One plant per revert direction. Text plants use from:/to:, row plants use rows:.
# `detects:` is a list because a misspelt name trips both ends of the pin at once.
BUDGET_MUTATIONS = [
  { label: "the telemetry budget's production default",
    from: %(ENV.fetch("PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS", "90")),
    to: %(ENV.fetch("PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS", "6")),
    detects: "PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS is not read with a " \
             "production default of 90" },
  { label: "the notification budget's production default",
    from: %(ENV.fetch("PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS", "15")),
    to: %(ENV.fetch("PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS", "4")),
    detects: "PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS is not read with a " \
             "production default of 15" },
  { label: "the telemetry deadline's read of its budget",
    from: "timeout_seconds: TELEMETRY_POLL_TIMEOUT_SECONDS",
    to: "timeout_seconds: 90",
    detects: "the deadline PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS sets is not " \
             "spent through it" },
  { label: "the notification deadline's read of its budget",
    from: "MONOTONIC) + NOTIFICATION_POLL_TIMEOUT_SECONDS",
    to: "MONOTONIC) + 15",
    detects: "the deadline PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS sets is not " \
             "spent through it" },
  {
    label: "every row's budget override",
    rows: ->(rows) { rows.map { |row| row.reject { |key, _value| key == :env } } },
    detects: ["no row overrides PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS",
              "no row overrides PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS"]
  },
  {
    # Row side only: the override silently does nothing.
    label: "a budget override's name",
    rows: lambda { |rows|
      rows.map do |row|
        next row unless row.key?(:env)

        row.merge(env: row.fetch(:env).transform_keys { |key| "#{key}_MISSPELT" })
      end
    },
    detects: ["no row overrides PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS",
              "a row overrides PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS_MISSPELT, " \
              "which the program never reads"]
  },
  {
    # Only the ceiling catches this one.
    label: "a budget override's short value",
    rows: lambda { |rows|
      rows.map do |row|
        next row unless row.key?(:env)

        row.merge(env: row.fetch(:env).to_h { |name, value|
          [name, BUDGETS.key?(name) ? BUDGETS.fetch(name).fetch(:default) : value]
        })
      end
    },
    detects: ["a row spends 90s of PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS, over the 10s",
              "a row spends 15s of PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS, over the 6s"]
  }
].freeze

WRAPPER_MUTATIONS = [
  { label: "a dropped stdin redirect on the static invocation",
    from: %(  ruby -ryaml "$static_program" "$repo_dir" </dev/null\n),
    to: %(  ruby -ryaml "$static_program" "$repo_dir"\n),
    layer: :stdin },
  { label: "a dropped stdin redirect on the telemetry-fixtures invocation",
    from: %(    "$telemetry_fixtures_program" "$2" "$3" </dev/null\n),
    to: %(    "$telemetry_fixtures_program" "$2" "$3"\n),
    layer: :stdin },
  { label: "a dropped stdin redirect on the runtime invocation",
    from: %(exec ruby "$runtime_program" "$mode" </dev/null\n),
    to: %(exec ruby "$runtime_program" "$mode"\n),
    layer: :stdin },
  {
    # Load-bearing: beszel-static.rb uses YAML before it requires policy_support.rb.
    label: "the static invocation's -ryaml preload",
    from: %(  ruby -ryaml "$static_program" "$repo_dir" </dev/null\n),
    to: %(  ruby "$static_program" "$repo_dir" </dev/null\n),
    layer: :wrapper
  },
  {
    # Declared inert: the second preload already requires json. Kept because nothing
    # guarantees that stays true.
    label: "the telemetry-fixtures -rjson preload",
    from: %(  exec ruby -rjson -r"$repo_dir/tests/contracts/support/beszel_telemetry" \\\n),
    to: %(  exec ruby -r"$repo_dir/tests/contracts/support/beszel_telemetry" \\\n),
    layer: :wrapper,
    skip: "inert -- the support preload already requires json, so dropping it changes no outcome"
  },
  { label: "the static program resolved from the inspected tree",
    from: "static_program=$contract_repo_dir/tests/contracts/beszel-static.rb",
    to: "static_program=$repo_dir/tests/contracts/beszel-static.rb",
    layer: :two_roots },
  { label: "the telemetry-fixtures program resolved from the inspected tree",
    from: "telemetry_fixtures_program=$contract_repo_dir/tests/contracts/beszel-telemetry-fixtures.rb",
    to: "telemetry_fixtures_program=$repo_dir/tests/contracts/beszel-telemetry-fixtures.rb",
    layer: :two_roots },
  { label: "the runtime program resolved from the inspected tree",
    from: "runtime_program=$contract_repo_dir/tests/contracts/beszel-runtime.rb",
    to: "runtime_program=$repo_dir/tests/contracts/beszel-runtime.rb",
    layer: :runtime_program_root },
  { label: "the telemetry preload rerooted to the checkout",
    from: %(  exec ruby -rjson -r"$repo_dir/tests/contracts/support/beszel_telemetry" \\\n),
    to: %(  exec ruby -rjson -r"$contract_repo_dir/tests/contracts/support/beszel_telemetry" \\\n),
    layer: :two_roots },
  {
    # The literal occurs twice; an unscoped sub would leave the winning second pair.
    label: "the inspected-tree export rerooted to the checkout",
    from: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\n",
    to: "PLATFORM_CONTRACT_REPO_DIR=$contract_repo_dir\n",
    occurrences: 2,
    layer: :two_roots
  },
  { label: "the mode guard",
    from: "case $mode in static|telemetry-fixtures|verify|drift|drift-verify|duplicate|wrong-owner|remove-duplicate|notify) ;; *) exit 2 ;; esac",
    to: "case $mode in *) ;; esac",
    layer: :wrapper },
  { label: "the static mode gate",
    from: %(if [ "$mode" = static ]; then\n),
    to: %(if [ "$mode" != static ]; then\n),
    layer: :wrapper },
  { label: "the telemetry-fixtures argument count guard",
    from: %(  [ "$#" -eq 3 ] || exit 2\n),
    to: %(  [ "$#" -ge 1 ] || exit 2\n),
    layer: :wrapper },
  { label: "the vault file requirement",
    from: %(: "${PLATFORM_CONTRACT_VAULT_FILE:?}"),
    to: %(: "${PLATFORM_CONTRACT_VAULT_FILE:=}"),
    layer: :wrapper },
  { label: "the vault password file requirement",
    from: %(: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?}"),
    to: %(: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=}"),
    layer: :wrapper },
  { label: "the report root requirement",
    from: %(: "${PLATFORM_REPORT_ROOT:?}"),
    to: %(: "${PLATFORM_REPORT_ROOT:=}"),
    layer: :wrapper }
].freeze

# report_mutation cannot be used: two budget plants are caught by two sentences.
# Each named sentence must appear; nothing else is held against the plant.
def report_budget_mutation(collected, mutation, caught)
  if caught.empty?
    collected << "removing #{mutation.fetch(:label)} was accepted"
    return
  end

  Array(mutation.fetch(:detects)).each do |sentence|
    collected << "removing #{mutation.fetch(:label)} was caught by the wrong assertion: " \
                 "#{caught.join(' | ')}" unless
      caught.any? { |failure| failure.include?(sentence) }
  end
end

def report_mutation(collected, mutation, caught, rows)
  detects = mutation.fetch(:detects, "accepted what it must refuse")
  if caught.empty?
    collected << "removing #{mutation.fetch(:label)} was accepted by #{rows.length} row(s)"
  elsif !caught.all? { |failure| failure.include?(detects) }
    collected << "removing #{mutation.fetch(:label)} was caught by the wrong assertion: " \
                 "#{caught.join(' | ')}"
  end
end

if ARGV.include?("--self-test")
  mismatches = []
  planted = 0
  skipped = []

  # Plants are prepared on the main thread via the *_or_error forms, so every wrong
  # count is reported at once; an abort in a worker surfaces as a KeyError.
  preparation_errors = []
  prepare = lambda do |mutations, source_path, rows|
    mutations.reject { |mutation| mutation[:skip] }.filter_map do |mutation|
      source, plant_error = plant_or_error(File.read(source_path), mutation)
      selected, rows_error = rows_named_or_error(rows, mutation.fetch(:rows))
      [plant_error, rows_error].compact.each { |error| preparation_errors << error }
      next if plant_error || rows_error

      [mutation, source, selected]
    end
  end
  skipped.concat(
    (STATIC_MUTATIONS + SELF_READ_MUTATIONS + FIXTURES_MUTATIONS + RUNTIME_MUTATIONS +
     BUDGET_MUTATIONS + WRAPPER_MUTATIONS)
      .select { |mutation| mutation[:skip] }
      .map { |mutation| "#{mutation.fetch(:label)}: #{mutation.fetch(:skip)}" }
  )

  static_cases = prepare.call(STATIC_MUTATIONS, STATIC_PROGRAM, STATIC_ROWS)
  self_read_cases = prepare.call(SELF_READ_MUTATIONS, STATIC_PROGRAM, SELF_READ_ROWS)
  fixtures_cases = prepare.call(FIXTURES_MUTATIONS, FIXTURES_PROGRAM, FIXTURES_ROWS)
  runtime_cases = prepare.call(RUNTIME_MUTATIONS, RUNTIME_PROGRAM, RUNTIME_ROWS)
  # Two plant shapes (text `from:`, row `rows:`); both must change something.
  budget_cases = BUDGET_MUTATIONS.reject { |mutation| mutation[:skip] }.filter_map do |mutation|
    if mutation.key?(:from)
      source, error = plant_or_error(File.read(RUNTIME_PROGRAM), mutation)
      preparation_errors << error if error
      next if error

      [mutation, source, RUNTIME_ROWS]
    else
      rows = mutation.fetch(:rows).call(RUNTIME_ROWS)
      if rows == RUNTIME_ROWS
        preparation_errors << "planted nothing for #{mutation.fetch(:label)}"
        next
      end
      [mutation, File.read(RUNTIME_PROGRAM), rows]
    end
  end
  wrapper_cases = WRAPPER_MUTATIONS.reject { |mutation| mutation[:skip] }
                                   .filter_map do |mutation|
    source, error = plant_or_error(File.read(CONTRACT), mutation)
    preparation_errors << error if error
    next if error

    [mutation, source]
  end
  unless preparation_errors.empty?
    preparation_errors.each { |error| warn "FAIL self-test: #{error}" }
    abort "#{preparation_errors.length} self-test plant(s) could not be prepared"
  end

  in_parallel_cases(mismatches, static_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-beszel-mutant.") do |directory|
      path = File.join(directory, "beszel-static.rb")
      File.write(path, source)
      report_mutation(collected, mutation, static_failures(path, rows), rows)
    end
  end
  planted += static_cases.length

  in_parallel_cases(mismatches, self_read_cases) do |(mutation, source, rows), collected|
    report_mutation(collected, mutation, self_read_failures(static_source: source), rows)
  end
  planted += self_read_cases.length

  in_parallel_cases(mismatches, fixtures_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-beszel-mutant.") do |directory|
      path = File.join(directory, "beszel-telemetry-fixtures.rb")
      File.write(path, source)
      report_mutation(collected, mutation, fixtures_failures(path, rows), rows)
    end
  end
  planted += fixtures_cases.length

  in_parallel_cases(mismatches, runtime_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-beszel-mutant.") do |directory|
      path = File.join(directory, "beszel-runtime.rb")
      File.write(path, source)
      report_mutation(collected, mutation, runtime_failures(path, rows), rows)
    end
  end
  planted += runtime_cases.length

  in_parallel_cases(mismatches, budget_cases) do |(mutation, source, rows), collected|
    report_budget_mutation(collected, mutation,
                           budget_failures(runtime_source: source, rows: rows))
  end
  planted += budget_cases.length

  in_parallel_cases(mismatches, wrapper_cases) do |(mutation, source), collected|
    caught = case mutation.fetch(:layer)
             when :stdin then stdin_failures(wrapper_source: source)
             when :two_roots then two_roots_failures(wrapper_source: source)
             when :runtime_program_root
               runtime_program_root_failures(wrapper_source: source)
             else wrapper_failures(wrapper_source: source)
             end
    collected << "removing #{mutation.fetch(:label)} was accepted" if caught.empty?
  end
  planted += wrapper_cases.length

  # The two edits #608's adversarial check made to the real defaults.
  [["moving the Temperature threshold from 88 to 87",
    "    value: 88\n    min: 15\n", "    value: 87\n    min: 15\n"],
   ["deleting the Temperature alert",
    "  - name: Temperature\n    value: 88\n    min: 15\n", ""]].each do |label, from, to|
    Dir.mktmpdir("nas-platform-beszel-alert-pin.") do |raw|
      root = build_fixture_repository(File.realpath(raw))
      mutate_text(root, "roles/beszel/defaults/main.yml", from, to)
      caught = alert_pin_failures(root)
      mismatches << "#{label} in the role defaults was not caught by the alert pin alone: " \
                    "#{caught.inspect}" unless
        caught.length == 1 && caught.first.start_with?("alert pin: Temperature ")
    end
    planted += 1
  end

  skipped.each { |note| warn "SKIP self-test plant: #{note}" }
  unless mismatches.empty?
    mismatches.each { |mismatch| warn "FAIL self-test: #{mismatch}" }
    abort "#{mismatches.length} self-test mismatch(es) of #{planted} planted regressions"
  end

  puts "beszel contract: self-test detects #{planted} planted regressions"
  exit
end

failures = alert_pin_failures + static_failures + missing_file_failures + fixtures_failures + runtime_failures +
           budget_failures + wrapper_failures + self_read_failures + stdin_failures +
           two_roots_failures + runtime_program_root_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Beszel contract violation(s)"
end

puts "beszel contract: #{STATIC_ROWS.length} static, #{FIXTURES_ROWS.length} fixture and " \
     "#{RUNTIME_ROWS.length} runtime properties hold, both self-read guards bite against a " \
     "sentinel that did not move, all #{BUDGETS.length} waiting budgets keep the deployment's " \
     "default while a row overrides each, and the wrapper reaches all three programs from its " \
     "own checkout while all three of its inspected-tree reads stay bound to the tree"
