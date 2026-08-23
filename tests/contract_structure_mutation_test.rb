#!/usr/bin/env ruby
# Mutation proofs for the contract assertions that read parsed task structure.
#
# A test assertion that has quietly stopped checking anything still passes, so a
# conversion from source text to parsed structure is only as good as the proof
# that the new form still bites. Every row below copies the repository, breaks
# exactly one thing in the copy, runs the static half of the contract against it
# and requires the contract to name the failure.
#
# The rows marked accepted prove the other direction. Each one is a shape the old
# source-text assertion judged wrongly: a required task name that survives only
# inside a comment, a literal that moved into a comment, a URL that changed
# nothing but its quoting style. Those rows are the reason the conversion is a
# correctness change rather than a restyling, and they are what would regress
# first if someone reintroduced a substring check.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
VALIDATE_POLICY = File.join(ROOT, "tests", "validate-policy.sh")
# The media probe suite reads the same Jellyfin role and duplicates several of
# the contract assertions, so it is proven here too. Its slow behavioural probes
# need Ansible and a container runtime; MEDIA_MANAGED_USERS_PROBES selects no
# probe group, which leaves exactly the static role assertions these rows are
# about and keeps a row under a second instead of near three minutes.
SUITES = {
  jellyfin: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "jellyfin.sh"), "--platform", "nas", "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { "Jellyfin contract failed: #{message}" }
  },
  komga: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "komga.sh"), "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { "Komga contract failed: #{message}" }
  },
  paperless: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "paperless.sh"), "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { "Paperless contract failed: #{message}" }
  },
  media_probes: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "media_managed_users_test.rb")] },
    environment: ->(_repo) { { "MEDIA_MANAGED_USERS_PROBES" => "none" } },
    diagnostic: ->(message) { "FAIL #{message}" }
  }
}.freeze

failures = []

def check(failures, condition, message)
  failures << message unless condition
end

def with_copied_repo
  Dir.mktmpdir("nas-platform-contract-structure-") do |directory|
    repo = File.join(directory, "repo")
    FileUtils.cp_r(ROOT, repo)
    yield repo
  end
end

def run_static(suite, repo)
  definition = SUITES.fetch(suite)
  Open3.capture3(definition.fetch(:environment).call(repo), *definition.fetch(:command).call(repo))
end

# Each substitution must match exactly once. A fixture that drifted would
# otherwise mutate the wrong place, or nothing at all, and the row would report a
# pass that proves nothing.
def apply_substitutions(repo, substitutions)
  substitutions.each do |relative_path, original, replacement|
    path = File.join(repo, relative_path)
    body = File.read(path)
    occurrences = body.scan(original).length
    raise "#{relative_path} fixture differs: #{occurrences} matches" unless occurrences == 1

    File.write(path, body.sub(original, replacement))
  end
end

# The contract suites abort on the first violation, so their whole diagnostic is
# one line. The probe suite reports every violation it found, so the expected line
# has to be present among them rather than be the only one.
def check_rejected(failures, suite, name, substitutions, diagnostic)
  expected = SUITES.fetch(suite).fetch(:diagnostic).call(diagnostic)
  with_copied_repo do |repo|
    apply_substitutions(repo, substitutions)
    _stdout, stderr, status = run_static(suite, repo)
    check(failures, !status.success?, "#{suite} contract accepted #{name}")
    check(failures, stderr.lines.map(&:chomp).include?(expected),
          "#{suite} contract #{name} diagnostic differs: #{stderr.lines.first&.strip}")
  end
rescue RuntimeError, SystemCallError => error
  failures << "#{suite} #{name} mutation fixture failed: #{error.message}"
end

def check_accepted(failures, suite, name, substitutions)
  with_copied_repo do |repo|
    apply_substitutions(repo, substitutions)
    _stdout, stderr, status = run_static(suite, repo)
    check(failures, status.success?,
          "#{suite} contract rejected #{name}: #{stderr.lines.first&.strip}")
  end
rescue RuntimeError, SystemCallError => error
  failures << "#{suite} #{name} fixture failed: #{error.message}"
end

JELLYFIN_ROLE = "roles/jellyfin/tasks/main.yml"
JELLYFIN_IDENTITY = "roles/jellyfin/tasks/primary_identity.yml"
JELLYFIN_SETTINGS = "roles/jellyfin/tasks/settings.yml"
KOMGA_ROLE = "roles/komga/tasks/main.yml"
PAPERLESS_SNAPSHOT = "tests/mac/snapshot-paperless.sh"

SUITES.each_key do |suite|
  with_copied_repo do |repo|
    _stdout, stderr, status = run_static(suite, repo)
    check(failures, status.success?,
          "#{suite} static contract failed on a pristine copy: #{stderr.lines.first&.strip}")
  end
end

check_rejected(
  failures, :jellyfin, "a required task that survives only as a comment",
  [[JELLYFIN_ROLE,
    "- name: Verify exact Jellyfin owned state\n",
    "# - name: Verify exact Jellyfin owned state\n" \
    "- name: Verify exact Jellyfin owned state after rename\n"]],
  "missing Verify exact Jellyfin owned state"
)

check_rejected(
  failures, :jellyfin, "a mutation task declared before the identity preflight",
  [[JELLYFIN_ROLE,
    "- name: Wait for the Jellyfin startup API\n",
    "- name: Update the Jellyfin server name\n" \
    "  ansible.builtin.debug:\n" \
    "    msg: jellyfin-early-mutation\n" \
    "\n" \
    "- name: Wait for the Jellyfin startup API\n"]],
  "all identity/library preflight must precede mutation"
)

check_rejected(
  failures, :jellyfin, "a DELETE verb that belongs to an unrelated request",
  [[JELLYFIN_ROLE, "    method: DELETE\n", "    method: POST\n"],
   [JELLYFIN_ROLE,
    "- name: Remove the exact Jellyfin administrator image probe\n",
    "- name: Remove an unrelated Jellyfin resource\n" \
    "  ansible.builtin.uri:\n" \
    "    url: \"{{ jellyfin_api }}/Items/probe\"\n" \
    "    method: DELETE\n" \
    "\n" \
    "- name: Remove the exact Jellyfin administrator image probe\n"]],
  "current path removal API is absent"
)

check_rejected(
  failures, :jellyfin, "an unconditional avatar upload beside conditional siblings",
  [[JELLYFIN_ROLE,
    "    body: \"{{ jellyfin_admin_avatar_staged.content }}\"\n" \
    "    status_code: [204]\n" \
    "  when:\n" \
    "    - not ansible_check_mode\n" \
    "    - jellyfin_admin_avatar_upload_required | default(false) | bool\n",
    "    body: \"{{ jellyfin_admin_avatar_staged.content }}\"\n" \
    "    status_code: [204]\n"]],
  "avatar upload is unconditional"
)

check_rejected(
  failures, :jellyfin, "a server configuration overwrite whose merge moved into a comment",
  [[JELLYFIN_ROLE,
    "    body: >-\n" \
    "      {{ jellyfin_server_configuration_for_update.json |\n" \
    "         combine({'ServerName': jellyfin_server_name}) }}\n",
    "    # {{ jellyfin_server_configuration_for_update.json | combine(...) }}\n" \
    "    body: >-\n" \
    "      {{ {'ServerName': jellyfin_server_name} }}\n"]],
  "server configuration update does not preserve unrelated fields"
)

check_rejected(
  failures, :jellyfin, "an opaque database reference in an unscoped task",
  [[JELLYFIN_ROLE,
    "    msg: JELLYFIN_PLAN_SERVER_NAME\n",
    "    msg: JELLYFIN_PLAN_SERVER_NAME jellyfin.db\n"]],
  "role must not edit an opaque database"
)

check_rejected(
  failures, :jellyfin, "a version pin folded across the plugin install URL",
  [[JELLYFIN_SETTINGS,
    "         '&repositoryUrl=' ~ (item.RepositoryUrl | urlencode) }}\n",
    "         '&repositoryUrl=' ~ (item.RepositoryUrl | urlencode) ~\n" \
    "         '&version=1.0' }}\n"]],
  "plugin install must not supply a version"
)

check_rejected(
  failures, :jellyfin, "a package catalog preflight against a different endpoint",
  [[JELLYFIN_SETTINGS,
    "    url: \"{{ jellyfin_api }}/Packages\"\n",
    "    url: \"{{ jellyfin_api }}/PackagesCatalog\"\n"]],
  "compatible package catalog preflight is absent"
)

check_rejected(
  failures, :jellyfin, "a recovery marker read that no longer requires private mode",
  [[JELLYFIN_ROLE,
    "      - not jellyfin_primary_recovery_marker_state.stat.exists or\n" \
    "        jellyfin_primary_recovery_marker_state.stat.mode == '0600'\n",
    "      - true\n"]],
  "recovery marker privacy is not checked before reading"
)

check_rejected(
  failures, :jellyfin, "a primary identity rename with no recovery path",
  [[JELLYFIN_IDENTITY, "  rescue:\n", "  always:\n"]],
  "primary identity rename lacks recovery"
)

check_accepted(
  failures, :jellyfin, "a package catalog URL that changed only its quoting style",
  [[JELLYFIN_SETTINGS,
    "    url: \"{{ jellyfin_api }}/Packages\"\n",
    "    url: '{{ jellyfin_api }}/Packages'\n"]]
)

# A byte offset is not a task position. Both of these place a mutation task's name
# in a comment ahead of the preflight, which changed nothing about the role but
# moved the offset the old ordering assertions measured, so both suites reported a
# phase violation that did not exist.
check_accepted(
  failures, :jellyfin, "a mutation task name mentioned in an early comment",
  [[JELLYFIN_ROLE,
    "- name: Wait for the Jellyfin startup API\n",
    "# - name: Update the Jellyfin server name\n" \
    "- name: Wait for the Jellyfin startup API\n"]]
)

check_accepted(
  failures, :komga, "a mutation task name mentioned in an early comment",
  [[KOMGA_ROLE,
    "- name: Deploy Komga\n",
    "# - name: Create the managed Komga library\n" \
    "- name: Deploy Komga\n"]]
)

check_rejected(
  failures, :komga, "a required task that survives only as a comment",
  [[KOMGA_ROLE,
    "- name: Require exact reconciled Komga library\n",
    "# - name: Require exact reconciled Komga library\n" \
    "- name: Require exact reconciled Komga libraries\n"]],
  "missing Require exact reconciled Komga library"
)

check_rejected(
  failures, :komga, "a mutation task declared before the library preflight",
  [[KOMGA_ROLE,
    "- name: Read Komga claim status\n",
    "- name: Create the managed Komga library\n" \
    "  ansible.builtin.debug:\n" \
    "    msg: komga-early-mutation\n" \
    "\n" \
    "- name: Read Komga claim status\n"]],
  "library preflight must precede every mutation"
)

check_rejected(
  failures, :komga, "a normalized root fact that dropped its trailing-slash filter",
  [[KOMGA_ROLE,
    "    komga_library_normalized_root: \"{{ komga_library_root | regex_replace('/+$', '') }}\"\n",
    "    komga_library_normalized_root: \"{{ komga_library_root }}\"\n"]],
  "managed root matching is not trailing-slash normalized"
)

check_rejected(
  failures, :komga, "a library repair whose selected identifier moved into a comment",
  [[KOMGA_ROLE,
    "    url: >-\n" \
    "      {{ komga_api }}/api/v1/libraries/{{ komga_existing_library.id | urlencode }}\n" \
    "    method: PATCH\n",
    "    # {{ komga_existing_library.id | urlencode }}\n" \
    "    url: >-\n" \
    "      {{ komga_api }}/api/v1/libraries/{{ komga_existing_library.name | urlencode }}\n" \
    "    method: PATCH\n"]],
  "library updates must preserve the selected identifier"
)

check_rejected(
  failures, :komga, "an opaque database reference in an unscoped task",
  [[KOMGA_ROLE, "    msg: KOMGA_PLAN_CLAIM\n", "    msg: KOMGA_PLAN_CLAIM database.sqlite\n"]],
  "role must not edit an opaque database"
)

# The exact line the drill carried before the login budget was fixed. The
# behavioural proof of the budget is tests/mac/snapshot-paperless-drill-throttle-test.sh;
# this row proves the cheap static half of the pair still rejects the shape, so the
# assertion cannot rot into one that passes against the broken form too.
check_rejected(
  failures, :paperless, "a deletion poll that logs in again on every pass",
  [[PAPERLESS_SNAPSHOT,
    "    break if catalogue(drill_token).empty?\n",
    "    break if catalogue(authenticate(admin_username, admin_password)).empty?\n"]],
  "Paperless drill poll must reuse the drill token rather than log in again"
)

check_rejected(
  failures, :media_probes, "a managed-user include that survives only as a comment",
  [[KOMGA_ROLE,
    "  ansible.builtin.include_tasks: managed_users.yml\n",
    "  # ansible.builtin.include_tasks: managed_users.yml\n" \
    "  ansible.builtin.debug:\n" \
    "    msg: komga-managed-users-disabled\n"],
   [KOMGA_ROLE, "    file: managed_users.yml\n", "    file: managed_users_disabled.yml\n"]],
  "komga main tasks omit managed-user reconciliation"
)

check_rejected(
  failures, :media_probes, "an explicitly managed Collections library",
  [[JELLYFIN_ROLE,
    "- name: Wait for the Jellyfin startup API\n",
    "- name: Manage the Jellyfin Collections library\n" \
    "  ansible.builtin.set_fact:\n" \
    "    collection_type: Collections\n" \
    "\n" \
    "- name: Wait for the Jellyfin startup API\n"]],
  "Jellyfin must not explicitly manage Collections"
)

check_rejected(
  failures, :media_probes, "a DELETE verb that belongs to an unrelated request",
  [[JELLYFIN_ROLE, "    method: DELETE\n", "    method: POST\n"],
   [JELLYFIN_ROLE,
    "- name: Remove the exact Jellyfin administrator image probe\n",
    "- name: Remove an unrelated Jellyfin resource\n" \
    "  ansible.builtin.uri:\n" \
    "    url: \"{{ jellyfin_api }}/Items/probe\"\n" \
    "    method: DELETE\n" \
    "\n" \
    "- name: Remove the exact Jellyfin administrator image probe\n"]],
  "Jellyfin extra library paths do not use the supported removal endpoint"
)

check_rejected(
  failures, :media_probes, "an image endpoint renamed on every request that uses it",
  [[JELLYFIN_ROLE,
    "    url: \"{{ jellyfin_api }}/UserImage?userId=" \
    "{{ jellyfin_primary_authenticated_id | urlencode }}\"\n",
    "    url: \"{{ jellyfin_api }}/UserImageUpload?userId=" \
    "{{ jellyfin_primary_authenticated_id | urlencode }}\"\n"],
   [JELLYFIN_ROLE,
    "      {{ jellyfin_api ~ '/UserImage?userId=' ~\n" \
    "         (jellyfin_primary_authenticated_id | urlencode) ~ '&tag=' ~\n",
    "      {{ jellyfin_api ~ '/UserImageRead?userId=' ~\n" \
    "         (jellyfin_primary_authenticated_id | urlencode) ~ '&tag=' ~\n"],
   [JELLYFIN_ROLE,
    "      {{ jellyfin_api ~ '/UserImage?userId=' ~\n" \
    "         (jellyfin_verified_primary_user.Id | string | urlencode) ~ '&tag=' ~\n",
    "      {{ jellyfin_api ~ '/UserImageRead?userId=' ~\n" \
    "         (jellyfin_verified_primary_user.Id | string | urlencode) ~ '&tag=' ~\n"]],
  "Jellyfin image upload does not use the supported current endpoint"
)

check_rejected(
  failures, :media_probes, "a server configuration overwrite whose merge moved into a comment",
  [[JELLYFIN_ROLE,
    "    body: >-\n" \
    "      {{ jellyfin_server_configuration_for_update.json |\n" \
    "         combine({'ServerName': jellyfin_server_name}) }}\n",
    "    # {{ jellyfin_server_configuration_for_update.json | combine(...) }}\n" \
    "    body: >-\n" \
    "      {{ {'ServerName': jellyfin_server_name} }}\n"]],
  "Jellyfin server update does not preserve the full configuration"
)

check_rejected(
  failures, :media_probes, "a temporary recovery match whose exact form moved into a comment",
  [[JELLYFIN_ROLE,
    "    jellyfin_primary_temporary_matches: >-\n" \
    "      {{ jellyfin_primary_temporary_matches +\n" \
    "         ([item] if item.Name == jellyfin_primary_temporary_name else []) }}\n",
    "    # ([item] if item.Name == jellyfin_primary_temporary_name else [])\n" \
    "    jellyfin_primary_temporary_matches: >-\n" \
    "      {{ jellyfin_primary_temporary_matches +\n" \
    "         ([item] if item.Name | trim == jellyfin_primary_temporary_name else []) }}\n"]],
  "Jellyfin temporary recovery match is not byte-exact"
)

check_rejected(
  failures, :media_probes, "a primary identity rename with no recovery path",
  [[JELLYFIN_IDENTITY, "  rescue:\n", "  always:\n"]],
  "Jellyfin primary rename is not guarded by block/rescue recovery"
)

check_rejected(
  failures, :media_probes, "image digest comparisons removed from both assertions",
  [[JELLYFIN_ROLE,
    "      - jellyfin_admin_avatar_source_state.stat.checksum == jellyfin_admin_avatar_sha256\n",
    "      - true\n"],
   [JELLYFIN_ROLE,
    "      - jellyfin_verified_admin_avatar_state.stat.checksum == jellyfin_admin_avatar_sha256\n",
    "      - true\n"]],
  "Jellyfin role has no authoritative image byte verification"
)

check(failures,
      File.readlines(VALIDATE_POLICY).include?("ruby tests/contract_structure_mutation_test.rb\n"),
      "contract structure mutation proofs are not registered in the policy suite")

if failures.empty?
  puts "Contract structure mutations: parsed task assertions reject every named shape"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} contract structure mutation failure(s)"
end
