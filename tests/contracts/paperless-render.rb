#!/usr/bin/env ruby
# Effective-Compose half of the Paperless service contract.
#
# usage: PAPERLESS_RENDERED_COMPOSE=<docker compose config --format json> \
#          ruby -rjson -rpathname paperless-render.rb VARIANT
#
# -rjson is required: the body calls JSON.parse without requiring json.
variant = ARGV.fetch(0)
services = JSON.parse(ENV.fetch("PAPERLESS_RENDERED_COMPOSE")).fetch("services")
# Compose appends `ports:` lists, so only the merged render shows a missing `!override`.
webserver_networking = services.fetch("webserver")
abort "Paperless contract failed: #{variant} effective config must not use host networking" if
  webserver_networking.key?("network_mode")
expected_published = variant == "mac" ? ["38000"] : ["8000"]
abort "Paperless contract failed: #{variant} effective webserver publication differs" unless
  webserver_networking.fetch("ports").map { |port| port.fetch("published").to_s } == expected_published
%w[broker db gotenberg tika].each do |name|
  abort "Paperless contract failed: #{variant} #{name} publishes a host port" unless
    Array(services.fetch(name)["ports"]).empty?
end
mounts = services.fetch("webserver").fetch("volumes")
by_target = mounts.group_by { |mount| mount.fetch("target") }
expected_targets = %w[
  /usr/src/paperless/data /usr/src/paperless/cache /usr/src/paperless/export
  /usr/share/tesseract-ocr/5/tessdata/heb.traineddata
  /usr/src/paperless/media /usr/src/paperless/consume
]
abort "Paperless contract failed: #{variant} duplicate or missing webserver mount targets" unless
  by_target.keys.sort == expected_targets.sort && by_target.values.all? { |entries| entries.length == 1 }

document_targets = {
  "/usr/src/paperless/media" => "/volume2/Documents/archive",
  "/usr/src/paperless/consume" => "/volume2/Documents/inbox",
  "/usr/src/paperless/export" => "/volume2/Documents/export"
}
document_sources = document_targets.map do |target, expected_source|
  mount = by_target.fetch(target).fetch(0)
  source = File.expand_path(mount.fetch("source"))
  abort "Paperless contract failed: #{variant} document mount #{target} source differs" unless
    source == expected_source
  abort "Paperless contract failed: #{variant} document mount #{target} is read-only" if
    mount["read_only"] == true
  source
end
abort "Paperless contract failed: #{variant} document sources alias or overlap" unless
  document_sources.uniq.length == document_sources.length &&
    document_sources.combination(2).none? do |left, right|
      left.start_with?(right + File::SEPARATOR) || right.start_with?(left + File::SEPARATOR)
    end
abort "Paperless contract failed: #{variant} document source resolves below volume1" if
  document_sources.any? { |source| source == "/volume1" || source.start_with?("/volume1/") }

state_sources = [
  services.fetch("broker").fetch("volumes").fetch(0).fetch("source"),
  services.fetch("db").fetch("volumes").fetch(0).fetch("source"),
  *%w[/usr/src/paperless/data /usr/src/paperless/cache
      /usr/share/tesseract-ocr/5/tessdata/heb.traineddata].map do |target|
    by_target.fetch(target).fetch(0).fetch("source")
  end
].map { |source| File.expand_path(source) }
expected_state_root = "/volume1/Docker/paperless-ngx"
abort "Paperless contract failed: #{variant} state source escapes its isolated root" unless
  state_sources.all? do |source|
    source.start_with?(expected_state_root + File::SEPARATOR)
  end
expected_state_sources = %w[postgres redis data cache].map do |relative|
  File.join(expected_state_root, relative)
end + [File.join(expected_state_root, "tessdata", "heb.traineddata")]
abort "Paperless contract failed: #{variant} effective state source list differs" unless
  state_sources.sort == expected_state_sources.sort
