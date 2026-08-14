#!/usr/bin/env ruby
# Focused behavioral regressions for the rerunnable Jellyfin transcode proof.

require "fileutils"
require "json"
require "socket"
require "tmpdir"
require "uri"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "jellyfin.sh")
VALIDATE_POLICY = File.join(ROOT, "tests", "validate-policy.sh")
SECRET = "JELLYFIN-TRANSCODE-SECRET-DO-NOT-LEAK"
Response = Struct.new(:code, :body)
ContractFailure = Class.new(StandardError)

failures = []

def check(failures, condition, message)
  failures << message unless condition
end

def query_for(target)
  URI.decode_www_form(URI(target).query.to_s).to_h
end

class TranscodeScenario
  attr_reader :master_targets, :segment_cache_keys, :session_poll_while_active,
              :stale_cache_hit, :missing_deadline_paths, :attempt_deadlines,
              :deadline_mismatch

  def initialize(mode, transcode_root:)
    @mode = mode
    @transcode_root = transcode_root
    @master_targets = []
    @segment_cache_keys = []
    @mutex = Mutex.new
    @condition = ConditionVariable.new
    @segment_active = false
    @session_poll_while_active = false
    @stale_cache_hit = false
    @cached_segments = {}
    @missing_deadline_paths = []
    @attempt_deadlines = []
    @deadline_mismatch = false
  end

  def request(_method, path, **options)
    if path == "/Sessions/Capabilities" || path.include?("m3u8") || path.include?("hls1/") ||
       path.start_with?("/Sessions?")
      @missing_deadline_paths << path unless options[:deadline]
      if path == "/Sessions/Capabilities"
        @current_deadline = options[:deadline]
        @attempt_deadlines << @current_deadline if @current_deadline
      elsif options[:deadline] && options[:deadline] != @current_deadline
        @deadline_mismatch = true
      end
    end
    case path
    when "/Sessions/Capabilities"
      Response.new("204", "")
    when %r{/master\.m3u8\?}
      @master_targets << path
      @current_identity = proof_identity(path)
      @mutex.synchronize { @session_poll_while_active = false }
      Response.new("200", "#EXTM3U\nmain.m3u8?#{URI.encode_www_form(@current_identity)}\n")
    when %r{/main\.m3u8\?}
      require_current_identity(path)
      Response.new("200", "#EXTM3U\nhls1/proof/0.ts?#{URI.encode_www_form(@current_identity)}\n")
    when %r{/hls1/}
      require_current_identity(path)
      cache_segment
      segment_response
    when %r{\A/Sessions(?:\?|\z)}
      sessions_response(path)
    else
      raise ContractFailure, "unexpected request path"
    end
  end

  private

  def proof_identity(path)
    query = query_for(path)
    { "deviceId" => query["deviceId"], "playSessionId" => query["playSessionId"] }
  end

  def require_current_identity(path)
    raise ContractFailure, "playlist dropped or changed the proof identity" unless
      proof_identity(path) == @current_identity
  end

  def cache_segment
    key = @current_identity.values
    @segment_cache_keys << key
    return if @mode == :stale_cache_only

    if @cached_segments.key?(key)
      @stale_cache_hit = true
      return
    end

    @cached_segments[key] = true
    cache_name = "proof-#{Digest::SHA256.hexdigest(key.join("\0"))}.ts"
    File.binwrite(File.join(@transcode_root, cache_name), "\x47mpeg-ts")
  end

  def segment_response
    case @mode
    when :fast_success
      Response.new("200", "\x47mpeg-ts")
    when :success, :ordering, :stale_cache_only
      # The old contract issues this request synchronously and cannot observe a
      # session until after it returns. The fixed contract runs it in a worker.
      return Response.new("200", "\x47mpeg-ts") if Thread.current == Thread.main

      @mutex.synchronize do
        @segment_active = true
        @condition.wait(@mutex, 1) until @session_poll_while_active
        sleep 0.05
        @segment_active = false
      end
      Response.new("200", "\x47mpeg-ts")
    when :failure
      raise ContractFailure, "transcoded segment request failed safely"
    when :timeout
      return Response.new("200", "\x47mpeg-ts") if Thread.current == Thread.main

      @mutex.synchronize { @segment_active = true }
      sleep 5
      Response.new("200", "\x47mpeg-ts")
    else
      raise "unknown transcode scenario"
    end
  end

  def sessions_response(path)
    active = @mutex.synchronize do
      @condition.wait(@mutex, 0.1) unless @segment_active
      if @segment_active
        @session_poll_while_active = true
        @condition.broadcast
      end
      @segment_active
    end
    if @mode == :ordering && !active
      raise ContractFailure, "Sessions was polled only after the segment request completed"
    end
    if @mode == :timeout
      raise ContractFailure, "Sessions was polled after the segment request completed" unless active

      return [Response.new("200", "[]"), []]
    end

    transcode = {
      "IsVideoDirect" => false, "Width" => 32,
      "HardwareAccelerationType" => "none"
    }
    device_id = query_for(path)["deviceId"] || "nas-platform-jellyfin-contract"
    session = { "DeviceId" => device_id, "TranscodingInfo" => transcode }
    [Response.new("200", JSON.generate([session])), [session]]
  end
end

Dir.mktmpdir("nas-platform-jellyfin-transcode-") do |directory|
  transcodes = File.join(directory, "transcodes")
  FileUtils.mkdir_p(transcodes)
  ENV.update(
    "PLATFORM_JELLYFIN_PLATFORM" => "mac",
    "PLATFORM_JELLYFIN_PORT" => "8096",
    "PLATFORM_MEDIA_ROOT" => directory,
    "PLATFORM_DOCKER_ROOT" => directory,
    "PLATFORM_REPORT_ROOT" => directory,
    "PLATFORM_JELLYFIN_CONTAINER" => "jellyfin",
    "PLATFORM_JELLYFIN_AVATAR_PATH" => File.join(directory, "avatar.jpeg"),
    "PLATFORM_JELLYFIN_TRANSCODE_ROOT" => transcodes
  )
  ARGV.replace(["seed"])
  runtime_marker = %q{exec ruby - "$mode" "$@" <<'RUBY'} + "\n"
  runtime = File.read(CONTRACT).split(runtime_marker, 2).fetch(1)
  library = runtime.split(/^vault_yaml, vault_error, vault_status = /, 2).fetch(0)
  eval(library, TOPLEVEL_BINDING, CONTRACT)
  original_request = Object.instance_method(:request)

  Object.send(:define_method, :fail_contract) { |message| raise ContractFailure, message }
  Object.send(:define_method, :request) do |method, path, **options|
    $jellyfin_transcode_scenario.request(method, path, **options)
  end

  identity_scenario = TranscodeScenario.new(:success, transcode_root: transcodes)
  $jellyfin_transcode_scenario = identity_scenario
  2.times { assert_cpu_transcode("#{SECRET}-token", "item", "source") }
  identities = identity_scenario.master_targets.map { |target| query_for(target)["playSessionId"] }
  devices = identity_scenario.master_targets.map { |target| query_for(target)["deviceId"] }
  check(failures, identities.all? { |identity| identity&.match?(/\A[A-Za-z0-9_-]{16,128}\z/) },
        "transcode attempts do not use a safe unique PlaySessionId")
  check(failures, identities.uniq.length == 2,
        "two transcode attempts reused the same cache identity")
  check(failures, devices.all? { |device| device&.match?(/\Anas-platform-jellyfin-proof-[a-f0-9]{32}\z/) },
        "transcode attempts do not use a safe proof-specific DeviceId")
  check(failures, devices.uniq.length == 2,
        "two transcode attempts reused the same session identity")
  check(failures, identity_scenario.segment_cache_keys.uniq.length == 2,
        "the second transcode segment reused the first attempt's cache key")
  check(failures, !identity_scenario.stale_cache_hit,
        "the second transcode segment was served from the first attempt's cache")
  check(failures, Dir.glob(File.join(transcodes, "*.ts")).length == 2,
        "two transcode attempts did not produce distinct cache evidence")
  check(failures, identity_scenario.missing_deadline_paths.empty?,
        "transcode requests do not share one end-to-end proof deadline")
  check(failures,
        identity_scenario.attempt_deadlines.length == 2 && !identity_scenario.deadline_mismatch,
        "transcode requests use different per-request deadlines within an attempt")

  ordering_scenario = TranscodeScenario.new(:ordering, transcode_root: transcodes)
  $jellyfin_transcode_scenario = ordering_scenario
  begin
    assert_cpu_transcode("#{SECRET}-token", "item", "source")
  rescue ContractFailure => error
    failures << "transcode session ordering failed: #{error.message}"
  end
  check(failures, ordering_scenario.session_poll_while_active,
        "the contract did not poll Sessions while the segment request was active")

  # Ruby's Timeout module lazily starts one shared watcher thread. Prime it so
  # leak checks count only per-request workers created by the proof or fixture.
  Timeout.timeout(0.01) { nil }
  baseline_threads = Thread.list.select(&:alive?)
  stale_scenario = TranscodeScenario.new(:stale_cache_only, transcode_root: transcodes)
  $jellyfin_transcode_scenario = stale_scenario
  begin
    assert_cpu_transcode("#{SECRET}-token", "item", "source")
    failures << "pre-existing transcode cache satisfied the current attempt"
  rescue ContractFailure => error
    check(failures, error.message == "no current-attempt transcoded segment reached the cache volume",
          "stale-only transcode cache diagnostic differs")
  end
  check(failures, Thread.list.select(&:alive?) == baseline_threads,
        "the stale-cache rejection leaked a segment worker thread")

  fast_scenario = TranscodeScenario.new(:fast_success, transcode_root: transcodes)
  $jellyfin_transcode_scenario = fast_scenario
  begin
    assert_cpu_transcode("#{SECRET}-token", "item", "source")
    failures << "retained TranscodingInfo was accepted after the segment request completed"
  rescue ContractFailure => error
    check(failures,
          error.message == "transcode session was observed only after the segment request completed",
          "completed-request transcode diagnostic differs")
  end
  check(failures, Thread.list.select(&:alive?) == baseline_threads,
        "the completed-request rejection leaked a segment worker thread")

  failure_scenario = TranscodeScenario.new(:failure, transcode_root: transcodes)
  $jellyfin_transcode_scenario = failure_scenario
  begin
    assert_cpu_transcode("#{SECRET}-token", "item", "source")
    failures << "a failed background segment request was accepted"
  rescue ContractFailure => error
    check(failures, !error.message.include?(SECRET), "segment failure diagnostic leaked the token")
  end
  sleep 0.05
  check(failures, Thread.list.select(&:alive?) == baseline_threads,
        "a failed segment request leaked a worker thread")

  if Object.const_defined?(:TRANSCODE_PROOF_TIMEOUT_SECONDS)
    Object.send(:remove_const, :TRANSCODE_PROOF_TIMEOUT_SECONDS)
    Object.const_set(:TRANSCODE_PROOF_TIMEOUT_SECONDS, 0.1)
  end
  timeout_scenario = TranscodeScenario.new(:timeout, transcode_root: transcodes)
  $jellyfin_transcode_scenario = timeout_scenario
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    assert_cpu_transcode("#{SECRET}-token", "item", "source")
    failures << "a timed-out background segment request was accepted"
  rescue ContractFailure => error
    check(failures, error.message == "transcode proof timed out",
          "transcode timeout diagnostic differs or exposes request details")
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  check(failures, elapsed < 1, "transcode timeout was not bounded in the focused regression")
  sleep 0.05
  check(failures, Thread.list.select(&:alive?) == baseline_threads,
        "a timed-out segment request leaked a worker thread")

  original_base = BASE
  %w[/Videos/item/master.m3u8 /Sessions].each do |path|
    server = TCPServer.new("127.0.0.1", 0)
    server_thread = Thread.new do
      Thread.current.report_on_exception = false
      client = server.accept
      client.gets
      sleep 5
    rescue IOError, Errno::EBADF
      nil
    ensure
      client&.close
    end
    Object.send(:remove_const, :BASE)
    Object.const_set(:BASE, URI("http://127.0.0.1:#{server.addr.fetch(1)}"))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      original_request.bind(self).call(
        "get", path, token: "#{SECRET}-token", raw: true,
        deadline: started + 0.1, timeout_message: "transcode proof timed out"
      )
      failures << "blocked #{path} request exceeded the proof contract without failing"
    rescue ContractFailure => error
      check(failures, error.message == "transcode proof timed out",
            "blocked #{path} request emitted an unsafe or incorrect timeout diagnostic")
    rescue ArgumentError => error
      failures << "blocked #{path} request has no deadline support: #{error.message}"
    ensure
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      check(failures, elapsed < 1, "blocked #{path} request was not bounded by the proof deadline")
      server.close
      server_thread.kill
      server_thread.join
    end
  end
  Object.send(:remove_const, :BASE)
  Object.const_set(:BASE, original_base)
  sleep 0.05
  live_threads = Thread.list.select(&:alive?)
  check(failures, live_threads == baseline_threads,
        "blocked proof requests leaked a server or segment worker thread")
ensure
  $jellyfin_transcode_scenario = nil
end

check(failures,
      File.readlines(VALIDATE_POLICY).include?("ruby tests/jellyfin_transcode_contract_test.rb\n"),
      "Jellyfin transcode regression is not registered in the policy suite")

if failures.empty?
  puts "Jellyfin transcode contract regressions: unique reruns and active observation hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Jellyfin transcode contract regression(s)"
end
