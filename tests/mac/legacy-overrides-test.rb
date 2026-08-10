#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

TEST_DIR = Pathname(__dir__).realpath
REPO_DIR = TEST_DIR.join("../..").realpath
OVERRIDE_DIR = TEST_DIR.join("legacy-overrides")
MANIFEST = YAML.safe_load_file(REPO_DIR.join("services/manifest.yml"), aliases: false)
SERVICES = MANIFEST.fetch("services").to_h { |entry| [entry.fetch("name"), entry] }.freeze

COMMAND_ENVIRONMENT = {
  "HOME" => ENV.fetch("HOME"),
  "LANG" => "C",
  "LC_ALL" => "C",
  "PATH" => ENV.fetch("PATH"),
  "TMPDIR" => ENV.fetch("TMPDIR", "/tmp")
}.freeze

PORTS = {
  "audiobookshelf" => { "audiobookshelf" => [["33378", "80"]] },
  "beszel" => { "hub" => [["38090", "8090"]] },
  "dozzle" => { "dozzle" => [["38080", "8080"]] },
  "immich" => { "immich-server" => [["32283", "2283"]] },
  "jellyfin" => { "jellyfin" => [["38096", "8096"]] },
  "komga" => { "komga" => [["35600", "25600"]] },
  "ntfy" => { "ntfy" => [["32586", "80"]] },
  "paperless-ngx" => { "webserver" => [["38000", "8000"]] },
  "tinymediamanager" => {
    "tinymediamanager" => [["34000", "4000"], ["37878", "7878"]]
  }
}.freeze

PORT_VARIABLES = %w[
  AUDIOBOOKSHELF_HOST_PORT BESZEL_HOST_PORT DOZZLE_HOST_PORT IMMICH_HOST_PORT
  JELLYFIN_HOST_PORT KOMGA_HOST_PORT NTFY_HOST_PORT PAPERLESS_HOST_PORT
  TINYMEDIAMANAGER_API_HOST_PORT TINYMEDIAMANAGER_WEB_HOST_PORT
].freeze

ENVIRONMENT = {
  "AUDIOBOOKSHELF_HOST_PORT" => "33378",
  "BESZEL_AGENT_KEY" => "test-key",
  "BESZEL_AGENT_TOKEN" => "test-token",
  "BESZEL_APP_URL" => "http://127.0.0.1:38090",
  "BESZEL_HOST_PORT" => "38090",
  "BESZEL_SYSTEM_NAME" => "disposable-test",
  "DB_NAME" => "paperless",
  "DB_DATABASE_NAME" => "immich_test",
  "DB_PASSWORD" => "test-password",
  "DB_USER" => "paperless",
  "DB_USERNAME" => "immich_test_user",
  "DOZZLE_HOST_PORT" => "38080",
  "GROUP_ID" => "100",
  "IMMICH_HOST_PORT" => "32283",
  "JELLYFIN_HOST_PORT" => "38096",
  "KOMGA_HOST_PORT" => "35600",
  "NTFY_BASE_URL" => "http://127.0.0.1:32586",
  "NTFY_HOST_PORT" => "32586",
  "PAPERLESS_AI_ENABLED" => "false",
  "PAPERLESS_AI_LLM_ENDPOINT" => "http://example.invalid:11434",
  "PAPERLESS_AI_LLM_MODEL" => "test-model",
  "PAPERLESS_HOST_PORT" => "38000",
  "PAPERLESS_SECRET_KEY" => "test-secret",
  "PAPERLESS_TASK_WORKERS" => "1",
  "PAPERLESS_THREADS_PER_WORKER" => "1",
  "PASSWORD" => "test-password",
  "TINYMEDIAMANAGER_API_HOST_PORT" => "37878",
  "TINYMEDIAMANAGER_WEB_HOST_PORT" => "34000",
  "TZ" => "UTC",
  "USER_ID" => "1000"
}.freeze

EXPECTED_BINDS = {
  "audiobookshelf" => {
    "audiobookshelf" => {
      "/config" => "legacy/audiobookshelf/config",
      "/metadata" => "legacy/audiobookshelf/metadata",
      "/audiobooks" => "legacy/audiobookshelf/media"
    }
  },
  "beszel" => {
    "hub" => { "/beszel_data" => "legacy/beszel/hub" },
    "agent" => {
      "/var/lib/beszel-agent" => "legacy/beszel/agent",
      "/extra-filesystems/volume1" => "legacy/beszel/volume1",
      "/extra-filesystems/volume2" => "legacy/beszel/volume2"
    },
    "socket-proxy" => { "/var/run/docker.sock" => :docker_socket }
  },
  "dozzle" => {
    "dozzle" => { "/data" => "legacy/dozzle/data" },
    "socket-proxy" => { "/var/run/docker.sock" => :docker_socket }
  },
  "immich" => {
    "immich-server" => {
      "/data" => "legacy/immich/data",
      "/data/thumbs" => "legacy/immich/thumbs",
      "/data/encoded-video" => "legacy/immich/encoded-video",
      "/data/profile" => "legacy/immich/profile",
      "/data/backups" => "legacy/immich/backups"
    },
    "immich-machine-learning" => { "/cache" => "legacy/immich/model-cache" },
    "database" => { "/var/lib/postgresql/data" => "legacy/immich/postgres" }
  },
  "jellyfin" => {
    "jellyfin" => {
      "/config" => "legacy/jellyfin/config",
      "/cache" => "legacy/jellyfin/cache",
      "/media" => "legacy/jellyfin/media"
    }
  },
  "komga" => {
    "komga" => { "/config" => "legacy/komga/config", "/data" => "legacy/komga/library" }
  },
  "ntfy" => {
    "ntfy" => {
      "/var/cache/ntfy" => "legacy/ntfy/cache",
      "/var/lib/ntfy" => "legacy/ntfy/data"
    }
  },
  "paperless-ngx" => {
    "broker" => { "/data" => "legacy/paperless-ngx/redis" },
    "db" => { "/var/lib/postgresql" => "legacy/paperless-ngx/postgres" },
    "webserver" => {
      "/usr/src/paperless/data" => "legacy/paperless-ngx/data",
      "/usr/src/paperless/export" => "legacy/paperless-ngx/export",
      "/usr/share/tesseract-ocr/5/tessdata/heb.traineddata" =>
        "legacy/paperless-ngx/tessdata/heb.traineddata",
      "/usr/src/paperless/media" => "legacy/paperless-ngx/media",
      "/usr/src/paperless/consume" => "legacy/paperless-ngx/consume"
    }
  },
  "tinymediamanager" => {
    "tinymediamanager" => {
      "/data" => "legacy/tinymediamanager/data",
      "/media/Movies" => "legacy/tinymediamanager/movies",
      "/media/Series" => "legacy/tinymediamanager/series"
    }
  }
}.freeze

ALLOWED_OVERRIDE_KEYS = {
  "audiobookshelf" => { "audiobookshelf" => %w[container_name ports volumes] },
  "beszel" => {
    "hub" => %w[container_name ports volumes],
    "agent" => %w[cap_add container_name devices environment network_mode volumes],
    "socket-proxy" => %w[container_name ports]
  },
  "dozzle" => {
    "dozzle" => %w[container_name ports volumes],
    "socket-proxy" => %w[container_name ports]
  },
  "immich" => {
    "immich-server" => %w[container_name devices ports volumes],
    "immich-machine-learning" => %w[container_name volumes],
    "redis" => %w[container_name],
    "database" => %w[container_name volumes]
  },
  "jellyfin" => { "jellyfin" => %w[container_name devices group_add ports volumes] },
  "komga" => { "komga" => %w[container_name ports volumes] },
  "ntfy" => { "ntfy" => %w[container_name ports volumes] },
  "paperless-ngx" => {
    "broker" => %w[container_name ports volumes],
    "db" => %w[container_name ports volumes],
    "webserver" => %w[container_name environment network_mode ports volumes],
    "gotenberg" => %w[container_name ports],
    "tika" => %w[container_name ports]
  },
  "tinymediamanager" => {
    "tinymediamanager" => %w[container_name network_mode ports volumes]
  }
}.freeze

ALLOWED_ENVIRONMENT_KEYS = {
  "beszel" => {
    "agent" => %w[DOCKER_HOST EXCLUDE_SMART HUB_URL INTEL_GPU_DEVICE]
  },
  "paperless-ngx" => {
    "webserver" => %w[
      PAPERLESS_DBHOST PAPERLESS_REDIS PAPERLESS_TIKA_ENDPOINT
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT
    ]
  }
}.freeze

def fail_contract(message)
  warn "Legacy override contract failed: #{message}"
  exit 1
end

def capture!(*command, env: {})
  command_environment = COMMAND_ENVIRONMENT.merge(env)
  stdout, stderr, status = Open3.capture3(command_environment, *command, unsetenv_others: true)
  fail_contract("#{command.join(' ')} failed: #{stderr.strip}") unless status.success?
  fail_contract("#{command.join(' ')} emitted a warning: #{stderr.strip}") unless stderr.empty?
  stdout
end

def bind_mounts(service)
  service.fetch("volumes", []).select { |mount| mount.fetch("type") == "bind" }
end

def expected_port(published, target)
  {
    "mode" => "ingress",
    "host_ip" => "127.0.0.1",
    "target" => target.to_i,
    "published" => published,
    "protocol" => "tcp"
  }
end

def yaml_key?(node, expected_key)
  if node.is_a?(Psych::Nodes::Mapping)
    node.children.each_slice(2).any? do |key, value|
      (key.is_a?(Psych::Nodes::Scalar) && key.value == expected_key) || yaml_key?(value, expected_key)
    end
  else
    node.respond_to?(:children) && Array(node.children).any? { |child| yaml_key?(child, expected_key) }
  end
end

def yaml_mapping_value(mapping, expected_key)
  return unless mapping.is_a?(Psych::Nodes::Mapping)

  mapping.children.each_slice(2) do |key, value|
    return value if key.is_a?(Psych::Nodes::Scalar) && key.value == expected_key
  end
  nil
end

def yaml_mapping_keys(mapping)
  return [] unless mapping.is_a?(Psych::Nodes::Mapping)

  mapping.children.each_slice(2).map do |key, _value|
    fail_contract("override contains a non-scalar YAML key") unless key.is_a?(Psych::Nodes::Scalar)
    key.value
  end
end

unless OVERRIDE_DIR.directory? && !OVERRIDE_DIR.symlink?
  fail_contract("#{OVERRIDE_DIR.relative_path_from(REPO_DIR)} must be a regular directory")
end

actual_files = OVERRIDE_DIR.children.select(&:file?).map(&:basename).map(&:to_s).sort
expected_files = SERVICES.keys.map { |name| "#{name}.yml" }.sort
fail_contract("override file set differs from the manifest") unless actual_files == expected_files

git_common = Pathname(capture!("git", "-C", REPO_DIR.to_s, "rev-parse", "--git-common-dir").strip)
git_common = REPO_DIR.join(git_common) unless git_common.absolute?
canonical_repo = git_common.realpath.dirname
legacy_root = if ENV["NAS_INFRASTRUCTURE_DIR"]
                Pathname(ENV.fetch("NAS_INFRASTRUCTURE_DIR")).realpath
              else
                canonical_repo.join(MANIFEST.fetch("legacy_source").fetch("local_path")).realpath
              end
legacy_commit = MANIFEST.fetch("legacy_source").fetch("commit")
capture!("git", "-C", legacy_root.to_s, "cat-file", "-e", "#{legacy_commit}^{commit}")

Dir.mktmpdir("nas-platform-legacy-overrides.") do |temporary|
  sandbox = Pathname(temporary).join("sandbox")
  base_root = Pathname(temporary).join("base")
  FileUtils.mkdir_p([sandbox, base_root])
  render_env = ENVIRONMENT.merge("PLATFORM_MAC_SANDBOX" => sandbox.to_s)

  SERVICES.each do |name, manifest_entry|
    override = OVERRIDE_DIR.join("#{name}.yml")
    fail_contract("#{override.basename} must be a regular non-symlink file") unless
      override.file? && !override.symlink?

    override_text = override.read
    override_document = Psych.parse(override_text)
    fail_contract("#{override.basename} overrides an image") if yaml_key?(override_document, "image")
    fail_contract("#{override.basename} has unexpected top-level keys") unless
      yaml_mapping_keys(override_document.root) == ["services"]
    override_services = yaml_mapping_value(override_document.root, "services")
    expected_service_overrides = ALLOWED_OVERRIDE_KEYS.fetch(name)
    fail_contract("#{override.basename} has an unexpected service override") unless
      yaml_mapping_keys(override_services).sort == expected_service_overrides.keys.sort
    expected_service_overrides.each do |service_name, allowed_keys|
      service_override = yaml_mapping_value(override_services, service_name)
      fail_contract("#{name}/#{service_name} changes unauthorized runtime semantics") unless
        yaml_mapping_keys(service_override).sort == allowed_keys.sort
      environment_override = yaml_mapping_value(service_override, "environment")
      allowed_environment = ALLOWED_ENVIRONMENT_KEYS.dig(name, service_name) || []
      fail_contract("#{name}/#{service_name} changes unauthorized environment semantics") unless
        yaml_mapping_keys(environment_override).sort == allowed_environment.sort
    end
    active_override_text = override_text.lines.reject { |line| line.lstrip.start_with?("#") }.join
    fail_contract("#{override.basename} contains a production NAS path") if
      active_override_text.match?(%r{(?:^|\s)/(?:volume[0-9]+|dev/dri)(?:/|\b)})

    relative_legacy_path = manifest_entry.fetch("legacy_path")
    base_file = base_root.join("#{name}.yml")
    base_file.write(capture!("git", "-C", legacy_root.to_s, "show", "#{legacy_commit}:#{relative_legacy_path}"))

    base_json = capture!(
      "docker", "compose", "--project-name", "legacy-#{name}-base",
      "-f", base_file.to_s, "config", "--format", "json", env: render_env
    )
    base = JSON.parse(base_json)

    rendered = %w[one two].each_with_index.map do |suffix, index|
      project = "legacy-#{name}-#{suffix}"
      project_env = render_env.dup
      if index == 1
        PORT_VARIABLES.each { |variable| project_env[variable] = (project_env.fetch(variable).to_i + 1000).to_s }
      end
      json = capture!(
        "docker", "compose", "--project-name", project,
        "-f", base_file.to_s, "-f", override.to_s,
        "config", "--format", "json", env: project_env
      )
      config = JSON.parse(json)
      fail_contract("#{name} rendered the wrong project namespace") unless config.fetch("name") == project
      config
    end

    first, second = rendered
    fail_contract("#{name} project namespaces collide") if first.fetch("name") == second.fetch("name")
    fail_contract("#{name} changed the pinned service set") unless
      first.fetch("services").keys.sort == base.fetch("services").keys.sort
    default_network = first.fetch("networks")
    fail_contract("#{name} attaches to an external or additional network") unless
      default_network.keys == ["default"] &&
      default_network.dig("default", "name") == "#{first.fetch('name')}_default" &&
      !default_network.fetch("default").fetch("external", false)

    first.fetch("services").each do |service_name, service|
      base_service = base.fetch("services").fetch(service_name)
      fail_contract("#{name}/#{service_name} changed its pinned image") unless
        service.fetch("image") == base_service.fetch("image")
      fail_contract("#{name}/#{service_name} retains a fixed container_name") if service.key?("container_name")
      fail_contract("#{name}/#{service_name} overrides the default Compose network") if service.key?("network_mode")
      fail_contract("#{name}/#{service_name} enables privileged mode") if service.fetch("privileged", false)
      fail_contract("#{name}/#{service_name} retains an unexpected capability") unless
        service.fetch("cap_add", []).empty?
      fail_contract("#{name}/#{service_name} retains a NAS device") unless service.fetch("devices", []).empty?
      fail_contract("#{name}/#{service_name} retains an unexpected supplemental group") unless
        service.fetch("group_add", []).empty?
      fail_contract("#{name}/#{service_name} leaves the private default network") unless
        service.fetch("networks", {}).keys == ["default"]

      mounts = bind_mounts(service)
      base_mounts_by_target = bind_mounts(base_service).to_h { |mount| [mount.fetch("target"), mount] }
      planned_binds = EXPECTED_BINDS.fetch(name).fetch(service_name, {})
      expected_targets = planned_binds.keys.sort
      fail_contract("#{name}/#{service_name} changed or omitted a container-side bind target") unless
        mounts.map { |mount| mount.fetch("target") }.sort == expected_targets

      mounts.each do |mount|
        source = mount.fetch("source")
        target = mount.fetch("target")
        base_mount = base_mounts_by_target.fetch(target)
        planned_source = planned_binds.fetch(target)
        expected_source = if planned_source == :docker_socket
                            "/var/run/docker.sock"
                          else
                            sandbox.join(planned_source).to_s
                          end
        expected_mount = base_mount.merge("source" => expected_source)
        fail_contract("#{name}/#{service_name} changes normalized bind semantics for #{target}") unless
          mount == expected_mount
        if target == "/var/run/docker.sock"
          fail_contract("#{name}/#{service_name} has unauthorized Docker socket access") unless
            %w[beszel dozzle].include?(name) && service_name == "socket-proxy" &&
            source == "/var/run/docker.sock" && mount.fetch("read_only", false)
        else
          expanded_source = Pathname(source).expand_path
          fail_contract("#{name}/#{service_name} bind escapes PLATFORM_MAC_SANDBOX") unless
            expanded_source.to_s.start_with?("#{sandbox}/")
        end
      end

      actual_ports = service.fetch("ports", []).sort_by { |port| [port.fetch("published"), port.fetch("target")] }
      expected_port_pairs = PORTS.fetch(name).fetch(service_name, [])
      expected_ports = expected_port_pairs.map do |published, target|
        expected_port(published, target)
      end.sort_by { |port| [port.fetch("published"), port.fetch("target")] }
      fail_contract("#{name}/#{service_name} changes normalized port semantics") unless
        actual_ports == expected_ports

      second_ports = second.fetch("services").fetch(service_name).fetch("ports", []).sort_by do |port|
        [port.fetch("published"), port.fetch("target")]
      end
      second_expected_ports = expected_port_pairs.map do |published, target|
        expected_port((published.to_i + 1000).to_s, target)
      end.sort_by { |port| [port.fetch("published"), port.fetch("target")] }
      fail_contract("#{name}/#{service_name} ports are not driven by the allocation") unless
        second_ports == second_expected_ports
    end

    if name == "beszel"
      agent = first.fetch("services").fetch("agent")
      fail_contract("Beszel agent retains Intel-only capability") unless agent.fetch("cap_add", []).empty?
      fail_contract("Beszel agent cannot resolve the hub") unless agent.dig("environment", "HUB_URL") == "http://hub:8090"
      fail_contract("Beszel agent bypasses the private socket proxy") unless
        agent.dig("environment", "DOCKER_HOST") == "tcp://socket-proxy:2375"
      fail_contract("Beszel agent retains Intel-only environment") unless
        %w[EXCLUDE_SMART INTEL_GPU_DEVICE].none? { |key| agent.fetch("environment", {}).key?(key) }
      fail_contract("Beszel socket proxy publishes a Docker API port") if
        first.fetch("services").fetch("socket-proxy").key?("ports")
    end

    if name == "dozzle"
      fail_contract("Dozzle does not use its private socket proxy") unless
        first.dig("services", "dozzle", "environment", "DOZZLE_REMOTE_HOST") == "tcp://socket-proxy:2375"
      fail_contract("Dozzle socket proxy publishes a Docker API port") if
        first.fetch("services").fetch("socket-proxy").key?("ports")
    end

    if name == "immich"
      server = first.fetch("services").fetch("immich-server")
      database = first.fetch("services").fetch("database")
      expected_identity = {
        "DB_DATABASE_NAME" => ENVIRONMENT.fetch("DB_DATABASE_NAME"),
        "DB_USERNAME" => ENVIRONMENT.fetch("DB_USERNAME")
      }
      fail_contract("Immich server rendered an empty or mismatched database identity") unless
        expected_identity.values.none?(&:empty?) &&
        server.fetch("environment").slice(*expected_identity.keys) == expected_identity
      fail_contract("Immich database identity differs from the server") unless
        database.dig("environment", "POSTGRES_DB") == expected_identity.fetch("DB_DATABASE_NAME") &&
        database.dig("environment", "POSTGRES_USER") == expected_identity.fetch("DB_USERNAME")
      fail_contract("Immich dependency DNS contract changed") unless
        server.fetch("depends_on").keys.sort == %w[database redis]
      fail_contract("Immich dependencies are not on the default Compose network") unless
        %w[immich-server redis database].all? do |service_name|
          !first.fetch("services").fetch(service_name).key?("network_mode")
        end
    end

    next unless name == "paperless-ngx"

    web = first.fetch("services").fetch("webserver")
    expected_addresses = {
      "PAPERLESS_DBHOST" => "db",
      "PAPERLESS_REDIS" => "redis://broker:6379",
      "PAPERLESS_TIKA_ENDPOINT" => "http://tika:9998",
      "PAPERLESS_TIKA_GOTENBERG_ENDPOINT" => "http://gotenberg:3000"
    }
    base_addresses = base.dig("services", "webserver", "environment").slice(*expected_addresses.keys)
    fail_contract("Paperless override does not exclusively change network addresses") unless
      base_addresses.keys.sort == expected_addresses.keys.sort &&
      base_addresses.all? { |key, value| value != expected_addresses.fetch(key) }
    fail_contract("Paperless dependency DNS addresses changed") unless
      web.fetch("environment").slice(*expected_addresses.keys) == expected_addresses
    fail_contract("Paperless dependency contract changed") unless
      web.fetch("depends_on").keys.sort == %w[broker db gotenberg tika]
    fail_contract("Paperless dependencies are not on the default Compose network") unless
      %w[webserver broker db gotenberg tika].all? do |service_name|
        !first.fetch("services").fetch(service_name).key?("network_mode")
      end
  end
end

puts "Legacy override contract: nine pinned stacks are disposable and isolated"
