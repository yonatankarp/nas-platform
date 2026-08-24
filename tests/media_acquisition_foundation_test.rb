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
    "role" => "arr", "status" => "planned", "services" => {
      "radarr" => service("long_running", 1.0, ui_port(7878, published_by: "radarr")),
      "sonarr" => service("long_running", 1.0, ui_port(8989, published_by: "sonarr")),
      "prowlarr" => service("long_running", 0.5, ui_port(9696, published_by: "prowlarr")),
      "bazarr" => service("long_running", 1.0, ui_port(6767, published_by: "bazarr")),
      "configarr" => service("one_shot", 0.5, [], compose_profile: "jobs")
    }
  },
  "downloaders" => {
    "role" => "downloaders", "status" => "planned", "services" => {
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
  ["audiobookshelf", "audiobookshelf", "0.0.0.0", 13_378, 80, "tcp"],
  ["beszel", "hub", "0.0.0.0", 8090, 8090, "tcp"],
  ["beszel", "socket-proxy", "127.0.0.1", 2375, 2375, "tcp"],
  ["dozzle", "dozzle", "0.0.0.0", 8080, 8080, "tcp"],
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

def catalog_contract_problems(catalog)
  catalog == EXPECTED ? [] : ["media acquisition catalog differs from the pinned inert contract"]
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
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

  catalog.fetch("projects").each do |project_name, project|
    role_path = File.join(ROOT, "roles", project.fetch("role"))
    service_path = File.join(ROOT, "services", project_name)
    failures << "planned role tree exists prematurely: #{role_path.delete_prefix("#{ROOT}/")}" if
      path_entry_exists?(role_path)
    failures << "planned service tree exists prematurely: #{service_path.delete_prefix("#{ROOT}/")}" if
      path_entry_exists?(service_path)
  end
end

manifest, manifest_problems = strict_yaml_file(File.join(ROOT, "services", "manifest.yml"))
manifest_problems.each { |problem| failures << "services/manifest.yml #{problem}" }
if manifest
  entries = manifest.fetch("services")
  names = entries.map { |entry| entry.fetch("name") }
  failures << "service manifest names must be unique" unless names.uniq == names
  EXPECTED_PROJECTS.each do |name, project|
    failures << "#{name} must be planned in the service manifest" unless
      entries.include?({ "name" => name, "role" => project.fetch("role"), "status" => "planned" })
  end

  actual_ports = implemented_ports(manifest)
  failures << "canonical Compose ports changed without catalog collision review" unless
    actual_ports.sort == EXPECTED_IMPLEMENTED_PORTS.sort
  existing = actual_ports.map do |_project, _container, bind_address, host_port, _container_port, protocol|
    { "protocol" => protocol, "bind_address" => bind_address, "host_port" => host_port }
  end
  if catalog
    catalog.fetch("projects").values.flat_map { |project| project.fetch("services").values }
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
acquisition_storage = shared_vars.fetch("nas_storage").select do |entry|
  entry["media_acquisition_foundation"] == true
end
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

%w[nas_hosts mac_hosts].each do |host_group|
  vars = YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", host_group, "main.yml"))
  %w[media_usenet_enabled media_torrent_enabled].each do |flag|
    failures << "#{host_group} #{flag} must be literal false" unless vars[flag] == false
  end
end
expected_network_expression = "{{ (platform_project_name ~ '-media-control') if platform_project_name | default('') | length > 0 else 'media-control' }}"
failures << "media control network identity must be derived from the project namespace" unless
  shared_vars["platform_media_control_network"] == expected_network_expression

host_prep = YAML.safe_load_file(File.join(ROOT, "roles", "host_prep", "tasks", "main.yml"))
all_host_prep_tasks = flatten_tasks(host_prep)
network_task = host_prep.find do |task|
  task["name"] == "Create the external media control network"
end
network_definition = network_task&.fetch("community.docker.docker_network", nil)
failures << "host preparation must create the derived bridge media control network" unless
  network_definition == {
    "name" => "{{ platform_media_control_network }}",
    "driver" => "bridge",
    "labels" => {
      "nas.platform.purpose" => "media-control",
      "nas.platform.project" => "{{ platform_project_name | default('nas-platform', true) }}"
    },
    "state" => "present"
  }
containment_index = host_prep.index do |task|
  task["name"] == "Validate central storage targets before directory creation"
end
network_index = host_prep.index(network_task)
failures << "media control network creation must follow target containment" unless
  containment_index && network_index && containment_index < network_index
failures << "host preparation must never delete Docker networks" if
  all_host_prep_tasks.any? do |task|
    task.dig("community.docker.docker_network", "state") == "absent"
  end
failures << "host preparation must never recursively change storage ownership" if
  all_host_prep_tasks.any? { |task| task.dig("ansible.builtin.file", "recurse") == true }

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
