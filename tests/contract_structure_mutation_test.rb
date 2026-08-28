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
  },
  beszel: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "beszel.sh"), "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { "Beszel contract failed: #{message}" }
  },
  audiobookshelf: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "audiobookshelf.sh"), "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { "Audiobookshelf contract failed: #{message}" }
  },
  immich: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "immich.sh"), "--platform", "nas", "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { "Immich contract failed: #{message}" }
  },
  dozzle: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "dozzle.sh"), "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { "Dozzle contract failed: #{message}" }
  },
  # The policy scripts resolve the repository from their own location, so a copy
  # under a temporary directory checks the copy. They report every violation they
  # found rather than aborting on the first, so the expected line has to be
  # present among them rather than be the only one.
  policy: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "policy_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  policy_deployment: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "policy_deployment_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  policy_platform: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "policy_platform_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  # This suite installs the role into a temporary home and runs it, so it is the
  # slowest row here at roughly ten seconds. That is the price of proving the
  # assertions that read the installed artifacts alongside the parsed ones.
  auto_deploy: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "production_auto_deploy_role_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" },
    stream: :stdout
  },
  immich_restore: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "immich_restore_quality_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "Immich restore quality failed: #{message}" }
  }
}.freeze

failures = []

def check(failures, condition, message)
  failures << message unless condition
end

# Every row copies the repository, so the copy is the cost of a proof. Ignored
# paths — the Python virtualenv, worktrees, editor caches — are build artifacts,
# never contract inputs, and copying them costs ten times what copying the
# repository does. `.git` is kept: policy_test.rb enumerates its own sources with
# git and fails without it. If git cannot answer, the whole tree is copied, which
# is only slower.
def ignored_children(children)
  stdout, _stderr, status = Open3.capture3("git", "-C", ROOT, "check-ignore", "--", *children)
  status.exitstatus == 128 ? [] : stdout.lines.map(&:chomp)
rescue SystemCallError
  []
end

def with_copied_repo
  Dir.mktmpdir("nas-platform-contract-structure-") do |directory|
    repo = File.join(directory, "repo")
    FileUtils.mkdir_p(repo)
    children = Dir.children(ROOT)
    (children - ignored_children(children)).each do |entry|
      FileUtils.cp_r(File.join(ROOT, entry), File.join(repo, entry))
    end
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
# Most suites diagnose on stderr; production_auto_deploy_role_test.rb reports on
# stdout, so the stream is part of the suite definition rather than assumed.
def diagnostics(suite, stdout, stderr)
  SUITES.fetch(suite)[:stream] == :stdout ? stdout : stderr
end

# A few diagnostics name the file they are about, which lives under the copy, so
# %REPO% in an expected diagnostic is replaced with the copy's root.
def check_rejected(failures, suite, name, substitutions, diagnostic)
  with_copied_repo do |repo|
    expected = SUITES.fetch(suite).fetch(:diagnostic).call(diagnostic).gsub("%REPO%", File.realpath(repo))
    apply_substitutions(repo, substitutions)
    stdout, stderr, status = run_static(suite, repo)
    reported = diagnostics(suite, stdout, stderr)
    check(failures, !status.success?, "#{suite} contract accepted #{name}")
    check(failures, reported.lines.map(&:chomp).include?(expected),
          "#{suite} contract #{name} diagnostic differs: #{reported.lines.first&.strip}")
  end
rescue RuntimeError, SystemCallError => error
  failures << "#{suite} #{name} mutation fixture failed: #{error.message}"
end

def check_accepted(failures, suite, name, substitutions)
  with_copied_repo do |repo|
    apply_substitutions(repo, substitutions)
    stdout, stderr, status = run_static(suite, repo)
    check(failures, status.success?,
          "#{suite} contract rejected #{name}: #{diagnostics(suite, stdout, stderr).lines.first&.strip}")
  end
rescue RuntimeError, SystemCallError => error
  failures << "#{suite} #{name} fixture failed: #{error.message}"
end

JELLYFIN_ROLE = "roles/jellyfin/tasks/main.yml"
JELLYFIN_IDENTITY = "roles/jellyfin/tasks/primary_identity.yml"
JELLYFIN_SETTINGS = "roles/jellyfin/tasks/settings.yml"
KOMGA_ROLE = "roles/komga/tasks/main.yml"
PAPERLESS_SNAPSHOT = "tests/mac/snapshot-paperless.sh"
PAPERLESS_ROLE = "roles/paperless_ngx/tasks/main.yml"
PAPERLESS_ENVIRONMENT = "roles/paperless_ngx/templates/env.j2"
PAPERLESS_MAC_COMPOSE = "services/paperless-ngx/compose.mac.yml"
GENERATOR = "generate-secrets.yml"
BESZEL_VARS = "roles/beszel/vars/main.yml"
BESZEL_ROLE = "roles/beszel/tasks/main.yml"
AUDIOBOOKSHELF_ROLE = "roles/audiobookshelf/tasks/main.yml"
AUDIOBOOKSHELF_ENVIRONMENT = "roles/audiobookshelf/templates/env.j2"
IMMICH_ROLE = "roles/immich/tasks/main.yml"
IMMICH_RESTORE = "roles/immich/tasks/restore.yml"
IMMICH_ONBOARDING = "roles/immich/tasks/user_onboarding.yml"
DOZZLE_ROLE = "roles/dozzle/tasks/main.yml"
DOZZLE_DEFAULTS = "roles/dozzle/defaults/main.yml"
PREFLIGHT = "roles/preflight/tasks/main.yml"
BUNDLE_INPUTS = "roles/deployment_bundle/tasks/inputs.yml"
BUNDLE_TARGET = "roles/deployment_bundle/tasks/target.yml"
BUNDLE_MANIFEST_TEMPLATE = "roles/deployment_bundle/templates/manifest.yml.j2"
COMPOSE_METADATA_BEHAVIOR = "tests/compose_metadata_filter_test.yml"
AUTO_DEPLOY_ROLE = "roles/production_auto_deploy/tasks/main.yml"
AUTO_DEPLOY_NOTIFIER = "roles/production_auto_deploy/templates/ntfy.curl.j2"

SUITES.each_key do |suite|
  with_copied_repo do |repo|
    stdout, stderr, status = run_static(suite, repo)
    check(failures, status.success?,
          "#{suite} static contract failed on a pristine copy: " \
          "#{diagnostics(suite, stdout, stderr).lines.first&.strip}")
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
  failures, :media_probes, "a library rename that suppresses its identity refresh",
  [[JELLYFIN_ROLE, "'&refreshLibrary=true' }}\n", "'&refreshLibrary=false' }}\n"]],
  "Jellyfin library rename does not request identity refresh"
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

# --- Paperless contract -------------------------------------------------------
#
# `network_mode: !reset null` and `network_mode: null` parse to the same nil, so
# the override's own structure cannot tell them apart. Only the merged effective
# config can, and without the tag the NAS host networking survives into the Mac
# render, which is the one thing the override exists to prevent.
check_rejected(
  failures, :paperless, "a Mac override that lost its reset tag",
  [[PAPERLESS_MAC_COMPOSE, "network_mode: !reset null", "network_mode: null"]],
  "mac effective config did not reset NAS host networking"
)

check_rejected(
  failures, :paperless, "a required task that survives only as a comment",
  [[PAPERLESS_ROLE,
    "- name: Repair the managed Paperless mail rule\n",
    "# - name: Repair the managed Paperless mail rule\n" \
    "- name: Repair the managed Paperless mail rule again\n"]],
  "missing Repair the managed Paperless mail rule"
)

# The snapshot pair has to straddle the probe. Renaming the first half leaves the
# old whole-file substring satisfied twice over, once by the longer name that
# contains it and once by the comparison that still spells both operands.
check_rejected(
  failures, :paperless, "a probe-state snapshot the probe no longer sits between",
  [[PAPERLESS_ROLE,
    "    paperless_managed_mail_probe_state_before:\n",
    "    paperless_managed_mail_probe_state_before_disabled:\n"]],
  "managed account/rule state is not snapshotted around the credential probe"
)

check_rejected(
  failures, :paperless, "a probe-state comparison replaced by a tautology",
  [[PAPERLESS_ROLE,
    "      - paperless_managed_mail_probe_state_before == paperless_managed_mail_probe_state_after\n",
    "      - true\n"]],
  "managed account/rule state is not snapshotted around the credential probe"
)

check_rejected(
  failures, :paperless, "a renamed schema validation task",
  [[PAPERLESS_ROLE,
    "- name: Validate Paperless mail account and rule schemas before mutation\n",
    "- name: Validate Paperless mail account and rule schemas after mutation\n"]],
  "managed mail schema is not validated globally before mutation"
)

check_rejected(
  failures, :paperless, "a schema validation task named only in a comment",
  [[PAPERLESS_ROLE,
    "- name: Validate Paperless mail account and rule schemas before mutation\n",
    "# - name: Validate Paperless mail account and rule schemas before mutation\n" \
    "- name: Validate Paperless mail schemas before mutation\n"]],
  "managed mail schema is not validated globally before mutation"
)

check_rejected(
  failures, :paperless, "a sixth effective state source",
  [[PAPERLESS_ROLE,
    "    paperless_effective_state_host_paths:\n" \
    "      - \"{{ paperless_effective_state_host_path }}/postgres\"\n",
    "    paperless_effective_state_host_paths:\n" \
    "      - \"{{ paperless_effective_state_host_path }}/extra\"\n" \
    "      - \"{{ paperless_effective_state_host_path }}/postgres\"\n"]],
  "Paperless effective state sources do not match the five Compose/env state roots"
)

# A folded scalar carries its line breaks into the parsed value, so a forbidden
# endpoint written across two lines does not match a pattern for the single-line
# form. These two rows are the reason the absence invariants match the
# whitespace-stripped scalar as well: read as source text, both were accepted.
check_rejected(
  failures, :paperless, "a consuming mail endpoint folded across two lines",
  [[PAPERLESS_ROLE,
    "- name: Refuse duplicate managed Paperless mail rules\n",
    "- name: Consume the managed Paperless mail account\n" \
    "  ansible.builtin.uri:\n" \
    "    url: >-\n" \
    "      {{ paperless_api }}/api/mail_accounts/9/\n" \
    "      process/\n" \
    "    method: POST\n" \
    "\n" \
    "- name: Refuse duplicate managed Paperless mail rules\n"]],
  "role must never invoke the consuming mail endpoint"
)

check_rejected(
  failures, :paperless, "a global task-count endpoint folded across two lines",
  [[PAPERLESS_ROLE,
    "- name: Refuse duplicate managed Paperless mail accounts\n",
    "- name: Count global Paperless tasks\n" \
    "  ansible.builtin.uri:\n" \
    "    url: >-\n" \
    "      {{ paperless_api }}/api/\n" \
    "      tasks/\n" \
    "    method: GET\n" \
    "\n" \
    "- name: Refuse duplicate managed Paperless mail accounts\n"]],
  "mail probe must not inspect global processed-mail or task counts"
)

check_rejected(
  failures, :paperless, "a generator that synthesizes the Gmail app password",
  [[GENERATOR,
    "    paperless_gmail_app_password: replace-with-google-app-password\n",
    "    paperless_gmail_app_password: \"{{ lookup('password', password_spec) }}\"\n"]],
  "Gmail app password must be a visible sentinel in the new-platform generator"
)

check_rejected(
  failures, :paperless, "a generator sentinel that survives only as a comment",
  [[GENERATOR,
    "    paperless_gmail_app_password: replace-with-google-app-password\n",
    "    # paperless_gmail_app_password: replace-with-google-app-password\n" \
    "    paperless_gmail_app_password: hunter2hunter2\n"]],
  "Gmail app password must be a visible sentinel in the new-platform generator"
)

# Google displays the app password in groups of four. Stripping the spaces in one
# of the two places it is consumed and not the other left the old whole-file
# substring satisfied by whichever one still did it.
check_rejected(
  failures, :paperless, "grouped app-password spacing kept out of the payload only",
  [[PAPERLESS_ROLE,
    "           'password': vault_paperless_gmail_app_password | replace(' ', ''),\n",
    "           'password': vault_paperless_gmail_app_password,\n"]],
  "role must accept Google's grouped app-password display"
)

check_rejected(
  failures, :paperless, "grouped app-password spacing kept out of the fingerprint only",
  [[PAPERLESS_ROLE,
    "          (vault_paperless_gmail_app_password | replace(' ', ''))) | hash('sha256') }}\n",
    "          vault_paperless_gmail_app_password) | hash('sha256') }}\n"]],
  "role must accept Google's grouped app-password display"
)

check_rejected(
  failures, :paperless, "one host-network endpoint that stops covering integration",
  [[PAPERLESS_ENVIRONMENT,
    "PAPERLESS_TIKA_ENDPOINT=http://{{ '127.0.0.1' if platform_compose_kind in " \
    "['nas', 'integration'] else 'tika' }}:9998\n",
    "PAPERLESS_TIKA_ENDPOINT=http://{{ '127.0.0.1' if platform_compose_kind == " \
    "'nas' else 'tika' }}:9998\n"]],
  "host-network endpoint selection must cover NAS and integration for PAPERLESS_TIKA_ENDPOINT"
)

# Compose reads the last assignment of a name, so an appended unescaped duplicate
# is the live one. A substring check for the escaped form still found the earlier
# line and passed.
check_rejected(
  failures, :paperless, "an unescaped secret assignment appended after the escaped one",
  [[PAPERLESS_ENVIRONMENT,
    "PAPERLESS_AI_LLM_MODEL={{ paperless_ai_llm_model }}\n",
    "PAPERLESS_AI_LLM_MODEL={{ paperless_ai_llm_model }}\n" \
    "PAPERLESS_ADMIN_PASSWORD={{ vault_paperless_admin_password }}\n"]],
  "vault_paperless_admin_password is not protected from Compose interpolation"
)

check_rejected(
  failures, :paperless, "an escaping filter dropped from the admin password",
  [[PAPERLESS_ENVIRONMENT,
    "PAPERLESS_ADMIN_PASSWORD={{ vault_paperless_admin_password | replace('$', '$$') }}\n",
    "PAPERLESS_ADMIN_PASSWORD={{ vault_paperless_admin_password }}\n"]],
  "vault_paperless_admin_password is not protected from Compose interpolation"
)

# --- Immich restore quality ---------------------------------------------------

check_rejected(
  failures, :immich_restore, "a sanitized refusal code that survives only as a comment",
  [[IMMICH_ROLE,
    "             'incompatible-newest-backup',\n",
    "             # 'incompatible-newest-backup',\n"]],
  "incompatible newest backup diagnostic is not sanitized"
)

check_rejected(
  failures, :immich_restore, "a different refusal code dropped from the sanitized list",
  [[IMMICH_ROLE,
    "             ['unsafe-storage', 'unsafe-originals', 'missing-safe-backup',\n",
    "             ['unsafe-storage', 'missing-safe-backup',\n"]],
  "incompatible newest backup diagnostic is not sanitized"
)

check_rejected(
  failures, :immich_restore, "a real DELETE folded across two lines",
  [[IMMICH_RESTORE,
    "            SELECT json_build_object(\n",
    "            DELETE\n            FROM asset;\n            SELECT json_build_object(\n"]],
  "restore verification mutates an application table"
)

check_rejected(
  failures, :immich_restore, "a task that removes the restore provenance marker",
  [[IMMICH_RESTORE,
    "  rescue:\n",
    "  always:\n" \
    "    - name: Remove the Immich restore failure marker\n" \
    "      ansible.builtin.file:\n" \
    "        path: \"{{ immich_restore_effective_failure_marker }}\"\n" \
    "        state: absent\n" \
    "\n" \
    "  rescue:\n"]],
  "restore removes provenance before server initialization"
)

check_rejected(
  failures, :immich_restore, "a migration marker check deleted but kept in a comment",
  [[IMMICH_RESTORE,
    "            'schemaMarker', to_regclass('public.kysely_migrations') IS NOT NULL,\n",
    "            # public.kysely_migrations\n            'schemaMarker', true,\n"]],
  "restore does not verify the pinned v3 migration marker"
)

# Two stages sharing one label makes the marker ambiguous about which phase
# failed, which is the whole point of recording it. Both labels were still
# present as substrings, so the old form could not see it.
check_rejected(
  failures, :immich_restore, "two failure stages collapsed onto one label",
  [[IMMICH_RESTORE,
    "        immich_restore_stage: database-verification\n",
    "        immich_restore_stage: database-restore\n"]],
  "restore failures do not preserve a sanitized marker stage"
)

check_rejected(
  failures, :immich_restore, "a rescue marker that stops recording the stage it reached",
  [[IMMICH_RESTORE,
    "          {{ {'version': 1, 'stage': (immich_restore_stage | default('restore'))} | to_json }}\n",
    "          {{ {'version': 1, 'stage': 'restore'} | to_json }}\n"]],
  "restore failures do not preserve a sanitized marker stage"
)

# The other direction. Both of these are shapes the source-text form rejected as
# violations that did not exist: a comment is not a statement and not a task.
check_accepted(
  failures, :immich_restore, "a comment warning against DELETE",
  [[IMMICH_RESTORE,
    "  rescue:\n",
    "  # The restore never issues DELETE or TRUNCATE against an application table.\n  rescue:\n"]]
)

check_accepted(
  failures, :immich_restore, "the provenance-removal task named only in a comment",
  [[IMMICH_RESTORE,
    "  rescue:\n",
    "  # Deliberately no 'Remove the Immich restore failure marker' task here.\n  rescue:\n"]]
)

# --- Beszel contract ----------------------------------------------------------

check_rejected(
  failures, :beszel, "a required task that survives only as a comment",
  [[BESZEL_ROLE,
    "    - name: Poll persisted Beszel telemetry collections\n",
    "    # - name: Poll persisted Beszel telemetry collections\n" \
    "    - name: Poll persisted Beszel telemetry collections twice\n"]],
  "missing Poll persisted Beszel telemetry collections"
)

# #85's headline for this contract: the old form passed with the register deleted,
# because the variable's name still appeared elsewhere in the file.
check_rejected(
  failures, :beszel, "a telemetry poll that no longer registers its probe result",
  [[BESZEL_ROLE,
    "      register: beszel_telemetry_probe_result\n",
    "      changed_when: false\n"]],
  "role treats live health as persisted telemetry"
)

check_rejected(
  failures, :beszel, "a GPU inference reintroduced with different spacing",
  [[BESZEL_VARS,
    "beszel_effective_required_telemetry_categories: >-\n" \
    "  {{ ['core', 'disk', 'containers']\n",
    "beszel_effective_required_telemetry_categories: >-\n" \
    "  {{ (['gpu'] if beszel_require_gpu_telemetry|bool else []) + ['core', 'disk', 'containers']\n"]],
  "effective categories must use explicit inventory policy"
)

# --- Audiobookshelf contract --------------------------------------------------

check_rejected(
  failures, :audiobookshelf, "a duplicate backup path assignment appended to the env file",
  [[AUDIOBOOKSHELF_ENVIRONMENT,
    "AUDIOBOOKSHELF_BACKUP_PATH={{ audiobookshelf_effective_backup_host_path }}\n",
    "AUDIOBOOKSHELF_BACKUP_PATH={{ audiobookshelf_effective_backup_host_path }}\n" \
    "AUDIOBOOKSHELF_BACKUP_PATH=/volume1/Docker/audiobookshelf/backups\n"]],
  "backup environment is absent"
)

check_rejected(
  failures, :audiobookshelf, "a required task that survives only as a comment",
  [[AUDIOBOOKSHELF_ROLE,
    "- name: Require exactly the managed Audiobookshelf library\n",
    "# - name: Require exactly the managed Audiobookshelf library\n" \
    "- name: Require exactly the managed Audiobookshelf libraries\n"]],
  "missing Require exactly the managed Audiobookshelf library"
)

# --- Immich contract ----------------------------------------------------------

check_rejected(
  failures, :immich, "a required task that survives only as a comment",
  [[IMMICH_ROLE,
    "- name: Read Immich initialization state\n",
    "# - name: Read Immich initialization state\n" \
    "- name: Read Immich initialization states\n"]],
  "missing Read Immich initialization state"
)

check_rejected(
  failures, :immich, "a Docker API exec reintroduced as a task module",
  [[IMMICH_ROLE,
    "- name: Read Immich initialization state\n",
    "- name: Reach into the Immich database directly\n" \
    "  community.docker.docker_container_exec:\n" \
    "    container: immich_postgres\n" \
    "    command: /bin/true\n" \
    "\n" \
    "- name: Read Immich initialization state\n"]],
  "role must not use the Docker API exec module"
)

check_rejected(
  failures, :immich, "an opaque container variable reintroduced in a task",
  [[IMMICH_ROLE,
    "- name: Read Immich initialization state\n",
    "- name: Report the opaque Immich container\n" \
    "  ansible.builtin.debug:\n" \
    "    msg: \"{{ immich_postgres_container }}\"\n" \
    "\n" \
    "- name: Read Immich initialization state\n"]],
  "role still references immich_postgres_container"
)

check_rejected(
  failures, :immich, "an onboarding task that shells into psql",
  [[IMMICH_ONBOARDING,
    "- name: Initialize configured Immich onboarding accounts\n",
    "- name: Patch the Immich onboarding rows\n" \
    "  ansible.builtin.command:\n" \
    "    argv: [psql, --command, 'SELECT 1']\n" \
    "  changed_when: false\n" \
    "\n" \
    "- name: Initialize configured Immich onboarding accounts\n"]],
  "Immich user onboarding role contains a database write path"
)

# --- Dozzle contract ----------------------------------------------------------
#
# The dispatcher header is the whole of "the role wires the write-only ntfy
# token", so this row is what the deleted second substring check was pretending
# to prove.
check_rejected(
  failures, :dozzle, "a dispatcher header that borrows another publisher's token",
  [[DOZZLE_DEFAULTS,
    "Bearer {{ vault_ntfy_dozzle_token }}",
    "Bearer {{ vault_ntfy_deploy_token }}"]],
  "managed dispatcher authorization differs"
)

# --- Repository policy --------------------------------------------------------

check_rejected(
  failures, :policy, "a planned-change task that survives only as a comment",
  [[DOZZLE_ROLE,
    "- name: Report planned managed Dozzle dispatcher creation\n",
    "# - name: Report planned managed Dozzle dispatcher creation\n" \
    "- name: Report planned managed Dozzle dispatcher creations\n"]],
  "Dozzle must expose every REST mutation category as a check-mode planned change"
)

# The old pair of substring checks never had to describe the same task: the count
# matched any line spelling the include, and the service name could come from
# anywhere else in the file.
check_rejected(
  failures, :policy, "a container CPU include that names another service",
  [[BESZEL_ROLE,
    "    container_cpu_service_name: beszel\n",
    "    container_cpu_service_name: dozzle\n"]],
  "beszel: role must verify its effective container CPU policy exactly once"
)

# The window this replaced was 120 characters wide, so a shell-out that named the
# module further down its own argument list was past the end of it.
check_rejected(
  failures, :policy, "a Compose shell-out past the end of the old scan window",
  [[BESZEL_ROLE,
    "- name: Wait for the hub to report healthy\n",
    "- name: Restart the Beszel stack by hand\n" \
    "  ansible.builtin.command:\n" \
    "    argv:\n" \
    "      - /bin/sh\n" \
    "      - -c\n" \
    "      - >-\n" \
    "        cd /volume1/Docker/beszel && printf '%s\\n' 'padding padding padding padding' &&\n" \
    "        printf '%s\\n' 'padding padding padding padding' && docker compose up -d\n" \
    "  changed_when: false\n" \
    "\n" \
    "- name: Wait for the hub to report healthy\n"]],
  "%REPO%/roles/beszel/tasks/main.yml: shells out to Compose; use community.docker.docker_compose_v2"
)

# --- Deployment bundle policy -------------------------------------------------
#
# The inputs the role validates are the paths its controller_input.yml inclusions
# name. The old whole-file substring could not tell a validated path from a path
# mentioned in a comment, so deleting the canonical Compose validation outright
# left the check passing as long as the words survived somewhere in the file.
check_rejected(
  failures, :policy_deployment, "canonical Compose validation deleted with its path left in a comment",
  [[BUNDLE_INPUTS,
    "- name: Validate canonical controller Compose inputs\n" \
    "  ansible.builtin.include_tasks: controller_input.yml\n" \
    "  vars:\n" \
    "    deployment_controller_input_path: >-\n" \
    "      {{ playbook_dir }}/services/{{ deployment_controller_service.name }}/compose.yml\n" \
    "    deployment_controller_input_allow_missing: false\n",
    "# deployment_controller_input_path: services/<name>/compose.yml\n" \
    "- name: Assume canonical controller Compose inputs are fine\n" \
    "  ansible.builtin.debug:\n" \
    "    msg: canonical compose validation removed\n"]],
  "controller inputs must validate manifest, canonical Compose, and platform overrides"
)

check_rejected(
  failures, :policy_deployment, "a runtime helper input no longer handed to the validator",
  [[BUNDLE_INPUTS,
    "    deployment_controller_input_path: \"{{ playbook_dir }}/services/dozzle/alert_relay.py\"\n",
    "    deployment_controller_input_path: \"{{ playbook_dir }}/services/dozzle/alert_relay.py.bak\"\n"]],
  "controller inputs must validate every tracked runtime helper"
)

# The leaf moves out of the expression the command evaluates and into a comment
# beside it. The file still contains the words; the validator no longer sees the
# path.
check_rejected(
  failures, :policy_deployment, "a guarded leaf demoted to a comment beside the batch",
  [[BUNDLE_TARGET,
    "    deployment_target_paths: >-\n" \
    "      {{ [nas_docker_root,\n" \
    "          nas_docker_root ~ '/.nas-platform-preflight-probe',\n",
    "    # nas_docker_root ~ '/.nas-platform-preflight-probe' is no longer guarded\n" \
    "    deployment_target_paths: >-\n" \
    "      {{ [nas_docker_root,\n"]],
  "target validator must guard the exact preflight probe leaf"
)

check_rejected(
  failures, :policy_deployment, "the runtime service leaves dropped from the batch",
  [[BUNDLE_TARGET,
    "         + (deployment_bundle_services | default([])\n" \
    "            | map(attribute='name')\n" \
    "            | map('regex_replace', '^', platform_runtime_dir ~ '/services/')\n" \
    "            | list) }}\n",
    "         }}\n"]],
  "target validator must guard every implemented runtime service leaf"
)

check_rejected(
  failures, :policy_deployment, "a behavior proof renamed while its old name stays in a comment",
  [[COMPOSE_METADATA_BEHAVIOR,
    "    - name: Require unknown YAML tags to fail closed\n",
    "    # Require unknown YAML tags to fail closed\n" \
    "    - name: Tolerate unknown YAML tags\n"]],
  "policy validation must execute Compose metadata parser behavior tests"
)

check_rejected(
  failures, :policy_deployment, "the manifest's platform inputs key renamed",
  [[BUNDLE_MANIFEST_TEMPLATE, "platform_inputs:\n", "platform_input:\n"]],
  "deployment manifest must bind the exact acquisition catalog path, mode, and checksum"
)

# The byte-offset form this replaced compared the first occurrence of each key
# anywhere in the file, so a comment naming the later key sorted ahead of the key
# itself and failed a template that renders in exactly the required order.
check_accepted(
  failures, :policy_deployment, "a template comment naming a key that renders later",
  [[BUNDLE_MANIFEST_TEMPLATE,
    "---\n",
    "---\n{# platform_inputs is rendered before services: below #}\n"]]
)

# --- Platform policy ----------------------------------------------------------

check_rejected(
  failures, :policy_platform, "a capacity probe whose result nothing is derived from",
  [[PREFLIGHT,
    "  register: preflight_docker_info\n",
    "  register: preflight_docker_capacity_unused\n"]],
  "preflight must derive the effective container CPU set from Docker capacity"
)

# The old pair only ruled out the one wrong path that had been used before, so any
# other divergent path satisfied it.
check_rejected(
  failures, :policy_platform, "one probe task pointed at a divergent path",
  [[PREFLIGHT,
    "    paths: \"{{ nas_docker_root }}/.nas-platform-preflight-probe\"\n",
    "    paths: \"{{ platform_deploy_root }}/.nas-platform-preflight-probe\"\n"]],
  "fresh-install preflight must probe the existing validated nas_docker_root"
)

# --- Production auto-deploy role ----------------------------------------------
#
# These two rows install and run the role, so they are the slowest here at about
# ten seconds each. The first is #85's headline find: the probe could be deleted
# outright and the old whole-file substring still passed, because the same path
# appears in the poller's own command line and in a fail_msg.
check_rejected(
  failures, :auto_deploy, "a virtualenv probe deleted while its path stays in the command line",
  [[AUTO_DEPLOY_ROLE,
    "- name: Require the controller virtualenv the poller runs Ansible from\n" \
    "  ansible.builtin.stat:\n" \
    "    path: \"{{ production_auto_deploy_checkout }}/.venv/bin/ansible-playbook\"\n" \
    "  register: production_auto_deploy_tooling\n",
    "- name: Assume the controller virtualenv is present\n" \
    "  ansible.builtin.set_fact:\n" \
    "    production_auto_deploy_tooling: {stat: {exists: true}}\n"]],
  "the role must verify the controller virtualenv before installing"
)

# curl sends every header directive it is given, so two Authorization directives
# are two credentials presented on one request. The old pair named one variable to
# require and one to forbid, and neither said anything about how many times the
# required one appears; the rendered-artifact check two dozen lines below cannot
# see it either, because a file carrying the token twice still contains it.
check_rejected(
  failures, :auto_deploy, "a duplicated Authorization directive",
  [[AUTO_DEPLOY_NOTIFIER,
    "header = \"Authorization: Bearer {{ vault_ntfy_deploy_token }}\"\n",
    "header = \"Authorization: Bearer {{ vault_ntfy_deploy_token }}\"\n" \
    "header = \"Authorization: Bearer {{ vault_ntfy_deploy_token }}\"\n"]],
  "the ntfy.curl config must present exactly the deploy publisher's own bearer token"
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
