#!/usr/bin/env ruby
# Offline self-test for the Immich snapshot manifest. The functions are a copy of
# snapshot-immich.rb's, which cannot be required: it reads the vault at load time.
require "digest"
require "fileutils"
require "json"
require "pathname"
require "tmpdir"

def manifest_for(directory, members)
  {
    "schema" => 1,
    "members" => members.sort.map do |member|
      path = directory.join(member)
      { "name" => member, "bytes" => path.size,
        "sha256" => Digest::SHA256.file(path.to_s).hexdigest }
    end
  }
end

def verify_manifest(directory, manifest)
  problems = []
  problems << "manifest schema is not 1" unless manifest["schema"] == 1
  Array(manifest["members"]).each do |member|
    path = directory.join(member.fetch("name"))
    unless path.file? && !path.symlink?
      problems << "#{member.fetch('name')} is missing"
      next
    end
    problems << "#{member.fetch('name')} changed size" unless path.size == member.fetch("bytes")
    problems << "#{member.fetch('name')} changed content" unless
      Digest::SHA256.file(path.to_s).hexdigest == member.fetch("sha256")
  end
  problems
end

failures = []
def check(failures, condition, message)
  failures << message unless condition
end

Dir.mktmpdir("nas-platform-snapshot-selftest") do |raw|
  directory = Pathname.new(raw)
  directory.join("database.sql").write("-- dump\n")
  directory.join("originals.tar").write("originals")
  directory.join("profile.tar").write("profile")
  directory.join("generated.tar").write("generated")
  members = %w[database.sql generated.tar originals.tar profile.tar]
  manifest = manifest_for(directory, members)

  check(failures, manifest.fetch("members").map { |m| m.fetch("name") } == members,
        "manifest must record every coordinated member in a stable order")
  check(failures, verify_manifest(directory, manifest).empty?,
        "an untouched snapshot must verify clean")

  directory.join("originals.tar").write("originals-tampered")
  problems = verify_manifest(directory, manifest)
  check(failures, problems.any? { |problem| problem.include?("originals.tar") },
        "a changed original must be reported")
  directory.join("originals.tar").write("originals")
  check(failures, verify_manifest(directory, manifest).empty?,
        "restoring the exact bytes must verify clean again")

  # Same length, different content: a size-only check would pass this.
  directory.join("database.sql").write("-- DUMP\n")
  check(failures, verify_manifest(directory, manifest).any? { |p| p.include?("changed content") },
        "a same-length edit must still be reported")
  directory.join("database.sql").write("-- dump\n")

  directory.join("generated.tar").unlink
  check(failures, verify_manifest(directory, manifest).any? { |p| p.include?("missing") },
        "a missing member must be reported")

  check(failures, verify_manifest(directory, { "schema" => 2, "members" => [] }).any?,
        "an unknown manifest schema must be refused")
end

if failures.empty?
  puts "snapshot-immich self-test: coordinated manifest logic holds"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} snapshot self-test failure(s)"
end
