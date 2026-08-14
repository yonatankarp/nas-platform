#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

output, inventory_path = ARGV
vault = YAML.safe_load($stdin.read, aliases: false)
inventory = YAML.safe_load_file(inventory_path, aliases: false)
managed = vault.fetch("vault_managed_users").fetch("immich")
raise "managed" unless managed.is_a?(Array) && !managed.empty?

email = managed.first.fetch("email")
raise "email" unless email.is_a?(String) && email.match?(/\A[^@ ]+@[^@ ]+\z/)

standard = inventory.fetch("immich_managed_user_preference_profiles").fetch("standard")
document = {
  "immich_managed_user_preference_profile_default" => "standard",
  "immich_managed_user_preference_profiles" => {
    "standard" => standard,
    "compact" => {
      "avatar" => {},
      "folders" => { "enabled" => true },
      "people" => { "sidebarWeb" => true }
    }
  },
  "immich_managed_user_preference_profile_by_email" => {
    " #{email.upcase} " => "compact"
  },
  "immich_managed_user_preference_overrides" => {
    " #{email.capitalize} " => { "people" => { "minimumFaces" => 7 } }
  },
  "immich_contract_partial_profile_email" => email
}

File.open(output, File::WRONLY | File::TRUNC, 0o600) { |file| file.write(YAML.dump(document)) }
