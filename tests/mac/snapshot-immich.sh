#!/bin/sh
set -eu
set +x
umask 077

# Coordinated snapshot and rollback for Immich. Immich keeps one application
# state in three places that must move together: PostgreSQL rows, the original
# files under the media root, and the generated derivatives under the Docker
# root. Backing up any one of them alone produces a restore that starts and
# then serves broken thumbnails or missing originals, so every operation here
# takes all three or none.

usage() {
  printf '%s\n' \
    'usage: snapshot-immich.sh --self-test | snapshot DIR | restore DIR | drill DIR' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
mode=$1
shift

if [ "$mode" = --self-test ]; then
  [ "$#" -eq 0 ] || usage
  exec ruby - --self-test <<'RUBY'
require "digest"
require "fileutils"
require "json"
require "pathname"
require "tmpdir"

# The self-test exercises the coordination logic with no deployment: a manifest
# that does not notice a changed byte is the failure mode that turns a restore
# into silent data loss, so that is what gets tested offline.
def manifest_for(directory, members)
  {
    "schema" => 1,
    "members" => members.sort.map do |member|
      path = directory.join(member)
      { "name" => member, "bytes" => path.size,
        "sha256" => Digest::SHA256.file(path.to_s).hexdigest }
    end
  }
end

def verify_manifest(directory, manifest)
  problems = []
  problems << "manifest schema is not 1" unless manifest["schema"] == 1
  Array(manifest["members"]).each do |member|
    path = directory.join(member.fetch("name"))
    unless path.file? && !path.symlink?
      problems << "#{member.fetch('name')} is missing"
      next
    end
    problems << "#{member.fetch('name')} changed size" unless path.size == member.fetch("bytes")
    problems << "#{member.fetch('name')} changed content" unless
      Digest::SHA256.file(path.to_s).hexdigest == member.fetch("sha256")
  end
  problems
end

failures = []
def check(failures, condition, message)
  failures << message unless condition
end

Dir.mktmpdir("nas-platform-snapshot-selftest") do |raw|
  directory = Pathname.new(raw)
  directory.join("database.sql").write("-- dump\n")
  directory.join("originals.tar").write("originals")
  directory.join("generated.tar").write("generated")
  members = %w[database.sql generated.tar originals.tar]
  manifest = manifest_for(directory, members)

  check(failures, manifest.fetch("members").map { |m| m.fetch("name") } == members,
        "manifest must record every coordinated member in a stable order")
  check(failures, verify_manifest(directory, manifest).empty?,
        "an untouched snapshot must verify clean")

  directory.join("originals.tar").write("originals-tampered")
  problems = verify_manifest(directory, manifest)
  check(failures, problems.any? { |problem| problem.include?("originals.tar") },
        "a changed original must be reported")
  directory.join("originals.tar").write("originals")
  check(failures, verify_manifest(directory, manifest).empty?,
        "restoring the exact bytes must verify clean again")

  # Same length, different content: a size-only check would pass this.
  directory.join("database.sql").write("-- DUMP\n")
  check(failures, verify_manifest(directory, manifest).any? { |p| p.include?("changed content") },
        "a same-length edit must still be reported")
  directory.join("database.sql").write("-- dump\n")

  directory.join("generated.tar").unlink
  check(failures, verify_manifest(directory, manifest).any? { |p| p.include?("missing") },
        "a missing member must be reported")

  check(failures, verify_manifest(directory, { "schema" => 2, "members" => [] }).any?,
        "an unknown manifest schema must be refused")
end

if failures.empty?
  puts "snapshot-immich self-test: coordinated manifest logic holds"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} snapshot self-test failure(s)"
end
RUBY
fi

case $mode in
  snapshot|restore|drill) ;;
  *) usage ;;
esac
[ "$#" -eq 1 ] || usage
snapshot_dir=$1

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_IMMICH_PORT:=2283}"
if [ -n "${PLATFORM_PROJECT_NAME:-}" ]; then
  : "${PLATFORM_IMMICH_SERVER_CONTAINER:=$PLATFORM_PROJECT_NAME-immich-server}"
  : "${PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER:=$PLATFORM_PROJECT_NAME-immich-machine-learning}"
  : "${PLATFORM_IMMICH_POSTGRES_CONTAINER:=$PLATFORM_PROJECT_NAME-immich-postgres}"
else
  : "${PLATFORM_IMMICH_SERVER_CONTAINER:=immich_server}"
  : "${PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER:=immich_machine_learning}"
  : "${PLATFORM_IMMICH_POSTGRES_CONTAINER:=immich_postgres}"
fi
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_MEDIA_ROOT PLATFORM_IMMICH_PORT
export PLATFORM_IMMICH_SERVER_CONTAINER PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER
export PLATFORM_IMMICH_POSTGRES_CONTAINER

exec ruby - "$mode" "$snapshot_dir" <<'RUBY'
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

ORIGINALS_ROOT = MEDIA_ROOT.join("Immich")
GENERATED_ROOT = DOCKER_ROOT.join("immich", "data", "thumbs")
DUMP_NAME = "database.sql"
ORIGINALS_NAME = "originals.tar"
GENERATED_NAME = "generated.tar"
MEMBERS = [DUMP_NAME, GENERATED_NAME, ORIGINALS_NAME].freeze
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
  die("the snapshot does not carry all three coordinated members") unless recorded == MEMBERS.sort
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
    archive_tree(ORIGINALS_ROOT, directory.join(ORIGINALS_NAME))
    archive_tree(GENERATED_ROOT, directory.join(GENERATED_NAME))
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
    restore_tree(ORIGINALS_ROOT, directory.join(ORIGINALS_NAME))
    restore_tree(GENERATED_ROOT, directory.join(GENERATED_NAME))
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
  deadline = Time.now + 120
  loop do
    break if catalogue(authenticate).empty?

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
RUBY
