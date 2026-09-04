#!/usr/bin/env ruby
# The alert-definition half of the Dozzle service contract: the four managed
# rules, the managed dispatcher's URL, authorization header and template, and
# -- under `static` only -- the proofs that the integration lane and the Mac
# hooks still exercise them.
#
# Takes the mode as its last argument and gates the last third of the file on
# it, so a live mode checks the definitions without demanding the harness text.
defaults = YAML.safe_load_file(ARGV.fetch(0))
role_tasks = YAML.safe_load_file(ARGV.fetch(1), aliases: false)
integration = File.read(ARGV.fetch(2))
mac_drift = File.read(ARGV.fetch(3))
mac_verify = File.read(ARGV.fetch(4))
# The label assertions the verification hook makes have been a program beside it
# since #315, so the hook is read for the inspection it performs and the program
# for the labels it names. Reading only the hook would leave two positive
# substring checks that can no longer match, which is the shape #291 removed from
# this file when the runtime half moved out of it.
mac_verify_labels = File.read(ARGV.fetch(5))
expected = {
  "OOM" => ['name == "oom"', 300],
  "Unexpected exit" => ['name == "die" && !(attributes["exitCode"] in ["0", "130", "143", "137"])', 300],
  "Unhealthy" => ['name == "health_status" && attributes["healthStatus"] == "unhealthy"', 0],
  "Recovery" => ['name == "health_status" && attributes["healthStatus"] == "healthy"', 0]
}
alerts = defaults.fetch("dozzle_alerts")
actual = alerts.to_h { |alert| [alert.fetch("name"), [alert.fetch("eventExpression"), alert.fetch("cooldown")]] }
abort "Dozzle contract failed: exact alert definitions differ" unless actual == expected
abort "Dozzle contract failed: alerts must be enabled event-only rules over all containers" unless
  alerts.all? { |alert| alert.fetch("enabled") == true && alert.fetch("containerExpression") == "true" && alert.fetch("logExpression") == "" }
relay_port = defaults.fetch("dozzle_alert_relay_port", nil)
abort "Dozzle contract failed: relay listener port is not a single declared TCP port" unless
  relay_port.is_a?(Integer) && relay_port.between?(1, 65535)
dispatcher = defaults.fetch("dozzle_dispatcher")
# The URL interpolates the declared port rather than repeating it, so the
# dispatcher cannot drift away from the port the relay is told to listen on.
abort "Dozzle contract failed: managed dispatcher must target only the private alert relay" unless
  dispatcher.fetch("url") == "http://alert-relay:{{ dozzle_alert_relay_port }}/alerts"
# This is the whole of "the role wires the write-only ntfy token": the equality
# above names the variable, in the header, on the dispatcher the relay posts to.
# A second check for the same variable anywhere in the defaults file could only
# ever pass when this one already had.
abort "Dozzle contract failed: managed dispatcher authorization differs" unless
  dispatcher.fetch("headers") == {"Authorization" => "Bearer {{ vault_ntfy_dozzle_token }}"}
expected_template_fields = {
  "version" => "1",
  "rule" => ".Subscription.Name",
  "containerId" => ".Container.ID",
  "container" => ".Container.Name",
  "host" => ".Container.HostName",
  "event" => ".Event.Name",
  "healthStatus" => 'index .Event.Attributes `healthStatus`',
  "exitCode" => 'index .Event.Attributes `exitCode`',
  "timestamp" => '.Event.Timestamp.Format `2006-01-02T15:04:05.999999999Z07:00`'
}
template_source = dispatcher.fetch("template")
abort "Dozzle contract failed: managed dispatcher retains an ntfy presentation envelope" if
  %w[topic title message priority tags markdown].any? { |field| template_source.include?("'#{field}'") }
expected_template_fields.each do |field, expression|
  abort "Dozzle contract failed: managed dispatcher is missing exact #{field}" unless
    template_source.include?("'#{field}':") && template_source.include?(expression)
end
abort "Dozzle contract failed: role does not reconcile enabled state through PATCH" unless
  role_tasks.any? { |task| task.dig("ansible.builtin.uri", "method") == "PATCH" }
planned_tasks = [
  "Report planned managed Dozzle dispatcher creation",
  "Report planned managed Dozzle dispatcher repair",
  "Report planned managed Dozzle alert rule creation",
  "Report planned managed Dozzle alert rule repair",
  "Report planned managed Dozzle alert rule enabled-state repair",
  "Report planned unmanaged Dozzle alert rule removal",
  "Report planned unmanaged Dozzle dispatcher removal"
]
markers = %w[
  DOZZLE_DUPLICATE_DISPATCHER_REFUSED_WITH_SAFE_IDS
  DOZZLE_DUPLICATE_RULE_REFUSED_WITH_SAFE_IDS
  DOZZLE_SURPLUS_STATE_REMOVED
  DOZZLE_CHECK_MIXED_PLANNED_IMMUTABLE_AND_REPAIRED
  DOZZLE_CHECK_MISSING_PLANNED_IMMUTABLE_AND_REPAIRED
]
if ARGV.fetch(6) == "static"
  planned_tasks.each do |name|
    abort "Dozzle contract failed: missing #{name}" unless
      role_tasks.any? { |task| task["name"] == name }
  end
  markers.each do |marker|
    abort "Dozzle contract failed: integration is missing #{marker}" unless integration.include?(marker)
  end
  %w[check-mixed-create check-mixed-unchanged --check --diff].each do |proof|
    abort "Dozzle contract failed: Mac drift proof is missing #{proof}" unless mac_drift.include?(proof)
  end
  abort "Dozzle contract failed: Mac drift proof does not corrupt a managed group label" unless
    mac_drift.include?("dev.dozzle.group")
  abort "Dozzle contract failed: Mac drift proof does not corrupt the managed friendly name" unless
    mac_drift.include?("dev.dozzle.name: dozzle-contract-drift")
  abort "Dozzle contract failed: Mac drift proof does not install an unrelated sentinel label" unless
    mac_drift.include?("dev.dozzle.contract.sentinel")
  abort "Dozzle contract failed: Mac runtime verification does not inspect Docker labels" unless
    mac_verify.include?("docker container inspect") &&
      mac_verify_labels.include?("dev.dozzle.group") &&
      mac_verify_labels.include?("dev.dozzle.name")
end
