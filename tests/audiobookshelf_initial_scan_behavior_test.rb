#!/usr/bin/env ruby
# frozen_string_literal: true

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
MEDIA_SENTINEL = "MEDIA_SECRET_SENTINEL"

def selected_scan_tasks
  return YAML.safe_load_file(SCAN_TASKS, aliases: false) if File.file?(SCAN_TASKS)

  tasks = YAML.safe_load_file(MAIN_TASKS, aliases: false)
  first = tasks.index do |task|
    task["name"] == "Resolve Audiobookshelf initial scan marker path and desired state"
  end
  last = tasks.index { |task| task["name"] == "Record durable Audiobookshelf initial scan state" }
  first ||= tasks.index { |task| task["name"] == "Report planned Audiobookshelf initial scan" }
  last ||= tasks.index { |task| task["name"] == "Require completed Audiobookshelf initial library scan" }
  raise "Audiobookshelf initial scan task slice is unavailable" unless first && last && first <= last

  return tasks[first..last] if tasks[first]["name"].include?("marker path")

  [{
    "name" => "Resolve fixture Audiobookshelf initial scan requirement",
    "ansible.builtin.set_fact" => {
      "audiobookshelf_initial_scan_required" => "{{ audiobookshelf_library_create_required | bool or audiobookshelf_library_folder_repair_required | bool }}"
    }
  }, *tasks[first..last]]
end

def send_json(client, status, body)
  payload = JSON.generate(body)
  client.write(
    "HTTP/1.1 #{status} Fixture\r\nContent-Type: application/json\r\n" \
    "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}"
  )
end

class ScanFixture
  attr_accessor :advance_last_scan, :tasks_shape, :items_shape
  attr_reader :port, :scan_requests, :last_scan

  def initialize(advance_last_scan:, tasks_shape: [], items_shape: [])
    @advance_last_scan = advance_last_scan
    @tasks_shape = tasks_shape
    @items_shape = items_shape
    @scan_requests = 0
    @last_scan = nil
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
        client.read(headers.fetch("content-length", "0").to_i)
        respond(client, method, target)
      ensure
        client.close unless client.closed?
      end
    end
  rescue IOError, Errno::EBADF
    nil
  rescue StandardError => error
    @error = error
  end

  def respond(client, method, target)
    case [method, target]
    when ["POST", "/api/libraries/#{LIBRARY_ID}/scan"]
      @scan_requests += 1
      @pending_scan = true
      send_json(client, 200, { "ok" => true })
    when ["GET", "/api/tasks"]
      send_json(client, 200, { "tasks" => @tasks_shape })
    when ["GET", "/api/libraries"]
      if @pending_scan && @advance_last_scan
        @last_scan = (@last_scan || 100) + 1
        @pending_scan = false
      end
      send_json(client, 200, { "libraries" => [{ "id" => LIBRARY_ID, "lastScan" => @last_scan }] })
    when ["GET", "/api/libraries/#{LIBRARY_ID}/items?limit=1&minified=1"]
      send_json(client, 200, { "results" => @items_shape, "total" => 0 })
    else
      send_json(client, 500, { "error" => "unexpected fixture request" })
    end
  end
end

def run_scan(fixture, config_root, create_required:)
  variables = DEFAULTS.merge(
    "audiobookshelf_api" => "http://127.0.0.1:#{fixture.port}",
    "audiobookshelf_reconcile_token" => "RECONCILE_SECRET_SENTINEL",
    "audiobookshelf_effective_config_host_path" => config_root,
    "audiobookshelf_current_library" => { "id" => LIBRARY_ID, "lastScan" => fixture.last_scan },
    "audiobookshelf_existing_library_paths" => ["/audiobooks"],
    "audiobookshelf_library_create_required" => create_required,
    "audiobookshelf_library_folder_repair_required" => false,
    "audiobookshelf_initial_scan_retries" => 2,
    "audiobookshelf_initial_scan_delay" => 0,
    "nas_uid" => Process.uid,
    "nas_gid" => Process.gid
  )
  playbook = [{
    "hosts" => "localhost", "gather_facts" => false,
    "vars" => variables, "tasks" => selected_scan_tasks
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

failures = []

Dir.mktmpdir("audiobookshelf-scan-state-") do |config_root|
  fixture = ScanFixture.new(advance_last_scan: false)
  begin
    stdout, stderr, status = run_scan(fixture, config_root, create_required: true)
    output = stdout + stderr
    failures << "disappeared failed scan was accepted" if status.success?
    failures << "failed scan did not POST exactly once" unless fixture.scan_requests == 1
    failures << "failed scan leaked protected data" if output.include?(MEDIA_SENTINEL) ||
                                                       output.include?("RECONCILE_SECRET_SENTINEL")
    marker = File.join(config_root, MARKER_NAME)
    failures << "failed scan wrote durable success state" if File.exist?(marker)

    fixture.advance_last_scan = true
    stdout, stderr, retry_status = run_scan(fixture, config_root, create_required: false)
    failures << "partial convergence did not retry successfully: #{failure_tail(stdout + stderr)}" unless
      retry_status.success?
    failures << "partial convergence did not POST a second scan" unless fixture.scan_requests == 2
    failures << "successful empty-source scan did not write durable state" unless File.file?(marker)
    if File.file?(marker)
      marker_state = JSON.parse(File.read(marker))
      failures << "durable scan state differs" unless marker_state == {
        "schema" => 1, "library_id" => LIBRARY_ID, "folder_paths" => ["/audiobooks"]
      }
      failures << "durable scan state mode differs" unless (File.stat(marker).mode & 0o777) == 0o600
    end

    stdout, stderr, third_status = run_scan(fixture, config_root, create_required: false)
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
    fixture = ScanFixture.new(advance_last_scan: true, tasks_shape: tasks_shape)
    begin
      stdout, stderr, status = run_scan(fixture, config_root, create_required: true)
      output = stdout + stderr
      failures << "malformed tasks shape was accepted" if status.success?
      failures << "malformed tasks shape leaked media data" if output.include?(MEDIA_SENTINEL)
      failures << "malformed tasks shape wrote durable state" if
        File.exist?(File.join(config_root, MARKER_NAME))
    ensure
      fixture.close
    end
  end
end

[{ "bad" => "items" }, MEDIA_SENTINEL].each do |items_shape|
  Dir.mktmpdir("audiobookshelf-item-shape-") do |config_root|
    fixture = ScanFixture.new(advance_last_scan: true, items_shape: items_shape)
    begin
      stdout, stderr, status = run_scan(fixture, config_root, create_required: true)
      output = stdout + stderr
      failures << "malformed items shape was accepted" if status.success?
      failures << "malformed items shape leaked media data" if output.include?(MEDIA_SENTINEL)
      failures << "malformed items shape wrote durable state" if
        File.exist?(File.join(config_root, MARKER_NAME))
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
