#!/usr/bin/env ruby
# Coordinated snapshot, restore and rollback drill for Paperless-ngx.
#
# usage: snapshot-paperless.rb snapshot|restore|drill SNAPSHOT_DIR
#
# Paperless keeps one application state in four places that must move together:
# PostgreSQL rows, the archive and inbox trees under the media root, and the
# application tree under the Docker root. Every operation here takes all of them
# or none, with the webserver and redis stopped across the whole of it. The
# valkey queue is discarded on restore rather than captured, because it holds
# work queued against a database state the restore has just replaced.
#
# tests/mac/snapshot-paperless.sh is the shell wrapper: it validates the mode,
# refuses `drill` anywhere that is not a disposable Mac or integration sandbox,
# and exports the PLATFORM_* environment this program reads. It ran this program
# from a `<<'RUBY'` heredoc until #315 -- nothing syntax-checked it and no linter
# could reach it, and both tests/contracts/paperless.sh and
# tests/contracts/paperless-static.rb had to grep the wrapper for text that was
# really this program's. They now read this file, and the wrapper only for the
# one setting that is genuinely the wrapper's.
#
# The body below is byte-identical to what that heredoc rendered, its own
# requires included, and tests/mac/snapshot-paperless-test.rb covers the manifest
# logic it duplicates offline.
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "timeout"
require "uri"
require "yaml"

MODE = ARGV.fetch(0)
SNAPSHOT_DIR = Pathname.new(ARGV.fetch(1))
DOCKER_ROOT = Pathname.new(ENV.fetch("PLATFORM_DOCKER_ROOT")).expand_path
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
WEBSERVER = ENV.fetch("PLATFORM_PAPERLESS_WEBSERVER_CONTAINER")
POSTGRES = ENV.fetch("PLATFORM_PAPERLESS_POSTGRES_CONTAINER")
REDIS = ENV.fetch("PLATFORM_PAPERLESS_REDIS_CONTAINER")
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_PAPERLESS_PORT'), 10)}")
MEMBERS = %w[archive.tar application.tar database.sql inbox.tar].freeze
MANIFEST = "manifest.json"
# Floored at one second so a zero or negative setting still leaves a retry in
# place: the wait it guards is the only thing standing between recovery and the
# start race, and a knob that can switch it off is a knob that can restore the
# defect while every check still reports a pass.
RECOVERY_DEADLINE = [
  Integer(ENV.fetch("PLATFORM_PAPERLESS_RECOVERY_DEADLINE"), 10), 1
].max

def die(message)
  warn "Paperless snapshot failed: #{message}"
  exit 1
end

def run(*argv, input: nil)
  stdout, stderr, status = Open3.capture3(*argv, stdin_data: input.to_s)
  detail = stderr.to_s.lines.last(3).map(&:strip).reject(&:empty?).join("; ")
  stderr.replace("\0" * stderr.bytesize)
  die("#{argv.first} failed: #{detail}") unless status.success?
  stdout
end

def run_to_file(path, *argv)
  path.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    _pid, status = Process.wait2(Process.spawn(*argv, out: file, err: File::NULL))
    die("#{argv.first} failed") unless status.success?
  end
end

def safe_directory(path, empty: false)
  die("snapshot directory must be absolute") unless path.absolute?
  die("snapshot directory is unavailable or unsafe") unless path.directory? && !path.symlink?
  physical = path.realpath
  die("snapshot directory must not contain symlink aliases") unless physical.to_s == path.to_s
  die("refusing a non-empty snapshot directory") if empty && physical.children.any?
  physical
end

def manifest_for(directory)
  {
    "schema" => 1,
    "members" => MEMBERS.map do |name|
      path = directory.join(name)
      die("#{name} was not produced") unless path.file? && !path.symlink?
      { "name" => name, "bytes" => path.size,
        "sha256" => Digest::SHA256.file(path.to_s).hexdigest }
    end
  }
end

def verify_manifest(directory)
  path = directory.join(MANIFEST)
  die("manifest is unavailable or unsafe") unless path.file? && !path.symlink?
  manifest = JSON.parse(path.read)
  die("manifest schema differs") unless manifest["schema"] == 1
  die("manifest members differ") unless manifest.fetch("members").map { |member| member["name"] } == MEMBERS
  manifest.fetch("members").each do |member|
    member_path = directory.join(member.fetch("name"))
    die("#{member.fetch('name')} is unavailable or unsafe") unless
      member_path.file? && !member_path.symlink?
    die("#{member.fetch('name')} checksum differs") unless
      member_path.size == member.fetch("bytes") &&
      Digest::SHA256.file(member_path.to_s).hexdigest == member.fetch("sha256")
  end
end

def archive(path, source)
  die("snapshot source is unavailable or unsafe") unless source.directory? && !source.symlink?
  run_to_file(path, "tar", "-C", source.to_s, "-cf", "-", ".")
end

def clear_and_restore(target, archive_path)
  die("restore target is unavailable or unsafe") unless target.directory? && !target.symlink?
  target.children.each { |entry| FileUtils.remove_entry_secure(entry.to_s) }
  run("tar", "-C", target.to_s, "-xf", archive_path.to_s)
end

def wait_healthy(*containers)
  deadline = Time.now + 180
  containers.each do |container|
    loop do
      status = run(
        "docker", "inspect", "--format", "{{.State.Health.Status}}", container
      ).strip
      break if status == "healthy"
      die("#{container} did not become healthy") if Time.now >= deadline
      sleep 2
    end
  end
end

# Retries one command until it succeeds or the deadline passes, and hands the
# caller the last attempt's result instead of raising.
#
# docker start returns once the container process has been launched, not once the
# server inside it has bound its port, so a command aimed at that port straight
# after a start can lose the race and fail with a connection refusal. Waiting on
# the command itself is what closes the window, and it is strictly better here
# than waiting on {{.State.Health.Status}}: health only refreshes at the
# container's healthcheck interval, so it can still report the pre-restart state
# long after the socket is live, and it answers "did the healthcheck pass" rather
# than "can this exec reach the port".
#
# The sleep is this loop's poll interval, in the same shape as wait_healthy's,
# not a fixed wait standing in for a readiness signal: a redis that is already
# up costs one attempt and no sleep at all.
#
# Returning rather than calling die matters. The only caller is an ensure block
# unwinding a restore that may have already failed, and it has to record a
# recovery failure rather than raise one over the failure it is unwinding.
def capture_until_ready(*argv, deadline: RECOVERY_DEADLINE)
  limit = Time.now + deadline
  loop do
    stdout, stderr, status = Open3.capture3(*argv)
    return [stdout, stderr, status] if status.success? || Time.now >= limit
    sleep 1
  end
end

def request(method, path, token: nil, body: nil, expected: [200])
  uri = URI.join(BASE.to_s, path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Token #{token}" if token
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 60) do |http|
    http.request(request)
  end
  die("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless
    expected.include?(response.code.to_i)
  response.body.to_s.empty? ? nil : JSON.parse(response.body)
rescue JSON::ParserError
  die("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error => error
  die("#{method.upcase} #{uri.path} failed: #{error.class}")
end

def authenticate(username, password)
  request("post", "/api/token/", body: { "username" => username, "password" => password }).fetch("token")
end

def document_checksum(document)
  root_version = document.fetch("versions").find { |version| version.fetch("is_root") }
  checksum = root_version&.fetch("checksum")
  die("document root-version checksum is absent") if checksum.to_s.empty?
  checksum
end

def catalogue(token)
  request("get", "/api/documents/?page_size=1000", token: token).fetch("results").map do |document|
    { "id" => document.fetch("id"), "checksum" => document_checksum(document) }
  end.sort_by { |document| document.fetch("id") }
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"), ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
die("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
db_user = vault.fetch("vault_paperless_db_username")
db_name = vault.fetch("vault_paperless_db_name")
admin_username = vault.fetch("vault_paperless_admin_username")
admin_password = vault.fetch("vault_paperless_admin_password")

archive_root = MEDIA_ROOT.join("Documents/archive")
inbox_root = MEDIA_ROOT.join("Documents/inbox")
application_root = DOCKER_ROOT.join("paperless-ngx/data")

drill_before = nil
if MODE == "drill"
  drill_token = authenticate(admin_username, admin_password)
  drill_before = catalogue(drill_token)
  die("the rollback drill needs seeded documents") if drill_before.empty?
end

if MODE == "snapshot" || MODE == "drill"
  directory = safe_directory(SNAPSHOT_DIR, empty: true)
  run("docker", "stop", WEBSERVER, REDIS)
  begin
    run_to_file(directory.join("database.sql"), "docker", "exec", POSTGRES,
                "pg_dump", "--username", db_user, "--dbname", db_name,
                "--clean", "--if-exists", "--no-owner")
    archive(directory.join("archive.tar"), archive_root)
    archive(directory.join("application.tar"), application_root)
    archive(directory.join("inbox.tar"), inbox_root)
    directory.join(MANIFEST).open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(manifest_for(directory)) + "\n")
    end
  ensure
    run("docker", "start", REDIS, WEBSERVER)
  end
  wait_healthy(REDIS, WEBSERVER)
  puts "Paperless coordinated snapshot created"
end

if MODE == "drill"
  drill_token = authenticate(admin_username, admin_password)
  drill_before.each do |document|
    request("delete", "/api/documents/#{document.fetch('id')}/", token: drill_token, expected: [204])
  end
  # The poll reuses the token the deletion was authorized with instead of logging
  # in again on every pass. Paperless throttles /api/token/ at five requests a
  # minute by default (PAPERLESS_TOKEN_THROTTLE_RATE), and a pass every two
  # seconds is thirty a minute, so a login per pass exhausted the allowance about
  # ten seconds into the loop and request died on "POST /api/token/ returned HTTP
  # 429" before the drill could prove anything about the restore. The phases
  # before the drill have already spent part of that window, which is why it
  # failed sooner on a warm sandbox than the arithmetic alone suggests.
  #
  # Reusing that token is correct whatever /api/token/ does with existing ones:
  # it was issued at the top of this block, and nothing between there and here
  # restarts a container or restores the database, so it is the freshest
  # credential the drill holds.
  #
  # The timing is unchanged on purpose. The wait is what proves the asynchronous
  # deletion settles, so a longer sleep or a shorter deadline would weaken what
  # the drill demonstrates rather than fix the login budget.
  deadline = Time.now + 120
  loop do
    break if catalogue(drill_token).empty?
    die("the rollback mutation did not remove the documents") if Time.now >= deadline
    sleep 2
  end
end

if MODE == "restore" || MODE == "drill"
  directory = safe_directory(SNAPSHOT_DIR)
  verify_manifest(directory)
  run("docker", "stop", WEBSERVER, REDIS)
  begin
    clear_and_restore(archive_root, directory.join("archive.tar"))
    clear_and_restore(application_root, directory.join("application.tar"))
    clear_and_restore(inbox_root, directory.join("inbox.tar"))
    database_sql = directory.join("database.sql").binread
    run("docker", "exec", "-i", POSTGRES, "psql", "--username", db_user,
        "--dbname", db_name, input: database_sql)
    database_sql.replace("\0" * database_sql.bytesize)
  ensure
    restore_failure = $!
    recovery_failures = []
    # The flushall is the only step that has to wait, and it must: it reaches
    # valkey over 127.0.0.1:6379 immediately after the start above, so as a
    # one-shot exec it raced the socket and intermittently reported a connection
    # refusal on a restore that had in fact succeeded. Repeating it is free
    # because discarding an already-discarded queue discards the same queue.
    # The two starts speak to the docker daemon rather than to a service port, so
    # they cannot lose that race and retrying them would only delay the report.
    [
      [["docker", "start", REDIS], :once],
      [["docker", "exec", REDIS, "valkey-cli", "flushall"], :until_ready],
      [["docker", "start", WEBSERVER], :once]
    ].each do |argv, attempts|
      _stdout, stderr, status = if attempts == :until_ready
                                  capture_until_ready(*argv)
                                else
                                  Open3.capture3(*argv)
                                end
      recovery_failures << "#{argv[1..].join(' ')}: #{stderr.lines.last.to_s.strip}" unless status.success?
    end
    begin
      wait_healthy(REDIS, WEBSERVER)
    rescue SystemExit => error
      recovery_failures << "health check exited #{error.status}"
    end
    unless recovery_failures.empty?
      warn "Paperless snapshot recovery failed: #{recovery_failures.join('; ')}"
    end
    raise restore_failure if restore_failure
    die("application recovery failed") unless recovery_failures.empty?
  end
  if MODE == "drill"
    restored = catalogue(authenticate(admin_username, admin_password))
    die("restored Paperless records differ from the snapshot") unless restored == drill_before
  end
  puts "Paperless coordinated snapshot restored"
end
