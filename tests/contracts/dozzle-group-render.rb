#!/usr/bin/env ruby
# Rendered-document half of the Dozzle contract: container names and grouping,
# read off a merged `docker compose config` so an override cannot slip past.
# argv: stack, variant, expected group, probe port; document in DOZZLE_RENDERED_COMPOSE.
stack, variant, expected_group, relay_probe_port = ARGV
services = JSON.parse(ENV.fetch("DOZZLE_RENDERED_COMPOSE")).fetch("services")
if stack == "dozzle"
  # Both consumers must come back holding a probe port the repository never contains.
  relay = services.fetch("alert-relay")
  probed = relay.fetch("environment", {})["ALERT_RELAY_PORT"]
  healthcheck = Array(relay.dig("healthcheck", "test")).join(" ")
  abort "Dozzle contract failed: #{stack} #{variant} alert relay does not take its listener port from one variable" unless
    probed == relay_probe_port &&
    healthcheck.include?("http://127.0.0.1:#{relay_probe_port}/healthz")
end
services.each do |service, definition|
  matches = definition.fetch("labels", {}).select { |name, _value| name == "dev.dozzle.name" }
  abort "Dozzle contract failed: #{stack} #{variant} #{service} name label is absent" if matches.empty?
  abort "Dozzle contract failed: #{stack} #{variant} #{service} name label differs" unless
    matches == {"dev.dozzle.name" => service}
end
if expected_group.empty?
  abort "Dozzle contract failed: #{stack} #{variant} must remain a single-container stack" unless
    services.length == 1
  services.each do |service, definition|
    abort "Dozzle contract failed: #{stack} #{variant} #{service} left Running Containers grouping" if
      definition.fetch("labels", {}).key?("dev.dozzle.group")
  end
else
  abort "Dozzle contract failed: #{stack} #{variant} must remain a multi-container stack" unless
    services.length > 1
  services.each do |service, definition|
    labels = definition.fetch("labels", {})
    matches = labels.select { |name, _value| name == "dev.dozzle.group" }
    abort "Dozzle contract failed: #{stack} #{variant} #{service} group label differs" unless
      matches == {"dev.dozzle.group" => expected_group}
  end
end
