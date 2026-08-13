# frozen_string_literal: true

require "time"
require "json"
require "net/http"
require "timeout"
require "uri"

module BeszelTelemetry
  FRESHNESS_SECONDS = 180
  FUTURE_SKEW_SECONDS = 5
  BASE_CATEGORIES = %w[core disk containers].freeze
  TransientFetchError = Class.new(StandardError)
  NonRetryableFetchError = Class.new(StandardError)

  Evidence = Struct.new(
    :system_id, :system_stats_id, :container_stats_id, :missing_categories,
    keyword_init: true
  ) do
    def ready?
      missing_categories.empty?
    end

    def safe_failure
      "persisted telemetry unavailable or stale for system ID #{system_id}: " \
        "categories=#{missing_categories.join(',')}; " \
        "record IDs=system_stats:#{system_stats_id},container_stats:#{container_stats_id}"
    end
  end

  module_function

  def poll(platform:, system:, timeout_seconds:, request_timeout_seconds:, delay_seconds:,
           fetcher:, now: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
           wall_clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) })
    deadline = clock.call + timeout_seconds
    system_stats = nil
    container_stats = nil
    evidence = evaluate(platform: platform, system: system, system_stats: nil,
                        container_stats: nil, now: now || wall_clock.call)
    loop do
      remaining = deadline - clock.call
      break unless remaining.positive?
      candidate = fetch_with_retryable_failure(
        fetcher, "system_stats", [request_timeout_seconds, remaining].min
      )
      system_stats = candidate unless candidate.nil?

      remaining = deadline - clock.call
      break unless remaining.positive?
      candidate = fetch_with_retryable_failure(
        fetcher, "container_stats", [request_timeout_seconds, remaining].min
      )
      container_stats = candidate unless candidate.nil?
      evidence = evaluate(platform: platform, system: system, system_stats: system_stats,
                          container_stats: container_stats, now: now || wall_clock.call)
      return evidence if evidence.ready?

      remaining = deadline - clock.call
      break unless remaining.positive?
      sleeper.call([delay_seconds, remaining].min)
    end
    evidence
  end

  def required_categories(platform)
    BASE_CATEGORIES + (platform == "nas" ? ["gpu"] : [])
  end

  def fetch_with_retryable_failure(fetcher, collection, timeout)
    fetcher.call(collection, timeout)
  rescue TransientFetchError
    nil
  end

  def evaluate(platform:, system:, system_stats:, container_stats:, now: Time.now.utc,
               freshness_seconds: FRESHNESS_SECONDS)
    system = {} unless system.is_a?(Hash)
    system_stats = {} unless system_stats.is_a?(Hash)
    container_stats = {} unless container_stats.is_a?(Hash)
    system_id = safe_id(system)
    system_fresh = fresh_record?(system_stats, system_id, now, freshness_seconds)
    container_fresh = fresh_record?(container_stats, system_id, now, freshness_seconds)
    stats = system_stats["stats"].is_a?(Hash) ? system_stats["stats"] : {}
    containers = container_stats["stats"].is_a?(Array) ? container_stats["stats"] : []

    ready = {
      "core" => system_fresh && numeric_fields?(stats, %w[cpu m mu mp]) && stats["m"].positive?,
      "disk" => system_fresh && numeric_fields?(stats, %w[d du dp]) && stats["d"].positive?,
      "gpu" => system_fresh && gpu_ready?(stats["g"]),
      "containers" => container_fresh && containers_ready?(containers)
    }

    Evidence.new(
      system_id: system_id,
      system_stats_id: safe_id(system_stats),
      container_stats_id: safe_id(container_stats),
      missing_categories: required_categories(platform).reject { |category| ready.fetch(category) }
    )
  end

  def safe_id(record)
    return "[absent]" unless record.is_a?(Hash) && record.key?("id")

    id = record["id"].is_a?(String) ? record["id"] : ""
    id.match?(/\A[A-Za-z0-9_-]+\z/) ? id : "[invalid]"
  end

  def fresh_record?(record, system_id, now, freshness_seconds)
    return false unless record.is_a?(Hash)
    return false unless valid_id?(record["id"])
    return false unless record["system"] == system_id && record["type"] == "1m"
    return false unless record["created"].is_a?(String)
    return false unless record["created"].match?(/(?:Z|[+-]\d{2}:\d{2})\z/)

    created_text = record.fetch("created").sub(
      /\A(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})/, '\\1T\\2'
    )
    created = Time.iso8601(created_text).utc
    age = now.utc - created
    age >= -FUTURE_SKEW_SECONDS && age <= freshness_seconds
  rescue KeyError, ArgumentError, TypeError
    false
  end

  def valid_id?(value)
    value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]+\z/)
  end

  def numeric_fields?(data, fields)
    fields.all? { |field| numeric?(data[field]) }
  end

  def numeric?(value)
    value.is_a?(Numeric) && ![true, false].include?(value)
  end

  def gpu_ready?(gpus)
    gpus.is_a?(Hash) && !gpus.empty? && gpus.values.all? do |gpu|
      gpu.is_a?(Hash) && gpu["n"].is_a?(String) && !gpu["n"].strip.empty? &&
        numeric?(gpu["u"])
    end
  end

  def containers_ready?(containers)
    !containers.empty? && containers.all? do |container|
      container.is_a?(Hash) && container["n"].is_a?(String) && !container["n"].strip.empty? &&
        numeric?(container["c"]) && numeric?(container["m"])
    end
  end

  def fetch_latest_record(base_uri:, collection:, token:, system_id:, timeout_seconds:,
                          requester: method(:telemetry_get))
    filter = ["system = #{JSON.generate(system_id)}", 'type = "1m"'].join(" && ")
    query = URI.encode_www_form(
      page: 1, perPage: 1, sort: "-created", fields: "id,system,stats,type,created",
      filter: filter
    )
    uri = URI.join(base_uri.to_s, "/api/collections/#{collection}/records?#{query}")
    response = requester.call(uri, token, timeout_seconds)
    code = response.code.to_i
    if [401, 403].include?(code)
      raise NonRetryableFetchError, "telemetry request was not authorized"
    end
    if code == 408 || code == 429 || code >= 500
      raise TransientFetchError, "telemetry request was temporarily unavailable"
    end
    raise NonRetryableFetchError, "telemetry request returned HTTP #{code}" unless code == 200

    payload = JSON.parse(response.body.to_s)
    return nil unless payload.is_a?(Hash) && payload["items"].is_a?(Array)

    payload["items"].first
  rescue JSON::ParserError
    nil
  end

  def telemetry_get(uri, token, timeout_seconds)
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = token
    Timeout.timeout(timeout_seconds) do
      Net::HTTP.start(uri.host, uri.port, open_timeout: [timeout_seconds, 1].min,
                      read_timeout: timeout_seconds) { |http| http.request(request) }
    end
  rescue SystemCallError, IOError, EOFError, Timeout::Error => error
    raise TransientFetchError, error.class.to_s
  end
end
