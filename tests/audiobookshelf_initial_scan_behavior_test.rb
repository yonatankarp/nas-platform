#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "timeout"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

MAIN_TASKS = File.join(ROOT, "roles", "audiobookshelf", "tasks", "main.yml")
SCAN_TASKS = File.join(ROOT, "roles", "audiobookshelf", "tasks", "initial_scan.yml")
DEFAULTS = YAML.safe_load_file(
  File.join(ROOT, "roles", "audiobookshelf", "defaults", "main.yml"), aliases: false
)
MARKER_NAME = ".nas-platform-initial-scan.json"
LIBRARY_ID = "managed-library"
LIBRARY_NAME = DEFAULTS.fetch("audiobookshelf_library_name")
MEDIA_SENTINEL = "MEDIA_SECRET_SENTINEL"

# The crash-resumable unit this file drives: the role's initial-scan stage, whole.
# The stage has its own file, so it is read as one; a role that still carries the
# stage inline is read as the slice between its first and last task, which is the
# same list.
def scan_task_slice
  return YAML.safe_load_file(SCAN_TASKS, aliases: false) if File.file?(SCAN_TASKS)

  tasks = YAML.safe_load_file(MAIN_TASKS, aliases: false)
  first = tasks.index { |task| task["name"] == "Resolve Audiobookshelf library repair requirement" }
  last = tasks.index { |task| task["name"] == "Clear completed Audiobookshelf initial scan intent" }
  raise "Audiobookshelf initial scan task slice is unavailable" unless first && last && first <= last

  tasks[first..last]
end

# Which task to interrupt at. Reading the slice and inserting the interruption
# were one method, and its early return for the stage file happened before the
# insertion -- so the day roles/audiobookshelf/tasks/initial_scan.yml existed,
# every scenario below ran to completion uninterrupted and the twelve
# crash-resume properties reported failures against a run that never crashed.
# They are two methods now so that neither path can skip the other.
def selected_scan_tasks(stop_after: nil, stop_before: nil)
  selected = scan_task_slice
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
  attr_accessor :advance_last_scan, :items_shape, :libraries_shape, :marker_path, :tasks_shape
  attr_reader :create_requests, :events, :library, :marker_pending_at_requested_completion,
              :marker_pending_at_scan_request, :noop_scan_requests, :patch_requests, :port,
              :scan_requests

  def initialize(
    advance_last_scan:, library: exact_library, tasks_shape: nil, items_shape: [],
    libraries_shape: nil, scan_race: false
  )
    @advance_last_scan = advance_last_scan
    @library = library
    @tasks_shape = tasks_shape
    @items_shape = items_shape
    @libraries_shape = libraries_shape
    @scan_race = scan_race
    @create_requests = 0
    @patch_requests = 0
    @scan_requests = 0
    @noop_scan_requests = 0
    @pending_scan = false
    @active_scan = scan_race ? :old : nil
    @active_scan_poll_count = 0
    @events = []
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
      @events << :patch_while_scan_active if @active_scan
      @events << :patch
      start_active_scan(:intervening) if @scan_race && !@active_scan
      send_json(client, 200, @library)
    when ["POST", "/api/libraries/#{LIBRARY_ID}/scan"]
      @scan_requests += 1
      @marker_pending_at_scan_request = pending_marker?
      @events << :scan_post
      if @active_scan
        @noop_scan_requests += 1
        @events << :noop_scan_post
      elsif @scan_race
        start_active_scan(:requested)
      else
        @pending_scan = true
      end
      send_json(client, 200, { "ok" => true })
    when ["GET", "/api/tasks"]
      send_json(client, 200, { "tasks" => tasks_response })
    when ["GET", "/api/libraries"]
      @events << (@scan_requests.zero? ? :baseline_read : :verification_read)
      if !@libraries_shape.nil?
        send_json(client, 200, { "libraries" => @libraries_shape })
        return
      end
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

  def tasks_response
    return @tasks_shape unless @tasks_shape.nil?
    return [] unless @active_scan

    @active_scan_poll_count += 1
    return [active_scan_task] if @active_scan_poll_count == 1

    complete_active_scan
    []
  end

  def active_scan_task
    {
      "action" => "library-scan",
      "isFinished" => false,
      "data" => { "libraryId" => LIBRARY_ID }
    }
  end

  def start_active_scan(kind)
    @active_scan = kind
    @active_scan_poll_count = 0
  end

  def complete_active_scan
    kind = @active_scan
    if kind != :requested || @advance_last_scan
      @library["lastScan"] = (@library["lastScan"] || 100) + 1
    end
    @events << :old_scan_complete if kind == :old
    @events << :intervening_scan_complete if kind == :intervening
    if kind == :requested
      @marker_pending_at_requested_completion = pending_marker?
      @events << :requested_scan_complete
    end
    @active_scan = nil
    @active_scan_poll_count = 0
  end

  def pending_marker?
    return false unless @marker_path && File.file?(@marker_path)

    JSON.parse(File.read(@marker_path)).fetch("state", nil) == "pending"
  rescue JSON::ParserError
    false
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

def run_scan(
  fixture, config_root, stop_after: nil, stop_before: nil, platform_kind: "nas",
  manage_linux_ownership: false, nas_uid: Process.uid, nas_gid: Process.gid
)
  fixture.marker_path = File.join(config_root, MARKER_NAME)
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
    "platform_kind" => platform_kind,
    "platform_manage_linux_ownership" => manage_linux_ownership,
    "nas_uid" => nas_uid,
    "nas_gid" => nas_gid
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

Dir.mktmpdir("audiobookshelf-native-mac-marker-") do |config_root|
  fixture = ScanFixture.new(advance_last_scan: true, library: nil)
  begin
    _stdout, _stderr, interrupted = run_scan(
      fixture, config_root,
      stop_after: "Bind Audiobookshelf initial scan intent to current library",
      platform_kind: "mac", manage_linux_ownership: false, nas_uid: 1000, nas_gid: 100
    )
    marker = File.join(config_root, MARKER_NAME)
    failures << "native Mac marker fixture was not interrupted" if interrupted.success?
    failures << "native Mac marker fixture did not create exactly once" unless fixture.create_requests == 1
    failures << "native Mac marker fixture scanned before resume" unless fixture.scan_requests.zero?
    failures << "native Mac marker was not created" unless File.file?(marker)
    if File.file?(marker)
      failures << "native Mac marker did not preserve host UID" unless File.stat(marker).uid == Process.uid
      failures << "native Mac marker did not preserve host GID" unless File.stat(marker).gid == Process.gid
      failures << "native Mac marker mode differs" unless (File.stat(marker).mode & 0o777) == 0o600
    end

    stdout, stderr, resumed = run_scan(
      fixture, config_root,
      platform_kind: "mac", manage_linux_ownership: false, nas_uid: 1000, nas_gid: 100
    )
    failures << "native Mac host-owned marker did not resume: #{failure_tail(stdout + stderr)}" unless
      resumed.success?
    failures << "native Mac marker resume recreated the library" unless fixture.create_requests == 1
    failures << "native Mac marker resume did not scan exactly once" unless fixture.scan_requests == 1
    failures << "native Mac marker resume retained pending intent" if File.exist?(marker)
  ensure
    fixture.close
  end
end

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

Dir.mktmpdir("audiobookshelf-overlapping-scan-") do |config_root|
  fixture = ScanFixture.new(
    advance_last_scan: true,
    library: exact_library(folder_paths: ["/old-audiobooks"], last_scan: 100),
    scan_race: true
  )
  begin
    stdout, stderr, status = run_scan(fixture, config_root)
    output = stdout + stderr
    expected_events = [
      :old_scan_complete,
      :patch,
      :intervening_scan_complete,
      :baseline_read,
      :scan_post,
      :requested_scan_complete,
      :verification_read
    ]
    failures << "overlapping scan reconciliation failed: #{failure_tail(output)}" unless status.success?
    failures << "overlapping scan ordering differs: #{fixture.events.inspect}" unless
      fixture.events == expected_events
    failures << "overlapping scan caused a no-op POST" unless fixture.noop_scan_requests.zero?
    failures << "overlapping scan did not POST exactly once" unless fixture.scan_requests == 1
    failures << "scan intent was absent at requested scan POST" unless
      fixture.marker_pending_at_scan_request
    failures << "scan intent cleared before requested scan completion" unless
      fixture.marker_pending_at_requested_completion
    failures << "requested repaired-binding scan did not advance beyond fresh baseline" unless
      fixture.library["lastScan"] == 103
    failures << "successful overlapping scan retained pending intent" if
      File.exist?(File.join(config_root, MARKER_NAME))
  ensure
    fixture.close
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

Dir.mktmpdir("audiobookshelf-post-repair-interruption-") do |config_root|
  fixture = ScanFixture.new(
    advance_last_scan: true, library: exact_library(folder_paths: ["/old-audiobooks"])
  )
  begin
    stdout, stderr, interrupted = run_scan(
      fixture, config_root, stop_after: "Repair the managed Audiobookshelf library"
    )
    output = stdout + stderr
    failures << "post-repair interruption was accepted" if interrupted.success?
    failures << "post-repair interruption did not PATCH exactly once" unless fixture.patch_requests == 1
    failures << "post-repair interruption scanned" unless fixture.scan_requests.zero?
    marker = File.join(config_root, MARKER_NAME)
    failures << "post-repair interruption did not retain ID-bound intent" unless
      File.file?(marker) && JSON.parse(File.read(marker)) == pending_state

    stdout, stderr, resumed = run_scan(fixture, config_root)
    output = stdout + stderr
    failures << "post-repair interruption did not resume: #{failure_tail(output)}" unless resumed.success?
    failures << "post-repair resume repeated PATCH" unless fixture.patch_requests == 1
    failures << "post-repair resume did not scan exactly once" unless fixture.scan_requests == 1
    failures << "post-repair resume retained pending intent" if File.exist?(marker)
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

[{ "bad" => "libraries" }, MEDIA_SENTINEL].each do |libraries_shape|
  Dir.mktmpdir("audiobookshelf-library-shape-") do |config_root|
    write_marker(config_root, pending_state)
    fixture = ScanFixture.new(
      advance_last_scan: true,
      library: exact_library(last_scan: 100),
      libraries_shape: libraries_shape
    )
    begin
      stdout, stderr, status = run_scan(fixture, config_root)
      output = stdout + stderr
      failures << "malformed libraries shape was accepted" if status.success?
      failures << "malformed libraries shape reached scan POST" unless fixture.scan_requests.zero?
      failures << "malformed libraries shape leaked media data" if output.include?(MEDIA_SENTINEL)
      if (failure = pending_marker_failure(config_root))
        failures << "malformed libraries shape #{failure}"
      end
    ensure
      fixture.close
    end
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

report(failures, "Audiobookshelf initial scan behavior tests passed",
       "Audiobookshelf initial scan behavior failure(s)")
