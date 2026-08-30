#!/usr/bin/env ruby
# frozen_string_literal: true

# The pinned Bazarr provider schemas must be usable and current.
#
# media_bazarr_providers is validated against no list of known providers: any
# lowercase name with a non-empty settings mapping passes. A misspelled key
# therefore converges and fetches nothing, so the operator's protection is that
# docs/bazarr-providers.md carries blocks derived from the deployed version
# rather than remembered.
#
# Two ways that protection rots, and both are checked here. The blocks stop
# matching what the role accepts, which this catches by running them through
# the real filter. Or Bazarr is upgraded and upstream renames a setting, which
# this catches by pinning the version the file was derived from to the version
# the compose file deploys.
#
# Run with --self-test to prove the check detects its own regression.

require "json"
require "open3"
require "yaml"

ROOT = File.expand_path("..", __dir__)
DOC = File.join(ROOT, "docs", "bazarr-providers.md")
COMPOSE = File.join(ROOT, "services", "arr", "compose.yml")

def documented_blocks(text)
  text.scan(/```yaml\n(.*?)```/m).flatten
end

def documented_providers(text)
  documented_blocks(text).flat_map do |block|
    parsed = begin
      YAML.safe_load(block)
    rescue Psych::SyntaxError
      nil
    end
    case parsed
    when Hash
      # A complete declaration, carrying its own key.
      Array(parsed["media_bazarr_providers"])
    when Array
      # A block a reader appends to one: the indented list fragment parses as a
      # sequence on its own. Skipping these silently is how this file came to
      # validate only its first provider.
      parsed
    else
      []
    end
  end.compact.select { |entry| entry.is_a?(Hash) && entry.key?("name") }
end

def ansible_python
  version, status = Open3.capture2("ansible-playbook", "--version")
  return nil unless status.success?

  path = version[/^\s*python version = .*\((\/[^()]*)\)$/, 1]
  path if path && File.executable?(path)
end

# The filter is the authority on what converges, so the documented blocks are
# run through it rather than re-checked against a copy of its rules.
VALIDATION_PROGRAM = <<~PYTHON
  import importlib.util, json, pathlib, sys

  root = pathlib.Path(sys.argv[1])
  spec = importlib.util.spec_from_file_location(
      "acquisition_bazarr", root / "filter_plugins" / "acquisition_bazarr.py"
  )
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)

  payload = json.load(sys.stdin)
  try:
      module.acquisition_bazarr_declarations(payload["languages"], payload["providers"])
  except Exception as caught:
      json.dump({"error": str(caught)}, sys.stdout)
  else:
      json.dump({"error": None}, sys.stdout)
PYTHON

def validate(providers, languages)
  python = ansible_python
  return "the Ansible interpreter is unavailable" unless python

  output, errors, status = Open3.capture3(
    python, "-c", VALIDATION_PROGRAM, ROOT,
    stdin_data: JSON.generate({ "providers" => providers, "languages" => languages })
  )
  return "validation probe failed: #{errors}" unless status.success?

  JSON.parse(output)["error"]
end

def collect_failures(doc_text, compose_text)
  failures = []

  deployed = compose_text[%r{image:\s*lscr\.io/linuxserver/bazarr:([0-9][^@\s]*)}, 1]
  failures << "the compose file does not pin a readable Bazarr version" unless deployed
  documented = doc_text[/Derived from Bazarr \*\*([^*]+)\*\*/, 1]
  failures << "the provider reference does not record the version it was derived from" unless documented
  if deployed && documented && deployed != documented
    failures << "the provider reference was derived from Bazarr #{documented} but " \
                "#{deployed} is deployed; re-derive the settings keys from that release"
  end

  providers = documented_providers(doc_text)
  failures << "the provider reference documents no provider blocks" if providers.empty?

  languages = documented_blocks(doc_text).filter_map do |block|
    parsed = begin
      YAML.safe_load(block)
    rescue Psych::SyntaxError
      nil
    end
    parsed["media_bazarr_languages"] if parsed.is_a?(Hash)
  end.flatten
  failures << "the provider reference documents no language example" if languages.empty?

  # Every documented block must be one the role would accept, together and
  # individually: a reader copies one provider, not the file.
  error = validate(providers, languages)
  failures << "the documented providers are rejected by the role: #{error}" if error
  providers.each do |provider|
    single = validate([provider], languages)
    failures << "documented provider #{provider['name'].inspect} is rejected: #{single}" if single
  end

  failures
end

doc_text = File.read(DOC)
compose_text = File.read(COMPOSE)

if ARGV.include?("--self-test")
  planted = doc_text.sub("settings-ktuvit-hashed_password", "settings-ktuvit-hashed-password")
  abort "self-test could not plant a hyphenated setting suffix" if planted == doc_text
  unless collect_failures(planted, compose_text).any? { |failure| failure.include?("ktuvit") }
    abort "self-test failed: a hyphenated setting suffix was accepted"
  end
  stale = doc_text.sub(/Derived from Bazarr \*\*[^*]+\*\*/, "Derived from Bazarr **0.0.0**")
  unless collect_failures(stale, compose_text).any? { |failure| failure.include?("re-derive") }
    abort "self-test failed: a stale derivation version was accepted"
  end
  puts "bazarr provider schemas: self-test detects a bad key and a stale version"
  exit
end

failures = collect_failures(doc_text, compose_text)
abort failures.join("\n") unless failures.empty?
puts "bazarr provider schemas: documented blocks validate against Bazarr #{compose_text[%r{bazarr:([0-9][^@\s]*)}, 1]}"
