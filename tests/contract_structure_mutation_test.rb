#!/usr/bin/env ruby
# Mutation proofs for the contract assertions that read parsed task structure: each
# row breaks one thing in a copy of the repository and requires the contract to name
# it. Rows marked accepted are shapes the old source-text assertions judged wrongly.

require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "case_pool_support"
require_relative "policy_support"

include TestScaffold

VALIDATE_POLICY = File.join(ROOT, "tests", "validate-policy.sh")
# MEDIA_MANAGED_USERS_PROBES selects no probe group, leaving only the static role
# assertions and keeping a row under a second.
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
  # Policy scripts check the copy they sit in and report every violation, so the
  # expected line need only be among them.
  policy: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "policy_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  # Reports every violation, each line prefixed (#352).
  arr: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "arr.sh"), "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { "Arr contract failed: #{message}" }
  },
  # Drives the real vault_contract role (~20s a row), so only three rows.
  managed_users_vault: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "managed_users_vault_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  downloaders: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "downloaders.sh"), "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { "Downloaders contract failed: #{message}" }
  },
  policy_deployment: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "policy_deployment_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  reader_identity: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "reader_platform_identity_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  acquisition_phase1: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "media_acquisition_phase1_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { message }
  },
  acquisition_adoption: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "media_acquisition_adoption_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { message }
  },
  policy_integration: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "policy_integration_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  policy_mac: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "policy_mac_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  policy_vault: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "policy_vault_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  policy_platform: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "policy_platform_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  # Installs and runs the role in a temporary home (~10s a row).
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

# Ignored paths are never contract inputs and dominate the copy cost. `.git` is kept:
# policy_test.rb enumerates its sources with git. Without git, the whole tree is copied.
def ignored_children(children)
  stdout, _stderr, status = Open3.capture3("git", "-C", ROOT, "check-ignore", "--", *children)
  status.exitstatus == 128 ? [] : stdout.lines.map(&:chomp)
rescue SystemCallError
  []
end

# One copy per pool worker, reused: a row restores the paths it substituted, and the
# tree is hashed after every row so a contaminated copy is discarded and rebuilt.
# `.git` is excluded from the hash (git writes there) but kept in the copy.
COPY_ACCOUNTING = { copies: 0, rows: 0, rebuilt: [] }
# Guards the shared accounting only; each worker's copy is thread-local.
ACCOUNTING_LOCK = Mutex.new
PRISTINE_DIRECTORIES = []

def tree_manifest(repo)
  Dir.glob("**/*", File::FNM_DOTMATCH, base: repo).each_with_object({}) do |relative, manifest|
    next if File.basename(relative) == "." || File.basename(relative) == ".."
    next if relative == ".git" || relative.start_with?(".git/")

    path = File.join(repo, relative)
    stat = File.lstat(path)
    manifest[relative] =
      if stat.symlink?
        "link:#{File.readlink(path)}"
      elsif stat.directory?
        "directory"
      else
        format("file:%<mode>o:%<digest>s", mode: stat.mode & 0o7777,
                                           digest: Digest::SHA256.file(path).hexdigest)
      end
  end
end

def discard_repo
  state = Thread.current[:pristine]
  return unless state

  FileUtils.remove_entry(state[:directory])
  ACCOUNTING_LOCK.synchronize { PRISTINE_DIRECTORIES.delete(state[:directory]) }
  Thread.current[:pristine] = nil
end
# Removal is not rescued: a leaked copy of the repository should fail loudly.
at_exit do
  ACCOUNTING_LOCK.synchronize { PRISTINE_DIRECTORIES.dup }.each do |directory|
    FileUtils.remove_entry(directory)
  end
end

def pristine_repo
  existing = Thread.current[:pristine]
  return existing if existing

  directory = Dir.mktmpdir("nas-platform-contract-structure-")
  repo = File.join(directory, "repo")
  FileUtils.mkdir_p(repo)
  children = Dir.children(ROOT)
  (children - ignored_children(children)).each do |entry|
    FileUtils.cp_r(File.join(ROOT, entry), File.join(repo, entry))
  end
  state = { directory: directory, repo: repo, manifest: tree_manifest(repo) }
  Thread.current[:pristine] = state
  ACCOUNTING_LOCK.synchronize do
    PRISTINE_DIRECTORIES << directory
    COPY_ACCOUNTING[:copies] += 1
  end
  state
end

def with_copied_repo(mutated = [], label = nil)
  state = pristine_repo
  repo = state[:repo]
  ACCOUNTING_LOCK.synchronize { COPY_ACCOUNTING[:rows] += 1 }
  begin
    yield repo
  ensure
    mutated.each do |relative_path|
      FileUtils.cp(File.join(ROOT, relative_path), File.join(repo, relative_path))
    end
    unless tree_manifest(repo) == state[:manifest]
      ACCOUNTING_LOCK.synchronize { COPY_ACCOUNTING[:rebuilt] << (label || "unnamed row") }
      discard_repo
    end
  end
end

# No __pycache__ from Ansible, so any other byte a suite writes counts as contamination.
def run_static(suite, repo)
  definition = SUITES.fetch(suite)
  environment = { "PYTHONDONTWRITEBYTECODE" => "1" }.merge(definition.fetch(:environment).call(repo))
  Open3.capture3(environment, *definition.fetch(:command).call(repo))
end

# Each substitution must match exactly once, or a drifted row would prove nothing.
def apply_substitutions(repo, substitutions)
  substitutions.each do |relative_path, original, replacement|
    path = File.join(repo, relative_path)
    body = File.read(path)
    occurrences = body.scan(original).length
    raise "#{relative_path} fixture differs: #{occurrences} matches" unless occurrences == 1

    File.write(path, body.sub(original, replacement))
  end
end

# Contract suites abort on the first violation; the probe suite reports all.
# production_auto_deploy_role_test.rb reports on stdout, the rest on stderr.
def diagnostics(suite, stdout, stderr)
  SUITES.fetch(suite)[:stream] == :stdout ? stdout : stderr
end

# Rows queue here and the pool at the foot of the file runs them, concatenating
# failures in written order; so a row may name a constant declared further down.
ROWS = []

# %REPO% in an expected diagnostic is replaced with the copy's root.
def check_rejected(suite, name, substitutions, diagnostic)
  ROWS << ->(failures) { rejected_row(failures, suite, name, substitutions, diagnostic) }
end

def check_accepted(suite, name, substitutions)
  ROWS << ->(failures) { accepted_row(failures, suite, name, substitutions) }
end

def rejected_row(failures, suite, name, substitutions, diagnostic)
  with_copied_repo(substitutions.map(&:first), "#{suite} #{name}") do |repo|
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

def accepted_row(failures, suite, name, substitutions)
  with_copied_repo(substitutions.map(&:first), "#{suite} #{name}") do |repo|
    apply_substitutions(repo, substitutions)
    stdout, stderr, status = run_static(suite, repo)
    check(failures, status.success?,
          "#{suite} contract rejected #{name}: #{diagnostics(suite, stdout, stderr).lines.first&.strip}")
  end
rescue RuntimeError, SystemCallError => error
  failures << "#{suite} #{name} fixture failed: #{error.message}"
end

# Roles split one stage per file: a row names the stage that owns the text it breaks.
JELLYFIN_DEPLOY = "roles/jellyfin/tasks/deploy.yml"
JELLYFIN_AUTHENTICATION = "roles/jellyfin/tasks/authentication.yml"
JELLYFIN_PREFLIGHT = "roles/jellyfin/tasks/preflight.yml"
JELLYFIN_IDENTITY = "roles/jellyfin/tasks/identity.yml"
JELLYFIN_LIBRARIES = "roles/jellyfin/tasks/libraries.yml"
JELLYFIN_VERIFY = "roles/jellyfin/tasks/verify.yml"
# The rename helper identity.yml calls, not the stage above it.
JELLYFIN_PRIMARY_IDENTITY = "roles/jellyfin/tasks/primary_identity.yml"
JELLYFIN_SETTINGS = "roles/jellyfin/tasks/settings.yml"
KOMGA_ROLE = "roles/komga/tasks/main.yml"
# The coordinated snapshot is the program, not the wrapper beside it, since #315.
PAPERLESS_SNAPSHOT = "tests/mac/snapshot-paperless.rb"
PAPERLESS_STORAGE = "roles/paperless_ngx/tasks/storage.yml"
PAPERLESS_MAIL_STATE = "roles/paperless_ngx/tasks/mail_state.yml"
PAPERLESS_MAIL_PROBE = "roles/paperless_ngx/tasks/mail_probe.yml"
PAPERLESS_MAIL_RECONCILE = "roles/paperless_ngx/tasks/mail_reconcile.yml"
PAPERLESS_ENVIRONMENT = "roles/paperless_ngx/templates/env.j2"
PAPERLESS_COMPOSE = "services/paperless-ngx/compose.yml"
PAPERLESS_MAC_COMPOSE = "services/paperless-ngx/compose.mac.yml"
GENERATOR = "generate-secrets.yml"
BESZEL_VARS = "roles/beszel/vars/main.yml"
BESZEL_DEPLOY = "roles/beszel/tasks/deploy.yml"
BESZEL_APPLICATION_USER = "roles/beszel/tasks/application_user.yml"
BESZEL_CONFIGURE = "roles/beszel/tasks/configure.yml"
AUDIOBOOKSHELF_MAIN = "roles/audiobookshelf/tasks/main.yml"
AUDIOBOOKSHELF_VERIFY = "roles/audiobookshelf/tasks/verify.yml"
AUDIOBOOKSHELF_ENVIRONMENT = "roles/audiobookshelf/templates/env.j2"
IMMICH_ROLE = "roles/immich/tasks/main.yml"
IMMICH_RESTORE = "roles/immich/tasks/restore.yml"
IMMICH_ONBOARDING = "roles/immich/tasks/user_onboarding.yml"
DOZZLE_ROLE = "roles/dozzle/tasks/main.yml"
DOZZLE_DEFAULTS = "roles/dozzle/defaults/main.yml"
DOZZLE_ENV = "roles/dozzle/templates/env.j2"
PREFLIGHT = "roles/preflight/tasks/main.yml"
ARR_MAIN = "roles/arr/tasks/main.yml"
ARR_BOOTSTRAP = "roles/arr/tasks/bootstrap.yml"
ARR_CONFIG_XML = "roles/arr/templates/config.xml.j2"
ARR_ENVIRONMENT = "roles/arr/templates/env.j2"
ARR_SERVARR = "roles/arr/tasks/reconcile_servarr.yml"
ARR_PROWLARR = "roles/arr/tasks/reconcile_prowlarr.yml"
ARR_BAZARR = "roles/arr/tasks/reconcile_bazarr.yml"
ARR_BAZARR_FILTER = "filter_plugins/acquisition_bazarr.py"
KOMGA_COMPOSE = "services/komga/compose.yml"
DOWNLOADERS_COMPOSE = "services/downloaders/compose.yml"
ARR_STATE_GUARD = "roles/arr/tasks/state_guard.yml"
MAC_PATH_FIXTURE = "tests/mac_inventory_path_test.yml"
SHARED_INVENTORY = "inventory/group_vars/all/main.yml"
HOST_PREP = "roles/host_prep/tasks/main.yml"
VERIFY_PLAY = "verify.yml"
CI_WORKFLOW = ".github/workflows/ci.yml"
# Relative: a substitution names the path inside the copied tree.
POLICY_GATE = "tests/validate-policy.sh"
VAULT_CONTRACT = "roles/vault_contract/tasks/main.yml"
DOWNLOADERS_MAIN = "roles/downloaders/tasks/main.yml"
DOWNLOADERS_ENVIRONMENT = "roles/downloaders/templates/env.j2"
DOWNLOADERS_INI = "roles/downloaders/templates/sabnzbd.ini.j2"
DOWNLOADERS_VERIFY = "roles/downloaders/tasks/verify.yml"
BUNDLE_INPUTS = "roles/deployment_bundle/tasks/inputs.yml"
BUNDLE_TARGET = "roles/deployment_bundle/tasks/target.yml"
BUNDLE_MANIFEST_TEMPLATE = "roles/deployment_bundle/templates/manifest.yml.j2"
COMPOSE_METADATA_BEHAVIOR = "tests/compose_metadata_filter_test.yml"
AUTO_DEPLOY_ROLE = "roles/production_auto_deploy/tasks/main.yml"
AUTO_DEPLOY_PUSHOVER_NOTIFIER = "roles/production_auto_deploy/templates/pushover.curl.j2"

SUITES.each_key do |suite|
  ROWS << lambda do |collected|
    with_copied_repo([], "#{suite} pristine baseline") do |repo|
      stdout, stderr, status = run_static(suite, repo)
      check(collected, status.success?,
            "#{suite} static contract failed on a pristine copy: " \
            "#{diagnostics(suite, stdout, stderr).lines.first&.strip}")
    end
  end
end

check_rejected(
  :jellyfin, "a required task that survives only as a comment",
  [[JELLYFIN_VERIFY,
    "- name: Verify exact Jellyfin owned state\n",
    "# - name: Verify exact Jellyfin owned state\n" \
    "- name: Verify exact Jellyfin owned state after rename\n"]],
  "missing Verify exact Jellyfin owned state"
)

check_rejected(
  :jellyfin, "a mutation task declared before the identity preflight",
  [[JELLYFIN_DEPLOY,
    "- name: Wait for the Jellyfin startup API\n",
    "- name: Update the Jellyfin server name\n" \
    "  ansible.builtin.debug:\n" \
    "    msg: jellyfin-early-mutation\n" \
    "\n" \
    "- name: Wait for the Jellyfin startup API\n"]],
  "all identity/library preflight must precede mutation"
)

check_rejected(
  :jellyfin, "a DELETE verb that belongs to an unrelated request",
  [[JELLYFIN_LIBRARIES, "    method: DELETE\n", "    method: POST\n"],
   [JELLYFIN_VERIFY,
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
  :jellyfin, "an unconditional avatar upload beside conditional siblings",
  [[JELLYFIN_IDENTITY,
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
  :jellyfin, "a server configuration overwrite whose merge moved into a comment",
  [[JELLYFIN_IDENTITY,
    "    body: >-\n" \
    "      {{ jellyfin_server_configuration_for_update.json |\n" \
    "         combine({'ServerName': jellyfin_server_name}) }}\n",
    "    # {{ jellyfin_server_configuration_for_update.json | combine(...) }}\n" \
    "    body: >-\n" \
    "      {{ {'ServerName': jellyfin_server_name} }}\n"]],
  "server configuration update does not preserve unrelated fields"
)

check_rejected(
  :jellyfin, "an opaque database reference in an unscoped task",
  [[JELLYFIN_IDENTITY,
    "    msg: JELLYFIN_PLAN_SERVER_NAME\n",
    "    msg: JELLYFIN_PLAN_SERVER_NAME jellyfin.db\n"]],
  "role must not edit an opaque database"
)

check_rejected(
  :jellyfin, "a version pin folded across the plugin install URL",
  [[JELLYFIN_SETTINGS,
    "         '&repositoryUrl=' ~ (item.RepositoryUrl | urlencode) }}\n",
    "         '&repositoryUrl=' ~ (item.RepositoryUrl | urlencode) ~\n" \
    "         '&version=1.0' }}\n"]],
  "plugin install must not supply a version"
)

check_rejected(
  :jellyfin, "a package catalog preflight against a different endpoint",
  [[JELLYFIN_SETTINGS,
    "    url: \"{{ jellyfin_api }}/Packages\"\n",
    "    url: \"{{ jellyfin_api }}/PackagesCatalog\"\n"]],
  "compatible package catalog preflight is absent"
)

check_rejected(
  :jellyfin, "a recovery marker read that no longer requires private mode",
  [[JELLYFIN_AUTHENTICATION,
    "      - not jellyfin_primary_recovery_marker_state.stat.exists or\n" \
    "        jellyfin_primary_recovery_marker_state.stat.mode == '0600'\n",
    "      - true\n"]],
  "recovery marker privacy is not checked before reading"
)

check_rejected(
  :jellyfin, "a primary identity rename with no recovery path",
  [[JELLYFIN_PRIMARY_IDENTITY, "  rescue:\n", "  always:\n"]],
  "primary identity rename lacks recovery"
)

check_accepted(
  :jellyfin, "a package catalog URL that changed only its quoting style",
  [[JELLYFIN_SETTINGS,
    "    url: \"{{ jellyfin_api }}/Packages\"\n",
    "    url: '{{ jellyfin_api }}/Packages'\n"]]
)

# A byte offset is not a task position: a task name in a comment ahead of the
# preflight used to read as a phase violation.
check_accepted(
  :jellyfin, "a mutation task name mentioned in an early comment",
  [[JELLYFIN_DEPLOY,
    "- name: Wait for the Jellyfin startup API\n",
    "# - name: Update the Jellyfin server name\n" \
    "- name: Wait for the Jellyfin startup API\n"]]
)

check_accepted(
  :komga, "a mutation task name mentioned in an early comment",
  [[KOMGA_ROLE,
    "- name: Deploy Komga, catching a container that runs but never serves\n",
    "# - name: Create the managed Komga library\n" \
    "- name: Deploy Komga, catching a container that runs but never serves\n"]]
)

check_rejected(
  :komga, "a required task that survives only as a comment",
  [[KOMGA_ROLE,
    "- name: Require exact reconciled Komga library\n",
    "# - name: Require exact reconciled Komga library\n" \
    "- name: Require exact reconciled Komga libraries\n"]],
  "missing Require exact reconciled Komga library"
)

check_rejected(
  :komga, "a mutation task declared before the library preflight",
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
  :komga, "a normalized root fact that dropped its trailing-slash filter",
  [[KOMGA_ROLE,
    "           'normalized_root': item.root | default('', true) | string | regex_replace('/+$', ''),\n",
    "           'normalized_root': item.root | default('', true) | string,\n"]],
  "managed root matching is not trailing-slash normalized"
)

check_rejected(
  :komga, "a library repair whose selected identifier moved into a comment",
  [[KOMGA_ROLE,
    "    url: >-\n" \
    "      {{ komga_api }}/api/v1/libraries/{{ item.id | urlencode }}\n" \
    "    method: PATCH\n",
    "    # {{ item.id | urlencode }}\n" \
    "    url: >-\n" \
    "      {{ komga_api }}/api/v1/libraries/{{ item.name | urlencode }}\n" \
    "    method: PATCH\n"]],
  "library updates must preserve the selected identifier"
)

check_rejected(
  :komga, "an ambiguity guard that lost its one-convergence migration clause",
  [[KOMGA_ROLE,
    "        komga_library_root_migration_allowed | bool\n",
    "        true\n"]],
  "the library root move is not gated on the one-convergence input"
)

check_rejected(
  :komga, "an opaque database reference in an unscoped task",
  [[KOMGA_ROLE, "    msg: KOMGA_PLAN_CLAIM\n", "    msg: KOMGA_PLAN_CLAIM database.sqlite\n"]],
  "role must not edit an opaque database"
)

# The drill line before the login budget fix; the behavioural proof is
# tests/mac/snapshot-paperless-drill-throttle-test.sh.
check_rejected(
  :paperless, "a deletion poll that logs in again on every pass",
  [[PAPERLESS_SNAPSHOT,
    "    break if catalogue(drill_token).empty?\n",
    "    break if catalogue(authenticate(admin_username, admin_password)).empty?\n"]],
  "Paperless drill poll must reuse the drill token rather than log in again"
)

check_rejected(
  :media_probes, "a managed-user include that survives only as a comment",
  [[KOMGA_ROLE,
    "  ansible.builtin.include_tasks: managed_users.yml\n",
    "  # ansible.builtin.include_tasks: managed_users.yml\n" \
    "  ansible.builtin.debug:\n" \
    "    msg: komga-managed-users-disabled\n"],
   [KOMGA_ROLE, "    file: managed_users.yml\n", "    file: managed_users_disabled.yml\n"]],
  "komga main tasks omit managed-user reconciliation"
)

check_rejected(
  :media_probes, "an explicitly managed Collections library",
  [[JELLYFIN_DEPLOY,
    "- name: Wait for the Jellyfin startup API\n",
    "- name: Manage the Jellyfin Collections library\n" \
    "  ansible.builtin.set_fact:\n" \
    "    collection_type: Collections\n" \
    "\n" \
    "- name: Wait for the Jellyfin startup API\n"]],
  "Jellyfin must not explicitly manage Collections"
)

check_rejected(
  :media_probes, "a DELETE verb that belongs to an unrelated request",
  [[JELLYFIN_LIBRARIES, "    method: DELETE\n", "    method: POST\n"],
   [JELLYFIN_VERIFY,
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
  :media_probes, "an image endpoint renamed on every request that uses it",
  [[JELLYFIN_IDENTITY,
    "    url: \"{{ jellyfin_api }}/UserImage?userId=" \
    "{{ jellyfin_primary_authenticated_id | urlencode }}\"\n",
    "    url: \"{{ jellyfin_api }}/UserImageUpload?userId=" \
    "{{ jellyfin_primary_authenticated_id | urlencode }}\"\n"],
   [JELLYFIN_PREFLIGHT,
    "      {{ jellyfin_api ~ '/UserImage?userId=' ~\n" \
    "         (jellyfin_primary_authenticated_id | urlencode) ~ '&tag=' ~\n",
    "      {{ jellyfin_api ~ '/UserImageRead?userId=' ~\n" \
    "         (jellyfin_primary_authenticated_id | urlencode) ~ '&tag=' ~\n"],
   [JELLYFIN_VERIFY,
    "      {{ jellyfin_api ~ '/UserImage?userId=' ~\n" \
    "         (jellyfin_verified_primary_user.Id | string | urlencode) ~ '&tag=' ~\n",
    "      {{ jellyfin_api ~ '/UserImageRead?userId=' ~\n" \
    "         (jellyfin_verified_primary_user.Id | string | urlencode) ~ '&tag=' ~\n"]],
  "Jellyfin image upload does not use the supported current endpoint"
)

check_rejected(
  :media_probes, "a server configuration overwrite whose merge moved into a comment",
  [[JELLYFIN_IDENTITY,
    "    body: >-\n" \
    "      {{ jellyfin_server_configuration_for_update.json |\n" \
    "         combine({'ServerName': jellyfin_server_name}) }}\n",
    "    # {{ jellyfin_server_configuration_for_update.json | combine(...) }}\n" \
    "    body: >-\n" \
    "      {{ {'ServerName': jellyfin_server_name} }}\n"]],
  "Jellyfin server update does not preserve the full configuration"
)

check_rejected(
  :media_probes, "a temporary recovery match whose exact form moved into a comment",
  [[JELLYFIN_PREFLIGHT,
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
  :media_probes, "a primary identity rename with no recovery path",
  [[JELLYFIN_PRIMARY_IDENTITY, "  rescue:\n", "  always:\n"]],
  "Jellyfin primary rename is not guarded by block/rescue recovery"
)

check_rejected(
  :media_probes, "a library rename that suppresses its identity refresh",
  [[JELLYFIN_LIBRARIES, "'&refreshLibrary=true' }}\n", "'&refreshLibrary=false' }}\n"]],
  "Jellyfin library rename does not request identity refresh"
)

check_rejected(
  :media_probes, "image digest comparisons removed from both assertions",
  [[JELLYFIN_PREFLIGHT,
    "      - jellyfin_admin_avatar_source_state.stat.checksum == jellyfin_admin_avatar_sha256\n",
    "      - true\n"],
   [JELLYFIN_VERIFY,
    "      - jellyfin_verified_admin_avatar_state.stat.checksum == jellyfin_admin_avatar_sha256\n",
    "      - true\n"]],
  "Jellyfin role has no authoritative image byte verification"
)

# --- Paperless contract -------------------------------------------------------
# Host networking hides the webserver from the port registry.
check_rejected(
  :paperless, "a webserver that goes back to host networking",
  [[PAPERLESS_COMPOSE, "    ports:\n      - \"8000:8000\"\n", "    network_mode: host\n"]],
  "nas effective config must not use host networking"
)

check_rejected(
  :paperless, "a dependency that goes back to publishing a host port",
  [[PAPERLESS_COMPOSE,
    "    volumes:\n      - ${PAPERLESS_REDIS_PATH:?}:/data\n",
    "    volumes:\n      - ${PAPERLESS_REDIS_PATH:?}:/data\n" \
    "    ports:\n      - \"127.0.0.1:6379:6379\"\n"]],
  "nas broker publishes a host port"
)

# Compose appends merged `ports:` lists, so an override without `!override` publishes
# both ports; only the merged config shows it.
check_rejected(
  :paperless, "a Mac override that lost its override tag",
  [[PAPERLESS_MAC_COMPOSE, "    ports: !override\n", "    ports:\n"]],
  "mac effective webserver publication differs"
)

check_rejected(
  :paperless, "a required task that survives only as a comment",
  [[PAPERLESS_MAIL_RECONCILE,
    "- name: Repair the managed Paperless mail rule\n",
    "# - name: Repair the managed Paperless mail rule\n" \
    "- name: Repair the managed Paperless mail rule again\n"]],
  "missing Repair the managed Paperless mail rule"
)

check_rejected(
  :paperless, "a probe-state snapshot the probe no longer sits between",
  [[PAPERLESS_MAIL_STATE,
    "    paperless_managed_mail_probe_state_before:\n",
    "    paperless_managed_mail_probe_state_before_disabled:\n"]],
  "managed account/rule state is not snapshotted around the credential probe"
)

check_rejected(
  :paperless, "a probe-state comparison replaced by a tautology",
  [[PAPERLESS_MAIL_PROBE,
    "      - paperless_managed_mail_probe_state_before == paperless_managed_mail_probe_state_after\n",
    "      - true\n"]],
  "managed account/rule state is not snapshotted around the credential probe"
)

check_rejected(
  :paperless, "a renamed schema validation task",
  [[PAPERLESS_MAIL_STATE,
    "- name: Validate Paperless mail account and rule schemas before mutation\n",
    "- name: Validate Paperless mail account and rule schemas after mutation\n"]],
  "managed mail schema is not validated globally before mutation"
)

check_rejected(
  :paperless, "a schema validation task named only in a comment",
  [[PAPERLESS_MAIL_STATE,
    "- name: Validate Paperless mail account and rule schemas before mutation\n",
    "# - name: Validate Paperless mail account and rule schemas before mutation\n" \
    "- name: Validate Paperless mail schemas before mutation\n"]],
  "managed mail schema is not validated globally before mutation"
)

check_rejected(
  :paperless, "a sixth effective state source",
  [[PAPERLESS_STORAGE,
    "    paperless_effective_state_host_paths:\n" \
    "      - \"{{ paperless_effective_state_host_path }}/postgres\"\n",
    "    paperless_effective_state_host_paths:\n" \
    "      - \"{{ paperless_effective_state_host_path }}/extra\"\n" \
    "      - \"{{ paperless_effective_state_host_path }}/postgres\"\n"]],
  "Paperless effective state sources do not match the five Compose/env state roots"
)

# A folded scalar keeps line breaks, so absence checks also match the
# whitespace-stripped scalar.
check_rejected(
  :paperless, "a consuming mail endpoint folded across two lines",
  [[PAPERLESS_MAIL_STATE,
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
  :paperless, "a global task-count endpoint folded across two lines",
  [[PAPERLESS_MAIL_STATE,
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
  :paperless, "a generator that synthesizes the Gmail app password",
  [[GENERATOR,
    "    paperless_gmail_app_password: replace-with-google-app-password\n",
    "    paperless_gmail_app_password: \"{{ lookup('password', password_spec) }}\"\n"]],
  "Gmail app password must be a visible sentinel in the new-platform generator"
)

check_rejected(
  :paperless, "a generator sentinel that survives only as a comment",
  [[GENERATOR,
    "    paperless_gmail_app_password: replace-with-google-app-password\n",
    "    # paperless_gmail_app_password: replace-with-google-app-password\n" \
    "    paperless_gmail_app_password: hunter2hunter2\n"]],
  "Gmail app password must be a visible sentinel in the new-platform generator"
)

check_rejected(
  :paperless, "grouped app-password spacing kept out of the payload only",
  [[PAPERLESS_MAIL_STATE,
    "           'password': vault_paperless_gmail_app_password | replace(' ', ''),\n",
    "           'password': vault_paperless_gmail_app_password,\n"]],
  "role must accept Google's grouped app-password display"
)

check_rejected(
  :paperless, "grouped app-password spacing kept out of the fingerprint only",
  [[PAPERLESS_MAIL_STATE,
    "          (vault_paperless_gmail_app_password | replace(' ', ''))) | hash('sha256') }}\n",
    "          vault_paperless_gmail_app_password) | hash('sha256') }}\n"]],
  "role must accept Google's grouped app-password display"
)

check_rejected(
  :paperless, "one dependency endpoint that goes back to a loopback address",
  [[PAPERLESS_ENVIRONMENT,
    "PAPERLESS_TIKA_ENDPOINT=http://tika:9998\n",
    "PAPERLESS_TIKA_ENDPOINT=http://127.0.0.1:9998\n"]],
  "PAPERLESS_TIKA_ENDPOINT must address its Compose service by name on every platform"
)

# Compose reads the last assignment of a name, so an appended duplicate is the live one.
check_rejected(
  :paperless, "an unescaped secret assignment appended after the escaped one",
  [[PAPERLESS_ENVIRONMENT,
    "PAPERLESS_AI_LLM_MODEL={{ paperless_ai_llm_model }}\n",
    "PAPERLESS_AI_LLM_MODEL={{ paperless_ai_llm_model }}\n" \
    "PAPERLESS_ADMIN_PASSWORD={{ vault_paperless_admin_password }}\n"]],
  "vault_paperless_admin_password is not protected from Compose interpolation"
)

check_rejected(
  :paperless, "an escaping filter dropped from the admin password",
  [[PAPERLESS_ENVIRONMENT,
    "PAPERLESS_ADMIN_PASSWORD={{ vault_paperless_admin_password | replace('$', '$$') }}\n",
    "PAPERLESS_ADMIN_PASSWORD={{ vault_paperless_admin_password }}\n"]],
  "vault_paperless_admin_password is not protected from Compose interpolation"
)

# --- Immich restore quality ---------------------------------------------------

check_rejected(
  :immich_restore, "a sanitized refusal code that survives only as a comment",
  [[IMMICH_ROLE,
    "             'incompatible-newest-backup',\n",
    "             # 'incompatible-newest-backup',\n"]],
  "incompatible newest backup diagnostic is not sanitized"
)

check_rejected(
  :immich_restore, "a different refusal code dropped from the sanitized list",
  [[IMMICH_ROLE,
    "             ['unsafe-storage', 'unsafe-originals', 'missing-safe-backup',\n",
    "             ['unsafe-storage', 'missing-safe-backup',\n"]],
  "incompatible newest backup diagnostic is not sanitized"
)

check_rejected(
  :immich_restore, "the stale backup refusal dropped from the sanitized list",
  [[IMMICH_ROLE, "             'stale-newest-backup',\n", ""]],
  "incompatible newest backup diagnostic is not sanitized"
)

check_rejected(
  :immich_restore, "the stale backup refusal left on the generic message",
  [[IMMICH_ROLE,
    "      if immich_restore_classification_status == 'stale-newest-backup'\n",
    "      if false\n"]],
  "stale backup refusal does not say how to take a fresh backup"
)

check_rejected(
  :immich_restore, "a missing restored source file counted but not refused",
  [[IMMICH_RESTORE,
    "          - (immich_restored_source_verification.stdout | from_json).missing | int == 0\n",
    ""]],
  "a missing restored source file does not refuse startup"
)

check_rejected(
  :immich_restore, "the missing source-file count dropped from the failure",
  [[IMMICH_RESTORE,
    "          ((immich_restored_source_verification.stdout | from_json).missing | string)\n",
    "          ('some' | string)\n"]],
  "source-file failure does not report how many assets were missing"
)

check_rejected(
  :immich_restore, "the PostgreSQL major refusals dropped from the sanitized list",
  [[IMMICH_ROLE,
    "             'postgres-major-mismatch', 'unreadable-postgres-version',\n",
    ""]],
  "incompatible newest backup diagnostic is not sanitized"
)

# Immich's restore rewrites the dump's empty search_path; gzip straight to psql skips it.
check_rejected(
  :immich_restore, "the search_path rewrite dropped from the restore pipe",
  [[IMMICH_RESTORE,
    "            sed \"s/SELECT pg_catalog.set_config('search_path', '', false);/" \
    "SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g\" |\n",
    ""]],
  "restore does not apply Immich's search_path rewrite before psql"
)

check_rejected(
  :immich_restore, "the search_path rewrite kept only in a comment",
  [[IMMICH_RESTORE,
    "            sed \"s/SELECT pg_catalog.set_config('search_path', '', false);/" \
    "SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g\" |\n",
    "            # sed search_path rewrite\n"]],
  "restore does not apply Immich's search_path rewrite before psql"
)

check_rejected(
  :immich_restore, "the unverified PostgreSQL major warning keyed on another status",
  [[IMMICH_ROLE,
    "    'postgres-version-unverified'\n",
    "    'unreadable-postgres-version'\n"]],
  "unverified PostgreSQL major is not reported"
)

check_rejected(
  :immich_restore, "a real DELETE folded across two lines",
  [[IMMICH_RESTORE,
    "            SELECT json_build_object(\n",
    "            DELETE\n            FROM asset;\n            SELECT json_build_object(\n"]],
  "restore verification mutates an application table"
)

check_rejected(
  :immich_restore, "a task that removes the restore provenance marker",
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
  :immich_restore, "a migration marker check deleted but kept in a comment",
  [[IMMICH_RESTORE,
    "            'schemaMarker', to_regclass('public.kysely_migrations') IS NOT NULL,\n",
    "            # public.kysely_migrations\n            'schemaMarker', true,\n"]],
  "restore does not verify the pinned v3 migration marker"
)

check_rejected(
  :immich_restore, "two failure stages collapsed onto one label",
  [[IMMICH_RESTORE,
    "        immich_restore_stage: database-verification\n",
    "        immich_restore_stage: database-restore\n"]],
  "restore failures do not preserve a sanitized marker stage"
)

check_rejected(
  :immich_restore, "a rescue marker that stops recording the stage it reached",
  [[IMMICH_RESTORE,
    "          {{ {'version': 1, 'stage': (immich_restore_stage | default('restore'))} | to_json }}\n",
    "          {{ {'version': 1, 'stage': 'restore'} | to_json }}\n"]],
  "restore failures do not preserve a sanitized marker stage"
)

# Accepted: a comment is not a statement and not a task.
check_accepted(
  :immich_restore, "a comment warning against DELETE",
  [[IMMICH_RESTORE,
    "  rescue:\n",
    "  # The restore never issues DELETE or TRUNCATE against an application table.\n  rescue:\n"]]
)

check_accepted(
  :immich_restore, "the provenance-removal task named only in a comment",
  [[IMMICH_RESTORE,
    "  rescue:\n",
    "  # Deliberately no 'Remove the Immich restore failure marker' task here.\n  rescue:\n"]]
)

# --- Beszel contract ----------------------------------------------------------

check_rejected(
  :beszel, "a required task that survives only as a comment",
  [[BESZEL_CONFIGURE,
    "    - name: Poll persisted Beszel telemetry collections\n",
    "    # - name: Poll persisted Beszel telemetry collections\n" \
    "    - name: Poll persisted Beszel telemetry collections twice\n"]],
  "missing Poll persisted Beszel telemetry collections"
)

check_rejected(
  :beszel, "a telemetry poll that no longer registers its probe result",
  [[BESZEL_CONFIGURE,
    "      register: beszel_telemetry_probe_result\n",
    "      changed_when: false\n"]],
  "role treats live health as persisted telemetry"
)

check_rejected(
  :beszel, "a GPU inference reintroduced with different spacing",
  [[BESZEL_VARS,
    "beszel_effective_required_telemetry_categories: >-\n" \
    "  {{ ['core', 'disk', 'containers']\n",
    "beszel_effective_required_telemetry_categories: >-\n" \
    "  {{ (['gpu'] if beszel_require_gpu_telemetry|bool else []) + ['core', 'disk', 'containers']\n"]],
  "effective categories must use explicit inventory policy"
)

# --- Audiobookshelf contract --------------------------------------------------

check_rejected(
  :audiobookshelf, "a duplicate backup path assignment appended to the env file",
  [[AUDIOBOOKSHELF_ENVIRONMENT,
    "AUDIOBOOKSHELF_BACKUP_PATH={{ audiobookshelf_effective_backup_host_path }}\n",
    "AUDIOBOOKSHELF_BACKUP_PATH={{ audiobookshelf_effective_backup_host_path }}\n" \
    "AUDIOBOOKSHELF_BACKUP_PATH=/volume1/Docker/audiobookshelf/backups\n"]],
  "backup environment is absent"
)

# Stages must be static imports: verify.yml tags this role [never], and only an
# import carries the platform_verify tag into a stage (static_role_tasks skips includes).
check_rejected(
  :audiobookshelf, "a verification stage demoted to a dynamic include",
  [[AUDIOBOOKSHELF_MAIN,
    "  ansible.builtin.import_tasks: verify.yml\n",
    "  ansible.builtin.include_tasks: verify.yml\n"]],
  "missing Require exactly the managed Audiobookshelf administrator"
)

check_rejected(
  :audiobookshelf, "a required task that survives only as a comment",
  [[AUDIOBOOKSHELF_VERIFY,
    "- name: Require exactly the managed Audiobookshelf library\n",
    "# - name: Require exactly the managed Audiobookshelf library\n" \
    "- name: Require exactly the managed Audiobookshelf libraries\n"]],
  "missing Require exactly the managed Audiobookshelf library"
)

# --- Immich contract ----------------------------------------------------------

check_rejected(
  :immich, "a required task that survives only as a comment",
  [[IMMICH_ROLE,
    "- name: Read Immich initialization state\n",
    "# - name: Read Immich initialization state\n" \
    "- name: Read Immich initialization states\n"]],
  "missing Read Immich initialization state"
)

check_rejected(
  :immich, "a Docker API exec reintroduced as a task module",
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
  :immich, "an opaque container variable reintroduced in a task",
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
  :immich, "an onboarding task that shells into psql",
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
check_rejected(
  :dozzle, "a dispatcher header that borrows another publisher's token",
  [[DOZZLE_DEFAULTS,
    "Bearer {{ vault_dozzle_alert_relay_token }}",
    "Bearer {{ vault_pushover_containers_token }}"]],
  "managed dispatcher authorization differs"
)

check_rejected(
  :dozzle, "a relay secret that borrows the Pushover application token",
  [[DOZZLE_ENV,
    "ALERT_RELAY_TOKEN={{ vault_dozzle_alert_relay_token }}",
    "ALERT_RELAY_TOKEN={{ vault_pushover_containers_token }}"]],
  "the relay secret is not a credential of its own"
)

# --- Repository policy --------------------------------------------------------

check_rejected(
  :policy, "a planned-change task that survives only as a comment",
  [[DOZZLE_ROLE,
    "- name: Report planned managed Dozzle dispatcher creation\n",
    "# - name: Report planned managed Dozzle dispatcher creation\n" \
    "- name: Report planned managed Dozzle dispatcher creations\n"]],
  "Dozzle must expose every REST mutation category as a check-mode planned change"
)

check_rejected(
  :policy, "a container CPU include that names another service",
  [[BESZEL_DEPLOY,
    "    container_cpu_service_name: beszel\n",
    "    container_cpu_service_name: dozzle\n"]],
  "beszel: role must verify its effective container CPU policy exactly once"
)

check_rejected(
  :policy, "a Compose shell-out past the end of the old scan window",
  [[BESZEL_DEPLOY,
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
  "%REPO%/roles/beszel/tasks/deploy.yml: shells out to Compose; use community.docker.docker_compose_v2"
)

# --- Arr Phase 1 API ownership ------------------------------------------------

check_rejected(
  :arr, "an activation downgraded while the module stays named in the file",
  [[ARR_MAIN,
    "        env_files: [\"{{ platform_runtime_dir }}/services/arr/.env\"]\n        state: present\n",
    "        env_files: [\"{{ platform_runtime_dir }}/services/arr/.env\"]\n        state: absent\n"]],
  "Arr role must deploy through docker_compose_v2"
)

check_rejected(
  :arr, "the activation gate demoted to a comment",
  [[ARR_MAIN,
    "- name: Deploy the Phase 1 Arr project, catching a container that runs but never serves\n" \
    "  when: media_usenet_enabled | bool\n",
    "- name: Deploy the Phase 1 Arr project, catching a container that runs but never serves\n" \
    "  # when: media_usenet_enabled | bool\n"]],
  "Arr role must gate activation on media_usenet_enabled"
)

# force: false must sit on the Bazarr seed task itself, not just somewhere in the file.
check_rejected(
  :arr, "a Bazarr seed that overwrites an operator's own configuration",
  [[ARR_BOOTSTRAP,
    "    dest: \"{{ arr_bazarr_config_host_path }}/config/config.yaml\"\n" \
    "    owner: \"{{ nas_uid }}\"\n" \
    "    group: \"{{ nas_gid }}\"\n" \
    "    mode: \"0600\"\n" \
    "    force: false\n",
    "    dest: \"{{ arr_bazarr_config_host_path }}/config/config.yaml\"\n" \
    "    owner: \"{{ nas_uid }}\"\n" \
    "    group: \"{{ nas_gid }}\"\n" \
    "    mode: \"0600\"\n"]],
  "Bazarr bootstrap must preserve existing config"
)

check_rejected(
  :arr, "authentication disabled with the old element left in a comment",
  [[ARR_CONFIG_XML,
    "  <AuthenticationRequired>Enabled</AuthenticationRequired>\n",
    "  <!-- <AuthenticationRequired>Enabled</AuthenticationRequired> -->\n" \
    "  <AuthenticationRequired>Disabled</AuthenticationRequired>\n"]],
  "Servarr authentication must be enabled before first start"
)

check_rejected(
  :arr, "an API key bound to the wrong service",
  [[ARR_ENVIRONMENT,
    "BAZARR_API_KEY={{ vault_arr_bazarr_api_key }}\n",
    "BAZARR_API_KEY={{ vault_arr_radarr_api_key }}\n" \
    "# BAZARR_API_KEY={{ vault_arr_bazarr_api_key }}\n"]],
  "Arr env must carry all deterministic API keys"
)

check_rejected(
  :arr, "one API request logging its payload while its siblings redact",
  [[ARR_BAZARR,
    "  register: arr_bazarr_settings_before\n  changed_when: false\n" \
    "  check_mode: false\n  no_log: true\n",
    "  register: arr_bazarr_settings_before\n  changed_when: false\n  check_mode: false\n"]],
  "all Arr API reconciliation must redact secret-bearing payloads"
)

check_rejected(
  :arr, "a library scan command issued beside the root folder creation",
  [[ARR_SERVARR,
    "- name: Create the declared Servarr root without import or search\n",
    "- name: Trigger a Servarr library scan\n" \
    "  ansible.builtin.uri:\n" \
    "    url: \"{{ arr_servarr_instance.api }}/command\"\n" \
    "    method: POST\n" \
    "    body_format: json\n" \
    "    body:\n" \
    "      name: DownloadedMoviesScan\n" \
    "  no_log: true\n" \
    "\n" \
    "- name: Create the declared Servarr root without import or search\n"]],
  "Servarr reconciliation must create root folders without import commands"
)

check_rejected(
  :arr, "the host request replacing unowned fields instead of merging them",
  [[ARR_SERVARR,
    "      {{ arr_servarr_host_before.json | combine({\n" \
    "           'authenticationMethod': 'forms',\n",
    "      {{ {\n" \
    "           'authenticationMethod': 'forms',\n"]],
  "Servarr reconciliation must preserve unowned host fields"
)

check_accepted(
  :arr, "a comment recording that no download client is created",
  [[ARR_PROWLARR,
    "---\n",
    "---\n# Prowlarr indexes; a download client is deliberately never created here.\n"]]
)

# Bazarr's Jellyfin integration is off deliberately; an absent flag looks identical
# to an unmade decision.
check_rejected(
  :arr, "the Jellyfin integration pin quietly deleted",
  [[ARR_BAZARR_FILTER,
    "        \"settings-general-use_jellyfin\": \"false\",\n",
    ""]],
  "Bazarr must pin its Jellyfin integration off rather than ignore it"
)

# --- Compose identity, adoption guard and the Paperless environment -------------

check_rejected(
  :reader_identity, "the platform identity moved into a comment",
  [[KOMGA_COMPOSE,
    "    user: \"${NAS_UID:?}:${NAS_GID:?}\"\n",
    "    # user: \"${NAS_UID:?}:${NAS_GID:?}\"\n"]],
  "komga Compose must declare its user as ${NAS_UID:?}:${NAS_GID:?} exactly once"
)

check_accepted(
  :reader_identity, "a comment recording the banned literal identity",
  [[KOMGA_COMPOSE,
    "services:\n",
    "# The identity is never the literal 1000:100; it is supplied by the platform.\nservices:\n"]]
)

check_rejected(
  :acquisition_phase1, "the Unpackerr identity hard-coded",
  [[DOWNLOADERS_COMPOSE,
    "    user: \"${NAS_UID:?}:${NAS_GID:?}\"\n",
    "    user: \"4242:4343\"\n    # user: \"${NAS_UID:?}:${NAS_GID:?}\"\n"]],
  "Unpackerr source must derive its user from NAS_UID and NAS_GID"
)

# Plants the writing module and the variable in the same task, the shape that persists input.
check_rejected(
  :acquisition_adoption, "the one-run adoption input written to disk",
  [[ARR_STATE_GUARD,
    "- name: Detect existing movie library content\n",
    "- name: Remember the adoption bypass\n" \
    "  ansible.builtin.copy:\n" \
    "    dest: /tmp/adopted\n" \
    "    content: \"{{ media_acquisition_adopt_existing_libraries }}\"\n" \
    "    mode: \"0644\"\n" \
    "\n" \
    "- name: Detect existing movie library content\n"]],
  "guard must never persist the one-run adoption input"
)

check_rejected(
  :policy, "a Paperless worker assignment demoted to a comment",
  [[PAPERLESS_ENVIRONMENT,
    "PAPERLESS_TASK_WORKERS={{ paperless_task_workers }}\n",
    "# PAPERLESS_TASK_WORKERS={{ paperless_task_workers }}\n" \
    "PAPERLESS_TASK_WORKERS=2\n"]],
  "Paperless environment template must contain exact line: " \
  "PAPERLESS_TASK_WORKERS={{ paperless_task_workers }}"
)

# --- Integration, Mac and vault policy ------------------------------------------

# tasks_from: target is a prefix of tasks_from: target_docker_dependencies.
check_rejected(
  :policy_integration, "the Mac path fixture pointed at a different entry point",
  [[MAC_PATH_FIXTURE, "        tasks_from: target\n", "        tasks_from: target_docker_dependencies\n"]],
  "integration must prove canonical Mac paths pass target validation"
)

check_rejected(
  :policy_integration, "the Arr project namespace unscoped in the environment",
  [[ARR_ENVIRONMENT,
    "PLATFORM_PROJECT_NAME={{ arr_platform_project_name }}\n",
    "PLATFORM_PROJECT_NAME={{ platform_project_name }}\n" \
    "# PLATFORM_PROJECT_NAME={{ arr_platform_project_name }}\n"]],
  "Arr must derive its Compose project and container prefix through its role-scoped namespace"
)

check_rejected(
  :policy_integration, "the media-control network suffix changed",
  [[SHARED_INVENTORY,
    "  {{ (platform_project_name ~ '-media-control') if",
    "  {{ (platform_project_name ~ '-media') if"]],
  "acquisition namespacing must not alter the media-control or legacy project defaults"
)

check_accepted(
  :policy_integration, "a comment naming a role-scoped namespace variable",
  [[HOST_PREP,
    "---\n",
    "---\n# The media control network is shared; arr_platform_project_name never applies.\n"]]
)

check_rejected(
  :policy_mac, "a converging role added to verify.yml",
  [[VERIFY_PLAY, "  roles:\n    - role: beszel\n", "  roles:\n    - role: host_prep\n    - role: beszel\n"]],
  "Mac verification must not deploy or converge services"
)

check_accepted(
  :policy_mac, "a comment naming the roles verify.yml refuses to run",
  [[VERIFY_PLAY,
    "  roles:\n",
    "  # Never: role: host_prep, role: deployment_bundle, community.docker.docker_compose_v2.\n" \
    "  roles:\n"]]
)

# Named in tests/validate-policy.sh but outside every shard heredoc (#653), so the
# assertion reads PolicySupport.gate_shards rather than grepping the file.
check_rejected(
  :policy_vault, "the redaction test demoted from a dispatched line to its name",
  [[POLICY_GATE,
    "tests/generate-secrets-redaction-test.sh\n" \
    "POLICY_CHECKS_3\n" \
    "}\n",
    "POLICY_CHECKS_3\n" \
    "}\n" \
    "\n" \
    "# Retired: tests/generate-secrets-redaction-test.sh\n"]],
  "CI must execute the generated-secret redaction test"
)

# --- Managed-user vault contract ----------------------------------------------

check_rejected(
  :managed_users_vault, "a managed-user list dropped from the schema mapping",
  [[VAULT_CONTRACT,
    "          'komga': vault_managed_komga_users,\n",
    ""]],
  "vault contract must submit vault_managed_komga_users for schema validation"
)

check_rejected(
  :managed_users_vault, "a reserved identity dropped while its name stays in a comment",
  [[VAULT_CONTRACT,
    "      komga: [\"{{ vault_komga_admin_email }}\"]\n",
    "      # komga: [\"{{ vault_komga_admin_email }}\"]\n      komga: []\n"]],
  "vault contract validation is missing vault_komga_admin_email"
)

# --- Downloader Phase 1 Usenet ownership ---------------------------------------

check_rejected(
  :downloaders, "the state guard replaced by a comment naming it",
  [[DOWNLOADERS_MAIN,
    "- name: Guard downloader critical state before Phase 1 activation\n" \
    "  ansible.builtin.include_tasks: state_guard.yml\n",
    "# ansible.builtin.include_tasks: state_guard.yml\n" \
    "- name: Guard downloader critical state before Phase 1 activation\n" \
    "  ansible.builtin.debug:\n" \
    "    msg: state guard skipped\n"]],
  "downloaders role must include the state guard before deployment"
)

check_rejected(
  :downloaders, "the CPU policy service renamed with the old name left in a comment",
  [[DOWNLOADERS_MAIN,
    "    container_cpu_service_name: downloaders\n",
    "    # container_cpu_service_name: downloaders\n" \
    "    container_cpu_service_name: usenet-downloaders\n"]],
  "downloaders role must verify its effective project CPU policy"
)

check_rejected(
  :downloaders, "the activation gate demoted to a comment",
  [[DOWNLOADERS_MAIN,
    "- name: Deploy the Phase 1 downloader project, catching a container that runs but never serves\n" \
    "  when: media_usenet_enabled | bool\n",
    "- name: Deploy the Phase 1 downloader project, catching a container that runs but never serves\n" \
    "  # when: media_usenet_enabled | bool\n"]],
  "downloaders role must gate activation on media_usenet_enabled"
)

check_rejected(
  :downloaders, "the Arr client reconciliation pointed at a different entry point",
  [[DOWNLOADERS_MAIN,
    "    tasks_from: reconcile_download_clients\n",
    "    tasks_from: reconcile_download_clients_disabled\n"]],
  "downloaders must reconcile Arr clients only after SABnzbd"
)

check_rejected(
  :downloaders, "an API key bound to the wrong service",
  [[DOWNLOADERS_ENVIRONMENT,
    "SONARR_API_KEY={{ vault_arr_sonarr_api_key }}\n",
    "SONARR_API_KEY={{ vault_arr_radarr_api_key }}\n" \
    "# SONARR_API_KEY={{ vault_arr_sonarr_api_key }}\n"]],
  "downloaders env must carry only declared API keys"
)

check_rejected(
  :downloaders, "SABnzbd bound to loopback with the old value left in a comment",
  [[DOWNLOADERS_INI,
    "host = 0.0.0.0\nport = 8080\n",
    "host = 127.0.0.1\nport = 8080\n# host = 0.0.0.0\n"]],
  "bootstrap must bind SABnzbd on all container interfaces"
)

check_rejected(
  :downloaders, "a category destination fixed instead of declared",
  [[DOWNLOADERS_INI,
    "dir = {{ directory }}\n",
    "dir = /data/media/.acquisition/usenet\n# dir = {{ directory }}\n"]],
  "bootstrap must render every declared category and destination"
)

check_accepted(
  :downloaders, "a comment recording that no provider section is rendered",
  [[DOWNLOADERS_INI,
    "[misc]\n",
    "# No [servers] section: providers are the operator's, never ours.\n[misc]\n"]]
)

check_accepted(
  :downloaders, "a comment explaining why categories are not a mapping",
  [[DOWNLOADERS_VERIFY,
    "---\n",
    "---\n# SABnzbd returns config.categories is mapping only on ancient builds.\n"]]
)

# --- Deployment bundle policy -------------------------------------------------
# The validated inputs are those the controller_input.yml expression names; a
# comment naming a path must not count (#333).
check_rejected(
  :policy_deployment, "canonical Compose validation deleted with its path left in a comment",
  [[BUNDLE_INPUTS,
    "- name: Validate every derived controller input in one pass\n" \
    "  ansible.builtin.include_tasks: controller_input.yml\n" \
    "  vars:\n" \
    "    deployment_controller_inputs: >-\n" \
    "      {{ ([playbook_dir ~ '/services/']\n" \
    "          | product(deployment_bundle_services | map(attribute='name') | list)\n" \
    "          | map('join') | product(['/compose.yml']) | map('join')\n" \
    "          | product(['0']) | list)\n" \
    "         + ([playbook_dir ~ '/services/']",
    "# canonical Compose inputs were services/<name>/compose.yml\n" \
    "- name: Validate every derived controller input in one pass\n" \
    "  ansible.builtin.include_tasks: controller_input.yml\n" \
    "  vars:\n" \
    "    deployment_controller_inputs: >-\n" \
    "      {{ ([] | list)\n" \
    "         + ([playbook_dir ~ '/services/']"]],
  "controller inputs must validate manifest, canonical Compose, and platform overrides"
)

check_rejected(
  :policy_deployment, "a runtime helper input no longer handed to the validator",
  [[BUNDLE_INPUTS,
    "[playbook_dir ~ '/services/dozzle/alert_relay.py', '0'],\n",
    "[playbook_dir ~ '/services/dozzle/alert_relay.py.bak', '0'],\n"]],
  "controller inputs must validate every tracked runtime helper"
)

check_rejected(
  :policy_deployment, "a guarded leaf demoted to a comment beside the batch",
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
  :policy_deployment, "the runtime service leaves dropped from the batch",
  [[BUNDLE_TARGET,
    "         + ([platform_runtime_dir ~ '/services/']\n" \
    "            | product(deployment_bundle_services | default([])\n" \
    "                      | map(attribute='name') | list)\n" \
    "            | map('join') | list) }}\n",
    "         }}\n"]],
  "target validator must guard every implemented runtime service leaf"
)

check_rejected(
  :policy_deployment, "a behavior proof renamed while its old name stays in a comment",
  [[COMPOSE_METADATA_BEHAVIOR,
    "    - name: Require unknown YAML tags to fail closed\n",
    "    # Require unknown YAML tags to fail closed\n" \
    "    - name: Tolerate unknown YAML tags\n"]],
  "policy validation must execute Compose metadata parser behavior tests"
)

check_rejected(
  :policy_deployment, "the manifest's platform inputs key renamed",
  [[BUNDLE_MANIFEST_TEMPLATE, "platform_inputs:\n", "platform_input:\n"]],
  "deployment manifest must bind the exact acquisition catalog path, mode, and checksum"
)

check_accepted(
  :policy_deployment, "a template comment naming a key that renders later",
  [[BUNDLE_MANIFEST_TEMPLATE,
    "---\n",
    "---\n{# platform_inputs is rendered before services: below #}\n"]]
)

# --- Platform policy ----------------------------------------------------------

check_rejected(
  :policy_platform, "a capacity probe whose result nothing is derived from",
  [[PREFLIGHT,
    "  register: preflight_docker_info\n",
    "  register: preflight_docker_capacity_unused\n"]],
  "preflight must derive the effective container CPU set from Docker capacity"
)

check_rejected(
  :policy_platform, "one probe task pointed at a divergent path",
  [[PREFLIGHT,
    "    paths: \"{{ nas_docker_root }}/.nas-platform-preflight-probe\"\n",
    "    paths: \"{{ platform_deploy_root }}/.nas-platform-preflight-probe\"\n"]],
  "fresh-install preflight must probe the existing validated nas_docker_root"
)

# --- Production auto-deploy role ----------------------------------------------
# These rows install and run the role (~10s each).
check_rejected(
  :auto_deploy, "a virtualenv probe deleted while its path stays in the command line",
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

# curl sends every form-string it is given, so a duplicated token line is a second token.
check_rejected(
  :auto_deploy, "a duplicated Pushover token form-string",
  [[AUTO_DEPLOY_PUSHOVER_NOTIFIER,
    "form-string = \"token=",
    "form-string = \"token={{ vault_pushover_alerts_token }}\"\nform-string = \"token="]],
  "the pushover.curl config must present exactly one token, its own application's, read " \
  "by name and escaped"
)

in_parallel_cases(failures, ROWS) { |row, collected| row.call(collected) }

check(failures,
      File.readlines(VALIDATE_POLICY).include?("ruby tests/contract_structure_mutation_test.rb\n"),
      "contract structure mutation proofs are not registered in the policy suite")

# Printed so cache reuse is checkable from a build log; the floor is one copy per worker.
reuse = format("%<rows>d rows, %<copies>d repository copies", **COPY_ACCOUNTING.slice(:rows, :copies))
unless COPY_ACCOUNTING[:rebuilt].empty?
  warn "contract structure copy rebuilt after: #{COPY_ACCOUNTING[:rebuilt].join(', ')}"
end

report(failures,
       "Contract structure mutations: parsed task assertions reject every named shape (#{reuse})",
       "contract structure mutation failure(s)")
