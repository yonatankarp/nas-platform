#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Dozzle service contract's six Ruby programs and its wrapper,
# tests/contracts/dozzle.sh. Run with --self-test to plant a regression in each.

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "uri"
require "yaml"

require_relative "case_pool_support"
require_relative "policy_support"
require_relative "contract_test_support"

include TestScaffold
include ContractTestSupport

ROOT = File.expand_path("..", __dir__)
# Matching the fragment alone accepted a backtrace or an echoed argument as a refusal.
DIAGNOSTIC_PREFIX = "Dozzle contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "dozzle.sh")
GROUP_RENDER_PROGRAM = File.join(ROOT, "tests", "contracts", "dozzle-group-render.rb")
LABELS_PROGRAM = File.join(ROOT, "tests", "contracts", "dozzle-labels.rb")
STACK_PROGRAM = File.join(ROOT, "tests", "contracts", "dozzle-stack.rb")
ALERTS_PROGRAM = File.join(ROOT, "tests", "contracts", "dozzle-alerts.rb")
PLANNED_OUTPUT_PROGRAM = File.join(ROOT, "tests", "contracts", "dozzle-planned-output.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "dozzle-runtime.rb")

# Transcribed from tests/contracts/dozzle.sh. -rjson/-ryaml are load-bearing: the
# bodies do not require what they use. The labels preload names the inspected tree.
GROUP_RENDER_COMMAND = [RbConfig.ruby, "-rjson"].freeze
STACK_COMMAND = [RbConfig.ruby, "-ryaml"].freeze
ALERTS_COMMAND = [RbConfig.ruby, "-ryaml"].freeze
PLANNED_COMMAND = [RbConfig.ruby].freeze
RUNTIME_COMMAND = [RbConfig.ruby].freeze

# The wrapper's order; held against services/manifest.yml below.
BASE_COMPOSE_FILES = %w[
  services/arr/compose.yml
  services/audiobookshelf/compose.yml
  services/beszel/compose.yml
  services/bindery/compose.yml
  services/downloaders/compose.yml
  services/dozzle/compose.yml
  services/immich/compose.yml
  services/jellyfin/compose.yml
  services/kapowarr/compose.yml
  services/karakeep/compose.yml
  services/komga/compose.yml
  services/nextcloud/compose.yml
  services/paperless-ngx/compose.yml
  services/pinchflat/compose.yml
  services/seerr/compose.yml
  services/trailarr/compose.yml
  services/vaultwarden/compose.yml
].freeze

MANIFEST_SERVICE_NAMES = YAML.safe_load_file(File.join(ROOT, "services", "manifest.yml"))
                             .fetch("services").map { |entry| entry.fetch("name") }.sort.freeze

STACK_ARGUMENT_VARIABLES = {
  "services/dozzle/compose.yml" => "compose",
  "roles/dozzle/tasks/main.yml" => "role",
  "roles/dozzle/templates/env.j2" => "env_template",
  "roles/deployment_bundle/tasks/inputs.yml" => "deployment_inputs",
  "roles/deployment_bundle/tasks/main.yml" => "deployment_bundle",
  "roles/dozzle/defaults/main.yml" => "defaults"
}.freeze

# The sixth argument is the mode, which is not a path.
ALERTS_ARGUMENT_VARIABLES = {
  "roles/dozzle/defaults/main.yml" => "defaults",
  "roles/dozzle/tasks/main.yml" => "role",
  "tests/integration_controller.sh" => "integration",
  "tests/mac/hooks/drift/20-dozzle.sh" => "mac_drift",
  "tests/mac/hooks/verify/20-dozzle.sh" => "mac_verify",
  "tests/mac/hooks/verify/20-dozzle-labels.rb" => "mac_verify_labels",
  "inventory/group_vars/all/service_dozzle.yml" => "service_vars"
}.freeze

# Exactly what the contract reads out of the tree it inspects.
FIXTURE_FILES = (BASE_COMPOSE_FILES + %w[
  services/dozzle/alert_relay.py
  roles/dozzle/tasks/main.yml
  roles/dozzle/defaults/main.yml
  inventory/group_vars/all/service_dozzle.yml
  roles/dozzle/templates/env.j2
  roles/deployment_bundle/tasks/inputs.yml
  roles/deployment_bundle/tasks/main.yml
  tests/integration_controller.sh
  tests/mac/hooks/drift/20-dozzle.sh
  tests/mac/hooks/verify/20-dozzle.sh
  tests/mac/hooks/verify/20-dozzle-labels.rb
  tests/policy_support.rb
]).uniq.freeze

# Deliberately absent: tests/contracts/dozzle.sh and its programs. A copy here would
# hide a program resolved from $repo_dir (#251); the wrapper layer plants impostors.


# Asserts its own match count: a plain sub can hit the wrong copy and plant nothing.
def substitute(text, from, to, count: 1)
  found = text.scan(from).length
  raise "#{from.inspect} matched #{found} times, expected #{count}" unless found == count

  count == 1 ? text.sub(from, to) : text.gsub(from, to)
end

# --- group render layer ----------------------------------------------------

PROBE_PORT = "53081"

def dozzle_render(port = PROBE_PORT)
  {
    "services" => {
      "alert-relay" => {
        "environment" => { "ALERT_RELAY_PORT" => port },
        "ports" => [{ "mode" => "ingress", "host_ip" => "127.0.0.1", "target" => port.to_i,
                      "published" => port, "protocol" => "tcp" }],
        "healthcheck" => {
          "test" => ["CMD-SHELL",
                     "python -c \"import urllib.request as r; " \
                     "r.urlopen('http://127.0.0.1:#{port}/healthz')\""]
        },
        "labels" => { "dev.dozzle.group" => "dozzle", "dev.dozzle.name" => "alert-relay" }
      },
      "dozzle" => {
        "labels" => { "dev.dozzle.group" => "dozzle", "dev.dozzle.name" => "dozzle" }
      },
      "socket-proxy" => {
        "labels" => { "dev.dozzle.group" => "dozzle", "dev.dozzle.name" => "socket-proxy" }
      }
    }
  }
end

def grouped_render(group)
  {
    "services" => {
      "hub" => { "labels" => { "dev.dozzle.group" => group, "dev.dozzle.name" => "hub" } },
      "agent" => { "labels" => { "dev.dozzle.group" => group, "dev.dozzle.name" => "agent" } }
    }
  }
end

def single_render(service)
  { "services" => { service => { "labels" => { "dev.dozzle.name" => service } } } }
end

GROUP_RENDER_ROWS = [
  { name: "an intact Dozzle render", stack: "dozzle", group: "dozzle", variant: "base",
    config: -> { dozzle_render }, expects: nil },
  { name: "an intact grouped render", stack: "beszel", group: "beszel", variant: "mac",
    config: -> { grouped_render("beszel") }, expects: nil },
  { name: "an intact single-container render", stack: "komga", group: "", variant: "integration",
    config: -> { single_render("komga") }, expects: nil },
  {
    # Driven with a port the repository never contains, so a literal copy disagrees.
    name: "a relay environment holding a literal port", stack: "dozzle", group: "dozzle",
    variant: "base",
    config: lambda {
      config = dozzle_render
      config.dig("services", "alert-relay", "environment")["ALERT_RELAY_PORT"] = "8081"
      config
    },
    expects: "dozzle base alert relay does not take its listener port from one variable"
  },
  {
    name: "a relay healthcheck holding a literal port", stack: "dozzle", group: "dozzle",
    variant: "base",
    config: lambda {
      config = dozzle_render
      config["services"]["alert-relay"]["healthcheck"]["test"] =
        ["CMD-SHELL", "urlopen('http://127.0.0.1:8081/healthz')"]
      config
    },
    expects: "dozzle base alert relay does not take its listener port from one variable"
  },
  {
    name: "a relay with no listener port at all", stack: "dozzle", group: "dozzle",
    variant: "base",
    config: lambda {
      config = dozzle_render
      config["services"]["alert-relay"].delete("environment")
      config
    },
    expects: "dozzle base alert relay does not take its listener port from one variable"
  },
  {
    name: "a relay published on the wildcard", stack: "dozzle", group: "dozzle", variant: "base",
    config: lambda {
      config = dozzle_render
      config["services"]["alert-relay"]["ports"][0]["host_ip"] = "0.0.0.0"
      config
    },
    expects: "dozzle base alert relay does not publish its listener port on loopback alone"
  },
  {
    name: "a relay published on a literal port", stack: "dozzle", group: "dozzle", variant: "base",
    config: lambda {
      config = dozzle_render
      config["services"]["alert-relay"]["ports"][0]["published"] = "8081"
      config
    },
    expects: "dozzle base alert relay does not publish its listener port on loopback alone"
  },
  {
    name: "a Mac relay that keeps its publication", stack: "dozzle", group: "dozzle", variant: "mac",
    config: -> { dozzle_render },
    expects: "dozzle mac alert relay does not publish its listener port on loopback alone"
  },
  {
    # The relay guard is Dozzle's alone. A grouped stack whose services happen to
    # include an `alert-relay` must not be judged by it -- and must not raise.
    name: "another stack that happens to carry an alert-relay", stack: "beszel",
    group: "beszel", variant: "base",
    config: lambda {
      config = grouped_render("beszel")
      config["services"]["alert-relay"] =
        { "labels" => { "dev.dozzle.group" => "beszel", "dev.dozzle.name" => "alert-relay" } }
      config
    },
    expects: nil
  },
  {
    name: "a service with no friendly name", stack: "dozzle", group: "dozzle", variant: "base",
    config: lambda {
      config = dozzle_render
      config["services"]["socket-proxy"]["labels"].delete("dev.dozzle.name")
      config
    },
    expects: "dozzle base socket-proxy name label is absent"
  },
  {
    name: "a service with no labels at all", stack: "dozzle", group: "dozzle", variant: "base",
    config: lambda {
      config = dozzle_render
      config["services"]["socket-proxy"].delete("labels")
      config
    },
    expects: "dozzle base socket-proxy name label is absent"
  },
  {
    name: "a friendly name that is not the service name", stack: "dozzle", group: "dozzle",
    variant: "base",
    config: lambda {
      config = dozzle_render
      config["services"]["socket-proxy"]["labels"]["dev.dozzle.name"] = "proxy"
      config
    },
    expects: "dozzle base socket-proxy name label differs"
  },
  {
    name: "a single-container stack that gained a group", stack: "komga", group: "",
    variant: "base",
    config: lambda {
      config = single_render("komga")
      config["services"]["komga"]["labels"]["dev.dozzle.group"] = "komga"
      config
    },
    expects: "komga base komga left Running Containers grouping"
  },
  {
    name: "a single-container stack that gained a container", stack: "komga", group: "",
    variant: "base",
    config: lambda {
      config = single_render("komga")
      config["services"]["sidecar"] = { "labels" => { "dev.dozzle.name" => "sidecar" } }
      config
    },
    expects: "komga base must remain a single-container stack"
  },
  {
    name: "a grouped stack collapsed to one container", stack: "beszel", group: "beszel",
    variant: "base",
    config: lambda {
      config = grouped_render("beszel")
      config["services"].delete("agent")
      config
    },
    expects: "beszel base must remain a multi-container stack"
  },
  {
    name: "a grouped stack with the wrong group", stack: "beszel", group: "beszel",
    variant: "base",
    config: lambda {
      config = grouped_render("beszel")
      config["services"]["agent"]["labels"]["dev.dozzle.group"] = "telemetry"
      config
    },
    expects: "beszel base agent group label differs"
  },
  {
    name: "a grouped stack with one ungrouped container", stack: "beszel", group: "beszel",
    variant: "base",
    config: lambda {
      config = grouped_render("beszel")
      config["services"]["agent"]["labels"].delete("dev.dozzle.group")
      config
    },
    expects: "beszel base agent group label differs"
  }
].freeze

def group_render_failures(program = GROUP_RENDER_PROGRAM, rows = GROUP_RENDER_ROWS)
  in_parallel_case_results(rows) do |row|
    stdout, stderr, status = Open3.capture3(
      { "DOZZLE_RENDERED_COMPOSE" => JSON.generate(row.fetch(:config).call) },
      *GROUP_RENDER_COMMAND, program,
      row.fetch(:stack), row.fetch(:variant), row.fetch(:group), PROBE_PORT
    )
    judge("group render rejects #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
          prefix: DIAGNOSTIC_PREFIX)
  end
end

# --- labels layer ----------------------------------------------------------

LABEL_ROWS = [
  { name: "an intact set of base Compose files", edit: ->(_root) {}, expects: nil },
  {
    name: "a name label spelled twice on one service",
    edit: lambda { |root| edit_text(root, "services/dozzle/compose.yml") { |source|
      substitute(source, "      dev.dozzle.name: dozzle\n",
                 "      dev.dozzle.name: dozzle\n      dev.dozzle.name: dozzle\n")
    } },
    expects: "base Compose has duplicate dev.dozzle.name labels"
  },
  {
    name: "an unrelated duplicated key",
    edit: lambda { |root| edit_text(root, "services/dozzle/compose.yml") { |source|
      substitute(source, "    container_name: dozzle_alert_relay\n",
                 "    container_name: dozzle_alert_relay\n    container_name: dozzle_alert_relay\n")
    } },
    expects: nil
  },
  {
    name: "a base Compose file that no longer parses",
    edit: lambda { |root| edit_text(root, "services/jellyfin/compose.yml") { |source|
      substitute(source, "services:\n", "services:\n  \tbroken: [\n")
    } },
    expects: "base Compose label YAML is invalid"
  },
  {
    name: "a base Compose file that is absent",
    edit: ->(root) { FileUtils.rm(File.join(root, "services/komga/compose.yml")) },
    expects: "base Compose label YAML is invalid"
  }
].freeze

def labels_failures(program = LABELS_PROGRAM, rows = LABEL_ROWS)
  in_parallel_case_results(rows) do |row|
    with_fixture_repository do |root|
      row.fetch(:edit).call(root)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-r#{File.join(root, 'tests/policy_support.rb')}", program,
        *BASE_COMPOSE_FILES.map { |relative| File.join(root, relative) }
      )
      judge("labels rejects #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
            prefix: DIAGNOSTIC_PREFIX)
    end
  end
end

# --- the fixture repository -------------------------------------------------

def with_fixture_repository
  Dir.mktmpdir("nas-platform-dozzle-fixture.") do |raw|
    root = File.realpath(raw)
    FIXTURE_FILES.each do |relative|
      target = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(File.join(ROOT, relative), target)
      File.chmod(relative.end_with?(".sh") ? 0o755 : 0o644, target)
    end
    yield root
  end
end

def edit_text(root, relative)
  path = File.join(root, relative)
  File.write(path, yield(File.read(path)))
end

def edit_yaml_text(root, relative, from, to, count: 1)
  edit_text(root, relative) { |source| substitute(source, from, to, count: count) }
end

# --- stack layer ------------------------------------------------------------

STACK_ROWS = [
  { name: "an intact tree", edit: ->(_root) {}, expects: nil },
  {
    name: "a renamed socket proxy", argument: "services/dozzle/compose.yml",
    edit: ->(root) { edit_yaml_text(root, "services/dozzle/compose.yml", "\n  socket-proxy:\n", "\n  proxy:\n") },
    expects: "stack must define exactly alert-relay, dozzle, and socket-proxy"
  },
  {
    name: "analytics turned back on", argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "      DOZZLE_NO_ANALYTICS: \"true\"\n", "      DOZZLE_NO_ANALYTICS: \"false\"\n")
    },
    expects: "security environment differs"
  },
  {
    name: "the Docker socket mounted into the relay", argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "      - ${DOZZLE_STATE_ROOT:?}/alert-relay:/state\n",
                     "      - ${DOZZLE_STATE_ROOT:?}/alert-relay:/state\n" \
                     "      - /var/run/docker.sock:/var/run/docker.sock:ro\n")
    },
    expects: "Docker socket is mounted outside socket-proxy"
  },
  {
    name: "a writable proxy socket", argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "      - /var/run/docker.sock:/var/run/docker.sock:ro\n",
                     "      - /var/run/docker.sock:/var/run/docker.sock\n")
    },
    expects: "proxy Docker socket must be read-only"
  },
  {
    name: "a proxy that allows POST", argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml", "      POST: \"0\"\n", "      POST: \"1\"\n")
    },
    expects: "proxy permissions differ"
  },
  {
    name: "a relay on a single-architecture image", argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_text(root, "services/dozzle/compose.yml") do |source|
        source.sub(/^    image: docker\.io\/library\/python:.*$/,
                   "    image: docker.io/library/alpine:3.22")
      end
    },
    expects: "alert relay image is not the multi-architecture Python image"
  },
  {
    name: "a relay running as root", argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      # Both services declare the same identity; the anchor keeps this off Dozzle's copy.
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "    user: \"${NAS_UID:?}:${NAS_GID:?}\"\n" \
                     "    command: [python, /app/alert_relay.py]\n",
                     "    user: \"0:0\"\n    command: [python, /app/alert_relay.py]\n")
    },
    expects: "alert relay runtime identity differs"
  },
  {
    name: "a relay handed the publish token under another name",
    argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "      PUSHOVER_TOKEN: ${PUSHOVER_TOKEN:?}\n",
                     "      PUSHOVER_TOKEN: ${PUSHOVER_PUBLISH_TOKEN:?}\n")
    },
    expects: "alert relay environment differs"
  },
  {
    name: "a relay handed no global ceiling",
    argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "      ALERT_DAILY_GLOBAL_CEILING: ${ALERT_DAILY_GLOBAL_CEILING:?}\n", "")
    },
    expects: "alert relay environment differs"
  },
  {
    # A literal endpoint defeats every lane override, keeping lane churn off phones.
    name: "a relay publishing at a literal Pushover endpoint",
    argument: "roles/dozzle/templates/env.j2",
    edit: lambda { |root|
      edit_text(root, "roles/dozzle/templates/env.j2") do |source|
        source.sub("PUSHOVER_API_URL={{ dozzle_pushover_api_url }}",
                   "PUSHOVER_API_URL=https://api.pushover.net/1/messages.json")
      end
    },
    expects: "the relay publish endpoint is not redirectable"
  },
  {
    name: "a ceiling written into the environment file instead of the defaults",
    argument: "roles/dozzle/templates/env.j2",
    edit: lambda { |root|
      edit_text(root, "roles/dozzle/templates/env.j2") do |source|
        source.sub("ALERT_DAILY_CONTAINER_CEILING={{ dozzle_alert_daily_container_ceiling }}",
                   "ALERT_DAILY_CONTAINER_CEILING=10")
      end
    },
    expects: "the alert ceiling is not rendered from the role defaults"
  },
  {
    name: "a relay handed the Pushover user key under another name",
    argument: "roles/dozzle/templates/env.j2",
    edit: lambda { |root|
      edit_text(root, "roles/dozzle/templates/env.j2") do |source|
        source.sub("PUSHOVER_USER_KEY={{ vault_pushover_user_key | replace('$', '$$') }}",
                   "PUSHOVER_USER_KEY={{ vault_pushover_containers_token | replace('$', '$$') }}")
      end
    },
    expects: "the relay secret is not a credential of its own"
  },
  {
    name: "a relay sending with the Alerts application token",
    argument: "roles/dozzle/templates/env.j2",
    edit: lambda { |root|
      edit_text(root, "roles/dozzle/templates/env.j2") do |source|
        source.sub("PUSHOVER_TOKEN={{ vault_pushover_containers_token | replace('$', '$$') }}",
                   "PUSHOVER_TOKEN={{ vault_pushover_alerts_token | replace('$', '$$') }}")
      end
    },
    expects: "the relay secret is not a credential of its own"
  },
  {
    name: "an alert link base written as a literal host",
    argument: "roles/dozzle/templates/env.j2",
    edit: lambda { |root|
      edit_text(root, "roles/dozzle/templates/env.j2") do |source|
        source.sub("ALERT_RELAY_LINK_BASE={{ dozzle_alert_relay_link_base }}",
                   "ALERT_RELAY_LINK_BASE=http://nas.local:8080")
      end
    },
    expects: "the alert link is not built from the public host and Dozzle port"
  },
  {
    name: "a relay handed no alert link base",
    argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "      ALERT_RELAY_LINK_BASE: ${ALERT_RELAY_LINK_BASE:?}\n", "")
    },
    expects: "alert relay environment differs"
  },
  {
    name: "relay state mounted read-only", argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "      - ${DOZZLE_STATE_ROOT:?}/alert-relay:/state\n",
                     "      - ${DOZZLE_STATE_ROOT:?}/alert-relay:/state:ro\n")
    },
    expects: "alert relay mounts differ"
  },
  {
    name: "a relay that publishes on the wildcard", argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "      - \"127.0.0.1:${ALERT_RELAY_PORT:?}:${ALERT_RELAY_PORT:?}\"\n",
                     "      - \"${ALERT_RELAY_PORT:?}:${ALERT_RELAY_PORT:?}\"\n")
    },
    expects: "alert relay must publish only its listener port, on loopback"
  },
  {
    name: "a writable relay root filesystem", argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "      start_period: 5s\n    read_only: true\n    tmpfs:\n      - /tmp\n",
                     "      start_period: 5s\n    read_only: false\n    tmpfs:\n      - /tmp\n")
    },
    expects: "alert relay hardening differs"
  },
  {
    name: "Dozzle started before the relay is healthy", argument: "services/dozzle/compose.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "services/dozzle/compose.yml",
                     "      alert-relay:\n        condition: service_healthy\n",
                     "      alert-relay:\n        condition: service_started\n")
    },
    expects: "Dozzle dependency health gates differ"
  },
  {
    name: "deployment inputs that stop validating the relay",
    argument: "roles/deployment_bundle/tasks/inputs.yml",
    edit: lambda { |root|
      # Not a suffix: the assertion is `include?`, so `alert_relay.pyx` proves nothing.
      edit_yaml_text(root, "roles/deployment_bundle/tasks/inputs.yml",
                     "services/dozzle/alert_relay.py", "services/dozzle/relay_alert.py")
    },
    expects: "deployment inputs do not validate the alert relay"
  },
  {
    name: "a release that stops carrying the relay",
    argument: "roles/deployment_bundle/tasks/main.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/deployment_bundle/tasks/main.yml",
                     "services/dozzle/alert_relay.py", "services/dozzle/relay_alert.py", count: 2)
    },
    expects: "immutable release does not include the alert relay"
  },
  {
    name: "a role that stops revalidating the tracked relay",
    argument: "roles/dozzle/tasks/main.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/dozzle/tasks/main.yml",
                     "      - \"{{ platform_current_dir }}/services/dozzle/alert_relay.py\"\n",
                     "      - \"{{ platform_current_dir }}/services/dozzle/relay_alert.py\"\n")
    },
    expects: "role does not validate the tracked relay script"
  },
  {
    name: "a relay state directory that is not private",
    argument: "roles/dozzle/tasks/main.yml",
    edit: ->(root) { edit_yaml_text(root, "roles/dozzle/tasks/main.yml", "    mode: \"0700\"\n", "    mode: \"0750\"\n") },
    expects: "role does not prepare an isolated private relay state directory"
  },
  {
    name: "a state child preflight that follows symlinks",
    argument: "roles/dozzle/tasks/main.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/dozzle/tasks/main.yml",
                     "- name: Inspect the Dozzle alert relay state child before mutation\n" \
                     "  ansible.builtin.stat:\n" \
                     "    path: \"{{ dozzle_state_root }}/alert-relay\"\n    follow: false\n",
                     "- name: Inspect the Dozzle alert relay state child before mutation\n" \
                     "  ansible.builtin.stat:\n" \
                     "    path: \"{{ dozzle_state_root }}/alert-relay\"\n    follow: true\n")
    },
    expects: "role can mutate an unsafe relay state child"
  },
  {
    name: "a legacy relocation that takes option-shaped paths",
    argument: "roles/dozzle/tasks/main.yml",
    edit: ->(root) { edit_yaml_text(root, "roles/dozzle/tasks/main.yml", "      - mv\n      - --\n", "      - mv\n      - -f\n") },
    expects: "role does not safely relocate the legacy relay state file"
  },
  {
    name: "an environment that stops rendering the state root",
    argument: "roles/dozzle/templates/env.j2",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/dozzle/templates/env.j2",
                     "DOZZLE_STATE_ROOT={{ dozzle_state_root }}\n", "")
    },
    expects: "environment does not render the selected state and script roots"
  },
  {
    name: "an environment that stops rendering the listener port",
    argument: "roles/dozzle/templates/env.j2",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/dozzle/templates/env.j2",
                     "ALERT_RELAY_PORT={{ dozzle_alert_relay_port }}\n", "")
    },
    expects: "environment does not render the single relay listener port"
  }
].freeze

def stack_failures(program = STACK_PROGRAM, rows = STACK_ROWS)
  in_parallel_case_results(rows) do |row|
    with_fixture_repository do |root|
      row.fetch(:edit).call(root)
      stdout, stderr, status = Open3.capture3(
        *STACK_COMMAND, program,
        *STACK_ARGUMENT_VARIABLES.keys.map { |relative| File.join(root, relative) }
      )
      judge("stack rejects #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
            prefix: DIAGNOSTIC_PREFIX)
    end
  end
end

# --- alerts layer -----------------------------------------------------------

ALERTS_ROWS = [
  { name: "an intact tree under static", mode: "static", edit: ->(_root) {}, expects: nil },
  { name: "an intact tree under verify", mode: "verify", edit: ->(_root) {}, expects: nil },
  {
    name: "a cooldown that drifted", mode: "verify",
    argument: "roles/dozzle/defaults/main.yml",
    edit: ->(root) { edit_yaml_text(root, "roles/dozzle/defaults/main.yml", "    cooldown: 300\n", "    cooldown: 301\n", count: 2) },
    expects: "exact alert definitions differ"
  },
  {
    name: "a rule that also matches log lines", mode: "verify",
    argument: "roles/dozzle/defaults/main.yml",
    edit: ->(root) { edit_yaml_text(root, "roles/dozzle/defaults/main.yml", "    logExpression: \"\"\n", "    logExpression: \"true\"\n", count: 4) },
    expects: "alerts must be enabled event-only rules over all containers"
  },
  {
    name: "a listener port that is not a number", mode: "verify",
    argument: "inventory/group_vars/all/service_dozzle.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "inventory/group_vars/all/service_dozzle.yml",
                     "dozzle_alert_relay_port: 8081\n", "dozzle_alert_relay_port: \"8081\"\n")
    },
    expects: "relay listener port is not a single declared TCP port"
  },
  {
    name: "a dispatcher pointed straight at the publisher", mode: "verify",
    argument: "roles/dozzle/defaults/main.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/dozzle/defaults/main.yml",
                     "  url: \"http://alert-relay:{{ dozzle_alert_relay_port }}/alerts\"\n",
                     "  url: https://api.pushover.net/1/messages.json\n")
    },
    expects: "managed dispatcher must target only the private alert relay"
  },
  {
    name: "a dispatcher that stopped carrying its token", mode: "verify",
    argument: "roles/dozzle/defaults/main.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/dozzle/defaults/main.yml",
                     "  headers:\n    Authorization: \"Bearer {{ vault_dozzle_alert_relay_token }}\"\n",
                     "  headers: {}\n")
    },
    expects: "managed dispatcher authorization differs"
  },
  {
    name: "a dispatcher that went back to a presentation envelope", mode: "verify",
    argument: "roles/dozzle/defaults/main.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/dozzle/defaults/main.yml",
                     "    {{ {'version': 1,\n", "    {{ {'title': '{{ .Container.Name }}',\n        'version': 1,\n")
    },
    expects: "managed dispatcher retains a presentation envelope"
  },
  {
    name: "a dispatcher missing the container identity", mode: "verify",
    argument: "roles/dozzle/defaults/main.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/dozzle/defaults/main.yml",
                     "        'containerId': '{{ .Container.ID }}',\n", "")
    },
    expects: "managed dispatcher is missing exact containerId"
  },
  {
    name: "a role that stopped reconciling enabled state", mode: "verify",
    argument: "roles/dozzle/tasks/main.yml",
    edit: ->(root) { edit_yaml_text(root, "roles/dozzle/tasks/main.yml", "    method: PATCH\n", "    method: PUT\n") },
    expects: "role does not reconcile enabled state through PATCH"
  },
  {
    name: "a renamed planned-change report task under static", mode: "static",
    argument: "roles/dozzle/tasks/main.yml",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/dozzle/tasks/main.yml",
                     "- name: Report planned unmanaged Dozzle dispatcher removal\n",
                     "- name: Report planned unmanaged Dozzle dispatcher retirement\n")
    },
    expects: "missing Report planned unmanaged Dozzle dispatcher removal"
  },
  {
    # A live mode must not demand the harness text; the harness is not deployed.
    name: "a renamed planned-change report task under verify", mode: "verify",
    edit: lambda { |root|
      edit_yaml_text(root, "roles/dozzle/tasks/main.yml",
                     "- name: Report planned unmanaged Dozzle dispatcher removal\n",
                     "- name: Report planned unmanaged Dozzle dispatcher retirement\n")
    },
    expects: nil
  },
  {
    name: "an integration lane that stopped printing a scenario marker", mode: "static",
    argument: "tests/integration_controller.sh",
    edit: lambda { |root|
      edit_yaml_text(root, "tests/integration_controller.sh",
                     "DOZZLE_SURPLUS_STATE_REMOVED", "DOZZLE_SURPLUS_STATE_GONE")
    },
    expects: "integration is missing DOZZLE_SURPLUS_STATE_REMOVED"
  },
  {
    name: "the same missing marker under verify", mode: "verify",
    edit: lambda { |root|
      edit_yaml_text(root, "tests/integration_controller.sh",
                     "DOZZLE_SURPLUS_STATE_REMOVED", "DOZZLE_SURPLUS_STATE_GONE")
    },
    expects: nil
  },
  {
    name: "a Mac drift proof that stopped running the check-mode scenario", mode: "static",
    argument: "tests/mac/hooks/drift/20-dozzle.sh",
    edit: lambda { |root|
      edit_yaml_text(root, "tests/mac/hooks/drift/20-dozzle.sh",
                     "check-mixed-unchanged", "check-mixed-untouched")
    },
    expects: "Mac drift proof is missing check-mixed-unchanged"
  },
  {
    name: "a Mac drift proof that stopped corrupting the group label", mode: "static",
    argument: "tests/mac/hooks/drift/20-dozzle.sh",
    edit: lambda { |root|
      edit_yaml_text(root, "tests/mac/hooks/drift/20-dozzle.sh",
                     "dev.dozzle.group", "dev.dozzle.klaster", count: 2)
    },
    expects: "Mac drift proof does not corrupt a managed group label"
  },
  {
    name: "a Mac drift proof that stopped corrupting the friendly name", mode: "static",
    argument: "tests/mac/hooks/drift/20-dozzle.sh",
    edit: lambda { |root|
      edit_yaml_text(root, "tests/mac/hooks/drift/20-dozzle.sh",
                     "dev.dozzle.name: dozzle-contract-drift",
                     "dev.dozzle.name: dozzle-drift-contract")
    },
    expects: "Mac drift proof does not corrupt the managed friendly name"
  },
  {
    name: "a Mac drift proof that stopped installing its sentinel", mode: "static",
    argument: "tests/mac/hooks/drift/20-dozzle.sh",
    edit: lambda { |root|
      edit_yaml_text(root, "tests/mac/hooks/drift/20-dozzle.sh",
                     "dev.dozzle.contract.sentinel", "dev.dozzle.contract.beacon", count: 2)
    },
    expects: "Mac drift proof does not install an unrelated sentinel label"
  },
  {
    name: "Mac verification that stopped reading Docker labels", mode: "static",
    argument: "tests/mac/hooks/verify/20-dozzle.sh",
    edit: lambda { |root|
      edit_yaml_text(root, "tests/mac/hooks/verify/20-dozzle.sh",
                     "docker container inspect", "docker container examine")
    },
    expects: "Mac runtime verification does not inspect Docker labels"
  },
  {
    name: "Mac verification that stopped naming the managed labels", mode: "static",
    argument: "tests/mac/hooks/verify/20-dozzle-labels.rb",
    edit: lambda { |root|
      edit_yaml_text(root, "tests/mac/hooks/verify/20-dozzle-labels.rb",
                     "dev.dozzle.group", "dev.dozzle.cohort", count: 5)
    },
    expects: "Mac runtime verification does not inspect Docker labels"
  }
].freeze

def alerts_failures(program = ALERTS_PROGRAM, rows = ALERTS_ROWS)
  in_parallel_case_results(rows) do |row|
    with_fixture_repository do |root|
      row.fetch(:edit).call(root)
      stdout, stderr, status = Open3.capture3(
        *ALERTS_COMMAND, program,
        *ALERTS_ARGUMENT_VARIABLES.keys.map { |relative| File.join(root, relative) },
        row.fetch(:mode)
      )
      judge("alerts under #{row.fetch(:mode)} rejects #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
            prefix: DIAGNOSTIC_PREFIX)
    end
  end
end

# --- planned output layer ---------------------------------------------------

MARKER_COUNTS = {
  "DOZZLE_PLAN_DISPATCHER_CREATE" => [0, 1],
  "DOZZLE_PLAN_DISPATCHER_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_CREATE" => [1, 4],
  "DOZZLE_PLAN_RULE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_ENABLE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_REMOVE" => [1, 0],
  "DOZZLE_PLAN_DISPATCHER_REMOVE" => [1, 0]
}.freeze

def marker_transcript(index)
  MARKER_COUNTS.flat_map { |marker, counts| [marker] * counts.fetch(index) }.join("\n") + "\n"
end

PLANNED_ROWS = [
  { name: "the exact mixed transcript", mode: "assert-check-mixed-output",
    body: -> { marker_transcript(0) }, expects: nil },
  { name: "the exact missing transcript", mode: "assert-check-missing-output",
    body: -> { marker_transcript(1) }, expects: nil },
  {
    name: "the missing transcript judged as mixed", mode: "assert-check-mixed-output",
    body: -> { marker_transcript(1) },
    expects: "planned-change marker count differs for DOZZLE_PLAN_DISPATCHER_CREATE"
  },
  {
    name: "the mixed transcript judged as missing", mode: "assert-check-missing-output",
    body: -> { marker_transcript(0) },
    expects: "planned-change marker count differs for DOZZLE_PLAN_DISPATCHER_CREATE"
  },
  {
    name: "a repair marker printed twice", mode: "assert-check-mixed-output",
    body: lambda {
      substitute(marker_transcript(0), "DOZZLE_PLAN_RULE_REPAIR\n",
                 "DOZZLE_PLAN_RULE_REPAIR\nDOZZLE_PLAN_RULE_REPAIR\n")
    },
    expects: "planned-change marker count differs for DOZZLE_PLAN_RULE_REPAIR"
  },
  {
    name: "a skipped repair predicate", mode: "assert-check-mixed-output",
    body: -> { substitute(marker_transcript(0), "DOZZLE_PLAN_RULE_REMOVE\n", "") },
    expects: "planned-change marker count differs for DOZZLE_PLAN_RULE_REMOVE"
  },
  {
    name: "a longer token that begins with a marker", mode: "assert-check-mixed-output",
    body: -> { marker_transcript(0) + "DOZZLE_PLAN_RULE_CREATED_ALREADY\n" },
    expects: nil
  },
  { name: "no transcript path at all", mode: "assert-check-mixed-output", body: nil,
    expects: "planned-change output path is absent" },
  { name: "a transcript that is not there", mode: "assert-check-mixed-output", body: :absent,
    expects: "planned-change output is unsafe" },
  { name: "a transcript reached through a symlink", mode: "assert-check-mixed-output",
    body: :symlink, expects: "planned-change output is unsafe" }
].freeze

def planned_failures(program = PLANNED_OUTPUT_PROGRAM, rows = PLANNED_ROWS)
  in_parallel_case_results(rows) do |row|
    Dir.mktmpdir("nas-platform-dozzle-planned.") do |directory|
      argv = [*PLANNED_COMMAND, program, row.fetch(:mode)]
      case row.fetch(:body)
      when nil then nil
      when :absent then argv << File.join(directory, "absent.txt")
      when :symlink
        target = File.join(directory, "target.txt")
        File.write(target, marker_transcript(0))
        link = File.join(directory, "link.txt")
        File.symlink(target, link)
        argv << link
      else
        path = File.join(directory, "ansible-output.txt")
        File.write(path, row.fetch(:body).call, mode: "w", perm: 0o600)
        argv << path
      end
      stdout, stderr, status = Open3.capture3(*argv)
      judge("planned output rejects #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
            prefix: DIAGNOSTIC_PREFIX)
    end
  end
end

# --- runtime layer ----------------------------------------------------------

VAULT_FIXTURE = {
  "vault_dozzle_admin_username" => "dozzle-contract-admin",
  "vault_dozzle_admin_password" => "dozzle-contract-secret",
  "vault_dozzle_alert_relay_token" => "7f3c" * 16,
  "vault_beszel_superuser_email" => "beszel-contract-superuser@example.invalid",
  "vault_beszel_superuser_password" => "beszel-contract-superuser-secret",
  "vault_beszel_app_user_email" => "beszel-contract-app@example.invalid",
  "vault_beszel_app_user_password" => "beszel-contract-app-secret",
  "vault_pushover_alerts_token" => "dozzle-contract-alerts-token",
  "vault_pushover_containers_token" => "dozzle-contract-containers-token",
  "vault_pushover_user_key" => "dozzle-contract-user-key"
}.freeze

BESZEL_STORED_WEBHOOK =
  "generic://alert-relay:8081/beszel?disabletls=yes&template=json&@Authorization=Bearer%20x"

EXPECTED_TEMPLATE = JSON.generate(
  version: 1,
  rule: "{{ .Subscription.Name }}",
  containerId: "{{ .Container.ID }}",
  container: "{{ .Container.Name }}",
  host: "{{ .Container.HostName }}",
  event: "{{ .Event.Name }}",
  healthStatus: '{{ index .Event.Attributes `healthStatus` }}',
  exitCode: '{{ index .Event.Attributes `exitCode` }}',
  timestamp: '{{ .Event.Timestamp.UTC.Format `2006-01-02T15:04:05.999999999Z07:00` }}'
)

DESIRED_ALERTS = {
  "OOM" => ['name == "oom"', 300],
  "Unexpected exit" => ['name == "die" && !(attributes["exitCode"] in ["0", "130", "143"])', 300],
  "Unhealthy" => ['name == "health_status" && attributes["healthStatus"] == "unhealthy"', 0],
  "Recovery" => ['name == "health_status" && attributes["healthStatus"] == "healthy"', 0]
}.freeze

def desired_dispatcher(port = 8081)
  {
    "id" => "disp01", "name" => "alert relay", "type" => "webhook",
    "url" => "http://alert-relay:#{port}/alerts", "template" => EXPECTED_TEMPLATE,
    "headers" => { "Authorization" => "Bearer #{VAULT_FIXTURE.fetch('vault_dozzle_alert_relay_token')}" }
  }
end

def desired_rules(dispatcher_id = "disp01")
  DESIRED_ALERTS.each_with_index.map do |(name, (expression, cooldown)), index|
    {
      "id" => "rule0#{index + 1}", "name" => name, "enabled" => true,
      "containerExpression" => "true", "logExpression" => "",
      "eventExpression" => expression, "cooldown" => cooldown,
      "dispatcher" => { "id" => dispatcher_id }, "triggerCount" => 0
    }
  end
end

class StubApi
  def initialize(state)
    @state = state
    @servers = {}
    @threads = []
  end

  def start
    server = TCPServer.new("127.0.0.1", 0)
    @servers[:dozzle] = server
    @threads << Thread.new { serve(server) }
    server.addr[1]
  end

  def stop
    @servers.each_value { |server| server.close unless server.closed? }
    @threads.each { |thread| thread.kill }
  end

  private

  def serve(server)
    loop do
      socket = begin
        server.accept
      rescue IOError, Errno::EBADF
        break
      end
      begin
        handle(socket)
      rescue StandardError
        nil
      ensure
        socket.close unless socket.closed?
      end
    end
  end

  def handle(socket)
    request_line = socket.gets
    return unless request_line

    method, target, = request_line.split
    headers = {}
    while (line = socket.gets) && line.strip != ""
      name, value = line.split(":", 2)
      headers[name.to_s.downcase.strip] = value.to_s.strip
    end
    length = headers.fetch("content-length", "0").to_i
    body = length.positive? ? socket.read(length) : ""
    status, content_type, payload, extra = route(method, target, headers, body)
    socket.write("HTTP/1.1 #{status} X\r\n")
    Array(extra).each { |header| socket.write("#{header}\r\n") }
    socket.write("Content-Type: #{content_type}\r\n") if content_type
    socket.write("Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n")
    socket.write(payload)
  end

  JSON_TYPE = "application/json"

  def route(method, target, headers, body)
    path = target.split("?", 2).first
    return token_route(body) if method == "POST" && path == "/api/token"
    return beszel_route(method, path, headers) if path.start_with?("/api/collections/", "/api/beszel/")

    unless headers.key?("cookie")
      return [@state.fetch(:unauthenticated_status, 401), JSON_TYPE,
              JSON.generate("error" => "unauthenticated"), nil]
    end

    case [method, path]
    in ["GET", "/api/notifications/dispatchers"]
      [200, JSON_TYPE, JSON.generate(@state.fetch(:dispatchers)), nil]
    in ["GET", "/api/notifications/rules"]
      [200, JSON_TYPE, JSON.generate(@state.fetch(:rules)), nil]
    in ["POST", "/api/notifications/dispatchers"]
      created = JSON.parse(body).merge("id" => "created-disp-#{@state.fetch(:dispatchers).length}")
      @state.fetch(:dispatchers) << created
      [201, JSON_TYPE, JSON.generate(created), nil]
    in ["POST", "/api/notifications/rules"]
      created = JSON.parse(body).merge("id" => "created-rule-#{@state.fetch(:rules).length}")
      @state.fetch(:rules) << created
      [201, JSON_TYPE, JSON.generate(created), nil]
    else
      collection, identifier = path.delete_prefix("/api/notifications/").split("/", 2)
      key = collection == "dispatchers" ? :dispatchers : :rules
      if method == "DELETE"
        @state.fetch(key).reject! { |entry| entry.fetch("id") == identifier }
        return [204, nil, "", nil]
      end
      entry = @state.fetch(key).find { |candidate| candidate.fetch("id") == identifier }
      return [404, JSON_TYPE, JSON.generate("error" => "absent"), nil] unless entry

      entry.merge!(JSON.parse(body)) unless body.empty?
      [200, JSON_TYPE, JSON.generate(entry), nil]
    end
  end

  def beszel_route(method, path, headers)
    authorization = headers.fetch("authorization", "")
    case [method, path]
    in ["POST", "/api/collections/_superusers/auth-with-password"]
      [200, JSON_TYPE, JSON.generate("token" => "beszel-superuser-token"), nil]
    in ["POST", "/api/collections/users/auth-with-password"]
      [200, JSON_TYPE, JSON.generate("token" => "beszel-app-token", "record" => { "id" => "appuser1" }), nil]
    in ["GET", "/api/collections/user_settings/records"]
      return [401, JSON_TYPE, JSON.generate("message" => "unauthorized"), nil] unless
        authorization == "beszel-superuser-token"

      webhooks = @state.fetch(:beszel_webhooks, [BESZEL_STORED_WEBHOOK])
      [200, JSON_TYPE, JSON.generate("items" => [{ "settings" => { "webhooks" => webhooks } }]), nil]
    in ["POST", "/api/beszel/test-notification"]
      return [401, JSON_TYPE, JSON.generate("message" => "unauthorized"), nil] unless
        authorization == "beszel-app-token"
      return [200, JSON_TYPE, JSON.generate("err" => @state.fetch(:beszel_err)), nil] if @state.key?(:beszel_err)

      if @state.fetch(:beszel_delivers, false)
        form = {
          "token" => @state.fetch(:beszel_publish_token, VAULT_FIXTURE.fetch("vault_pushover_alerts_token")),
          "user" => VAULT_FIXTURE.fetch("vault_pushover_user_key"),
          "title" => "Test Alert", "message" => "This is a notification from Beszel.",
          "priority" => "1", "html" => "1"
        }.merge(@state.fetch(:beszel_extra_fields, {}))
        Net::HTTP.post_form(URI("http://127.0.0.1:#{@state.fetch(:recorder_port)}/1/messages.json"), form)
      end
      [200, JSON_TYPE, JSON.generate("err" => false), nil]
    else
      [404, JSON_TYPE, JSON.generate("message" => "absent"), nil]
    end
  end

  def token_route(body)
    fields = body.split("&").to_h { |pair| pair.split("=", 2).map { |value| CGI.unescape(value.to_s) } }
    expected_user = VAULT_FIXTURE.fetch("vault_dozzle_admin_username")
    expected_password = VAULT_FIXTURE.fetch("vault_dozzle_admin_password")
    correct = fields["username"] == expected_user && fields["password"] == expected_password
    return [@state.fetch(:wrong_password_status, 401), JSON_TYPE, JSON.generate("error" => "no"), nil] unless
      correct

    extra = @state.fetch(:set_cookie, true) ? ["Set-Cookie: dozzle-session=abc; Path=/"] : []
    [200, JSON_TYPE, JSON.generate("ok" => true), extra]
  end
end

require "cgi"

VAULT_STUB = <<~STUB
  #!/bin/sh
  # `ansible-vault view --vault-password-file <path> <vault>` and nothing else.
  [ "${DOZZLE_STUB_VAULT_FAILS:-false}" = true ] && {
    printf 'ERROR! Decryption failed\\n' >&2
    exit 1
  }
  cat "$DOZZLE_STUB_VAULT"
STUB

RUNTIME_DOCKER_STUB = <<~STUB
  #!/bin/sh
  case $1 in
    ps) printf 'dozzle\n' ;;
    logs)
      [ "${DOZZLE_STUB_TLS_LOG:-loaded}" = loaded ] &&
        printf '{"message":"Loaded custom dozzle certificate and key"}\n'
      printf '{"message":"Accepting connections on :8080"}\n' ;;
    *) exit 1 ;;
  esac
STUB

def with_runtime_stub(state, relay_port: 8081, recorder: false)
  merged = { dispatchers: [desired_dispatcher(relay_port)], rules: desired_rules }.merge(state)
  # Reserved rather than sampled, and released just above the yield: the binder
  # is the subprocess the block spawns (#736).
  recorder_reservation = ReservedLocalPort.new if recorder
  merged[:recorder_port] = recorder_reservation.number if recorder_reservation
  stub = StubApi.new(merged)
  dozzle_port = stub.start
  Dir.mktmpdir("nas-platform-dozzle-runtime.") do |raw|
    root = File.realpath(raw)
    reports = File.join(root, "reports")
    FileUtils.mkdir_p(reports)
    vault = File.join(root, "vault.yml")
    File.write(vault, YAML.dump(VAULT_FIXTURE.dup))
    defaults = File.join(root, "defaults.yml")
    File.write(defaults, YAML.dump("dozzle_alert_relay_port" => relay_port))
    bin = File.join(root, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "ansible-vault"), VAULT_STUB)
    File.chmod(0o755, File.join(bin, "ansible-vault"))
    File.write(File.join(bin, "docker"), RUNTIME_DOCKER_STUB)
    File.chmod(0o755, File.join(bin, "docker"))
    recorder_reservation&.release_to_binder
    yield({
      "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
      "DOZZLE_STUB_VAULT" => vault,
      "PLATFORM_DOZZLE_PORT" => dozzle_port.to_s,
      # Deliberately a port nothing binds: none of these rows reaches the notify mode.
      "PLATFORM_DOZZLE_PUSHOVER_PORT" => merged.fetch(:recorder_port, 1).to_s,
      "PLATFORM_BESZEL_PORT" => dozzle_port.to_s,
      "PLATFORM_REPORT_ROOT" => reports,
      "PLATFORM_CONTRACT_VAULT_FILE" => vault,
      "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "password"),
      "PLATFORM_CONTRACT_DOZZLE_SERVICE_VARS" => defaults
    }, root, merged)
  end
ensure
  stub&.stop
  recorder_reservation&.release_to_binder
end

RUNTIME_ROWS = [
  { name: "a converged deployment", mode: "verify", state: {}, expects: nil,
    prints: "Dozzle contract passed" },
  { name: "a Dozzle that fell back to the image's public agent pair", mode: "verify",
    state: {}, environment: { "DOZZLE_STUB_TLS_LOG" => "absent" },
    expects: "Dozzle did not load the platform's agent TLS pair" },
  {
    name: "a deployment on a different declared listener port", mode: "verify",
    relay_port: 9091, state: {}, expects: nil, prints: "Dozzle contract passed"
  },
  {
    name: "a listener port the dispatcher no longer agrees with", mode: "verify",
    state: { dispatchers: [desired_dispatcher(8081)] }, relay_port: 9091,
    expects: "managed dispatcher URL differs"
  },
  {
    name: "an API that serves rules without authentication", mode: "verify",
    state: { unauthenticated_status: 200 },
    expects: "GET /api/notifications/rules returned HTTP 200"
  },
  {
    name: "an API that accepts a wrong password", mode: "verify",
    state: { wrong_password_status: 200 },
    expects: "POST /api/token returned HTTP 200"
  },
  {
    name: "a login that returns no session", mode: "verify", state: { set_cookie: false },
    expects: "vault credential did not receive an authentication cookie"
  },
  {
    name: "a second managed dispatcher", mode: "verify",
    state: { dispatchers: [desired_dispatcher, desired_dispatcher.merge("id" => "disp02")] },
    expects: "expected exactly one dispatcher"
  },
  {
    name: "a renamed dispatcher", mode: "verify",
    state: { dispatchers: [desired_dispatcher.merge("name" => "ntfy critical")] },
    expects: "managed dispatcher name differs"
  },
  {
    name: "a dispatcher that is no longer a webhook", mode: "verify",
    state: { dispatchers: [desired_dispatcher.merge("type" => "pushover")] },
    expects: "managed dispatcher type differs"
  },
  {
    name: "a dispatcher whose template lost a field", mode: "verify",
    state: { dispatchers: [desired_dispatcher.merge("template" => JSON.generate(version: 1))] },
    expects: "managed dispatcher template differs"
  },
  {
    name: "a dispatcher carrying somebody else's token", mode: "verify",
    state: {
      dispatchers: [desired_dispatcher.merge(
        "headers" => { "Authorization" => "Bearer tk_someoneelse" }
      )]
    },
    expects: "managed dispatcher headers differ"
  },
  {
    name: "a deleted alert rule", mode: "verify", state: { rules: desired_rules.first(3) },
    expects: "expected exactly four alert rules"
  },
  {
    name: "a disabled alert rule", mode: "verify",
    state: {
      rules: desired_rules.map { |rule| rule.fetch("name") == "OOM" ? rule.merge("enabled" => false) : rule }
    },
    expects: "OOM rule differs"
  },
  {
    name: "a rule wired to another dispatcher", mode: "verify",
    state: {
      rules: desired_rules.map do |rule|
        rule.fetch("name") == "Recovery" ? rule.merge("dispatcher" => { "id" => "disp99" }) : rule
      end
    },
    expects: "Recovery rule differs"
  },
  {
    # duplicate-dispatcher-verify is the earliest mode that reaches safe_id, so the
    # refusal is the filter's and not the artifact's.
    name: "an API identifier that is not safe to echo", mode: "duplicate-dispatcher-verify",
    state: { dispatchers: [desired_dispatcher.merge("id" => "../../etc/passwd")] },
    expects: "API returned an unsafe identifier"
  },
  {
    name: "a drift fixture that is still in place", mode: "drift-verify",
    state: {
      dispatchers: [desired_dispatcher.merge("url" => "https://example.invalid/contract-drift")],
      rules: desired_rules.map do |rule|
        next rule unless rule.fetch("name") == "OOM"

        rule.merge("enabled" => false, "containerExpression" => "false",
                   "eventExpression" => 'name == "start"', "cooldown" => 1)
      end
    },
    expects: nil
  },
  {
    name: "a drift fixture the run reverted", mode: "drift-verify", state: {},
    expects: "dispatcher drift changed"
  },
  {
    name: "a vault that cannot be decrypted", mode: "verify", state: {},
    environment: { "DOZZLE_STUB_VAULT_FAILS" => "true" },
    expects: "encrypted vault could not be read"
  },
  {
    name: "a report root reached through a symlink", mode: "duplicate-dispatcher-create",
    state: {}, report_root: :symlink,
    expects: "contract report root is unavailable"
  },
  # --- beszel-notify ------------------------------------------------------
  # A short delivery budget: a row that reaches the deadline sits out the whole of it.
  {
    name: "a Beszel test notification the relay published with the Alerts token",
    mode: "beszel-notify", recorder: true, state: { beszel_delivers: true },
    expects: nil, prints: "Dozzle contract passed"
  },
  {
    name: "a Beszel test notification that never reaches the recorder",
    mode: "beszel-notify", recorder: true, state: {},
    environment: { "PLATFORM_DOZZLE_BESZEL_NOTIFICATION_TIMEOUT_SECONDS" => "3" },
    expects: "Beszel test notification did not reach the Pushover recorder through the relay"
  },
  {
    name: "a Beszel test notification published with the Containers token",
    mode: "beszel-notify", recorder: true,
    state: { beszel_delivers: true,
             beszel_publish_token: VAULT_FIXTURE.fetch("vault_pushover_containers_token") },
    expects: "relay published Beszel's test notification without the Alerts credentials"
  },
  {
    name: "a hub that reports the relay refused the test notification",
    mode: "beszel-notify", recorder: true,
    state: { beszel_err: "server returned unexpected response status code: 401" },
    environment: { "PLATFORM_DOZZLE_BESZEL_NOTIFICATION_TIMEOUT_SECONDS" => "3" },
    expects: "Beszel test notification through the relay reported delivery failure"
  },
  {
    name: "a hub whose stored webhook is not the relay's /beszel route",
    mode: "beszel-notify", recorder: true,
    state: { beszel_webhooks: ["pushover://shoutrrr:token@user/?priority=1"] },
    environment: { "PLATFORM_DOZZLE_BESZEL_NOTIFICATION_TIMEOUT_SECONDS" => "3" },
    expects: "Beszel's stored webhook is not the alert relay's /beszel route"
  },
  {
    name: "a Beszel test notification that arrived with a button",
    mode: "beszel-notify", recorder: true,
    state: { beszel_delivers: true,
             beszel_extra_fields: { "url" => "http://beszel.invalid", "url_title" => "Open in Beszel" } },
    expects: "Beszel test notification presentation differs"
  }
].freeze

def runtime_failures(program = RUNTIME_PROGRAM, rows = RUNTIME_ROWS)
  in_parallel_case_results(rows) do |row|
    with_runtime_stub(row.fetch(:state), relay_port: row.fetch(:relay_port, 8081),
                      recorder: row.fetch(:recorder, false)) do |env, root, _state|
      if row[:report_root] == :symlink
        link = File.join(root, "reports-link")
        File.symlink(File.join(root, "reports"), link)
        env = env.merge("PLATFORM_REPORT_ROOT" => link)
      end
      env = env.merge(row.fetch(:environment, {}))
      stdout, stderr, status = Open3.capture3(env, *RUNTIME_COMMAND, program, row.fetch(:mode))
      label = "runtime under #{row.fetch(:mode)} rejects #{row.fetch(:name)}"
      failures = judge(label, row.fetch(:expects), stdout, stderr, status, prefix: DIAGNOSTIC_PREFIX)
      if (prints = row[:prints]) && failures.empty? && !stdout.include?(prints)
        failures << "#{label}: reached success without printing #{prints.inspect}"
      end
      failures
    end
  end
end

# The fixture modes are sequences: one mode records identifiers in 0600 artifacts
# under PLATFORM_REPORT_ROOT and later modes read them back.
def runtime_sequence_failures(program = RUNTIME_PROGRAM)
  failures = []
  with_runtime_stub({}) do |env, _root, state|
    stdout, stderr, status = Open3.capture3(
      env, *RUNTIME_COMMAND, program, "duplicate-dispatcher-create"
    )
    unless status.success?
      failures << "runtime sequence: duplicate-dispatcher-create failed: #{(stdout + stderr).strip}"
      next
    end
    reports = env.fetch("PLATFORM_REPORT_ROOT")
    created = File.join(reports, "dozzle-duplicate-dispatcher-created-id.txt")
    matching = File.join(reports, "dozzle-duplicate-dispatcher-matching-ids.txt")
    [created, matching].each do |path|
      failures << "runtime sequence: #{File.basename(path)} was not written" unless File.file?(path)
      next unless File.file?(path)

      # Derived from the umask; a literal would assert this machine's umask.
      expected = 0o600 & ~File.umask
      actual = File.stat(path).mode & 0o777
      failures << "runtime sequence: #{File.basename(path)} is mode " \
                  "#{format('%04o', actual)}, wanted #{format('%04o', expected)}" unless
        actual == expected
    end
    failures << "runtime sequence: the duplicate was not created" unless
      state.fetch(:dispatchers).length == 2

    _out, _err, status = Open3.capture3(env, *RUNTIME_COMMAND, program, "duplicate-dispatcher-verify")
    failures << "runtime sequence: duplicate-dispatcher-verify rejected the fixture it created" unless
      status.success?

    ids = File.readlines(matching, chomp: true).sort
    transcript = File.join(reports, "play.txt")
    File.write(transcript,
               "Managed Dozzle dispatcher identity is duplicated at safe IDs: #{ids.join(', ')}\n")
    _out, _err, status = Open3.capture3(
      env, *RUNTIME_COMMAND, program, "duplicate-dispatcher-assert-output", transcript
    )
    failures << "runtime sequence: the safe-ID diagnostic was not accepted" unless status.success?

    File.write(transcript, "Managed Dozzle dispatcher identity is duplicated at safe IDs: disp99\n")
    stdout, stderr, status = Open3.capture3(
      env, *RUNTIME_COMMAND, program, "duplicate-dispatcher-assert-output", transcript
    )
    output = stdout + stderr
    if status.success?
      failures << "runtime sequence: a diagnostic naming the wrong identifiers was accepted"
    elsif !output.include?("expected-failure output omitted the safe-ID diagnostic")
      failures << "runtime sequence: the wrong-identifier diagnostic differs: #{output.strip.inspect}"
    end

    _out, _err, status = Open3.capture3(env, *RUNTIME_COMMAND, program, "duplicate-dispatcher-cleanup")
    failures << "runtime sequence: duplicate-dispatcher-cleanup failed" unless status.success?
    failures << "runtime sequence: cleanup did not restore exactly the managed original" unless
      state.fetch(:dispatchers).length == 1
    [created, matching].each do |path|
      failures << "runtime sequence: #{File.basename(path)} survived cleanup" if File.exist?(path)
    end
  end
  failures
end

# --- wrapper layer ----------------------------------------------------------

DOCKER_STUB = <<~STUB
  #!/bin/sh
  # Answers `docker compose --project-name dozzle-contract-<stack>-<variant> ... config`
  # with the canned render for that stack, and nothing else. The wrapper renders
  # fifty-one times in a static run; none of them needs a daemon here.
  project=
  for argument in "$@"; do
    case $argument in
      dozzle-contract-*) project=${argument#dozzle-contract-} ;;
    esac
  done
  stack=${project%-*}
  if [ -f "$DOZZLE_STUB_RENDERS/$project.json" ]; then
    cat "$DOZZLE_STUB_RENDERS/$project.json"
  elif [ -f "$DOZZLE_STUB_RENDERS/$stack.json" ]; then
    cat "$DOZZLE_STUB_RENDERS/$stack.json"
  else
    cat "$DOZZLE_STUB_RENDERS/single.json"
  fi
STUB

WRAPPER_PROGRAM_SOURCES = {
  "dozzle-group-render.rb" => -> { File.read(GROUP_RENDER_PROGRAM) },
  "dozzle-labels.rb" => -> { File.read(LABELS_PROGRAM) },
  "dozzle-stack.rb" => -> { File.read(STACK_PROGRAM) },
  "dozzle-alerts.rb" => -> { File.read(ALERTS_PROGRAM) },
  "dozzle-planned-output.rb" => -> { File.read(PLANNED_OUTPUT_PROGRAM) },
  "dozzle-runtime.rb" => -> { File.read(RUNTIME_PROGRAM) }
}.freeze

# The set is held against MANIFEST_SERVICE_NAMES; the group is stated, since deriving
# it from the Compose file judged would agree with anything. "" means no group.
RENDERED_STACKS = {
  "arr" => "arr", "beszel" => "beszel", "downloaders" => "downloaders",
  "dozzle" => "dozzle", "paperless-ngx" => "paperless",
  "immich" => "immich", "nextcloud" => "nextcloud", "karakeep" => "karakeep",
  "audiobookshelf" => "", "bindery" => "", "jellyfin" => "", "kapowarr" => "",
  "komga" => "", "pinchflat" => "", "seerr" => "",
  "trailarr" => "", "vaultwarden" => ""
}.freeze

def with_contract_copy(programs: {}, wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-dozzle-wrapper.") do |raw|
    root = File.realpath(raw)
    FIXTURE_FILES.each do |relative|
      target = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(File.join(ROOT, relative), target)
      File.chmod(relative.end_with?(".sh") ? 0o755 : 0o644, target)
    end
    contracts = File.join(root, "checkout", "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    contract = File.join(contracts, "dozzle.sh")
    File.write(contract, wrapper)
    File.chmod(0o755, contract)
    WRAPPER_PROGRAM_SOURCES.each do |name, default|
      File.write(File.join(contracts, name), programs.fetch(name, default).call)
      File.chmod(0o644, File.join(contracts, name))
    end
    renders = File.join(root, "renders")
    FileUtils.mkdir_p(renders)
    File.write(File.join(renders, "dozzle.json"), JSON.generate(dozzle_render))
    # The Mac override resets the relay's loopback publication.
    mac = dozzle_render
    mac.dig("services", "alert-relay").delete("ports")
    File.write(File.join(renders, "dozzle-mac.json"), JSON.generate(mac))
    RENDERED_STACKS.each do |stack, group|
      next if stack == "dozzle"

      body = group.empty? ? single_render(stack) : grouped_render(group)
      File.write(File.join(renders, "#{stack}.json"), JSON.generate(body))
    end
    File.write(File.join(renders, "single.json"), JSON.generate(single_render("solo")))
    stub_dir = File.join(root, "stub-bin")
    FileUtils.mkdir_p(stub_dir)
    File.write(File.join(stub_dir, "docker"), DOCKER_STUB)
    File.chmod(0o755, File.join(stub_dir, "docker"))
    yield contract, root, {
      "PATH" => "#{stub_dir}:#{ENV.fetch('PATH')}",
      "DOZZLE_STUB_RENDERS" => renders
    }
  end
end

# The recorder port has three homes and they must be one number: a mismatch is a
# relay POSTing at nothing, alerts silently lost. Read from the real tree.
PUSHOVER_PORT_SOURCES = {
  "tests/contracts/dozzle.sh" => /PLATFORM_DOZZLE_PUSHOVER_PORT:=([0-9]+)\}/,
  "tests/integration_controller_lib.sh" =>
    %r{integration_dozzle_pushover_api_url='http://\{\{ platform_callback_host \}\}:([0-9]+)/1/messages\.json'},
  "tests/mac/lib.sh" =>
    %r{-e 'dozzle_pushover_api_url=http://\{\{ platform_callback_host \}\}:([0-9]+)/1/messages\.json'}
}.freeze

def pushover_port_failures
  failures = []
  found = PUSHOVER_PORT_SOURCES.to_h do |relative, pattern|
    path = File.join(ROOT, relative)
    [relative, File.file?(path) ? File.read(path)[pattern, 1] : nil]
  end
  found.each do |relative, port|
    failures << "#{relative} declares no Pushover recorder port: the relay would be " \
                "converged against an endpoint nothing in the lane listens on" if port.nil?
  end
  return failures unless failures.empty?

  unless found.values.uniq.length == 1
    failures << "the Pushover recorder port disagrees across #{found.inspect}: the lane " \
                "renders it into the relay's environment at converge time, so a mismatch " \
                "loses every alert to a 502 rather than failing an assertion"
  end
  failures
end

# --- the notify mode's recorder, executed against the real relay -----------
#
# The helpers are read out of the shipped program and eval'd, never copied: a copy
# would test a second implementation (urlencode vs decode_www_form boundary).
RECORDER_SECTION_START = "# --- the Pushover stand-in ---"
RECORDER_SECTION_END = "\nrequest(\"get\", endpoint(DOZZLE,"
RELAY_SCRIPT = File.join(ROOT, "services", "dozzle", "alert_relay.py")

# Just enough for the extracted section to load: fail_contract and CALLBACK_HOST.
RECORDER_PRELUDE = <<~RUBY
  def fail_contract(message)
    raise "Dozzle contract failed: \#{message}"
  end
  CALLBACK_HOST = "127.0.0.1"
RUBY

def recorder_module(port)
  source = File.read(RUNTIME_PROGRAM)
  start = source.index(RECORDER_SECTION_START)
  finish = source.index(RECORDER_SECTION_END)
  raise "recorder section markers not found in #{RUNTIME_PROGRAM}" if start.nil? || finish.nil?

  section = source[start...finish]
  raise "recorder section does not define with_pushover_recorder" unless
    section.include?("def with_pushover_recorder")

  holder = Module.new
  ENV["PLATFORM_DOZZLE_PUSHOVER_PORT"] = port.to_s
  holder.module_eval("#{RECORDER_PRELUDE}\n#{section}", RUNTIME_PROGRAM, 1)
  holder.module_eval { module_function(*holder.instance_methods(false)) }
  holder
end

# A loopback port held by a listening socket until the binder is ready to take it.
# Sampling-then-closing lost the port to a pooled check (#736); release_to_binder
# runs immediately before the bind. Wildcard, because the recorder binds 0.0.0.0.
class ReservedLocalPort
  attr_reader :number

  def initialize
    @holder = TCPServer.new("0.0.0.0", 0)
    @number = @holder.addr[1]
  end

  # Call immediately before the bind. Idempotent, so it doubles as cleanup.
  def release_to_binder
    @holder.close unless @holder.closed?
    @number
  end

  def held?
    !@holder.closed?
  end
end

# A second process that binds +port+ and keeps it. Returns [bound, pid].
PORT_THIEF_PROGRAM = <<~'RUBY'
  require "socket"
  begin
    server = TCPServer.new("0.0.0.0", Integer(ARGV[0], 10))
  rescue SystemCallError => error
    $stdout.puts("refused #{error.class}")
    $stdout.flush
    exit 0
  end
  $stdout.puts("bound #{server.addr[1]}")
  $stdout.flush
  sleep
RUBY

def steal_port(port)
  reader, writer = IO.pipe
  pid = spawn(RbConfig.ruby, "-e", PORT_THIEF_PROGRAM, port.to_s,
              out: writer, err: File::NULL)
  writer.close
  verdict = reader.gets.to_s
  [verdict.start_with?("bound"), pid]
ensure
  reader&.close unless reader&.closed?
  writer&.close unless writer&.closed?
end

def reap_thief(pid)
  return if pid.nil?

  begin
    Process.kill("TERM", pid)
  rescue Errno::ESRCH
    nil
  end
  Process.wait(pid)
rescue Errno::ECHILD
  nil
end

# Proves ReservedLocalPort reserves, against a real second process. A held port being
# refused is certain (the detection); a released port being taken is a race (the
# retried control, which catches a steal_port that stopped binding anything).
PORT_CONTROL_ATTEMPTS = 5

def port_reservation_failures
  failures = []
  thief = nil

  reservation = ReservedLocalPort.new
  begin
    stolen, thief = steal_port(reservation.number)
    failures << "port reservation: a second process bound #{reservation.number} while the " \
                "reservation was held, so ReservedLocalPort is not reserving anything" if
      stolen
  ensure
    reap_thief(thief)
    thief = nil
  end

  failures << "port reservation: the reservation released its port before anyone asked " \
              "for it" unless reservation.held?

  bound = false
  attempts = 0
  while attempts < PORT_CONTROL_ATTEMPTS && !bound
    attempts += 1
    released = ReservedLocalPort.new.release_to_binder
    begin
      bound, thief = steal_port(released)
    ensure
      reap_thief(thief)
      thief = nil
    end
  end
  failures << "port reservation: no second process could bind a released port in " \
              "#{attempts} attempts, so either release_to_binder does not release or the " \
              "direction above is passing on a probe that binds nothing" unless bound

  failures
end

def post_through_relay(relay_port, payload, token)
  uri = URI("http://127.0.0.1:#{relay_port}/alerts")
  request = Net::HTTP::Post.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(payload)
  Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) do |http|
    http.request(request)
  end
end

def recorder_failures
  failures = []
  # Both ports held until the statement before each bind. See ReservedLocalPort.
  recorder_reservation = ReservedLocalPort.new
  relay_reservation = ReservedLocalPort.new
  recorder_port = recorder_reservation.number
  relay_port = relay_reservation.number
  helpers = recorder_module(recorder_port)
  relay_token = "recorder-case-relay-token"
  pushover_token = "recorder-case-pushover-token"
  pushover_user_key = "recorder-case-pushover-user-key"

  Dir.mktmpdir("nas-platform-dozzle-recorder.") do |raw|
    state_directory = File.join(File.realpath(raw), "state")
    FileUtils.mkdir_p(state_directory)
    File.chmod(0o700, state_directory)
    environment = {
      "ALERT_RELAY_TOKEN" => relay_token,
      "ALERT_RELAY_PORT" => relay_port.to_s,
      "PUSHOVER_API_URL" => "http://127.0.0.1:#{recorder_port}/1/messages.json",
      "ALERT_RELAY_LINK_BASE" => "http://127.0.0.1:38080",
      "PUSHOVER_TOKEN" => pushover_token,
      "PUSHOVER_USER_KEY" => pushover_user_key,
      "ALERT_DAILY_CONTAINER_CEILING" => "10",
      "ALERT_DAILY_OOM_CONTAINER_CEILING" => "25",
      "ALERT_DAILY_GLOBAL_CEILING" => "200",
      "PUSHOVER_ALERTS_TOKEN" => "test-pushover-alerts-token",
      "BESZEL_LINK_BASE" => "http://127.0.0.1:8090",
      "ALERT_STATE_PATH" => File.join(state_directory, "alert-relay.json"),
      "PYTHONDONTWRITEBYTECODE" => "1"
    }
    relay_reservation.release_to_binder
    relay = spawn(environment, "python3", RELAY_SCRIPT,
                  out: File::NULL, err: File::NULL)
    begin
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      listening = false
      until listening || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        begin
          TCPSocket.new("127.0.0.1", relay_port).close
          listening = true
        rescue SystemCallError
          sleep 0.05
        end
      end
      return ["recorder: the relay never began listening"] unless listening

      captured = nil
      begin
      recorder_reservation.release_to_binder
      helpers.with_pushover_recorder(pushover_token, pushover_user_key) do |reader|
        # A space becomes `+` under quote_plus and the message carries newlines.
        response = post_through_relay(relay_port, {
          "version" => 1, "rule" => "Unhealthy",
          "containerId" => "a" * 64, "container" => "svc one & two",
          "host" => "nas host", "event" => "health_status",
          "healthStatus" => "unhealthy", "exitCode" => "",
          "timestamp" => "2026-08-15T01:22:13Z"
        }, relay_token)
        failures << "recorder: the relay refused the envelope with HTTP #{response.code}" unless
          response.code.to_i == 204
        captured, = helpers.wait_for_pushover(
          reader, "nothing reached the recorder", timeout: 10
        ) { |messages| messages.first }
      end
      rescue RuntimeError => error
        failures << "recorder: #{error.message}"
      end
      return failures if captured.nil?

      # The direction a hardcoded `true` cannot satisfy (measured: it stayed green).
      mismatched = helpers.redact_credentials(
        { "form" => { "token" => "wrong", "user" => "wrong", "title" => "x" } },
        pushover_token, pushover_user_key
      )
      failures << "recorder: a request carrying the wrong credentials was reported as " \
                  "carrying the managed pair" if mismatched["credentials_ok"]

      form = captured.fetch("form")
      failures << "recorder: the relay did not POST the messages endpoint, got " \
                  "#{captured['path'].inspect}" unless captured["path"] == "/1/messages.json"
      failures << "recorder: the request was not a form POST, got " \
                  "#{captured['content_type'].inspect}" unless
        captured["content_type"].to_s.start_with?("application/x-www-form-urlencoded")
      failures << "recorder: a credential arrived in an Authorization header" unless
        captured["authorization"].nil?
      failures << "recorder: the managed Pushover credentials were not recognised" unless
        captured["credentials_ok"]
      failures << "recorder: the credentials survived capture as #{form.keys.sort.inspect}" unless
        (form.keys & %w[token user]).empty?
      failures << "recorder: the decoded title differs: #{form['title'].inspect}" unless
        form["title"] == "\u{1F7E0} svc one & two unhealthy"
      failures << "recorder: the decoded message differs: #{form['message'].inspect}" unless
        form["message"] == "<b>svc one &amp; two</b> is <font color=\"#f9a825\">unhealthy</font>\n\n" \
                           "\u{1F5A5}\u{FE0F} <b>Host</b> nas host\n" \
                           "\u{1F4E6} <b>Container</b> " \
                           "<a href=\"http://127.0.0.1:38080/container/#{'a' * 64}\">svc one &amp; two</a>\n" \
                           "\u{1F552} <b>When</b> 15 Aug 01:22 UTC\n\n" \
                           "<i>Open it in Dozzle to see why.</i>"
      failures << "recorder: the decoded priority differs: #{form['priority'].inspect}" unless
        form["priority"] == "1"
      failures << "recorder: the decoded html flag differs: #{form['html'].inspect}" unless
        form["html"] == "1"
    ensure
      Process.kill("TERM", relay)
      Process.wait(relay)
    end
  end
  failures
ensure
  # Cleanup: a held socket outliving this method would starve the pool.
  recorder_reservation&.release_to_binder
  relay_reservation&.release_to_binder
end

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []

  # Paths bind to the inspected tree; programs come from the checkout (#251, #291).
  (STACK_ARGUMENT_VARIABLES.merge(ALERTS_ARGUMENT_VARIABLES)).each do |relative, variable|
    failures << "wrapper: does not bind #{variable} to #{relative} in the inspected tree" unless
      wrapper_source.include?("#{variable}=$repo_dir/#{relative}")
  end
  WRAPPER_PROGRAM_SOURCES.each_key do |name|
    failures << "wrapper: does not resolve #{name} from its own checkout" unless
      wrapper_source.include?("=$contract_repo_dir/tests/contracts/#{name}\n")
  end
  # The `-r` preload is the one path that must stay on the inspected tree.
  failures << "wrapper: the labels preload must name the inspected tree" unless
    wrapper_source.include?(%(ruby -r"$repo_dir/tests/policy_support.rb" "$labels_program"))
  # Closed against services/manifest.yml both ways: a rendered subset cannot fail
  # for a stack it never renders (#656).
  missing = MANIFEST_SERVICE_NAMES - RENDERED_STACKS.keys
  surplus = RENDERED_STACKS.keys - MANIFEST_SERVICE_NAMES
  failures << "wrapper: services/manifest.yml declares #{missing.inspect}, which the " \
              "wrapper renders for no group at all" unless missing.empty?
  failures << "wrapper: renders #{surplus.inspect}, which services/manifest.yml does " \
              "not declare" unless surplus.empty?
  expected_labelled = MANIFEST_SERVICE_NAMES.map { |name| "services/#{name}/compose.yml" }
  failures << "wrapper: hands the labels program #{BASE_COMPOSE_FILES.sort.inspect}, not " \
              "the manifest's own #{expected_labelled.inspect}" unless
    BASE_COMPOSE_FILES.sort == expected_labelled
  RENDERED_STACKS.each do |stack, group|
    expected = group.empty? ? %(render_group_variants #{stack} "") : "render_group_variants #{stack} #{group}"
    failures << "wrapper: does not render #{stack} expecting group #{group.inspect}" unless
      wrapper_source.include?(expected)
  end
  BASE_COMPOSE_FILES.each do |relative|
    failures << "wrapper: does not hand #{relative} to the labels program" unless
      wrapper_source.include?(%("$repo_dir/#{relative}"))
  end
  stack_invocation = wrapper_source[/^ruby -ryaml "\$stack_program".*?\n\n/m].to_s
  passed = stack_invocation.scan(/\$\{?(\w+)/).flatten - ["stack_program"]
  failures << "wrapper: the stack invocation passes #{passed.inspect}, not " \
              "#{STACK_ARGUMENT_VARIABLES.values.inspect}" unless
    passed == STACK_ARGUMENT_VARIABLES.values
  alerts_invocation = wrapper_source[/^ruby -ryaml "\$alerts_program".*?\n\n/m].to_s
  passed = alerts_invocation.scan(/\$\{?(\w+)/).flatten - ["alerts_program"]
  failures << "wrapper: the alerts invocation passes #{passed.inspect}, not " \
              "#{(ALERTS_ARGUMENT_VARIABLES.values + ['mode']).inspect}" unless
    passed == ALERTS_ARGUMENT_VARIABLES.values + ["mode"]

  with_contract_copy(wrapper: wrapper_source) do |contract, root, stub_env|
    environment = stub_env.merge("PLATFORM_CONTRACT_REPO_DIR" => root)
    stdout, stderr, status = Open3.capture3(environment, contract, "static")
    unless status.success? && stdout.include?("Dozzle static contract passed")
      failures << "wrapper: static mode failed against the fixture tree: #{(stdout + stderr).strip}"
    end

    # The mode guard prints nothing; recognised by that silence, since a bare
    # ${VAR:?} refusal also exits 2 under dash.
    %w[bogus --help static-x drift_verify beszel_notify].each do |mode|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root }, contract, mode
      )
      output = stdout + stderr
      failures << "wrapper: the mode guard accepted #{mode.inspect}" if status.success?
      failures << "wrapper: the mode guard refused #{mode.inspect} with exit " \
                  "#{status.exitstatus}, wanted 2" unless status.exitstatus == 2
      failures << "wrapper: the mode guard let #{mode.inspect} reach past it: " \
                  "#{output.strip.inspect}" unless output.strip.empty?
    end

    broken = File.join(root, "roles/dozzle/templates/env.j2")
    original = File.read(broken)
    File.write(broken, substitute(original, "ALERT_RELAY_PORT={{ dozzle_alert_relay_port }}\n", ""))
    stdout, stderr, status = Open3.capture3(environment, contract, "static")
    output = stdout + stderr
    if status.success?
      failures << "wrapper: static mode accepted a broken inspected tree"
    elsif !output.include?("Dozzle contract failed: environment does not render the single relay listener port")
      failures << "wrapper: static mode did not report the broken inspected tree: #{output.strip.inspect}"
    end
    File.write(broken, original)

    # The fixture carries no tests/contracts, so only an impostor there separates
    # the two roots.
    impostors = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(impostors)
    WRAPPER_PROGRAM_SOURCES.each_key do |name|
      File.write(File.join(impostors, name), %(warn "impostor #{name} ran"\nexit 0\n))
    end
    File.write(File.join(impostors, "dozzle.sh"), "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, File.join(impostors, "dozzle.sh"))
    stdout, stderr, status = Open3.capture3(environment, contract, "static")
    output = stdout + stderr
    failures << "wrapper: a program planted in the inspected tree ran: #{output.strip.inspect}" if
      output.include?("impostor")
    failures << "wrapper: static mode failed with an impostor beside the inspected tree: " \
                "#{output.strip.inspect}" unless status.success?
    FileUtils.rm_rf(impostors)

    support = File.join(root, "tests/policy_support.rb")
    support_source = File.read(support)
    FileUtils.rm_f(support)
    stdout, stderr, status = Open3.capture3(environment, contract, "static")
    output = stdout + stderr
    if status.success?
      failures << "wrapper: the labels program did not read policy_support from the inspected tree"
    elsif !output.include?("policy_support")
      failures << "wrapper: a missing policy_support in the inspected tree was not named: " \
                  "#{output.strip.inspect}"
    end
    File.write(support, support_source)

    transcript = File.join(root, "ansible-output.txt")
    File.write(transcript, marker_transcript(0))
    stdout, stderr, status = Open3.capture3(
      environment, contract, "assert-check-mixed-output", transcript
    )
    unless status.success? && stdout.include?("Dozzle planned-change output contract passed")
      failures << "wrapper: assert-check-mixed-output did not reach the planned-output program: " \
                  "#{(stdout + stderr).strip}"
    end

    # The refusal wording is the shell's, so only the prefix is asserted. Empty
    # rather than removed: `:?` refuses null too, and an exported var would mask it.
    guards = %w[
      PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE PLATFORM_REPORT_ROOT
    ]
    guards.each do |name|
      guarded = environment.merge(
        guards.to_h { |key| [key, key == name ? "" : File.join(root, "present")] }
      )
      stdout, stderr, status = Open3.capture3(guarded, contract, "verify")
      output = stdout + stderr
      failures << "wrapper: #{name} null was accepted" if status.success?
      failures << "wrapper: #{name} null was refused without naming it: #{output.strip.inspect}" unless
        output.include?("#{name}: parameter")
      ["encrypted vault could not be read", "Dozzle contract passed"].each do |sentence|
        failures << "wrapper: the runtime program started with #{name} null" if
          output.include?(sentence)
      end
    end
  end

  failures
end

# --- stdin ------------------------------------------------------------------
#
# None of the six reads stdin today, so dropping `</dev/null` changes no outcome.
# Each row swaps in a probe that does read.

PROBE = <<~'PROBE'
  payload = $stdin.read
  abort "Dozzle contract failed: %<half>s program was handed #{payload.bytesize} B on stdin" unless
    payload.empty?
PROBE

def probe_program(half, tail)
  format(PROBE, half: half) + tail
end

def stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  probes = WRAPPER_PROGRAM_SOURCES.to_h do |name, default|
    half = name.delete_prefix("dozzle-").delete_suffix(".rb")
    tail = if %w[dozzle-planned-output.rb dozzle-runtime.rb].include?(name)
             %(puts "#{half} probe reached with an empty stdin"\nexit 0\n) + default.call
           else
             default.call
           end
    [name, -> { probe_program(half, tail) }]
  end
  with_contract_copy(programs: probes, wrapper: wrapper_source) do |contract, root, stub_env|
    environment = stub_env.merge("PLATFORM_CONTRACT_REPO_DIR" => root)
    stdout, stderr, status, survived = run_with_caller_stdin(environment, contract, %w[static])
    failures << "stdin: a program was handed the caller's input: #{(stdout + stderr).strip.inspect}" unless
      status.success?
    failures << "stdin: the caller's input did not survive the contract: #{(stdout + stderr).strip.inspect}" unless
      survived

    transcript = File.join(root, "ansible-output.txt")
    File.write(transcript, marker_transcript(0))
    stdout, stderr, status, survived = run_with_caller_stdin(environment, contract,
                                                             ["assert-check-mixed-output", transcript])
    unless status.success? && stdout.include?("planned-output probe reached with an empty stdin")
      failures << "stdin: the planned-output program was handed the caller's input: " \
                  "#{(stdout + stderr).strip.inspect}"
    end
    failures << "stdin: the caller's input did not survive the contract: #{(stdout + stderr).strip.inspect}" unless
      survived

    runtime_environment = environment.merge(
      "PLATFORM_CONTRACT_VAULT_FILE" => File.join(root, "absent-vault.yml"),
      "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "absent-password"),
      "PLATFORM_REPORT_ROOT" => root
    )
    stdout, stderr, status, survived = run_with_caller_stdin(runtime_environment, contract, %w[verify])
    unless status.success? && stdout.include?("runtime probe reached with an empty stdin")
      failures << "stdin: the runtime program was handed the caller's input: " \
                  "#{(stdout + stderr).strip.inspect}"
    end
    failures << "stdin: the caller's input did not survive the contract: #{(stdout + stderr).strip.inspect}" unless
      survived
  end
  failures
end

# --- planted regressions ----------------------------------------------------
#
# Each entry removes one guard from one program and names the rows that must catch it.

PROGRAM_MUTATIONS = [
  {
    label: "the single-listener-port probe",
    program: :group_render,
    from: "  abort \"Dozzle contract failed: #{'#'}{stack} #{'#'}{variant} alert relay does not take " \
          "its listener port from one variable\" unless\n",
    to: "  abort \"unreachable\" unless true ||\n",
    rows: ["a relay environment holding a literal port",
           "a relay healthcheck holding a literal port",
           "a relay with no listener port at all"]
  },
  {
    label: "the friendly-name absence check",
    program: :group_render,
    from: "  abort \"Dozzle contract failed: #{'#'}{stack} #{'#'}{variant} #{'#'}{service} name label " \
          "is absent\" if matches.empty?\n",
    to: "",
    rows: ["a service with no friendly name", "a service with no labels at all"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the friendly-name equality check",
    program: :group_render,
    from: "    matches == {\"dev.dozzle.name\" => service}\n",
    to: "    true\n",
    rows: ["a friendly name that is not the service name"]
  },
  {
    label: "the single-container grouping check",
    program: :group_render,
    from: "      definition.fetch(\"labels\", {}).key?(\"dev.dozzle.group\")\n",
    to: "      false\n",
    rows: ["a single-container stack that gained a group"]
  },
  {
    label: "the single-container cardinality check",
    program: :group_render,
    from: "    services.length == 1\n",
    to: "    true\n",
    rows: ["a single-container stack that gained a container"]
  },
  {
    label: "the multi-container cardinality check",
    program: :group_render,
    from: "    services.length > 1\n",
    to: "    true\n",
    rows: ["a grouped stack collapsed to one container"]
  },
  {
    label: "the group equality check",
    program: :group_render,
    from: "      matches == {\"dev.dozzle.group\" => expected_group}\n",
    to: "      true\n",
    rows: ["a grouped stack with the wrong group",
           "a grouped stack with one ungrouped container"]
  },
  {
    label: "the duplicate-label scan",
    program: :labels,
    from: "      PolicySupport.duplicate_yaml_keys(document).include?(\"dev.dozzle.name\")\n",
    to: "      false\n",
    rows: ["a name label spelled twice on one service"]
  },
  {
    label: "the YAML validity rescue",
    program: :labels,
    from: "rescue Psych::Exception, SystemCallError\n",
    to: "rescue Psych::BadAlias\n",
    rows: ["a base Compose file that no longer parses", "a base Compose file that is absent"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the service-set equality",
    program: :stack,
    from: "  services.keys.sort == %w[alert-relay dozzle socket-proxy]\n",
    to: "  true\n",
    rows: ["a renamed socket proxy"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the security environment equality",
    program: :stack,
    from: "  dozzle.fetch(\"environment\") == expected_environment\n",
    to: "  true\n",
    rows: ["analytics turned back on"]
  },
  {
    label: "the Docker socket containment check",
    program: :stack,
    from: "  [dozzle, relay].any? do |service|\n",
    to: "  [].any? do |service|\n",
    rows: ["the Docker socket mounted into the relay"],
    # A cascade: the relay's mount list is compared exactly below. The check still
    # catches a socket mounted into the Dozzle service.
    detects: "refused for the wrong reason"
  },
  {
    label: "the read-only proxy socket check",
    program: :stack,
    from: "  proxy.fetch(\"volumes\") == [\"/var/run/docker.sock:/var/run/docker.sock:ro\"]\n",
    to: "  true\n",
    rows: ["a writable proxy socket"]
  },
  {
    label: "the proxy permission slice",
    program: :stack,
    from: "  proxy.fetch(\"environment\").slice(\"CONTAINERS\", \"EVENTS\", \"INFO\", \"POST\") == {\n",
    to: "  {\n",
    rows: ["a proxy that allows POST"]
  },
  {
    label: "the multi-architecture relay image check",
    program: :stack,
    from: "  relay[\"image\"].to_s.start_with?(\"docker.io/library/python:\")\n",
    to: "  true\n",
    rows: ["a relay on a single-architecture image"]
  },
  {
    label: "the relay runtime identity check",
    program: :stack,
    from: "  relay[\"user\"] == \"${NAS_UID:?}:${NAS_GID:?}\" && relay[\"command\"] == " \
          "[\"python\", \"/app/alert_relay.py\"]\n",
    to: "  true\n",
    rows: ["a relay running as root"]
  },
  {
    label: "the relay environment equality",
    program: :stack,
    from: "  relay[\"environment\"] == {\n",
    to: "  true || {\n",
    rows: ["a relay handed the publish token under another name"]
  },
  {
    label: "the relay mount list equality",
    program: :stack,
    from: "abort \"Dozzle contract failed: alert relay mounts differ\" unless relay[\"volumes\"] == [\n",
    to: "abort \"Dozzle contract failed: alert relay mounts differ\" unless true || [\n",
    rows: ["relay state mounted read-only"]
  },
  {
    label: "the loopback-only relay publication check",
    program: :stack,
    from: "  relay[\"ports\"] == [\"127.0.0.1:${ALERT_RELAY_PORT:?}:${ALERT_RELAY_PORT:?}\"] &&\n",
    to: "  true &&\n",
    rows: ["a relay that publishes on the wildcard"]
  },
  {
    label: "the relay hardening check",
    program: :stack,
    from: "  relay[\"read_only\"] == true && relay[\"tmpfs\"] == [\"/tmp\"] &&\n",
    to: "  true ||\n",
    rows: ["a writable relay root filesystem"]
  },
  {
    label: "the dependency health gate check",
    program: :stack,
    from: "  dozzle[\"depends_on\"] == {\n",
    to: "  true || {\n",
    rows: ["Dozzle started before the relay is healthy"]
  },
  {
    label: "the deployment input check",
    program: :stack,
    from: "  deployment_inputs.include?(\"services/dozzle/alert_relay.py\")\n",
    to: "  true\n",
    rows: ["deployment inputs that stop validating the relay"]
  },
  {
    label: "the immutable release check",
    program: :stack,
    from: "  deployment_bundle.include?(\"services/dozzle/alert_relay.py\") &&\n",
    to: "  true ||\n",
    rows: ["a release that stops carrying the relay"]
  },
  {
    label: "the tracked relay revalidation check",
    program: :stack,
    from: "  Array(revalidate&.dig(\"vars\", \"deployment_target_extra_paths\"))\n",
    to: "  [\"{{ platform_current_dir }}/services/dozzle/alert_relay.py\"]\n",
    rows: ["a role that stops revalidating the tracked relay"]
  },
  {
    label: "the private relay state mode check",
    program: :stack,
    from: "  prepare.dig(\"ansible.builtin.file\", \"mode\") == \"0700\" &&\n",
    to: "  true &&\n",
    rows: ["a relay state directory that is not private"]
  },
  {
    label: "the state child symlink check",
    program: :stack,
    from: "  child_inspect.dig(\"ansible.builtin.stat\", \"follow\") == false &&\n",
    to: "  true &&\n",
    rows: ["a state child preflight that follows symlinks"]
  },
  {
    label: "the relocation argv guard",
    program: :stack,
    from: "  relocate_argv.first == \"mv\" && relocate_argv[1] == \"--\" &&\n",
    to: "  true &&\n",
    rows: ["a legacy relocation that takes option-shaped paths"]
  },
  {
    label: "the rendered state root check",
    program: :stack,
    from: "  env_template.include?(\"DOZZLE_STATE_ROOT={{ dozzle_state_root }}\")\n",
    to: "  true\n",
    rows: ["an environment that stops rendering the state root"]
  },
  {
    label: "the rendered listener port check",
    program: :stack,
    from: "  env_template.include?(\"ALERT_RELAY_PORT={{ dozzle_alert_relay_port }}\")\n",
    to: "  true\n",
    rows: ["an environment that stops rendering the listener port"]
  },
  {
    label: "the exact alert definitions",
    program: :alerts,
    from: "abort \"Dozzle contract failed: exact alert definitions differ\" unless actual == expected\n",
    to: "",
    rows: ["a cooldown that drifted"]
  },
  {
    label: "the event-only rule check",
    program: :alerts,
    from: "  alerts.all? { |alert| alert.fetch(\"enabled\") == true && " \
          "alert.fetch(\"containerExpression\") == \"true\" && alert.fetch(\"logExpression\") == \"\" }\n",
    to: "  true\n",
    rows: ["a rule that also matches log lines"]
  },
  {
    label: "the single declared TCP port check",
    program: :alerts,
    from: "  relay_port.is_a?(Integer) && relay_port.between?(1, 65535)\n",
    to: "  true\n",
    rows: ["a listener port that is not a number"]
  },
  {
    label: "the private-relay dispatcher target check",
    program: :alerts,
    from: "  dispatcher.fetch(\"url\") == \"http://alert-relay:{{ dozzle_alert_relay_port }}/alerts\"\n",
    to: "  true\n",
    rows: ["a dispatcher pointed straight at the publisher"]
  },
  {
    label: "the dispatcher authorization check",
    program: :alerts,
    from: "  dispatcher.fetch(\"headers\") == {\"Authorization\" => " \
          "\"Bearer {{ vault_dozzle_alert_relay_token }}\"}\n",
    to: "  true\n",
    rows: ["a dispatcher that stopped carrying its token"]
  },
  {
    label: "the presentation envelope rejection",
    program: :alerts,
    from: "  %w[topic title message priority tags markdown].any? " \
          "{ |field| template_source.include?(\"'#{'#'}{field}'\") }\n",
    to: "  false\n",
    rows: ["a dispatcher that went back to a presentation envelope"]
  },
  {
    label: "the exact template field scan",
    program: :alerts,
    from: "    template_source.include?(\"'#{'#'}{field}':\") && template_source.include?(expression)\n",
    to: "    true\n",
    rows: ["a dispatcher missing the container identity"]
  },
  {
    label: "the PATCH reconciliation check",
    program: :alerts,
    from: "  role_tasks.any? { |task| task.dig(\"ansible.builtin.uri\", \"method\") == \"PATCH\" }\n",
    to: "  true\n",
    rows: ["a role that stopped reconciling enabled state"]
  },
  {
    label: "the planned-change task scan",
    program: :alerts,
    from: "      role_tasks.any? { |task| task[\"name\"] == name }\n",
    to: "      true\n",
    rows: ["a renamed planned-change report task under static"]
  },
  {
    label: "the integration marker scan",
    program: :alerts,
    from: "    abort \"Dozzle contract failed: integration is missing #{'#'}{marker}\" unless " \
          "integration.include?(marker)\n",
    to: "",
    rows: ["an integration lane that stopped printing a scenario marker"]
  },
  {
    label: "the Mac drift mode proof",
    program: :alerts,
    from: "    abort \"Dozzle contract failed: Mac drift proof is missing #{'#'}{proof}\" unless " \
          "mac_drift.include?(proof)\n",
    to: "",
    rows: ["a Mac drift proof that stopped running the check-mode scenario"]
  },
  {
    label: "the Mac drift group-label proof",
    program: :alerts,
    from: "    mac_drift.include?(\"dev.dozzle.group\")\n",
    to: "    true\n",
    rows: ["a Mac drift proof that stopped corrupting the group label"]
  },
  {
    label: "the Mac drift friendly-name proof",
    program: :alerts,
    from: "    mac_drift.include?(\"dev.dozzle.name: dozzle-contract-drift\")\n",
    to: "    true\n",
    rows: ["a Mac drift proof that stopped corrupting the friendly name"]
  },
  {
    label: "the Mac drift sentinel proof",
    program: :alerts,
    from: "    mac_drift.include?(\"dev.dozzle.contract.sentinel\")\n",
    to: "    true\n",
    rows: ["a Mac drift proof that stopped installing its sentinel"]
  },
  {
    label: "the Mac verification label proof",
    program: :alerts,
    from: "    mac_verify.include?(\"docker container inspect\") &&\n",
    to: "    true ||\n",
    rows: ["Mac verification that stopped reading Docker labels"]
  },
  # The half that moved to the sibling program in #315.
  {
    label: "the Mac verification managed-label proof",
    program: :alerts,
    from: "      mac_verify_labels.include?(\"dev.dozzle.group\") &&\n",
    to: "      true &&\n",
    rows: ["Mac verification that stopped naming the managed labels"]
  },
  {
    label: "the per-marker count comparison",
    program: :planned,
    from: "  abort \"Dozzle contract failed: planned-change marker count differs for " \
          "#{'#'}{marker}\" unless actual == expected\n",
    to: "",
    rows: ["the missing transcript judged as mixed", "the mixed transcript judged as missing",
           "a repair marker printed twice", "a skipped repair predicate"]
  },
  {
    label: "the word boundary around a marker",
    program: :planned,
    from: "  actual = output.scan(/\\b#{'#'}{Regexp.escape(marker)}\\b/).length\n",
    to: "  actual = output.scan(/#{'#'}{Regexp.escape(marker)}/).length\n",
    rows: ["a longer token that begins with a marker"],
    # The only mutation whose row expects *success*.
    detects: "expected success"
  },
  {
    label: "the transcript path safety check, against a symlink",
    program: :planned,
    from: "  File.file?(output_path) && !File.symlink?(output_path)\n",
    to: "  true\n",
    rows: ["a transcript reached through a symlink"]
  },
  {
    # Without `File.file?` an absent path raises Errno::ENOENT. A cascade.
    label: "the transcript path safety check, against an absent file",
    program: :planned,
    from: "  File.file?(output_path) && !File.symlink?(output_path)\n",
    to: "  true\n",
    rows: ["a transcript that is not there"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the transcript path presence check",
    program: :planned,
    from: "abort \"Dozzle contract failed: planned-change output path is absent\" unless output_path\n",
    to: "",
    rows: ["no transcript path at all"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the safe identifier filter",
    program: :runtime,
    from: "  fail_contract(\"API returned an unsafe identifier\") unless id.match?(SAFE_ID)\n",
    to: "",
    rows: ["an API identifier that is not safe to echo"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the session cookie check",
    program: :runtime,
    from: "fail_contract(\"vault credential did not receive an authentication cookie\") if " \
          "cookie.to_s.empty?\n",
    to: "",
    rows: ["a login that returns no session"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the dispatcher cardinality check",
    program: :runtime,
    from: "fail_contract(\"expected exactly one dispatcher\") unless dispatchers.length == 1\n",
    to: "",
    rows: ["a second managed dispatcher"],
    detects: "accepted what it must refuse"
  },
  {
    label: "the dispatcher URL check",
    program: :runtime,
    from: "fail_contract(\"managed dispatcher URL differs\") unless dispatcher[\"url\"] == expected_url\n",
    to: "",
    rows: ["a listener port the dispatcher no longer agrees with"]
  },
  {
    label: "the dispatcher template check",
    program: :runtime,
    from: "fail_contract(\"managed dispatcher template differs\") unless " \
          "dispatcher[\"template\"] == expected_template\n",
    to: "",
    rows: ["a dispatcher whose template lost a field"]
  },
  {
    label: "the dispatcher header check",
    program: :runtime,
    from: "  dispatcher[\"headers\"] == { \"Authorization\" => " \
          "\"Bearer #{'#'}{vault.fetch('vault_dozzle_alert_relay_token')}\" }\n",
    to: "  true\n",
    rows: ["a dispatcher carrying somebody else's token"]
  },
  {
    label: "the rule cardinality check",
    program: :runtime,
    from: "fail_contract(\"expected exactly four alert rules\") unless rules.length == 4\n",
    to: "",
    rows: ["a deleted alert rule"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the per-rule equality check",
    program: :runtime,
    from: "  fail_contract(\"#{'#'}{name} rule differs\") unless rule[\"enabled\"] == true &&\n",
    to: "  fail_contract(\"#{'#'}{name} rule differs\") unless true ||\n",
    rows: ["a disabled alert rule", "a rule wired to another dispatcher"]
  },
  {
    label: "the report root safety check",
    program: :runtime,
    from: "    File.directory?(REPORT_ROOT) && !File.symlink?(REPORT_ROOT)\n",
    to: "    true\n",
    rows: ["a report root reached through a symlink"],
    detects: "accepted what it must refuse"
  },
  {
    label: "the vault read status check",
    program: :runtime,
    from: "fail_contract(\"encrypted vault could not be read\") unless status.success?\n",
    to: "",
    rows: ["a vault that cannot be decrypted"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the drift fixture assertion",
    program: :runtime,
    from: "  fail_contract(\"dispatcher drift changed\") unless dispatchers.length == 1 &&\n",
    to: "  fail_contract(\"dispatcher drift changed\") unless true ||\n",
    rows: ["a drift fixture the run reverted"],
    # A cascade: the OOM rule check below refuses first.
    detects: "refused for the wrong reason"
  },
  {
    label: "the Beszel end-to-end recorder requirement",
    program: :runtime,
    from: "      messages.find { |message| message.fetch(\"form\")[\"title\"] == \"Test Alert\" }\n",
    to: "      { \"credentials_ok\" => true, \"path\" => \"/1/messages.json\", " \
        "\"form\" => { \"title\" => \"Test Alert\", \"priority\" => \"1\", \"html\" => \"1\" } }\n",
    rows: ["a Beszel test notification that never reaches the recorder"]
  },
  {
    label: "the Beszel Alerts credential check",
    program: :runtime,
    from: "      delivered[\"credentials_ok\"]\n",
    to: "      true\n",
    rows: ["a Beszel test notification published with the Containers token"]
  },
  {
    label: "the Beszel delivery failure check",
    program: :runtime,
    from: "      answer.is_a?(Hash) && answer[\"err\"] == false\n",
    to: "      true\n",
    rows: ["a hub that reports the relay refused the test notification"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the Beszel stored webhook check",
    program: :runtime,
    from: "    webhooks.length == 1 && webhooks.first.start_with?(relay_route)\n",
    to: "    true\n",
    rows: ["a hub whose stored webhook is not the relay's /beszel route"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the Beszel test notification presentation check",
    program: :runtime,
    from: "      !form.key?(\"url\") && !form.key?(\"url_title\")\n",
    to: "      true\n",
    rows: ["a Beszel test notification that arrived with a button"]
  }
].freeze

# Deliberately unpinned: the stack program's three task-existence conjuncts (they
# raise NoMethodError first), the runtime's `rule is absent or duplicated` (the
# count check refuses first), and the exit-event increment (needs real Docker).

def canonical_program(kind)
  {
    group_render: GROUP_RENDER_PROGRAM, labels: LABELS_PROGRAM, stack: STACK_PROGRAM,
    alerts: ALERTS_PROGRAM, planned: PLANNED_OUTPUT_PROGRAM, runtime: RUNTIME_PROGRAM
  }.fetch(kind)
end

def with_mutant(mutation)
  canonical = canonical_program(mutation.fetch(:program))
  source = substitute(File.read(canonical), mutation.fetch(:from), mutation.fetch(:to),
                      count: mutation.fetch(:count, 1))
  Dir.mktmpdir("nas-platform-dozzle-mutant.") do |directory|
    path = File.join(directory, File.basename(canonical))
    File.write(path, source)
    yield path
  end
end

if ARGV.include?("--self-test")
  # Accumulated rather than aborted, so one run reports every plant.
  problems = in_parallel_case_results(PROGRAM_MUTATIONS) do |mutation|
    with_mutant(mutation) do |mutant|
      rows = mutation.fetch(:rows)
      caught = case mutation.fetch(:program)
               when :group_render then group_render_failures(mutant, rows_named(GROUP_RENDER_ROWS, rows))
               when :labels then labels_failures(mutant, rows_named(LABEL_ROWS, rows))
               when :stack then stack_failures(mutant, rows_named(STACK_ROWS, rows))
               when :alerts then alerts_failures(mutant, rows_named(ALERTS_ROWS, rows))
               when :planned then planned_failures(mutant, rows_named(PLANNED_ROWS, rows))
               else runtime_failures(mutant, rows_named(RUNTIME_ROWS, rows))
               end
      next ["removing #{mutation.fetch(:label)} was accepted"] if caught.empty?

      detects = mutation.fetch(:detects, "accepted what it must refuse")
      next [] if caught.all? { |failure| failure.include?(detects) }

      ["removing #{mutation.fetch(:label)} was caught by the wrong assertion: " \
       "#{caught.join(' | ')}"]
    end
  end
  unless problems.empty?
    problems.each { |problem| warn "SELF-TEST #{problem}" }
    abort "#{problems.length} self-test failure(s)"
  end

  # The last two are `exec`ed and cannot be covered by any of the others.
  planted_redirects = 0
  [
    ["\"$stack\" \"$variant\" \"$expected_group\" \"$relay_probe_port\" </dev/null\n",
     "\"$stack\" \"$variant\" \"$expected_group\" \"$relay_probe_port\"\n"],
    # Taken from the list rather than restated, since the last file moves.
    ["\"$repo_dir/#{BASE_COMPOSE_FILES.last}\" </dev/null\n",
     "\"$repo_dir/#{BASE_COMPOSE_FILES.last}\"\n"],
    ["\"$deployment_inputs\" \"$deployment_bundle\" \"$defaults\" </dev/null\n",
     "\"$deployment_inputs\" \"$deployment_bundle\" \"$defaults\"\n"],
    ["\"$mac_verify\" \"$mac_verify_labels\" \"$service_vars\" \"$mode\" </dev/null\n",
     "\"$mac_verify\" \"$mac_verify_labels\" \"$service_vars\" \"$mode\"\n"],
    ["exec ruby \"$planned_output_program\" \"$mode\" \"$@\" </dev/null\n",
     "exec ruby \"$planned_output_program\" \"$mode\" \"$@\"\n"],
    ["exec ruby \"$runtime_program\" \"$mode\" \"$@\" </dev/null\n",
     "exec ruby \"$runtime_program\" \"$mode\" \"$@\"\n"],
    ["exec ruby \"$runtime_program\" \"$mode\" \"$@\" </dev/null\n",
     "cat >/dev/null\nexec ruby \"$runtime_program\" \"$mode\" \"$@\" </dev/null\n"]
  ].each do |from, to|
    unredirected = substitute(File.read(CONTRACT), from, to)
    leaked = stdin_failures(wrapper_source: unredirected)
    abort "self-test failed: a dropped stdin redirect was accepted: #{from.strip.inspect}" if
      leaked.empty?
    planted_redirects += 1
  end

  # #251's defect at every site, including the `-r` preload where it inverts.
  planted_roots = 0
  program_plants = WRAPPER_PROGRAM_SOURCES.keys.map do |name|
    variable = name.delete_prefix("dozzle-").delete_suffix(".rb").tr("-", "_")
    variable = "#{variable}_program"
    ["#{variable}=$contract_repo_dir/tests/contracts/#{name}\n",
     "#{variable}=$repo_dir/tests/contracts/#{name}\n"]
  end
  (program_plants + [
    [%(ruby -r"$repo_dir/tests/policy_support.rb" "$labels_program"),
     %(ruby -r"$contract_repo_dir/tests/policy_support.rb" "$labels_program")],
    ["defaults=$repo_dir/roles/dozzle/defaults/main.yml\n",
     "defaults=$contract_repo_dir/roles/dozzle/defaults/main.yml\n"],
    ["integration=$repo_dir/tests/integration_controller.sh\n",
     "integration=$contract_repo_dir/tests/integration_controller.sh\n"]
  ]).each do |from, to|
    misrooted = substitute(File.read(CONTRACT), from, to)
    caught = wrapper_failures(wrapper_source: misrooted)
    abort "self-test failed: #{from.strip.inspect} rerooted to the wrong tree was accepted" if
      caught.empty?
    planted_roots += 1
  end

  # Checked by name: any other row failing would satisfy a bare non-empty check.
  unguarded = substitute(File.read(CONTRACT), "  *) exit 2 ;;\n", "  *) ;;\n")
  caught = wrapper_failures(wrapper_source: unguarded)
  abort "self-test failed: a deleted mode guard was accepted" if caught.empty?
  abort "self-test failed: a deleted mode guard was caught by the wrong assertion: " \
        "#{caught.join(' | ')}" unless caught.all? { |failure| failure.include?("the mode guard") }
  planted_guards = 1

  puts "dozzle contract: self-test detects " \
       "#{PROGRAM_MUTATIONS.length + planted_redirects + planted_roots + planted_guards} " \
       "planted regressions"
  exit
end

failures = group_render_failures + labels_failures + stack_failures + alerts_failures +
           planned_failures + runtime_failures + runtime_sequence_failures +
           wrapper_failures + stdin_failures + pushover_port_failures + recorder_failures +
           port_reservation_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Dozzle contract violation(s)"
end

puts "dozzle contract: #{GROUP_RENDER_ROWS.length} group render, #{LABEL_ROWS.length} label, " \
     "#{STACK_ROWS.length} stack, #{ALERTS_ROWS.length} alert, #{PLANNED_ROWS.length} planned " \
     "and #{RUNTIME_ROWS.length} runtime properties hold, the notify mode's recorder " \
     "decodes what the deployed relay actually POSTs and redacts the credentials out of " \
     "it, the wrapper reaches all six programs with an empty stdin, and a reserved " \
     "loopback port is one a second process is refused while a released one is not"
