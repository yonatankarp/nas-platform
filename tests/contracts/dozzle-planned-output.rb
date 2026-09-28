#!/usr/bin/env ruby
# Planned-change half of the Dozzle contract: exact `DOZZLE_PLAN_*` marker counts in
# a `--check --diff` transcript; presence alone cannot tell repair from creation.
mode, output_path = ARGV
abort "Dozzle contract failed: planned-change output path is absent" unless output_path
abort "Dozzle contract failed: planned-change output is unsafe" unless
  File.file?(output_path) && !File.symlink?(output_path)

expected_counts = {
  "DOZZLE_PLAN_DISPATCHER_CREATE" => [0, 1],
  "DOZZLE_PLAN_DISPATCHER_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_CREATE" => [1, 4],
  "DOZZLE_PLAN_RULE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_ENABLE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_REMOVE" => [1, 0],
  "DOZZLE_PLAN_DISPATCHER_REMOVE" => [1, 0]
}
scenario_index = mode == "assert-check-mixed-output" ? 0 : 1
output = File.read(output_path)
expected_counts.each do |marker, counts|
  expected = counts.fetch(scenario_index)
  actual = output.scan(/\b#{Regexp.escape(marker)}\b/).length
  abort "Dozzle contract failed: planned-change marker count differs for #{marker}" unless actual == expected
end
puts "Dozzle planned-change output contract passed"
