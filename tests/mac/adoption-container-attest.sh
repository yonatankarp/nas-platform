#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$script_dir/lib.sh"

die() { printf 'adoption-attestation-error: %s\n' "$1" >&2; exit 1; }

sandbox=$(mac_validate_sandbox "${PLATFORM_ADOPTION_ROOT:?}" 2>/dev/null) || die 'owned adoption root is invalid'
[ "${PLATFORM_ADOPTION_ENABLED:-}" = true ] || die 'adoption mapping is not enabled'
[ "${PLATFORM_REPORT_ROOT:?}" = "$sandbox/report" ] &&
  [ -d "$PLATFORM_REPORT_ROOT" ] && [ ! -L "$PLATFORM_REPORT_ROOT" ] &&
  [ "$(mac_owner_id "$PLATFORM_REPORT_ROOT")" = "$(id -u)" ] &&
  [ "$(mac_file_mode "$PLATFORM_REPORT_ROOT")" = 700 ] || die 'owned report root is invalid'
temporary_dir=$(mktemp -d "${PLATFORM_REPORT_ROOT:?}/adoption-attestation.XXXXXX")
chmod 0700 "$temporary_dir"
temporary=$temporary_dir/readback
records=$temporary_dir/records
temporary_signature=$(ruby -e 's = File.lstat(ARGV.fetch(0)); puts "#{s.dev}:#{s.ino}"' "$temporary_dir")
challenge_token=
challenge_journal=$temporary_dir/challenge.json
challenge_source=
challenge_kind=
challenge_digest=

restore_challenge() {
  [ -e "$challenge_journal" ] || return 0
  ruby "$script_dir/adoption-mount-challenge.rb" restore "$sandbox" \
    "$challenge_source" "$challenge_kind" "$challenge_digest" "$challenge_journal"
  challenge_token=
}

stop_targets() {
  for suffix in audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless tinymediamanager; do
    ids=$(docker ps -q --filter "label=com.docker.compose.project=$PLATFORM_PROJECT_NAME-$suffix" 2>/dev/null || true)
    [ -z "$ids" ] || docker stop $ids >/dev/null 2>&1 || true
  done
}
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  cleanup_allowed=true
  if ! restore_challenge; then
    status=1
    cleanup_allowed=false
  fi
  [ "$status" -eq 0 ] || stop_targets
  if [ "$cleanup_allowed" = true ]; then
    ruby -rfiddle/import - "$PLATFORM_REPORT_ROOT" "$(basename -- "$temporary_dir")" \
    "$temporary_signature" <<'RUBY' 2>/dev/null || true
module CleanupFS
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int openat(int, const char *, int, int)"
  extern "int unlinkat(int, const char *, int)"
end
AT_REMOVEDIR = 0x80
def open_at(parent, name)
  fd = CleanupFS.openat(parent.fileno, name, File::RDONLY | File::NOFOLLOW, 0)
  raise SystemCallError.new("openat", Fiddle.last_error) if fd.negative?
  File.for_fd(fd)
end
def remove_at(parent, name)
  entry = open_at(parent, name)
  if entry.stat.directory?
    duplicate = entry.dup
    duplicate.autoclose = false
    directory = Dir.for_fd(duplicate.fileno)
    children = directory.children
    directory.close
    children.each { |child| remove_at(entry, child) }
    entry.close
    result = CleanupFS.unlinkat(parent.fileno, name, AT_REMOVEDIR)
  else
    entry.close
    result = CleanupFS.unlinkat(parent.fileno, name, 0)
  end
  raise SystemCallError.new("unlinkat", Fiddle.last_error) if result.negative?
rescue Errno::ELOOP
  result = CleanupFS.unlinkat(parent.fileno, name, 0)
  raise SystemCallError.new("unlinkat", Fiddle.last_error) if result.negative?
end
report = File.open(ARGV.fetch(0), File::RDONLY | File::NOFOLLOW)
temporary = open_at(report, ARGV.fetch(1))
stat = temporary.stat
abort "temporary namespace changed" unless "#{stat.dev}:#{stat.ino}" == ARGV.fetch(2) &&
  stat.directory? && stat.uid == Process.uid && (stat.mode & 0o7777) == 0o700
temporary.close
remove_at(report, ARGV.fetch(1))
RUBY
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

namespace_before=$("$script_dir/adoption-snapshot.sh" live-namespace \
  --override-root "$script_dir/legacy-overrides" --baseline "$sandbox/baseline.json" \
  --run-state "$PLATFORM_REPORT_ROOT/phase-input.json") || die 'namespace pre-attestation failed'

attestation_json=$("$script_dir/adoption-snapshot.sh" attestations \
  --override-root "$script_dir/legacy-overrides" --baseline "$sandbox/baseline.json" \
  --run-state "$PLATFORM_REPORT_ROOT/phase-input.json") || die 'snapshot attestations are unavailable'
ruby -rjson - "$attestation_json" > "$records" <<'RUBY'
JSON.parse(ARGV.fetch(0)).each do |entry|
  puts %w[project_suffix target_compose_service source target access kind container_path size sha256].map {
    |key| entry.fetch(key)
  }.join("\t")
end
RUBY

tab=$(printf '\t')
while IFS="$tab" read -r suffix service source destination access kind container_path expected_size expected; do
  project=$PLATFORM_PROJECT_NAME-$suffix
  ids=$(docker ps -q --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.service=$service") || { stop_targets; die 'container lookup failed'; }
  [ "$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ] || {
    stop_targets; die 'exactly one attested container is required';
  }
  mounts=$(docker inspect --format '{{json .Mounts}}' "$ids") || { stop_targets; die 'mount inspection failed'; }
  ruby -rjson -e '
    mounts, source, destination, access = JSON.parse(ARGV[0]), ARGV[1], ARGV[2], ARGV[3]
    selected = mounts.select { |mount| mount["Destination"] == destination }
    abort "mount tuple differs" unless selected.length == 1 && selected[0]["Source"] == source &&
      selected[0]["RW"] == (access == "rw")
  ' "$mounts" "$sandbox/$source" "$destination" "$access" || { stop_targets; die 'mounted tuple differs'; }
  case "$expected_size" in ''|*[!0-9]*) die 'invalid attestation size' ;; esac
  case "$kind" in
    sentinel)
      [ "$expected_size" -le 256 ] || die 'invalid sentinel attestation size'
      copy_limit=256
      ;;
    file)
      [ "$expected_size" -le 67108864 ] || die 'invalid file attestation size'
      copy_limit=67108864
      ;;
    *) die 'invalid attestation kind' ;;
  esac
  copy_blocks=$(( (copy_limit + 511) / 512 ))
  challenge_source=$source
  challenge_kind=$kind
  challenge_digest=$expected
  challenge_mtime_ns=$(ruby "$script_dir/adoption-mount-challenge.rb" prepare "$sandbox" \
    "$source" "$kind" "$expected" "$challenge_journal") || die 'mount challenge preparation failed'
  challenge_token=$challenge_mtime_ns
  rm -f -- "$temporary"
  (ulimit -f "$copy_blocks"; docker cp "$ids:$container_path" "$temporary" >/dev/null) || {
    restore_challenge || true
    stop_targets; die 'attestation readback failed';
  }
  actual=$(ruby -rdigest -rfiddle/import - "$temporary_dir" "$expected_size" "$copy_limit" <<'RUBY'
module GuardFS
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int openat(int, const char *, int, int)"
end
directory = File.open(ARGV.fetch(0), File::RDONLY | File::NOFOLLOW)
descriptor = GuardFS.openat(directory.fileno, "readback", File::RDONLY | File::NOFOLLOW, 0)
abort "unsafe Docker copy output" if descriptor.negative?
file = File.for_fd(descriptor)
before = file.stat
expected_size, copy_limit = Integer(ARGV.fetch(1), 10), Integer(ARGV.fetch(2), 10)
abort "unsafe Docker copy output" unless before.file? && before.uid == Process.uid &&
  before.size == expected_size && before.size <= copy_limit
file.chmod(0o400)
before = file.stat
abort "unsafe Docker copy output" unless (before.mode & 0o222).zero?
bytes = file.read
abort "Docker copy output changed" unless [file.stat.dev, file.stat.ino, file.stat.size, file.stat.mode] ==
  [before.dev, before.ino, before.size, before.mode]
puts [Digest::SHA256.hexdigest(bytes), (before.mtime.to_r * 1_000_000_000).to_i].join("\t")
RUBY
) || { restore_challenge || true; stop_targets; die 'unsafe sentinel readback'; }
  restore_challenge || { stop_targets; die 'mount challenge restoration failed'; }
  actual_digest=${actual%%"$tab"*}
  actual_mtime_ns=${actual#*"$tab"}
  [ "$actual_digest" = "$expected" ] && [ "$actual_mtime_ns" = "$challenge_mtime_ns" ] || {
    stop_targets; die 'mounted sentinel differs';
  }
done < "$records"

namespace_after=$("$script_dir/adoption-snapshot.sh" live-namespace \
  --override-root "$script_dir/legacy-overrides" --baseline "$sandbox/baseline.json" \
  --run-state "$PLATFORM_REPORT_ROOT/phase-input.json") || die 'namespace post-attestation failed'
[ "$namespace_after" = "$namespace_before" ] || die 'live adoption namespace changed during attestation'

printf '%s\n' 'Adoption container mounts: snapshot-bound sentinels verified'
