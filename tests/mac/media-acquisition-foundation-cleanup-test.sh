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

# The fake docker is a 79-line Ruby program that used to arrive here as a
# `cat > ... <<'RUBY'` heredoc. It is
# media-acquisition-foundation-cleanup-fake-docker.rb now, so sh -n, ruby -c and
# a reader can all reach it. Resolve it from this script's own checkout, never
# from a tree under inspection.
cp "$repo_dir/tests/mac/media-acquisition-foundation-cleanup-fake-docker.rb" \
  "$fixture/bin/docker" ||
  fail "media-acquisition-foundation-cleanup-fake-docker.rb is missing"
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
