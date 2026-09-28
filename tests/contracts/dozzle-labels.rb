#!/usr/bin/env ruby
# Duplicate-label half of the Dozzle contract: Compose keeps the last of two
# identical keys, so only the Psych source stream shows a second `dev.dozzle.name`.
begin
  ARGV.each do |path|
    document = Psych.parse_stream(File.read(path))
    abort "Dozzle contract failed: base Compose has duplicate dev.dozzle.name labels" if
      PolicySupport.duplicate_yaml_keys(document).include?("dev.dozzle.name")
  end
rescue Psych::Exception, SystemCallError
  abort "Dozzle contract failed: base Compose label YAML is invalid"
end
