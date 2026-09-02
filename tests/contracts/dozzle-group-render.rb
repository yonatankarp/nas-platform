#!/usr/bin/env ruby
# The rendered-document half of the Dozzle service contract: the friendly
# container names and the Running Containers grouping, read off a merged
# `docker compose config --format json` rather than off Compose source, so an
# override that breaks either cannot slip in unrendered.
#
# Invoked once per stack per platform variant -- twenty-four times in a static
# run -- with the stack, the variant, the expected group and the probe port as
# argv, and the whole rendered document in DOZZLE_RENDERED_COMPOSE. The probe
# port is a value the repository never contains, which is what makes the first
# assertion behavioural: both container-internal consumers of the listener port
# have to come back holding it.
stack, variant, expected_group, relay_probe_port = ARGV
services = JSON.parse(ENV.fetch("DOZZLE_RENDERED_COMPOSE")).fetch("services")
if stack == "dozzle"
  # Behavioural in the only sense available to a rendered document: both
  # container-internal consumers of the listener port are read back from a render
  # driven by a port the repository never mentions. Asserting the Python source
  # text instead would pin whatever literal it happened to contain.
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
