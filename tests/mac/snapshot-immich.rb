#!/usr/bin/env ruby
# Coordinated snapshot, restore and rollback drill for Immich.
#
# usage: snapshot-immich.rb snapshot|restore|drill SNAPSHOT_DIR
#
# Immich keeps one application state in several places that must move together:
# PostgreSQL rows, the original files under the media root, and the profile and
# thumbnail trees under the Docker root. Every operation here takes all of them
# or none. The Valkey job queue is discarded on restore rather than captured,
# because it holds work queued against a database state the restore replaced.
#
# tests/mac/snapshot-immich.sh is the shell wrapper: it validates the mode,
# refuses `drill` outside a disposable Mac sandbox project, and exports the
# PLATFORM_* environment this program reads. It ran this program from a
# `<<'RUBY'` heredoc until #315 -- nothing syntax-checked it and no linter
# could reach it. The body below is byte-identical to what that heredoc
# rendered, and tests/mac/snapshot-immich-test.rb covers the manifest logic it
# duplicates offline.
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
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_IMMICH_PORT'), 10)}")
DOCKER_ROOT = Pathname.new(ENV.fetch("PLATFORM_DOCKER_ROOT")).expand_path
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
SERVER = ENV.fetch("PLATFORM_IMMICH_SERVER_CONTAINER")
MACHINE_LEARNING = ENV.fetch("PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER")
POSTGRES = ENV.fetch("PLATFORM_IMMICH_POSTGRES_CONTAINER")
REDIS = ENV.fetch("PLATFORM_IMMICH_REDIS_CONTAINER")

DUMP_NAME = "database.sql"
# The trees that must move with the database. The originals tree carries the
# irreplaceable uploads; the profile tree is classified critical in nas_storage
# and is regenerable from nothing; the thumbnail tree is the generated state a
# restored database expects to find already present.
#
# encoded-video and model-cache are deliberately absent because both are
# regenerable caches, and /data/backups is excluded because it holds Immich's
# own dumps: snapshotting a backup into a backup only doubles what a restore
# has to sift through.
TREES = [
  ["originals.tar", MEDIA_ROOT.join("Immich")],
  ["profile.tar", DOCKER_ROOT.join("immich", "data", "profile")],
  ["generated.tar", DOCKER_ROOT.join("immich", "data", "thumbs")]
].freeze
MEMBERS = ([DUMP_NAME] + TREES.map(&:first)).freeze
MANIFEST_NAME = "manifest.json"

def die(message)
  warn "Immich snapshot failed: #{message}"
  exit 1
end

def run(*argv, input: nil)
  stdout, stderr, status = Open3.capture3(*argv, stdin_data: input.to_s)
  unless status.success?
    detail = stderr.to_s.lines.last(3).map(&:strip).reject(&:empty?).join("; ")
    stderr.replace("\0" * stderr.bytesize)
    die("#{argv.first} failed: #{detail}")
  end
  stderr.replace("\0" * stderr.bytesize)
  stdout
end

def validate_directory(path, require_empty:)
  die("snapshot directory must be absolute") unless path.absolute?
  die("snapshot directory is unavailable or unsafe") unless
    path.directory? && !path.symlink?
  physical = path.realpath
  die("snapshot directory must not be a symlinked path") unless physical.to_s == path.to_s
  entries = physical.children.map(&:basename).map(&:to_s)
  if require_empty
    die("refusing to overwrite a non-empty snapshot directory") unless entries.empty?
  end
  physical
end

def manifest_for(directory)
  {
    "schema" => 1,
    "members" => MEMBERS.sort.map do |member|
      path = directory.join(member)
      die("#{member} was not produced") unless path.file? && !path.symlink?
      { "name" => member, "bytes" => path.size,
        "sha256" => Digest::SHA256.file(path.to_s).hexdigest }
    end
  }
end

def verify_manifest(directory)
  manifest_path = directory.join(MANIFEST_NAME)
  die("the snapshot manifest is missing") unless
    manifest_path.file? && !manifest_path.symlink?
  manifest = JSON.parse(manifest_path.read)
  die("unknown snapshot manifest schema") unless manifest["schema"] == 1
  recorded = Array(manifest["members"]).map { |member| member.fetch("name") }.sort
  die("the snapshot does not carry every coordinated member") unless recorded == MEMBERS.sort
  Array(manifest["members"]).each do |member|
    path = directory.join(member.fetch("name"))
    die("#{member.fetch('name')} is missing from the snapshot") unless
      path.file? && !path.symlink?
    die("#{member.fetch('name')} changed size since the snapshot") unless
      path.size == member.fetch("bytes")
    die("#{member.fetch('name')} changed content since the snapshot") unless
      Digest::SHA256.file(path.to_s).hexdigest == member.fetch("sha256")
  end
  manifest
end

def vault
  yaml, error, status = Open3.capture3(
    "ansible-vault", "view", "--vault-password-file",
    ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
    ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
  )
  die("encrypted vault could not be read") unless status.success?
  parsed = YAML.safe_load(yaml)
  yaml.replace("\0" * yaml.bytesize)
  error.replace("\0" * error.bytesize)
  parsed
end

CREDENTIALS = vault
DB_NAME = CREDENTIALS.fetch("vault_immich_db_name")
DB_USERNAME = CREDENTIALS.fetch("vault_immich_db_username")
ADMIN_EMAIL = CREDENTIALS.fetch("vault_immich_admin_email")
ADMIN_PASSWORD = CREDENTIALS.fetch("vault_immich_admin_password")

# Stopping the application is what makes the dump application-consistent: the
# job queues cannot enqueue a thumbnail whose row lands after pg_dump has read
# the asset table but whose file lands before the tar reads the directory.
def stop_writes
  run("docker", "stop", SERVER, MACHINE_LEARNING)
end

def start_writes
  run("docker", "start", MACHINE_LEARNING, SERVER)
end

# Immich deletes assets asynchronously through a job queue held in Valkey, so a
# restore that puts the rows and files back while the queue still holds the jobs
# that removed them gets quietly undone the moment the server starts draining
# it. The queue describes work against a database state that no longer exists,
# so discarding it is both safe and necessary.
def discard_queued_work
  run("docker", "exec", REDIS, "redis-cli", "flushall")
end

def dump_database(target)
  # Client and server are the same PostgreSQL 14 build inside this container, so
  # the dump and its restore can never disagree about dump-format directives.
  output = run(
    "docker", "exec", POSTGRES,
    "pg_dump", "--username=#{DB_USERNAME}", "--dbname=#{DB_NAME}",
    "--clean", "--if-exists", "--no-owner", "--no-privileges"
  )
  target.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(output) }
end

def restore_database(source)
  run("docker", "exec", "--interactive", POSTGRES,
      "psql", "--username=#{DB_USERNAME}", "--dbname=#{DB_NAME}",
      "--quiet", "--no-psqlrc", "--set=ON_ERROR_STOP=1",
      input: source.read)
end

def archive_tree(root, target)
  die("#{root} is unavailable or unsafe") unless root.directory? && !root.symlink?
  run("tar", "--create", "--file", target.to_s, "--directory", root.to_s, ".")
end

def restore_tree(root, source)
  die("#{root} is unavailable or unsafe") unless root.directory? && !root.symlink?
  root.children.each { |child| FileUtils.rm_rf(child.to_s, secure: true) }
  run("tar", "--extract", "--file", source.to_s, "--directory", root.to_s)
end

def request(method, path, token: nil, body: nil, expected: [200], raw: false)
  uri = URI.join(BASE.to_s, path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Bearer #{token}" if token
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 120) do |http|
    http.request(request)
  end
  die("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless
    expected.include?(response.code.to_i)
  return response if raw

  response.body.to_s.empty? ? nil : JSON.parse(response.body)
rescue JSON::ParserError
  die("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error, EOFError => error
  die("#{method.upcase} #{uri.path} failed: #{error.class}")
end

def wait_for_application
  deadline = Time.now + 300
  loop do
    uri = URI.join(BASE.to_s, "/api/server/config")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 15) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    return if response.code.to_i == 200 && JSON.parse(response.body)["isInitialized"] == true
  rescue JSON::ParserError, SystemCallError, Timeout::Error, EOFError
    nil
  ensure
    die("Immich did not come back after the snapshot operation") if Time.now >= deadline
    sleep 2
  end
end

def authenticate
  session = request("post", "/api/auth/login", expected: [201],
                    body: { "email" => ADMIN_EMAIL, "password" => ADMIN_PASSWORD })
  session.fetch("accessToken")
end

def catalogue(token)
  payload = request("post", "/api/search/metadata", token: token, body: {})
  payload.fetch("assets").fetch("items").map do |item|
    { "id" => item.fetch("id"), "checksum" => item.fetch("checksum"),
      "originalFileName" => item.fetch("originalFileName") }
  end.sort_by { |record| record.fetch("originalFileName") }
end

def originals_digest(token, records)
  records.to_h do |record|
    response = request("get", "/api/assets/#{record.fetch('id')}/original",
                       token: token, raw: true)
    [record.fetch("originalFileName"), Digest::SHA256.hexdigest(response.body)]
  end
end

def take_snapshot(directory)
  stop_writes
  begin
    dump_database(directory.join(DUMP_NAME))
    TREES.each { |name, root| archive_tree(root, directory.join(name)) }
    manifest = manifest_for(directory)
    directory.join(MANIFEST_NAME).open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate(manifest))
    end
  ensure
    start_writes
  end
  wait_for_application
end

def restore_snapshot(directory)
  verify_manifest(directory)
  stop_writes
  begin
    restore_database(directory.join(DUMP_NAME))
    TREES.each { |name, root| restore_tree(root, directory.join(name)) }
    discard_queued_work
  ensure
    start_writes
  end
  wait_for_application
end

case MODE
when "snapshot"
  directory = validate_directory(SNAPSHOT_DIR, require_empty: true)
  wait_for_application
  take_snapshot(directory)
  puts "Immich database, originals, and generated assets snapshotted together"
when "restore"
  directory = validate_directory(SNAPSHOT_DIR, require_empty: false)
  restore_snapshot(directory)
  puts "Immich database, originals, and generated assets restored together"
when "drill"
  # The shell preamble has already refused any project that is not a disposable
  # Mac sandbox; this is the destructive path it was guarding.
  directory = validate_directory(SNAPSHOT_DIR, require_empty: true)
  wait_for_application
  token = authenticate
  before = catalogue(token)
  die("the rollback drill needs at least one asset; run the seed phase first") if before.empty?
  before_originals = originals_digest(token, before)

  take_snapshot(directory)

  # Mutate the deployment the way a bad restore or a mistaken bulk delete would:
  # rows and files disappear together, so recovering needs both halves.
  token = authenticate
  ids = before.map { |record| record.fetch("id") }
  request("delete", "/api/assets", token: token, expected: [204],
          body: { "ids" => ids, "force" => true })
  # The poll reuses the session the deletion was authorized with, for the reason
  # the Paperless drill does: a login on every pass is about forty logins against
  # an endpoint whose rate limit no test controls, and nothing inside the loop
  # invalidates the session it would be replacing.
  deadline = Time.now + 120
  loop do
    break if catalogue(token).empty?

    die("the mutation did not remove the assets") if Time.now >= deadline
    sleep 3
  end

  restore_snapshot(directory)

  token = authenticate
  after = catalogue(token)
  die("database records do not match the snapshot") unless after == before
  die("originals do not open with the snapshotted bytes") unless
    originals_digest(token, after) == before_originals
  puts "Immich coordinated rollback restored #{after.length} asset(s), " \
       "database records and originals both intact"
end
