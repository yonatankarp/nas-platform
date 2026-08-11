#!/bin/sh
set -eu
set +x
umask 077

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd -P)
snapshotter=$test_dir/adoption-snapshot.sh
adoption=$test_dir/adoption.sh
runner=$test_dir/run.sh

if grep -Eq 'Dir\.(for_fd|fchdir)' "$snapshotter"; then
  printf '%s\n' 'adoption snapshot uses unavailable Ruby directory descriptor APIs' >&2
  exit 1
fi
if grep -Eq 'Dir\.(for_fd|fchdir)' "$test_dir/adoption-container-attest.sh"; then
  printf '%s\n' 'adoption attester uses unavailable Ruby directory descriptor APIs' >&2
  exit 1
fi

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

mode() {
  ruby -e 'puts((File.lstat(ARGV.fetch(0)).mode & 0o777).to_s(8))' "$1"
}

blocks() {
  ruby -e 'puts File.stat(ARGV.fetch(0)).blocks' "$1"
}

size() {
  ruby -e 'puts File.stat(ARGV.fetch(0)).size' "$1"
}

owner() {
  ruby -e 's = File.stat(ARGV.fetch(0)); puts "#{s.uid}:#{s.gid}"' "$1"
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
verify_call = adoption.index('adoption-snapshot.sh" begin-cutover', cutover_branch)
raise "cutover does not atomically record strict snapshot validation" unless cutover_branch && verify_call
execute_phase = runner.index("execute_phase()")
runner_cutover = runner[execute_phase..].match(/cutover\)\s*\n(?<body>.*?)\n\s*;;/m) if execute_phase
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
run_site = runner.match(/run_site\(\) \{(?<body>.*?)\n\}/m)
raise "run_site does not fail closed through container attestation" unless
  run_site && run_site[:body].include?("adoption-container-attest.sh") &&
  run_site[:body].include?('return "$run_site_status"')
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
# Exercise the file-bind attestation path with a realistic payload that exceeds
# the tiny fixed-size directory sentinel bound.
ruby -e 'File.binwrite(ARGV.fetch(0), "ocr-model\n" * 1024)' \
  "$sandbox/legacy/paperless-ngx/tessdata/heb.traineddata"

baseline=$sandbox/baseline.json
report_root=$sandbox.reports
state=$report_root/phase-input.json
mkdir -m 0700 "$report_root"
printf 'schema=1\nsandbox=%s\n' "$(basename -- "$sandbox")" \
  > "$report_root/.nas-platform-mac-report-owned"
chmod 0600 "$report_root/.nas-platform-mac-report-owned"
printf '%s\n' '{"schema":1,"legacy_commit":"0123456789012345678901234567890123456789"}' > "$baseline"
printf '%s\n' '{"lane":"adoption","sandbox_id":"nas-platform-mac.AbC123","git_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","vault_checksum":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","parity_vault_checksum":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","legacy_commit":"0123456789012345678901234567890123456789","project_name":"nas-platform-mac-abc123"}' > "$state"
chmod 0600 "$baseline" "$state"
baseline_before=$(shasum -a 256 "$baseline" | awk '{print $1}')
if [ "$(uname -s)" = Darwin ] && command -v xattr >/dev/null 2>&1; then
  xattr -cr "$sandbox"
fi

archive_gid=$(id -G | tr ' ' '\n' | awk -v primary="$(id -g)" '$1 != primary { print; exit }')
if [ -n "$archive_gid" ]; then
  printf '%s\n' archive-ownership > "$sandbox/legacy/dozzle/data/owned-by-secondary-group"
  chown "$(id -u):$archive_gid" "$sandbox/legacy/dozzle/data"
  chown "$(id -u):$archive_gid" "$sandbox/legacy/dozzle/data/owned-by-secondary-group"
fi

cp "$override_root/audiobookshelf.yml" "$fixture/audiobookshelf-mode.original"
ruby -e '
  path = ARGV.fetch(0)
  source = File.binread(path)
  abort unless source.scan(":/audiobooks:ro").length == 1
  File.binwrite(path, source.sub(":/audiobooks:ro", ":/audiobooks:rw"))
' "$override_root/audiobookshelf.yml"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'read-only mapping changed to read-write was accepted'
fi
grep -F 'legacy adoption mapping differs from committed policy' "$fixture/output" >/dev/null ||
  fail 'mapping access-mode drift was not rejected by committed policy'
mv "$fixture/audiobookshelf-mode.original" "$override_root/audiobookshelf.yml"

cp "$override_root/dozzle.yml" "$fixture/dozzle-policy.original"
ruby -e '
  path = ARGV.fetch(0)
  source = File.binread(path)
  needle = "      - ${PLATFORM_MAC_SANDBOX:?}/legacy/dozzle/data:/data\n"
  abort unless source.scan(needle).length == 1
  File.binwrite(path, source.sub(needle, needle + "      - ${PLATFORM_MAC_SANDBOX:?}/legacy/dozzle/extra:/extra\n"))
' "$override_root/dozzle.yml"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'valid extra source outside the committed 32-source policy was accepted'
fi
grep -F 'legacy adoption mapping differs from committed policy' "$fixture/output" >/dev/null ||
  fail 'extra valid source was not rejected by committed policy'
mv "$fixture/dozzle-policy.original" "$override_root/dozzle.yml"

paperless_model=$sandbox/legacy/paperless-ngx/tessdata/heb.traineddata
cp -p "$paperless_model" "$fixture/paperless-model.original"
ruby -e 'File.truncate(ARGV.fetch(0), 64 * 1024 * 1024 + 1)' "$paperless_model"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'oversized file-bind attestation was accepted'
fi
grep -F 'file mount attestation exceeds the accepted size' "$fixture/output" >/dev/null ||
  fail 'oversized file-bind attestation emitted wrong diagnostic'
mv "$fixture/paperless-model.original" "$paperless_model"

durability_shim=$fixture/durability-fault.rb
cat > "$durability_shim" <<'RUBY'
trace = TracePoint.new(:end) do |event|
  next unless event.self.name == "SnapshotDurability"

  trace.disable
  singleton = event.self.singleton_class
  singleton.alias_method(:original_sync_for_fault_test, :sync)
  singleton.define_method(:sync) do |descriptor, label|
    if label == ENV["PLATFORM_DURABILITY_FAULT_LABEL"]
      File.write(ENV.fetch("PLATFORM_DURABILITY_FAULT_MARKER"), "fired\n")
      raise Errno::EIO, "forced directory fsync failure"
    end
    original_sync_for_fault_test(descriptor, label)
  end
end
trace.enable
RUBY
for durability_label in snapshot-parent-entry snapshot-nested-directory-entry; do
  durability_marker=$fixture/durability-$durability_label
  if RUBYOPT="-r$durability_shim" \
    PLATFORM_DURABILITY_FAULT_LABEL=$durability_label \
    PLATFORM_DURABILITY_FAULT_MARKER=$durability_marker \
    PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
    "$snapshotter" publish --override-root "$override_root" \
    --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
    fail "$durability_label fsync failure was accepted"
  fi
  [ -f "$durability_marker" ] || fail "$durability_label fsync fault did not fire"
  [ ! -e "$sandbox/snapshot/pre-cutover" ] || fail "$durability_label fault published a snapshot"
  if [ "$durability_label" = snapshot-parent-entry ]; then
    [ ! -e "$sandbox/snapshot" ] || fail 'top-level fsync fault left an uncommitted snapshot directory'
  fi
done

conflicting_sentinel=$sandbox/legacy/audiobookshelf/metadata/.nas-platform-adoption-root-sentinel
printf '%s\n' conflicting > "$conflicting_sentinel"
chmod 0444 "$conflicting_sentinel"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'conflicting sentinel was accepted'
fi
[ ! -e "$sandbox/legacy/audiobookshelf/config/.nas-platform-adoption-root-sentinel" ] ||
  fail 'partial sentinel installation was not rolled back'
[ "$(cat "$conflicting_sentinel")" = conflicting ] ||
  fail 'conflicting user sentinel was modified during rollback'
chmod 0600 "$conflicting_sentinel"
rm "$conflicting_sentinel"

sentinel_swap_shim=$fixture/sentinel-cleanup-swap.rb
cat > "$sentinel_swap_shim" <<'RUBY'
trace = TracePoint.new(:end) do |event|
  next unless event.self.name == "SnapshotFileSystem"
  trace.disable
  singleton = event.self.singleton_class
  singleton.alias_method(:original_openat_for_sentinel_cleanup_test, :openat)
  singleton.define_method(:openat) do |parent, name, flags, permissions|
    if name == ".nas-platform-adoption-root-sentinel"
      @sentinel_opens = @sentinel_opens.to_i + 1
      if @sentinel_opens == 3
        path = ENV.fetch("PLATFORM_SENTINEL_REPLACEMENT_TARGET")
        File.chmod(0o600, path)
        File.binwrite(path, "replacement sentinel\n")
        File.chmod(0o444, path)
      end
    end
    original_openat_for_sentinel_cleanup_test(parent, name, flags, permissions)
  end
end
trace.enable
RUBY
printf '%s\n' conflicting > "$conflicting_sentinel"
chmod 0444 "$conflicting_sentinel"
replacement_sentinel=$sandbox/legacy/audiobookshelf/config/.nas-platform-adoption-root-sentinel
if RUBYOPT="-r$sentinel_swap_shim" \
  PLATFORM_SENTINEL_REPLACEMENT_TARGET="$replacement_sentinel" \
  PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'sentinel cleanup replacement race was accepted'
fi
[ "$(cat "$replacement_sentinel")" = 'replacement sentinel' ] ||
  fail 'cleanup deleted a concurrently replaced sentinel'
chmod 0600 "$replacement_sentinel" "$conflicting_sentinel"
rm "$replacement_sentinel" "$conflicting_sentinel"

ln "$sandbox/legacy/dozzle/data/state" "$sandbox/legacy/dozzle/data/state-hardlink"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" publish --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'hardlinked state topology was silently flattened'
fi
grep -F 'hardlinked state is outside the accepted archive class' "$fixture/output" >/dev/null ||
  fail "hardlinked state emitted wrong archive diagnostic: $(cat "$fixture/output"); $(xattr -lr "$sandbox")"
rm "$sandbox/legacy/dozzle/data/state-hardlink"

archive_feature_file=$sandbox/legacy/dozzle/data/archive-features
printf archive-metadata > "$archive_feature_file"
if command -v xattr >/dev/null 2>&1; then
  xattr -w com.nas-platform.archive-fidelity exact "$archive_feature_file"
fi
if [ "$(uname -s)" = Darwin ]; then
  chmod +a "user:$(id -un) allow read" "$archive_feature_file"
  if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
    "$snapshotter" publish --override-root "$override_root" \
    --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
    fail 'ACL state was accepted without verifiable inventory metadata'
  fi
  grep -F 'access control lists are outside the accepted archive class' "$fixture/output" >/dev/null ||
    fail 'ACL state emitted wrong archive diagnostic'
  chmod -N "$archive_feature_file"
  chflags hidden "$archive_feature_file"
  if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
    "$snapshotter" publish --override-root "$override_root" \
    --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
    fail 'file-flag state was accepted without verifiable inventory metadata'
  fi
  grep -F 'file flags are outside the accepted archive class' "$fixture/output" >/dev/null ||
    fail 'file-flag state emitted wrong archive diagnostic'
  chflags nohidden "$archive_feature_file"
fi
if [ "$(uname -s)" = Darwin ]; then
  mkfile -n 8m "$archive_feature_file"
  printf x | dd of="$archive_feature_file" bs=1 seek=8388607 conv=notrunc 2>/dev/null
else
  dd if=/dev/zero of="$archive_feature_file" bs=1 count=1 seek=8388607 2>/dev/null
  if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
    "$snapshotter" publish --override-root "$override_root" \
    --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
    fail 'sparse state was accepted without portable archive support'
  fi
  grep -F 'special state metadata requires macOS archive support' "$fixture/output" >/dev/null ||
    fail 'sparse state emitted wrong archive diagnostic'
  printf archive-metadata > "$archive_feature_file"
fi
source_sparse_blocks=$(blocks "$archive_feature_file")
source_sparse_size=$(size "$archive_feature_file")
sparse_supported=false
[ $((source_sparse_blocks * 512)) -ge "$source_sparse_size" ] || sparse_supported=true

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
[ "$(mode "$published")" = 500 ] ||
  fail 'published snapshot is not immutable by mode'
[ -f "$published/inventory.json" ] && [ -f "$published/binding.json" ] ||
  fail 'snapshot metadata is incomplete'
[ "$(shasum -a 256 "$baseline" | awk '{print $1}')" = "$baseline_before" ] ||
  fail 'baseline changed during snapshot'
cmp -s "$baseline" "$published/baseline.json" || fail 'immutable baseline copy differs'
[ "$(mode "$published/baseline.json")" = 400 ] ||
  fail 'baseline copy mode differs'

challenge_fault_shim=$fixture/challenge-handoff-fault.rb
cat > "$challenge_fault_shim" <<'RUBY'
trace = TracePoint.new(:end) do |event|
  next unless event.self.name == "ChallengeFS"

  trace.disable
  singleton = event.self.singleton_class
  singleton.alias_method(:original_futimens_for_handoff_test, :futimens)
  singleton.define_method(:futimens) do |descriptor, times|
    result = original_futimens_for_handoff_test(descriptor, times)
    if ENV.delete("PLATFORM_CHALLENGE_HANDOFF_FAULT")
      File.binwrite(ENV.fetch("PLATFORM_CHALLENGE_HANDOFF_MARKER"), "fired\n")
      ENV["PLATFORM_CHALLENGE_HANDOFF_MODE"] == "signal" ?
        Process.kill("TERM", Process.pid) : raise("forced pre-handoff failure")
    end
    result
  end
end
trace.enable
RUBY
challenge_source=legacy/audiobookshelf/config
challenge_file=$sandbox/$challenge_source/.nas-platform-adoption-root-sentinel
challenge_digest=$(shasum -a 256 "$challenge_file" | awk '{print $1}')
for challenge_mode in exception signal; do
  challenge_before=$(ruby -e 's=File.stat(ARGV.fetch(0)); puts((s.mtime.to_r*1_000_000_000).to_i)' "$challenge_file")
  challenge_journal=$report_root/challenge-$challenge_mode.json
  challenge_marker=$fixture/challenge-$challenge_mode-fired
  if RUBYOPT="-r$challenge_fault_shim" PLATFORM_CHALLENGE_HANDOFF_FAULT=1 \
    PLATFORM_CHALLENGE_HANDOFF_MODE=$challenge_mode \
    PLATFORM_CHALLENGE_HANDOFF_MARKER=$challenge_marker \
    ruby "$test_dir/adoption-mount-challenge.rb" prepare "$sandbox" \
    "$challenge_source" sentinel "$challenge_digest" "$challenge_journal" \
    >"$fixture/output" 2>&1; then
    fail "$challenge_mode before challenge-token handoff was accepted"
  fi
  [ -f "$challenge_marker" ] ||
    { cat "$fixture/output" >&2; fail "$challenge_mode before challenge-token handoff did not fire"; }
  challenge_after=$(ruby -e 's=File.stat(ARGV.fetch(0)); puts((s.mtime.to_r*1_000_000_000).to_i)' "$challenge_file")
  [ "$challenge_after" = "$challenge_before" ] ||
    fail "$challenge_mode before token handoff did not restore source metadata"
  [ ! -e "$challenge_journal" ] || fail "$challenge_mode before token handoff retained its journal"
done
if [ -n "$archive_gid" ]; then
  source_owner=$(owner "$sandbox/legacy/dozzle/data/owned-by-secondary-group")
  snapshot_owner=$(owner "$published/state/legacy/dozzle/data/owned-by-secondary-group")
  [ "$snapshot_owner" = "$source_owner" ] || fail 'snapshot did not preserve numeric archive ownership'
  source_directory_owner=$(owner "$sandbox/legacy/dozzle/data")
  snapshot_directory_owner=$(owner "$published/state/legacy/dozzle/data")
  [ "$snapshot_directory_owner" = "$source_directory_owner" ] ||
    fail 'snapshot did not preserve numeric directory ownership'
fi
snapshot_feature_file=$published/state/legacy/dozzle/data/archive-features
snapshot_sparse_blocks=$(blocks "$snapshot_feature_file")
if [ "$sparse_supported" = true ]; then
  [ "$snapshot_sparse_blocks" -le "$source_sparse_blocks" ] || fail 'snapshot expanded sparse state'
fi
if [ "$(uname -s)" = Darwin ] && command -v xattr >/dev/null 2>&1; then
  [ "$(xattr -p com.nas-platform.archive-fidelity "$snapshot_feature_file")" = exact ] ||
    fail 'snapshot did not preserve extended attributes'
fi

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
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" marker-post-cutover --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'post-cutover marker was available before strict cutover validation'
fi
grep -F 'cutover transition is unavailable' "$fixture/output" >/dev/null ||
  fail 'missing cutover transition emitted wrong diagnostic'
cp -p "$sandbox/legacy/dozzle/data/state" "$fixture/pre-cutover-state.original"
printf '%s\n' changed-before-strict-validation >> "$sandbox/legacy/dozzle/data/state"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" begin-cutover --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'strict cutover validation accepted changed live state'
fi
[ ! -e "$sandbox/snapshot/cutover-started.json" ] ||
  fail 'cutover transition was set before strict validation passed'
cp -p "$fixture/pre-cutover-state.original" "$sandbox/legacy/dozzle/data/state"
cutover_marker=$(PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" begin-cutover --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state")
[ "$cutover_marker" = "$(shasum -a 256 "$published/binding.json" | awk '{print $1}')" ] ||
  fail 'strict cutover transition did not bind the snapshot'
baseline_binding=$(PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" baseline-binding --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state")
ruby -rjson -rdigest -e '
  value = JSON.parse(ARGV.fetch(0))
  raise unless value.keys.sort == %w[baseline_sha256 binding_sha256]
  raise unless value.fetch("binding_sha256") == Digest::SHA256.file(ARGV.fetch(1)).hexdigest
  raise unless value.fetch("baseline_sha256") == Digest::SHA256.file(ARGV.fetch(2)).hexdigest
' "$baseline_binding" "$published/binding.json" "$published/baseline.json" ||
  fail 'baseline binding output differs from immutable publication'
rollback_binding=$(PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" rollback-binding --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state")
ruby -rjson -rdigest -e '
  value = JSON.parse(ARGV.fetch(0))
  binding = JSON.parse(File.binread(ARGV.fetch(1)))
  raise unless value.keys.sort == %w[baseline_sha256 binding_sha256 git_revision legacy_commit]
  raise unless value.fetch("binding_sha256") == Digest::SHA256.file(ARGV.fetch(1)).hexdigest
  raise unless value.fetch("baseline_sha256") == Digest::SHA256.file(ARGV.fetch(2)).hexdigest
  raise unless value.fetch("git_revision") == binding.fetch("git_revision")
  raise unless value.fetch("legacy_commit") == binding.fetch("legacy_commit")
' "$rollback_binding" "$published/binding.json" "$published/baseline.json" ||
  fail 'rollback binding output differs from immutable publication'
rollback_sandbox=$(mktemp -d "$fixture/nas-platform-mac.XXXXXX")
rollback_sandbox=$(CDPATH= cd -- "$rollback_sandbox" && pwd -P)
chmod 0700 "$rollback_sandbox"
rollback_suffix=${rollback_sandbox##*.}
rollback_project=nas-platform-mac-$(printf '%s' "$rollback_suffix" | tr '[:upper:]' '[:lower:]')
printf 'schema=1\nproject=%s\nnamespace=rollback\nsource_project=nas-platform-mac-abc123\nsnapshot_binding=%s\n' \
  "$rollback_project" "$cutover_marker" > "$rollback_sandbox/.nas-platform-mac-owned"
chmod 0600 "$rollback_sandbox/.nas-platform-mac-owned"
restored_marker=$(PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  PLATFORM_ADOPTION_ROLLBACK_ROOT=$rollback_sandbox \
  PLATFORM_ADOPTION_ROLLBACK_PROJECT=$rollback_project \
  "$snapshotter" restore --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state")
[ "$restored_marker" = "$cutover_marker" ] || fail 'rollback restore marker differs'
cmp -s "$published/baseline.json" "$rollback_sandbox/pre-cutover-baseline.json" ||
  fail 'rollback restore baseline differs'
ruby -rjson -rdigest -e '
  inventory = JSON.parse(File.read(ARGV.fetch(0)))
  inventory.fetch("entries").select { |entry| entry.fetch("type") == "file" }.each do |entry|
    restored = File.join(ARGV.fetch(1), entry.fetch("path"))
    raise unless File.file?(restored) && !File.symlink?(restored)
    raise unless Digest::SHA256.file(restored).hexdigest == entry.fetch("sha256")
  end
' "$published/inventory.json" "$rollback_sandbox" || fail 'rollback restored state differs'
transition=$sandbox/snapshot/cutover-started.json
[ -f "$transition" ] && [ ! -L "$transition" ] || fail 'cutover transition was not published safely'
[ "$(mode "$transition")" = 400 ] ||
  fail 'cutover transition mode differs'
cp -p "$sandbox/legacy/dozzle/data/state" "$fixture/dozzle-state.original"
simulate_failed_target_and_verifier() {
  printf '%s\n' post-cutover-write >> "$sandbox/legacy/dozzle/data/state"
  return 23
}
if simulate_failed_target_and_verifier; then
  fail 'simulated cutover verifier unexpectedly passed'
fi
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" marker --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'pre-cutover marker accepted changed live state'
fi
post_cutover_marker=$(PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" begin-cutover --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state")
[ "$post_cutover_marker" = "$(shasum -a 256 "$published/binding.json" | awk '{print $1}')" ] ||
  fail 'failed cutover retry did not revalidate the immutable publication'
chmod 0600 "$transition"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" begin-cutover --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'writable cutover transition was accepted'
fi
chmod 0400 "$transition"
cp -p "$transition" "$fixture/cutover-transition.original"
chmod 0600 "$transition"
printf '%s\n' '{}' > "$transition"
chmod 0400 "$transition"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" begin-cutover --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'forged cutover transition was accepted'
fi
chmod 0600 "$transition"
cp -p "$fixture/cutover-transition.original" "$transition"
mv "$transition" "$fixture/cutover-transition.held"
ln -s "$published/binding.json" "$transition"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" begin-cutover --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'symlinked cutover transition was accepted'
fi
rm "$transition"
mv "$fixture/cutover-transition.held" "$transition"
transition_swap_shim=$fixture/transition-swap.rb
cat > "$transition_swap_shim" <<'RUBY'
trace = TracePoint.new(:end) do |event|
  next unless event.self.name == "SnapshotFileSystem"

  trace.disable
  singleton = event.self.singleton_class
  singleton.alias_method(:original_openat_for_transition_test, :openat)
  singleton.define_method(:openat) do |parent, name, flags, permissions|
    unless name == "cutover-started.json" && ENV["PLATFORM_TRANSITION_SWAP_ARMED"] == "1"
      next original_openat_for_transition_test(parent, name, flags, permissions)
    end

    ENV["PLATFORM_TRANSITION_SWAP_ARMED"] = "0"
    target = ENV.fetch("PLATFORM_TRANSITION_SWAP_TARGET")
    held = ENV.fetch("PLATFORM_TRANSITION_SWAP_HELD")
    replacement = ENV.fetch("PLATFORM_TRANSITION_SWAP_REPLACEMENT")
    File.rename(target, held)
    File.rename(replacement, target)
    descriptor = original_openat_for_transition_test(parent, name, flags, permissions)
    File.rename(target, replacement)
    File.rename(held, target)
    File.write(ENV.fetch("PLATFORM_TRANSITION_SWAP_MARKER"), "fired\n")
    descriptor
  end
end
trace.enable
RUBY
printf '%s\n' '{}' > "$fixture/transition-race-replacement"
chmod 0400 "$fixture/transition-race-replacement"
if RUBYOPT="-r$transition_swap_shim" PLATFORM_TRANSITION_SWAP_ARMED=1 \
  PLATFORM_TRANSITION_SWAP_TARGET="$transition" \
  PLATFORM_TRANSITION_SWAP_HELD="$fixture/transition-race-held" \
  PLATFORM_TRANSITION_SWAP_REPLACEMENT="$fixture/transition-race-replacement" \
  PLATFORM_TRANSITION_SWAP_MARKER="$fixture/transition-race-fired" \
  PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" marker-post-cutover --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'cutover transition swap race was accepted'
fi
[ -f "$fixture/transition-race-fired" ] || fail 'cutover transition swap race did not fire'
[ -f "$transition" ] && [ ! -L "$transition" ] || fail 'cutover transition race escaped its binding'

attestation_swap_shim=$fixture/attestation-binding-swap.rb
cat > "$attestation_swap_shim" <<'RUBY'
count = 0
trace = TracePoint.new(:end) do |event|
  next unless event.self.name == "SnapshotFileSystem"
  trace.disable
  singleton = event.self.singleton_class
  singleton.alias_method(:original_openat_for_attestation_test, :openat)
  singleton.define_method(:openat) do |parent, name, flags, permissions|
    count += 1 if name == "attestations.json"
    if count == 3
      target = ENV.fetch("PLATFORM_ATTESTATION_BINDING_TARGET")
      publication = File.dirname(target)
      File.chmod(0o700, publication)
      File.rename(target, ENV.fetch("PLATFORM_ATTESTATION_BINDING_HELD"))
      File.rename(ENV.fetch("PLATFORM_ATTESTATION_BINDING_REPLACEMENT"), target)
      File.chmod(0o500, publication)
      File.binwrite(ENV.fetch("PLATFORM_ATTESTATION_BINDING_MARKER"), "fired\n")
      count += 1
    end
    original_openat_for_attestation_test(parent, name, flags, permissions)
  end
end
trace.enable
RUBY
printf '%s\n' '{}' > "$fixture/attestation-binding-replacement"
chmod 0400 "$fixture/attestation-binding-replacement"
if RUBYOPT="-r$attestation_swap_shim" \
  PLATFORM_ATTESTATION_BINDING_TARGET="$published/binding.json" \
  PLATFORM_ATTESTATION_BINDING_HELD="$fixture/attestation-binding-held" \
  PLATFORM_ATTESTATION_BINDING_REPLACEMENT="$fixture/attestation-binding-replacement" \
  PLATFORM_ATTESTATION_BINDING_MARKER="$fixture/attestation-binding-race-fired" \
  PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" attestations --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'binding swap before attestation emission was accepted'
fi
[ -f "$fixture/attestation-binding-race-fired" ] ||
  { cat "$fixture/output" >&2; fail 'binding swap before attestation emission did not fire'; }
grep -F 'snapshot binding changed before attestation emit' "$fixture/output" >/dev/null ||
  fail 'binding swap before attestation emission emitted wrong diagnostic'
chmod 0700 "$published"
mv "$published/binding.json" "$fixture/attestation-binding-replacement.used"
mv "$fixture/attestation-binding-held" "$published/binding.json"
chmod 0500 "$published"

fake_docker_dir=$fixture/fake-docker
mkdir "$fake_docker_dir"
cat > "$fake_docker_dir/docker" <<'RUBY'
#!/usr/bin/env ruby
require "json"
require "fileutils"
records = JSON.parse(File.binread(ENV.fetch("PLATFORM_FAKE_ATTESTATIONS")))
case ARGV.shift
when "ps"
  project = ARGV.join(" ")[/com[.]docker[.]compose[.]project=([^ ]+)/, 1]
  service = ARGV.join(" ")[/com[.]docker[.]compose[.]service=([^ ]+)/, 1]
  selected = records.select { |entry| "#{ENV.fetch('PLATFORM_PROJECT_NAME')}-#{entry['project_suffix']}" == project }
  selected.select! { |entry| entry["target_compose_service"] == service } if service
  puts selected.map { |entry| "#{project}__#{entry['target_compose_service']}" }.uniq
when "inspect"
  id = ARGV.last
  project, service = id.split("__", 2)
  mounts = records.select do |entry|
    "#{ENV.fetch('PLATFORM_PROJECT_NAME')}-#{entry['project_suffix']}" == project &&
      entry["target_compose_service"] == service
  end.map do |entry|
    { "Source" => File.join(ENV.fetch("PLATFORM_ADOPTION_ROOT"), entry["source"]),
      "Destination" => entry["target"], "RW" => entry["access"] == "rw" }
  end
  puts JSON.generate(mounts)
when "cp"
  specification, destination = ARGV
  id, path = specification.split(":", 2)
  project, service = id.split("__", 2)
  entry = records.find do |candidate|
    "#{ENV.fetch('PLATFORM_PROJECT_NAME')}-#{candidate['project_suffix']}" == project &&
      candidate["target_compose_service"] == service && candidate["container_path"] == path
  end or abort "missing fake cp source"
  if ENV["PLATFORM_FAKE_CP_LOG"]
    File.open(ENV.fetch("PLATFORM_FAKE_CP_LOG"), "a") do |file|
      file.puts([project, service, path].join("\t"))
    end
  end
  if ENV["PLATFORM_FAKE_SWAP"] == "copied" && !File.exist?(ENV.fetch("PLATFORM_FAKE_SWAP_MARKER"))
    FileUtils.cp(ENV.fetch("PLATFORM_FAKE_COPIED_SENTINEL"), destination, preserve: true)
    File.binwrite(ENV.fetch("PLATFORM_FAKE_SWAP_MARKER"), "fired\n")
  elsif ENV["PLATFORM_FAKE_SWAP"] == "symlink"
    File.symlink(ENV.fetch("PLATFORM_FAKE_ESCAPE"), destination)
    exit 0
  elsif ENV["PLATFORM_FAKE_SWAP"] == "directory"
    Dir.mkdir(destination)
  elsif ENV["PLATFORM_FAKE_SWAP"] == "oversize"
    File.binwrite(destination, "x" * 257)
  elsif ENV["PLATFORM_FAKE_SWAP"] == "1"
    ENV["PLATFORM_FAKE_SWAP"] = "0"
    File.binwrite(destination, "x" * entry.fetch("size"))
  else
    source_path = File.join(ENV.fetch("PLATFORM_ADOPTION_ROOT"), entry["source"])
    source_path = File.join(source_path, ".nas-platform-adoption-root-sentinel") if entry["kind"] == "sentinel"
    FileUtils.cp(source_path, destination, preserve: true)
  end
  File.chmod(0o444, destination)
when "stop"
  File.open(ENV.fetch("PLATFORM_FAKE_STOP_LOG"), "a") { |file| file.puts(ARGV) }
else
  abort "unexpected fake docker command"
end
RUBY
chmod 0755 "$fake_docker_dir/docker"
hostile_report=$fixture/hostile.reports
mkdir -m 0700 "$hostile_report"
printf 'schema=1\nsandbox=%s\n' "$(basename -- "$sandbox")" \
  > "$hostile_report/.nas-platform-mac-report-owned"
chmod 0600 "$hostile_report/.nas-platform-mac-report-owned"
if PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=0 \
  PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
  PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
  PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  PLATFORM_REPORT_ROOT=$hostile_report PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1; then
  fail 'non-sibling adoption report root was accepted'
fi
grep -F 'owned report root is invalid' "$fixture/output" >/dev/null ||
  fail 'non-sibling adoption report root emitted wrong diagnostic'
[ ! -e "$fixture/target-stop.log" ] || fail 'hostile report root reached target operations'

cp -p "$report_root/.nas-platform-mac-report-owned" "$fixture/report-marker.original"
printf 'schema=1\nsandbox=nas-platform-mac.Wrong1\n' > "$report_root/.nas-platform-mac-report-owned"
chmod 0600 "$report_root/.nas-platform-mac-report-owned"
if PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=0 \
  PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
  PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
  PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  PLATFORM_REPORT_ROOT=$report_root PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1; then
  fail 'report marker bound to another sandbox was accepted'
fi
grep -F 'owned report root is invalid' "$fixture/output" >/dev/null ||
  fail 'foreign report marker emitted wrong diagnostic'
mv "$fixture/report-marker.original" "$report_root/.nas-platform-mac-report-owned"

if PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=0 \
  PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
  PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
  PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-wrong1 \
  PLATFORM_REPORT_ROOT=$report_root PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1; then
  fail 'report context with another project was accepted'
fi
grep -F 'owned report project is invalid' "$fixture/output" >/dev/null ||
  fail 'foreign report project emitted wrong diagnostic'
[ ! -e "$fixture/target-stop.log" ] || fail 'hostile report binding reached target operations'

crash_source=legacy/audiobookshelf/config
crash_sentinel=$sandbox/$crash_source/.nas-platform-adoption-root-sentinel
crash_digest=$(shasum -a 256 "$crash_sentinel" | awk '{print $1}')
crash_mtime=$(ruby -e 's=File.stat(ARGV.fetch(0)); puts((s.mtime.to_r*1_000_000_000).to_i)' "$crash_sentinel")
crash_journal=$report_root/adoption-attestation-challenge.json
ruby "$test_dir/adoption-mount-challenge.rb" prepare "$sandbox" \
  "$crash_source" sentinel "$crash_digest" "$crash_journal" >/dev/null
[ -f "$crash_journal" ] || fail 'killed guard fixture did not leave a recoverable challenge journal'
[ "$(ruby -e 's=File.stat(ARGV.fetch(0)); puts((s.mtime.to_r*1_000_000_000).to_i)' "$crash_sentinel")" != "$crash_mtime" ] ||
  fail 'killed guard fixture did not reach the challenged-mtime crash window'
PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=0 \
  PLATFORM_FAKE_CP_LOG="$fixture/attested-mounts.log" \
  PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
  PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
  PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  PLATFORM_REPORT_ROOT=$report_root PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1 ||
  fail 'complete fake container attestation failed'
[ ! -e "$crash_journal" ] || fail 'next guard did not remove the prior crash journal'
[ "$(ruby -e 's=File.stat(ARGV.fetch(0)); puts((s.mtime.to_r*1_000_000_000).to_i)' "$crash_sentinel")" = "$crash_mtime" ] ||
  fail 'next guard did not exactly restore the prior challenged timestamp'
[ "$(wc -l < "$fixture/attested-mounts.log" | tr -d ' ')" = 32 ] ||
  fail 'container attestation did not read all 32 mounted roots'
grep -F "$(printf 'nas-platform-mac-abc123-beszel\tagent-portable\t/var/lib/beszel-agent/.nas-platform-adoption-root-sentinel')" \
  "$fixture/attested-mounts.log" >/dev/null || fail 'Beszel portable-agent sentinel was not read'
grep -F "$(printf 'nas-platform-mac-abc123-paperless\tbroker\t/data/.nas-platform-adoption-root-sentinel')" \
  "$fixture/attested-mounts.log" >/dev/null || fail 'Paperless broker sentinel was not read'
grep -F "$(printf 'nas-platform-mac-abc123-paperless\twebserver\t/usr/src/paperless/data/.nas-platform-adoption-root-sentinel')" \
  "$fixture/attested-mounts.log" >/dev/null || fail 'Paperless webserver sentinel was not read'
[ ! -e "$fixture/target-stop.log" ] || fail 'successful mount attestation stopped targets'

attestation_bytes=$(cat "$published/attestations.json")
for idempotent_action in recover restore; do
  original_mtime=$(ruby -e 's=File.stat(ARGV.fetch(0)); puts((s.mtime.to_r*1_000_000_000).to_i)' "$crash_sentinel")
  ruby "$test_dir/adoption-mount-challenge.rb" prepare "$sandbox" \
    "$crash_source" sentinel "$crash_digest" "$crash_journal" >/dev/null
  cp -p "$crash_journal" "$fixture/$idempotent_action-journal.saved"
  ruby "$test_dir/adoption-mount-challenge.rb" restore "$sandbox" \
    "$crash_source" sentinel "$crash_digest" "$crash_journal" >/dev/null
  cp -p "$fixture/$idempotent_action-journal.saved" "$crash_journal"
  if [ "$idempotent_action" = recover ]; then
    ruby "$test_dir/adoption-mount-challenge.rb" recover "$sandbox" - - - \
      "$crash_journal" "$attestation_bytes" >/dev/null
  else
    ruby "$test_dir/adoption-mount-challenge.rb" restore "$sandbox" \
      "$crash_source" sentinel "$crash_digest" "$crash_journal" >/dev/null
  fi
  [ ! -e "$crash_journal" ] || fail "$idempotent_action did not remove an original-mtime journal"
  [ "$(ruby -e 's=File.stat(ARGV.fetch(0)); puts((s.mtime.to_r*1_000_000_000).to_i)' "$crash_sentinel")" = "$original_mtime" ] ||
    fail "$idempotent_action changed an already restored source timestamp"
done

forged_source=legacy/dozzle/data/state
forged_file=$sandbox/$forged_source
forged_digest=$(shasum -a 256 "$forged_file" | awk '{print $1}')
ruby "$test_dir/adoption-mount-challenge.rb" prepare "$sandbox" \
  "$forged_source" file "$forged_digest" "$crash_journal" >/dev/null
if PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=0 \
  PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
  PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
  PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  PLATFORM_REPORT_ROOT=$report_root PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1; then
  fail 'journal outside the signed attestation set was accepted for crash recovery'
fi
grep -F 'challenge recovery is not bound to the snapshot attestations' "$fixture/output" >/dev/null ||
  fail 'unbound crash journal emitted wrong diagnostic'
ruby "$test_dir/adoption-mount-challenge.rb" restore "$sandbox" \
  "$forged_source" file "$forged_digest" "$crash_journal" >/dev/null

: > "$fixture/target-stop.log"
oversize_mtime=$(ruby -e 's=File.stat(ARGV.fetch(0)); puts((s.mtime.to_r*1_000_000_000).to_i)' "$crash_sentinel")
ruby -e 'File.binwrite(ARGV.fetch(0), "x" * 4097)' "$crash_journal"
chmod 0400 "$crash_journal"
if PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=0 \
  PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
  PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
  PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  PLATFORM_REPORT_ROOT=$report_root PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1; then
  fail 'oversized stable challenge journal was accepted'
fi
grep -F 'challenge journal is unsafe' "$fixture/output" >/dev/null ||
  fail 'oversized stable challenge journal emitted wrong diagnostic'
[ "$(ruby -e 's=File.stat(ARGV.fetch(0)); puts((s.mtime.to_r*1_000_000_000).to_i)' "$crash_sentinel")" = "$oversize_mtime" ] ||
  fail 'oversized stable challenge journal mutated a live source'
rm "$crash_journal"

: > "$fixture/target-stop.log"
ln "$crash_sentinel" "$fixture/hardlinked-sentinel"
if PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=0 \
  PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
  PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
  PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  PLATFORM_REPORT_ROOT=$report_root PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1; then
  fail 'hardlinked adoption sentinel was accepted by the live challenge'
fi
[ -s "$fixture/target-stop.log" ] || fail 'hardlinked adoption sentinel did not stop targets'
rm "$fixture/hardlinked-sentinel"

: > "$fixture/target-stop.log"
mv "$sandbox/legacy/audiobookshelf/config" "$fixture/config-original"
mkdir -m 0700 "$sandbox/legacy/audiobookshelf/config"
cp -p "$fixture/config-original/.nas-platform-adoption-root-sentinel" \
  "$sandbox/legacy/audiobookshelf/config/.nas-platform-adoption-root-sentinel"
if PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=0 \
  PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
  PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
  PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  PLATFORM_REPORT_ROOT=$report_root PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1; then
  fail 'persistent alternate adopted root was accepted'
fi
grep -F 'live source identity differs from pre-cutover attestation' "$fixture/output" >/dev/null ||
  fail 'persistent alternate adopted root emitted wrong diagnostic'
[ -s "$fixture/target-stop.log" ] || fail 'persistent alternate adopted root did not stop targets'
rm -R "$sandbox/legacy/audiobookshelf/config"
mv "$fixture/config-original" "$sandbox/legacy/audiobookshelf/config"

copied_sentinel=$fixture/copied-sentinel
cp -p "$sandbox/legacy/audiobookshelf/config/.nas-platform-adoption-root-sentinel" "$copied_sentinel"
if PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=copied \
  PLATFORM_FAKE_SWAP_MARKER="$fixture/copied-sentinel-fired" \
  PLATFORM_FAKE_COPIED_SENTINEL="$copied_sentinel" \
  PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
  PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
  PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  PLATFORM_REPORT_ROOT=$report_root PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1; then
  fail 'same-content copied sentinel mount was accepted'
fi
[ -f "$fixture/copied-sentinel-fired" ] || fail 'same-content copied sentinel swap did not fire'
[ -s "$fixture/target-stop.log" ] || fail 'same-content copied sentinel did not stop target projects'
if PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=1 \
  PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
  PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
  PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
  PLATFORM_REPORT_ROOT=$report_root PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1; then
  fail 'swap-and-restore replacement sentinel was accepted'
fi
grep -F 'mounted sentinel differs' "$fixture/output" >/dev/null ||
  fail 'replacement sentinel emitted wrong diagnostic'
[ -s "$fixture/target-stop.log" ] || fail 'sentinel mismatch did not stop target projects'
for unsafe_copy in symlink directory oversize; do
  : > "$fixture/target-stop.log"
  if PATH="$fake_docker_dir:$PATH" PLATFORM_FAKE_SWAP=$unsafe_copy \
    PLATFORM_FAKE_ESCAPE="$fixture/escape-target" \
    PLATFORM_FAKE_ATTESTATIONS="$published/attestations.json" \
    PLATFORM_FAKE_STOP_LOG="$fixture/target-stop.log" PLATFORM_ADOPTION_ENABLED=true \
    PLATFORM_ADOPTION_ROOT=$sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-abc123 \
    PLATFORM_REPORT_ROOT=$report_root PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
    "$test_dir/adoption-container-attest.sh" >"$fixture/output" 2>&1; then
    fail "unsafe Docker-copy $unsafe_copy output was accepted"
  fi
  grep -F 'unsafe sentinel readback' "$fixture/output" >/dev/null ||
    fail "unsafe Docker-copy $unsafe_copy emitted wrong diagnostic"
  [ -s "$fixture/target-stop.log" ] || fail "unsafe Docker-copy $unsafe_copy did not stop targets"
done
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
ruby -e '
  path = ARGV.fetch(0)
  lines = File.readlines(path, mode: "rb")
  abort unless lines.last == "# changed reviewed mapping\n"
  File.binwrite(path, lines[0...-1].join)
' "$override_root/dozzle.yml"

cp "$baseline" "$fixture/baseline.original"
printf '%s\n' changed >> "$baseline"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" verify --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'changed immutable baseline was accepted'
fi
grep -F 'snapshot baseline changed' "$fixture/output" >/dev/null ||
  fail 'changed immutable baseline emitted wrong diagnostic'
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_MAC_SANDBOX=$sandbox \
  "$snapshotter" baseline-binding --override-root "$override_root" \
  --baseline "$baseline" --run-state "$state" >"$fixture/output" 2>&1; then
  fail 'baseline binding accepted replaced live expectations'
fi
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
