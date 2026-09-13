# Reads the storage inventory the way Ansible composes it.
#
# nas_storage is no longer written in one place. Each service declares
# nas_storage_<role> in inventory/group_vars/all/service_<role>.yml, the two
# shared media groups declare their own, and main.yml composes whatever is
# present:
#
#   platform_storage_names: "{{ q('varnames', '^nas_storage_') | sort }}"
#   nas_storage: "{{ q('vars', *platform_storage_names) | flatten(levels=1) | sort(attribute='path') }}"
#
# The rule is derived on both sides rather than restated as a list of services,
# for the reason tests/idempotence_shard_partition_test.rb records: adding a
# service already touches 59 files and a sixtieth list is the one nobody edits.
# This file is the Ruby half of that rule, and every static reader of the storage
# inventory goes through it so there is one place the rule is written.
#
# What a derived rule cannot do is notice that it lost everything. Deleting every
# contributor leaves nas_storage as [] and the play reports ok, measured
# 2026-09-12. So membership is checked against services/manifest.yml in both
# directions below, and host_prep asserts a floor before it creates anything.
require "yaml"

module NasStorage
  CONTRIBUTOR_PREFIX = "nas_storage_".freeze

  # The contributors that are not a service. Both are shared by construction: arr
  # mounts the whole media root, jellyfin mounts all of Media and komga all of
  # Books, so the library roots belong to no one service, and downloaders writes
  # the acquisition trees that arr reads. They are two files rather than one
  # because they carry different recovery classes, and the recovery class drives
  # the disaster-recovery documentation.
  #
  # Closed in both directions by problems below, the way
  # CREDENTIAL_FREE_SERVICES in tests/policy_support.rb is: a name here that no
  # file defines exempts nothing, and a file here that this list does not name
  # would be a third shared group nobody decided to add.
  SHARED_CONTRIBUTORS = %w[
    nas_storage_media_libraries
    nas_storage_media_acquisition
  ].freeze

  # A service that owns no storage of its own. Empty today: all seventeen
  # implemented roles own at least one directory. Kept, and closed in both
  # directions, because a service that loses its last entry must fail as loudly
  # as one that gains a first.
  STORAGE_FREE_SERVICES = [].freeze

  # The collapse floor, and deliberately a stated number rather than a count
  # derived from the roster. Membership below is the real check; this catches the
  # case membership cannot, which is the composition returning nothing at all
  # because the glob matched nothing. It only has to be large enough that an
  # empty or nearly empty result fails, so it does not track the roster and does
  # not need bumping when a service is added. roles/host_prep asserts the same
  # number on the Ansible side, where the manifest is not readable.
  MINIMUM_CONTRIBUTORS = 12

  module_function

  def group_vars_dir(root)
    File.join(root, "inventory", "group_vars", "all")
  end

  # Every group_vars file that is readable YAML. An encrypted vault is skipped
  # rather than parsed: it holds no storage contributor, and safe_load_file on
  # ciphertext raises or returns a string depending on the header.
  def readable_documents(root)
    Dir.glob(File.join(group_vars_dir(root), "*.yml")).sort.filter_map do |path|
      next if File.basename(path) == "vault.yml.example"

      first = File.open(path) { |handle| handle.gets }
      next if first.nil? || first.start_with?("$ANSIBLE_VAULT")

      document = YAML.safe_load_file(path, aliases: true)
      next unless document.is_a?(Hash)

      [path, document]
    end
  end

  # The whole non-secret inventory as one hash, which is what "the shared
  # inventory" means now that it is a directory rather than a file. Ansible
  # composes exactly this view, so a check that swept main.yml for a property --
  # the vault_ prefix sweep in tests/policy_vault_test.rb is the one that matters
  # -- has to sweep all of it or the property stops holding for nineteen files it
  # used to cover. Duplicate keys raise: Ansible would silently let the
  # last-loaded file win, and a key defined twice across this directory is the
  # failure this split exists to make impossible.
  def shared_inventory(root)
    merged = {}
    readable_documents(root).each do |path, document|
      document.each do |key, value|
        raise "#{key} is defined twice; the second is in #{path}" if merged.key?(key)

        merged[key] = value
      end
    end
    merged
  end

  # {contributor_variable => entries}, which is what the varnames lookup sees.
  def contributors(root)
    found = {}
    readable_documents(root).each do |path, document|
      document.each do |key, value|
        next unless key.is_a?(String) && key.start_with?(CONTRIBUTOR_PREFIX)

        raise "#{key} is defined twice; the second is in #{path}" if found.key?(key)
        raise "#{key} in #{path} is #{value.class}, expected a list" unless value.is_a?(Array)

        found[key] = value
      end
    end
    found
  end

  # The composed inventory, ordered exactly as Ansible orders it: contributors by
  # variable name, then the whole list sorted by path. The path sort is what puts
  # every parent ahead of its children, because a parent path is a prefix of them.
  def entries(root)
    found = contributors(root)
    found.keys.sort.flat_map { |name| found.fetch(name) }
         .sort_by { |entry| entry.fetch("path") }
  end

  def role_for(contributor)
    contributor.delete_prefix(CONTRIBUTOR_PREFIX)
  end

  # Membership, in both directions, against the roster the manifest already
  # states. This is what makes the derived composition safe: a service dropped
  # from it fails here by name rather than contributing nothing.
  def problems(root, implemented_roles)
    problems = []
    found = contributors(root)

    if found.size < MINIMUM_CONTRIBUTORS
      problems << "only #{found.size} nas_storage_* contributors were found in " \
                  "#{group_vars_dir(root)}, below the stated floor of " \
                  "#{MINIMUM_CONTRIBUTORS}: a composition that matched nothing " \
                  "evaluates to an empty inventory and reports success"
    end

    expected_roles = implemented_roles - STORAGE_FREE_SERVICES
    missing = expected_roles.reject { |role| found.key?("#{CONTRIBUTOR_PREFIX}#{role}") }
    unless missing.empty?
      problems << "#{missing.sort.join(', ')} declare no #{CONTRIBUTOR_PREFIX}<role> " \
                  "variable: an implemented service contributes its own storage or is " \
                  "named in STORAGE_FREE_SERVICES"
    end

    unexpected = found.keys - SHARED_CONTRIBUTORS
    unexpected.reject! { |name| implemented_roles.include?(role_for(name)) }
    unless unexpected.empty?
      problems << "#{unexpected.sort.join(', ')} name no implemented service and are not " \
                  "in SHARED_CONTRIBUTORS: a contributor the roster does not account for " \
                  "adds paths host_prep creates and nothing else checks"
    end

    absent_shared = SHARED_CONTRIBUTORS - found.keys
    unless absent_shared.empty?
      problems << "SHARED_CONTRIBUTORS names #{absent_shared.sort.join(', ')}, which no " \
                  "group_vars file defines: an exemption that outlives its subject exempts " \
                  "nothing and hides the next contributor that takes the name"
    end

    stray_free = STORAGE_FREE_SERVICES - implemented_roles
    unless stray_free.empty?
      problems << "STORAGE_FREE_SERVICES names #{stray_free.sort.join(', ')}, which no " \
                  "implemented service accounts for"
    end

    claimed_free = STORAGE_FREE_SERVICES.select { |role| found.key?("#{CONTRIBUTOR_PREFIX}#{role}") }
    unless claimed_free.empty?
      problems << "#{claimed_free.sort.join(', ')} are in STORAGE_FREE_SERVICES but do " \
                  "declare storage: an exemption that is not exercised is a claim nothing tests"
    end

    problems
  end
end
