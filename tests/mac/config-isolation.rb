#!/usr/bin/env ruby
# Assert that two simultaneous Mac sandboxes are isolated from each other.
#
# usage: config-isolation.rb DIRECTORY
#
# DIRECTORY holds the rendered `docker compose config --format json` output for
# every stack, twice: once as `first-<stack>.json` and once as
# `second-<stack>.json`. tests/mac/config-isolation.sh renders those two sets
# with different project names and ports; this program is the half that reads
# them back and refuses any Compose project name, container name, published
# port, control network or state bind the two sandboxes would share.
#
# Every refusal is a `raise` naming the stack and the thing that collided, so
# the failing pair is readable without re-rendering anything.
#
# It lived in a `<<'RUBY'` heredoc in that script until #315, opened as
# `ruby -rjson -`; the require below is that preload, which the body never had.
require "json"

directory = ARGV.fetch(0)
first_beszel = JSON.parse(File.read(File.join(directory, "first-beszel.json")))
second_beszel = JSON.parse(File.read(File.join(directory, "second-beszel.json")))
first_ntfy = JSON.parse(File.read(File.join(directory, "first-ntfy.json")))
second_ntfy = JSON.parse(File.read(File.join(directory, "second-ntfy.json")))
first_dozzle = JSON.parse(File.read(File.join(directory, "first-dozzle.json")))
second_dozzle = JSON.parse(File.read(File.join(directory, "second-dozzle.json")))
first_audiobookshelf = JSON.parse(File.read(File.join(directory, "first-audiobookshelf.json")))
second_audiobookshelf = JSON.parse(File.read(File.join(directory, "second-audiobookshelf.json")))
first_pinchflat = JSON.parse(File.read(File.join(directory, "first-pinchflat.json")))
second_pinchflat = JSON.parse(File.read(File.join(directory, "second-pinchflat.json")))
first_kapowarr = JSON.parse(File.read(File.join(directory, "first-kapowarr.json")))
second_kapowarr = JSON.parse(File.read(File.join(directory, "second-kapowarr.json")))
first_bindery = JSON.parse(File.read(File.join(directory, "first-bindery.json")))
second_bindery = JSON.parse(File.read(File.join(directory, "second-bindery.json")))
first_trailarr = JSON.parse(File.read(File.join(directory, "first-trailarr.json")))
second_trailarr = JSON.parse(File.read(File.join(directory, "second-trailarr.json")))
first_seerr = JSON.parse(File.read(File.join(directory, "first-seerr.json")))
second_seerr = JSON.parse(File.read(File.join(directory, "second-seerr.json")))
first_komga = JSON.parse(File.read(File.join(directory, "first-komga.json")))
second_komga = JSON.parse(File.read(File.join(directory, "second-komga.json")))
first_jellyfin = JSON.parse(File.read(File.join(directory, "first-jellyfin.json")))
second_jellyfin = JSON.parse(File.read(File.join(directory, "second-jellyfin.json")))
first_immich = JSON.parse(File.read(File.join(directory, "first-immich.json")))
second_immich = JSON.parse(File.read(File.join(directory, "second-immich.json")))
first_paperless = JSON.parse(File.read(File.join(directory, "first-paperless.json")))
second_paperless = JSON.parse(File.read(File.join(directory, "second-paperless.json")))
first_arr = JSON.parse(File.read(File.join(directory, "first-arr.json")))
second_arr = JSON.parse(File.read(File.join(directory, "second-arr.json")))
first_downloaders = JSON.parse(File.read(File.join(directory, "first-downloaders.json")))
second_downloaders = JSON.parse(File.read(File.join(directory, "second-downloaders.json")))

def published(config, service)
  config.dig("services", service, "ports", 0, "published").to_s
end

def bind_source(config, service, target)
  mounts = config.dig("services", service, "volumes") || []
  matches = mounts.select { |mount| mount["type"] == "bind" && mount["target"] == target }
  raise "#{service} has an ambiguous #{target} bind" unless matches.length == 1

  matches.fetch(0).fetch("source")
end

def assert_dozzle_aliases_and_distinct_names(first, second, stack)
  first.fetch("services").each_key do |service|
    first_alias = first.dig("services", service, "labels", "dev.dozzle.name")
    second_alias = second.dig("services", service, "labels", "dev.dozzle.name")
    raise "#{stack} first #{service} Dozzle name is not the service key" unless first_alias == service
    raise "#{stack} second #{service} Dozzle name is not the service key" unless second_alias == service

    first_name = first.dig("services", service, "container_name")
    second_name = second.dig("services", service, "container_name")
    raise "#{stack} #{service} container name is absent" unless first_name && second_name
    raise "#{stack} #{service} container names collide" if first_name == second_name
  end
end

[
  [first_beszel, second_beszel, "Beszel"],
  [first_ntfy, second_ntfy, "ntfy"],
  [first_dozzle, second_dozzle, "Dozzle"],
  [first_audiobookshelf, second_audiobookshelf, "Audiobookshelf"],
  [first_komga, second_komga, "Komga"],
  [first_jellyfin, second_jellyfin, "Jellyfin"],
  [first_immich, second_immich, "Immich"],
  [first_paperless, second_paperless, "Paperless"],
  [first_arr, second_arr, "Arr"],
  [first_downloaders, second_downloaders, "downloaders"]
].each do |first, second, stack|
  assert_dozzle_aliases_and_distinct_names(first, second, stack)
end

raise "Beszel project namespaces collide" if first_beszel["name"] == second_beszel["name"]
raise "ntfy project namespaces collide" if first_ntfy["name"] == second_ntfy["name"]
raise "Dozzle project namespaces collide" if first_dozzle["name"] == second_dozzle["name"]
raise "Audiobookshelf project namespaces collide" if first_audiobookshelf["name"] == second_audiobookshelf["name"]
raise "Komga project namespaces collide" if first_komga["name"] == second_komga["name"]
raise "Jellyfin project namespaces collide" if first_jellyfin["name"] == second_jellyfin["name"]
first_beszel.fetch("services").each_key do |service|
  first_name = first_beszel.dig("services", service, "container_name")
  second_name = second_beszel.dig("services", service, "container_name")
  raise "Beszel #{service} container name is absent" unless first_name && second_name
  raise "Beszel #{service} container names collide" if first_name == second_name
end
raise "ntfy container names collide" if first_ntfy.dig("services", "ntfy", "container_name") ==
                                        second_ntfy.dig("services", "ntfy", "container_name")
first_dozzle.fetch("services").each_key do |service|
  first_name = first_dozzle.dig("services", service, "container_name")
  second_name = second_dozzle.dig("services", service, "container_name")
  raise "Dozzle #{service} container name is absent" unless first_name && second_name
  raise "Dozzle #{service} container names collide" if first_name == second_name
end
raise "Beszel published ports collide" if published(first_beszel, "hub") == published(second_beszel, "hub")
raise "ntfy published ports collide" if published(first_ntfy, "ntfy") == published(second_ntfy, "ntfy")
raise "Dozzle published ports collide" if published(first_dozzle, "dozzle") == published(second_dozzle, "dozzle")
raise "Audiobookshelf container names collide" if
  first_audiobookshelf.dig("services", "audiobookshelf", "container_name") ==
    second_audiobookshelf.dig("services", "audiobookshelf", "container_name")
raise "Audiobookshelf published ports collide" if
  published(first_audiobookshelf, "audiobookshelf") == published(second_audiobookshelf, "audiobookshelf")
raise "first Audiobookshelf backup bind escaped its Docker state root" unless
  bind_source(first_audiobookshelf, "audiobookshelf", "/metadata/backups") ==
    File.join(directory, "first/audiobookshelf/backups")
raise "second Audiobookshelf backup bind escaped its Docker state root" unless
  bind_source(second_audiobookshelf, "audiobookshelf", "/metadata/backups") ==
    File.join(directory, "second/audiobookshelf/backups")
raise "Komga container names collide" if first_komga.dig("services", "komga", "container_name") ==
                                         second_komga.dig("services", "komga", "container_name")
raise "Komga published ports collide" if published(first_komga, "komga") == published(second_komga, "komga")
raise "Jellyfin container names collide" if
  first_jellyfin.dig("services", "jellyfin", "container_name") ==
    second_jellyfin.dig("services", "jellyfin", "container_name")
raise "Jellyfin published ports collide" if
  published(first_jellyfin, "jellyfin") == published(second_jellyfin, "jellyfin")
# The Mac override must drop the NAS render node and the root group that opens
# it, or a Docker Desktop run would fail on a device that does not exist.
raise "Jellyfin Mac runtime kept the NAS render device" unless
  first_jellyfin.dig("services", "jellyfin", "devices").to_a.empty?
raise "Jellyfin Mac runtime kept the NAS root group" unless
  first_jellyfin.dig("services", "jellyfin", "group_add").to_a.empty?
raise "Immich project namespaces collide" if first_immich["name"] == second_immich["name"]
# Immich is four containers; every one of them must be namespaced, or a second
# sandbox would collide on the database or the cache rather than on the server.
first_immich.fetch("services").each_key do |service|
  first_name = first_immich.dig("services", service, "container_name")
  second_name = second_immich.dig("services", service, "container_name")
  raise "Immich #{service} container name is absent" unless first_name && second_name
  raise "Immich #{service} container names collide" if first_name == second_name
end
raise "Immich published ports collide" if
  published(first_immich, "immich-server") == published(second_immich, "immich-server")
raise "Immich Mac runtime kept the NAS render device" unless
  first_immich.dig("services", "immich-server", "devices").to_a.empty?
%w[immich-machine-learning redis database].each do |service|
  raise "Immich #{service} publishes a host port" if
    first_immich.dig("services", service).key?("ports")
end

raise "Paperless project namespaces collide" if first_paperless["name"] == second_paperless["name"]
first_paperless.fetch("services").each_key do |service|
  first_name = first_paperless.dig("services", service, "container_name")
  second_name = second_paperless.dig("services", service, "container_name")
  raise "Paperless #{service} container name is absent" unless first_name && second_name
  raise "Paperless #{service} container names collide" if first_name == second_name
end
raise "Paperless published ports collide" if
  published(first_paperless, "webserver") == published(second_paperless, "webserver")
raise "Paperless Mac runtime left the Compose network" if
  first_paperless.dig("services", "webserver").key?("network_mode")
%w[broker db gotenberg tika].each do |service|
  raise "Paperless #{service} publishes a host port" if
    first_paperless.dig("services", service).key?("ports")
end

%w[radarr sonarr prowlarr bazarr].each do |service|
  raise "Arr #{service} published ports collide" if
    published(first_arr, service) == published(second_arr, service)
end
raise "SABnzbd published ports collide" if
  published(first_downloaders, "sabnzbd") == published(second_downloaders, "sabnzbd")
raise "Unpackerr publishes a host port" if
  first_downloaders.dig("services", "unpackerr").key?("ports")

raise "Pinchflat project namespaces collide" if first_pinchflat["name"] == second_pinchflat["name"]
raise "Pinchflat container names collide" if
  first_pinchflat.dig("services", "pinchflat", "container_name") ==
  second_pinchflat.dig("services", "pinchflat", "container_name")
raise "Pinchflat published ports collide" if
  published(first_pinchflat, "pinchflat") == published(second_pinchflat, "pinchflat")

raise "Kapowarr project namespaces collide" if first_kapowarr["name"] == second_kapowarr["name"]
raise "Kapowarr container names collide" if
  first_kapowarr.dig("services", "kapowarr", "container_name") ==
  second_kapowarr.dig("services", "kapowarr", "container_name")
raise "Kapowarr published ports collide" if
  published(first_kapowarr, "kapowarr") == published(second_kapowarr, "kapowarr")

raise "Bindery project namespaces collide" if first_bindery["name"] == second_bindery["name"]
raise "Bindery container names collide" if
  first_bindery.dig("services", "bindery", "container_name") ==
  second_bindery.dig("services", "bindery", "container_name")
raise "Bindery published ports collide" if
  published(first_bindery, "bindery") == published(second_bindery, "bindery")
# Bindery is the only Phase 2 project on the shared control network, so a
# sandbox copy must take its own rather than joining the neighbour's.
raise "Bindery control networks collide" if
  first_bindery.dig("networks", "media-control", "name") ==
  second_bindery.dig("networks", "media-control", "name")

raise "Trailarr project namespaces collide" if first_trailarr["name"] == second_trailarr["name"]
raise "Trailarr container names collide" if
  first_trailarr.dig("services", "trailarr", "container_name") ==
  second_trailarr.dig("services", "trailarr", "container_name")
raise "Trailarr published ports collide" if
  published(first_trailarr, "trailarr") == published(second_trailarr, "trailarr")
# Trailarr reads Radarr and Sonarr by service name, so a sandbox copy must take
# its own control network rather than joining the neighbour's.
raise "Trailarr control networks collide" if
  first_trailarr.dig("networks", "media-control", "name") ==
  second_trailarr.dig("networks", "media-control", "name")

raise "Seerr project namespaces collide" if first_seerr["name"] == second_seerr["name"]
raise "Seerr container names collide" if
  first_seerr.dig("services", "seerr", "container_name") ==
  second_seerr.dig("services", "seerr", "container_name")
raise "Seerr published ports collide" if
  published(first_seerr, "seerr") == published(second_seerr, "seerr")
# Seerr reads Jellyfin and writes Radarr and Sonarr by service name, so a
# sandbox copy must take its own control network rather than joining the
# neighbour's.
raise "Seerr control networks collide" if
  first_seerr.dig("networks", "media-control", "name") ==
  second_seerr.dig("networks", "media-control", "name")

raise "Mac socket proxy publishes a host port" if first_beszel.dig("services", "socket-proxy").key?("ports")
raise "Dozzle socket proxy publishes a host port" if first_dozzle.dig("services", "socket-proxy").key?("ports")

puts "Mac Compose isolation: distinct projects, names, and ports"
