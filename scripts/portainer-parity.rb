#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"

class PortainerParityError < StandardError; end

module PortainerParity
  ROOT_FIELDS = %w[legacy_commit schema stacks].freeze
  CLASSIFICATIONS = %w[excluded inventory role vault].freeze
  EXPECTED_VARIABLES = {
    "audiobookshelf" => %w[TZ].freeze,
    "beszel" => %w[BESZEL_AGENT_KEY BESZEL_AGENT_TOKEN BESZEL_APP_URL BESZEL_SYSTEM_NAME TZ].freeze,
    "dozzle" => %w[TZ].freeze,
    "immich" => %w[DB_DATABASE_NAME DB_PASSWORD DB_USERNAME TZ].freeze,
    "jellyfin" => %w[TZ].freeze,
    "komga" => %w[GROUP_ID TZ USER_ID].freeze,
    "ntfy" => %w[GROUP_ID NTFY_BASE_URL TZ USER_ID].freeze,
    "paperless-ngx" => %w[
      DB_NAME DB_PASSWORD DB_USER GROUP_ID PAPERLESS_AI_ENABLED
      PAPERLESS_AI_LLM_ENDPOINT PAPERLESS_AI_LLM_MODEL PAPERLESS_SECRET_KEY
      PAPERLESS_TASK_WORKERS PAPERLESS_THREADS_PER_WORKER TZ USER_ID
    ].freeze,
    "tinymediamanager" => %w[GROUP_ID PASSWORD TZ USER_ID].freeze
  }.freeze
  REQUIRED_STACKS = EXPECTED_VARIABLES.keys.sort.freeze
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

  def same_file?(left, right)
    left.dev == right.dev && left.ino == right.ino
  end

  def read_regular_file(path, label)
    initial = File.lstat(path)
    fail!("unsafe #{label}") unless initial.file? && !initial.symlink?

    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    file = File.open(path, flags)
    opened = file.stat
    fail!("unsafe #{label}") unless opened.file? && same_file?(initial, opened)

    file.binmode
    file.read
  rescue SystemCallError, IOError
    fail!("#{label} is unavailable")
  ensure
    file&.close
  end

  def string_identifier!(value, label, pattern)
    fail!("#{label} is invalid") unless value.is_a?(String) && pattern.match?(value)
  end

  def inspect_yaml_tree!(source)
    tree = Psych.parse_stream(source)
    fail!("mapping must contain exactly one YAML document") unless tree.children.length == 1

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
    source = read_regular_file(path, "mapping")
    inspect_yaml_tree!(source)
    document = YAML.safe_load(source, aliases: false, filename: sanitized(path))
    fail!("mapping document is empty") if document.nil?

    document
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
    fail!("mapping stack set differs") unless stacks.keys.all? { |key| key.is_a?(String) } &&
                                                 stacks.keys.sort == REQUIRED_STACKS
    stacks.each do |stack, rules|
      string_identifier!(stack, "stack name", STACK_NAME)
      validate_rules!(rules, stack)
    end
    document
  end

  def validate_rules!(rules, stack)
    rules = mapping!(rules, "stack rules")
    fail!("stack variable set differs") unless rules.keys.all? { |key| key.is_a?(String) } &&
                                                   rules.keys.sort == EXPECTED_VARIABLES.fetch(stack)
    rules.each do |key, rule|
      string_identifier!(key, "variable name", ENVIRONMENT_NAME)
      validate_rule!(rule)
    end
  end

  def validate_decrypted_document(source, mapping_path, commit)
    inspect_yaml_tree!(source)
    document = YAML.safe_load(source, aliases: false, filename: sanitized(mapping_path))
    document = mapping!(document, "decrypted document")
    exact_fields!(document, ROOT_FIELDS, "decrypted document root")
    fail!("decrypted schema is invalid") unless document["schema"] == 1
    validate_commit!(document["legacy_commit"])
    validate_commit!(commit, "requested legacy commit")
    fail!("legacy commit mismatch") unless document["legacy_commit"] == commit

    mapping = validate_mapping(load_mapping(mapping_path), commit)
    stacks = mapping!(document["stacks"], "decrypted stacks")
    fail!("decrypted stack set differs") unless stacks.keys.all? { |key| key.is_a?(String) } &&
                                                   stacks.keys.sort == REQUIRED_STACKS
    stacks.each do |stack, values|
      rules = mapping.fetch("stacks").fetch(stack)
      values = mapping!(values, "decrypted stack")
      fail!("decrypted variable set differs") unless values.keys.all? { |key| key.is_a?(String) } &&
                                                        values.keys.sort == rules.keys.sort
      fail!("decrypted value is invalid") unless values.values.all? { |value| value.is_a?(String) }
    end
    true
  rescue Psych::Exception
    fail!("decrypted YAML is malformed")
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
    bytes = read_regular_file(path, "environment file")
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
  end

  def build_parity(input_dir, mapping, commit)
    document = validate_mapping(mapping, commit)
    initial_directory = File.lstat(input_dir)
    fail!("unsafe input directory") unless initial_directory.directory? && !initial_directory.symlink?

    stacks = document.fetch("stacks")
    expected_files = stacks.keys.map { |name| "#{name}.env" }.sort
    fail!("stack file set differs from mapping") unless Dir.children(input_dir).sort == expected_files

    values = stacks.keys.sort.to_h do |stack|
      parsed = parse_env(File.join(input_dir, "#{stack}.env"))
      rules = stacks.fetch(stack)
      fail!("stack variable set differs from mapping") unless parsed.keys.sort == rules.keys.sort

      [stack, parsed.keys.sort.to_h { |key| [key, parsed.fetch(key)] }]
    end
    current_directory = File.lstat(input_dir)
    fail!("unsafe input directory") unless current_directory.directory? && same_file?(initial_directory, current_directory)

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
    options = { validate_stdin: false }
    set = lambda do |key, value|
      fail!("command line is invalid") if options.key?(key)

      options[key] = value
    end
    parser = OptionParser.new do |opts|
      opts.on("--input-dir DIR") { |value| set.call(:input_dir, value) }
      opts.on("--mapping FILE") { |value| set.call(:mapping, value) }
      opts.on("--legacy-commit COMMIT") { |value| set.call(:legacy_commit, value) }
      opts.on("--format FORMAT") { |value| set.call(:format, value) }
      opts.on("--validate-stdin") do
        fail!("command line is invalid") if options[:validate_stdin]

        options[:validate_stdin] = true
      end
    end
    parser.parse!(arguments)
    fail!("unexpected positional argument") unless arguments.empty?
    %i[mapping legacy_commit].each { |key| fail!("#{key.to_s.tr('_', ' ')} is required") unless options[key] }
    if options[:validate_stdin]
      fail!("command line is invalid") if options[:input_dir] || options[:format]
    else
      fail!("input dir is required") unless options[:input_dir]
      options[:format] ||= "yaml"
      fail!("format is invalid") unless %w[yaml json].include?(options[:format])
    end
    options
  rescue OptionParser::ParseError
    fail!("command line is invalid")
  end

  def run(arguments)
    options = parse_options(arguments)
    if options[:validate_stdin]
      validate_decrypted_document(STDIN.read, options.fetch(:mapping), options.fetch(:legacy_commit))
      puts "Portainer parity: decrypted schema is valid"
      return
    end

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
