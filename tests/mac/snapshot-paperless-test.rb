#!/usr/bin/env ruby
# Offline proof of the coordinated manifest logic tests/mac/snapshot-paperless.rb
# uses to decide whether a snapshot is intact.
#
# usage: snapshot-paperless-test.rb   (no arguments, no Docker, no network)
#
# It builds a throwaway directory of the four members a snapshot holds, takes a
# manifest of them, and then checks that the manifest verifies what it should and
# refuses tampering, an absent member and an unknown schema. The logic is a
# duplicate of the snapshot program's on purpose: this half must be provable
# without a deployment, and the contract holds the two halves to each other.
#
# tests/mac/snapshot-paperless.sh --self-test runs it, which is how the policy
# gate reaches it. It ran from a `<<'RUBY'` heredoc in that wrapper until #315,
# opened as a bare `ruby -` with no `-r` preloads, where sh -n, ruby -c and a
# reader could reach none of it -- and the gate did not run it at all until the
# commit before this one. The body below is byte-identical to what that heredoc
# rendered, its own requires included.
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
