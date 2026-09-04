#!/usr/bin/env ruby
# Behaviour and sequencing of tests/mac/read-integration-ports.rb.
#
# The reader is how tests/mac/run.sh learns which host ports an integration
# sandbox was allocated. It is fed a file the harness wrote outside the
# repository, and everything it accepts becomes a port the proof binds, so its
# whole job is refusing anything it was not handed itself. Until #315 it was a
# 30-line Ruby program inside a `<<'RUBY'` heredoc in tests/mac/run.sh: nothing
# syntax-checked it, and the only thing that ran it was a full integration proof.
#
# Two layers, following tests/mac/pin-protected-input-test.rb:
#
#   Behaviour -- drive the real program over real inputs, one case per refusal it
#   is supposed to make and one for the input it is supposed to accept. Every
#   refusal is the single word `unsafe` by design, so a case asserts the exit
#   status and that nothing was emitted: a reader that printed a partial roster
#   before refusing would bind ports out of a file it had just rejected.
#
#   Sequencing -- the file is opened once and the stat held through that
#   descriptor must agree with the lstat taken before it and the stat taken after
#   the read. That is an ordering, not an output: a reader that re-stats the path
#   by name instead answers about whatever the name points at now, and prints the
#   same ports. Those orderings are pinned as source text, the same way
#   tests/policy_mac_test.rb pins that reconciliation deploys before it verifies.
#
# Run with --self-test to prove both layers detect a planted regression.

require "fileutils"
require "json"
require "open3"
require "tmpdir"

PROGRAM = File.join(__dir__, "read-integration-ports.rb")
ROSTER = %w[beszel ntfy dozzle audiobookshelf].freeze
VALID = { "schema" => 1, "beszel_port" => 38_090, "ntfy_port" => 32_586,
          "dozzle_port" => 38_080, "audiobookshelf_port" => 33_378 }.freeze
EXPECTED_LINE = "38090 32586 38080 33378\n".freeze

def with_sandbox
  Dir.mktmpdir("nas-platform-ports-test.") do |raw|
    # Realpath, not the mktmpdir path: the program compares the input's parent
    # against a realpath, and macOS hands out /var/... symlinks for TMPDIR.
    root = File.realpath(raw)
    repository = File.join(root, "repo")
    FileUtils.mkdir_p(File.join(repository, "inside"))
    yield(root, repository)
  end
end

def write_input(path, document, mode: 0o600)
  File.write(path, document.is_a?(String) ? document : JSON.generate(document))
  File.chmod(mode, path)
  path
end

# label => builds the argv the program is run with, inside a fresh sandbox.
BEHAVIOUR = {
  "accepts a roster written outside the repository" => lambda do |root, repository|
    [[write_input(File.join(root, "ports.json"), VALID), repository, *ROSTER], :accept]
  end,
  "refuses an empty roster" => lambda do |root, repository|
    [[write_input(File.join(root, "ports.json"), VALID), repository], :refuse]
  end,
  "refuses a roster naming one service twice" => lambda do |root, repository|
    [[write_input(File.join(root, "ports.json"), VALID), repository, "beszel", "beszel"], :refuse]
  end,
  "refuses a relative path" => lambda do |root, repository|
    write_input(File.join(root, "ports.json"), VALID)
    [["ports.json", repository, *ROSTER], :refuse]
  end,
  "refuses a symlink to a valid input" => lambda do |root, repository|
    write_input(File.join(root, "ports.json"), VALID)
    link = File.join(root, "link.json")
    FileUtils.ln_s(File.join(root, "ports.json"), link)
    [[link, repository, *ROSTER], :refuse]
  end,
  "refuses an input inside the repository" => lambda do |_root, repository|
    [[write_input(File.join(repository, "inside", "ports.json"), VALID), repository, *ROSTER],
     :refuse]
  end,
  "refuses an input in the repository root itself" => lambda do |_root, repository|
    [[write_input(File.join(repository, "ports.json"), VALID), repository, *ROSTER], :refuse]
  end,
  "refuses a world-readable input" => lambda do |root, repository|
    [[write_input(File.join(root, "ports.json"), VALID, mode: 0o644), repository, *ROSTER],
     :refuse]
  end,
  "refuses an input larger than the cap" => lambda do |root, repository|
    padded = JSON.generate(VALID) + (" " * 5000)
    [[write_input(File.join(root, "ports.json"), padded), repository, *ROSTER], :refuse]
  end,
  "refuses a directory" => lambda do |root, repository|
    directory = File.join(root, "ports.json")
    FileUtils.mkdir_p(directory)
    [[directory, repository, *ROSTER], :refuse]
  end,
  "refuses malformed JSON" => lambda do |root, repository|
    [[write_input(File.join(root, "ports.json"), "{not json"), repository, *ROSTER], :refuse]
  end,
  "refuses a JSON array" => lambda do |root, repository|
    [[write_input(File.join(root, "ports.json"), "[1,2]"), repository, *ROSTER], :refuse]
  end,
  "refuses a document with no schema" => lambda do |root, repository|
    document = VALID.reject { |key, _| key == "schema" }
    [[write_input(File.join(root, "ports.json"), document), repository, *ROSTER], :refuse]
  end,
  "refuses an unknown schema" => lambda do |root, repository|
    [[write_input(File.join(root, "ports.json"), VALID.merge("schema" => 2)), repository, *ROSTER],
     :refuse]
  end,
  "refuses an unexpected key" => lambda do |root, repository|
    [[write_input(File.join(root, "ports.json"), VALID.merge("extra" => 1)), repository, *ROSTER],
     :refuse]
  end,
  "refuses a roster the document does not cover" => lambda do |root, repository|
    document = VALID.reject { |key, _| key == "ntfy_port" }
    [[write_input(File.join(root, "ports.json"), document), repository, *ROSTER], :refuse]
  end,
  "refuses a port that is not an integer" => lambda do |root, repository|
    document = VALID.merge("ntfy_port" => "32586")
    [[write_input(File.join(root, "ports.json"), document), repository, *ROSTER], :refuse]
  end,
  "refuses a privileged port" => lambda do |root, repository|
    [[write_input(File.join(root, "ports.json"), VALID.merge("ntfy_port" => 80)), repository,
      *ROSTER], :refuse]
  end,
  "refuses a port above the range" => lambda do |root, repository|
    document = VALID.merge("ntfy_port" => 70_000)
    [[write_input(File.join(root, "ports.json"), document), repository, *ROSTER], :refuse]
  end,
  "refuses two services sharing a port" => lambda do |root, repository|
    document = VALID.merge("ntfy_port" => 38_090)
    [[write_input(File.join(root, "ports.json"), document), repository, *ROSTER], :refuse]
  end
}.freeze

def behaviour_failures(program, only: nil)
  failures = []
  BEHAVIOUR.each do |label, build|
    next if only && !only.include?(label)

    with_sandbox do |root, repository|
      argv, expectation = build.call(root, repository)
      stdout, _stderr, status = Open3.capture3(program, *argv, stdin_data: "")
      if expectation == :accept
        failures << "#{label}: exited #{status.exitstatus}" unless status.success?
        failures << "#{label}: emitted #{stdout.inspect}" unless stdout == EXPECTED_LINE
      else
        failures << "#{label}: accepted the input" if status.success?
        failures << "#{label}: emitted #{stdout.inspect} before refusing" unless stdout.empty?
      end
    end
  end
  failures
end

# The orderings the reader's safety rests on, and which no output can show.
SEQUENCE = [
  ["the pre-open lstat is taken before the open",
   "before = File.lstat(path)"],
  ["the read happens through the held descriptor's stat",
   "held = input.stat"],
  ["the held stat is compared with the pre-open lstat",
   "raise \"unsafe\" unless [held.dev, held.ino, held.size, held.mode, held.uid] =="],
  ["the file is re-stat'd through the same descriptor after the read",
   "after = input.stat"],
  ["the open refuses to follow a symlink where the platform allows it",
   "flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)"]
].freeze

def sequence_failures(source)
  failures = []
  SEQUENCE.each do |label, literal|
    failures << "#{label} (#{literal.inspect} is absent)" unless source.include?(literal)
  end
  offsets = ["before = File.lstat(path)", "held = input.stat", "value = input.read(4097)",
             "after = input.stat"].map { |literal| source.index(literal) }
  failures << "the lstat, held stat, read and post-read stat are out of order" unless
    offsets.all? && offsets == offsets.compact.sort
  failures
end

def interface_failures(program)
  failures = []
  failures << "the program is missing" unless File.file?(program)
  failures << "the program is not executable" unless File.executable?(program)
  failures << "the program has no ruby shebang" unless
    File.file?(program) && File.open(program, &:readline).start_with?("#!")
  # The `-rjson` preload the heredoc was opened with has to be inside the file
  # now; without it the body raises NameError on the first JSON.parse.
  failures << "the program does not require json" unless
    File.file?(program) && File.read(program).include?("require \"json\"")
  failures
end

MUTATIONS = [
  { label: "a dropped mode check",
    from: "(before.mode & 0o777) == 0o600 && before.size <= 4096",
    to: "before.size <= 4096",
    cases: ["refuses a world-readable input"] },
  { label: "a dropped repository containment check",
    from: "raise \"unsafe\" if parent == repository || parent.start_with?(repository + File::SEPARATOR)",
    to: "",
    cases: ["refuses an input inside the repository", "refuses an input in the repository root itself"] },
  # Not the symlink check: lstat's `before.file?` and the NOFOLLOW open each
  # refuse a symlink on their own, so removing any one of the three changes no
  # outcome. A mutation nothing can detect is not evidence, so it is not listed.
  { label: "a dropped schema check",
    from: "document[\"schema\"] == 1",
    to: "document[\"schema\"].is_a?(Integer)",
    cases: ["refuses an unknown schema"] },
  { label: "a dropped key-set check",
    from: "document.keys.sort == ([\"schema\"] + expected).sort &&",
    to: "",
    cases: ["refuses an unexpected key"] },
  { label: "a dropped port range check",
    from: "port.is_a?(Integer) && port.between?(1024, 65_535)",
    to: "port.is_a?(Integer)",
    cases: ["refuses a privileged port", "refuses a port above the range"] },
  { label: "a dropped duplicate-port check",
    from: "ports.uniq.length == ports.length",
    to: "true",
    cases: ["refuses two services sharing a port"] }
].freeze

SEQUENCE_MUTATION = {
  label: "a post-read stat taken by name",
  from: "after = input.stat",
  to: "after = File.stat(path)"
}.freeze

def mutate(source, mutation)
  from = mutation.fetch(:from)
  abort "self-test could not plant #{mutation.fetch(:label)}: #{from.inspect} is absent" unless
    source.include?(from)

  source.sub(from, mutation.fetch(:to))
end

def with_mutant(source, mutation)
  Dir.mktmpdir("nas-platform-ports-mutant.") do |directory|
    path = File.join(directory, "read-integration-ports.rb")
    File.write(path, mutate(source, mutation))
    File.chmod(0o755, path)
    yield path
  end
end

source_text = File.file?(PROGRAM) ? File.read(PROGRAM) : ""

if ARGV.include?("--self-test")
  MUTATIONS.each do |mutation|
    with_mutant(source_text, mutation) do |mutant|
      caught = behaviour_failures(mutant, only: mutation.fetch(:cases))
      abort "self-test failed: #{mutation.fetch(:label)} was accepted" if caught.empty?
    end
  end
  planted = mutate(source_text, SEQUENCE_MUTATION)
  unless sequence_failures(planted).any?
    abort "self-test failed: #{SEQUENCE_MUTATION.fetch(:label)} was accepted"
  end
  puts "integration ports reader: self-test detects #{MUTATIONS.length + 1} planted regressions"
  exit
end

failures = interface_failures(PROGRAM) + sequence_failures(source_text) + behaviour_failures(PROGRAM)
abort failures.map { |failure| "FAIL #{failure}" }.join("\n") unless failures.empty?
puts "integration ports reader: #{BEHAVIOUR.length} behaviours and its ordering " \
     "properties verified against the real program"
