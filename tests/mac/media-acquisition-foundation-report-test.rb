#!/usr/bin/env ruby

ROOT = File.expand_path("../..", __dir__)
source = File.read(File.join(ROOT, "tests", "mac", "report.rb"))

expected = [
  "MEDIA_ACQUISITION_FOUNDATION: network present, bridge driver, isolated project name, Jellyfin and Audiobookshelf attached to default and media-control",
  "MEDIA_ACQUISITION_STORAGE: 28 exact classified paths present",
  "MEDIA_ACQUISITION_TRANSPORTS: usenet=false torrent=false",
  "MEDIA_ACQUISITION_CONTAINERS: none declared or started"
]

failures = []
expected.each { |line| failures << "report omits bounded field #{line}" unless source.include?(line) }
section = source[/def media_acquisition_foundation_report.*?^end/m].to_s
failures << "report must expose exactly four bounded media acquisition fields" unless
  expected.all? { |line| section.include?(line) } && section.scan(/MEDIA_ACQUISITION_[A-Z]+:/).length == 4
%w[password secret token authorization private_key ACL].each do |forbidden|
  failures << "media acquisition report leaks or claims #{forbidden}" if section.downcase.include?(forbidden.downcase)
end
failures << "media acquisition report must not enumerate storage or containers" if
  section.match?(/Dir\.|glob|docker|nas_storage|\.acquisition\/|radarr|sonarr|sabnzbd/i)

if failures.empty?
  puts "media acquisition report: four bounded non-secret fields hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} media acquisition report regression(s)"
end
