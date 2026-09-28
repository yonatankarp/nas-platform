#!/usr/bin/env ruby
# Assert one container's Dozzle display labels are exactly what the platform
# declared, and that the contract's drift sentinel is gone.
# usage: 20-dozzle-labels.rb EXPECTED_GROUP EXPECTED_NAME CONTAINER
# An empty EXPECTED_GROUP means no dev.dozzle.group label at all. Run by 20-dozzle.sh;
# tests/contracts/dozzle-alerts.rb reads this file as text for both label names (#315).
require "json"

expected_group, expected_name, container = ARGV
begin
  labels = JSON.parse(ENV.fetch("DOZZLE_RUNTIME_LABELS"))
rescue JSON::ParserError
  abort "#{container} returned invalid Docker labels"
end
abort "#{container} returned non-object Docker labels" unless labels.is_a?(Hash)
abort "#{container} has an incorrect dev.dozzle.name label" unless
  labels["dev.dozzle.name"] == expected_name
if expected_group.empty?
  abort "#{container} has an unexpected dev.dozzle.group label" if
    labels.key?("dev.dozzle.group")
else
  abort "#{container} has an incorrect dev.dozzle.group label" unless
    labels["dev.dozzle.group"] == expected_group
end
abort "#{container} retained the unmanaged Dozzle drift sentinel" if
  labels.key?("dev.dozzle.contract.sentinel")
