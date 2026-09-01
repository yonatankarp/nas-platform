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

require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "policy_support"

include TestScaffold

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
  # The Arr contract reports every violation it found, one bare message per line,
  # rather than aborting on the first with a prefix.
  arr: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "arr.sh"), "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { message }
  },
  # This suite drives the real vault_contract role over the documented vault, so
  # each row costs about twenty seconds. It carries three rows rather than one per
  # conversion: the ones below are the shapes the old whole-file substrings could
  # not see at all.
  managed_users_vault: {
    command: ->(repo) { [RbConfig.ruby, File.join(repo, "tests", "managed_users_vault_test.rb")] },
    environment: ->(_repo) { {} },
    diagnostic: ->(message) { "FAIL #{message}" }
  },
  downloaders: {
    command: ->(repo) { [File.join(repo, "tests", "contracts", "downloaders.sh"), "static"] },
    environment: ->(repo) { { "PLATFORM_CONTRACT_REPO_DIR" => repo } },
    diagnostic: ->(message) { message }
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
  # This suite reports bare messages, one per line, and drives a real Ansible
  # guard matrix, so its single row is the slowest of the fast ones.
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

# One copy, reused. Copying the repository took a third of a second and every row
# paid it to change two or three files, which made the copies alone a quarter of
# this suite's runtime. A row now restores exactly the paths it substituted.
#
# The reuse is verified rather than assumed. Restoring the wrong set of paths, or a
# suite writing into the copy, would leave the next row proving something about a
# tree nobody described -- so the whole tree is hashed after every row and compared
# against the state it was built in. A copy that does not match is thrown away and
# rebuilt. That costs 15ms per row against a 330ms copy, and its failure mode is an
# extra copy rather than a row that passes for the wrong reason.
#
# `.git` is excluded from the comparison but kept in the copy: policy_test.rb
# enumerates its own sources with git, and running git legitimately writes there.
PRISTINE = { directory: nil, repo: nil, manifest: nil }
COPY_ACCOUNTING = { copies: 0, rows: 0, rebuilt: [] }

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
  FileUtils.remove_entry(PRISTINE[:directory]) if PRISTINE[:directory]
  PRISTINE[:directory] = PRISTINE[:repo] = PRISTINE[:manifest] = nil
end
at_exit { discard_repo }

def pristine_repo
  return PRISTINE if PRISTINE[:repo]

  directory = Dir.mktmpdir("nas-platform-contract-structure-")
  repo = File.join(directory, "repo")
  FileUtils.mkdir_p(repo)
  children = Dir.children(ROOT)
  (children - ignored_children(children)).each do |entry|
    FileUtils.cp_r(File.join(ROOT, entry), File.join(repo, entry))
  end
  PRISTINE[:directory] = directory
  PRISTINE[:repo] = repo
  PRISTINE[:manifest] = tree_manifest(repo)
  COPY_ACCOUNTING[:copies] += 1
  PRISTINE
end

def with_copied_repo(mutated = [], label = nil)
  state = pristine_repo
  repo = state[:repo]
  COPY_ACCOUNTING[:rows] += 1
  begin
    yield repo
  ensure
    mutated.each do |relative_path|
      FileUtils.cp(File.join(ROOT, relative_path), File.join(repo, relative_path))
    end
    unless tree_manifest(repo) == state[:manifest]
      COPY_ACCOUNTING[:rebuilt] << (label || "unnamed row")
      discard_repo
    end
  end
end

# PYTHONDONTWRITEBYTECODE is set for the same reason tests/validate-policy.sh sets
# it: the suites that reach Ansible leave a __pycache__ tree behind them, which is
# a build artifact rather than anything a contract reads. Suppressing it is what
# lets the reuse check below stay strict -- every other byte a suite writes into
# the copy is treated as contamination.
def run_static(suite, repo)
  definition = SUITES.fetch(suite)
  environment = { "PYTHONDONTWRITEBYTECODE" => "1" }.merge(definition.fetch(:environment).call(repo))
  Open3.capture3(environment, *definition.fetch(:command).call(repo))
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

def check_accepted(failures, suite, name, substitutions)
  with_copied_repo(substitutions.map(&:first), "#{suite} #{name}") do |repo|
    apply_substitutions(repo, substitutions)
    stdout, stderr, status = run_static(suite, repo)
    check(failures, status.success?,
          "#{suite} contract rejected #{name}: #{diagnostics(suite, stdout, stderr).lines.first&.strip}")
  end
rescue RuntimeError, SystemCallError => error
  failures << "#{suite} #{name} fixture failed: #{error.message}"
end

# The Jellyfin role is one stage per file, imported from a main.yml index, so a
# row names the stage that owns the text it breaks. apply_substitutions requires
# exactly one match, so a row left pointing at main.yml would fail loudly with
# "0 matches" rather than pass while mutating nothing.
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
PAPERLESS_SNAPSHOT = "tests/mac/snapshot-paperless.sh"
# The Paperless role is one stage per file, imported from a main.yml index, so a
# row names the stage that owns the text it breaks -- same reason as Jellyfin
# above.
PAPERLESS_STORAGE = "roles/paperless_ngx/tasks/storage.yml"
PAPERLESS_MAIL_STATE = "roles/paperless_ngx/tasks/mail_state.yml"
PAPERLESS_MAIL_PROBE = "roles/paperless_ngx/tasks/mail_probe.yml"
PAPERLESS_MAIL_RECONCILE = "roles/paperless_ngx/tasks/mail_reconcile.yml"
PAPERLESS_ENVIRONMENT = "roles/paperless_ngx/templates/env.j2"
PAPERLESS_COMPOSE = "services/paperless-ngx/compose.yml"
PAPERLESS_MAC_COMPOSE = "services/paperless-ngx/compose.mac.yml"
GENERATOR = "generate-secrets.yml"
BESZEL_VARS = "roles/beszel/vars/main.yml"
# The Beszel role is one stage per file, so a row names the stage that owns the
# text it breaks rather than main.yml, which is now an index of static imports.
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
AUTO_DEPLOY_NOTIFIER = "roles/production_auto_deploy/templates/ntfy.curl.j2"

SUITES.each_key do |suite|
  with_copied_repo([], "#{suite} pristine baseline") do |repo|
    stdout, stderr, status = run_static(suite, repo)
    check(failures, status.success?,
          "#{suite} static contract failed on a pristine copy: " \
          "#{diagnostics(suite, stdout, stderr).lines.first&.strip}")
  end
end

check_rejected(
  failures, :jellyfin, "a required task that survives only as a comment",
  [[JELLYFIN_VERIFY,
    "- name: Verify exact Jellyfin owned state\n",
    "# - name: Verify exact Jellyfin owned state\n" \
    "- name: Verify exact Jellyfin owned state after rename\n"]],
  "missing Verify exact Jellyfin owned state"
)

check_rejected(
  failures, :jellyfin, "a mutation task declared before the identity preflight",
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
  failures, :jellyfin, "a DELETE verb that belongs to an unrelated request",
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
  failures, :jellyfin, "an unconditional avatar upload beside conditional siblings",
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
  failures, :jellyfin, "a server configuration overwrite whose merge moved into a comment",
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
  failures, :jellyfin, "an opaque database reference in an unscoped task",
  [[JELLYFIN_IDENTITY,
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
  [[JELLYFIN_AUTHENTICATION,
    "      - not jellyfin_primary_recovery_marker_state.stat.exists or\n" \
    "        jellyfin_primary_recovery_marker_state.stat.mode == '0600'\n",
    "      - true\n"]],
  "recovery marker privacy is not checked before reading"
)

check_rejected(
  failures, :jellyfin, "a primary identity rename with no recovery path",
  [[JELLYFIN_PRIMARY_IDENTITY, "  rescue:\n", "  always:\n"]],
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
  [[JELLYFIN_DEPLOY,
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
    "           'normalized_root': item.root | default('', true) | string | regex_replace('/+$', ''),\n",
    "           'normalized_root': item.root | default('', true) | string,\n"]],
  "managed root matching is not trailing-slash normalized"
)

check_rejected(
  failures, :komga, "a library repair whose selected identifier moved into a comment",
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

# The root move is the one repair the ambiguity guard exists to refuse, so the
# clause that opens it for a single convergence must not be able to vanish.
check_rejected(
  failures, :komga, "an ambiguity guard that lost its one-convergence migration clause",
  [[KOMGA_ROLE,
    "        komga_library_root_migration_allowed | bool\n",
    "        true\n"]],
  "the library root move is not gated on the one-convergence input"
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
  failures, :media_probes, "a DELETE verb that belongs to an unrelated request",
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
  failures, :media_probes, "an image endpoint renamed on every request that uses it",
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
  failures, :media_probes, "a server configuration overwrite whose merge moved into a comment",
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
  failures, :media_probes, "a temporary recovery match whose exact form moved into a comment",
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
  failures, :media_probes, "a primary identity rename with no recovery path",
  [[JELLYFIN_PRIMARY_IDENTITY, "  rescue:\n", "  always:\n"]],
  "Jellyfin primary rename is not guarded by block/rescue recovery"
)

check_rejected(
  failures, :media_probes, "a library rename that suppresses its identity refresh",
  [[JELLYFIN_LIBRARIES, "'&refreshLibrary=true' }}\n", "'&refreshLibrary=false' }}\n"]],
  "Jellyfin library rename does not request identity refresh"
)

check_rejected(
  failures, :media_probes, "image digest comparisons removed from both assertions",
  [[JELLYFIN_PREFLIGHT,
    "      - jellyfin_admin_avatar_source_state.stat.checksum == jellyfin_admin_avatar_sha256\n",
    "      - true\n"],
   [JELLYFIN_VERIFY,
    "      - jellyfin_verified_admin_avatar_state.stat.checksum == jellyfin_admin_avatar_sha256\n",
    "      - true\n"]],
  "Jellyfin role has no authoritative image byte verification"
)

# --- Paperless contract -------------------------------------------------------
#
# Host networking makes the webserver occupy the host's whole port namespace, so
# the port registry that guards every other publication cannot see it at all.
check_rejected(
  failures, :paperless, "a webserver that goes back to host networking",
  [[PAPERLESS_COMPOSE, "    ports:\n      - \"8000:8000\"\n", "    network_mode: host\n"]],
  "nas effective config must not use host networking"
)

# The dependencies answer on the stack's own network, so a host publication for
# one of them is surface with nothing behind it.
check_rejected(
  failures, :paperless, "a dependency that goes back to publishing a host port",
  [[PAPERLESS_COMPOSE,
    "    volumes:\n      - ${PAPERLESS_REDIS_PATH:?}:/data\n",
    "    volumes:\n      - ${PAPERLESS_REDIS_PATH:?}:/data\n" \
    "    ports:\n      - \"127.0.0.1:6379:6379\"\n"]],
  "nas broker publishes a host port"
)

# Compose merges two `ports:` lists by appending them, so an override that drops
# `!override` publishes the production port next to its allocated one and the
# collision it exists to prevent comes back. The override's own structure cannot
# say that; only the merged effective config can.
check_rejected(
  failures, :paperless, "a Mac override that lost its override tag",
  [[PAPERLESS_MAC_COMPOSE, "    ports: !override\n", "    ports:\n"]],
  "mac effective webserver publication differs"
)

check_rejected(
  failures, :paperless, "a required task that survives only as a comment",
  [[PAPERLESS_MAIL_RECONCILE,
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
  [[PAPERLESS_MAIL_STATE,
    "    paperless_managed_mail_probe_state_before:\n",
    "    paperless_managed_mail_probe_state_before_disabled:\n"]],
  "managed account/rule state is not snapshotted around the credential probe"
)

check_rejected(
  failures, :paperless, "a probe-state comparison replaced by a tautology",
  [[PAPERLESS_MAIL_PROBE,
    "      - paperless_managed_mail_probe_state_before == paperless_managed_mail_probe_state_after\n",
    "      - true\n"]],
  "managed account/rule state is not snapshotted around the credential probe"
)

check_rejected(
  failures, :paperless, "a renamed schema validation task",
  [[PAPERLESS_MAIL_STATE,
    "- name: Validate Paperless mail account and rule schemas before mutation\n",
    "- name: Validate Paperless mail account and rule schemas after mutation\n"]],
  "managed mail schema is not validated globally before mutation"
)

check_rejected(
  failures, :paperless, "a schema validation task named only in a comment",
  [[PAPERLESS_MAIL_STATE,
    "- name: Validate Paperless mail account and rule schemas before mutation\n",
    "# - name: Validate Paperless mail account and rule schemas before mutation\n" \
    "- name: Validate Paperless mail schemas before mutation\n"]],
  "managed mail schema is not validated globally before mutation"
)

check_rejected(
  failures, :paperless, "a sixth effective state source",
  [[PAPERLESS_STORAGE,
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
  failures, :paperless, "a global task-count endpoint folded across two lines",
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
  [[PAPERLESS_MAIL_STATE,
    "           'password': vault_paperless_gmail_app_password | replace(' ', ''),\n",
    "           'password': vault_paperless_gmail_app_password,\n"]],
  "role must accept Google's grouped app-password display"
)

check_rejected(
  failures, :paperless, "grouped app-password spacing kept out of the fingerprint only",
  [[PAPERLESS_MAIL_STATE,
    "          (vault_paperless_gmail_app_password | replace(' ', ''))) | hash('sha256') }}\n",
    "          vault_paperless_gmail_app_password) | hash('sha256') }}\n"]],
  "role must accept Google's grouped app-password display"
)

check_rejected(
  failures, :paperless, "one dependency endpoint that goes back to a loopback address",
  [[PAPERLESS_ENVIRONMENT,
    "PAPERLESS_TIKA_ENDPOINT=http://tika:9998\n",
    "PAPERLESS_TIKA_ENDPOINT=http://127.0.0.1:9998\n"]],
  "PAPERLESS_TIKA_ENDPOINT must address its Compose service by name on every platform"
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
  [[BESZEL_CONFIGURE,
    "    - name: Poll persisted Beszel telemetry collections\n",
    "    # - name: Poll persisted Beszel telemetry collections\n" \
    "    - name: Poll persisted Beszel telemetry collections twice\n"]],
  "missing Poll persisted Beszel telemetry collections"
)

# #85's headline for this contract: the old form passed with the register deleted,
# because the variable's name still appeared elsewhere in the file.
check_rejected(
  failures, :beszel, "a telemetry poll that no longer registers its probe result",
  [[BESZEL_CONFIGURE,
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

# The role is one stage per file, and main.yml imports each stage statically.
# That is not a formatting choice: verify.yml lists this role with tags: [never],
# and only a static import carries that inherited tag -- alongside each task's own
# platform_verify_audiobookshelf -- down into the stage, so a stage demoted to a
# dynamic include would be skipped before its file was read. It is also what lets
# every check above see the whole role: static_role_tasks follows an import and
# deliberately does not follow an include, so the demotion removes the stage from
# the role this contract inspects rather than quietly passing on a shorter list.
check_rejected(
  failures, :audiobookshelf, "a verification stage demoted to a dynamic include",
  [[AUDIOBOOKSHELF_MAIN,
    "  ansible.builtin.import_tasks: verify.yml\n",
    "  ansible.builtin.include_tasks: verify.yml\n"]],
  "missing Require exactly the managed Audiobookshelf administrator"
)

check_rejected(
  failures, :audiobookshelf, "a required task that survives only as a comment",
  [[AUDIOBOOKSHELF_VERIFY,
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
  [[BESZEL_DEPLOY,
    "    container_cpu_service_name: beszel\n",
    "    container_cpu_service_name: dozzle\n"]],
  "beszel: role must verify its effective container CPU policy exactly once"
)

# The window this replaced was 120 characters wide, so a shell-out that named the
# module further down its own argument list was past the end of it.
check_rejected(
  failures, :policy, "a Compose shell-out past the end of the old scan window",
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
#
# Every row below was accepted by the whole-file substring pairs these assertions
# replaced. Three of them are the unintended-match class: a literal that belongs
# to one task satisfying a check about another.

check_rejected(
  failures, :arr, "an activation downgraded while the module stays named in the file",
  [[ARR_MAIN, "    state: present\n    wait: true\n", "    state: absent\n    wait: true\n"]],
  "Arr role must deploy through docker_compose_v2"
)

check_rejected(
  failures, :arr, "the activation gate demoted to a comment",
  [[ARR_MAIN,
    "  when: media_usenet_enabled | bool\n  register: arr_deploy\n",
    "  # when: media_usenet_enabled | bool\n  register: arr_deploy\n"]],
  "Arr role must gate activation on media_usenet_enabled"
)

# force: false lives on one of two seed tasks. The old pair asked whether the file
# contained the words, so the Servarr task's force answered for the Bazarr task,
# and the Bazarr half never asked about force at all.
check_rejected(
  failures, :arr, "a Bazarr seed that overwrites an operator's own configuration",
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
  failures, :arr, "authentication disabled with the old element left in a comment",
  [[ARR_CONFIG_XML,
    "  <AuthenticationRequired>Enabled</AuthenticationRequired>\n",
    "  <!-- <AuthenticationRequired>Enabled</AuthenticationRequired> -->\n" \
    "  <AuthenticationRequired>Disabled</AuthenticationRequired>\n"]],
  "Servarr authentication must be enabled before first start"
)

check_rejected(
  failures, :arr, "an API key bound to the wrong service",
  [[ARR_ENVIRONMENT,
    "BAZARR_API_KEY={{ vault_arr_bazarr_api_key }}\n",
    "BAZARR_API_KEY={{ vault_arr_radarr_api_key }}\n" \
    "# BAZARR_API_KEY={{ vault_arr_bazarr_api_key }}\n"]],
  "Arr env must carry all deterministic API keys"
)

check_rejected(
  failures, :arr, "one API request logging its payload while its siblings redact",
  [[ARR_BAZARR,
    "  register: arr_bazarr_settings_before\n  changed_when: false\n" \
    "  check_mode: false\n  no_log: true\n",
    "  register: arr_bazarr_settings_before\n  changed_when: false\n  check_mode: false\n"]],
  "all Arr API reconciliation must redact secret-bearing payloads"
)

# The negative half of the old pair only matched an import or search named on the
# same source line as the word command, which a JSON body on its own line is not.
check_rejected(
  failures, :arr, "a library scan command issued beside the root folder creation",
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

# combine( appears in two requests in this file, so the old check was answered by
# the naming request no matter what the host request did with unowned fields.
check_rejected(
  failures, :arr, "the host request replacing unowned fields instead of merging them",
  [[ARR_SERVARR,
    "      {{ arr_servarr_host_before.json | combine({\n" \
    "           'authenticationMethod': 'forms',\n",
    "      {{ {\n" \
    "           'authenticationMethod': 'forms',\n"]],
  "Servarr reconciliation must preserve unowned host fields"
)

# The forbidden-endpoint check used to read the file's text, so writing down that
# the endpoint is deliberately not used was itself a violation.
check_accepted(
  failures, :arr, "a comment recording that no download client is created",
  [[ARR_PROWLARR,
    "---\n",
    "---\n# Prowlarr indexes; a download client is deliberately never created here.\n"]]
)

# Deleting the pin is the whole failure mode it guards against: Bazarr's Jellyfin
# integration is left off deliberately, and an absent flag looks identical to a
# decision that was never made. Without this row the assertion could stop biting
# and every test would still pass.
check_rejected(
  failures, :arr, "the Jellyfin integration pin quietly deleted",
  [[ARR_BAZARR_FILTER,
    "        \"settings-general-use_jellyfin\": \"false\",\n",
    ""]],
  "Bazarr must pin its Jellyfin integration off rather than ignore it"
)

# --- Compose identity, adoption guard and the Paperless environment -------------

check_rejected(
  failures, :reader_identity, "the platform identity moved into a comment",
  [[KOMGA_COMPOSE,
    "    user: \"${NAS_UID:?}:${NAS_GID:?}\"\n",
    "    # user: \"${NAS_UID:?}:${NAS_GID:?}\"\n"]],
  "komga Compose must declare its user as ${NAS_UID:?}:${NAS_GID:?} exactly once"
)

# The banned literal used to be searched for in the file's text, so recording
# that it is banned was itself the ban being broken.
check_accepted(
  failures, :reader_identity, "a comment recording the banned literal identity",
  [[KOMGA_COMPOSE,
    "services:\n",
    "# The identity is never the literal 1000:100; it is supplied by the platform.\nservices:\n"]]
)

check_rejected(
  failures, :acquisition_phase1, "the Unpackerr identity hard-coded",
  [[DOWNLOADERS_COMPOSE,
    "    user: \"${NAS_UID:?}:${NAS_GID:?}\"\n",
    "    user: \"4242:4343\"\n    # user: \"${NAS_UID:?}:${NAS_GID:?}\"\n"]],
  "Unpackerr source must derive its user from NAS_UID and NAS_GID"
)

# The pattern this replaced ran with /m over the whole file, so it could see a
# writing module in one task and the variable in another. This plants both in
# the same task, which is the only shape that actually persists the input.
check_rejected(
  failures, :acquisition_adoption, "the one-run adoption input written to disk",
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
  failures, :policy, "a Paperless worker assignment demoted to a comment",
  [[PAPERLESS_ENVIRONMENT,
    "PAPERLESS_TASK_WORKERS={{ paperless_task_workers }}\n",
    "# PAPERLESS_TASK_WORKERS={{ paperless_task_workers }}\n" \
    "PAPERLESS_TASK_WORKERS=2\n"]],
  "Paperless environment template must contain exact line: " \
  "PAPERLESS_TASK_WORKERS={{ paperless_task_workers }}"
)

# --- Integration, Mac and vault policy ------------------------------------------

# tasks_from: target is a prefix of tasks_from: target_docker_dependencies, so
# the substring check could not tell the containment validator from the module
# preflight that runs beside it.
check_rejected(
  failures, :policy_integration, "the Mac path fixture pointed at a different entry point",
  [[MAC_PATH_FIXTURE, "        tasks_from: target\n", "        tasks_from: target_docker_dependencies\n"]],
  "integration must prove canonical Mac paths pass target validation"
)

check_rejected(
  failures, :policy_integration, "the Arr project namespace unscoped in the environment",
  [[ARR_ENVIRONMENT,
    "PLATFORM_PROJECT_NAME={{ arr_platform_project_name }}\n",
    "PLATFORM_PROJECT_NAME={{ platform_project_name }}\n" \
    "# PLATFORM_PROJECT_NAME={{ arr_platform_project_name }}\n"]],
  "Arr must derive its Compose project and container prefix through its role-scoped namespace"
)

check_rejected(
  failures, :policy_integration, "the media-control network suffix changed",
  [[SHARED_INVENTORY,
    "  {{ (platform_project_name ~ '-media-control') if",
    "  {{ (platform_project_name ~ '-media') if"]],
  "acquisition namespacing must not alter the media-control or legacy project defaults"
)

# The leak check read three concatenated files, so a comment saying the scoped
# variable does not apply here was itself the leak.
check_accepted(
  failures, :policy_integration, "a comment naming a role-scoped namespace variable",
  [[HOST_PREP,
    "---\n",
    "---\n# The media control network is shared; arr_platform_project_name never applies.\n"]]
)

check_rejected(
  failures, :policy_mac, "a converging role added to verify.yml",
  [[VERIFY_PLAY, "  roles:\n    - role: ntfy\n", "  roles:\n    - role: host_prep\n    - role: ntfy\n"]],
  "Mac verification must not deploy or converge services"
)

check_accepted(
  failures, :policy_mac, "a comment naming the roles verify.yml refuses to run",
  [[VERIFY_PLAY,
    "  roles:\n",
    "  # Never: role: host_prep, role: deployment_bundle, community.docker.docker_compose_v2.\n" \
    "  roles:\n"]]
)

check_rejected(
  failures, :policy_vault, "the redaction test demoted from a run step to its name",
  [[CI_WORKFLOW,
    "      - name: Check generated credential redaction\n" \
    "        run: tests/generate-secrets-redaction-test.sh\n",
    "      - name: Check generated credential redaction with " \
    "tests/generate-secrets-redaction-test.sh\n" \
    "        run: true\n"]],
  "CI must execute the generated-secret redaction test"
)

# --- Managed-user vault contract ----------------------------------------------

check_rejected(
  failures, :managed_users_vault, "a published fact demoted to a comment",
  [[VAULT_CONTRACT,
    "    vault_managed_komga_users: \"{{ vault_managed_users.komga }}\"\n",
    "    # vault_managed_komga_users: \"{{ vault_managed_users.komga }}\"\n"]],
  "vault contract must publish named fact vault_managed_komga_users"
)

check_rejected(
  failures, :managed_users_vault, "a reserved identity dropped while its name stays in a comment",
  [[VAULT_CONTRACT,
    "      komga: [\"{{ vault_komga_admin_email }}\"]\n",
    "      # komga: [\"{{ vault_komga_admin_email }}\"]\n      komga: []\n"]],
  "vault contract validation is missing vault_komga_admin_email"
)

check_rejected(
  failures, :managed_users_vault, "an ntfy publisher token dropped from the ownership check",
  [[VAULT_CONTRACT,
    "         vault_managed_user_errors([vault_ntfy_dozzle_token, vault_ntfy_beszel_token,\n",
    "         vault_managed_user_errors([vault_ntfy_dozzle_token,\n"]],
  "vault contract must enforce global ntfy token uniqueness and publisher separation"
)

# --- Downloader Phase 1 Usenet ownership ---------------------------------------
#
# Two of these are the byte-offset ordering failure this conversion is about: a
# task named in a comment sorts ahead of the task it names, and a substring that
# is a prefix of a longer identifier matches it.

check_rejected(
  failures, :downloaders, "the state guard replaced by a comment naming it",
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
  failures, :downloaders, "the CPU policy service renamed with the old name left in a comment",
  [[DOWNLOADERS_MAIN,
    "    container_cpu_service_name: downloaders\n",
    "    # container_cpu_service_name: downloaders\n" \
    "    container_cpu_service_name: usenet-downloaders\n"]],
  "downloaders role must verify its effective project CPU policy"
)

check_rejected(
  failures, :downloaders, "the activation gate demoted to a comment",
  [[DOWNLOADERS_MAIN,
    "  when: media_usenet_enabled | bool\n  register: downloaders_deploy\n",
    "  # when: media_usenet_enabled | bool\n  register: downloaders_deploy\n"]],
  "downloaders role must gate activation on media_usenet_enabled"
)

check_rejected(
  failures, :downloaders, "the Arr client reconciliation pointed at a different entry point",
  [[DOWNLOADERS_MAIN,
    "    tasks_from: reconcile_download_clients\n",
    "    tasks_from: reconcile_download_clients_disabled\n"]],
  "downloaders must reconcile Arr clients only after SABnzbd"
)

check_rejected(
  failures, :downloaders, "an API key bound to the wrong service",
  [[DOWNLOADERS_ENVIRONMENT,
    "SONARR_API_KEY={{ vault_arr_sonarr_api_key }}\n",
    "SONARR_API_KEY={{ vault_arr_radarr_api_key }}\n" \
    "# SONARR_API_KEY={{ vault_arr_sonarr_api_key }}\n"]],
  "downloaders env must carry only declared API keys"
)

check_rejected(
  failures, :downloaders, "SABnzbd bound to loopback with the old value left in a comment",
  [[DOWNLOADERS_INI,
    "host = 0.0.0.0\nport = 8080\n",
    "host = 127.0.0.1\nport = 8080\n# host = 0.0.0.0\n"]],
  "bootstrap must bind SABnzbd on all container interfaces"
)

check_rejected(
  failures, :downloaders, "a category destination fixed instead of declared",
  [[DOWNLOADERS_INI,
    "dir = {{ directory }}\n",
    "dir = /data/media/.acquisition/usenet\n# dir = {{ directory }}\n"]],
  "bootstrap must render every declared category and destination"
)

# Both absence invariants used to read the file's text, so writing down that the
# forbidden shape is deliberately absent was itself the forbidden shape.
check_accepted(
  failures, :downloaders, "a comment recording that no provider section is rendered",
  [[DOWNLOADERS_INI,
    "[misc]\n",
    "# No [servers] section: providers are the operator's, never ours.\n[misc]\n"]]
)

check_accepted(
  failures, :downloaders, "a comment explaining why categories are not a mapping",
  [[DOWNLOADERS_VERIFY,
    "---\n",
    "---\n# SABnzbd returns config.categories is mapping only on ancient builds.\n"]]
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

# Printed so the reuse is checkable from a build log rather than believed: one copy
# for every row means the verification is rejecting the copy every time and the
# rows are paying for a cache that is not working.
reuse = format("%<rows>d rows, %<copies>d repository copies", **COPY_ACCOUNTING.slice(:rows, :copies))
unless COPY_ACCOUNTING[:rebuilt].empty?
  warn "contract structure copy rebuilt after: #{COPY_ACCOUNTING[:rebuilt].join(', ')}"
end

report(failures,
       "Contract structure mutations: parsed task assertions reject every named shape (#{reuse})",
       "contract structure mutation failure(s)")
