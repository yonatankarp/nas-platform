#!/usr/bin/env ruby
# The duplicate-label half of the Dozzle service contract.
#
# A rendered document cannot see this: Compose keeps the last of two identical
# mapping keys, so a stack that spells `dev.dozzle.name` twice renders as one
# label and the rendered half above it agrees. Reading the source stream with
# Psych is the only place the second spelling is still visible.
#
# PolicySupport arrives as a `-r` preload naming the INSPECTED tree, not this
# checkout -- see the comment on the invocation in tests/contracts/dozzle.sh.
begin
  ARGV.each do |path|
    document = Psych.parse_stream(File.read(path))
    abort "Dozzle contract failed: base Compose has duplicate dev.dozzle.name labels" if
      PolicySupport.duplicate_yaml_keys(document).include?("dev.dozzle.name")
  end
rescue Psych::Exception, SystemCallError
  abort "Dozzle contract failed: base Compose label YAML is invalid"
end
