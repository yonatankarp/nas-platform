#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"

class PortainerParityError < StandardError; end

module PortainerParity
  ROOT_FIELDS = %w[legacy_commit schema stacks].freeze
  CLASSIFICATIONS = %w[excluded inventory role vault].freeze
  ENVIRONMENT_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
  STACK_NAME = /\A[a-z0-9][a-z0-9-]*\z/
  COMMIT = /\A[0-9a-f]{40}\z/

  module_function

  def fail!(message)
    raise PortainerParityError, message
  end

  def sanitized(message)
    message.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?").gsub(/[[:cntrl:]]/, "?")
  end

  def validate_commit!(commit, label = "legacy commit")
    fail!("#{label} is invalid") unless commit.is_a?(String) && COMMIT.match?(commit)
  end

  def mapping!(value, label)
    fail!("#{label} must be a mapping") unless value.is_a?(Hash)

    value
  end

  def exact_fields!(value, expected, label)
    fail!("#{label} fields differ") unless value.keys.all? { |key| key.is_a?(String) } && value.keys.sort == expected
  end

  def string_identifier!(value, label, pattern)
    fail!("#{label} is invalid") unless value.is_a?(String) && pattern.match?(value)
  end

  def inspect_yaml_tree!(source)
    tree = Psych.parse_stream(source)
    traverse_yaml!(tree)
  rescue Psych::Exception
    fail!("mapping YAML is malformed")
  end

  def traverse_yaml!(node)
    fail!("mapping contains YAML aliases") if node.is_a?(Psych::Nodes::Alias) ||
                                              (node.respond_to?(:anchor) && node.anchor)

    if node.is_a?(Psych::Nodes::Mapping)
      keys = node.children.each_slice(2).map do |key, _value|
        fail!("mapping has a malformed key") unless key.is_a?(Psych::Nodes::Scalar)

        key.value
      end
      fail!("mapping contains duplicate YAML keys") unless keys.uniq.length == keys.length
    end

    Array(node.children).each { |child| traverse_yaml!(child) } if node.respond_to?(:children)
  end

  def load_mapping(path)
    fail!("mapping is unsafe") unless File.file?(path) && !File.symlink?(path)

    source = File.binread(path)
    inspect_yaml_tree!(source)
    YAML.safe_load_file(path, aliases: false)
  rescue SystemCallError
    fail!("mapping is unavailable")
  rescue Psych::Exception
    fail!("mapping YAML is malformed")
  end

  def validate_mapping(mapping, commit = nil)
    document = mapping!(mapping, "mapping")
    exact_fields!(document, ROOT_FIELDS, "mapping root")
    fail!("mapping schema is invalid") unless document["schema"] == 1

    legacy_commit = document["legacy_commit"]
    validate_commit!(legacy_commit)
    validate_commit!(commit, "requested legacy commit") if commit
    fail!("legacy commit mismatch") if commit && legacy_commit != commit

    stacks = mapping!(document["stacks"], "mapping stacks")
    fail!("mapping stacks are empty") if stacks.empty?
    stacks.each do |stack, rules|
      string_identifier!(stack, "stack name", STACK_NAME)
      validate_rules!(rules, stack)
    end
    document
  end

  def validate_rules!(rules, stack)
    rules = mapping!(rules, "stack rules")
    fail!("stack rules are empty") if rules.empty?
    rules.each do |key, rule|
      string_identifier!(key, "variable name", ENVIRONMENT_NAME)
      validate_rule!(rule)
    end
  end

  def validate_rule!(rule)
    rule = mapping!(rule, "mapping rule")
    classification = rule["classification"]
    fail!("rule classification is invalid") unless classification.is_a?(String) && CLASSIFICATIONS.include?(classification)

    expected = classification == "excluded" ? %w[classification reason] : %w[classification target]
    exact_fields!(rule, expected, "rule")

    if classification == "excluded"
      fail!("rule exclusion reason is invalid") unless rule["reason"].is_a?(String) && !rule["reason"].empty?
    else
      target = rule["target"]
      fail!("rule target is invalid") unless target.is_a?(String) && !target.empty?
    end
  end

  def parse_env(path)
    fail!("unsafe environment file") unless File.file?(path) && !File.symlink?(path)

    bytes = File.binread(path)
    fail!("environment file contains NUL") if bytes.include?("\0")
    fail!("environment file contains CR") if bytes.include?("\r")
    fail!("environment file has invalid encoding") unless bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?

    values = {}
    bytes.force_encoding(Encoding::UTF_8).split("\n", -1).each_with_index do |line, index|
      next if line.empty? || /\A[ \t]*#/.match?(line)

      match = /\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/.match(line)
      fail!("environment line #{index + 1} is malformed") unless match

      key, value = match.captures
      fail!("environment variable is duplicated") if values.key?(key)

      values[key] = value
    end
    values
  rescue SystemCallError
    fail!("environment file is unavailable")
  end

  def build_parity(input_dir, mapping, commit)
    document = validate_mapping(mapping, commit)
    fail!("unsafe input directory") unless File.directory?(input_dir) && !File.symlink?(input_dir)

    stacks = document.fetch("stacks")
    expected_files = stacks.keys.map { |name| "#{name}.env" }.sort
    fail!("stack file set differs from mapping") unless Dir.children(input_dir).sort == expected_files

    values = stacks.keys.sort.to_h do |stack|
      parsed = parse_env(File.join(input_dir, "#{stack}.env"))
      rules = stacks.fetch(stack)
      fail!("stack variable set differs from mapping") unless parsed.keys.sort == rules.keys.sort

      [stack, parsed.keys.sort.to_h { |key| [key, parsed.fetch(key)] }]
    end
    { "schema" => 1, "legacy_commit" => commit, "stacks" => values }
  rescue SystemCallError
    fail!("input directory is unavailable")
  end

  def serialize(document, format)
    case format
    when "yaml" then YAML.dump(document)
    when "json" then "#{JSON.generate(document)}\n"
    else fail!("format is invalid")
    end
  rescue JSON::GeneratorError, Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
    fail!("parity document cannot be serialized")
  end

  def parse_options(arguments)
    options = { format: "yaml" }
    parser = OptionParser.new do |opts|
      opts.on("--input-dir DIR") { |value| options[:input_dir] = value }
      opts.on("--mapping FILE") { |value| options[:mapping] = value }
      opts.on("--legacy-commit COMMIT") { |value| options[:legacy_commit] = value }
      opts.on("--format FORMAT") { |value| options[:format] = value }
    end
    parser.parse!(arguments)
    fail!("unexpected positional argument") unless arguments.empty?
    %i[input_dir mapping legacy_commit].each { |key| fail!("#{key.to_s.tr('_', ' ')} is required") unless options[key] }
    fail!("format is invalid") unless %w[yaml json].include?(options[:format])
    options
  rescue OptionParser::ParseError
    fail!("command line is invalid")
  end

  def run(arguments)
    options = parse_options(arguments)
    mapping = load_mapping(options.fetch(:mapping))
    document = build_parity(options.fetch(:input_dir), mapping, options.fetch(:legacy_commit))
    STDOUT.write(serialize(document, options.fetch(:format)))
  end
end

def parse_env(path)
  PortainerParity.parse_env(path)
end

def validate_mapping(mapping, commit = nil)
  PortainerParity.validate_mapping(mapping, commit)
end

def build_parity(input_dir, mapping, commit)
  PortainerParity.build_parity(input_dir, mapping, commit)
end

def serialize(document, format)
  PortainerParity.serialize(document, format)
end

if $PROGRAM_NAME == __FILE__
  begin
    PortainerParity.run(ARGV)
  rescue PortainerParityError => error
    warn "portainer-parity-error: #{PortainerParity.sanitized(error.message)}"
    exit 1
  rescue StandardError
    warn "portainer-parity-error: processing failed"
    exit 1
  end
end
