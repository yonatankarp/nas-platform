#!/usr/bin/env ruby

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../policy_support"

include TestScaffold

REPORT = File.join(ROOT, "tests", "mac", "report.rb")
source = File.read(REPORT)

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

def report_input
  {
    "schema" => 1,
    "lane" => "fresh",
    "proof_platform" => "mac",
    "platform_kind" => "mac",
    "platform_compose_kind" => "mac",
    "callback_host" => "host.docker.internal",
    "sandbox_id" => "nas-platform-mac.Report1",
    "project_name" => "nas-platform-mac-report1",
    "beszel_port" => 38_090,
    "ntfy_port" => 32_586,
    "dozzle_port" => 38_080,
    "audiobookshelf_port" => 33_378,
    "komga_port" => 35_600,
    "jellyfin_port" => 38_096,
    "immich_port" => 32_283,
    "paperless_port" => 38_000,
    "radarr_port" => 37_878,
    "sonarr_port" => 38_989,
    "prowlarr_port" => 36_969,
    "bazarr_port" => 36_767,
    "sabnzbd_port" => 38_082,
    "pinchflat_port" => 38_945,
    "kapowarr_port" => 35_656,
    "git_revision" => "abc123",
    "vault_checksum" => "0" * 64,
    "diagnostic_locations" => [],
    "phases" => []
  }
end

def rendered_media_fields(report_path, expected, phases: [])
  Dir.mktmpdir("media-acquisition-report.") do |directory|
    input = File.join(directory, "input.json")
    json = File.join(directory, "report.json")
    markdown = File.join(directory, "report.md")
    File.write(input, JSON.generate(report_input.merge("phases" => phases)))
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, report_path, "--input", input, "--json", json, "--markdown", markdown
    )
    return ["report call site failed: #{stdout}#{stderr}"] unless status.success?

    actual = File.readlines(markdown, chomp: true).grep(/\AMEDIA_ACQUISITION_[A-Z]+:/)
    actual == expected ? [] : ["report call site emitted #{actual.inspect} instead of the exact four fields"]
  end
end

finished_at = "2026-08-25T12:00:00Z"
passed_verify = [{ "name" => "verify", "status" => "passed", "finished_at" => finished_at }]
failed_verify = [{ "name" => "verify", "status" => "failed", "finished_at" => finished_at }]
failures.concat(rendered_media_fields(REPORT, expected, phases: passed_verify))
failures.concat(
  rendered_media_fields(REPORT, [], phases: []).map do |failure|
    "absent verification emitted observed-state claims: #{failure}"
  end
)
failures.concat(
  rendered_media_fields(REPORT, [], phases: failed_verify).map do |failure|
    "failed verification emitted observed-state claims: #{failure}"
  end
)

Dir.mktmpdir("media-acquisition-report-mutant.") do |directory|
  mutant = File.join(directory, "report.rb")
  mutated = source.sub("    *media_acquisition_foundation_report(report),\n", "")
  failures << "report mutation did not remove the markdown call site" if mutated == source
  File.write(mutant, mutated)
  failures << "report test accepts removal of the markdown call site" if
    rendered_media_fields(mutant, expected, phases: passed_verify).empty?
end

report(failures, "media acquisition report: four bounded non-secret fields hold",
       "media acquisition report regression(s)")
