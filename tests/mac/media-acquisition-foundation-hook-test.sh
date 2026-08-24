#!/bin/sh
set -eu
set +x

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
drift=$repo_dir/tests/mac/hooks/drift/15-media-acquisition-foundation.sh
verify=$repo_dir/tests/mac/hooks/verify/15-media-acquisition-foundation.sh

fail() {
  printf 'media-acquisition-hook-error: %s\n' "$1" >&2
  exit 1
}

[ -x "$drift" ] && [ -x "$verify" ] || fail 'lifecycle hooks must be executable'
drift_source=$(cat "$drift")
verify_source=$(cat "$verify")

for token in \
  'network=$PLATFORM_PROJECT_NAME-media-control' \
  'audiobookshelf=$PLATFORM_PROJECT_NAME-audiobookshelf' \
  'jellyfin=$PLATFORM_PROJECT_NAME-jellyfin' \
  'leaf=$PLATFORM_MEDIA_ROOT/Media/.acquisition/usenet/movies' \
  'audiobook_disconnect_started=false' \
  'jellyfin_disconnect_started=false' \
  'network_removal_started=false' \
  'leaf_removal_started=false' \
  'trap media_acquisition_recover EXIT' \
  'trap media_acquisition_handle_hup HUP' \
  'trap media_acquisition_handle_int INT' \
  'trap media_acquisition_handle_term TERM' \
  'nas.platform.purpose=media-control' \
  'nas.platform.project=$PLATFORM_PROJECT_NAME' \
  'com.docker.compose.service=audiobookshelf' \
  'com.docker.compose.service=jellyfin' \
  'docker network disconnect "$network" "$audiobookshelf"' \
  'docker network disconnect "$network" "$jellyfin"' \
  'docker network rm "$network"' \
  'rmdir -- "$leaf"'; do
  printf '%s\n' "$drift_source" | grep -Fq "$token" || fail "drift hook omits $token"
done

printf '%s\n' "$drift_source" | grep -Eq 'docker network disconnect[[:space:]]+-f|docker network disconnect[[:space:]]+--force' &&
  fail 'drift hook must not force disconnects'
printf '%s\n' "$drift_source" | grep -Eq 'docker (system|network) prune|docker network (rm|disconnect).*[?*[]' &&
  fail 'drift hook must not prune or use broad network targets'

for token in \
  'platform_verify_media_acquisition_foundation' \
  'platform_media_control_network=$network' \
  'NetworkSettings.Networks' \
  'media_acquisition_foundation' \
  'media_usenet_enabled=false' \
  'media_torrent_enabled=false'; do
  printf '%s\n' "$verify_source" | grep -Fq "$token" || fail "verify hook omits $token"
done
printf '%s\n' "$verify_source" | grep -Eq 'ls[[:space:]]|find[[:space:]]' &&
  fail 'verify hook must not list acquisition contents'

fixture=$(mktemp -d "${TMPDIR:-/tmp}/media-acquisition-hook.XXXXXX")
fixture=$(CDPATH= cd -- "$fixture" && pwd -P)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/bin"

cat > "$fixture/bin/docker" <<'RUBY'
#!/usr/bin/env ruby
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
RUBY

cat > "$fixture/bin/rmdir" <<'SH'
#!/bin/sh
/bin/rmdir "$@" || exit $?
case ${INJECT:-} in
  after_leaf_forced) exit 42 ;;
  after_leaf_HUP) kill -HUP "$PPID" ;;
  after_leaf_INT) kill -INT "$PPID" ;;
  after_leaf_TERM) kill -TERM "$PPID" ;;
  recovery_create_HUP|recovery_connect_INT|recovery_leaf_TERM) exit 42 ;;
esac
SH
cat > "$fixture/bin/mkdir" <<'SH'
#!/bin/sh
/bin/mkdir "$@" || exit $?
[ "${INJECT:-}" = recovery_leaf_TERM ] && kill -TERM "$PPID"
exit 0
SH
chmod 0755 "$fixture/bin/docker" "$fixture/bin/rmdir" "$fixture/bin/mkdir"

initialize_case() {
  case_root=$1
  project=proof
  network=$project-media-control
  audio=$project-audiobookshelf
  jelly=$project-jellyfin
  media_root=$case_root/media
  leaf=$media_root/Media/.acquisition/usenet/movies
  mkdir -p "$leaf"
  chmod 0755 "$leaf"
  state=$case_root/state.json
  log=$case_root/docker.log
  : > "$log"
  ruby -rjson -e '
    project, path = ARGV
    network = "#{project}-media-control"
    readers = %w[audiobookshelf jellyfin].to_h do |reader|
      name = "#{project}-#{reader}"
      [name, {
        "name" => name, "id" => "id-#{reader}",
        "labels" => {
          "com.docker.compose.service" => reader,
          "com.docker.compose.project" => "#{project}-#{reader}"
        },
        "networks" => ["#{project}-#{reader}_default", network]
      }]
    end
    readers["unrelated"] = {
      "name" => "unrelated", "id" => "id-unrelated", "labels" => {}, "networks" => ["unrelated-net"]
    }
    networks = {
      network => {
        "name" => network, "driver" => "bridge",
        "labels" => { "nas.platform.purpose" => "media-control", "nas.platform.project" => project },
        "containers" => {
          "id-audiobookshelf" => { "name" => "#{project}-audiobookshelf" },
          "id-jellyfin" => { "name" => "#{project}-jellyfin" }
        }
      },
      "unrelated-net" => {
        "name" => "unrelated-net", "driver" => "bridge", "labels" => { "owner" => "someone-else" },
        "containers" => { "id-unrelated" => { "name" => "unrelated" } }
      }
    }
    File.write(path, JSON.generate("networks" => networks, "containers" => readers))
  ' "$project" "$state"
}

assert_restored() {
  ruby -rjson -e '
    state = JSON.parse(File.read(ARGV.fetch(0)))
    project = ARGV.fetch(1)
    network = "#{project}-media-control"
    control = state.fetch("networks").fetch(network)
    abort unless control.fetch("driver") == "bridge"
    abort unless control.fetch("labels") == {
      "nas.platform.purpose" => "media-control", "nas.platform.project" => project
    }
    abort unless control.fetch("containers").keys.sort == %w[id-audiobookshelf id-jellyfin]
    %w[audiobookshelf jellyfin].each do |reader|
      actual = state.fetch("containers").fetch("#{project}-#{reader}").fetch("networks").sort
      abort unless actual == ["#{project}-#{reader}_default", network].sort
    end
    unrelated = state.fetch("networks").fetch("unrelated-net")
    abort unless unrelated.fetch("containers").keys == ["id-unrelated"]
  ' "$state" "$project" || {
    printf 'media-acquisition-hook-state: case=%s state=%s log=%s\n' \
      "${inject:-unknown}" "$(cat "$state")" "$(tr '\n' ';' < "$log")" >&2
    fail 'recovery did not restore exact isolated state'
  }
  [ -d "$leaf" ] && [ ! -L "$leaf" ] || fail 'recovery did not restore the real leaf'
  [ "$(find "$leaf" -mindepth 1 -maxdepth 1 -print -quit)" = '' ] || fail 'recovery leaf is not empty'
  [ "$(stat -c '%a' "$leaf" 2>/dev/null || stat -f '%Lp' "$leaf")" = 755 ] || fail 'recovery leaf mode differs'
  [ "$(stat -c '%u' "$leaf" 2>/dev/null || stat -f '%u' "$leaf")" = "$(id -u)" ] || fail 'recovery leaf owner differs'
}

run_drift_case() {
  inject=$1
  case_root=$fixture/$inject
  mkdir "$case_root"
  initialize_case "$case_root"
  hook_under_test=$drift
  if [ "${TRACE_MEDIA_ACQUISITION_HOOK:-0}" = 1 ]; then
    sed 's/^set +x$/set -x/' "$drift" > "$case_root/traced-hook"
    chmod 0755 "$case_root/traced-hook"
    hook_under_test=$case_root/traced-hook
  fi
  set +e
  env PATH="$fixture/bin:$PATH" FAKE_DOCKER_STATE="$state" FAKE_DOCKER_LOG="$log" INJECT="$inject" \
    PLATFORM_PROJECT_NAME="$project" PLATFORM_MEDIA_ROOT="$media_root" \
    ruby -e '
      system(ARGV.fetch(0), out: ARGV.fetch(1), err: ARGV.fetch(2))
      status = $?
      exit(status.signaled? ? 128 + status.termsig : status.exitstatus)
    ' "$hook_under_test" "$case_root/out" "$case_root/err"
  status=$?
  set -e
}

for inject in after_first_disconnect after_network_removal \
    after_leaf_forced after_leaf_HUP after_leaf_INT after_leaf_TERM; do
  run_drift_case "$inject"
  [ "$status" -ne 0 ] || fail "$inject did not preserve failure or signal status"
  assert_restored
  case $inject in
    after_first_disconnect)
      [ "$status" -eq 42 ] || fail 'forced disconnect failure status changed'
      [ "$(grep -c '^MUTATE disconnect ' "$log")" -eq 1 ] || fail 'first-disconnect injection missed its boundary'
      ;;
    after_network_removal)
      [ "$status" -eq 42 ] || fail 'forced network-removal failure status changed'
      grep -qx "MUTATE remove $network" "$log" || fail 'network-removal injection missed its boundary'
      ;;
    after_leaf_forced)
      [ "$status" -eq 42 ] || fail 'forced post-leaf failure status changed'
      grep -qx "MUTATE create $network" "$log" || fail 'post-leaf forced recovery did not recreate the bridge'
      ;;
    after_leaf_HUP)
      [ "$status" -eq 129 ] || fail 'HUP status was not preserved'
      grep -qx "MUTATE create $network" "$log" || fail 'post-leaf HUP recovery did not recreate the bridge'
      ;;
    after_leaf_INT)
      [ "$status" -eq 130 ] || fail 'INT status was not preserved'
      grep -qx "MUTATE create $network" "$log" || fail 'post-leaf INT recovery did not recreate the bridge'
      ;;
    after_leaf_TERM)
      [ "$status" -eq 143 ] || fail 'TERM status was not preserved'
      grep -qx "MUTATE create $network" "$log" || fail 'post-leaf TERM recovery did not recreate the bridge'
      ;;
  esac
done

for inject in recovery_create_HUP recovery_connect_INT recovery_leaf_TERM; do
  run_drift_case "$inject"
  [ "$status" -eq 42 ] || fail "$inject did not preserve the original recovery status"
  assert_restored
  case $inject in
    recovery_create_HUP)
      grep -qx "MUTATE create $network" "$log" || fail 'recovery HUP did not reach network creation'
      ;;
    recovery_connect_INT)
      grep -qx "MUTATE connect $network $audio" "$log" || fail 'recovery INT did not reach reader reconnect'
      ;;
    recovery_leaf_TERM)
      [ -d "$leaf" ] || fail 'recovery TERM did not reach leaf restoration'
      ;;
  esac
done

for deception in extra_endpoint wrong_network_label wrong_reader_name wrong_reader_service wrong_reader_project; do
  case_root=$fixture/$deception
  mkdir "$case_root"
  initialize_case "$case_root"
  ruby -rjson -e '
    path, mutation = ARGV
    state = JSON.parse(File.read(path))
    project = "proof"
    network = state.fetch("networks").fetch("#{project}-media-control")
    case mutation
    when "extra_endpoint"
      network.fetch("containers")["id-unrelated"] = { "name" => "unrelated" }
    when "wrong_network_label"
      network.fetch("labels")["nas.platform.project"] = "proof-lookalike"
    when "wrong_reader_name"
      reader = state.fetch("containers").delete("#{project}-audiobookshelf")
      reader["name"] = "#{project}-audiobookshelf-lookalike"
      state.fetch("containers")[reader.fetch("name")] = reader
      network.fetch("containers").fetch("id-audiobookshelf")["name"] = reader.fetch("name")
    when "wrong_reader_service"
      state.fetch("containers").fetch("#{project}-audiobookshelf")
        .fetch("labels")["com.docker.compose.service"] = "audiobookshelf-lookalike"
    when "wrong_reader_project"
      state.fetch("containers").fetch("#{project}-jellyfin")
        .fetch("labels")["com.docker.compose.project"] = "#{project}-jellyfin-lookalike"
    end
    File.write(path, JSON.generate(state))
  ' "$state" "$deception"
  : > "$log"
  set +e
  env PATH="$fixture/bin:$PATH" FAKE_DOCKER_STATE="$state" FAKE_DOCKER_LOG="$log" INJECT=none \
    PLATFORM_PROJECT_NAME="$project" PLATFORM_MEDIA_ROOT="$media_root" "$drift" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "$deception passed preflight"
  [ ! -s "$log" ] || fail "$deception mutated state before refusal"
done

run_drift_case none
[ "$status" -eq 0 ] || {
  printf 'media-acquisition-hook-normal: status=%s out=%s err=%s\n' \
    "$status" "$(tr '\n' ';' < "$case_root/out")" "$(tr '\n' ';' < "$case_root/err")" >&2
  printf 'media-acquisition-hook-normal-state: %s log=%s\n' \
    "$(cat "$state")" "$(tr '\n' ';' < "$log")" >&2
  fail 'normal drift failed'
}
[ ! -e "$leaf" ] && [ ! -L "$leaf" ] || fail 'normal drift retained the seeded leaf'
ruby -rjson -e '
  state = JSON.parse(File.read(ARGV.fetch(0)))
  abort if state.fetch("networks").key?("proof-media-control")
  abort unless state.fetch("networks").key?("unrelated-net")
' "$state" || fail 'normal drift removed the wrong network'

# Model the normal run_site reconciliation boundary, then perform the same exact
# membership checks as the second verifier invocation.
env PATH="$fixture/bin:$PATH" FAKE_DOCKER_STATE="$state" FAKE_DOCKER_LOG="$log" \
  docker network create --driver bridge --label nas.platform.purpose=media-control \
  --label nas.platform.project="$project" "$network" >/dev/null
env PATH="$fixture/bin:$PATH" FAKE_DOCKER_STATE="$state" FAKE_DOCKER_LOG="$log" \
  docker network connect "$network" "$audio"
env PATH="$fixture/bin:$PATH" FAKE_DOCKER_STATE="$state" FAKE_DOCKER_LOG="$log" \
  docker network connect "$network" "$jelly"
mkdir "$leaf"
chmod 0755 "$leaf"
assert_restored

printf '%s\n' 'media acquisition hook: exact drift, recovery, signal, and reconcile contract holds'
