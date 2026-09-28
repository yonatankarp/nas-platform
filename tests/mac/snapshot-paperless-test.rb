#!/usr/bin/env ruby
# Offline proof of snapshot-paperless.rb's manifest logic (tamper, absent member,
# unknown schema). Deliberately a duplicate; run by snapshot-paperless.sh --self-test.
require "digest"
require "json"
require "pathname"
require "tmpdir"

MEMBERS = %w[archive.tar application.tar database.sql inbox.tar].freeze

def manifest_for(directory)
  {
    "schema" => 1,
    "members" => MEMBERS.map do |name|
      path = directory.join(name)
      { "name" => name, "bytes" => path.size,
        "sha256" => Digest::SHA256.file(path.to_s).hexdigest }
    end
  }
end

def problems(directory, manifest)
  failures = []
  failures << "manifest schema is not 1" unless manifest["schema"] == 1
  failures << "manifest members differ" unless
    Array(manifest["members"]).map { |member| member["name"] } == MEMBERS
  Array(manifest["members"]).each do |member|
    path = directory.join(member.fetch("name"))
    unless path.file? && !path.symlink?
      failures << "#{member.fetch('name')} is missing"
      next
    end
    failures << "#{member.fetch('name')} changed size" unless path.size == member.fetch("bytes")
    failures << "#{member.fetch('name')} changed content" unless
      Digest::SHA256.file(path.to_s).hexdigest == member.fetch("sha256")
  end
  failures
end

failures = []
Dir.mktmpdir("nas-platform-paperless-snapshot.") do |raw|
  directory = Pathname.new(raw)
  MEMBERS.each { |name| directory.join(name).write("#{name}\n") }
  manifest = manifest_for(directory)
  failures << "untouched manifest did not verify" unless problems(directory, manifest).empty?
  directory.join("archive.tar").write("tampered\n")
  failures << "archive tampering was not detected" unless
    problems(directory, manifest).any? { |problem| problem.include?("archive.tar") }
  directory.join("archive.tar").write("archive.tar\n")
  directory.join("inbox.tar").unlink
  failures << "missing inbox was not detected" unless
    problems(directory, manifest).any? { |problem| problem.include?("inbox.tar") }
  failures << "unknown schema was accepted" if problems(directory, { "schema" => 2, "members" => [] }).empty?
end

if failures.empty?
  puts "snapshot-paperless self-test: coordinated manifest logic holds"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} snapshot self-test failure(s)"
end
