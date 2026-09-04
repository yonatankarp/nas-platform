#!/usr/bin/env ruby
# Assert one container's Dozzle display labels are exactly what the platform
# declared, and that the contract's drift sentinel is gone.
#
# usage: 20-dozzle-labels.rb EXPECTED_GROUP EXPECTED_NAME CONTAINER
#
# An empty EXPECTED_GROUP means the container must carry no dev.dozzle.group
# label at all, which is how the single-container services are spelled.
#
# tests/mac/hooks/verify/20-dozzle.sh is the hook this belongs to. It inspects
# each container once, hands the label JSON over in DOZZLE_RUNTIME_LABELS, and
# runs this program per container.
#
# tests/contracts/dozzle-alerts.rb reads this file as text and requires it to
# name both labels, so the contract asserts on the program rather than on a
# wrapper the assertions have moved out of. It reads it out of the tree it is
# inspecting, which is not the same root the hook resolves this program from --
# the hook uses its own checkout, and the contract uses whatever it was pointed
# at.
#
# It ran from a `<<'RUBY'` heredoc in that hook until #315, opened as
# `ruby -rjson -` -- the body carried no require of its own and took json from
# the command line, so the require below is that preload written down.
# Everything after it is byte-identical to what the heredoc rendered.
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
