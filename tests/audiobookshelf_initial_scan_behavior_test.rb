#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "timeout"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
MAIN_TASKS = File.join(ROOT, "roles", "audiobookshelf", "tasks", "main.yml")
SCAN_TASKS = File.join(ROOT, "roles", "audiobookshelf", "tasks", "initial_scan.yml")
DEFAULTS = YAML.safe_load_file(
  File.join(ROOT, "roles", "audiobookshelf", "defaults", "main.yml"), aliases: false
)
MARKER_NAME = ".nas-platform-initial-scan.json"
LIBRARY_ID = "managed-library"
LIBRARY_NAME = DEFAULTS.fetch("audiobookshelf_library_name")
MEDIA_SENTINEL = "MEDIA_SECRET_SENTINEL"

def selected_scan_tasks(stop_after: nil, stop_before: nil)
  return YAML.safe_load_file(SCAN_TASKS, aliases: false) if File.file?(SCAN_TASKS)

  tasks = YAML.safe_load_file(MAIN_TASKS, aliases: false)
  first = tasks.index { |task| task["name"] == "Resolve Audiobookshelf library repair requirement" }
  last = tasks.index { |task| task["name"] == "Clear completed Audiobookshelf initial scan intent" }
  raise "Audiobookshelf initial scan task slice is unavailable" unless first && last && first <= last

  selected = tasks[first..last]
  interruption = {
    "name" => "Interrupt Audiobookshelf reconciliation fixture",
    "ansible.builtin.fail" => { "msg" => "EXPECTED_RECONCILIATION_INTERRUPTION" },
    "no_log" => true
  }
  if stop_after
    index = selected.index { |task| task["name"] == stop_after }
    raise "Audiobookshelf interruption target is unavailable: #{stop_after}" unless index

    selected.insert(index + 1, interruption)
  elsif stop_before
    index = selected.index { |task| task["name"] == stop_before }
    raise "Audiobookshelf interruption target is unavailable: #{stop_before}" unless index

    selected.insert(index, interruption)
  end
  selected
end

def send_json(client, status, body)
  payload = JSON.generate(body)
  client.write(
    "HTTP/1.1 #{status} Fixture\r\nContent-Type: application/json\r\n" \
    "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}"
  )
end

def exact_library(folder_paths: ["/audiobooks"], last_scan: nil)
  {
    "id" => LIBRARY_ID,
    "name" => LIBRARY_NAME,
    "folders" => folder_paths.map { |path| { "fullPath" => path } },
    "mediaType" => DEFAULTS.fetch("audiobookshelf_library_media_type"),
    "provider" => DEFAULTS.fetch("audiobookshelf_library_provider"),
    "icon" => DEFAULTS.fetch("audiobookshelf_library_icon"),
    "settings" => DEFAULTS.fetch("audiobookshelf_library_settings"),
    "lastScan" => last_scan
  }
end

class ScanFixture
  attr_accessor :advance_last_scan, :tasks_shape, :items_shape
  attr_reader :port, :create_requests, :patch_requests, :scan_requests, :library

  def initialize(advance_last_scan:, library: exact_library, tasks_shape: [], items_shape: [])
    @advance_last_scan = advance_last_scan
    @library = library
    @tasks_shape = tasks_shape
    @items_shape = items_shape
    @create_requests = 0
    @patch_requests = 0
    @scan_requests = 0
    @pending_scan = false
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr.fetch(1)
    @shutdown_reader, @shutdown_writer = IO.pipe
    @error = nil
    @thread = Thread.new { serve }
    @thread.report_on_exception = false
  end

  def close
    @shutdown_writer.write("x")
  rescue IOError, Errno::EPIPE
    nil
  ensure
    @shutdown_writer.close unless @shutdown_writer.closed?
    @server.close unless @server.closed?
    @thread.join(2)
    @thread.kill if @thread.alive?
    @thread.join(1)
    @shutdown_reader.close unless @shutdown_reader.closed?
    raise @error if @error
  end

  private

  def serve
    loop do
      ready = IO.select([@server, @shutdown_reader], nil, nil, 0.05)
      next unless ready
      break if ready.first.include?(@shutdown_reader)

      client = @server.accept
      begin
        method, target, = client.gets.to_s.strip.split(" ", 3)
        headers = {}
        while (line = client.gets)
          line = line.chomp
          break if line == "\r" || line.empty?

          key, value = line.split(":", 2)
          headers[key.downcase] = value.to_s.strip
        end
        body = client.read(headers.fetch("content-length", "0").to_i)
        respond(client, method, target, body)
      ensure
        client.close unless client.closed?
      end
    end
  rescue IOError, Errno::EBADF
    nil
  rescue StandardError => error
    @error = error
  end

  def respond(client, method, target, body)
    case [method, target]
    when ["POST", "/api/libraries"]
      @create_requests += 1
      @library = library_from_payload(JSON.parse(body))
      send_json(client, 200, @library)
    when ["PATCH", "/api/libraries/#{LIBRARY_ID}"]
      @patch_requests += 1
      @library = library_from_payload(JSON.parse(body), last_scan: @library["lastScan"])
      send_json(client, 200, @library)
    when ["POST", "/api/libraries/#{LIBRARY_ID}/scan"]
      @scan_requests += 1
      @pending_scan = true
      send_json(client, 200, { "ok" => true })
    when ["GET", "/api/tasks"]
      send_json(client, 200, { "tasks" => @tasks_shape })
    when ["GET", "/api/libraries"]
      if @pending_scan && @advance_last_scan
        @library["lastScan"] = (@library["lastScan"] || 100) + 1
        @pending_scan = false
      end
      send_json(client, 200, { "libraries" => [@library].compact })
    when ["GET", "/api/libraries/#{LIBRARY_ID}/items?limit=1&minified=1"]
      send_json(client, 200, { "results" => @items_shape, "total" => 0 })
    else
      send_json(client, 500, { "error" => "unexpected fixture request" })
    end
  end

  def library_from_payload(payload, last_scan: nil)
    {
      "id" => LIBRARY_ID,
      "name" => payload.fetch("name"),
      "folders" => payload.fetch("folders").map { |folder| { "fullPath" => folder.fetch("path") } },
      "mediaType" => payload.fetch("mediaType"),
      "provider" => payload.fetch("provider"),
      "icon" => payload.fetch("icon"),
      "settings" => payload.fetch("settings"),
      "lastScan" => last_scan
    }
  end
end

def run_scan(fixture, config_root, stop_after: nil, stop_before: nil)
  existing_library = fixture.library || {}
  variables = DEFAULTS.merge(
    "audiobookshelf_api" => "http://127.0.0.1:#{fixture.port}",
    "audiobookshelf_reconcile_token" => "RECONCILE_SECRET_SENTINEL",
    "audiobookshelf_effective_config_host_path" => config_root,
    "audiobookshelf_initialized" => true,
    "audiobookshelf_existing_library" => existing_library,
    "audiobookshelf_existing_library_paths" => existing_library.fetch("folders", []).map do |folder|
      folder.fetch("fullPath")
    end,
    "audiobookshelf_initial_scan_retries" => 2,
    "audiobookshelf_initial_scan_delay" => 0,
    "nas_uid" => Process.uid,
    "nas_gid" => Process.gid
  )
  playbook = [{
    "hosts" => "localhost", "gather_facts" => false,
    "vars" => variables,
    "tasks" => selected_scan_tasks(stop_after: stop_after, stop_before: stop_before)
  }]
  Dir.mktmpdir("audiobookshelf-scan-playbook-") do |directory|
    path = File.join(directory, "playbook.yml")
    File.write(path, YAML.dump(playbook), mode: "w", perm: 0o600)
    Timeout.timeout(30) do
      Open3.capture3(
        { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,", "-c", "local",
        path, chdir: ROOT
      )
    end
  end
end

def changed_count(output)
  match = output.match(/localhost\s+: .*changed=(\d+)/)
  match && Integer(match[1], 10)
end

def failure_tail(output)
  output.lines.map(&:strip).reject(&:empty?).last(10).join(" | ")
end

def pending_state(library_id: LIBRARY_ID, folder_paths: ["/audiobooks"])
  {
    "schema" => 1,
    "state" => "pending",
    "library_name" => LIBRARY_NAME,
    "library_id" => library_id,
    "folder_paths" => folder_paths
  }
end


def precreate_state
  pending_state(library_id: nil)
end

def write_marker(config_root, state)
  marker = File.join(config_root, MARKER_NAME)
  File.write(marker, JSON.generate(state), mode: "w", perm: 0o600)
  marker
end

def pending_marker_failure(config_root)
  marker = File.join(config_root, MARKER_NAME)
  return "pending scan intent is absent" unless File.file?(marker)
  return "pending scan intent differs" unless JSON.parse(File.read(marker)) == pending_state
  return "pending scan intent mode differs" unless (File.stat(marker).mode & 0o777) == 0o600

  nil
end

failures = []

[
  ["normal", ->(root) { root }],
  ["adoption", ->(root) { File.join(root, "legacy", "audiobookshelf", "config") }]
].each do |layout, config_path|
  Dir.mktmpdir("audiobookshelf-markerless-#{layout}-") do |root|
    config_root = config_path.call(root)
    FileUtils.mkdir_p(config_root)
    fixture = ScanFixture.new(advance_last_scan: true)
    begin
      stdout, stderr, status = run_scan(fixture, config_root)
      output = stdout + stderr
      failures << "markerless #{layout} convergence failed: #{failure_tail(output)}" unless status.success?
      failures << "markerless #{layout} convergence scanned" unless fixture.scan_requests.zero?
      failures << "markerless #{layout} convergence changed state" unless changed_count(output) == 0
      failures << "markerless #{layout} convergence wrote intent" if
        File.exist?(File.join(config_root, MARKER_NAME))
    ensure
      fixture.close
    end
  end
end

Dir.mktmpdir("audiobookshelf-folder-repair-") do |config_root|
  fixture = ScanFixture.new(
    advance_last_scan: true, library: exact_library(folder_paths: ["/old-audiobooks"])
  )
  begin
    stdout, stderr, status = run_scan(fixture, config_root)
    output = stdout + stderr
    failures << "folder repair scan failed: #{failure_tail(output)}" unless status.success?
    failures << "folder repair did not POST exactly once" unless fixture.scan_requests == 1
    failures << "folder repair did not clear pending intent" if
      File.exist?(File.join(config_root, MARKER_NAME))
  ensure
    fixture.close
  end
end

Dir.mktmpdir("audiobookshelf-create-interruption-") do |config_root|
  fixture = ScanFixture.new(advance_last_scan: true, library: nil)
  begin
    stdout, stderr, interrupted = run_scan(
      fixture, config_root, stop_after: "Create the managed Audiobookshelf library"
    )
    output = stdout + stderr
    failures << "post-create interruption was accepted" if interrupted.success?
    failures << "post-create interruption did not create exactly once" unless fixture.create_requests == 1
    failures << "post-create interruption mutated after create" unless
      fixture.patch_requests.zero? && fixture.scan_requests.zero?
    marker = File.join(config_root, MARKER_NAME)
    failures << "post-create interruption did not preserve exact pre-create intent" unless
      File.file?(marker) && JSON.parse(File.read(marker)) == precreate_state

    stdout, stderr, resumed = run_scan(fixture, config_root)
    output = stdout + stderr
    failures << "post-create interruption did not resume: #{failure_tail(output)}" unless resumed.success?
    failures << "post-create resume recreated the library" unless fixture.create_requests == 1
    failures << "post-create resume did not scan exactly once" unless fixture.scan_requests == 1
    failures << "post-create resume retained pending intent" if File.exist?(marker)

    stdout, stderr, unchanged = run_scan(fixture, config_root)
    failures << "post-create third convergence failed: #{failure_tail(stdout + stderr)}" unless
      unchanged.success?
    failures << "post-create third convergence changed" unless changed_count(stdout + stderr) == 0
    failures << "post-create third convergence rescanned" unless fixture.scan_requests == 1
  ensure
    fixture.close
  end
end

Dir.mktmpdir("audiobookshelf-repair-interruption-") do |config_root|
  fixture = ScanFixture.new(
    advance_last_scan: true, library: exact_library(folder_paths: ["/old-audiobooks"])
  )
  begin
    stdout, stderr, interrupted = run_scan(
      fixture, config_root, stop_before: "Repair the managed Audiobookshelf library"
    )
    output = stdout + stderr
    failures << "pre-repair interruption was accepted" if interrupted.success?
    failures << "pre-repair interruption mutated the API" unless
      fixture.create_requests.zero? && fixture.patch_requests.zero? && fixture.scan_requests.zero?
    marker = File.join(config_root, MARKER_NAME)
    failures << "pre-repair interruption did not preserve exact ID-bound intent" unless
      File.file?(marker) && JSON.parse(File.read(marker)) == pending_state

    stdout, stderr, resumed = run_scan(fixture, config_root)
    output = stdout + stderr
    failures << "pre-repair interruption did not resume: #{failure_tail(output)}" unless resumed.success?
    failures << "pre-repair resume did not PATCH exactly once" unless fixture.patch_requests == 1
    failures << "pre-repair resume did not scan exactly once" unless fixture.scan_requests == 1
    failures << "pre-repair resume retained pending intent" if File.exist?(marker)

    stdout, stderr, unchanged = run_scan(fixture, config_root)
    failures << "pre-repair third convergence failed: #{failure_tail(stdout + stderr)}" unless
      unchanged.success?
    failures << "pre-repair third convergence changed" unless changed_count(stdout + stderr) == 0
    failures << "pre-repair third convergence rescanned" unless fixture.scan_requests == 1
  ensure
    fixture.close
  end
end

Dir.mktmpdir("audiobookshelf-stale-repair-intent-") do |config_root|
  stale = pending_state(library_id: "stale-library", folder_paths: ["/#{MEDIA_SENTINEL}"])
  marker = write_marker(config_root, stale)
  fixture = ScanFixture.new(
    advance_last_scan: true, library: exact_library(folder_paths: ["/old-audiobooks"])
  )
  begin
    stdout, stderr, status = run_scan(fixture, config_root)
    output = stdout + stderr
    failures << "stale marker with folder drift was accepted" if status.success?
    failures << "stale marker with folder drift mutated the API" unless
      fixture.create_requests.zero? && fixture.patch_requests.zero? && fixture.scan_requests.zero?
    failures << "stale marker with folder drift leaked protected data" if output.include?(MEDIA_SENTINEL)
    failures << "stale marker with folder drift was mutated" unless
      File.file?(marker) && JSON.parse(File.read(marker)) == stale
  ensure
    fixture.close
  end
end

Dir.mktmpdir("audiobookshelf-unsupported-repair-intent-") do |config_root|
  marker = write_marker(config_root, {})
  fixture = ScanFixture.new(
    advance_last_scan: true, library: exact_library(folder_paths: ["/old-audiobooks"])
  )
  begin
    stdout, stderr, status = run_scan(fixture, config_root)
    output = stdout + stderr
    failures << "empty-object marker with folder drift was accepted" if status.success?
    failures << "empty-object marker with folder drift mutated the API" unless
      fixture.create_requests.zero? && fixture.patch_requests.zero? && fixture.scan_requests.zero?
    failures << "empty-object marker with folder drift was mutated" unless
      File.file?(marker) && JSON.parse(File.read(marker)) == {}
  ensure
    fixture.close
  end
end

Dir.mktmpdir("audiobookshelf-scan-state-") do |config_root|
  fixture = ScanFixture.new(advance_last_scan: false, library: nil)
  begin
    stdout, stderr, status = run_scan(fixture, config_root)
    output = stdout + stderr
    failures << "disappeared failed scan was accepted" if status.success?
    failures << "failed scan did not POST exactly once" unless fixture.scan_requests == 1
    failures << "failed scan leaked protected data" if output.include?(MEDIA_SENTINEL) ||
                                                       output.include?("RECONCILE_SECRET_SENTINEL")
    marker = File.join(config_root, MARKER_NAME)
    if (failure = pending_marker_failure(config_root))
      failures << "failed scan #{failure}"
    end

    fixture.advance_last_scan = true
    stdout, stderr, retry_status = run_scan(fixture, config_root)
    failures << "partial convergence did not retry successfully: #{failure_tail(stdout + stderr)}" unless
      retry_status.success?
    failures << "partial convergence did not POST a second scan" unless fixture.scan_requests == 2
    failures << "successful empty-source scan did not clear pending intent" if File.exist?(marker)

    stdout, stderr, third_status = run_scan(fixture, config_root)
    failures << "unchanged third convergence failed: #{failure_tail(stdout + stderr)}" unless
      third_status.success?
    failures << "unchanged third convergence rescanned" unless fixture.scan_requests == 2
    failures << "unchanged third convergence was not idempotent" unless
      changed_count(stdout + stderr) == 0
  ensure
    fixture.close
  end
end

[{ "bad" => "tasks" }, MEDIA_SENTINEL].each do |tasks_shape|
  Dir.mktmpdir("audiobookshelf-task-shape-") do |config_root|
    fixture = ScanFixture.new(advance_last_scan: true, library: nil, tasks_shape: tasks_shape)
    begin
      stdout, stderr, status = run_scan(fixture, config_root)
      output = stdout + stderr
      failures << "malformed tasks shape was accepted" if status.success?
      failures << "malformed tasks shape leaked media data" if output.include?(MEDIA_SENTINEL)
      if (failure = pending_marker_failure(config_root))
        failures << "malformed tasks shape #{failure}"
      end
    ensure
      fixture.close
    end
  end
end

[{ "bad" => "items" }, MEDIA_SENTINEL].each do |items_shape|
  Dir.mktmpdir("audiobookshelf-item-shape-") do |config_root|
    fixture = ScanFixture.new(advance_last_scan: true, library: nil, items_shape: items_shape)
    begin
      stdout, stderr, status = run_scan(fixture, config_root)
      output = stdout + stderr
      failures << "malformed items shape was accepted" if status.success?
      failures << "malformed items shape leaked media data" if output.include?(MEDIA_SENTINEL)
      if (failure = pending_marker_failure(config_root))
        failures << "malformed items shape #{failure}"
      end
    ensure
      fixture.close
    end
  end
end

{
  "mismatched pending" => pending_state(
    library_id: "stale-library", folder_paths: ["/#{MEDIA_SENTINEL}"]
  ),
  "completed" => pending_state.merge("state" => "completed")
}.each do |kind, state|
  Dir.mktmpdir("audiobookshelf-stale-intent-") do |config_root|
    marker = write_marker(config_root, state)
    fixture = ScanFixture.new(advance_last_scan: true)
    begin
      stdout, stderr, status = run_scan(fixture, config_root)
      output = stdout + stderr
      failures << "#{kind} intent was accepted" if status.success?
      failures << "#{kind} intent triggered a scan" unless fixture.scan_requests.zero?
      failures << "#{kind} intent leaked protected data" if output.include?(MEDIA_SENTINEL)
      failures << "#{kind} intent was mutated" unless
        File.file?(marker) && JSON.parse(File.read(marker)) == state
    ensure
      fixture.close
    end
  end
end

if failures.empty?
  puts "Audiobookshelf initial scan behavior tests passed"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Audiobookshelf initial scan behavior failure(s)"
end
