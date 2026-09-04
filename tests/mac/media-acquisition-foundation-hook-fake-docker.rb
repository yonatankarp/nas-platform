#!/usr/bin/env ruby
# A fake `docker` for tests/mac/media-acquisition-foundation-hook-test.sh.
#
# The test copies this file to $fixture/bin/docker and puts that directory
# first on PATH, so the media-acquisition drift and verify hooks talk to a
# JSON state model (FAKE_DOCKER_STATE) instead of a daemon, and every mutation
# it makes is appended to FAKE_DOCKER_LOG. INJECT names the failure the model
# should stage at a given call, which is how the hooks probe recovery paths.
#
# It lived in a `cat > "$fixture/bin/docker" <<'RUBY'` heredoc inside that test
# until #315 -- nothing syntax-checked it and no linter could reach it. The
# body below is byte-identical to what that heredoc rendered.
require "json"

path = ENV.fetch("FAKE_DOCKER_STATE")
state = JSON.parse(File.read(path))
args = ARGV.dup

def save(path, state)
  File.write(path, JSON.generate(state))
end

def formatted_network(network, format)
  case format
  when /\.Name.*\.Driver/
    [network.fetch("name"), network.fetch("driver"),
     network.fetch("labels")["nas.platform.purpose"],
     network.fetch("labels")["nas.platform.project"]].join("|")
  when /range \$key, \$value := \.Labels/
    network.fetch("labels").map { |key, value| "#{key}=#{value}|" }.join
  when /range \.Containers.*\.Name/
    network.fetch("containers").values.map { |entry| "#{entry.fetch('name')}|" }.join
  when /range \$id, \$_ := \.Containers/
    network.fetch("containers").keys.map { |id| "#{id}|" }.join
  else
    raise "unsupported network format: #{format}"
  end
end

def formatted_container(container, format)
  case format
  when /\.Name.*com\.docker\.compose\.service/
    labels = container.fetch("labels")
    "/#{container.fetch('name')}|com.docker.compose.service=#{labels['com.docker.compose.service']}|" \
      "com.docker.compose.project=#{labels['com.docker.compose.project']}"
  when /range \$name, \$_ := \.NetworkSettings\.Networks/
    container.fetch("networks").map { |name| "#{name}|" }.join
  when /\.Id/
    container.fetch("id")
  else
    raise "unsupported container format: #{format}"
  end
end

log = lambda do |line|
  File.open(ENV.fetch("FAKE_DOCKER_LOG"), "a") { |file| file.puts(line) }
end

if args[0, 2] == ["network", "inspect"] && args.length == 5 && args[3] == "--format"
  network = state.fetch("networks")[args[2]] or exit 1
  puts formatted_network(network, args[4])
elsif args[0, 2] == ["network", "inspect"] && args.length == 3
  exit(state.fetch("networks").key?(args[2]) ? 0 : 1)
elsif args.first == "inspect" && args.length == 4 && args[2] == "--format"
  container = state.fetch("containers")[args[1]] or exit 1
  puts formatted_container(container, args[3])
else
  if args[0, 2] == ["network", "disconnect"]
    network_name, container_name = args[2], args[3]
    network = state.fetch("networks").fetch(network_name)
    container = state.fetch("containers").fetch(container_name)
    network.fetch("containers").delete(container.fetch("id"))
    container.fetch("networks").delete(network_name)
    log.call("MUTATE disconnect #{network_name} #{container_name}")
    save(path, state)
    exit 42 if ENV["INJECT"] == "after_first_disconnect" && container_name.end_with?("-audiobookshelf")
  elsif args[0, 3] == ["network", "rm", args[2]]
    network_name = args[2]
    state.fetch("networks").delete(network_name) or exit 1
    log.call("MUTATE remove #{network_name}")
    save(path, state)
    exit 42 if ENV["INJECT"] == "after_network_removal"
  elsif args[0, 2] == ["network", "create"]
    network_name = args.last
    exit 43 if ENV["INJECT"] == "leaf_removed_network_recovery_failure"
    project_label = args.find { |item| item.start_with?("nas.platform.project=") }.to_s.split("=", 2).last
    state.fetch("networks")[network_name] = {
      "name" => network_name, "driver" => "bridge",
      "labels" => { "nas.platform.purpose" => "media-control", "nas.platform.project" => project_label },
      "containers" => {}
    }
    log.call("MUTATE create #{network_name}")
    save(path, state)
    Process.kill("HUP", Process.ppid) if ENV["INJECT"] == "recovery_create_HUP"
    puts network_name
  elsif args[0, 2] == ["network", "connect"]
    network_name, container_name = args[2], args[3]
    network = state.fetch("networks").fetch(network_name)
    container = state.fetch("containers").fetch(container_name)
    network.fetch("containers")[container.fetch("id")] = { "name" => container_name }
    container.fetch("networks") << network_name unless container.fetch("networks").include?(network_name)
    log.call("MUTATE connect #{network_name} #{container_name}")
    save(path, state)
    if ENV["INJECT"] == "recovery_connect_INT" && container_name.end_with?("-audiobookshelf")
      Process.kill("INT", Process.ppid)
    end
  else
    warn "unsupported fake docker command: #{args.inspect}"
    exit 64
  end
end
