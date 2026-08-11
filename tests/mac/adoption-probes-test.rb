#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("../..", __dir__)
PROBES = File.join(__dir__, "adoption-probes")
SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager
].freeze
SECRET = "probe-contract-secret-canary"

def executable(path, body)
  File.write(path, body)
  File.chmod(0o700, path)
end

def json_response(status, payload, headers = {})
  body = payload.nil? ? "" : JSON.generate(payload)
  [status, { "Content-Type" => "application/json" }.merge(headers), body]
end

def response_for(path, method, headers, body, root, mode)
  raise "forced malformed response" if mode == "malformed" && path.include?("/api/users")
  return json_response(503, { "error" => "unavailable" }) if mode == "status" && path == "/api/token"

  case path
  when "/login" then json_response(200, { "user" => { "accessToken" => "opaque" } })
  when "/api/users" then json_response(200, { "users" => [{ "username" => "admin", "type" => "root", "isActive" => true }] })
  when "/api/libraries" then json_response(200, [{ "id" => "library", "name" => "Audiobooks", "mediaType" => "book" }])
  when %r{\A/api/libraries/library/items} then json_response(200, { "results" => [{ "id" => "item" }], "total" => 1 })
  when %r{/api/collections/_superusers/auth-with-password} then json_response(200, { "token" => "opaque" })
  when %r{/api/collections/_superusers/records} then
    pages = mode == "pagination" ? 2 : 1
    json_response(200, { "totalPages" => pages, "items" => [
      { "email" => "root@example.test", "verified" => true },
      { "email" => "audit@example.test", "verified" => true }
    ] })
  when %r{/api/collections/users/records} then
    json_response(200, { "totalPages" => 1, "items" => [
      { "email" => "reader@example.test", "role" => "user", "verified" => true }
    ] })
  when %r{/api/collections/systems/records} then
    json_response(200, { "totalPages" => 1, "items" => [{ "name" => "ASUSTOR-AS6704T" }] })
  when %r{/api/collections/alerts/records} then
    json_response(200, { "totalPages" => 1, "items" => [{ "id" => "alert" }] })
  when "/api/token" then json_response(200, nil, "Set-Cookie" => "session=opaque; HttpOnly")
  when "/api/notifications/dispatchers" then
    json_response(200, [
      { "id" => "managed", "name" => "ntfy nas-critical", "type" => "webhook",
        "url" => "http://ntfy/nas-critical", "template" => "managed-template",
        "headers" => { "Authorization" => "protected" } },
      { "id" => "other", "name" => "unmanaged", "type" => "webhook", "url" => "http://other",
        "template" => "other", "headers" => {} }
    ])
  when "/api/notifications/rules" then
    json_response(200, [{ "name" => "all", "enabled" => true, "containerExpression" => "true",
                          "logExpression" => "", "eventExpression" => "event", "cooldown" => 1,
                          "dispatcher" => { "id" => "managed" } }])
  when "/api/auth/login" then json_response(201, { "accessToken" => "opaque" })
  when "/api/admin/users?withDeleted=true" then
    json_response(200, [{ "email" => "admin@example.test", "isAdmin" => true, "deletedAt" => nil }])
  when "/api/search/metadata"
    total = mode == "immich_pagination" ? 3 : 2
    json_response(200, { "assets" => { "items" => [{}, {}], "total" => total } })
  when "/api/system-config" then
    json_response(200, { "backup" => { "database" => { "enabled" => true } },
                         "machineLearning" => { "enabled" => true }, "newVersionCheck" => { "enabled" => false } })
  when "/Users/AuthenticateByName" then json_response(200, { "AccessToken" => "opaque", "User" => { "Id" => "admin" } })
  when "/Users" then
    json_response(200, [{ "Name" => "admin", "Policy" => { "IsAdministrator" => true, "IsDisabled" => false } }])
  when "/Library/VirtualFolders" then json_response(200, [{ "Name" => "Movies" }])
  when %r{\A/Items\?} then json_response(200, { "Items" => [{ "Id" => "movie" }], "TotalRecordCount" => 1 })
  when "/api/v2/users" then json_response(200, [{ "email" => "admin@example.test", "roles" => ["ADMIN"] }])
  when "/api/v1/libraries" then json_response(200, [{ "id" => "books", "name" => "Books" }])
  when %r{\A/api/v1/books\?} then json_response(200, { "content" => [{ "id" => "book" }] })
  when %r{\A/api/v1/series\?} then json_response(200, { "content" => [{ "id" => "series" }] })
  when "/v1/account" then [200, { "Content-Type" => "text/plain" }, ""]
  when "/api/token/" then json_response(200, { "token" => "opaque" })
  when %r{\A/api/users/} then
    json_response(200, { "next" => nil, "results" => [
      { "username" => "admin", "is_superuser" => true, "is_staff" => true, "is_active" => true }
    ] })
  when %r{\A/api/documents/} then json_response(200, { "next" => nil, "results" => [{ "id" => 1 }] })
  when %r{\A/api/mail_accounts/} then json_response(200, { "next" => nil, "results" => [{ "name" => "paperless" }] })
  when "/api/movie", "/api/tvshow"
    return json_response(403, { "error" => "forbidden" }) unless headers["api-key"] == SECRET
    command = JSON.parse(body)
    output = command.fetch("args").fetch("exportPath").delete_prefix("/data/")
    count = path.end_with?("movie") ? 3 : 2
    export_root = File.join(root, "legacy/tinymediamanager/data", output)
    export_bytes = if mode == "tmm_oversized"
                     "record\n" * 160_000
                   elsif mode == "tmm_missing"
                     ""
                   else
                     "record\n" * count
                   end
    File.binwrite(File.join(export_root, "index.html"), export_bytes)
    File.binwrite(File.join(export_root, "unexpected"), "x") if mode == "tmm_extra"
    json_response(200, nil)
  else
    json_response(404, { "error" => "not found" })
  end
rescue JSON::ParserError, KeyError
  json_response(400, { "error" => "bad request" })
end

failures = []
Dir.mktmpdir("adoption-probes-test-") do |root|
  root = File.realpath(root)
  mac = File.join(root, "tests/mac")
  contracts = File.join(root, "tests/contracts")
  bin = File.join(root, "bin")
  FileUtils.mkdir_p([mac, contracts, bin])
  FileUtils.cp(File.join(__dir__, "adoption-baseline.rb"), mac)
  FileUtils.mkdir_p(File.join(mac, "adoption-probes"))
  FileUtils.cp_r(File.join(PROBES, "tinymediamanager-templates"), File.join(mac, "adoption-probes"))
  contract_arguments = {
    "audiobookshelf" => "assert-persistence",
    "beszel" => "verify",
    "dozzle" => "verify",
    "immich" => "--platform mac assert-persistence",
    "jellyfin" => "--platform mac assert-persistence",
    "komga" => "assert-persistence",
    "paperless" => "assert-persistence",
    "tinymediamanager" => "assert-persistence"
  }
  contract_environment = {
    "audiobookshelf" => "[ \"$PLATFORM_AUDIOBOOKSHELF_MEDIA_LIBRARY\" = '#{root}/legacy/audiobookshelf/media' ]",
    "beszel" => "true",
    "dozzle" => "true",
    "immich" => "[ \"$PLATFORM_IMMICH_UPLOAD_ROOT\" = '#{root}/legacy/immich/data/upload' ] && " \
                "if [ \"${PLATFORM_ADOPTION_PROBE_TARGET:-false}\" = true ]; then " \
                "[ \"$PLATFORM_IMMICH_SERVER_CONTAINER\" = " \
                "\"${PLATFORM_EXPECT_IMMICH_SERVER_CONTAINER:-proof-immich-server}\" ] && " \
                "[ \"$PLATFORM_IMMICH_POSTGRES_CONTAINER\" = " \
                "\"${PLATFORM_EXPECT_IMMICH_POSTGRES_CONTAINER:-proof-immich-postgres}\" ]; else " \
                "[ \"$PLATFORM_IMMICH_SERVER_CONTAINER\" = 'proof-legacy-immich-immich-server-1' ] && " \
                "[ \"$PLATFORM_IMMICH_POSTGRES_CONTAINER\" = 'proof-legacy-immich-database-1' ]; fi",
    "jellyfin" => "[ \"$PLATFORM_JELLYFIN_MEDIA_ROOT\" = '#{root}/legacy/jellyfin/media' ] && " \
                  "if [ \"${PLATFORM_ADOPTION_PROBE_TARGET:-false}\" = true ]; then " \
                  "[ \"$PLATFORM_JELLYFIN_CONTAINER\" = " \
                  "\"${PLATFORM_EXPECT_JELLYFIN_CONTAINER:-proof-jellyfin}\" ]; else " \
                  "[ \"$PLATFORM_JELLYFIN_CONTAINER\" = 'proof-legacy-jellyfin-jellyfin-1' ]; fi",
    "komga" => "[ \"$PLATFORM_KOMGA_LIBRARY_PATH\" = '#{root}/legacy/komga/library' ]",
    "paperless" => "[ \"$PLATFORM_PAPERLESS_CONSUME_ROOT\" = '#{root}/legacy/paperless-ngx/consume' ] && " \
                   "[ \"$PLATFORM_CONTRACT_REPO_DIR\" = '#{root}/tests/mac/../..' ] && " \
                   "if [ \"${PLATFORM_ADOPTION_PROBE_TARGET:-false}\" = true ]; then " \
                   "[ \"$PLATFORM_PAPERLESS_WEBSERVER_CONTAINER\" = " \
                   "\"${PLATFORM_EXPECT_PAPERLESS_CONTAINER:-proof-paperless-webserver}\" ]; else " \
                   "[ \"$PLATFORM_PAPERLESS_WEBSERVER_CONTAINER\" = " \
                   "'proof-legacy-paperless-ngx-webserver-1' ]; fi",
    "tinymediamanager" => "[ \"$PLATFORM_TINYMEDIAMANAGER_MOVIES_ROOT\" = " \
                           "'#{root}/legacy/tinymediamanager/movies' ] && " \
                           "if [ \"${PLATFORM_ADOPTION_PROBE_TARGET:-false}\" = true ]; then " \
                           "[ \"$PLATFORM_TINYMEDIAMANAGER_CONTAINER\" = " \
                           "\"${PLATFORM_EXPECT_TMM_CONTAINER:-proof-tinymediamanager}\" ]; else " \
                           "[ \"$PLATFORM_TINYMEDIAMANAGER_CONTAINER\" = " \
                           "'proof-legacy-tinymediamanager-tinymediamanager-1' ]; fi"
  }
  contract_arguments.each do |name, expected|
    executable(File.join(contracts, "#{name}.sh"), <<~SH)
      #!/bin/sh
      set -eu
      [ "$*" = '#{expected}' ] || exit 64
      [ "$PLATFORM_CONTRACT_VAULT_FILE" = '#{root}/vault.yml' ] || exit 65
      [ "$PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" = '#{root}/vault-password' ] || exit 66
      #{contract_environment.fetch(name)} || exit 67
      exit 0
    SH
  end
  fixture_helper = File.join(contracts, "legacy-fixture-paths.sh")
  executable(fixture_helper, "#!/bin/sh\ntrue\n")
  %w[beszel dozzle].each do |name|
    executable(File.join(mac, "run-#{name}-contract.sh"), <<~SH)
      #!/bin/sh
      set -eu
      [ "$#" -eq 1 ] && [ "$1" = verify ] || exit 64
      [ "$PLATFORM_MAC_VAULT_FILE" = '#{root}/vault.yml' ] || exit 65
      [ "$PLATFORM_MAC_VAULT_PASSWORD_FILE" = '#{root}/vault-password' ] || exit 66
      if [ "${PLATFORM_PROOF_PLATFORM:-mac}" = integration ]; then
        [ "$PLATFORM_CALLBACK_HOST" = 172.17.0.1 ] || exit 67
      fi
      exit 0
    SH
  end
  executable(File.join(bin, "ansible-vault"), <<~YAML)
    #!/bin/sh
    cat <<'EOF'
    vault_audiobookshelf_admin_username: admin
    vault_audiobookshelf_admin_password: #{SECRET}
    vault_beszel_superuser_email: root@example.test
    vault_beszel_superuser_password: #{SECRET}
    vault_dozzle_admin_username: admin
    vault_dozzle_admin_password: #{SECRET}
    vault_immich_admin_email: admin@example.test
    vault_immich_admin_password: #{SECRET}
    vault_jellyfin_admin_username: admin
    vault_jellyfin_admin_password: #{SECRET}
    vault_komga_admin_email: admin@example.test
    vault_komga_admin_password: #{SECRET}
    vault_ntfy_admin_user: reader
    vault_ntfy_admin_password: #{SECRET}
    vault_paperless_admin_username: admin
    vault_paperless_admin_password: #{SECRET}
    vault_paperless_mail_account_name: paperless
    vault_tinymediamanager_password: #{SECRET}
    EOF
  YAML
  executable(File.join(bin, "docker"), <<~'SH')
    #!/bin/sh
    if [ -n "${PLATFORM_EXPECT_NTFY_CONTAINER:-}" ]; then
      [ "$1" = exec ] && [ "$2" = "$PLATFORM_EXPECT_NTFY_CONTAINER" ] || exit 68
    fi
    cat <<'EOF'
    user * (role: anonymous, tier: none)
    - no access to any (other) topics (server config)
    user Reader (role: user, tier: none)
    - read-only access to topic nas-critical
    - write-only access to topic side-channel
    user Writer (role: user, tier: none)
    - no topic-specific permissions
    user Unmanaged (role: user, tier: none)
    - read-only access to topic unmanaged
    EOF
  SH

  %w[vault.yml vault-password].each do |name|
    File.write(File.join(root, name), "protected\n")
    File.chmod(0o600, File.join(root, name))
  end
  fixture_paths = [
    "legacy/audiobookshelf/media/task-9-contract-book/task-9-contract-book.wav",
    "legacy/immich/data/upload/nas-platform-contract-photo.jpg",
    "legacy/immich/data/upload/nas-platform-contract-video.mp4",
    "legacy/jellyfin/media/Movies/Task 11 Contract Movie (2026)/Task 11 Contract Movie (2026).mp4",
    "legacy/komga/library/task-10-contract-comic/Task 10 Contract Comic.cbz",
    "legacy/tinymediamanager/movies/Task 10 Contract Movie (2024)/Task 10 Contract Movie (2024).mp4",
    "legacy/tinymediamanager/series/Task 10 Contract Series/Season 01/Task 10 Contract Series - S01E01.mp4"
  ]
  fixture_paths.each do |relative|
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "fixture")
  end
  File.chmod(
    0o777,
    File.join(root, "legacy/tinymediamanager/movies/Task 10 Contract Movie (2024)")
  )
  File.chmod(
    0o777,
    File.join(root, "legacy/tinymediamanager/series/Task 10 Contract Series/Season 01")
  )
  FileUtils.mkdir_p(File.join(root, "legacy/tinymediamanager/data/templates"))
  dozzle = File.join(root, "legacy/dozzle/data/users.yml")
  FileUtils.mkdir_p(File.dirname(dozzle))
  File.write(dozzle, { "users" => { "admin" => { "roles" => ["read"] },
                                     "viewer" => { "roles" => ["read"] } } }.to_yaml)
  File.chmod(0o600, dozzle)
  ntfy_env = File.join(root, "legacy-env/ntfy.env")
  FileUtils.mkdir_p(File.dirname(ntfy_env))
  File.write(
    ntfy_env,
    "NTFY_AUTH_USERS=reader:x:user,writer:x:user\n" \
    "NTFY_AUTH_ACCESS=reader:nas-critical:read-only,reader:side-channel:write-only\n"
  )
  File.chmod(0o600, ntfy_env)
  target_ntfy_env = File.join(root, "nas-platform/runtime/services/ntfy/.env")
  FileUtils.mkdir_p(File.dirname(target_ntfy_env))
  FileUtils.cp(ntfy_env, target_ntfy_env)
  File.chmod(0o600, target_ntfy_env)
  report = File.join(root, "reports")
  FileUtils.mkdir_p(report)
  paperless_state = File.join(report, "paperless-persistence.json")
  File.write(paperless_state, JSON.generate("pdf_checksum" => "f" * 64))
  File.chmod(0o600, paperless_state)

  mode = "ok"
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  server_thread = Thread.new do
    loop do
      socket = server.accept
      request_line = socket.gets
      next socket.close unless request_line
      method, path, = request_line.split(" ", 3)
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end
      body = socket.read(headers.fetch("content-length", "0").to_i)
      status, response_headers, response_body = response_for(path, method, headers, body, root, mode)
      reason = status.between?(200, 299) ? "OK" : "Error"
      socket.write("HTTP/1.1 #{status} #{reason}\r\n")
      response_headers.each { |key, value| socket.write("#{key}: #{value}\r\n") }
      socket.write("Content-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}")
      socket.close
    rescue IOError, Errno::EBADF
      break
    rescue StandardError
      socket&.close
    end
  end
  server_thread.report_on_exception = false

  env = {
    "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "PLATFORM_ADOPTION_SCRIPT_DIR" => mac,
    "PLATFORM_MAC_SANDBOX" => root, "PLATFORM_MAC_VAULT_FILE" => File.join(root, "vault.yml"),
    "PLATFORM_MAC_VAULT_PASSWORD_FILE" => File.join(root, "vault-password"),
    "PLATFORM_PROJECT_NAME" => "proof", "PLATFORM_DOCKER_ROOT" => root,
    "PLATFORM_MEDIA_ROOT" => root, "PLATFORM_FIXTURE_ROOT" => root, "PLATFORM_REPORT_ROOT" => report,
    "PLATFORM_AUDIOBOOKSHELF_PORT" => port.to_s, "PLATFORM_BESZEL_PORT" => port.to_s,
    "PLATFORM_DOZZLE_PORT" => port.to_s, "PLATFORM_IMMICH_PORT" => port.to_s,
    "PLATFORM_JELLYFIN_PORT" => port.to_s, "PLATFORM_KOMGA_PORT" => port.to_s,
    "PLATFORM_NTFY_PORT" => port.to_s, "PLATFORM_PAPERLESS_PORT" => port.to_s,
    "PLATFORM_TINYMEDIAMANAGER_API_PORT" => port.to_s
  }
  env["TMPDIR"] = ["/private/tmp", "/tmp"].filter_map do |candidate|
    next unless File.exist?(candidate)
    canonical = File.realpath(candidate)
    stat = File.stat(canonical)
    canonical if stat.uid.zero? && (stat.mode & 0o7777) == 0o1777
  end.uniq.fetch(0)
  SERVICES.each do |service|
    stdout, stderr, status = Open3.capture3(env, File.join(PROBES, "#{service}.sh"))
    failures << "#{service} real probe failed: #{stderr}" unless status.success?
    failures << "#{service} probe leaked protected data" if stdout.include?(SECRET) || stderr.include?(SECRET)
    begin
      payload = JSON.parse(stdout)
      failures << "#{service} probe emitted multiple documents" unless stdout == "#{JSON.generate(payload)}\n"
      failures << "#{service} probe emitted diagnostics on success" unless stderr.empty?
      if service == "ntfy"
        reader = payload.fetch("identities").find { |identity| identity.fetch("name") == "Reader" }
        failures << "ntfy probe lost multiple ACLs" unless reader&.fetch("permissions")&.length == 2
        failures << "ntfy probe omitted unmanaged live user" unless payload.fetch("identities").any? do |identity|
          identity.fetch("name") == "Unmanaged"
        end
      elsif service == "beszel"
        failures << "Beszel probe omitted live superuser collection" unless payload.fetch("identities").length == 3
      elsif service == "tinymediamanager"
        failures << "tinyMediaManager probe did not count indexed exports" unless payload.fetch("record_counts") == {
          "movies" => 3, "shows" => 2
        }
      end
    rescue JSON::ParserError, KeyError => error
      failures << "#{service} probe output is invalid: #{error.message}"
    end
  end

  target_env = env.merge(
    "PLATFORM_ADOPTION_PROBE_TARGET" => "true",
    "PLATFORM_EXPECT_NTFY_CONTAINER" => "proof-ntfy"
  )
  File.write(ntfy_env, "NTFY_AUTH_USERS=stale:x:user\nNTFY_AUTH_ACCESS=stale:wrong:write-only\n")
  SERVICES.each do |service|
    _stdout, stderr, status = Open3.capture3(target_env, File.join(PROBES, "#{service}.sh"))
    failures << "#{service} target probe path failed: #{stderr}" unless status.success?
  end
  integration_target_env = target_env.merge(
    "PLATFORM_PROOF_PLATFORM" => "integration",
    "PLATFORM_CALLBACK_HOST" => "172.17.0.1",
    "PLATFORM_ADOPTION_NTFY_CONTAINER" => "ntfy",
    "PLATFORM_EXPECT_NTFY_CONTAINER" => "ntfy",
    "PLATFORM_IMMICH_SERVER_CONTAINER" => "immich_server",
    "PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER" => "immich_machine_learning",
    "PLATFORM_IMMICH_REDIS_CONTAINER" => "immich_redis",
    "PLATFORM_IMMICH_POSTGRES_CONTAINER" => "immich_postgres",
    "PLATFORM_EXPECT_IMMICH_SERVER_CONTAINER" => "immich_server",
    "PLATFORM_EXPECT_IMMICH_POSTGRES_CONTAINER" => "immich_postgres",
    "PLATFORM_JELLYFIN_CONTAINER" => "jellyfin",
    "PLATFORM_EXPECT_JELLYFIN_CONTAINER" => "jellyfin",
    "PLATFORM_PAPERLESS_WEBSERVER_CONTAINER" => "paperless_webserver",
    "PLATFORM_EXPECT_PAPERLESS_CONTAINER" => "paperless_webserver",
    "PLATFORM_TINYMEDIAMANAGER_CONTAINER" => "tinymediamanager",
    "PLATFORM_EXPECT_TMM_CONTAINER" => "tinymediamanager"
  )
  SERVICES.each do |service|
    _stdout, stderr, status = Open3.capture3(integration_target_env, File.join(PROBES, "#{service}.sh"))
    failures << "#{service} integration target probe path failed: #{stderr}" unless status.success?
  end
  descriptor_paths = {
    "PLATFORM_ADOPTION_BASELINE_FILE" => File.join(mac, "adoption-baseline.rb"),
    "PLATFORM_ADOPTION_TMM_MOVIE_TEMPLATE_CONF" =>
      File.join(mac, "adoption-probes/tinymediamanager-templates/movie/template.conf"),
    "PLATFORM_ADOPTION_TMM_MOVIE_LIST_JMTE" =>
      File.join(mac, "adoption-probes/tinymediamanager-templates/movie/list.jmte"),
    "PLATFORM_ADOPTION_TMM_TVSHOW_TEMPLATE_CONF" =>
      File.join(mac, "adoption-probes/tinymediamanager-templates/tvshow/template.conf"),
    "PLATFORM_ADOPTION_TMM_TVSHOW_LIST_JMTE" =>
      File.join(mac, "adoption-probes/tinymediamanager-templates/tvshow/list.jmte")
  }
  descriptors = descriptor_paths.transform_values { |path| File.open(path, File::RDONLY) }
  contract_names = {
    "audiobookshelf" => "audiobookshelf", "beszel" => "beszel", "dozzle" => "dozzle",
    "immich" => "immich", "jellyfin" => "jellyfin", "komga" => "komga",
    "paperless-ngx" => "paperless", "tinymediamanager" => "tinymediamanager"
  }
  contract_descriptors = contract_names.to_h do |service, name|
    [service, File.open(File.join(contracts, "#{name}.sh"), File::RDONLY)]
  end
  helper_descriptor = File.open(fixture_helper, File::RDONLY)
  descriptor_env = target_env.merge(
    descriptors.to_h { |variable, descriptor| [variable, "/dev/fd/#{descriptor.fileno}"] },
    "PLATFORM_CONTRACT_REPO_DIR" => root,
    "PLATFORM_LEGACY_FIXTURE_HELPER_FILE" => "/dev/fd/#{helper_descriptor.fileno}"
  )
  all_descriptors = descriptors.values + contract_descriptors.values + [helper_descriptor]
  descriptor_options = all_descriptors.to_h { |descriptor| [descriptor.fileno, descriptor.fileno] }
  SERVICES.each do |service|
    service_env = descriptor_env.dup
    if (contract = contract_descriptors[service])
      service_env["PLATFORM_ADOPTION_CONTRACT_FILE"] = "/dev/fd/#{contract.fileno}"
    end
    _stdout, stderr, status = Open3.capture3(
      service_env, File.join(PROBES, "#{service}.sh"), descriptor_options
    )
    failures << "#{service} descriptor-bound target probe failed: #{stderr}" unless status.success?
  end
  all_descriptors.each(&:close)
  FileUtils.cp(target_ntfy_env, ntfy_env)
  File.chmod(0o600, ntfy_env)

  mode = "pagination"
  _stdout, stderr, status = Open3.capture3(env, File.join(PROBES, "beszel.sh"))
  failures << "Beszel pagination was accepted" if status.success?
  failures << "Beszel failure diagnostic differs" unless stderr == "adoption-probe-error: evidence unavailable\n"
  mode = "malformed"
  _stdout, stderr, status = Open3.capture3(env, File.join(PROBES, "audiobookshelf.sh"))
  failures << "malformed probe response was accepted" if status.success?
  failures << "probe failure diagnostic leaked" if stderr.include?(SECRET)
  mode = "status"
  _stdout, stderr, status = Open3.capture3(env, File.join(PROBES, "dozzle.sh"))
  failures << "unexpected HTTP status was accepted" if status.success?
  failures << "HTTP status diagnostic differs" unless stderr == "adoption-probe-error: evidence unavailable\n"
  mode = "immich_pagination"
  _stdout, stderr, status = Open3.capture3(env, File.join(PROBES, "immich.sh"))
  failures << "Immich incomplete page was accepted" if status.success?
  failures << "Immich pagination diagnostic differs" unless stderr == "adoption-probe-error: evidence unavailable\n"
  %w[tmm_oversized tmm_extra tmm_missing].each do |failure_mode|
    mode = failure_mode
    _stdout, stderr, status = Open3.capture3(env, File.join(PROBES, "tinymediamanager.sh"))
    failures << "#{failure_mode} export was accepted" if status.success?
    failures << "#{failure_mode} diagnostic leaked" if stderr.include?(SECRET)
    leftovers = Dir.glob(File.join(root, "legacy/tinymediamanager/data/{.nas-adoption-*,templates/nas-adoption-*}"))
    failures << "#{failure_mode} left disposable artifacts" unless leftovers.empty?
  end
  executable(File.join(bin, "docker"), <<~'SH')
    #!/bin/sh
    cat <<'EOF'
    user * (role: anonymous, tier: none)
    - no access to any (other) topics (server config)
    user Reader (role: user, tier: none)
    - read-only access to topic nas-critical
    user reader (role: user, tier: none)
    - read-only access to topic nas-critical
    EOF
  SH
  mode = "ok"
  _stdout, stderr, status = Open3.capture3(env, File.join(PROBES, "ntfy.sh"))
  failures << "ntfy normalized duplicate was accepted" if status.success?
  failures << "ntfy duplicate diagnostic differs" unless stderr == "adoption-probe-error: evidence unavailable\n"
  File.write(
    ntfy_env,
    "NTFY_AUTH_USERS=reader:x:user,writer:x:user\n" \
    "NTFY_AUTH_ACCESS=reader:nas-critical:write-only\n"
  )
  File.chmod(0o600, ntfy_env)
  executable(File.join(bin, "docker"), <<~'SH')
    #!/bin/sh
    cat <<'EOF'
    user * (role: anonymous, tier: none)
    - no access to any (other) topics (server config)
    user Reader (role: user, tier: none)
    - read-only access to topic nas-critical
    user Writer (role: user, tier: none)
    - no topic-specific permissions
    EOF
  SH
  _stdout, stderr, status = Open3.capture3(env, File.join(PROBES, "ntfy.sh"))
  failures << "ntfy declarative ACL drift was accepted" if status.success?
  failures << "ntfy ACL diagnostic differs" unless stderr == "adoption-probe-error: evidence unavailable\n"
  executable(File.join(bin, "docker"), <<~'SH')
    #!/bin/sh
    cat <<'EOF'
    user * (role: anonymous, tier: none)
    - no access to any (other) topics (server config)
    user Reader (role: user, tier: none)
    - read-only access to topic nas-critical
    - write-only access to topic side-channel
    user Writer (role: user, tier: none)
    - no topic-specific permissions
    user Unmanaged (role: user, tier: none)
    - read-only access to topic unmanaged
    EOF
  SH
  [
    "NTFY_AUTH_ACCESS=reader:nas-critical:read-only\n",
    "NTFY_AUTH_ACCESS=reader:nas-critical:read-only,unmanaged:unmanaged:read-only\n"
  ].each do |access_line|
    File.write(ntfy_env, "NTFY_AUTH_USERS=reader:x:user,writer:x:user\n#{access_line}")
    File.chmod(0o600, ntfy_env)
    _stdout, stderr, status = Open3.capture3(env, File.join(PROBES, "ntfy.sh"))
    failures << "ntfy extra/undeclared ACL drift was accepted" if status.success?
    failures << "ntfy extra ACL diagnostic differs" unless stderr == "adoption-probe-error: evidence unavailable\n"
  end
ensure
  server&.close
  server_thread&.join(2)
end

abort failures.join("\n") unless failures.empty?
puts "adoption probe contracts: passed"
