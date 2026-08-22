#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require "timeout"
require "uri"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "immich.sh")
FIXTURE_IDS = %w[photo-fixture video-fixture].freeze

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
  def sleep(_duration); end
end

def json_response(status, body)
  [status, JSON.generate(body)]
end

def complete_response
  json_response(
    200,
    { "assets" => { "items" => FIXTURE_IDS.map { |id| { "id" => id } } } }
  )
end

def with_http_responses(responses)
  server = TCPServer.new("127.0.0.1", 0)
  Object.send(:remove_const, :BASE) if Object.const_defined?(:BASE)
  Object.const_set(:BASE, URI("http://127.0.0.1:#{server.local_address.ip_port}"))
  requests = 0
  server_thread = Thread.new do
    responses.each do |status, payload|
      begin
        socket = server.accept
      rescue IOError
        break
      end
      while (line = socket.gets)
        break if line == "\r\n"
      end
      requests += 1
      socket.write("HTTP/1.1 #{status} Test\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      socket.close
    end
  end

  yield -> { requests }
ensure
  server&.close
  server_thread&.join(1)
end

def expect_success(responses, expected_requests:, expected_ids: FIXTURE_IDS)
  with_http_responses(responses) do |request_count|
    assert_cpu_machine_learning("test-token", expected_ids)
    raise TestFailure, "made #{request_count.call} requests, expected #{expected_requests}" unless
      request_count.call == expected_requests
  end
end

def expect_contract_failure(responses, expected_status: nil, expected_requests: 1,
                            expected_ids: FIXTURE_IDS)
  error = nil
  with_http_responses(responses) do |request_count|
    begin
      assert_cpu_machine_learning("test-token", expected_ids)
    rescue ContractFailure => caught
      error = caught
    rescue StandardError => caught
      raise TestFailure, "escaped #{caught.class} instead of failing the contract"
    end
    raise TestFailure, "contract unexpectedly accepted the response" unless error
    if expected_status && !error.message.include?(expected_status.to_s)
      raise TestFailure, "failure omitted HTTP #{expected_status}: #{error.message}"
    end
    raise TestFailure, "made #{request_count.call} requests, expected #{expected_requests}" unless
      request_count.call == expected_requests
  end
  error
end

def with_times(*times)
  real_now = Time.method(:now)
  last = times.last
  Time.define_singleton_method(:now) { times.shift || last }
  yield
ensure
  Time.define_singleton_method(:now, &real_now)
end

source = File.read(CONTRACT)
eval(extract_method(source, "request", "multipart_body"), binding, CONTRACT)
eval(
  extract_method(source, "assert_cpu_machine_learning", "assert_originals_open"),
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

run.call("partial semantic result") do
  partial = json_response(200, { "assets" => { "items" => [{ "id" => FIXTURE_IDS.first }] } })
  expect_success([partial, complete_response], expected_requests: 2)
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
  epoch = Time.at(1_700_000_000)
  with_times(epoch, epoch, epoch + 601) do
    error = expect_contract_failure(
      [json_response(503, {}), json_response(503, {})],
      expected_status: 503,
      expected_requests: 2
    )
    raise TestFailure, "deadline failure omitted the semantic result count" unless
      error.message.include?("0 embedded asset(s)")
  end
end

unless failures.empty?
  failures.each { |failure| warn "immich-smart-search-retry-test: #{failure}" }
  exit 1
end

puts "Immich smart-search retry and fail-closed behavior passed"
