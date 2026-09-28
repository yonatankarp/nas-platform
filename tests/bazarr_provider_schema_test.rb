#!/usr/bin/env ruby
# frozen_string_literal: true

# docs/bazarr-providers.md must pass the real filter and be stamped with the
# deployed Bazarr minor (not patch: patches only add keys, and a patch-level
# stamp redded every Renovate batch). --self-test proves the check bites.

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
      # An appended block parses as a bare sequence; skipping it validated only the first.
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

# The filter is the authority, so run the blocks through it.
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
      declarations = module.acquisition_bazarr_declarations(
          payload["languages"], payload["providers"]
      )
      # Accepting a block is not the same as acting on it. A provider whose
      # settings mapping is empty carries no body of its own, so the connection
      # body is the only thing that enables it, and the projection looks every
      # declared name up in provider_settings -- where a missing entry is a
      # crash rather than a report.
      body = module.acquisition_bazarr_connection_body(
          declarations, "probe-user", "probe-password", "probe-radarr", "probe-sonarr", []
      )
      for name in declarations["provider_names"]:
          if name not in declarations["provider_settings"]:
              raise AssertionError(f"{name} has no provider_settings entry to project")
          if name not in body["settings-general-enabled_providers"]:
              raise AssertionError(f"{name} is not enabled by the connection body")
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

  deployed = compose_text[%r{image:\s*lscr\.io/linuxserver/bazarr:(\d+\.\d+)[^@\s]*}, 1]
  failures << "the compose file does not pin a readable Bazarr version" unless deployed
  stamp = doc_text[/Derived from Bazarr \*\*([^*]+)\*\*/, 1]
  documented = stamp[/\A\d+\.\d+\z/] if stamp
  if stamp.nil?
    failures << "docs/bazarr-providers.md has no `Derived from Bazarr **<major>.<minor>**` line"
  elsif documented.nil?
    failures << "docs/bazarr-providers.md records Bazarr #{stamp.inspect}, which is not a major.minor " \
                "release; write it as `Derived from Bazarr **#{stamp[/\A\d+\.\d+/] || '<major>.<minor>'}**`"
  end
  if deployed && documented && deployed != documented
    failures << "docs/bazarr-providers.md was derived from Bazarr #{documented} but services/arr/compose.yml " \
                "deploys #{deployed}; re-derive the provider settings keys from #{deployed}'s " \
                "bazarr/app/config.py, then change the stamp to `Derived from Bazarr **#{deployed}**`"
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

  # Together and individually: a reader copies one provider, not the file.
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
  stale = doc_text.sub(/Derived from Bazarr \*\*[^*]+\*\*/, "Derived from Bazarr **0.0**")
  unless collect_failures(stale, compose_text).any? { |failure| failure.include?("re-derive") }
    abort "self-test failed: a stale derivation version was accepted"
  end
  patch_stamp = doc_text.sub(/Derived from Bazarr \*\*([^*]+)\*\*/, "Derived from Bazarr **\\1.1**")
  unless collect_failures(patch_stamp, compose_text).any? { |failure| failure.include?("not a major.minor") }
    abort "self-test failed: a patch-level stamp was not named as the wrong shape"
  end
  minor = compose_text[%r{bazarr:(\d+\.\d+)}, 1]
  patched = compose_text.sub(%r{(bazarr:\d+\.\d+)[^@\s]*}, "\\1.999")
  abort "self-test could not plant a patch bump" if patched == compose_text
  unless collect_failures(doc_text, patched).empty?
    abort "self-test failed: a patch bump within #{minor} was refused"
  end
  bumped = compose_text.sub(%r{bazarr:\d+\.\d+[^@\s]*}, "bazarr:#{minor.split('.').first}.999.0")
  unless collect_failures(doc_text, bumped).any? { |failure| failure.include?("re-derive") }
    abort "self-test failed: a minor bump was accepted"
  end
  puts "bazarr provider schemas: self-test detects a bad key and a stale minor, and admits a patch"
  exit
end

failures = collect_failures(doc_text, compose_text)
abort failures.join("\n") unless failures.empty?
puts "bazarr provider schemas: documented blocks validate against Bazarr #{compose_text[%r{bazarr:([0-9][^@\s]*)}, 1]}"
