#!/bin/sh
set -eu
set +x

mode=${1:-run}
case $mode in
  static|run) ;;
  *)
    printf '%s\n' 'bindery contract accepts only static or run' >&2
    exit 2
    ;;
esac

repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
ruby - "$repo_dir" <<'RUBY'
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/bindery/defaults/main.yml
  roles/bindery/meta/argument_specs.yml
  roles/bindery/tasks/main.yml
  roles/bindery/tasks/pre_upgrade_backup.yml
  roles/bindery/tasks/reconcile_usenet.yml
  roles/bindery/tasks/resolve_api_key.yml
  roles/bindery/templates/env.j2
  services/bindery/compose.yml
  services/bindery/compose.mac.yml
  services/bindery/compose.integration.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

# Task files are flattened so a task on a block's rescue or always path is still
# a task the role executes.
def flatten_tasks(tasks)
  Array(tasks).flat_map do |task|
    next [] unless task.is_a?(Hash)

    [task] + flatten_tasks(task["block"]) + flatten_tasks(task["rescue"]) +
      flatten_tasks(task["always"])
  end
end

# The environment file is a line-oriented grammar, so it is read as the
# assignments it declares: a commented-out sample of the right assignment
# satisfies a substring search while the live line exports something else.
def environment_assignments(path)
  File.readlines(path, chomp: true).filter_map do |line|
    stripped = line.strip
    next unless stripped.match?(/\A[A-Z][A-Z0-9_]*=/)

    name, _separator, value = stripped.partition("=")
    [name, value]
  end
end

if failures.empty?
  compose = YAML.safe_load_file(File.join(root, "services/bindery/compose.yml"), aliases: true)
  service = compose.fetch("services").fetch("bindery")

  # Bindery is the first Phase 2 project that reaches another platform service.
  # Both of its integration writes resolve the submitted host at write time and
  # answer 400 when the lookup fails, so it has to sit on the shared control
  # network; the two existing acquisition contracts assert the absence of a
  # networks key and neither of those assertions may be copied here.
  failures << "Bindery must join the shared media control network" unless
    Array(service["networks"]) == %w[default media-control]
  failures << "the shared media control network must be the external one" unless
    compose.dig("networks", "media-control") ==
      { "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}" }

  # The runtime stage is distroless: no shell, no entrypoint script, no root
  # phase and no gosu, so nothing in the container can remap or chown. `user:`
  # is the only mechanism, and BINDERY_PUID/BINDERY_PGID are boot-time
  # assertions that exit 1 rather than a remap, so both have to agree with it.
  failures << "Bindery must take the platform identity as the container user" unless
    service["user"] == "${NAS_UID:?}:${NAS_GID:?}"
  {
    "BINDERY_PUID" => "${NAS_UID:?}",
    "BINDERY_PGID" => "${NAS_GID:?}"
  }.each do |name, expected|
    failures << "Bindery must assert the platform identity as #{name}" unless
      service.dig("environment", name) == expected
  end

  # The two libraries and the two staging directories are mounted at the same
  # absolute paths SABnzbd uses for the same host directories, because SABnzbd
  # reports a finished download by its own container path and Bindery reads that
  # path off the filesystem.
  failures << "Bindery must mount its database, both libraries and both staging roots" unless
    Array(service["volumes"]) == [
      "${BINDERY_CONFIG_PATH:?}:/config",
      "${BINDERY_EBOOKS_PATH:?}:/data/books/Ebooks",
      "${BINDERY_AUDIOBOOKS_PATH:?}:/data/media/Audiobooks",
      "${BINDERY_EBOOK_DOWNLOADS_PATH:?}:/data/books/.acquisition/usenet/ebooks",
      "${BINDERY_AUDIOBOOK_DOWNLOADS_PATH:?}:/data/media/.acquisition/usenet/audiobooks"
    ]

  # Omitting either audiobook variable silently falls back to its ebook
  # equivalent and collapses the two libraries into one, which is the single
  # failure the design forbids and which no other reading would notice.
  {
    "BINDERY_LIBRARY_DIR" => "/data/books/Ebooks",
    "BINDERY_AUDIOBOOK_DIR" => "/data/media/Audiobooks",
    "BINDERY_DOWNLOAD_DIR" => "/data/books/.acquisition/usenet/ebooks",
    "BINDERY_AUDIOBOOK_DOWNLOAD_DIR" => "/data/media/.acquisition/usenet/audiobooks"
  }.each do |name, expected|
    failures << "Bindery must keep #{name} separate from its ebook equivalent" unless
      service.dig("environment", name) == expected
  end
  failures << "Bindery must disable telemetry in the environment" unless
    service.dig("environment", "BINDERY_TELEMETRY_DISABLED") == "true"
  # An over-broad trusted-proxy entry disables the per-IP login rate limiter,
  # and a URL base the platform does not serve breaks every published link.
  %w[BINDERY_TRUSTED_PROXY BINDERY_URL_BASE].each do |name|
    failures << "Bindery must leave #{name} unset" if
      service.fetch("environment", {}).key?(name)
  end

  failures << "Bindery must publish the acquisition web UI port" unless
    Array(service["ports"]) == ["8787:8787"]
  mac = YAML.safe_load_file(File.join(root, "services/bindery/compose.mac.yml"))
  failures << "the Mac override must republish the web UI on the harness port" unless
    mac.dig("services", "bindery", "ports") == ["${BINDERY_HOST_PORT:?}:8787"]

  # /bin, /sbin, /usr/bin and /usr/sbin all exist in the image and are all
  # empty; the only executable is /bindery. A CMD-SHELL probe cannot run at all,
  # and because deployment waits for health the failure surfaces as a timeout
  # that says nothing about the cause.
  probe = Array(service.dig("healthcheck", "test"))
  failures << "the Bindery health probe must be the binary's own exec-form subcommand" unless
    probe == %w[CMD /bindery healthcheck]

  defaults = YAML.safe_load_file(File.join(root, "roles/bindery/defaults/main.yml"))
  {
    "bindery_ebooks_host_path" => "{{ nas_media_root }}/Books/Ebooks",
    "bindery_audiobooks_host_path" => "{{ nas_media_root }}/Media/Audiobooks",
    "bindery_ebook_downloads_host_path" =>
      "{{ nas_media_root }}/Books/.acquisition/usenet/ebooks",
    "bindery_audiobook_downloads_host_path" =>
      "{{ nas_media_root }}/Media/.acquisition/usenet/audiobooks",
    "bindery_config_host_path" => "{{ nas_docker_root }}/bindery/config",
    "bindery_ebooks_root" => "/data/books/Ebooks",
    "bindery_audiobooks_root" => "/data/media/Audiobooks"
  }.each do |name, expected|
    failures << "Bindery must declare #{name} as #{expected}" unless defaults[name] == expected
  end
  failures << "Bindery must declare exactly the two destination roots" unless
    defaults["bindery_library_roots"] ==
      ["{{ bindery_ebooks_root }}", "{{ bindery_audiobooks_root }}"]
  # The auto-grab kill switch fails open: a missing row, a read error and an
  # unattached repository all read as enabled, so silence means grabbing.
  failures << "Bindery must pin the auto-grab kill switch and telemetry off" unless
    defaults["bindery_pinned_settings"] ==
      { "autoGrab.enabled" => "false", "telemetry.enabled" => "false" }
  failures << "Bindery must address Prowlarr and SABnzbd by their control-network alias" unless
    defaults["bindery_prowlarr_internal_url"] == "http://prowlarr:9696" &&
    defaults["bindery_sabnzbd_host"] == "sabnzbd"
  # One client serves both libraries only because the two categories differ;
  # SABnzbd's own category map is what lands each in its library's staging root.
  failures << "Bindery must keep the ebook and audiobook download categories distinct" unless
    defaults["bindery_sabnzbd_ebook_category"] == "ebooks" &&
    defaults["bindery_sabnzbd_audiobook_category"] == "audiobooks"
  failures << "Bindery must leave the Usenet integrations disabled by default" unless
    defaults["media_usenet_enabled"] == false

  env_assignments = environment_assignments(
    File.join(root, "roles/bindery/templates/env.j2")
  )
  failures << "Bindery env must render the CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  # The API-key seed is the only credential Bindery reads from its environment,
  # and it is the one that closes the anonymous first-run setup window. Any
  # other would be a copy nothing consumes.
  failures << "the Bindery environment must carry exactly the API-key seed" unless
    env_assignments.select { |_name, value| value.include?("vault_") } ==
      [["BINDERY_API_KEY", "{{ vault_bindery_api_key }}"]]

  role_tasks = %w[
    roles/bindery/tasks/main.yml
    roles/bindery/tasks/pre_upgrade_backup.yml
    roles/bindery/tasks/reconcile_usenet.yml
    roles/bindery/tasks/resolve_api_key.yml
  ].flat_map do |relative|
    flatten_tasks(YAML.safe_load_file(File.join(root, relative), aliases: true))
  end
  tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/bindery/tasks/main.yml"), aliases: true)
  )

  failures << "Bindery must deploy through docker_compose_v2" unless
    tasks.count { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" } == 1
  failures << "Bindery must verify its effective project CPU policy" unless
    tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "bindery" } == 1

  # The state guard has to precede the deploy: Bindery applies its schema
  # migrations on startup, so by the time the new image answers the old schema
  # is already gone.
  backup_include = tasks.index do |task|
    task["ansible.builtin.include_tasks"] == "pre_upgrade_backup.yml"
  end
  deploy_index = tasks.index { |task| task.key?("community.docker.docker_compose_v2") }
  failures << "the Bindery pre-upgrade state guard must run before the deployment" unless
    backup_include && deploy_index && backup_include < deploy_index

  backup_tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/bindery/tasks/pre_upgrade_backup.yml"),
                        aliases: true)
  )
  backup_request = backup_tasks.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.end_with?("/backup")
  end
  # POST /backup is VACUUM INTO, which is the whole point: the database runs in
  # WAL mode, so a plain file copy silently omits what is still in the WAL. The
  # request accepts only 201, so a failed backup fails the play with the new
  # image still unstarted.
  failures << "the Bindery pre-upgrade backup must accept only a created backup" unless
    backup_request && backup_request.dig("ansible.builtin.uri", "method") == "POST" &&
    backup_request.dig("ansible.builtin.uri", "status_code") == [201]
  backup_conditions = Array(backup_request&.fetch("when", nil)).join(" ")
  failures << "the Bindery pre-upgrade backup must be gated on an actual image change" unless
    backup_conditions.include?("bindery_upgrade_pending") &&
    backup_conditions.include?("ansible_check_mode")

  # Nothing in Bindery is create-if-absent: a duplicate user or root folder is a
  # 500, and a duplicate Prowlarr instance or download client is a silent second
  # row. Every mutation is therefore read-then-decide.
  identity_write = tasks.find do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/auth/users" &&
      task.dig("ansible.builtin.uri", "method") == "POST"
  end
  identity_conditions = Array(identity_write&.fetch("when", nil)).join(" ")
  failures << "the Bindery administrator write must be gated on the deployed users" unless
    identity_write && identity_conditions.include?("bindery_administrator_present") &&
    identity_conditions.include?("ansible_check_mode")
  failures << "the Bindery administrator must be declared as an administrator" unless
    identity_write && identity_write.dig("ansible.builtin.uri", "body", "role") == "admin"

  root_write = tasks.find do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/rootfolder" &&
      task.dig("ansible.builtin.uri", "method") == "POST"
  end
  failures << "the Bindery destination roots must be created only where missing" unless
    root_write && root_write["loop"] == "{{ bindery_missing_roots }}" &&
    Array(root_write["when"]).join(" ").include?("ansible_check_mode")

  usenet_include = tasks.find do |task|
    task["ansible.builtin.include_tasks"] == "reconcile_usenet.yml"
  end
  failures << "the Bindery Usenet integrations must be gated on the transport flag" unless
    usenet_include && Array(usenet_include["when"]).join(" ").include?("media_usenet_enabled")

  usenet_tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/bindery/tasks/reconcile_usenet.yml"),
                        aliases: true)
  )
  {
    "prowlarr" => "bindery_prowlarr",
    "downloadclient" => "bindery_client"
  }.each do |resource, prefix|
    create = usenet_tasks.find do |task|
      task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/#{resource}" &&
        task.dig("ansible.builtin.uri", "method") == "POST"
    end
    failures << "the Bindery #{resource} row must be created only when absent" unless
      create && Array(create["when"]).join(" ").include?("#{prefix}_create")
    repair = usenet_tasks.find do |task|
      task.dig("ansible.builtin.uri", "method") == "PUT" &&
        task.dig("ansible.builtin.uri", "url").to_s.include?("/#{resource}/")
    end
    failures << "the Bindery #{resource} row must be repaired rather than duplicated" unless
      repair && Array(repair["when"]).join(" ").include?("#{prefix}_repair")
    duplicate_guard = usenet_tasks.find do |task|
      task.key?("ansible.builtin.assert") &&
        task.to_s.include?("#{prefix}_matches | length <= 1")
    end
    failures << "Bindery must refuse an ambiguous #{resource} match" if duplicate_guard.nil?
  end

  # The login limiter records five failures per fifteen minutes per IP and then
  # answers 429 to the correct password too, so no probe anywhere in this role
  # may submit a password it expects to be refused.
  wrong_password_probe = role_tasks.find do |task|
    body = task.dig("ansible.builtin.uri", "body")
    body.is_a?(Hash) && body.key?("password") &&
      body["password"].to_s != "{{ vault_bindery_admin_password }}"
  end
  failures << "no Bindery request may submit a password the platform expects to be wrong" if
    wrong_password_probe

  # Every request, render and fact naming a credential must stay redacted: the
  # bodies, headers and resolved values are what a module result renders in
  # full. Assertions are judged separately below, because redacting one costs
  # the diagnostic that is the entire reason it exists.
  credential_tasks = role_tasks
                     .reject { |task| task.key?("ansible.builtin.assert") }
                     .select do |task|
    task.to_s.match?(/vault_bindery_(?:api_key|admin_username|admin_password)|bindery_api_key/)
  end
  failures << "every Bindery request naming a credential must use no_log" unless
    credential_tasks.length >= 10 && credential_tasks.all? { |task| task["no_log"] == true }

  # The shape guard compares the authored values themselves, so it is redacted.
  # The recoverability guard only measures the resolved key's length, and its
  # whole purpose is the diagnostic it prints when Bindery is holding an
  # identity this platform did not author, so it must stay readable.
  shape_guard = role_tasks.find do |task|
    task.key?("ansible.builtin.assert") && task.to_s.include?("vault_bindery_api_key")
  end
  failures << "the Bindery credential shape guard must use no_log" unless
    shape_guard && shape_guard["no_log"] == true
  recovery_guard = role_tasks.find do |task|
    task.key?("ansible.builtin.assert") && task.to_s.include?("bindery_api_key | length")
  end
  failures << "the Bindery recoverability guard must stay readable" unless
    recovery_guard && !recovery_guard["no_log"]

  environment_render = tasks.find do |task|
    task.dig("ansible.builtin.template", "src") == "env.j2"
  end
  failures << "the Bindery environment render must be private" unless
    environment_render && environment_render.dig("ansible.builtin.template", "mode") == "0600"

  verification = tasks.select { |task| Array(task["tags"]).include?("platform_verify_bindery") }
  verification_urls = verification.filter_map { |task| task.dig("ansible.builtin.uri", "url") }
  %w[/health /auth/status /rootfolder /auth/login /system/storage].each do |suffix|
    failures << "Bindery verification must read #{suffix}" unless
      verification_urls.any? { |url| url.to_s.include?(suffix) }
  end
  # The refusal probe is a credential-free read of a protected route, never a
  # deliberately wrong password.
  anonymous = verification.find do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/rootfolder" &&
      !task.dig("ansible.builtin.uri").key?("headers")
  end
  failures << "Bindery verification must probe a protected route with no credential" if
    anonymous.nil?
  failures << "the Bindery anonymous refusal probe must stay readable" if
    anonymous && anonymous["no_log"]
  logins = verification.select do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/auth/login"
  end
  failures << "Bindery verification must spend exactly one login attempt" unless
    logins.length == 1
  failures << "Bindery verification must authenticate as the vault administrator" unless
    logins.first&.dig("ansible.builtin.uri", "body", "password") ==
      "{{ vault_bindery_admin_password }}"

  # Every probe accepts any status and defers to the assertion, so a drifted
  # credential fails with a diagnosis rather than inside a redacted request.
  verification.each do |task|
    next unless task.key?("ansible.builtin.uri")
    next unless task["failed_when"] == false

    failures << "#{task.fetch('name')} must accept any status and defer to the assertion" unless
      task.dig("ansible.builtin.uri", "status_code") == "{{ range(100, 600) | list }}"
  end
  outcome_assertion = verification.find { |task| task.key?("ansible.builtin.assert") }
  conditions = Array(outcome_assertion&.dig("ansible.builtin.assert", "that"))
  {
    "the enforced authentication mode" => ["bindery_verify_auth_status", "enabled"],
    "the closed first-run setup" => ["bindery_verify_auth_status", "setupRequired"],
    "the refused anonymous caller" => ["bindery_verify_anonymous.status", "401"],
    "the accepted vault administrator" => ["bindery_verify_identity.status", "200"],
    "the owned destination roots" => ["bindery_verify_roots", "bindery_library_roots"],
    "the writable configured storage" => ["bindery_verify_storage", "writable"]
  }.each do |label, (needle, value)|
    failures << "Bindery verification must assert #{label}" unless
      conditions.any? { |condition| condition.include?(needle) && condition.include?(value) }
  end
  # The diagnosis is the point of deferring, so it must not be redacted away.
  failures << "the Bindery outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]

  failures << "Bindery verification reads must not claim a change" unless
    verification.all? do |task|
      !task.key?("ansible.builtin.uri") ||
        (task["changed_when"] == false && task["check_mode"] == false)
    end
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end
RUBY

[ "$mode" = static ] && {
  printf '%s\n' 'bindery static contract: two-library acquisition ownership holds'
  exit 0
}

# The runtime half. Both disposable lanes deploy Bindery under a project
# namespace and name the container after it; production leaves the namespace
# empty and keeps the canonical Compose name.
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_BINDERY_PORT:=8787}"
# Prowlarr and SABnzbd only exist where the host enabled the transport, and the
# two integration rows cannot be written without them, so the lane says which
# state it converged rather than the contract guessing from what it finds.
: "${PLATFORM_BINDERY_USENET:=false}"
PLATFORM_BINDERY_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}bindery
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_BINDERY_PORT PLATFORM_BINDERY_CONTAINER
export PLATFORM_BINDERY_USENET

exec ruby - <<'RUBY'
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = 120
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_BINDERY_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_BINDERY_CONTAINER")
USENET = ENV.fetch("PLATFORM_BINDERY_USENET") == "true"
# Bindery's whole state is one SQLite database beneath the declared config root.
# It is what has to survive a container recreation, and its absence is what a
# wrongly owned or wrongly mounted config bind looks like.
DATABASE = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "bindery", "config", "bindery.db")
LIBRARY_ROOTS = ["/data/books/Ebooks", "/data/media/Audiobooks"].freeze

def fail_contract(message)
  warn "Bindery contract failed: #{message}"
  exit 1
end

def request(message)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(message) }
end

def get(path, headers = {})
  request(Net::HTTP::Get.new(URI.join(BASE, path), headers))
end

def post(path, payload, headers = {})
  message = Net::HTTP::Post.new(URI.join(BASE, path),
                                headers.merge("Content-Type" => "application/json"))
  message.body = JSON.generate(payload)
  request(message)
end

def parsed(response, what)
  JSON.parse(response.body)
rescue JSON::ParserError
  fail_contract("Bindery did not answer JSON for #{what}")
end

def wait_for_readiness
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = get("/api/v1/health")
      return response if response.code == "200"
    rescue StandardError
      nil
    end
    fail_contract("Bindery never answered its health endpoint") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

health = parsed(wait_for_readiness, "health")
fail_contract("Bindery did not report itself healthy") unless health["status"] == "ok"

state, _error, status = Open3.capture3(
  "docker", "inspect", CONTAINER, "--format", "{{.State.Health.Status}}"
)
fail_contract("the Bindery container could not be inspected") unless status.success?
# The image is distroless and has no shell, so this is also the proof that the
# probe is the binary's own subcommand rather than a CMD-SHELL that can never run.
fail_contract("the Bindery container is not healthy") unless state.strip == "healthy"

# The first-run setup route is anonymous until any user exists and answers 409
# to everyone afterwards. A 200 here would mean the platform had left the
# administrator account open to whoever reached the port first, permanently.
setup = post("/api/v1/auth/setup",
             "username" => "contract-should-never-win", "password" => "contract-password")
fail_contract("Bindery left its first-run setup open") unless setup.code == "409"

auth_status = parsed(get("/api/v1/auth/status"), "auth status")
# local-only grants administrator to every private-network peer with no
# credential, and an administrator may read the API key in clear.
fail_contract("Bindery does not enforce authentication") unless auth_status["mode"] == "enabled"
fail_contract("Bindery still reports first-run setup as required") if auth_status["setupRequired"]

# The refusal probe is a credential-free read of a protected route. It is never
# a wrong password: the login limiter records five failures per fifteen minutes
# per IP and then answers 429 to the correct password too.
fail_contract("Bindery served a protected route to an unauthenticated caller") unless
  get("/api/v1/rootfolder").code == "401"
fail_contract("Bindery served its OPDS catalogue to an unauthenticated caller") unless
  get("/opds/").code == "401"

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
username = vault.fetch("vault_bindery_admin_username")
password = vault.fetch("vault_bindery_admin_password")
seeded_key = vault.fetch("vault_bindery_api_key")

login = post("/api/v1/auth/login", "username" => username, "password" => password)
fail_contract("Bindery refused the vault-authored administrator") unless login.code == "200"
cookie = login.get_fields("set-cookie").to_a.map { |value| value.split(";", 2).first }.join("; ")
fail_contract("Bindery issued no session to the vault administrator") if cookie.empty?

# The seed is honoured only while the stored key is absent, so a deployment that
# converged is holding exactly the key the vault authored.
config = parsed(get("/api/v1/auth/config", "Cookie" => cookie), "auth config")
fail_contract("Bindery is not holding the vault-authored API key") unless
  config["apiKey"] == seeded_key
key_headers = { "X-Api-Key" => seeded_key }

users = parsed(get("/api/v1/auth/users", key_headers), "users")
administrators = users.select { |user| user["username"] == username && user["role"] == "admin" }
fail_contract("Bindery does not hold exactly one vault-authored administrator") unless
  administrators.length == 1

roots = get("/api/v1/rootfolder", key_headers)
fail_contract("Bindery refused to list its destination roots") unless roots.code == "200"
declared = parsed(roots, "root folders").map { |entry| entry.fetch("path") }
# Two roots, not one: an audiobook root that fell back to the ebook root is the
# single-library collapse the design forbids, and it looks identical everywhere
# else.
fail_contract("Bindery does not own exactly the declared ebook and audiobook roots") unless
  declared.sort == LIBRARY_ROOTS.sort

# The image is distroless, starts as no one privileged and has no shell, so it
# cannot repair a wrongly owned directory. This is where that becomes a named
# failure rather than a permission-denied import weeks later.
storage = parsed(get("/api/v1/system/storage", key_headers), "storage")
%w[download library audiobook audiobook-download].each do |name|
  entry = storage.fetch("dirs", []).find { |dir| dir["name"] == name }
  fail_contract("Bindery reports no #{name} directory") if entry.nil?
  fail_contract("Bindery cannot write its #{name} directory at #{entry['path']}") unless
    entry["exists"] && entry["writable"]
end

settings = parsed(get("/api/v1/setting", key_headers), "settings")
   .to_h { |entry| [entry.fetch("key"), entry.fetch("value")] }
# The auto-grab kill switch fails open, so an absent row means unattended
# grabbing is on.
{ "autoGrab.enabled" => "false", "telemetry.enabled" => "false" }.each do |key, value|
  fail_contract("Bindery does not pin #{key} to #{value}") unless settings[key] == value
end

instances = parsed(get("/api/v1/prowlarr", key_headers), "prowlarr instances")
clients = parsed(get("/api/v1/downloadclient", key_headers), "download clients")
# A repeated create answers 201 and adds a second row rather than failing, so
# the count is the property that a converged reconciliation has to hold.
fail_contract("Bindery holds duplicate Prowlarr instances") if instances.length > 1
fail_contract("Bindery holds duplicate download clients") if clients.length > 1

if USENET
  instance = instances.first
  fail_contract("Bindery declared no Prowlarr instance") if instance.nil?
  fail_contract("Bindery does not reach Prowlarr by its control-network alias") unless
    instance["url"] == "http://prowlarr:9696"
  # Credentials are write-only in every response, so a stored key can be proved
  # present and never proved correct.
  fail_contract("Bindery stored no Prowlarr credential") unless instance["apiKeyConfigured"]
  fail_contract("Bindery disabled its Prowlarr instance") unless instance["enabled"]

  client = clients.first
  fail_contract("Bindery declared no download client") if client.nil?
  fail_contract("Bindery does not reach SABnzbd by its control-network alias") unless
    client["type"] == "sabnzbd" && client["host"] == "sabnzbd" && client["port"] == 8080
  fail_contract("Bindery stored no SABnzbd credential") unless client["apiKeyConfigured"]
  # One client serves both libraries only because the two categories differ.
  fail_contract("Bindery collapsed its ebook and audiobook download categories") unless
    client["category"] == "ebooks" && client["categoryAudiobook"] == "audiobooks"
  fail_contract("Bindery disabled its download client") unless client["enabled"]
else
  fail_contract("Bindery declared a Prowlarr instance with the transport disabled") unless
    instances.empty?
  fail_contract("Bindery declared a download client with the transport disabled") unless
    clients.empty?
end

fail_contract("Bindery did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

puts "bindery contract: health, closed first-run setup, exclusive administrator identity, " \
     "two-root ownership, writable storage, pinned settings and persisted state hold"
RUBY
