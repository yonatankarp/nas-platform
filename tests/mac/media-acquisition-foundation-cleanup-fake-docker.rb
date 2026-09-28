#!/usr/bin/env ruby
# A fake `docker` for media-acquisition-foundation-cleanup-test.sh: a JSON model
# answering only the cleanup path's calls; mutations logged to FAKE_DOCKER_LOG.
require "fileutils"
require "json"

path = ENV.fetch("FAKE_DOCKER_STATE")
state = JSON.parse(File.read(path))
args = ARGV.dup
log = ->(line) { File.open(ENV.fetch("FAKE_DOCKER_LOG"), "a") { |file| file.puts(line) } }
save = -> { File.write(path, JSON.generate(state)) }

if args[0] == "ps" && args.include?("--format")
  state.fetch("containers").each_value { |item| puts item.fetch("project") }
elsif args[0] == "ps" && args.include?("-aq")
  label = args.fetch(args.index("--filter") + 1).delete_prefix("label=com.docker.compose.project=")
  state.fetch("containers").each { |id, item| puts id if item.fetch("project") == label }
elsif args[0, 2] == ["network", "ls"] && args.include?("--format")
  format = args.fetch(args.index("--format") + 1)
  if format.include?("com.docker.compose.project")
    state.fetch("networks").each_value { |item| puts item.fetch("compose_project", "") }
  else
    purpose = args.each_cons(2).filter_map do |left, right|
      right.delete_prefix("label=nas.platform.purpose=") if left == "--filter" && right.start_with?("label=nas.platform.purpose=")
    end.first
    project = args.each_cons(2).filter_map do |left, right|
      right.delete_prefix("label=nas.platform.project=") if left == "--filter" && right.start_with?("label=nas.platform.project=")
    end.first
    state.fetch("networks").each_value do |item|
      labels = item.fetch("labels")
      puts item.fetch("name") if labels["nas.platform.purpose"] == purpose && labels["nas.platform.project"] == project
    end
  end
elsif args[0, 2] == ["network", "ls"]
  # No Compose-owned network IDs are present in this focused model.
elsif args[0] == "volume"
  # No volumes are present in this focused model.
elsif args[0, 2] == ["network", "inspect"]
  item = state.fetch("networks")[args[2]]
  unless item
    pending = state.delete("recreate_network")
    if pending && pending.fetch("name") == args[2]
      state.fetch("networks")[args[2]] = pending
      save.call
    end
    exit 1
  end
  if args.include?("--format")
    format = args.fetch(args.index("--format") + 1)
    if format.include?("range $key")
      print item.fetch("labels").map { |key, value| "#{key}=#{value}|" }.join
    else
      labels = item.fetch("labels")
      print [item.fetch("name"), item.fetch("driver"),
             "nas.platform.purpose=#{labels['nas.platform.purpose']}",
             "nas.platform.project=#{labels['nas.platform.project']}"].join("|")
    end
  end
elsif args[0, 2] == ["network", "rm"]
  name = args[2]
  removed = state.fetch("networks").delete(name) or exit 1
  state["recreate_network"] = removed if ENV["INJECT"] == "recreate_media_control"
  log.call("MUTATE network-rm #{name}")
  save.call
elsif args[0, 2] == ["rm", "-f"]
  id = args[2]
  state.fetch("containers").delete(id) or exit 1
  log.call("MUTATE container-rm #{id}")
  save.call
elsif args.first == "run"
  mount = args.fetch(args.index("-v") + 1)
  parent = mount.split(":", 2).first
  name = args[-2]
  target = File.join(parent, name)
  abort "unsafe fake cleanup target" unless File.dirname(target) == parent && File.basename(target) == name
  FileUtils.rm_rf(target)
  log.call("MUTATE sandbox-rm #{name}")
else
  warn "unsupported fake docker command: #{args.inspect}"
  exit 64
end
