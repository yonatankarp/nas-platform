#!/usr/bin/env ruby
# Focused regression checks for predicate-sensitive Dozzle proof output.

require "open3"
require "fileutils"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

CONTRACT = File.join(ROOT, "tests", "contracts", "dozzle.sh")
ROLE = File.join(ROOT, "roles", "dozzle", "tasks", "main.yml")
PAPERLESS_COMPOSE = File.join("services", "paperless-ngx", "compose.yml")
BASE_COMPOSE_FILES = %w[
  services/audiobookshelf/compose.yml
  services/beszel/compose.yml
  services/dozzle/compose.yml
  services/immich/compose.yml
  services/jellyfin/compose.yml
  services/komga/compose.yml
  services/ntfy/compose.yml
  services/paperless-ngx/compose.yml
].freeze
failures = []

MARKERS = {
  "DOZZLE_PLAN_DISPATCHER_CREATE" => [0, 1],
  "DOZZLE_PLAN_DISPATCHER_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_CREATE" => [1, 4],
  "DOZZLE_PLAN_RULE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_ENABLE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_REMOVE" => [1, 0],
  "DOZZLE_PLAN_DISPATCHER_REMOVE" => [1, 0]
}.freeze

TASKS = [
  "Report planned managed Dozzle dispatcher creation",
  "Report planned managed Dozzle dispatcher repair",
  "Report planned managed Dozzle alert rule creation",
  "Report planned managed Dozzle alert rule repair",
  "Report planned managed Dozzle alert rule enabled-state repair",
  "Report planned unmanaged Dozzle alert rule removal",
  "Report planned unmanaged Dozzle dispatcher removal"
].freeze

def output_for(index)
  headers = TASKS.map { |task| "TASK [dozzle : #{task}]" }
  markers = MARKERS.flat_map { |marker, counts| [marker] * counts.fetch(index) }
  (headers + markers + ["nas : ok=1 changed=6 unreachable=0 failed=0 skipped=6 rescued=0 ignored=0"]).join("\n") + "\n"
end

def run_assertion(mode, output)
  Dir.mktmpdir("nas-platform-dozzle-quality-") do |directory|
    path = File.join(directory, "ansible-output.txt")
    File.write(path, output, mode: "w", perm: 0o600)
    Open3.capture3(CONTRACT, mode, path)
  end
end

def run_static(repo_root)
  Open3.capture3({"PLATFORM_CONTRACT_REPO_DIR" => repo_root}, CONTRACT, "static")
end

def with_copied_repo
  Dir.mktmpdir("nas-platform-dozzle-quality-") do |directory|
    repo = File.join(directory, "repo")
    FileUtils.cp_r(ROOT, repo)
    yield repo
  end
end

def add_name_labels!(repo)
  BASE_COMPOSE_FILES.each do |relative_path|
    path = File.join(repo, relative_path)
    raise "base Compose fixture is unavailable" unless File.file?(path) && !File.symlink?(path)

    compose = File.read(path)
    services = YAML.safe_load(compose, aliases: true).fetch("services").keys.map(&:to_s)
    services.reverse_each do |service|
      header = /^  #{Regexp.escape(service)}:\s*$/
      starts = compose.enum_for(:scan, header).map { Regexp.last_match.begin(0) }
      raise "base Compose service fixture differs" unless starts.one?

      service_start = starts.fetch(0)
      service_end = compose.index(/^  [A-Za-z0-9_-]+:\s*$/, service_start + 1) || compose.length
      definition = compose[service_start...service_end]
      expected_label = "      dev.dozzle.name: #{service}\n"
      name_labels = definition.lines.grep(/^      dev\.dozzle\.name:/)
      if name_labels.empty?
        if definition.scan(/^    labels:\s*$/).one?
          definition = definition.sub(/^    labels:\s*$\n/, "    labels:\n#{expected_label}")
        else
          container_names = definition.scan(/^    container_name:.*$/)
          raise "base Compose container fixture differs" unless container_names.one?

          definition = definition.sub(
            /^(    container_name:.*\n)/,
            "\\1    labels:\n#{expected_label}"
          )
        end
      elsif name_labels != [expected_label]
        raise "base Compose name fixture differs"
      end
      compose[service_start...service_end] = definition
    end
    File.write(path, compose)
  end
end

def with_label_complete_repo
  with_copied_repo do |repo|
    add_name_labels!(repo)
    yield repo
  end
end

def mutate_gotenberg_name!(repo, mutation)
  path = File.join(repo, PAPERLESS_COMPOSE)
  compose = File.read(path)
  service_start = compose.index("\n  gotenberg:\n")
  service_end = service_start && compose.index("\n  tika:\n", service_start)
  raise "paperless gotenberg fixture is absent" unless service_start && service_end

  service = compose[service_start...service_end]
  label = "      dev.dozzle.name: gotenberg\n"
  raise "paperless gotenberg name fixture differs" unless service.scan(label).one?

  replacement = case mutation
                when :missing then ""
                when :wrong then "      dev.dozzle.name: paperless-gotenberg\n"
                when :duplicate then label * 2
                else raise "unknown paperless gotenberg mutation"
                end
  compose[service_start...service_end] = service.sub(label, replacement)
  File.write(path, compose)
end

def check_name_mutation(failures, mutation, expected_diagnostic)
  with_label_complete_repo do |repo|
    mutate_gotenberg_name!(repo, mutation)
    _stdout, stderr, status = run_static(repo)
    check(failures, !status.success?, "Dozzle static contract accepted #{mutation} gotenberg name label")
    check(failures, stderr == expected_diagnostic,
          "Dozzle static contract #{mutation} gotenberg diagnostic differs")
  end
rescue RuntimeError, SystemCallError => error
  failures << "Dozzle #{mutation} gotenberg mutation fixture failed: #{error.message}"
end

def check_label_complete_fixture(failures)
  with_label_complete_repo do |repo|
    _stdout, stderr, status = run_static(repo)
    check(failures, status.success?,
          "Dozzle label-complete fixture failed: #{stderr.lines.first&.strip}")
  end
rescue KeyError, Psych::Exception, RuntimeError, SystemCallError => error
  failures << "Dozzle label-complete fixture setup failed: #{error.message}"
end

def check_static_mutation(failures, name, relative_path, original, replacement, diagnostic)
  with_copied_repo do |repo|
    path = File.join(repo, relative_path)
    source = File.read(path)
    raise "#{name} fixture differs" unless source.scan(original).length == 1

    File.write(path, source.sub(original, replacement))
    _stdout, stderr, status = run_static(repo)
    check(failures, !status.success?, "Dozzle static contract accepted #{name}")
    check(failures, stderr == "Dozzle contract failed: #{diagnostic}\n",
          "Dozzle static contract #{name} diagnostic differs: #{stderr.lines.first&.strip}")
  end
rescue RuntimeError, SystemCallError => error
  failures << "Dozzle #{name} mutation fixture failed: #{error.message}"
end

%w[assert-check-mixed-output assert-check-missing-output].each_with_index do |mode, index|
  output = output_for(index)
  _stdout, stderr, status = run_assertion(mode, output)
  check(failures, status.success?, "#{mode} rejected exact marker counts: #{stderr.lines.first&.strip}")

  required_marker = MARKERS.find { |_marker, counts| counts.fetch(index).positive? }.fetch(0)
  missing_marker_output = output.sub(/^#{Regexp.escape(required_marker)}\n/, "")
  _stdout, _stderr, missing_status = run_assertion(mode, missing_marker_output)
  check(failures, !missing_status.success?,
        "#{mode} accepted a skipped predicate because its task header and global changed recap remained")

  duplicated_marker_output = output.sub(
    /^#{Regexp.escape(required_marker)}\n/,
    "#{required_marker}\n#{required_marker}\n"
  )
  _stdout, _stderr, duplicate_status = run_assertion(mode, duplicated_marker_output)
  check(failures, !duplicate_status.success?, "#{mode} accepted an incorrect per-category occurrence count")
end

contract = File.read(CONTRACT)
fixed_diagnostics = [
  "OOM drift fixture differs",
  "managed dispatcher template differs",
  "unhealthy event did not reach the private relay and disposable ntfy",
  "healthy transition did not produce one correlated recovery",
  "startup healthy fixture did not exercise the managed recovery rule",
  "startup healthy event produced a false recovery",
  "disposable exit fixture did not exit with the expected status",
  "exit-code-1 event did not reach the private relay and disposable ntfy",
  "relay exposed its event envelope as ntfy message text"
]
fixed_diagnostics.each do |diagnostic|
  check(failures, contract.include?(diagnostic), "Dozzle contract is missing fixed diagnostic: #{diagnostic}")
end
unsafe_diagnostic_fragments = [
  "template differs: expected #{'#'}{expected_template.inspect}",
  "webhook test failed: #{'#'}{webhook_test.inspect}",
  "observed #{'#'}{observed_webhooks.inspect}",
  "#{'#'}{error.lines.first}",
  "trigger counters #{'#'}{counters.inspect}"
]
unsafe_diagnostic_fragments.each do |fragment|
  check(failures, !contract.include?(fragment), "Dozzle contract retains unsafe diagnostic interpolation: #{fragment}")
end
check(failures,
      contract.include?('rule.dig("dispatcher", "id").to_s == dispatcher["id"].to_s'),
      "Dozzle contract does not normalize opaque dispatcher IDs as strings")

_stdout, stderr, status = run_static(ROOT)
check(failures, status.success?, "Dozzle static contract rejected effective Compose labels: #{stderr.lines.first&.strip}")
check_label_complete_fixture(failures)
check_name_mutation(
  failures,
  :missing,
  "Dozzle contract failed: paperless-ngx base gotenberg name label is absent\n"
)
check_name_mutation(
  failures,
  :wrong,
  "Dozzle contract failed: paperless-ngx base gotenberg name label differs\n"
)
check_name_mutation(
  failures,
  :duplicate,
  "Dozzle contract failed: base Compose has duplicate dev.dozzle.name labels\n"
)

relay_mutations = [
  ["direct ntfy topic publishing", "roles/dozzle/defaults/main.yml",
   "  url: \"http://alert-relay:{{ dozzle_alert_relay_port }}/alerts\"\n", "  url: http://ntfy:80/nas-critical\n",
   "managed dispatcher must target only the private alert relay"],
  ["direct ntfy root publishing", "roles/dozzle/defaults/main.yml",
   "  url: \"http://alert-relay:{{ dozzle_alert_relay_port }}/alerts\"\n", "  url: http://ntfy:80/\n",
   "managed dispatcher must target only the private alert relay"],
  ["missing relay authorization", "roles/dozzle/defaults/main.yml",
   "  headers:\n    Authorization: \"Bearer {{ vault_ntfy_dozzle_token }}\"\n",
   "  headers: {}\n", "managed dispatcher authorization differs"],
  ["missing envelope version", "roles/dozzle/defaults/main.yml",
   "    {{ {'version': 1,\n", "    {{ {\n", "managed dispatcher is missing exact version"],
  ["missing container identity", "roles/dozzle/defaults/main.yml",
   "        'containerId': '{{ .Container.ID }}',\n", "",
   "managed dispatcher is missing exact containerId"],
  ["missing health status", "roles/dozzle/defaults/main.yml",
   "        'healthStatus': '{{ index .Event.Attributes `healthStatus` }}',\n", "",
   "managed dispatcher is missing exact healthStatus"],
  ["published relay port", "services/dozzle/compose.yml",
   "    command: [python, /app/alert_relay.py]\n",
   "    command: [python, /app/alert_relay.py]\n    ports:\n      - \"8081:8081\"\n",
   "alert relay must not publish a port"],
  ["writable relay root", "services/dozzle/compose.yml",
   "      test: [CMD, python, -c, \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:${ALERT_RELAY_PORT:?}/healthz', timeout=3).read()\"]\n      interval: 30s\n      timeout: 5s\n      retries: 4\n      start_period: 5s\n    read_only: true\n",
   "      test: [CMD, python, -c, \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:${ALERT_RELAY_PORT:?}/healthz', timeout=3).read()\"]\n      interval: 30s\n      timeout: 5s\n      retries: 4\n      start_period: 5s\n    read_only: false\n",
   "alert relay hardening differs"],
  ["relay Docker socket", "services/dozzle/compose.yml",
   "      - ${DOZZLE_STATE_ROOT:?}/alert-relay:/state\n",
   "      - ${DOZZLE_STATE_ROOT:?}/alert-relay:/state\n      - /var/run/docker.sock:/var/run/docker.sock:ro\n",
   "Docker socket is mounted outside socket-proxy"],
  ["read-only relay state", "services/dozzle/compose.yml",
   "      - ${DOZZLE_STATE_ROOT:?}/alert-relay:/state\n",
   "      - ${DOZZLE_STATE_ROOT:?}/alert-relay:/state:ro\n",
   "alert relay mounts differ"],
  ["parent-root relay state", "services/dozzle/compose.yml",
   "      - ${DOZZLE_STATE_ROOT:?}/alert-relay:/state\n",
   "      - ${DOZZLE_STATE_ROOT:?}:/state\n",
   "alert relay mounts differ"],
  # The listener port has one home, roles/dozzle/defaults/main.yml. These three
  # mutations put a literal back into each consumer in turn and require the
  # contract to reject it, so a second copy cannot reappear unnoticed.
  ["literal relay healthcheck port", "services/dozzle/compose.yml",
   "urlopen('http://127.0.0.1:${ALERT_RELAY_PORT:?}/healthz'",
   "urlopen('http://127.0.0.1:8081/healthz'",
   "dozzle base alert relay does not take its listener port from one variable"],
  ["literal relay dispatcher port", "roles/dozzle/defaults/main.yml",
   "  url: \"http://alert-relay:{{ dozzle_alert_relay_port }}/alerts\"\n",
   "  url: http://alert-relay:8081/alerts\n",
   "managed dispatcher must target only the private alert relay"],
  ["unrendered relay listener port", "roles/dozzle/templates/env.j2",
   "ALERT_RELAY_PORT={{ dozzle_alert_relay_port }}\n", "",
   "environment does not render the single relay listener port"]
].freeze
relay_mutations.each do |name, path, original, replacement, diagnostic|
  check_static_mutation(failures, name, path, original, replacement, diagnostic)
end

role_safety_mutations = [
  ["child preflight follows symlinks",
   "- name: Inspect the Dozzle alert relay state child before mutation\n" \
   "  ansible.builtin.stat:\n" \
   "    path: \"{{ dozzle_state_root }}/alert-relay\"\n" \
   "    follow: false\n",
   "- name: Inspect the Dozzle alert relay state child before mutation\n" \
   "  ansible.builtin.stat:\n" \
   "    path: \"{{ dozzle_state_root }}/alert-relay\"\n" \
   "    follow: true\n"],
  ["child preparation follows symlinks",
   "- name: Prepare the isolated Dozzle alert relay state directory\n" \
   "  ansible.builtin.file:\n" \
   "    path: \"{{ dozzle_state_root }}/alert-relay\"\n" \
   "    state: directory\n" \
   "    follow: false\n",
   "- name: Prepare the isolated Dozzle alert relay state directory\n" \
   "  ansible.builtin.file:\n" \
   "    path: \"{{ dozzle_state_root }}/alert-relay\"\n" \
   "    state: directory\n" \
   "    follow: true\n"],
  ["child symlink rejection removed",
   "        (dozzle_alert_relay_state_child_before_prepare.stat.isdir | default(false) and\n" \
   "         not (dozzle_alert_relay_state_child_before_prepare.stat.islnk | default(false)))\n",
   "        dozzle_alert_relay_state_child_before_prepare.stat.isdir | default(false)\n"]
].freeze
role_safety_mutations.each do |name, original, replacement|
  check_static_mutation(
    failures,
    name,
    "roles/dozzle/tasks/main.yml",
    original,
    replacement,
    "role can mutate an unsafe relay state child"
  )
end

# An absence invariant over the whole role still has to reach every task, but it
# reads the parsed scalars one at a time: a comment explaining why the role must
# not coerce an opaque identifier is not a coercion, and a folded expression that
# breaks the pipe onto its own line is one. Each scalar is offered with its
# whitespace removed as well, so neither spelling escapes.
role_scalars = PolicySupport.task_strings(YAML.safe_load_file(ROLE, aliases: true))
                            .map { |value| value.gsub(/[[:space:]]+/, "") }
check(failures, role_scalars.none? { |value| value.include?("dispatcher.id|int") },
      "Dozzle verification coerces opaque dispatcher IDs to integers")

report(failures, "Dozzle quality regressions: marker counts and safe diagnostics hold",
       "Dozzle quality regression(s)")
