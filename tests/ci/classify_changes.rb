#!/usr/bin/env ruby

require "json"
require "open3"

module ClassifyChanges
  LANES = %w[
    static foundation smoke beszel dozzle audiobookshelf media paperless idempotence_check
  ].freeze
  # The integration suite each lane dispatches, in the order the CI matrix runs
  # them. `static` is not a suite.
  SUITES = {
    "foundation" => "foundation",
    "smoke" => "smoke",
    "beszel" => "beszel",
    "dozzle" => "dozzle",
    "audiobookshelf" => "audiobookshelf",
    "media" => "media",
    "paperless" => "paperless",
    "idempotence_check" => "idempotence-check"
  }.freeze
  SERVICE_LANES = %w[beszel dozzle audiobookshelf media paperless].freeze
  SERVICE_TAGS = {
    "beszel" => %w[host_prep deployment_bundle ntfy beszel],
    "dozzle" => %w[host_prep deployment_bundle ntfy dozzle],
    "audiobookshelf" => %w[host_prep deployment_bundle audiobookshelf],
    "media" => %w[host_prep deployment_bundle komga tinymediamanager jellyfin immich],
    "paperless" => %w[host_prep deployment_bundle paperless]
  }.freeze
  SERVICE_NAMES = {
    "beszel" => %w[beszel],
    "dozzle" => %w[dozzle],
    "audiobookshelf" => %w[audiobookshelf],
    "media" => %w[komga tinymediamanager jellyfin immich],
    "paperless" => %w[paperless paperless-ngx paperless_ngx]
  }.freeze

  module_function

  def classify(paths, full: false)
    selection = LANES.to_h { |lane| [lane, false] }
    return selection.transform_values { true } if full

    service_lanes = []
    paths.each do |raw_path|
      path = raw_path.to_s.sub(%r{\A\./}, "")
      next if inert_path?(path)

      lane = service_lane(path)
      return selection.transform_values { true } unless lane

      service_lanes << lane
    end

    unless service_lanes.empty?
      %w[static smoke idempotence_check].each { |lane| selection[lane] = true }
      service_lanes.each { |lane| selection[lane] = true }
    end
    selection
  end

  def changed_paths(base, head)
    output, error, status = Open3.capture3(
      "git", "diff", "--name-status", "-z", "--find-renames", "--find-copies-harder",
      "#{base}...#{head}"
    )
    raise "git diff failed: #{error.strip}" unless status.success?

    fields = output.split("\0", -1)
    fields.pop if fields.last == ""
    paths = []
    until fields.empty?
      status_field = fields.shift
      if status_field.start_with?("R", "C")
        raise "malformed git diff output" if fields.length < 2

        paths << fields.shift << fields.shift
      else
        raise "malformed git diff output" if fields.empty?

        paths << fields.shift
      end
    end
    paths
  end

  def write_github_outputs(selection, io)
    LANES.each { |lane| io.puts "#{lane}=#{selection.fetch(lane)}" }
    io.puts "suites=#{suites(selection).to_json}"
    io.puts "run_ci=#{selection.values.any?}"
    tags = if selection.fetch("foundation")
             []
           else
             SERVICE_LANES.filter { |lane| selection.fetch(lane) }
                          .flat_map { |lane| SERVICE_TAGS.fetch(lane) }
                          .uniq
           end
    io.puts "selected_tags=#{tags.join(',')}"
  end

  def suites(selection)
    SUITES.filter_map { |lane, suite| suite if selection.fetch(lane) }
  end

  def inert_path?(path)
    return true if path == "README.md" || path == ".gitignore" || path.match?(%r{\ALICENSE(?:\.[^/]+)?\z})
    return true if path.match?(%r{\A(?:\.idea|\.vscode)/}) || path == ".editorconfig"
    return true if path.start_with?("docs/")
    return false if path == "AGENTS.md" || path.match?(%r{\A(?:tests|fixtures|scripts)/})

    path.end_with?(".md")
  end

  def service_lane(path)
    SERVICE_NAMES.each do |lane, names|
      names.each do |name|
        return lane if path.start_with?("roles/#{name}/", "services/#{name}/")
        return lane if path.match?(%r{\Atests/contracts/#{Regexp.escape(name)}(?:[-.]|\z)})
      end
    end
    nil
  end

  def parse_cli(arguments)
    modes = []
    output_path = nil
    index = 0
    while index < arguments.length
      case arguments[index]
      when "--github-output"
        return nil if output_path || index + 1 >= arguments.length

        output_path = arguments[index + 1]
        index += 2
      when "--full"
        modes << [:full]
        index += 1
      when "--diff"
        return nil if index + 2 >= arguments.length || arguments[index + 1].start_with?("--") ||
                      arguments[index + 2].start_with?("--")

        modes << [:diff, arguments[index + 1], arguments[index + 2]]
        index += 3
      when "--files"
        index += 1
        files = []
        while index < arguments.length && !arguments[index].start_with?("--")
          files << arguments[index]
          index += 1
        end
        return nil if files.empty?

        modes << [:files, files]
      else
        return nil
      end
    end
    return nil unless modes.length == 1

    [modes.first, output_path]
  end

  def run_cli(arguments)
    parsed = parse_cli(arguments)
    unless parsed
      warn "usage: classify_changes.rb (--files PATH... | --diff BASE HEAD | --full) " \
           "[--github-output PATH]"
      return 2
    end

    mode, output_path = parsed
    selection = case mode.first
                when :full
                  classify([], full: true)
                when :diff
                  classify(changed_paths(mode[1], mode[2]))
                when :files
                  classify(mode[1])
                end
    if output_path
      File.open(output_path, "w") { |io| write_github_outputs(selection, io) }
    else
      write_github_outputs(selection, $stdout)
    end
    0
  rescue StandardError => e
    warn e.message
    1
  end
end

exit ClassifyChanges.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
