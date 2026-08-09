#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
SCRIPT = File.join(ROOT, "scripts", "portainer-parity.rb")
MAPPING = File.join(ROOT, "config", "portainer-parity.yml")
COMMIT = "400f03f276ae1bb69f5460c175b9fb923d620f1a"
CANARY = "PORTAINER-PARITY-CANARY-DO-NOT-LEAK"

require_relative "../scripts/portainer-parity"

def assert(condition, message)
  raise message unless condition
end

def assert_raises(message)
  yield
  raise "#{message}: expected failure"
rescue PortainerParityError
  # expected
end

def mapping_document
  YAML.safe_load_file(MAPPING, aliases: false)
end

def fixture_values(mapping)
  mapping.fetch("stacks").transform_values do |rules|
    rules.keys.to_h { |key| [key, "value-#{key}"] }
  end.tap do |stacks|
    stacks.fetch("beszel")["BESZEL_AGENT_KEY"] = " spaced $dollar #hash = equals "
    stacks.fetch("beszel")["BESZEL_AGENT_TOKEN"] = ""
    stacks.fetch("immich")["DB_PASSWORD"] = %q{"quoted" \\ slash $value #tag}
  end
end

def write_fixture(directory, mapping, values = fixture_values(mapping))
  values.each do |stack, entries|
    File.binwrite(File.join(directory, "#{stack}.env"), entries.map { |key, value| "#{key}=#{value}" }.join("\n") + "\n")
  end
  values
end

def run_cli(*arguments)
  Open3.capture3(RbConfig.ruby, SCRIPT, *arguments)
end

def assert_failure(label, *arguments)
  stdout, stderr, status = run_cli(*arguments)
  assert(!status.success?, "#{label}: expected failure")
  assert(stdout.empty?, "#{label}: stdout must be empty")
  assert(stderr.lines.length == 1, "#{label}: stderr must be exactly one line")
  assert(stderr.start_with?("portainer-parity-error:"), "#{label}: missing error prefix")
  assert(!stderr.include?(CANARY), "#{label}: leaked canary")
  assert(!stderr.include?("backtrace"), "#{label}: leaked backtrace")
  assert(!stderr.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/), "#{label}: unsanitized control byte")
end

def with_fixture
  Dir.mktmpdir("nas-platform-portainer-parity-") do |directory|
    mapping = mapping_document
    values = write_fixture(directory, mapping)
    yield directory, mapping, values
  end
end

def test_parse_env_literal_preservation
  with_fixture do |directory, _mapping, values|
    parsed = parse_env(File.join(directory, "beszel.env"))
    assert(parsed["BESZEL_AGENT_KEY"] == values["beszel"]["BESZEL_AGENT_KEY"], "space-dollar-hash-equals value changed")
    assert(parsed["BESZEL_AGENT_TOKEN"] == "", "empty value changed")
    assert(parse_env(File.join(directory, "immich.env"))["DB_PASSWORD"] == values["immich"]["DB_PASSWORD"], "quotes or backslashes changed")
  end
end

def test_direct_build_and_deterministic_serialization
  with_fixture do |directory, mapping, values|
    result = build_parity(directory, mapping, COMMIT)
    assert(result.dig("stacks", "beszel", "BESZEL_AGENT_KEY") == values["beszel"]["BESZEL_AGENT_KEY"], "build changed literal value")
    yaml = serialize(result, "yaml")
    json = serialize(result, "json")
    assert(yaml == serialize(result, "yaml"), "YAML is not deterministic")
    assert(json == serialize(result, "json"), "JSON is not deterministic")
    assert(YAML.safe_load(yaml, aliases: false) == result, "YAML round trip changed values")
    assert(JSON.parse(json) == result, "JSON round trip changed values")
  end
end

def test_cli_output
  with_fixture do |directory, _mapping, values|
    stdout, stderr, status = run_cli("--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT)
    assert(status.success?, "CLI YAML failed: #{stderr}")
    assert(stderr.empty?, "CLI YAML wrote stderr")
    assert(YAML.safe_load(stdout, aliases: false).dig("stacks", "beszel", "BESZEL_AGENT_KEY") == values["beszel"]["BESZEL_AGENT_KEY"], "CLI YAML changed value")
    stdout, stderr, status = run_cli("--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT, "--format", "json")
    assert(status.success?, "CLI JSON failed: #{stderr}")
    assert(stderr.empty?, "CLI JSON wrote stderr")
    assert(JSON.parse(stdout).dig("stacks", "immich", "DB_PASSWORD") == values["immich"]["DB_PASSWORD"], "CLI JSON changed value")
  end
end

def test_direct_parser_rejects_bad_env_bytes_and_lines
  Dir.mktmpdir("nas-platform-portainer-parity-env-") do |directory|
    path = File.join(directory, "sample.env")
    {
      "duplicate" => "A=1\nA=#{CANARY}\n",
      "unknown shape" => "bad-name=#{CANARY}\n",
      "indented" => " A=#{CANARY}\n",
      "export" => "export A=#{CANARY}\n",
      "NUL" => "A=#{CANARY}\0\n",
      "CR" => "A=#{CANARY}\r\n",
      "invalid encoding" => "A=\xFF\n"
    }.each do |label, source|
      File.binwrite(path, source)
      assert_raises(label) { parse_env(path) }
    end
  end
end

def test_cli_rejects_bad_env_bytes_and_lines_without_leaks
  {
    "duplicate" => "TZ=#{CANARY}\nTZ=#{CANARY}\n",
    "malformed name" => "bad-name=#{CANARY}\n",
    "indented assignment" => " TZ=#{CANARY}\n",
    "export syntax" => "export TZ=#{CANARY}\n",
    "NUL" => "TZ=#{CANARY}\0\n",
    "CR" => "TZ=#{CANARY}\r\n",
    "invalid encoding" => "TZ=\xFF\n"
  }.each do |label, source|
    with_fixture do |directory, _mapping, _values|
      File.binwrite(File.join(directory, "dozzle.env"), source)
      assert_failure(label, "--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT)
    end
  end
end

def test_cli_rejects_input_and_mapping_mutations_without_leaks
  with_fixture do |directory, mapping, _values|
    File.delete(File.join(directory, "dozzle.env"))
    assert_failure("missing file", "--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT)
  end

  with_fixture do |directory, _mapping, _values|
    File.binwrite(File.join(directory, "extra.env"), "A=#{CANARY}\n")
    assert_failure("extra file", "--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT)
  end

  with_fixture do |directory, _mapping, _values|
    FileUtils.mkdir(File.join(directory, "extra-dir"))
    assert_failure("directory child", "--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT)
  end

  Dir.mktmpdir("nas-platform-portainer-parity-link-") do |directory|
    target = File.join(directory, "target")
    FileUtils.mkdir(target)
    File.symlink(target, File.join(directory, "linked"))
    assert_failure("input symlink", "--input-dir", File.join(directory, "linked"), "--mapping", MAPPING, "--legacy-commit", COMMIT)
  end

  with_fixture do |directory, _mapping, _values|
    path = File.join(directory, "dozzle.env")
    File.delete(path)
    File.symlink(File.join(directory, "audiobookshelf.env"), path)
    assert_failure("file symlink", "--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT)
  end

  with_fixture do |directory, _mapping, _values|
    path = File.join(directory, "dozzle.env")
    File.binwrite(path, "TZ=#{CANARY}\nUNKNOWN=#{CANARY}\n")
    assert_failure("unknown key", "--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT)
  end

  with_fixture do |directory, _mapping, _values|
    path = File.join(directory, "dozzle.env")
    File.binwrite(path, "TZ=#{CANARY}\nTZ=#{CANARY}\n")
    assert_failure("duplicate key", "--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT)
  end

  with_fixture do |directory, _mapping, _values|
    File.binwrite(File.join(directory, "dozzle.env"), "# comment\n\n")
    assert_failure("missing key", "--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT)
  end

  Dir.mktmpdir("nas-platform-portainer-parity-mapping-") do |directory|
    paths = {
      "wrong schema" => "schema: 2\nlegacy_commit: #{COMMIT}\nstacks: {}\n",
      "wrong commit" => "schema: 1\nlegacy_commit: #{'a' * 40}\nstacks: {}\n",
      "duplicate YAML key" => "schema: 1\nschema: 1\nlegacy_commit: #{COMMIT}\nstacks: {}\n",
      "alias" => "schema: 1\nlegacy_commit: #{COMMIT}\nstacks: &stacks {}\n",
      "malformed root" => "schema: 1\nlegacy_commit: #{COMMIT}\nstacks: []\n",
      "malformed rule" => "schema: 1\nlegacy_commit: #{COMMIT}\nstacks: {dozzle: {TZ: nope}}\n",
      "unexpected rule field" => "schema: 1\nlegacy_commit: #{COMMIT}\nstacks: {dozzle: {TZ: {classification: inventory, target: nas_timezone, extra: no}}}\n"
    }
    paths.each do |label, source|
      path = File.join(directory, "#{label.tr(' ', '-')}.yml")
      File.binwrite(path, source)
      with_fixture do |input, _mapping, _values|
        assert_failure(label, "--input-dir", input, "--mapping", path, "--legacy-commit", COMMIT)
      end
    end
  end

  with_fixture do |directory, _mapping, _values|
    assert_failure("wrong CLI commit", "--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", "a" * 40)
    assert_failure("bad format", "--input-dir", directory, "--mapping", MAPPING, "--legacy-commit", COMMIT, "--format", "toml")
    assert_failure("missing options", "--input-dir", directory)
  end
end

test_parse_env_literal_preservation
test_direct_build_and_deterministic_serialization
test_cli_output
test_direct_parser_rejects_bad_env_bytes_and_lines
test_cli_rejects_bad_env_bytes_and_lines_without_leaks
test_cli_rejects_input_and_mapping_mutations_without_leaks

puts "Portainer parity parser: strict non-evaluating input holds"
