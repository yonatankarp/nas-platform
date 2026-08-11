#!/bin/sh
set -eu
set +x
umask 077

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd -P)
snapshotter=$test_dir/adoption-snapshot.sh
adoption=$test_dir/adoption.sh
runner=$test_dir/run.sh

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

fixture=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-snapshot-test.XXXXXX")
fixture=$(CDPATH= cd -- "$fixture" && pwd -P)
override_root=$fixture/overrides
cp -R "$test_dir/legacy-overrides" "$override_root"
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  chmod -R u+w "$fixture" 2>/dev/null || true
  find "$fixture" -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir "$fixture" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

ruby - "$adoption" "$runner" <<'RUBY'
adoption = File.read(ARGV.fetch(0))
runner = File.read(ARGV.fetch(1))
raise "snapshot/cutover commands are unavailable" unless
  adoption.match?(/preflight\|render\|legacy-deploy\|legacy-seed\|capture-baseline\|snapshot\|cutover/)
stop_definition = adoption.index("stop_legacy_projects()")
snapshot_branch = adoption.index('[ "$subcommand" = snapshot ]')
stop_call = adoption.index("stop_legacy_projects", snapshot_branch + 1)
publish_call = adoption.index('adoption-snapshot.sh" publish', snapshot_branch)
raise "all legacy projects must stop before publication" unless
  stop_definition && snapshot_branch && stop_call && publish_call && stop_call < publish_call
raise "snapshot stop must not delete volumes" if adoption.match?(/stop[^\n]*--volumes|down[^\n]*--volumes/)
cutover_branch = adoption.index('[ "$subcommand" = cutover ]')
verify_call = adoption.index('adoption-snapshot.sh" verify', cutover_branch)
raise "cutover does not revalidate snapshot" unless cutover_branch && verify_call
runner_cutover = runner.match(/cutover\)\s*\n(?<body>.*?)\n\s*;;/m)
raise "runner cutover is unavailable" unless runner_cutover
body = runner_cutover[:body]
validation = body.index("enable_adoption_mapping")
target = body.index("run_site")
verifier = body.index('verify.sh"')
raise "target ran before snapshot publication" unless validation && target && validation < target
raise "normal verifier is absent after target" unless verifier && target < verifier
mapping = runner.match(/enable_adoption_mapping\(\) \{(?<body>.*?)\n\}/m)
raise "mapping activation omits snapshot validation" unless
  mapping && mapping[:body].include?('adoption.sh" cutover')
legacy = runner.match(/legacy-deploy\)\s*(?<body>.*?)\s*;;/m)
raise "legacy deploy invoked target roles" if legacy && legacy[:body].include?("run_site")
deploy = runner.match(/deploy\)\s*\n(?<body>.*?)\n\s*;;/m)
raise "old adoption deploy behavior remains" if deploy && deploy[:body].include?("adoption-deploy")
RUBY

sandbox=$fixture/nas-platform-mac.AbC123
mkdir -m 0700 "$sandbox"
printf '%s\n%s\n' schema=1 project=nas-platform-mac-abc123 > "$sandbox/.nas-platform-mac-owned"
chmod 0600 "$sandbox/.nas-platform-mac-owned"
mkdir -m 0700 "$sandbox/legacy"

ruby - "$override_root" "$sandbox" <<'RUBY'
require "fileutils"
root, sandbox = ARGV
Dir.glob(File.join(root, "*.yml")).sort.each do |path|
  File.foreach(path) do |line|
    match = line.match(%r{^\s*-\s+\$\{PLATFORM_MAC_SANDBOX:\?\}/(legacy/[^:]+):})
    next unless match
    source = File.join(sandbox, match[1])
    if File.basename(source).include?(".")
      FileUtils.mkdir_p(File.dirname(source), mode: 0o700)
      File.binwrite(source, "fixture:#{match[1]}\n")
      File.chmod(0o640, source)
    else
      FileUtils.mkdir_p(source, mode: 0o700)
      File.binwrite(File.join(source, "state"), "fixture:#{match[1]}\n")
      File.chmod(0o640, File.join(source, "state"))
    end
  end
end
RUBY

baseline=$sandbox/baseline.json
state=$sandbox/report/phase-input.json
mkdir -m 0700 "$sandbox/report"
printf '%s\n' '{"schema":1,"legacy_commit":"0123456789012345678901234567890123456789"}' > "$baseline"
printf '%s\n' '{"lane":"adoption","sandbox_id":"nas-platform-mac.AbC123","git_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","vault_checksum":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","parity_vault_checksum":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","legacy_commit":"0123456789012345678901234567890123456789","project_name":"nas-platform-mac-abc123"}' > "$state"
chmod 0600 "$baseline" "$state"
baseline_before=$(shasum -a 256 "$baseline" | awk '{print $1}')

lock_ready=$fixture/lock-ready
ruby - "$sandbox/.adoption-snapshot.lock" "$lock_ready" <<'RUBY' &
lock = File.open(ARGV.fetch(0), File::RDWR | File::CREAT, 0o600)
lock.flock(File::LOCK_EX)
File.write(ARGV.fetch(1), "ready\n")
sleep 30
RUBY
lock_pid=$!
while [ ! -f "$lock_ready" ]; do sleep 0.01; done
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  fail 'concurrent snapshot writer was accepted'
fi
kill "$lock_pid" 2>/dev/null || true
wait "$lock_pid" 2>/dev/null || true
grep -F 'snapshot lock is held' "$fixture/output" >/dev/null ||
  fail 'concurrent snapshot emitted wrong diagnostic'
[ ! -e "$sandbox/snapshot/pre-cutover" ] || fail 'concurrent writer published a snapshot'

swap_escape=$fixture/snapshot-escape
mkdir "$swap_escape"
if PLATFORM_ADOPTION_SNAPSHOT_SELF_TEST=1 PLATFORM_SNAPSHOT_ESCAPE=$swap_escape \
  PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" self-test-candidate-swap --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'candidate state-directory swap was accepted'
fi
unset PLATFORM_ADOPTION_SNAPSHOT_SELF_TEST PLATFORM_SNAPSHOT_ESCAPE
grep -F 'candidate namespace changed' "$fixture/output" >/dev/null ||
  fail 'candidate state-directory swap did not fire'
[ -z "$(find "$swap_escape" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail 'candidate swap wrote outside the bound snapshot directory'
[ ! -e "$sandbox/snapshot/pre-cutover" ] || fail 'candidate swap published a snapshot'

if PLATFORM_ADOPTION_SNAPSHOT_SELF_TEST=1 PLATFORM_MAC_TMPDIR=$fixture \
  PLATFORM_MAC_SANDBOX=$sandbox "$snapshotter" self-test-post-publish-failure \
  --override-root "$override_root" --baseline "$baseline" --run-state "$state" \
  >"$fixture/output" 2>&1; then
  fail 'post-publication failure was accepted'
fi
grep -F 'forced post-publication failure' "$fixture/output" >/dev/null ||
  fail 'post-publication fault did not fire'
[ ! -e "$sandbox/snapshot/pre-cutover" ] || fail 'failed publication was not rolled back'

PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state"

published=$sandbox/snapshot/pre-cutover
[ -d "$published" ] && [ ! -L "$published" ] || fail 'snapshot was not published as a directory'
[ "$(stat -f '%Lp' "$published" 2>/dev/null || stat -c '%a' "$published")" = 500 ] ||
  fail 'published snapshot is not immutable by mode'
[ -f "$published/inventory.json" ] && [ -f "$published/binding.json" ] ||
  fail 'snapshot metadata is incomplete'
[ "$(shasum -a 256 "$baseline" | awk '{print $1}')" = "$baseline_before" ] ||
  fail 'baseline changed during snapshot'
cmp -s "$baseline" "$published/baseline.json" || fail 'immutable baseline copy differs'
[ "$(stat -f '%Lp' "$published/baseline.json" 2>/dev/null || stat -c '%a' "$published/baseline.json")" = 400 ] ||
  fail 'baseline copy mode differs'

ruby -rjson - "$published/inventory.json" <<'RUBY'
inventory = JSON.parse(File.read(ARGV.fetch(0)))
paths = inventory.fetch("roots").map { |entry| entry.fetch("path") }
raise "inventory does not derive all reviewed bindings" unless paths.length == 32 && paths.uniq.length == paths.length
%w[
  legacy/immich/data legacy/immich/thumbs legacy/immich/encoded-video
  legacy/immich/profile legacy/immich/backups legacy/immich/model-cache legacy/immich/postgres
  legacy/paperless-ngx/redis legacy/paperless-ngx/postgres legacy/paperless-ngx/data
  legacy/paperless-ngx/export legacy/paperless-ngx/tessdata/heb.traineddata
  legacy/paperless-ngx/media legacy/paperless-ngx/consume
].each { |path| raise "coordinated service root missing" unless paths.include?(path) }
raise "inventory is not verified" unless inventory.fetch("verified") == true
RUBY
ruby -rjson -e 'raise unless JSON.parse(File.read(ARGV.fetch(0))).fetch("sandbox_id") == ARGV.fetch(1)' \
  "$published/binding.json" "$(basename -- "$sandbox")" || fail 'snapshot omits report run identity'

PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" verify --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state"
cp -p "$sandbox/legacy/dozzle/data/state" "$fixture/dozzle-state.original"
printf '%s\n' post-cutover-write >> "$sandbox/legacy/dozzle/data/state"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" marker --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'pre-cutover marker accepted changed live state'
fi
post_cutover_marker=$(PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" marker-post-cutover --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state")
[ "$post_cutover_marker" = "$(shasum -a 256 "$published/binding.json" | awk '{print $1}')" ] ||
  fail 'post-cutover marker did not revalidate the immutable publication'
cp -p "$fixture/dozzle-state.original" "$sandbox/legacy/dozzle/data/state"
chmod 0640 "$sandbox/legacy/dozzle/data/state"
published_digest=$(shasum -a 256 "$published/binding.json" | awk '{print $1}')
PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state"
[ "$(shasum -a 256 "$published/binding.json" | awk '{print $1}')" = "$published_digest" ] ||
  fail 'snapshot resume replaced an immutable publication'

printf '%s\n' '# changed reviewed mapping' >> "$override_root/dozzle.yml"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" verify --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'changed reviewed overrides were accepted'
fi
grep -F 'reviewed overrides changed' "$fixture/output" >/dev/null ||
  fail 'changed reviewed overrides emitted wrong diagnostic'
sed -i '' -e '$d' "$override_root/dozzle.yml"

cp "$baseline" "$fixture/baseline.original"
printf '%s\n' changed >> "$baseline"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" verify --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'changed immutable baseline was accepted'
fi
grep -F 'snapshot baseline changed' "$fixture/output" >/dev/null ||
  fail 'changed immutable baseline emitted wrong diagnostic'
cp "$fixture/baseline.original" "$baseline"
chmod 0600 "$baseline"

chmod 0600 "$published/baseline.json"
printf '%s\n' changed >> "$published/baseline.json"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" verify --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'changed snapshot baseline was accepted'
fi
grep -F 'snapshot baseline' "$fixture/output" >/dev/null ||
  fail 'changed snapshot baseline emitted wrong diagnostic'

chmod 0700 "$published"
chmod 0400 "$published/baseline.json"
rm -f "$published/baseline.json"
cp "$baseline" "$published/baseline.json"
chmod 0400 "$published/baseline.json"
chmod 0500 "$published"

state_root=$sandbox/legacy/dozzle/data
mv "$state_root" "$state_root.real"
ln -s "$state_root.real" "$state_root"
chmod -R u+w "$sandbox/snapshot"
rm -rf "$sandbox/snapshot"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'symlinked state root was accepted'
fi
grep -F 'state source is unsafe' "$fixture/output" >/dev/null ||
  fail 'symlinked state emitted wrong diagnostic'
[ ! -e "$sandbox/snapshot/pre-cutover" ] || fail 'failed copy published a partial snapshot'
rm "$state_root"
mv "$state_root.real" "$state_root"

ln -s "$fixture" "$state_root/nested-link"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'nested symlinked state was accepted'
fi
grep -F 'state source is unsafe' "$fixture/output" >/dev/null ||
  fail 'nested symlinked state emitted wrong diagnostic'
[ ! -e "$sandbox/snapshot/pre-cutover" ] || fail 'nested symlink published a partial snapshot'
rm "$state_root/nested-link"

rm -rf "$state_root"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'missing state root was accepted'
fi
grep -F 'state source is unavailable' "$fixture/output" >/dev/null ||
  fail 'missing state emitted wrong diagnostic'
[ ! -e "$sandbox/snapshot/pre-cutover" ] || fail 'missing source published a partial snapshot'

printf '%s\n' 'Adoption snapshot test: coordinated immutable snapshot holds'
