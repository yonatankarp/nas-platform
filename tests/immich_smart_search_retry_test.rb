#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require "timeout"
require "uri"

ROOT = File.expand_path("..", __dir__)
# The runtime half of the Immich contract, whose `request` and
# `assert_cpu_machine_learning` this test slices out and evals. It was a
# `<<'RUBY'` heredoc inside tests/contracts/immich.sh until #147 and is a file
# now, which changes nothing here beyond the path: extract_method matches `^def`
# at column zero either way.
CONTRACT = File.join(ROOT, "tests", "contracts", "immich-runtime.rb")
FIXTURE_IDS = %w[photo-fixture video-fixture].freeze
SLEEP_DURATIONS = []

class ContractFailure < StandardError; end
class TestFailure < StandardError; end

def extract_method(source, name, next_name)
  source[/^def #{name}\b.*?(?=^def #{next_name}\b)/m] ||
    raise(TestFailure, "could not extract #{name} from the Immich contract")
end

def fail_contract(message)
  raise ContractFailure, message
end

module Kernel
  def sleep(duration)
    SLEEP_DURATIONS << duration
  end
end

def json_response(status, body)
  [status, JSON.generate(body)]
end

def duplicate_json(value)
  JSON.parse(JSON.generate(value))
end

def complete_response
  json_response(
    200,
    { "assets" => { "items" => FIXTURE_IDS.map { |id| { "id" => id } } } }
  )
end

def idle_smart_search_response(failed: 0)
  smart_search_response(failed: failed)
end

def smart_search_response(is_active: false, is_paused: false, **counts)
  job_counts = {
    "active" => 0, "completed" => 0, "failed" => 0,
    "delayed" => 0, "waiting" => 0, "paused" => 0
  }.merge(counts.transform_keys(&:to_s))
  json_response(
    200,
    {
      "smartSearch" => {
        "queueStatus" => { "isActive" => is_active, "isPaused" => is_paused },
        "jobCounts" => job_counts
      }
    }
  )
end

def requeue_response
  json_response(
    200,
    {
      "queueStatus" => { "isActive" => false, "isPaused" => false },
      "jobCounts" => {
        "active" => 0, "completed" => 0, "failed" => 1,
        "delayed" => 0, "waiting" => 1, "paused" => 0
      }
    }
  )
end

def with_http_responses(responses)
  server = TCPServer.new("127.0.0.1", 0)
  Object.send(:remove_const, :BASE) if Object.const_defined?(:BASE)
  Object.const_set(:BASE, URI("http://127.0.0.1:#{server.local_address.ip_port}"))
  requests = []
  server_thread = Thread.new do
    responses.each do |status, payload|
      begin
        socket = server.accept
      rescue IOError
        break
      end
      request_line = socket.gets
      headers = {}
      while (line = socket.gets)
        break if line == "\r\n"

        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip if value
      end
      body = socket.read(headers.fetch("content-length", "0").to_i)
      method, path, = request_line.split
      requests << { method: method, path: path, headers: headers, body: body }
      socket.write("HTTP/1.1 #{status} Test\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      socket.close
    end
  end

  yield -> { requests.dup }
ensure
  server&.close
  server_thread&.join(1)
end

def with_stalled_http_server
  server = TCPServer.new("127.0.0.1", 0)
  Object.send(:remove_const, :BASE) if Object.const_defined?(:BASE)
  Object.const_set(:BASE, URI("http://127.0.0.1:#{server.local_address.ip_port}"))
  requests = 0
  server_thread = Thread.new do
    socket = server.accept
    requests += 1
    IO.select([socket], nil, nil, 0.5)
    while (line = socket.gets)
      break if line == "\r\n"
    end
    IO.select(nil, nil, nil, 0.5)
  rescue IOError
    nil
  ensure
    socket&.close
  end

  yield -> { requests }
ensure
  server&.close
  server_thread&.join(1)
end

def expect_success(responses, expected_requests:, expected_ids: FIXTURE_IDS, clock: nil)
  with_http_responses(responses) do |requests|
    arguments = clock ? { clock: clock } : {}
    assert_cpu_machine_learning("test-token", expected_ids, **arguments)
    actual_requests = requests.call
    raise TestFailure, "made #{actual_requests.length} requests, expected #{expected_requests}" unless
      actual_requests.length == expected_requests
    yield actual_requests if block_given?
  end
end

def expect_contract_failure(responses, expected_status: nil, expected_requests: 1,
                            expected_ids: FIXTURE_IDS, clock: nil)
  error = nil
  with_http_responses(responses) do |requests|
    begin
      arguments = clock ? { clock: clock } : {}
      assert_cpu_machine_learning("test-token", expected_ids, **arguments)
    rescue ContractFailure => caught
      error = caught
    rescue StandardError => caught
      raise TestFailure, "escaped #{caught.class} instead of failing the contract"
    end
    raise TestFailure, "contract unexpectedly accepted the response" unless error
    if expected_status && !error.message.include?(expected_status.to_s)
      raise TestFailure, "failure omitted HTTP #{expected_status}: #{error.message}"
    end
    actual_requests = requests.call
    raise TestFailure, "made #{actual_requests.length} requests, expected #{expected_requests}" unless
      actual_requests.length == expected_requests
    yield actual_requests if block_given?
  end
  error
end

def monotonic_clock(*times)
  last = times.last
  -> { times.shift || last }
end

def with_captured_sleeps
  SLEEP_DURATIONS.clear
  yield SLEEP_DURATIONS
ensure
  SLEEP_DURATIONS.clear
end

source = File.read(CONTRACT)
eval(extract_method(source, "request", "multipart_body"), binding, CONTRACT)
smart_search_source = extract_method(
  source, "assert_cpu_machine_learning", "assert_originals_open"
)
eval(
  smart_search_source,
  binding,
  CONTRACT
)

failures = []
run = lambda do |label, &test|
  Timeout.timeout(10, TestFailure, "test timed out") { test.call }
rescue TestFailure, ContractFailure => error
  failures << "#{label}: #{error.message}"
end

[500, 502, 503, 504].each do |status|
  run.call("HTTP #{status} retry") do
    expect_success([json_response(status, { "message" => "not ready" }), complete_response],
                   expected_requests: 2)
  end
end

[401, 418, 501].each do |status|
  run.call("HTTP #{status} immediate failure") do
    expect_contract_failure(
      [json_response(status, { "message" => "refused" })], expected_status: status
    )
  end
end

run.call("partial semantic result is requeued") do
  partial = json_response(200, { "assets" => { "items" => [{ "id" => FIXTURE_IDS.first }] } })
  expect_success(
    [partial, idle_smart_search_response(failed: 1), requeue_response, complete_response],
    expected_requests: 4
  ) do |requests|
    raise TestFailure, "partial result did not receive exactly one requeue" unless
      requests.count { |request| request.fetch(:method) == "PUT" } == 1
  end
end

run.call("unrelated semantic result is requeued") do
  unrelated = json_response(
    200, { "assets" => { "items" => [{ "id" => "unrelated-asset" }] } }
  )
  expect_success(
    [unrelated, idle_smart_search_response(failed: 1), requeue_response, complete_response],
    expected_requests: 4
  ) do |requests|
    raise TestFailure, "unrelated result did not receive exactly one requeue" unless
      requests.count { |request| request.fetch(:method) == "PUT" } == 1
  end
end

run.call("missing embeddings are requeued once") do
  empty = json_response(200, { "assets" => { "items" => [] } })
  expect_success(
    [empty, idle_smart_search_response(failed: 1), requeue_response, complete_response],
    expected_requests: 4
  ) do |requests|
    queue_read = requests.fetch(1)
    requeue = requests.fetch(2)
    [queue_read, requeue].each do |request|
      raise TestFailure, "recovery request omitted bearer authentication" unless
        request[:headers].to_h["authorization"] == "Bearer test-token"
    end
    raise TestFailure, "recovery did not use PUT /api/jobs/smartSearch" unless
      requeue.values_at(:method, :path) == ["PUT", "/api/jobs/smartSearch"]
    raise TestFailure, "recovery did not select only missing embeddings" unless
      JSON.parse(requeue.fetch(:body)) == { "command" => "start", "force" => false }
  end
end

run.call("malformed jobs JSON") do
  empty = json_response(200, { "assets" => { "items" => [] } })
  error = expect_contract_failure([empty, [200, "not-json"]], expected_requests: 2)
  raise TestFailure, "malformed jobs JSON failure was not attributed to GET /api/jobs" unless
    error.message.include?("GET /api/jobs returned malformed JSON")
end

valid_queue = JSON.parse(idle_smart_search_response.last)
malformed_job_payloads = {
  "non-mapping jobs root" => [],
  "missing smartSearch queue" => {},
  "non-mapping smartSearch queue" => { "smartSearch" => [] },
  "missing queue status" => {
    "smartSearch" => valid_queue.fetch("smartSearch").reject { |key, _value| key == "queueStatus" }
  },
  "missing job counts" => {
    "smartSearch" => valid_queue.fetch("smartSearch").reject { |key, _value| key == "jobCounts" }
  },
  "non-mapping queue status" => duplicate_json(valid_queue).tap do |payload|
    payload.fetch("smartSearch")["queueStatus"] = []
  end,
  "non-mapping job counts" => duplicate_json(valid_queue).tap do |payload|
    payload.fetch("smartSearch")["jobCounts"] = []
  end,
  "missing active status" => duplicate_json(valid_queue).tap do |payload|
    payload.dig("smartSearch", "queueStatus").delete("isActive")
  end,
  "missing paused status" => duplicate_json(valid_queue).tap do |payload|
    payload.dig("smartSearch", "queueStatus").delete("isPaused")
  end,
  "non-boolean active status" => duplicate_json(valid_queue).tap do |payload|
    payload.dig("smartSearch", "queueStatus")["isActive"] = "false"
  end,
  "non-boolean paused status" => duplicate_json(valid_queue).tap do |payload|
    payload.dig("smartSearch", "queueStatus")["isPaused"] = nil
  end
}
%w[active waiting delayed paused].each do |name|
  malformed_job_payloads["missing #{name} count"] =
    duplicate_json(valid_queue).tap do |payload|
      payload.dig("smartSearch", "jobCounts").delete(name)
    end
  malformed_job_payloads["negative #{name} count"] =
    duplicate_json(valid_queue).tap do |payload|
      payload.dig("smartSearch", "jobCounts")[name] = -1
    end
  malformed_job_payloads["non-integer #{name} count"] =
    duplicate_json(valid_queue).tap do |payload|
      payload.dig("smartSearch", "jobCounts")[name] = "0"
    end
end
malformed_job_payloads.each do |label, payload|
  run.call(label) do
    empty = json_response(200, { "assets" => { "items" => [] } })
    error = expect_contract_failure([empty, json_response(200, payload)], expected_requests: 2)
    raise TestFailure, "malformed jobs schema failure was not fail-closed" unless
      error.message.include?("unsupported smartSearch schema")
  end
end

run.call("paused smart search queue") do
  empty = json_response(200, { "assets" => { "items" => [] } })
  error = expect_contract_failure(
    [empty, smart_search_response(is_paused: true, paused: 1)], expected_requests: 2
  ) do |requests|
    raise TestFailure, "paused queue was mutated" if
      requests.any? { |request| request.fetch(:method) == "PUT" }
  end
  raise TestFailure, "paused queue failure omitted its state" unless
    error.message.include?("smartSearch queue is paused")
end

%w[active waiting delayed paused].each do |count_name|
  run.call("busy #{count_name} queue waits until idle") do
    empty = json_response(200, { "assets" => { "items" => [] } })
    busy = smart_search_response(
      is_active: count_name == "active", **{ count_name.to_sym => 1 }
    )
    expect_success(
      [empty, busy, empty, idle_smart_search_response(failed: 1),
       requeue_response, complete_response],
      expected_requests: 6
    ) do |requests|
      puts_before_idle = requests.first(4).count do |request|
        request.values_at(:method, :path) == ["PUT", "/api/jobs/smartSearch"]
      end
      raise TestFailure, "busy queue was requeued before it became idle" unless puts_before_idle.zero?
      raise TestFailure, "idle queue did not receive exactly one requeue" unless
        requests.count { |request| request.fetch(:method) == "PUT" } == 1
    end
  end
end

run.call("persistently busy queue deadline") do
  epoch = 1_700_000_000.0
  empty = json_response(200, { "assets" => { "items" => [] } })
  clock = monotonic_clock(epoch, epoch, epoch, epoch, epoch, epoch + 601)
  expect_contract_failure(
    [empty, smart_search_response(is_active: true, active: 1)],
    expected_requests: 2, clock: clock
  ) do |requests|
    raise TestFailure, "persistently busy queue was mutated" if
      requests.any? { |request| request.fetch(:method) == "PUT" }
  end
end

run.call("deadline expiry after smart search prevents queue inspection") do
  epoch = 1_700_000_000.0
  empty = json_response(200, { "assets" => { "items" => [] } })
  clock = monotonic_clock(epoch, epoch, epoch + 601)
  expect_contract_failure(
    [empty, idle_smart_search_response(failed: 1), requeue_response],
    expected_requests: 1, clock: clock
  ) do |requests|
    raise TestFailure, "expired search inspected or mutated the queue" unless
      requests.none? { |request| request.fetch(:path).start_with?("/api/jobs") }
  end
end

run.call("deadline expiry during jobs read prevents requeue") do
  epoch = 1_700_000_000.0
  empty = json_response(200, { "assets" => { "items" => [] } })
  clock = monotonic_clock(epoch, epoch, epoch, epoch, epoch + 601)
  expect_contract_failure(
    [empty, idle_smart_search_response(failed: 1), requeue_response],
    expected_requests: 2, clock: clock
  ) do |requests|
    raise TestFailure, "expired jobs read performed a PUT" if
      requests.any? { |request| request.fetch(:method) == "PUT" }
  end
end

run.call("deadline expiry before requeue prevents PUT") do
  epoch = 1_700_000_000.0
  empty = json_response(200, { "assets" => { "items" => [] } })
  clock = monotonic_clock(epoch, epoch, epoch, epoch, epoch, epoch + 601)
  expect_contract_failure(
    [empty, idle_smart_search_response(failed: 1), requeue_response],
    expected_requests: 2, clock: clock
  ) do |requests|
    raise TestFailure, "expired pre-PUT budget performed a PUT" if
      requests.any? { |request| request.fetch(:method) == "PUT" }
  end
end

run.call("deadline expiry during successful requeue fails at the post-PUT checkpoint") do
  raise TestFailure, "post-PUT deadline checkpoint is not immediate" unless
    smart_search_source.match?(
      /timeout: remaining_budget\.call\n\s+\)\n\s+remaining_budget\.call\n\s+recovery_requested = true/
    )

  epoch = 1_700_000_000.0
  empty = json_response(200, { "assets" => { "items" => [] } })
  clock = monotonic_clock(epoch, epoch, epoch, epoch, epoch, epoch, epoch + 601)
  with_captured_sleeps do |sleeps|
    expect_contract_failure(
      [empty, idle_smart_search_response(failed: 1), requeue_response, complete_response],
      expected_requests: 3, clock: clock
    ) do |requests|
      raise TestFailure, "post-PUT expiry request sequence was not bounded" unless
        requests.map { |request| request.fetch(:method) } == %w[POST GET PUT]
      raise TestFailure, "post-PUT expiry requested a sleep" unless sleeps.empty?
    end
  end
end

run.call("near-deadline sleep is capped to the remaining budget") do
  raise TestFailure, "sleep no longer uses the remaining deadline budget" unless
    smart_search_source.include?("sleep [5, remaining_budget.call].min")

  epoch = 1_700_000_000.0
  clock = monotonic_clock(epoch, epoch, epoch + 598, epoch + 598, epoch + 601)
  with_captured_sleeps do |sleeps|
    expect_contract_failure(
      [json_response(503, { "message" => "not ready" })],
      expected_status: 503, expected_requests: 1, clock: clock
    )
    raise TestFailure, "near-deadline contract did not request exactly one sleep" unless
      sleeps.length == 1
    raise TestFailure, "sleep exceeded the remaining deadline budget: #{sleeps.first}" unless
      (sleeps.first - 2.0).abs < 0.001
  end
end

run.call("smart search request timeout is capped to the remaining budget") do
  epoch = 1_700_000_000.0
  clock = monotonic_clock(epoch, epoch + 599.95)
  with_stalled_http_server do |requests|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = begin
      assert_cpu_machine_learning("test-token", FIXTURE_IDS, clock: clock)
      nil
    rescue ContractFailure => caught
      caught
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    raise TestFailure, "stalled request unexpectedly satisfied the contract" unless error
    raise TestFailure, "stalled request did not use the remaining deadline budget" unless
      error.message.match?(%r{POST /api/search/smart failed: (?:Net::ReadTimeout|Timeout::Error)})
    raise TestFailure, "stalled request exceeded its remaining budget" unless elapsed < 0.5
    raise TestFailure, "stalled request was attempted more than once" unless requests.call == 1
  end
end

{ "unexpected jobs status" => 503, "jobs authentication status" => 401 }.each do |label, status|
  run.call(label) do
    empty = json_response(200, { "assets" => { "items" => [] } })
    expect_contract_failure(
      [empty, json_response(status, { "message" => "refused" })],
      expected_status: status, expected_requests: 2
    )
  end
end

{
  "unexpected requeue status" => 409,
  "requeue authentication status" => 403
}.each do |label, status|
  run.call(label) do
    empty = json_response(200, { "assets" => { "items" => [] } })
    expect_contract_failure(
      [empty, idle_smart_search_response(failed: 1),
       json_response(status, { "message" => "refused" })],
      expected_status: status, expected_requests: 3
    )
  end
end

run.call("malformed JSON") do
  expect_contract_failure([[200, "not-json"]])
end

[
  [],
  {},
  { "assets" => {} },
  { "assets" => { "items" => "not-an-array" } },
  { "assets" => { "items" => [nil] } },
  { "assets" => { "items" => [{ "id" => nil }] } }
].each_with_index do |payload, index|
  run.call("malformed semantic payload #{index + 1}") do
    expect_contract_failure([json_response(200, payload)])
  end
end

run.call("persistent transient deadline") do
  epoch = 1_700_000_000.0
  clock = monotonic_clock(epoch, epoch, epoch, epoch, epoch, epoch + 601)
  error = expect_contract_failure(
    [json_response(503, {}), json_response(503, {})],
    expected_status: 503, expected_requests: 2, clock: clock
  )
  raise TestFailure, "deadline failure omitted the semantic result count" unless
    error.message.include?("0 embedded asset(s)")
end

run.call("persistent missing embeddings requeue only once") do
  epoch = 1_700_000_000.0
  empty = json_response(200, { "assets" => { "items" => [] } })
  clock = monotonic_clock(
    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch + 601
  )
  error = expect_contract_failure(
    [empty, idle_smart_search_response(failed: 1), requeue_response, empty],
    expected_requests: 4, clock: clock
  ) do |requests|
    requeues = requests.select do |entry|
      entry.values_at(:method, :path) == ["PUT", "/api/jobs/smartSearch"]
    end
    raise TestFailure, "made #{requeues.length} recovery requests, expected one" unless
      requeues.length == 1
  end
  raise TestFailure, "deadline failure omitted the semantic result count" unless
    error.message.include?("0 embedded asset(s)")
end

run.call("persistent partial embeddings requeue only once") do
  epoch = 1_700_000_000.0
  partial = json_response(
    200, { "assets" => { "items" => [{ "id" => FIXTURE_IDS.first }] } }
  )
  clock = monotonic_clock(
    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch + 601
  )
  error = expect_contract_failure(
    [partial, idle_smart_search_response(failed: 1), requeue_response, partial],
    expected_requests: 4, clock: clock
  ) do |requests|
    raise TestFailure, "persistent partial result did not requeue exactly once" unless
      requests.count { |request| request.fetch(:method) == "PUT" } == 1
  end
  raise TestFailure, "partial deadline failure omitted the semantic result count" unless
    error.message.include?("1 embedded asset(s)")
end

run.call("persistent unrelated embeddings requeue only once") do
  epoch = 1_700_000_000.0
  unrelated = json_response(
    200, { "assets" => { "items" => [{ "id" => "unrelated-asset" }] } }
  )
  clock = monotonic_clock(
    epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch, epoch + 601
  )
  error = expect_contract_failure(
    [unrelated, idle_smart_search_response(failed: 1), requeue_response, unrelated],
    expected_requests: 4, clock: clock
  ) do |requests|
    raise TestFailure, "persistent unrelated result did not requeue exactly once" unless
      requests.count { |request| request.fetch(:method) == "PUT" } == 1
  end
  raise TestFailure, "unrelated deadline failure omitted the semantic result count" unless
    error.message.include?("1 embedded asset(s)")
end

unless failures.empty?
  failures.each { |failure| warn "immich-smart-search-retry-test: #{failure}" }
  exit 1
end

puts "Immich smart-search retry and fail-closed behavior passed"
