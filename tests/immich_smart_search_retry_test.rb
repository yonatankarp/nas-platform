#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require "uri"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "immich.sh")

class ContractFailure < StandardError; end

def fail_test(message)
  warn "immich-smart-search-retry-test: #{message}"
  exit 1
end

def extract_method(source, name, next_name)
  source[/^def #{name}\b.*?(?=^def #{next_name}\b)/m] ||
    fail_test("could not extract #{name} from the Immich contract")
end

def fail_contract(message)
  raise ContractFailure, message
end

module Kernel
  def sleep(_duration); end
end

source = File.read(CONTRACT)
request_source = extract_method(source, "request", "multipart_body")
smart_search_source = extract_method(
  source, "assert_cpu_machine_learning", "assert_originals_open"
)

server = TCPServer.new("127.0.0.1", 0)
Object.const_set(:BASE, URI("http://127.0.0.1:#{server.local_address.ip_port}"))
responses = [
  [500, { "message" => "machine learning is still loading" }],
  [200, { "assets" => { "items" => [{ "id" => "fixture-id" }] } }]
]
requests = 0
server_thread = Thread.new do
  responses.each do |status, body|
    begin
      socket = server.accept
    rescue IOError
      break
    end
    while (line = socket.gets)
      break if line == "\r\n"
    end
    payload = JSON.generate(body)
    socket.write("HTTP/1.1 #{status} Test\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    socket.close
    requests += 1
  end
end

eval(request_source, binding, CONTRACT)
eval(smart_search_source, binding, CONTRACT)

contract_error = nil
begin
  assert_cpu_machine_learning("test-token", ["fixture-id"])
rescue ContractFailure => error
  contract_error = error
ensure
  server.close
  server_thread.join(1)
end

fail_test("transient HTTP 500 was not retried: #{contract_error.message}") if contract_error
fail_test("smart search did not retry exactly once") unless requests == 2
puts "Immich smart-search transient failure retry passed"
