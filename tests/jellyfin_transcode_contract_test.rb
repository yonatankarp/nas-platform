#!/usr/bin/env ruby
# Focused behavioral regressions for Jellyfin runtime proofs.

require "fileutils"
require "json"
require "socket"
require "tmpdir"
require "uri"

require_relative "policy_support"

include TestScaffold

CONTRACT = File.join(ROOT, "tests", "contracts", "jellyfin.sh")
VALIDATE_POLICY = File.join(ROOT, "tests", "validate-policy.sh")
SECRET = "JELLYFIN-TRANSCODE-SECRET-DO-NOT-LEAK"
Response = Struct.new(:code, :body)
ContractFailure = Class.new(StandardError)

# These five bound how long the harness waits before calling something hung.
# They are not performance assertions: every behavioural property below has its
# own check, and the one that matters most -- that a request is cut short by its
# own deadline rather than by the far end finally letting go -- is proven by
# asking the fixture whether it was still holding the connection, not by a
# stopwatch. tests/validate-policy.sh runs its checks concurrently, so on a
# loaded runner work that takes milliseconds unloaded can take orders of
# magnitude longer: a 30-way parallel run failed this file's renamed-library
# poll budget, which passed alone moments later. They are generous enough that
# only a genuine hang trips them, and overridable for anyone who wants them
# strict.
#
# PROOF_DEADLINE  the deadline handed to a request that must be bounded.
# HANG_GUARD      the last-resort ceiling on any of it; only a hang reaches it.
# FIXTURE_HANG    how long a blackhole fixture holds a connection. It must
#                 outlast HANG_GUARD, or an unbounded request would slip under
#                 the guard because the fixture released it first.
PROOF_DEADLINE_SECONDS = Float(ENV.fetch("JELLYFIN_PROOF_DEADLINE", "1"))
HANG_GUARD_SECONDS = Float(ENV.fetch("JELLYFIN_HANG_GUARD", "10"))
FIXTURE_HANG_SECONDS = Float(ENV.fetch("JELLYFIN_FIXTURE_HANG", "30"))
# The renamed-library wait polls in-process. Cases that only have to reach the
# controlled timeout are load-safe at any budget -- a slow runner makes them
# time out sooner, not later -- so they stay small and keep the file quick.
LIBRARY_WAIT_TIMEOUT_SECONDS = Float(ENV.fetch("JELLYFIN_LIBRARY_WAIT_TIMEOUT", "0.05"))
# Cases that must poll more than once before giving up need a budget that
# survives losing the CPU between polls: this is the one that flaked.
LIBRARY_WAIT_POLLED_TIMEOUT_SECONDS =
  Float(ENV.fetch("JELLYFIN_LIBRARY_WAIT_POLLED_TIMEOUT", "1"))
# Cases that return as soon as the fixture yields a complete state pay nothing
# for a patient budget, so they get one.
LIBRARY_WAIT_PATIENT_TIMEOUT_SECONDS =
  Float(ENV.fetch("JELLYFIN_LIBRARY_WAIT_PATIENT_TIMEOUT", "10"))
# How long the proof keeps polling after the segment request returns. Production
# is deliberately generous; the cases that never report a transcode have to
# reach their diagnostic quickly, so they run against a small override. Only the
# no-transcode paths ever consume it, and they fail sooner under load, not later.
OBSERVATION_GRACE_SECONDS = Float(ENV.fetch("JELLYFIN_OBSERVATION_GRACE", "0.05"))

failures = []

# A server that accepts one request and then holds the connection open without
# answering it. `released?` stays false for as long as it is still holding, so a
# request that failed while it reads false was cut short by its own deadline
# rather than by this fixture letting go -- the property under test, stated
# without reference to how many seconds either of them took.
class BlackholeServer
  def initialize(hold: FIXTURE_HANG_SECONDS)
    @server = TCPServer.new("127.0.0.1", 0)
    @released = false
    @thread = Thread.new do
      Thread.current.report_on_exception = false
      client = @server.accept
      client.gets
      sleep hold
      @released = true
    rescue IOError, Errno::EBADF
      nil
    ensure
      client&.close
    end
  end

  def released?
    @released
  end

  def base
    URI("http://127.0.0.1:#{@server.addr.fetch(1)}")
  end

  def close
    @server.close
    @thread.kill
    @thread.join
  end
end

# Waiting for a worker to finish is a thread wake-up, so it is quick -- but on a
# loaded runner "quick" is not "within one fixed sleep", and a leak check that
# slept a guessed interval would report a leak for a thread that was merely
# waiting for a core. Poll for the baseline instead; a genuinely leaked thread
# never returns to it and still trips the guard.
def settle_threads(baseline)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  loop do
    live = Thread.list.select(&:alive?)
    return live if live == baseline
    return live if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= HANG_GUARD_SECONDS

    sleep 0.01
  end
end

def query_for(target)
  URI.decode_www_form(URI(target).query.to_s).to_h
end

class TranscodeScenario
  attr_reader :master_targets, :segment_cache_keys, :session_poll_while_active,
              :stale_cache_hit, :missing_deadline_paths, :attempt_deadlines,
              :deadline_mismatch, :observed_after_completion

  # False for as long as the blocked segment request is still blocked. A proof
  # that gave up while this reads false was bounded by its own deadline, not by
  # the fixture finally answering.
  def segment_released?
    @segment_released
  end

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
    @segment_released = false
    @segment_worker = nil
    @segment_answered = false
    @observed_after_completion = false
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

  # The modes that model an observation landing after the segment request: they
  # answer at once and record the worker, so `await_segment_completion` can hold
  # every later Sessions poll until that worker has actually finished.
  def segment_response
    case @mode
    when :straddle, :no_transcode, :foreign_device
      @mutex.synchronize do
        @segment_worker = Thread.current == Thread.main ? nil : Thread.current
        @segment_answered = true
      end
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
      # Outlasts the hang guard on purpose: a proof that waited for this instead
      # of honouring its own deadline must be caught, not accidentally excused.
      sleep FIXTURE_HANG_SECONDS
      @segment_released = true
      Response.new("200", "\x47mpeg-ts")
    else
      raise "unknown transcode scenario"
    end
  end

  # True only when the segment request has genuinely finished: the contract
  # clears its in-progress flag in an `ensure` before the worker dies, so a dead
  # worker is proof the flag is already false. Bounded by the hang guard, and it
  # reports what it saw rather than assuming -- a wait that ran out must not let
  # the straddle assertion pass on a straddle that never happened.
  def await_segment_completion
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loop do
      answered, worker = @mutex.synchronize { [@segment_answered, @segment_worker] }
      return true if answered && (worker.nil? || !worker.alive?)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= HANG_GUARD_SECONDS

      sleep 0.01
    end
  end

  # A session whose DeviceId is not this attempt's. The proof must ignore it
  # exactly as if no session had been reported at all.
  def foreign_session
    {
      "DeviceId" => "nas-platform-jellyfin-proof-#{"f" * 32}",
      "TranscodingInfo" => {
        "IsVideoDirect" => false, "Width" => 32, "HardwareAccelerationType" => "none"
      }
    }
  end

  def sessions_response(path)
    if %i[straddle no_transcode foreign_device].include?(@mode)
      @observed_after_completion = true if await_segment_completion
      device_id = query_for(path)["deviceId"]
      sessions =
        case @mode
        when :no_transcode then [{ "DeviceId" => device_id }]
        when :foreign_device then [foreign_session]
        else
          [{
            "DeviceId" => device_id,
            "TranscodingInfo" => {
              "IsVideoDirect" => false, "Width" => 32, "HardwareAccelerationType" => "none"
            }
          }]
        end
      return [Response.new("200", JSON.generate(sessions)), sessions]
    end

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

class LibraryWaitScenario
  attr_reader :calls, :deadlines, :responses

  def initialize(responses, delay: 0)
    @responses = responses
    @delay = delay
    @calls = 0
    @deadlines = []
  end

  def libraries(_token, deadline: nil)
    @calls += 1
    @deadlines << deadline
    sleep @delay if @delay.positive?
    @responses.fetch([@calls - 1, @responses.length - 1].min)
  end

  def fail_contract(message)
    raise ContractFailure, message
  end
end

def complete_library(name: "Movies Drifted", path: "/media/Movies", item_id: "a" * 32)
  {
    "Name" => name,
    "CollectionType" => "movies",
    "Locations" => [path],
    "LibraryOptions" => {
      "PathInfos" => [{ "Path" => path }], "EnableRealtimeMonitor" => true
    },
    "ItemId" => item_id
  }
end

def exercise_library_wait(scenario, timeout: LIBRARY_WAIT_TIMEOUT_SECONDS)
  scenario.send(
    :wait_for_complete_library, "token", { "Path" => "/media/Movies" },
    name: "Movies Drifted", timeout: timeout
  )
end

def library_wait_failure(scenario, timeout: LIBRARY_WAIT_TIMEOUT_SECONDS)
  exercise_library_wait(scenario, timeout: timeout)
  nil
rescue ContractFailure => error
  error
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
  Object.send(:remove_const, :LIBRARY_RENAME_POLL_INTERVAL_SECONDS)
  Object.const_set(:LIBRARY_RENAME_POLL_INTERVAL_SECONDS, 0.01)
  grace_overridden = Object.const_defined?(:TRANSCODE_OBSERVATION_GRACE_SECONDS)
  if grace_overridden
    Object.send(:remove_const, :TRANSCODE_OBSERVATION_GRACE_SECONDS)
    Object.const_set(:TRANSCODE_OBSERVATION_GRACE_SECONDS, OBSERVATION_GRACE_SECONDS)
  end
  # Without the override the no-transcode cases would poll to the full proof
  # timeout and assert the wrong diagnostic, inside a concurrent policy run.
  check(failures, grace_overridden,
        "the proof exposes no post-segment observation grace to bound")
  wait_source = library[/^def wait_for_complete_library.*?(?=^def assert_managed_library)/m]
  check(failures, !wait_source.nil?, "renamed-library wait helper cannot be extracted from production")

  check(failures,
        PROOF_DEADLINE_SECONDS < HANG_GUARD_SECONDS &&
          HANG_GUARD_SECONDS < FIXTURE_HANG_SECONDS,
        "the harness bounds are ordered so that an unbounded request could pass")

  immediate_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  immediate = LibraryWaitScenario.new([[complete_library]])
  check(failures,
        exercise_library_wait(
          immediate, timeout: LIBRARY_WAIT_PATIENT_TIMEOUT_SECONDS
        ) == complete_library,
        "complete renamed-library state was not accepted")
  # The deadline is absolute and monotonic: ahead of the clock read that preceded
  # the call, and no further ahead than the budget it was handed. The upper edge
  # is a sanity bound on the arithmetic, not a timing measurement.
  check(failures,
        immediate.deadlines.one? &&
          immediate.deadlines.first.is_a?(Numeric) &&
          immediate.deadlines.first.between?(
            immediate_started,
            immediate_started + LIBRARY_WAIT_PATIENT_TIMEOUT_SECONDS + HANG_GUARD_SECONDS
          ),
        "renamed-library polling did not propagate one monotonic absolute deadline")

  eventually_complete = LibraryWaitScenario.new([
    [],
    [{ "Name" => "Movies Drifted", "Locations" => ["/media/Movies"] }],
    [complete_library]
  ])
  check(failures,
        exercise_library_wait(
          eventually_complete, timeout: LIBRARY_WAIT_PATIENT_TIMEOUT_SECONDS
        ) == complete_library,
        "absent and incomplete renamed-library states were not polled to completion")
  check(failures, eventually_complete.deadlines.uniq.one?,
        "renamed-library polls did not share one absolute deadline")

  incomplete_sibling = {
    "Name" => "Shows", "CollectionType" => "tvshows", "Locations" => ["/media/Series"]
  }
  complete_sibling = complete_library(
    name: "Shows", path: "/media/Series", item_id: "b" * 32
  ).merge("CollectionType" => "tvshows")
  globally_eventual = LibraryWaitScenario.new([
    [complete_library, incomplete_sibling],
    [complete_library, complete_sibling]
  ])
  check(failures,
        exercise_library_wait(
          globally_eventual, timeout: LIBRARY_WAIT_PATIENT_TIMEOUT_SECONDS
        ) == complete_library,
        "a complete renamed target bypassed an incomplete sibling")
  check(failures, globally_eventual.calls == 2,
        "renamed-library polling did not wait for the complete folder array")

  # This one has to poll more than once *and* run out of budget, so it is the
  # only wait here that a runner losing the CPU between polls can break.
  persistent_incomplete = LibraryWaitScenario.new([[complete_library, incomplete_sibling]])
  persistent_error = library_wait_failure(
    persistent_incomplete, timeout: LIBRARY_WAIT_POLLED_TIMEOUT_SECONDS
  )
  check(failures,
        persistent_error&.message == "renamed library did not regain its complete API shape" &&
          persistent_incomplete.calls > 1,
        "a persistently incomplete sibling did not reach the bounded controlled timeout")

  expired = LibraryWaitScenario.new([[complete_library]])
  expired_error = library_wait_failure(expired, timeout: 0)
  check(failures, expired_error&.message == "renamed library did not regain its complete API shape" &&
                  expired.calls.zero?,
        "an expired renamed-library deadline reached the blocking API call")

  # The fixture sleeps past the budget unconditionally, so load can only make
  # this arrive later still: the expected failure is the load-safe direction.
  delayed_complete = LibraryWaitScenario.new(
    [[complete_library]], delay: LIBRARY_WAIT_TIMEOUT_SECONDS * 2
  )
  delayed_error = library_wait_failure(delayed_complete)
  check(failures, delayed_error&.message == "renamed library did not regain its complete API shape",
        "state returned after the deadline bypassed the post-request deadline guard")

  duplicate_error = library_wait_failure(
    LibraryWaitScenario.new([[complete_library, complete_library(item_id: "b" * 32)]])
  )
  check(failures, duplicate_error&.message&.include?("duplicated after rename"),
        "duplicate expected-path libraries did not fail closed")

  mismatch_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  mismatch_error = library_wait_failure(
    LibraryWaitScenario.new([[complete_library(name: "Movies")]])
  )
  mismatch_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - mismatch_started
  check(failures, mismatch_error&.message == "renamed library did not regain its complete API shape",
        "an exact-name mismatch did not reach the controlled timeout")
  # Terminating with the controlled diagnostic above is what proves the wait is
  # bounded; this only catches a wait that never terminates at all.
  check(failures, mismatch_elapsed < HANG_GUARD_SECONDS,
        "exact-name mismatch timeout hung past the guard")

  wrong_path_error = library_wait_failure(
    LibraryWaitScenario.new([[complete_library(path: "/media/Series")]])
  )
  check(failures, wrong_path_error&.message == "renamed library did not regain its complete API shape",
        "a different library path satisfied the renamed-library wait")

  malformed_error = begin
    library_wait_failure(LibraryWaitScenario.new([[{ "Locations" => "/media/Movies" }]]))
  rescue StandardError => error
    error
  end
  check(failures, malformed_error.is_a?(ContractFailure) &&
                  malformed_error.message == "renamed library did not regain its complete API shape",
        "persistently malformed renamed-library schema did not reach the controlled timeout")

  unsafe_id_error = library_wait_failure(
    LibraryWaitScenario.new([[complete_library(item_id: "unsafe/id")]])
  )
  check(failures,
        unsafe_id_error&.message == "renamed library did not regain its complete API shape",
        "a persistently unsafe renamed-library ItemId did not reach the controlled timeout")

  unless wait_source.nil?
    mutation_cases = {
      "duplicate guard" => [
        wait_source.sub(/^\s*fail_contract\("library path .*?duplicated after rename.*\n/, ""),
        LibraryWaitScenario.new([[complete_library, complete_library(item_id: "b" * 32)]])
      ],
      "exact-name guard" => [
        wait_source.sub('folder["Name"] == name && ', ""),
        LibraryWaitScenario.new([[complete_library(name: "Movies")]])
      ],
      "expected-path guard" => [
        wait_source.sub('folder.fetch("Locations").map { |path| normalize_path(path) }.include?(definition.fetch("Path"))', "true"),
        LibraryWaitScenario.new([[complete_library(path: "/media/Series")]])
      ]
    }
    mutation_cases.each do |label, (mutant_source, scenario)|
      check(failures, mutant_source != wait_source,
            "renamed-library #{label} mutation did not alter production source")
      mutant = Class.new(LibraryWaitScenario)
      mutant.class_eval(mutant_source, CONTRACT)
      mutant_scenario = mutant.new(scenario.responses)
      check(failures, library_wait_failure(mutant_scenario).nil?,
            "removing the renamed-library #{label} survived behavioral tests")
    end

    deadline_mutant_source = wait_source.sub(
      "libraries(token, deadline: deadline)", "libraries(token)"
    )
    check(failures, deadline_mutant_source != wait_source,
          "renamed-library deadline-propagation mutation did not alter production source")
    deadline_mutant = Class.new(LibraryWaitScenario)
    deadline_mutant.class_eval(deadline_mutant_source, CONTRACT)
    delayed = deadline_mutant.new(
      [[complete_library]], delay: LIBRARY_WAIT_TIMEOUT_SECONDS * 2
    )
    library_wait_failure(delayed)
    # The mutation's whole effect is at the API boundary: the blocking call is
    # entered with nothing that could cut it short. Observing that is the proof.
    # An elapsed-time check could not distinguish the two, because this fixture
    # sleeps for its full delay either way.
    check(failures, delayed.deadlines == [nil],
          "removing renamed-library deadline propagation survived behavioral tests")

    deadline_guard_source = wait_source.gsub(
      /^\s*fail_contract\("renamed library did not regain its complete API shape"\) if remaining <= 0\n/,
      ""
    )
    check(failures, deadline_guard_source != wait_source,
          "renamed-library deadline-guard mutation did not alter production source")
    deadline_guard_mutant = Class.new(LibraryWaitScenario)
    deadline_guard_mutant.class_eval(deadline_guard_source, CONTRACT)
    late_success = deadline_guard_mutant.new(
      [[complete_library]], delay: LIBRARY_WAIT_TIMEOUT_SECONDS * 2
    )
    check(failures, library_wait_failure(late_success).nil?,
          "removing renamed-library deadline guards survived behavioral tests")
  end

  original_base = BASE
  blackhole = BlackholeServer.new
  Object.send(:remove_const, :BASE)
  Object.const_set(:BASE, blackhole.base)
  stalled_probe = Object.new
  stalled_probe.define_singleton_method(:fail_contract) { |message| raise ContractFailure, message }
  stalled_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stalled_error = begin
    stalled_probe.send(
      :wait_for_complete_library, "token", { "Path" => "/media/Movies" },
      name: "Movies Drifted", timeout: PROOF_DEADLINE_SECONDS
    )
    nil
  rescue ContractFailure => error
    error
  ensure
    stalled_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - stalled_started
    stalled_still_blocked = !blackhole.released?
    blackhole.close
    Object.send(:remove_const, :BASE)
    Object.const_set(:BASE, original_base)
  end
  check(failures, stalled_error&.message == "renamed library did not regain its complete API shape",
        "stalled renamed-library request emitted an uncontrolled timeout diagnostic")
  check(failures, stalled_still_blocked,
        "stalled renamed-library request waited for the server instead of its own deadline")
  check(failures, stalled_elapsed < HANG_GUARD_SECONDS,
        "stalled renamed-library HTTP request hung past the guard")

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
  check(failures, settle_threads(baseline_threads) == baseline_threads,
        "the stale-cache rejection leaked a segment worker thread")

  # The regression this file exists to pin. A poll that straddles the segment
  # request's completion sees a transcode the server really did produce for this
  # attempt; the proof used to call that a failure and turn a correct platform
  # red. The fixture holds every Sessions poll until the segment worker has
  # finished, so the straddle is reproduced on purpose rather than raced into.
  straddle_scenario = TranscodeScenario.new(:straddle, transcode_root: transcodes)
  $jellyfin_transcode_scenario = straddle_scenario
  begin
    assert_cpu_transcode("#{SECRET}-token", "item", "source")
  rescue ContractFailure => error
    failures << "a transcode first observed after the segment completed was rejected: #{error.message}"
  end
  check(failures, straddle_scenario.observed_after_completion,
        "the straddle case did not observe the session after the segment request completed")
  check(failures, settle_threads(baseline_threads) == baseline_threads,
        "the straddled observation leaked a segment worker thread")

  # Relaxing *when* the session may be seen must not relax whether one was seen.
  no_transcode_scenario = TranscodeScenario.new(:no_transcode, transcode_root: transcodes)
  $jellyfin_transcode_scenario = no_transcode_scenario
  begin
    assert_cpu_transcode("#{SECRET}-token", "item", "source")
    failures << "a playback that never reported a transcode was accepted"
  rescue ContractFailure => error
    check(failures, error.message == "no transcode session was reported for this playback",
          "absent-transcode diagnostic differs")
  end
  check(failures, settle_threads(baseline_threads) == baseline_threads,
        "the absent-transcode rejection leaked a segment worker thread")

  # With the timing guard gone, the proof-specific DeviceId is the only thing
  # keeping somebody else's transcode out of this attempt's result.
  foreign_scenario = TranscodeScenario.new(:foreign_device, transcode_root: transcodes)
  $jellyfin_transcode_scenario = foreign_scenario
  begin
    assert_cpu_transcode("#{SECRET}-token", "item", "source")
    failures << "another device's transcode session satisfied this attempt"
  rescue ContractFailure => error
    check(failures, error.message == "no transcode session was reported for this playback",
          "foreign-session diagnostic differs")
  end
  check(failures, settle_threads(baseline_threads) == baseline_threads,
        "the foreign-session rejection leaked a segment worker thread")

  failure_scenario = TranscodeScenario.new(:failure, transcode_root: transcodes)
  $jellyfin_transcode_scenario = failure_scenario
  begin
    assert_cpu_transcode("#{SECRET}-token", "item", "source")
    failures << "a failed background segment request was accepted"
  rescue ContractFailure => error
    check(failures, !error.message.include?(SECRET), "segment failure diagnostic leaked the token")
  end
  check(failures, settle_threads(baseline_threads) == baseline_threads,
        "a failed segment request leaked a worker thread")

  if Object.const_defined?(:TRANSCODE_PROOF_TIMEOUT_SECONDS)
    Object.send(:remove_const, :TRANSCODE_PROOF_TIMEOUT_SECONDS)
    Object.const_set(:TRANSCODE_PROOF_TIMEOUT_SECONDS, PROOF_DEADLINE_SECONDS)
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
  check(failures, !timeout_scenario.segment_released?,
        "the transcode proof waited for its blocked segment instead of its own deadline")
  check(failures, elapsed < HANG_GUARD_SECONDS,
        "the transcode proof hung past the guard in the focused regression")
  check(failures, settle_threads(baseline_threads) == baseline_threads,
        "a timed-out segment request leaked a worker thread")

  original_base = BASE
  %w[/Videos/item/master.m3u8 /Sessions].each do |path|
    blocked = BlackholeServer.new
    Object.send(:remove_const, :BASE)
    Object.const_set(:BASE, blocked.base)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      original_request.bind(self).call(
        "get", path, token: "#{SECRET}-token", raw: true,
        deadline: started + PROOF_DEADLINE_SECONDS,
        timeout_message: "transcode proof timed out"
      )
      failures << "blocked #{path} request exceeded the proof contract without failing"
    rescue ContractFailure => error
      check(failures, error.message == "transcode proof timed out",
            "blocked #{path} request emitted an unsafe or incorrect timeout diagnostic")
    rescue ArgumentError => error
      failures << "blocked #{path} request has no deadline support: #{error.message}"
    ensure
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      check(failures, !blocked.released?,
            "blocked #{path} request waited for the server instead of the proof deadline")
      check(failures, elapsed < HANG_GUARD_SECONDS,
            "blocked #{path} request hung past the guard")
      blocked.close
    end
  end
  Object.send(:remove_const, :BASE)
  Object.const_set(:BASE, original_base)
  check(failures, settle_threads(baseline_threads) == baseline_threads,
        "blocked proof requests leaked a server or segment worker thread")
ensure
  $jellyfin_transcode_scenario = nil
end

check(failures,
      File.readlines(VALIDATE_POLICY).include?("ruby tests/jellyfin_transcode_contract_test.rb\n"),
      "Jellyfin transcode regression is not registered in the policy suite")

report(failures, "Jellyfin transcode contract regressions: unique reruns and bounded observation hold",
       "Jellyfin transcode contract regression(s)")
