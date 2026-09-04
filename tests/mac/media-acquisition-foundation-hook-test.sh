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
  'leaf_removal_succeeded=false' \
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

# The fake docker is a 100-line Ruby program that used to arrive here as a
# `cat > ... <<'RUBY'` heredoc. It is media-acquisition-foundation-hook-fake-docker.rb
# now, so sh -n, ruby -c and a reader can all reach it. Resolve it from this
# script's own checkout, never from a tree under inspection.
cp "$repo_dir/tests/mac/media-acquisition-foundation-hook-fake-docker.rb" "$fixture/bin/docker" ||
  fail "media-acquisition-foundation-hook-fake-docker.rb is missing"

cat > "$fixture/bin/rmdir" <<'SH'
#!/bin/sh
[ "${INJECT:-}" = before_leaf_removal_failure ] && exit 42
/bin/rmdir "$@" || exit $?
case ${INJECT:-} in
  after_leaf_forced) exit 42 ;;
  leaf_removed_network_recovery_failure) exit 42 ;;
  after_leaf_HUP) kill -HUP "$PPID" ;;
  after_leaf_INT) kill -INT "$PPID" ;;
  after_leaf_TERM) kill -TERM "$PPID" ;;
  recovery_create_HUP|recovery_connect_INT|recovery_leaf_TERM) exit 42 ;;
esac
SH
cat > "$fixture/bin/mkdir" <<'SH'
#!/bin/sh
printf 'MUTATE mkdir %s\n' "$*" >> "$FAKE_DOCKER_LOG"
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

run_drift_case leaf_removed_network_recovery_failure
[ "$status" -eq 42 ] || fail 'leaf/network recovery case changed the original status'
[ -d "$leaf" ] && [ ! -L "$leaf" ] ||
  fail 'leaf restoration depended on successful network recovery'
grep -q "^MUTATE mkdir $leaf$" "$log" ||
  fail 'removed leaf was not independently restored after network recovery failure'

run_drift_case before_leaf_removal_failure
[ "$status" -eq 42 ] || fail 'pre-removal failure status changed'
assert_restored
if grep -q '^MUTATE mkdir ' "$log"; then
  fail 'failed rmdir caused an unnecessary mkdir for the existing leaf'
fi

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
