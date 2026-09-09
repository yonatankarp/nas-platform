#!/usr/bin/env ruby
# Overwrite the one trusted domain this platform owns, which is the drift the
# Mac lane's reconcile repairs.
#
# usage: 90-nextcloud.rb   (no arguments; every input is an environment variable)
#
# tests/mac/hooks/drift/90-nextcloud.sh is the hook this belongs to. It requires
# PLATFORM_NEXTCLOUD_CONTAINER, runs this program, and then insists the Nextcloud
# contract refuses the drifted deployment. Only the mutation lives here; the
# hook's comment records why this setting is the one worth drifting and why the
# refusal it produces is not the one a reader would guess.
#
# The index is found rather than assumed. roles/nextcloud declares 127.0.0.1
# first, but the deployed array is not the declared list: the image's installer
# writes localhost at index 0 and then appends NEXTCLOUD_TRUSTED_DOMAINS from
# index 1 without de-duplicating, so the position of 127.0.0.1 is a property of
# how the stack was installed rather than of what the role declares. Setting the
# wrong index would overwrite a different domain and this hook would then be
# asserting the repair of something it did not mean to break.
#
# The edit goes through occ rather than a file write. trusted_domains lives in
# config.php, which the image writes as its own service account inside a bind
# mount, and occ is the only interface that rewrites a single array position
# without reformatting the document around it -- which is also the interface
# roles/nextcloud/tasks/reconcile_trusted_domains.yml uses to repair it.
require "open3"

CONTAINER = ENV.fetch("PLATFORM_NEXTCLOUD_CONTAINER")
PLANTED = "nextcloud-drift.invalid"
OWNED = "127.0.0.1"

def refuse(message)
  warn "nextcloud drift: #{message}"
  exit 1
end

# --user www-data, and it is not decoration: occ run as root writes root-owned
# files into the installation tree, which is how a container that was serving
# stops being able to. roles/nextcloud runs it the same way for the same reason.
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
# 127.0.0.1 still being trusted has two causes and they are not the same failure,
# so they are not reported as one. Either the write did not take, or it took and
# a duplicate entry elsewhere in the array still carries the domain -- occ sets
# one index and the installer appends without de-duplicating, which is the same
# property the index search above exists for. The second is unreachable today:
# roles/nextcloud/defaults applies `unique` to the declared list and env.j2 omits
# localhost, so there is no second copy to survive. It is distinguished anyway,
# because a diagnostic that says the edit never landed when the edit landed
# perfectly sends a reader to the wrong half of this program.
if confirmed.include?(OWNED)
  refuse("the hand edit landed at index #{index} but #{OWNED} survives elsewhere in the trusted " \
         "domain list, so this lane has not removed the platform-owned entry") if
    confirmed[index] == PLANTED
  refuse("the hand edit did not reach the deployed configuration")
end
refuse("the hand edit did not land at index #{index}") unless confirmed[index] == PLANTED
