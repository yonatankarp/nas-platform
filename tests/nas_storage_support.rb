# Reads the storage inventory the way Ansible composes it from every nas_storage_*
# variable (see CLAUDE.md). The Ruby half of that derived rule; since deleting every
# contributor silently yields [], membership is checked against the manifest both ways.
require "yaml"

module NasStorage
  CONTRIBUTOR_PREFIX = "nas_storage_".freeze

  # Shared, not per-service contributors (library roots and acquisition trees), split by
  # recovery class. Closed both ways, like CREDENTIAL_FREE_SERVICES.
  SHARED_CONTRIBUTORS = %w[
    nas_storage_media_libraries
    nas_storage_media_acquisition
  ].freeze

  # Empty today; kept and closed both ways so a service losing its last entry fails.
  STORAGE_FREE_SERVICES = [].freeze

  # Collapse floor, stated rather than derived; roles/host_prep asserts the same number.
  MINIMUM_CONTRIBUTORS = 12

  module_function

  def group_vars_dir(root)
    File.join(root, "inventory", "group_vars", "all")
  end

  # Encrypted vaults are skipped: no contributor, and ciphertext parses unpredictably.
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

  # The whole non-secret inventory as one hash, as Ansible sees it. Duplicate keys raise,
  # where Ansible would silently let the last file win.
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

  # Ordered as Ansible orders it; the path sort puts every parent before its children.
  def entries(root)
    found = contributors(root)
    found.keys.sort.flat_map { |name| found.fetch(name) }
         .sort_by { |entry| entry.fetch("path") }
  end

  def role_for(contributor)
    contributor.delete_prefix(CONTRIBUTOR_PREFIX)
  end

  # Membership both ways against the manifest roster.
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
