#!/bin/sh
set -eu
set +x
umask 077

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cleanup=$repo_dir/tests/mac/cleanup.sh
source=$(cat "$cleanup")
fixture=$(mktemp -d "${TMPDIR:-/tmp}/media-acquisition-cleanup.XXXXXX")
fixture=$(CDPATH= cd -- "$fixture" && pwd -P)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir "$fixture/bin" "$fixture/sandboxes"
chmod 0700 "$fixture/sandboxes"

fail() {
  printf 'media-acquisition-cleanup-error: %s\n' "$1" >&2
  exit 1
}

cat > "$fixture/bin/docker" <<'RUBY'
#!/usr/bin/env ruby
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
RUBY
chmod 0755 "$fixture/bin/docker"

new_case() {
  label=$1
  network_variant=$2
  sandbox=$(mktemp -d "$fixture/sandboxes/nas-platform-mac.XXXXXX")
  sandbox=$(CDPATH= cd -- "$sandbox" && pwd -P)
  chmod 0700 "$sandbox"
  suffix=${sandbox##*.}
  project_suffix=$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')
  project=nas-platform-mac-$project_suffix
  printf 'schema=1\nproject=%s\n' "$project" > "$sandbox/.nas-platform-mac-owned"
  chmod 0600 "$sandbox/.nas-platform-mac-owned"
  state=$fixture/$label.json
  log=$fixture/$label.log
  : > "$log"
  inject=none
  ruby -rjson -e '
    path, project, variant = ARGV
    exact = "#{project}-media-control"
    name = case variant
           when "bare" then "media-control"
           when "prefix" then "lookalike-#{exact}"
           when "suffix" then "#{exact}-lookalike"
           else exact
           end
    driver = variant == "wrong_driver" ? "overlay" : "bridge"
    labels = {
      "nas.platform.purpose" => "media-control",
      "nas.platform.project" => project
    }
    labels["nas.platform.purpose"] = "lookalike" if variant == "wrong_purpose"
    labels["nas.platform.project"] = "#{project}-lookalike" if variant == "wrong_project"
    networks = {
      name => { "name" => name, "driver" => driver, "labels" => labels },
      "unrelated-network" => {
        "name" => "unrelated-network", "driver" => "bridge", "labels" => { "owner" => "unrelated" }
      }
    }
    containers = {
      "reader-audio" => { "project" => "#{project}-audiobookshelf" },
      "reader-jelly" => { "project" => "#{project}-jellyfin" },
      "unrelated-container" => { "project" => "unrelated-project" }
    }
    File.write(path, JSON.generate("networks" => networks, "containers" => containers))
  ' "$state" "$project" "$network_variant"
}

run_cleanup() {
  set +e
  env PATH="$fixture/bin:$PATH" PLATFORM_MAC_TMPDIR="$fixture/sandboxes" \
    FAKE_DOCKER_STATE="$state" FAKE_DOCKER_LOG="$log" \
    INJECT="$inject" \
    "$cleanup" "$sandbox" >/dev/null 2>"$fixture/$label.err"
  status=$?
  set -e
}

assert_unrelated_preserved() {
  ruby -rjson -e '
    state = JSON.parse(File.read(ARGV.fetch(0)))
    abort unless state.fetch("networks").key?("unrelated-network")
    abort unless state.fetch("containers").key?("unrelated-container")
  ' "$state" || fail "$label changed unrelated resources"
}

new_case valid exact
run_cleanup
[ "$status" -eq 0 ] || {
  printf 'media-acquisition-cleanup-valid: status=%s err=%s log=%s\n' \
    "$status" "$(tr '\n' ';' < "$fixture/$label.err")" "$(tr '\n' ';' < "$log")" >&2
  fail 'valid exact cleanup failed'
}
[ ! -e "$sandbox" ] && [ ! -L "$sandbox" ] || fail 'valid exact cleanup retained its sandbox'
assert_unrelated_preserved

label=recreated_media_control
new_case "$label" exact
inject=recreate_media_control
run_cleanup
[ "$status" -ne 0 ] || fail 'recreated media-control network passed cleanup stability'
[ -d "$sandbox" ] && [ ! -L "$sandbox" ] || fail 'recreated media-control network removed cleanup state'
ruby -rjson -e '
  state = JSON.parse(File.read(ARGV.fetch(0)))
  project = ARGV.fetch(1)
  network = state.fetch("networks").fetch("#{project}-media-control")
  abort unless network.fetch("name") == "#{project}-media-control"
  abort unless network.fetch("driver") == "bridge"
  abort unless network.fetch("labels") == {
    "nas.platform.purpose" => "media-control", "nas.platform.project" => project
  }
' "$state" "$project" || fail 'recreated exact media-control network escaped stability inspection'
assert_unrelated_preserved

for variant in wrong_driver wrong_purpose wrong_project bare prefix suffix; do
  label=$variant
  new_case "$label" "$variant"
  run_cleanup
  [ "$status" -ne 0 ] || fail "$variant deception passed cleanup"
  [ -d "$sandbox" ] && [ ! -L "$sandbox" ] || fail "$variant deception removed cleanup state"
  [ ! -s "$log" ] || fail "$variant deception mutated resources before refusal"
  assert_unrelated_preserved
done

label=empty_project
new_case "$label" exact
printf 'schema=1\nproject=\n' > "$sandbox/.nas-platform-mac-owned"
run_cleanup
[ "$status" -ne 0 ] && [ ! -s "$log" ] || fail 'empty project mutated resources'

label=symlink_path
new_case "$label" exact
alias_path=$fixture/sandboxes/nas-platform-mac.alias
ln -s "$sandbox" "$alias_path"
set +e
env PATH="$fixture/bin:$PATH" PLATFORM_MAC_TMPDIR="$fixture/sandboxes" \
  FAKE_DOCKER_STATE="$state" FAKE_DOCKER_LOG="$log" "$cleanup" "$alias_path" >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] && [ ! -s "$log" ] && [ -d "$sandbox" ] || fail 'symlink cleanup path mutated state'

label=symlink_state
new_case "$label" exact
marker_target=$fixture/symlink-state-marker
mv "$sandbox/.nas-platform-mac-owned" "$marker_target"
ln -s "$marker_target" "$sandbox/.nas-platform-mac-owned"
run_cleanup
[ "$status" -ne 0 ] && [ ! -s "$log" ] && [ -d "$sandbox" ] || fail 'symlink cleanup state mutated resources'

for token in \
  'media_acquisition_cleanup_network=$mac_project-media-control' \
  'nas.platform.purpose=media-control' \
  'nas.platform.project=$mac_project' \
  'docker network rm "$media_acquisition_cleanup_network"'; do
  printf '%s\n' "$source" | grep -Fq "$token" || fail "cleanup omits $token"
done
printf '%s\n' "$source" | grep -Eq 'docker (system|network) prune' && fail 'cleanup must not prune'
printf '%s\n' "$source" | grep -Fq 'docker network disconnect' && fail 'cleanup must not disconnect broad endpoints'
printf '%s\n' "$source" | grep -Eq 'media_acquisition_cleanup_network=.*media-control$' ||
  fail 'cleanup network must be project-derived'

printf '%s\n' 'media acquisition cleanup: two-phase exact-network safety holds'
