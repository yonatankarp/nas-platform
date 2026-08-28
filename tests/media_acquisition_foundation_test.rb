#!/usr/bin/env ruby

require "open3"
require "set"
require "yaml"

ROOT = File.expand_path("..", __dir__)
CATALOG_PATH = File.join(ROOT, "config", "media-acquisition.yml")
ACQUISITION_PROJECTS = Set[
  "arr", "downloaders", "bindery", "kapowarr", "pinchflat", "trailarr", "seerr"
].freeze
ACQUISITION_JOB_SERVICES = Set["configarr"].freeze
FOUNDATION_WRAPPER_SOURCE = <<~'SH'.freeze
  #!/bin/sh
  set -eu
  set +x

  project=$(basename -- "$0" -foundation.sh)
  case $project in
    arr|downloaders|bindery|kapowarr|pinchflat|trailarr|seerr) ;;
    *) printf '%s\n' 'unknown acquisition foundation contract' >&2; exit 2 ;;
  esac
  mode=${1:-static}
  repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
  [ "$mode" = static ] || { printf '%s\n' "$project foundation contract accepts only static" >&2; exit 2; }
  ruby "$repo_dir/tests/media_acquisition_foundation_test.rb" --project "$project"
SH

def parse_project_selection(arguments)
  return nil if arguments.empty?
  return arguments.fetch(1) if arguments.length == 2 && arguments.first == "--project" &&
                               ACQUISITION_PROJECTS.include?(arguments.fetch(1))

  abort "usage: ruby tests/media_acquisition_foundation_test.rb [--project NAME]"
end

SELECTED_PROJECT = parse_project_selection(ARGV).freeze

def ui_port(port, container_port: port, published_by:)
  [{
    "purpose" => "web_ui",
    "protocol" => "tcp",
    "bind_address" => "0.0.0.0",
    "exposure" => "lan_mesh",
    "host_port" => port,
    "container_port" => container_port,
    "published_by" => published_by
  }]
end

def service(service_class, cpus, host_ports = [], compose_profile: nil)
  value = { "class" => service_class, "cpus" => cpus, "host_ports" => host_ports }
  value["compose_profile"] = compose_profile if compose_profile
  value
end

EXPECTED_PROJECTS = {
  "arr" => {
    "role" => "arr", "status" => "implemented", "services" => {
      "radarr" => service("long_running", 1.0, ui_port(7878, published_by: "radarr")),
      "sonarr" => service("long_running", 1.0, ui_port(8989, published_by: "sonarr")),
      "prowlarr" => service("long_running", 0.5, ui_port(9696, published_by: "prowlarr")),
      "bazarr" => service("long_running", 1.0, ui_port(6767, published_by: "bazarr")),
      "configarr" => service("one_shot", 0.5, [], compose_profile: "jobs")
    }
  },
  "downloaders" => {
    "role" => "downloaders", "status" => "implemented", "services" => {
      "sabnzbd" => service("long_running", 2.0,
                           ui_port(8085, container_port: 8080, published_by: "sabnzbd")),
      "unpackerr" => service("long_running", 1.0),
      "gluetun" => service("long_running", 0.5, [], compose_profile: "torrent"),
      "qbittorrent" => service("long_running", 1.5, [
        { "purpose" => "web_ui", "protocol" => "tcp", "bind_address" => "0.0.0.0",
          "exposure" => "lan_mesh", "host_port" => 8082, "container_port" => 8082,
          "published_by" => "gluetun" },
        { "purpose" => "peer", "protocol" => "tcp", "bind_address" => "0.0.0.0",
          "exposure" => "lan_mesh", "host_port" => 6881, "container_port" => 6881,
          "published_by" => "gluetun" },
        { "purpose" => "peer", "protocol" => "udp", "bind_address" => "0.0.0.0",
          "exposure" => "lan_mesh", "host_port" => 6881, "container_port" => 6881,
          "published_by" => "gluetun" }
      ], compose_profile: "torrent")
    }
  },
  "bindery" => {
    "role" => "bindery", "status" => "planned", "services" => {
      "bindery" => service("long_running", 1.0, ui_port(8787, published_by: "bindery"))
    }
  },
  "kapowarr" => {
    "role" => "kapowarr", "status" => "planned", "services" => {
      "kapowarr" => service("long_running", 1.0, ui_port(5656, published_by: "kapowarr"))
    }
  },
  "pinchflat" => {
    "role" => "pinchflat", "status" => "planned", "services" => {
      "pinchflat" => service("long_running", 1.0, ui_port(8945, published_by: "pinchflat"))
    }
  },
  "trailarr" => {
    "role" => "trailarr", "status" => "planned", "services" => {
      "trailarr" => service("long_running", 1.0, ui_port(7889, published_by: "trailarr"))
    }
  },
  "seerr" => {
    "role" => "seerr", "status" => "planned", "services" => {
      "seerr" => service("long_running", 1.0, ui_port(5055, published_by: "seerr"))
    }
  }
}.freeze

EXPECTED = {
  "schema" => 1,
  "enabled" => false,
  "network" => { "logical_name" => "media-control", "driver" => "bridge" },
  "filesystem_identity" => {
    "uid_environment" => "NAS_UID", "gid_environment" => "NAS_GID", "umask" => "022"
  },
  "configuration_ownership" => {
    "configarr" => %w[
      radarr_naming sonarr_naming radarr_quality sonarr_quality
      radarr_custom_formats sonarr_custom_formats
    ],
    "ansible" => {
      "prowlarr" => %w[
        authentication radarr_application sonarr_application full_sync
        operator_selected_indexers verification
      ],
      "radarr_sonarr" => %w[sabnzbd_download_client],
      "prowlarr_download_clients" => []
    }
  },
  "projects" => EXPECTED_PROJECTS
}.freeze

EXPECTED_IMPLEMENTED_PORTS = [
  ["arr", "bazarr", "0.0.0.0", 6767, 6767, "tcp"],
  ["arr", "prowlarr", "0.0.0.0", 9696, 9696, "tcp"],
  ["arr", "radarr", "0.0.0.0", 7878, 7878, "tcp"],
  ["arr", "sonarr", "0.0.0.0", 8989, 8989, "tcp"],
  ["audiobookshelf", "audiobookshelf", "0.0.0.0", 13_378, 80, "tcp"],
  ["beszel", "hub", "0.0.0.0", 8090, 8090, "tcp"],
  ["beszel", "socket-proxy", "127.0.0.1", 2375, 2375, "tcp"],
  ["dozzle", "dozzle", "0.0.0.0", 8080, 8080, "tcp"],
  ["downloaders", "sabnzbd", "0.0.0.0", 8085, 8080, "tcp"],
  ["immich", "immich-server", "0.0.0.0", 2283, 2283, "tcp"],
  ["jellyfin", "jellyfin", "0.0.0.0", 8096, 8096, "tcp"],
  ["komga", "komga", "0.0.0.0", 25_600, 25_600, "tcp"],
  ["ntfy", "ntfy", "0.0.0.0", 2586, 80, "tcp"],
  ["paperless-ngx", "broker", "127.0.0.1", 6379, 6379, "tcp"],
  ["paperless-ngx", "db", "127.0.0.1", 5432, 5432, "tcp"],
  ["paperless-ngx", "gotenberg", "127.0.0.1", 3000, 3000, "tcp"],
  ["paperless-ngx", "tika", "127.0.0.1", 9998, 9998, "tcp"]
].freeze

EXPECTED_STORAGE = {
  "{{ nas_media_root }}/Media/.acquisition/usenet/movies" => "cache",
  "{{ nas_media_root }}/Media/.acquisition/usenet/series" => "cache",
  "{{ nas_media_root }}/Media/.acquisition/usenet/audiobooks" => "cache",
  "{{ nas_media_root }}/Media/.acquisition/torrents/movies" => "cache",
  "{{ nas_media_root }}/Media/.acquisition/torrents/series" => "cache",
  "{{ nas_media_root }}/Media/.acquisition/torrents/audiobooks" => "cache",
  "{{ nas_media_root }}/Books/.acquisition/usenet/ebooks" => "cache",
  "{{ nas_media_root }}/Books/.acquisition/usenet/comics" => "cache",
  "{{ nas_media_root }}/Books/.acquisition/torrents/ebooks" => "cache",
  "{{ nas_media_root }}/Books/.acquisition/torrents/comics" => "cache",
  "{{ nas_media_root }}/Media/Movies" => "user",
  "{{ nas_media_root }}/Media/Series" => "user",
  "{{ nas_media_root }}/Media/Audiobooks" => "user",
  "{{ nas_media_root }}/Media/YouTube" => "user",
  "{{ nas_media_root }}/Books" => "user",
  "{{ nas_media_root }}/Books/Ebooks" => "user",
  "{{ nas_media_root }}/Books/Comics" => "user",
  "{{ nas_docker_root }}/radarr/config" => "critical",
  "{{ nas_docker_root }}/sonarr/config" => "critical",
  "{{ nas_docker_root }}/prowlarr/config" => "critical",
  "{{ nas_docker_root }}/bazarr/config" => "critical",
  "{{ nas_docker_root }}/sabnzbd/config" => "critical",
  "{{ nas_docker_root }}/qbittorrent/config" => "critical",
  "{{ nas_docker_root }}/bindery/config" => "critical",
  "{{ nas_docker_root }}/kapowarr/config" => "critical",
  "{{ nas_docker_root }}/pinchflat/config" => "critical",
  "{{ nas_docker_root }}/trailarr/config" => "critical",
  "{{ nas_docker_root }}/seerr/config" => "critical"
}.freeze

EXPECTED_INTEGRATION_WRITERS = Set[
  "{{ nas_media_root }}/Media/Movies",
  "{{ nas_media_root }}/Media/Series",
  "{{ nas_media_root }}/Media/.acquisition/usenet/movies",
  "{{ nas_media_root }}/Media/.acquisition/usenet/series",
  "{{ nas_media_root }}/Media/.acquisition/usenet/audiobooks",
  "{{ nas_media_root }}/Media/.acquisition/torrents/movies",
  "{{ nas_media_root }}/Media/.acquisition/torrents/series",
  "{{ nas_media_root }}/Media/.acquisition/torrents/audiobooks",
  "{{ nas_media_root }}/Books/.acquisition/usenet/ebooks",
  "{{ nas_media_root }}/Books/.acquisition/usenet/comics",
  "{{ nas_media_root }}/Books/.acquisition/torrents/ebooks",
  "{{ nas_media_root }}/Books/.acquisition/torrents/comics"
].freeze

def catalog_contract_problems(catalog)
  catalog == EXPECTED ? [] : ["media acquisition catalog differs from the pinned inert contract"]
end

def jellyfin_defaults_contract_problems(defaults)
  plugins = defaults.is_a?(Hash) ? defaults["jellyfin_plugins"] : nil
  plugins.is_a?(Array) && plugins.include?("Open Subtitles") ? [] :
    ["Jellyfin Open Subtitles must remain until Bazarr is proven in Phase 1"]
end

def planned_tree_problems(existing_paths)
  expected_paths = EXPECTED_PROJECTS.filter_map do |project_name, project|
    next unless project.fetch("status") == "planned"

    ["roles/#{project.fetch('role')}", "services/#{project_name}"]
  end.flatten
  (existing_paths & expected_paths).map do |path|
    tree_kind = path.start_with?("roles/") ? "role" : "service"
    "planned #{tree_kind} tree exists prematurely: #{path}"
  end
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def integration_writer_contract_problems(storage)
  integration_writers = storage.select do |entry|
    entry.key?("media_acquisition_writer")
  end
  actual_integration_writers = integration_writers.map { |entry| entry.fetch("path") }.to_set
  problems = []
  problems << "media acquisition integration writers differ from the exact writable set" unless
    actual_integration_writers == EXPECTED_INTEGRATION_WRITERS
  problems << "integration writer declarations must use literal true" if
    integration_writers.any? { |entry| entry["media_acquisition_writer"] != true }
  problems << "integration writer declarations must remain acquisition foundation storage" if
    integration_writers.any? { |entry| entry["media_acquisition_foundation"] != true }
  problems << "integration writer declarations must remain ownerless for production NAS storage" if
    integration_writers.any? { |entry| entry.key?("owner") || entry.key?("group") }
  problems
end

def flatten_tasks(tasks)
  Array(tasks).flat_map do |task|
    next [] unless task.is_a?(Hash)

    [task] + %w[block rescue always].flat_map { |section| flatten_tasks(task[section]) }
  end
end

def yaml_structure_problems(source)
  stream = Psych.parse_stream(source)
  problems = []
  problems << "must contain exactly one YAML document" unless stream.children.length == 1
  duplicates = []
  inspect_node = lambda do |node|
    problems << "must not contain YAML anchors or aliases" if
      node.is_a?(Psych::Nodes::Alias) || (node.respond_to?(:anchor) && node.anchor)
    if node.is_a?(Psych::Nodes::Mapping)
      seen = {}
      node.children.each_slice(2) do |key, value|
        if key.is_a?(Psych::Nodes::Scalar)
          duplicates << key.value if seen[key.value]
          seen[key.value] = true
        end
        inspect_node.call(key)
        inspect_node.call(value)
      end
    elsif node.respond_to?(:children) && node.children
      node.children.each { |child| inspect_node.call(child) }
    end
  end
  inspect_node.call(stream)
  duplicates.uniq.each { |key| problems << "contains duplicate mapping key #{key}" }
  [stream, problems]
rescue Psych::Exception => e
  [nil, ["is malformed: #{e.message.lines.first.strip}"]]
end

def strict_yaml_file(path)
  source = File.read(path)
  _stream, problems = yaml_structure_problems(source)
  return [nil, problems] unless problems.empty?

  [YAML.safe_load(source, aliases: false), []]
rescue Errno::ENOENT
  [nil, ["is missing"]]
rescue Psych::Exception => e
  [nil, ["is malformed: #{e.message.lines.first.strip}"]]
end

def parse_port(publication)
  unless publication.is_a?(String)
    raise ArgumentError, "Compose ports entries must use canonical short syntax"
  end

  protocol = publication.include?("/") ? publication.split("/", 2).last : "tcp"
  address_and_ports = publication.sub(%r{/[^/]+\z}, "")
  if (match = address_and_ports.match(/\A\[([^\]]+)\]:(\d+):(\d+)\z/))
    bind_address, host_port, container_port = match.captures
  elsif (match = address_and_ports.match(/\A(::):(\d+):(\d+)\z/))
    bind_address, host_port, container_port = match.captures
  else
    parts = address_and_ports.split(":")
    case parts.length
    when 2 then bind_address, host_port, container_port = "0.0.0.0", *parts
    when 3 then bind_address, host_port, container_port = parts
    else raise ArgumentError, "unsupported Compose ports entry #{publication.inspect}"
    end
  end
  bind_address = "0.0.0.0" if bind_address.nil? || bind_address.empty? || bind_address == "0.0.0.0"
  bind_address = "::" if %w[:: [::]].include?(bind_address)
  [bind_address, Integer(host_port, 10), Integer(container_port, 10), protocol]
end

def implemented_ports(manifest)
  manifest.fetch("services").flat_map do |entry|
    next [] unless %w[implemented accepted].include?(entry.fetch("status"))

    compose_path = File.join(ROOT, "services", entry.fetch("name"), "compose.yml")
    next [] unless File.file?(compose_path)

    compose = YAML.safe_load_file(compose_path, aliases: true)
    compose.fetch("services").flat_map do |container, definition|
      Array(definition["ports"]).map do |publication|
        [entry.fetch("name"), container, *parse_port(publication)]
      end
    end
  end
end

def collides?(left, right)
  return false unless left.fetch("protocol") == right.fetch("protocol")
  return false unless left.fetch("host_port") == right.fetch("host_port")

  left_bind = left.fetch("bind_address")
  right_bind = right.fetch("bind_address")
  wildcards = %w[0.0.0.0 ::]
  left_bind == right_bind || wildcards.include?(left_bind) || wildcards.include?(right_bind)
end

def path_entry_exists?(path)
  File.lstat(path)
  true
rescue Errno::ENOENT
  false
rescue SystemCallError
  true
end

failures = []
if SELECTED_PROJECT
  relative_wrapper_path = "tests/contracts/#{SELECTED_PROJECT}-foundation.sh"
  wrapper_path = File.join(ROOT, relative_wrapper_path)
  begin
    wrapper_stat = File.lstat(wrapper_path)
    failures << "#{relative_wrapper_path} must be a regular executable file" unless
      wrapper_stat.file? && !wrapper_stat.symlink? && (wrapper_stat.mode & 0o7777) == 0o755
    failures << "#{relative_wrapper_path} differs from the exact foundation wrapper" unless
      File.binread(wrapper_path) == FOUNDATION_WRAPPER_SOURCE
  rescue SystemCallError => e
    failures << "#{relative_wrapper_path} cannot be inspected: #{e.class}"
  end

  clean_git_environment = ENV.each_key.grep(/\AGIT_/).to_h { |name| [name, nil] }
  staged, staged_error, staged_status = Open3.capture3(
    clean_git_environment,
    "git", "-C", ROOT, "ls-files", "--stage", "--", relative_wrapper_path
  )
  unless staged_status.success?
    failures << "#{relative_wrapper_path} staged mode cannot be inspected: #{staged_error.lines.first&.strip}"
  end
  staged_lines = staged.lines
  staged_mode = staged_lines.fetch(0, "").split.fetch(0, nil)
  failures << "#{relative_wrapper_path} must be staged with Git mode 100755" unless
    staged_status.success? && staged_lines.length == 1 && staged_mode == "100755"
end

catalog, catalog_load_problems = strict_yaml_file(CATALOG_PATH)
catalog_load_problems.each { |problem| failures << "config/media-acquisition.yml #{problem}" }
if catalog_load_problems.empty? && !catalog.is_a?(Hash)
  failures.concat(catalog_contract_problems(catalog))
  failures << "config/media-acquisition.yml must be a mapping"
  catalog = nil
end
if catalog
  failures.concat(catalog_contract_problems(catalog))

  ports = catalog.fetch("projects").values.flat_map do |project|
    project.fetch("services").values.flat_map { |definition| definition.fetch("host_ports") }
  end
  ui_ports = ports.select { |port| port["purpose"] == "web_ui" }
  failures << "every UI publication must contain exactly the seven canonical fields" unless
    ui_ports.all? { |port| port.keys == %w[purpose protocol bind_address exposure host_port container_port published_by] }
  failures << "catalog publications must remain LAN/mesh-local" unless
    ports.all? { |port| port["exposure"] == "lan_mesh" }

  one_shots = catalog.fetch("projects").values.flat_map do |project|
    project.fetch("services").select { |_name, definition| definition["class"] == "one_shot" }.keys
  end.to_set
  failures << "Configarr must be the sole one-shot service" unless
    one_shots == ACQUISITION_JOB_SERVICES

  if SELECTED_PROJECT
    failures << "selected acquisition project differs from its exact pinned contract" unless
      catalog.fetch("projects")[SELECTED_PROJECT] == EXPECTED_PROJECTS.fetch(SELECTED_PROJECT)
  end

  planned_publications = ports.map do |port|
    port.slice("protocol", "bind_address", "host_port")
  end
  planned_publications.combination(2).each do |left, right|
    failures << "planned host publications collide" if collides?(left, right)
  end

  planned_projects = catalog.fetch("projects").select do |_project_name, project|
    project.fetch("status") == "planned"
  end
  planned_paths = planned_projects.flat_map do |project_name, project|
    ["roles/#{project.fetch('role')}", "services/#{project_name}"]
  end
  existing_planned_paths = planned_paths.select { |path| path_entry_exists?(File.join(ROOT, path)) }
  failures.concat(planned_tree_problems(existing_planned_paths))

  premature_tree_rejections = planned_tree_problems([planned_paths.first]).length
  failures << "planned tree guard accepts a premature project directory" unless
    premature_tree_rejections == 1
end

jellyfin_defaults_path = File.join(ROOT, "roles", "jellyfin", "defaults", "main.yml")
jellyfin_defaults, jellyfin_defaults_problems = strict_yaml_file(jellyfin_defaults_path)
jellyfin_defaults_problems.each do |problem|
  failures << "roles/jellyfin/defaults/main.yml #{problem}"
end
if jellyfin_defaults_problems.empty?
  failures.concat(jellyfin_defaults_contract_problems(jellyfin_defaults))
  if jellyfin_defaults.is_a?(Hash)
    jellyfin_without_open_subtitles = deep_copy(jellyfin_defaults)
    jellyfin_without_open_subtitles.fetch("jellyfin_plugins", []).delete("Open Subtitles")
    removal_rejections = jellyfin_defaults_contract_problems(jellyfin_without_open_subtitles).length
    failures << "Jellyfin Open Subtitles removal mutant was not rejected" unless removal_rejections == 1
  end
end

manifest, manifest_problems = strict_yaml_file(File.join(ROOT, "services", "manifest.yml"))
manifest_problems.each { |problem| failures << "services/manifest.yml #{problem}" }
if manifest
  entries = manifest.fetch("services")
  names = entries.map { |entry| entry.fetch("name") }
  failures << "service manifest names must be unique" unless names.uniq == names
  EXPECTED_PROJECTS.each do |name, project|
    status = project.fetch("status")
    failures << "#{name} must be #{status} in the service manifest" unless
      entries.include?({ "name" => name, "role" => project.fetch("role"), "status" => status })
  end

  actual_ports = implemented_ports(manifest)
  failures << "canonical Compose ports changed without catalog collision review" unless
    actual_ports.sort == EXPECTED_IMPLEMENTED_PORTS.sort
  existing = actual_ports.map do |_project, _container, bind_address, host_port, _container_port, protocol|
    { "protocol" => protocol, "bind_address" => bind_address, "host_port" => host_port }
  end
  if catalog
    catalog.fetch("projects").values.select { |project| project.fetch("status") == "planned" }
           .flat_map { |project| project.fetch("services").values }
           .flat_map { |definition| definition.fetch("host_ports") }.each do |planned|
      failures << "planned publication collides with an implemented Compose publication" if
        existing.any? { |publication| collides?(planned, publication) }
    end
  end
end

# Collision semantics are policy, not an incidental consequence of today's roster.
base = { "protocol" => "tcp", "bind_address" => "127.0.0.1", "host_port" => 3000 }
failures << "IPv4 wildcard must collide with a loopback publication" unless
  collides?(base, base.merge("bind_address" => "0.0.0.0"))
failures << "IPv6 wildcard must collide with an IPv4-specific publication" unless
  collides?(base, base.merge("bind_address" => "::"))
failures << "specific unequal addresses must not collide" if
  collides?(base, base.merge("bind_address" => "192.0.2.10"))
failures << "TCP and UDP may reuse a host port" if
  collides?(base, base.merge("protocol" => "udp"))
failures << "missing bind must normalize to IPv4 wildcard" unless
  parse_port("3000:3000") == ["0.0.0.0", 3000, 3000, "tcp"]
failures << "bracketed IPv6 wildcard must normalize" unless
  parse_port("[::]:3000:3000/udp") == ["::", 3000, 3000, "udp"]
failures << "unbracketed IPv6 wildcard must normalize" unless
  parse_port(":::3000:3000") == ["::", 3000, 3000, "tcp"]

# Prove the strict loader rejects YAML features that can disguise the catalog shape.
{
  "duplicate YAML key" => "---\nenabled: false\nenabled: true\n",
  "YAML alias" => "---\nbase: &base false\nenabled: *base\n",
  "anchored YAML key" => "---\n&enabled enabled: false\n",
  "extra YAML document" => "---\nenabled: false\n---\nenabled: false\n"
}.each do |label, source|
  _stream, problems = yaml_structure_problems(source)
  failures << "strict catalog loader accepts #{label}" if problems.empty?
end

shared_vars = YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", "all", "main.yml"))
all_storage = shared_vars.fetch("nas_storage")
acquisition_storage = shared_vars.fetch("nas_storage").select do |entry|
  entry["media_acquisition_foundation"] == true
end
failures.concat(integration_writer_contract_problems(all_storage))

extra_writer_mutation = deep_copy(all_storage)
extra_writer_mutation.find { |entry| entry.fetch("path").end_with?("/audiobookshelf/config") }["media_acquisition_writer"] = true
failures << "integration writer guard misses extra service-config marker" if
  integration_writer_contract_problems(extra_writer_mutation).empty?

non_true_writer_mutation = deep_copy(all_storage)
non_true_writer_mutation.find do |entry|
  entry.fetch("path") == "{{ nas_media_root }}/Media/Movies"
end["media_acquisition_writer"] = false
failures << "integration writer guard misses non-true declaration" if
  integration_writer_contract_problems(non_true_writer_mutation).empty?
actual_storage = acquisition_storage.to_h { |entry| [entry.fetch("path"), entry.fetch("recovery")] }
failures << "media acquisition storage differs from the exact classified foundation" unless
  actual_storage == EXPECTED_STORAGE && acquisition_storage.length == EXPECTED_STORAGE.length
failures << "every media acquisition storage entry must use mode 0755" unless
  acquisition_storage.all? { |entry| entry["mode"] == "0755" }
acquisition_storage.each do |entry|
  if entry.fetch("path").start_with?("{{ nas_media_root }}/")
    failures << "media acquisition user/cache paths must not claim ownership" if
      entry.key?("owner") || entry.key?("group")
  else
    failures << "media acquisition critical state must use the NAS identity" unless
      entry["owner"] == "{{ nas_uid }}" && entry["group"] == "{{ nas_gid }}"
  end
end
%w[configarr unpackerr gluetun].each do |stateless_service|
  failures << "#{stateless_service} must not gain critical host state" if
    shared_vars.fetch("nas_storage").any? do |entry|
      entry.fetch("path").start_with?("{{ nas_docker_root }}/#{stateless_service}/")
    end
end

# The foundation was inert while it was being built: no host enabled a
# transport, so the paths and control network existed with nothing running on
# them. That is still true of every transport nobody has taken through its
# handoff, and of the disposable Mac proof, which must converge the same
# unactivated platform every run or it stops proving anything.
#
# It stopped being true of Usenet on the NAS when Phase 1 was accepted there.
# Holding the flag false after that bought nothing and cost a great deal: the
# activation had to live outside source control, which the deployment poller
# cannot read, so enabling acquisition meant leaving the NAS with no automatic
# deployment at all. The guard now covers the transports that are still inert
# rather than the file that names them.
MEDIA_TRANSPORT_ACTIVATION = {
  "nas_hosts" => { "media_usenet_enabled" => true, "media_torrent_enabled" => false },
  "mac_hosts" => { "media_usenet_enabled" => false, "media_torrent_enabled" => false }
}.freeze
MEDIA_TRANSPORT_ACTIVATION.each do |host_group, flags|
  vars = YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", host_group, "main.yml"))
  flags.each do |flag, expected|
    failures << "#{host_group} #{flag} must be literal #{expected}" unless vars[flag] == expected
  end
end
expected_network_expression = "{{ (platform_project_name ~ '-media-control') if platform_project_name | default('') | length > 0 else 'media-control' }}"
failures << "media control network identity must be derived from the project namespace" unless
  shared_vars["platform_media_control_network"] == expected_network_expression

nas_guide = File.read(File.join(ROOT, "docs", "getting-started-nas.md"))
reader_prerequisite = "Direct Jellyfin-only or Audiobookshelf-only runs require a completed foundation or full-site converge that created the external `media-control` network."
failures << "NAS guide omits the reader-only external network prerequisite" unless
  nas_guide.gsub(/\s+/, " ").include?(reader_prerequisite)

host_prep = YAML.safe_load_file(File.join(ROOT, "roles", "host_prep", "tasks", "main.yml"))
all_host_prep_tasks = flatten_tasks(host_prep)
network_task = host_prep.find do |task|
  task["name"] == "Create the external media control network"
end
network_create_argv = network_task&.dig("ansible.builtin.command", "argv")
failures << "host preparation must create the derived bridge media control network atomically" unless
  network_create_argv == [
    "docker", "network", "create", "--driver", "bridge",
    "--label", "nas.platform.purpose=media-control",
    "--label", "nas.platform.project={{ platform_project_name | default('nas-platform', true) }}",
    "{{ platform_media_control_network }}"
  ] &&
    network_task["when"] == "not host_prep_media_control_existing.exists" &&
    network_task["changed_when"] == "host_prep_media_control_create.rc == 0" &&
    network_task["failed_when"] == "host_prep_media_control_create.rc != 0"
network_inspection = host_prep.find do |task|
  task["name"] == "Inspect an existing exact-name media control network"
end
network_refusal = host_prep.find do |task|
  task["name"] == "Refuse an existing media control network owned by another project"
end
network_post_inspection = host_prep.find do |task|
  task["name"] == "Inspect the exact media control network after create-only handling"
end
network_post_assertion = host_prep.find do |task|
  task["name"] == "Require the exact media control network after create-only handling"
end
writer_mode = host_prep.find do |task|
  task["name"] == "Select synthetic integration writer ownership"
end
writer_boundary = host_prep.find do |task|
  task["name"] == "Require the exact integration media sandbox"
end
writer_preserve_refusal = host_prep.find do |task|
  task["name"] == "Refuse preservation-only synthetic integration writers"
end
directory_task = host_prep.find do |task|
  task["name"] == "Create service state directories"
end
writer_inspection = host_prep.find do |task|
  task["name"] == "Inspect synthetic integration writer directories"
end
writer_assertion = host_prep.find do |task|
  task["name"] == "Require synthetic integration writer ownership"
end
network_refusal_conditions = Array(network_refusal&.dig("ansible.builtin.assert", "that"))
network_post_conditions = Array(network_post_assertion&.dig("ansible.builtin.assert", "that"))
failures << "host preparation must inspect and fail closed on exact-name network collisions" unless
  network_inspection&.dig("community.docker.docker_network_info", "name") ==
    "{{ platform_media_control_network }}" &&
    network_inspection["changed_when"] == false &&
    network_refusal_conditions.include?("host_prep_media_control_existing.network.Driver == 'bridge'") &&
    network_refusal_conditions.include?("host_prep_media_control_existing.network.Labels | default(none) is mapping") &&
    network_refusal_conditions.include?("host_prep_media_control_existing.network.Labels.get('nas.platform.purpose') == 'media-control'") &&
    network_refusal_conditions.include?("host_prep_media_control_existing.network.Labels.get('nas.platform.project') == (platform_project_name | default('nas-platform', true))") &&
    network_refusal_conditions.include?("host_prep_media_control_existing.network.Labels.keys() | sort == ['nas.platform.project', 'nas.platform.purpose']") &&
    Array(network_refusal&.fetch("when", [])).include?("host_prep_media_control_existing.exists")
failures << "host preparation must verify exact network state after create-only handling" unless
  network_post_inspection&.dig("community.docker.docker_network_info", "name") ==
    "{{ platform_media_control_network }}" &&
    network_post_inspection["changed_when"] == false &&
    network_post_conditions.include?("host_prep_media_control_final.exists") &&
    network_post_conditions.include?("host_prep_media_control_final.network.Name == platform_media_control_network") &&
    network_post_conditions.include?("host_prep_media_control_final.network.Driver == 'bridge'") &&
    network_post_conditions.include?("host_prep_media_control_final.network.Labels | default(none) is mapping") &&
    network_post_conditions.include?("host_prep_media_control_final.network.Labels.get('nas.platform.purpose') == 'media-control'") &&
    network_post_conditions.include?("host_prep_media_control_final.network.Labels.get('nas.platform.project') == (platform_project_name | default('nas-platform', true))") &&
    network_post_conditions.include?("host_prep_media_control_final.network.Labels.keys() | sort == ['nas.platform.project', 'nas.platform.purpose']")
containment_index = host_prep.index do |task|
  task["name"] == "Validate central storage targets before directory creation"
end
network_index = host_prep.index(network_task)
network_inspection_index = host_prep.index(network_inspection)
network_refusal_index = host_prep.index(network_refusal)
network_post_inspection_index = host_prep.index(network_post_inspection)
network_post_assertion_index = host_prep.index(network_post_assertion)
failures << "media control network creation must follow target containment" unless
  containment_index && network_inspection_index && network_refusal_index && network_index &&
    network_post_inspection_index && network_post_assertion_index &&
    containment_index < network_inspection_index && network_inspection_index < network_refusal_index &&
    network_refusal_index < network_index && network_index < network_post_inspection_index &&
    network_post_inspection_index < network_post_assertion_index
failures << "host preparation must never delete Docker networks" if
  all_host_prep_tasks.any? do |task|
    task.dig("community.docker.docker_network", "state") == "absent"
  end
failures << "host preparation must never recursively change storage ownership" if
  all_host_prep_tasks.any? { |task| task.dig("ansible.builtin.file", "recurse") == true }

writer_requested = writer_mode&.dig(
  "ansible.builtin.set_fact", "host_prep_integration_writer_requested"
).to_s
writer_enabled = writer_mode&.dig(
  "ansible.builtin.set_fact", "host_prep_integration_writer_enabled"
).to_s
writer_storage = writer_mode&.dig(
  "ansible.builtin.set_fact", "host_prep_integration_writer_storage"
).to_s
failures << "host preparation must select synthetic writer mode only for explicit NAS integration tests" unless
    writer_requested.include?("platform_kind == 'nas'") &&
    writer_requested.include?("platform_compose_kind == 'integration'") &&
    writer_requested.include?("deployment_bundle_test_mode | bool") &&
    writer_enabled.include?("platform_kind == 'nas'") &&
    writer_enabled.include?("platform_compose_kind == 'integration'") &&
    writer_enabled.include?("deployment_bundle_test_mode | bool") &&
    writer_enabled.include?("nas_media_root is match('^.*/nas-platform-integration[.][A-Za-z0-9]{6}/.+\\Z')") &&
    !writer_enabled.include?(".+$") &&
    writer_storage.include?("selectattr('media_acquisition_writer', 'defined')") &&
    writer_storage.include?("selectattr('media_acquisition_writer', 'sameas', true)")

writer_boundary_conditions = Array(writer_boundary&.dig("ansible.builtin.assert", "that"))
writer_boundary_message = writer_boundary&.dig("ansible.builtin.assert", "fail_msg").to_s
writer_preserve_conditions = Array(writer_preserve_refusal&.dig("ansible.builtin.assert", "that"))
writer_mode_index = host_prep.index(writer_mode)
writer_boundary_index = host_prep.index(writer_boundary)
writer_preserve_index = host_prep.index(writer_preserve_refusal)
directory_index = host_prep.index(directory_task)
failures << "host preparation must fail closed on the exact integration media sandbox before directory creation" unless
  writer_boundary&.fetch("when", nil) == "host_prep_integration_writer_requested | bool" &&
    writer_boundary_conditions.include?("host_prep_integration_writer_enabled | bool") &&
    writer_boundary_message.include?("nas_media_root | to_json") &&
    writer_boundary_message.include?("/nas-platform-integration.XXXXXX/") &&
    writer_preserve_refusal&.fetch("loop", nil) == "{{ host_prep_integration_writer_storage }}" &&
    writer_preserve_conditions.include?("item.preserve_only is not defined") &&
    writer_mode_index && writer_boundary_index && writer_preserve_index && directory_index &&
    writer_mode_index < writer_boundary_index && writer_boundary_index < writer_preserve_index &&
    writer_preserve_index < directory_index

directory_owner = directory_task&.dig("ansible.builtin.file", "owner").to_s.gsub(/\s+/, " ")
directory_group = directory_task&.dig("ansible.builtin.file", "group").to_s.gsub(/\s+/, " ")
failures << "host preparation must scope synthetic ownership to marked integration writer directories" unless
  directory_owner.include?("host_prep_integration_writer_enabled | bool") &&
    directory_owner.include?("(item.media_acquisition_writer | default(false)) is sameas true") &&
    !directory_owner.include?("item.media_acquisition_writer | default(false) | bool") &&
    !directory_owner.include?("item.media_acquisition_writer | default(false)) == true") &&
    directory_owner.include?("nas_uid") &&
    directory_owner.include?("else item.owner") &&
    directory_owner.include?("platform_kind == 'nas' or (platform_manage_linux_ownership | bool)") &&
    directory_owner.include?("item.owner is defined") &&
    directory_group.include?("host_prep_integration_writer_enabled | bool") &&
    directory_group.include?("(item.media_acquisition_writer | default(false)) is sameas true") &&
    !directory_group.include?("item.media_acquisition_writer | default(false) | bool") &&
    !directory_group.include?("item.media_acquisition_writer | default(false)) == true") &&
    directory_group.include?("nas_gid") &&
    directory_group.include?("else item.group") &&
    directory_group.include?("platform_kind == 'nas' or (platform_manage_linux_ownership | bool)") &&
    directory_group.include?("item.group is defined")

writer_inspection_index = host_prep.index(writer_inspection)
writer_assertion_index = host_prep.index(writer_assertion)
writer_assertion_conditions = Array(writer_assertion&.dig("ansible.builtin.assert", "that"))
failures << "host preparation must verify synthetic integration writer ownership after convergence" unless
  writer_inspection&.dig("ansible.builtin.stat", "follow") == false &&
    writer_inspection&.fetch("loop", nil) == "{{ host_prep_integration_writer_storage }}" &&
    writer_inspection&.fetch("when", nil) == "host_prep_integration_writer_enabled | bool" &&
    writer_assertion&.fetch("when", nil) == "host_prep_integration_writer_enabled | bool" &&
    directory_index && writer_inspection_index && writer_assertion_index &&
    writer_inspection_index == directory_index + 1 &&
    writer_assertion_index == writer_inspection_index + 1 &&
    writer_assertion_conditions.include?("item.stat.exists") &&
    writer_assertion_conditions.include?("item.stat.isdir") &&
    writer_assertion_conditions.include?("not item.stat.islnk") &&
    writer_assertion_conditions.include?("item.stat.uid == (nas_uid | int)") &&
    writer_assertion_conditions.include?("item.stat.gid == (nas_gid | int)") &&
    writer_assertion_conditions.include?("item.stat.mode == item.item.mode")

%w[audiobookshelf jellyfin].each do |reader|
  compose = YAML.safe_load_file(File.join(ROOT, "services", reader, "compose.yml"), aliases: true)
  failures << "#{reader} must join default and media-control explicitly" unless
    compose.dig("services", reader, "networks") == %w[default media-control]
  failures << "#{reader} must declare only canonical default and external media-control networks" unless
    compose["networks"] == {
      "default" => {},
      "media-control" => { "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}" }
    }
  read_only_mount = reader == "audiobookshelf" ?
    "${AUDIOBOOKSHELF_MEDIA_PATH:?}:/audiobooks:ro" :
    "${JELLYFIN_MEDIA_PATH:?}:/media:ro"
  failures << "#{reader} media mount must remain read-only" unless
    compose.dig("services", reader, "volumes").include?(read_only_mount)
  environment_assignments = File.readlines(
    File.join(ROOT, "roles", reader, "templates", "env.j2")
  ).filter_map do |line|
    name, _separator, value = line.strip.partition("=")
    [name, value] if line.strip.match?(/\A[A-Z][A-Z0-9_]*=/)
  end
  failures << "#{reader} must export the derived media control network exactly once" unless
    environment_assignments.select { |name, _value| name == "PLATFORM_MEDIA_NETWORK" } == [
      ["PLATFORM_MEDIA_NETWORK", "{{ platform_media_control_network }}"]
    ]
  options = YAML.safe_load_file(
    File.join(ROOT, "roles", reader, "meta", "argument_specs.yml")
  ).dig("argument_specs", "main", "options")
  failures << "#{reader} must require its media control network input" unless
    options["platform_media_control_network"] == { "type" => "str", "required" => true }
end

preflight_options = YAML.safe_load_file(
  File.join(ROOT, "roles", "preflight", "meta", "argument_specs.yml")
).dig("argument_specs", "main", "options")
%w[media_usenet_enabled media_torrent_enabled].each do |flag|
  failures << "preflight must require boolean #{flag}" unless
    preflight_options[flag] == { "type" => "bool", "required" => true }
end
host_prep_options = YAML.safe_load_file(
  File.join(ROOT, "roles", "host_prep", "meta", "argument_specs.yml")
).dig("argument_specs", "main", "options")
failures << "host_prep must require a string media control network" unless
  host_prep_options["platform_media_control_network"] == { "type" => "str", "required" => true }
failures << "host_prep must accept the acquisition foundation marker" unless
  host_prep_options.dig("nas_storage", "options", "media_acquisition_foundation") == {
    "type" => "bool", "required" => false
  }
failures << "host_prep must require the integration compose kind" unless
  host_prep_options["platform_compose_kind"] == { "type" => "str", "required" => true }
failures << "host_prep must default deployment bundle test mode off" unless
  host_prep_options["deployment_bundle_test_mode"] == { "type" => "bool", "default" => false }
failures << "host_prep must require the raw NAS user identity" unless
  host_prep_options["nas_uid"] == { "type" => "raw", "required" => true }
failures << "host_prep must require the raw NAS group identity" unless
  host_prep_options["nas_gid"] == { "type" => "raw", "required" => true }
failures << "host_prep must accept the synthetic integration writer marker" unless
  host_prep_options.dig("nas_storage", "options", "media_acquisition_writer")&.slice("type", "required") == {
    "type" => "bool", "required" => false
  }

site = YAML.safe_load_file(File.join(ROOT, "site.yml")).first
host_prep_role = site.fetch("roles").find { |role| role["role"] == "host_prep" }
failures << "host_prep must expose the media_acquisition_foundation convergence tag" unless
  host_prep_role && host_prep_role.fetch("tags").include?("media_acquisition_foundation")

verifier_path = File.join(ROOT, "roles", "host_prep", "tasks", "verify_media_acquisition.yml")
failures << "host_prep must provide the standalone media acquisition verifier" unless File.file?(verifier_path)
verify_play = YAML.safe_load_file(File.join(ROOT, "verify.yml")).first
verifier_include = Array(verify_play["tasks"]).find do |task|
  task.dig("ansible.builtin.include_role", "name") == "host_prep"
end
failures << "verify.yml must select the standalone media acquisition verifier by explicit tag" unless
  verifier_include&.dig("ansible.builtin.include_role", "tasks_from") == "verify_media_acquisition" &&
    Array(verifier_include["tags"]) == %w[never platform_verify_media_acquisition_foundation]

mac_verify_source = File.read(File.join(ROOT, "tests", "mac", "verify.sh"))
mac_lib_source = File.read(File.join(ROOT, "tests", "mac", "lib.sh"))
expected_mac_verify_hooks = %w[
  10-beszel.sh 15-media-acquisition-foundation.sh 15-ntfy.sh 20-dozzle.sh
]
failures << "Mac verification must dispatch the exact infrastructure hook roster" unless
  expected_mac_verify_hooks.all? { |hook| mac_lib_source.include?(hook) } &&
    mac_verify_source.include?("MAC_VERIFY_INFRASTRUCTURE_HOOKS")
failures << "Mac verification must dispatch contract-backed services through coverage" unless
  mac_verify_source.include?("hooks/verify/30-services.sh")
failures << "Mac verification must not pass the foundation hook through service coverage" if
  mac_verify_source.include?("mac_run_hooks verify")


# Exercise the exact-shape guard against every port field and the contract's
# security-sensitive structural boundaries. These mutations never touch disk.
port_locations = EXPECTED.fetch("projects").flat_map do |project_name, project|
  project.fetch("services").flat_map do |service_name, definition|
    definition.fetch("host_ports").each_index.map { |index| [project_name, service_name, index] }
  end
end
port_locations.each do |project_name, service_name, index|
  port = EXPECTED.dig("projects", project_name, "services", service_name, "host_ports", index)
  port.each_key do |field|
    mutation = deep_copy(EXPECTED)
    value = mutation.dig("projects", project_name, "services", service_name, "host_ports", index, field)
    mutation.dig("projects", project_name, "services", service_name, "host_ports", index)[field] =
      value.is_a?(Integer) ? value + 1 : "mutated-#{value}"
    failures << "catalog guard misses #{project_name}.#{service_name} port field #{field}" if
      catalog_contract_problems(mutation).empty?
  end
end

{
  "enabled state" => proc { |copy| copy["enabled"] = true },
  "missing port" => proc do |copy|
    copy.dig("projects", "arr", "services", "radarr", "host_ports").clear
  end,
  "extra port" => proc do |copy|
    copy.dig("projects", "arr", "services", "radarr", "host_ports") <<
      ui_port(9999, published_by: "radarr").first
  end,
  "Configarr class" => proc do |copy|
    copy.dig("projects", "arr", "services", "configarr")["class"] = "long_running"
  end,
  "Configarr profile" => proc do |copy|
    copy.dig("projects", "arr", "services", "configarr")["compose_profile"] = "default"
  end,
  "Configarr ownership" => proc { |copy| copy.dig("configuration_ownership", "configarr").pop },
  "Ansible ownership" => proc do |copy|
    copy.dig("configuration_ownership", "ansible", "prowlarr") << "download_clients"
  end,
  "extra project" => proc do |copy|
    copy.fetch("projects")["unexpected"] = { "role" => "unexpected", "status" => "planned", "services" => {} }
  end
}.each do |label, mutate|
  mutation = deep_copy(EXPECTED)
  mutate.call(mutation)
  failures << "catalog guard misses #{label}" if catalog_contract_problems(mutation).empty?
end

if failures.empty?
  puts "media acquisition foundation: inert catalog and port policy hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} media acquisition foundation regression(s)"
end
