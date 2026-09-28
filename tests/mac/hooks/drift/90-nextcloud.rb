#!/usr/bin/env ruby
# Overwrite the platform-owned trusted domain via occ (the reconcile's own interface).
# The index is searched for: the installer prepends localhost and appends without
# de-duplicating, so 127.0.0.1's position depends on how the stack was installed.
require "open3"

CONTAINER = ENV.fetch("PLATFORM_NEXTCLOUD_CONTAINER")
PLANTED = "nextcloud-drift.invalid"
OWNED = "127.0.0.1"

def refuse(message)
  warn "nextcloud drift: #{message}"
  exit 1
end

# occ as root writes root-owned files into the install tree and breaks the server.
def occ(*arguments)
  stdout, stderr, status = Open3.capture3(
    "docker", "exec", "--user", "www-data", CONTAINER, "php", "occ", *arguments
  )
  [stdout, stderr, status]
end

def trusted_domains
  stdout, stderr, status = occ("config:system:get", "trusted_domains")
  refuse("the deployed trusted domains could not be read: #{stderr.strip}") unless status.success?
  stdout.lines.map(&:strip).reject(&:empty?)
end

live = trusted_domains
refuse("the deployed instance trusts no domain at all, so this lane is not drifting anything") if
  live.empty?
index = live.index(OWNED)
refuse("the deployed instance already does not trust #{OWNED}, so this lane is not drifting " \
       "anything") if index.nil?

_out, error, status = occ("config:system:set", "trusted_domains", index.to_s, "--value=#{PLANTED}")
refuse("the hand edit could not be written inside #{CONTAINER}: #{error.strip}") unless
  status.success?

confirmed = trusted_domains
# Distinguish "write did not take" from "a duplicate entry still carries it".
if confirmed.include?(OWNED)
  refuse("the hand edit landed at index #{index} but #{OWNED} survives elsewhere in the trusted " \
         "domain list, so this lane has not removed the platform-owned entry") if
    confirmed[index] == PLANTED
  refuse("the hand edit did not reach the deployed configuration")
end
refuse("the hand edit did not land at index #{index}") unless confirmed[index] == PLANTED
