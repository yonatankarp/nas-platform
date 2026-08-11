#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

ruby - "$repo_dir/.github/workflows/ci.yml" <<'RUBY'
workflow_source = File.binread(ARGV.fetch(0))
forbidden_ci_inputs = [
  "nas-infrastructure",
  "NAS_INFRASTRUCTURE",
  "tests/adoption-integration.sh",
  "synthetic legacy adoption",
  "synthetic-adoption-diagnostics"
]
forbidden_ci_inputs.each do |input|
  raise "CI adoption contract: legacy adoption must remain local-only (found #{input})" if
    workflow_source.include?(input)
end
RUBY

[ -x "$repo_dir/tests/adoption-integration.sh" ] || {
  printf '%s\n' 'adoption integration contract: wrapper is missing or not executable' >&2
  exit 1
}
sh -n "$repo_dir/tests/adoption-integration.sh"
ruby - "$repo_dir/tests/mac/run.sh" "$repo_dir/tests/mac/lib.sh" \
  "$repo_dir/tests/mac/legacy-seed.sh" <<'RUBY'
runner, library, legacy_seed = ARGV.map { |path| File.binread(path) }
raise "runner contract: integration context is not centralized" unless
  runner.include?("mac_ansible_playbook") && library.include?("platform_compose_kind=integration") &&
    library.include?("deployment_bundle_test_mode=true") &&
    library.include?("platform_manage_linux_ownership=true")
raise "runner contract: dirty-controller bypass is enabled" if
  runner.include?("deployment_bundle_allow_dirty_controller=true")
raise "runner contract: legacy seed bypasses centralized integration context" unless
  legacy_seed.include?("mac_ansible_playbook")
RUBY
ruby -ropen3 - "$repo_dir/tests/adoption-integration.sh" <<'RUBY'
source = File.binread(ARGV.fetch(0))
runner_shell = source[/sh -eu -c '(.*?)' sh /m, 1] or raise "runner shell is unavailable"
raise "synthetic wrapper uses nonportable Dir.fchdir" if source.include?("Dir.fchdir")
raise "synthetic wrapper uses unavailable Dir.for_fd" if source.include?("Dir.for_fd")
raise "synthetic wrapper does not use descriptor-bound Dir#chdir" unless
  source.include?('Fiddle::Handle::DEFAULT["fchdir"]') &&
    source.include?("fchdir.call(file.fileno)") && source.include?("fchdir.call(previous.fileno)")
raise "runner shell must install packages exactly once" unless runner_shell.scan(/apk add /).length == 1
raise "runner shell lacks the pinned shasum provider" unless runner_shell.include?("perl-utils")
raise "runner shell does not validate shasum" unless
  runner_shell.include?("command -v shasum") && runner_shell.include?("e3b0c44298fc1c149afbf4c8996fb924")
raise "runner shell omits the root-run bind ownership regression" unless
  runner_shell.include?('ruby "$1/tests/mac/adoption-bind-prep-test.rb"')
validation = runner_shell[/command -v shasum.*?b855 \]/m] or raise "shasum validation is unavailable"
_stdout, stderr, status = Open3.capture3("sh", "-eu", "-c", validation)
raise "shasum validation is not executable: #{stderr}" unless status.success?
verification = source[/elsif operation == "verify"(.*?)elsif operation == "remove"/m, 1] or
  raise "inner owned-root verification is unavailable"
raise "inner verification incorrectly requires container Process.uid" if
  verification.include?("Process.uid")
raise "inner verification does not bind the recorded host owner" unless
  verification.include?("marker_stat.uid == root_stat.uid") && verification.include?("signature == expected")
RUBY

fail() {
  printf '%s\n' "adoption integration contract: $1" >&2
  exit 1
}

fixture_parent=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-adoption-contract.XXXXXX")
cleanup_fixture() {
  fixture_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$fixture_parent" ] && [ ! -L "$fixture_parent" ]; then
    find "$fixture_parent" -depth -mindepth 1 -delete
    rmdir -- "$fixture_parent"
  fi
  exit "$fixture_status"
}
trap cleanup_fixture EXIT HUP INT TERM

fixture_repo=$fixture_parent/nas-platform
fixture_legacy=$fixture_parent/nas-infrastructure
runner_parent=$fixture_parent/runner-temp
other_tmp=$fixture_parent/other-temp
fake_bin=$fixture_parent/bin
mkdir -p "$fixture_repo/tests/mac" "$fixture_repo/scripts" "$fixture_repo/services" \
  "$fixture_repo/config" "$fixture_repo/inventory/group_vars/all" \
  "$fixture_repo/roles/beszel/defaults" "$fixture_repo/roles/paperless_ngx/defaults" \
  "$fixture_legacy" "$runner_parent" "$other_tmp" "$fake_bin"
cp "$repo_dir/tests/adoption-integration.sh" "$fixture_repo/tests/adoption-integration.sh"
cp "$repo_dir/services/manifest.yml" "$fixture_repo/services/manifest.yml"
committed_manifest=$fixture_parent/committed-manifest.yml
cp "$repo_dir/services/manifest.yml" "$committed_manifest"
cp "$repo_dir/config/portainer-parity.yml" "$fixture_repo/config/portainer-parity.yml"
cp "$repo_dir/inventory/group_vars/all/main.yml" "$fixture_repo/inventory/group_vars/all/main.yml"
cp "$repo_dir/roles/beszel/defaults/main.yml" "$fixture_repo/roles/beszel/defaults/main.yml"
cp "$repo_dir/roles/paperless_ngx/defaults/main.yml" \
  "$fixture_repo/roles/paperless_ngx/defaults/main.yml"
chmod 0755 "$fixture_repo/tests/adoption-integration.sh"

cat > "$fixture_repo/tests/sandbox_cleanup.sh" <<'SH'
cleanup_sandbox() {
  target=$1
  printf 'outer:%s\n' "$target" >> "${FAKE_CLEANUP_LOG:?}"
  if [ "${FAKE_OUTER_CLEANUP_FAIL:-0}" = 1 ]; then
    return 1
  fi
  find "$target" -depth -mindepth 1 -delete && rmdir -- "$target"
}
cleanup_sandbox_contents() {
  parent=$1 name=$2 preserve=$3
  [ "$preserve" = .nas-platform-mac-report-owned ] || return 1
  target=$parent/$name
  printf 'report:%s\n' "$target" >> "${FAKE_CLEANUP_LOG:?}"
  find "$target" -depth -mindepth 1 -delete && rmdir -- "$target"
}
SH
cat > "$fixture_repo/tests/generate-ephemeral-vault.sh" <<'SH'
#!/bin/sh
set -eu
case $1 in
  --output)
    printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$2"
    printf '%s\n' synthetic-password > "$4"
    chmod 0600 "$2" "$4"
    printf 'generate:%s:%s\n' "$2" "$4" >> "${FAKE_VAULT_LOG:?}"
    ;;
  --cleanup)
    printf 'vault-cleanup:%s\n' "$2" >> "${FAKE_CLEANUP_LOG:?}"
    find "$2" -depth -mindepth 1 -delete
    rmdir -- "$2"
    ;;
  *) exit 2 ;;
esac
SH
cat > "$fixture_repo/scripts/import-portainer-parity.sh" <<'SH'
#!/bin/sh
set -eu
input= output= password=
while [ "$#" -gt 0 ]; do
  case $1 in
    --input-dir) input=$2 ;;
    --output) output=$2 ;;
    --vault-password-file) password=$2 ;;
    *) exit 2 ;;
  esac
  shift 2
done
ports_path=$(dirname -- "$input")/integration-ports.json
ruby -rjson - "$input" "$ports_path" <<'RUBY'
root, ports_path = ARGV
ports = JSON.parse(File.binread(ports_path))
files = Dir.children(root).sort
expected = %w[audiobookshelf.env beszel.env dozzle.env immich.env jellyfin.env komga.env ntfy.env paperless-ngx.env tinymediamanager.env]
raise "export set differs" unless files == expected
env = files.to_h do |name|
  values = File.readlines(File.join(root, name), chomp: true).to_h { |line| line.split("=", 2) }
  [name, values]
end
raise "timezone differs" unless env.fetch("audiobookshelf.env").fetch("TZ") == "Europe/Berlin"
raise "beszel URL differs" unless env.fetch("beszel.env").fetch("BESZEL_APP_URL") ==
  "http://127.0.0.1:#{ports.fetch('beszel_port')}"
raise "beszel name differs" unless env.fetch("beszel.env").fetch("BESZEL_SYSTEM_NAME") == "ASUSTOR-AS6704T"
raise "ntfy URL differs" unless env.fetch("ntfy.env").fetch("NTFY_BASE_URL") ==
  "http://127.0.0.1:#{ports.fetch('ntfy_port')}"
raise "vault parity differs" unless env.fetch("immich.env").fetch("DB_PASSWORD") == "synthetic-vault-value"
RUBY
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$output"
chmod 0600 "$output"
printf 'import:%s:%s:%s\n' "$input" "$output" "$password" >> "${FAKE_IMPORT_LOG:?}"
SH
cat > "$fixture_repo/tests/mac/run.sh" <<'SH'
#!/bin/sh
set -eu
printf 'coordinator-env:%s:%s\n' "${NAS_INFRASTRUCTURE_DIR:?}" "${PLATFORM_MAC_TMPDIR:?}" \
  >> "${FAKE_COORDINATOR_LOG:?}"
printf 'coordinator-argv:' >> "${FAKE_COORDINATOR_LOG:?}"
sandbox=
while [ "$#" -gt 0 ]; do
  argument=$1
  printf '<%s>' "$argument" >> "${FAKE_COORDINATOR_LOG:?}"
  if [ "$argument" = --sandbox ]; then
    sandbox=$2
  fi
  shift
done
printf '\n' >> "${FAKE_COORDINATOR_LOG:?}"
[ -n "$sandbox" ] || exit 2
mkdir -m 0700 "$sandbox.reports"
printf 'schema=1\nsandbox=%s\n' "$(basename -- "$sandbox")" \
  > "$sandbox.reports/.nas-platform-mac-report-owned"
chmod 0600 "$sandbox.reports/.nas-platform-mac-report-owned"
[ "${FAKE_COORDINATOR_FAIL:-0}" = 0 ]
SH
cat > "$fixture_repo/tests/mac/cleanup.sh" <<'SH'
#!/bin/sh
set -eu
printf 'sandbox:%s\n' "$1" >> "${FAKE_CLEANUP_LOG:?}"
find "$1" -depth -mindepth 1 -delete
rmdir -- "$1"
report=$1.reports
[ ! -d "$report" ] || printf 'production-cleanup-left-report:%s\n' "$report" >> "${FAKE_CLEANUP_LOG:?}"
SH
chmod 0755 "$fixture_repo/tests/generate-ephemeral-vault.sh" \
  "$fixture_repo/scripts/import-portainer-parity.sh" "$fixture_repo/tests/mac/run.sh" \
  "$fixture_repo/tests/mac/cleanup.sh"

cat > "$fake_bin/uname" <<'SH'
#!/bin/sh
printf '%s\n' Linux
SH
cat > "$fake_bin/git" <<'SH'
#!/bin/sh
root=
if [ "${1-}" = -C ]; then root=$2; shift 2; fi
case " $* " in
  *' rev-parse HEAD '*)
    if [ "$(basename -- "$root")" = nas-platform ]; then
      printf '%040d\n' 0
    else
      printf '%s\n' "${FAKE_LEGACY_REVISION:?}"
    fi
    ;;
  *' cat-file blob '*'services/manifest.yml '*) cat "${FAKE_CONTROLLER_MANIFEST:?}" ;;
  *' remote get-url origin '*)
    printf '%s\n' "${FAKE_LEGACY_ORIGIN:-https://github.com/yonatankarp/nas-infrastructure.git}"
    ;;
  *' status --porcelain=v1 --untracked-files=all '*)
    [ "${FAKE_LEGACY_DIRTY:-0}" = 0 ] || printf '%s\n' ' M compose/ntfy/compose.yml'
    ;;
  *) exit 2 ;;
esac
SH
cat > "$fake_bin/ansible-vault" <<'SH'
#!/bin/sh
[ "$1" = view ] || exit 2
cat "${FAKE_VAULT_VIEW:?}"
SH
cat > "$fake_bin/docker" <<'SH'
#!/bin/sh
set -eu
case ${1-} in
  network)
    printf '%s\n' 172.17.0.1
    ;;
  run)
    printf 'docker-run:' >> "${FAKE_DOCKER_LOG:?}"
    for argument in "$@"; do printf '<%s>' "$argument" >> "$FAKE_DOCKER_LOG"; done
    printf '\n' >> "$FAKE_DOCKER_LOG"
    script= owned= identity=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = sh ] && [ "${2-}" = -eu ] && [ "${3-}" = -c ]; then
        script=${9-}
        owned=${8-}
        identity=${10-}
        break
      fi
      shift
    done
    [ -n "$script" ] && [ -n "$owned" ] && [ -n "$identity" ] || exit 91
    inner_status=0
    FAKE_INNER_ROOT=1 "$script" --inner "$owned" "$identity" || inner_status=$?
    case ${FAKE_DIAGNOSTIC_MUTATION:-} in
      symlink) ln -s "${FAKE_DIAGNOSTIC_SENTINEL:?}" "$ADOPTION_DIAGNOSTICS_DIR/sanitized.txt" ;;
      fifo) mkfifo "$ADOPTION_DIAGNOSTICS_DIR/sanitized.txt" ;;
      parent)
        mv "$ADOPTION_DIAGNOSTICS_DIR" "$ADOPTION_DIAGNOSTICS_DIR.swapped"
        mkdir -m 0700 "$ADOPTION_DIAGNOSTICS_DIR"
        ;;
      directory-fifo)
        rmdir "$ADOPTION_DIAGNOSTICS_DIR"
        mkfifo "$ADOPTION_DIAGNOSTICS_DIR"
        ;;
      '') ;;
      *) exit 93 ;;
    esac
    [ "${FAKE_OUTER_CLEANUP_FAIL:-0}" = 0 ] || printf '%s\n' residue > "$owned/unexpected"
    exit "$inner_status"
    ;;
  *) exit 92 ;;
esac
SH
cat > "$fake_bin/id" <<'SH'
#!/bin/sh
if [ "${FAKE_INNER_ROOT:-0}" = 1 ] && [ "${1-}" = -u ]; then printf '%s\n' 0; else /usr/bin/id "$@"; fi
SH
chmod 0755 "$fake_bin/uname" "$fake_bin/git" "$fake_bin/ansible-vault" \
  "$fake_bin/docker" "$fake_bin/id"

gateway_bin=$fixture_parent/gateway-bin
mkdir "$gateway_bin"
cat > "$gateway_bin/docker" <<'SH'
#!/bin/sh
printf '%s\n' "${FAKE_DOCKER_GATEWAY:?}"
SH
chmod 0755 "$gateway_bin/docker"
gateway=$(PATH="$gateway_bin:$PATH" FAKE_DOCKER_GATEWAY=172.17.0.1 \
  sh -c '. "$1"; mac_integration_gateway' sh "$repo_dir/tests/mac/lib.sh") ||
  fail 'valid integration gateway was rejected'
[ "$gateway" = 172.17.0.1 ] || fail 'integration gateway was not canonicalized'
for hostile_gateway in '' 127.0.0.1 '172.17.0.1 -e hostile=true' '172.17.0.1
192.0.2.1' 2001:db8::1; do
  if PATH="$gateway_bin:$PATH" FAKE_DOCKER_GATEWAY="$hostile_gateway" \
      sh -c '. "$1"; mac_integration_gateway' sh "$repo_dir/tests/mac/lib.sh" \
      >/dev/null 2>&1; then
    fail 'hostile integration gateway was accepted'
  fi
done

vault_view=$fixture_parent/vault-view.yml
ruby -ryaml - "$fixture_repo/config/portainer-parity.yml" "$vault_view" <<'RUBY'
mapping = YAML.safe_load_file(ARGV.fetch(0), aliases: false)
keys = mapping.fetch("stacks").values.flat_map do |rules|
  rules.values.select { |rule| rule.fetch("classification") == "vault" }.map { |rule| rule.fetch("target") }
end.uniq
File.write(ARGV.fetch(1), YAML.dump(keys.to_h { |key| [key, "synthetic-vault-value"] }))
RUBY

legacy_revision=400f03f276ae1bb69f5460c175b9fb923d620f1a
vault_log=$fixture_parent/vault.log
import_log=$fixture_parent/import.log
coordinator_log=$fixture_parent/coordinator.log
cleanup_log=$fixture_parent/cleanup.log
docker_log=$fixture_parent/docker.log
: > "$vault_log"; : > "$import_log"; : > "$coordinator_log"; : > "$cleanup_log"; : > "$docker_log"

run_fixture() {
  PATH="$fake_bin:$PATH" RUNNER_TEMP="$runner_parent" TMPDIR="$other_tmp" \
    NAS_INFRASTRUCTURE_DIR="$fixture_legacy" \
    ADOPTION_DIAGNOSTICS_DIR="${TEST_DIAGNOSTICS_DIR:-$runner_parent/nas-platform-adoption-diagnostics}" \
    FAKE_LEGACY_REVISION="${TEST_LEGACY_REVISION:-$legacy_revision}" FAKE_VAULT_VIEW="$vault_view" \
    FAKE_LEGACY_ORIGIN="${TEST_LEGACY_ORIGIN:-https://github.com/yonatankarp/nas-infrastructure.git}" \
    FAKE_LEGACY_DIRTY="${TEST_LEGACY_DIRTY:-0}" \
    FAKE_CONTROLLER_MANIFEST="$committed_manifest" \
    FAKE_VAULT_LOG="$vault_log" FAKE_IMPORT_LOG="$import_log" \
    FAKE_COORDINATOR_LOG="$coordinator_log" FAKE_CLEANUP_LOG="$cleanup_log" \
    FAKE_DOCKER_LOG="$docker_log" \
    FAKE_DIAGNOSTIC_MUTATION="${TEST_DIAGNOSTIC_MUTATION:-}" \
    FAKE_DIAGNOSTIC_SENTINEL="${TEST_DIAGNOSTIC_SENTINEL:-}" \
    "$fixture_repo/tests/adoption-integration.sh"
}

if ! run_fixture > "$fixture_parent/success.out" 2>&1; then
  sed -n '1,40p' "$fixture_parent/success.out" >&2
  fail 'synthetic wrapper fixture failed'
fi
[ ! -e "$runner_parent/nas-platform-adoption-diagnostics" ] ||
  fail 'successful wrapper retained diagnostics'
[ -z "$(find "$runner_parent" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail 'successful wrapper retained owned state'
[ -z "$(find "$other_tmp" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail 'wrapper used TMPDIR instead of RUNNER_TEMP'
fixture_legacy_physical=$(CDPATH= cd -- "$fixture_legacy" && pwd -P)
fixture_repo_physical=$(CDPATH= cd -- "$fixture_repo" && pwd -P)
runner_parent_physical=$(CDPATH= cd -- "$runner_parent" && pwd -P)
grep -F '<--network><host>' "$docker_log" >/dev/null || fail 'runner container lacks host networking'
grep -F '</var/run/docker.sock:/var/run/docker.sock>' "$docker_log" >/dev/null ||
  fail 'runner container lacks the Docker socket'
grep -F "<$fixture_repo_physical:$fixture_repo_physical:ro>" "$docker_log" >/dev/null ||
  fail 'controller checkout is not mounted read-only at its exact path'
grep -F "<$fixture_legacy_physical:$fixture_legacy_physical:ro>" "$docker_log" >/dev/null ||
  fail 'legacy checkout is not mounted read-only at its exact path'
grep -F "<NAS_INFRASTRUCTURE_DIR=$fixture_legacy_physical>" "$docker_log" >/dev/null ||
  fail 'runner container did not receive the pinned legacy checkout'
grep -E '<RUNNER_TEMP=.*/nas-platform-integration\.[A-Za-z0-9]{6}>' "$docker_log" >/dev/null ||
  fail 'runner container did not receive its mounted owned temporary parent'
grep -F 'chown 0:0' "$docker_log" >/dev/null &&
  fail 'runner container changes ownership of the outer root'
grep -F '<docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0>' \
  "$docker_log" >/dev/null || fail 'runner image is not digest-pinned'
[ "$(grep -c '^generate:' "$vault_log")" -eq 1 ] || fail 'deployment vault was not generated once'
[ "$(grep -c '^import:' "$import_log")" -eq 1 ] || fail 'parity vault was not imported once'
deployment_root=$(sed -n 's/^generate:\([^:]*\)\/vault.yml:.*/\1/p' "$vault_log")
parity_root=$(sed -n 's/^import:[^:]*:\([^:]*\)\/vault.yml:.*/\1/p' "$import_log")
[ -n "$deployment_root" ] && [ -n "$parity_root" ] && [ "$deployment_root" != "$parity_root" ] ||
  fail 'deployment and parity credentials share a namespace'
grep -F 'coordinator-argv:<--lane><adoption><--platform><integration><--integration-ports-file>' \
  "$coordinator_log" >/dev/null || fail 'coordinator did not receive full integration mode'
grep -F "coordinator-env:$fixture_legacy_physical:$runner_parent_physical/" "$coordinator_log" >/dev/null ||
  fail 'coordinator did not receive the pinned sibling or owned root'
[ "$(grep -c '^vault-cleanup:' "$cleanup_log")" -eq 2 ] ||
  fail 'credential namespaces were not cleaned exactly once'
grep -c '^sandbox:' "$cleanup_log" | grep -qx 1 || fail 'coordinator sandbox cleanup differs'
grep -c '^report:' "$cleanup_log" | grep -qx 1 || fail 'synthetic report cleanup differs'
grep -c '^production-cleanup-left-report:' "$cleanup_log" | grep -qx 1 ||
  fail 'fixture did not mirror production report retention'
grep '^outer:' "$cleanup_log" >/dev/null && fail 'outer root used recursive cleanup instead of bound empty removal'

if FAKE_COORDINATOR_FAIL=1 run_fixture > "$fixture_parent/failure.out" 2>&1; then
  fail 'coordinator failure was accepted'
fi
diagnostic=$runner_parent/nas-platform-adoption-diagnostics/sanitized.txt
[ -f "$diagnostic" ] && [ ! -L "$diagnostic" ] || fail 'failure diagnostic is missing'
[ "$(cat "$diagnostic")" = 'synthetic legacy adoption failed; diagnostics are redacted' ] ||
  fail 'failure diagnostic is not fixed and sanitized'
grep -F "$fixture_parent" "$diagnostic" >/dev/null && fail 'failure diagnostic leaked a raw path'
find "$runner_parent/nas-platform-adoption-diagnostics" -depth -mindepth 1 -delete
rmdir -- "$runner_parent/nas-platform-adoption-diagnostics"

if FAKE_OUTER_CLEANUP_FAIL=1 run_fixture > "$fixture_parent/cleanup-failure.out" 2>&1; then
  fail 'contained cleanup failure was accepted'
fi
[ -f "$diagnostic" ] || fail 'cleanup failure did not retain sanitized diagnostics'
grep -F "$fixture_parent" "$diagnostic" >/dev/null && fail 'cleanup diagnostic leaked a raw path'
find "$runner_parent" -depth -mindepth 1 -delete

diagnostic_sentinel=$fixture_parent/diagnostic-sentinel
printf '%s\n' protected > "$diagnostic_sentinel"
for diagnostic_mutation in symlink fifo parent directory-fifo; do
  if FAKE_COORDINATOR_FAIL=1 TEST_DIAGNOSTIC_MUTATION="$diagnostic_mutation" \
      TEST_DIAGNOSTIC_SENTINEL="$diagnostic_sentinel" run_fixture \
      > "$fixture_parent/diagnostic-$diagnostic_mutation.out" 2>&1; then
    fail "$diagnostic_mutation diagnostic mutation was accepted"
  fi
  [ "$(cat "$diagnostic_sentinel")" = protected ] ||
    fail "$diagnostic_mutation diagnostic mutation changed an external sentinel"
  find "$runner_parent" -depth -mindepth 1 -delete
done

if TEST_DIAGNOSTICS_DIR="$other_tmp/escape" run_fixture \
    > "$fixture_parent/path-failure.out" 2>&1; then
  fail 'diagnostics outside RUNNER_TEMP were accepted'
fi
if TEST_LEGACY_REVISION=0000000000000000000000000000000000000000 run_fixture \
    > "$fixture_parent/ref-failure.out" 2>&1; then
  fail 'wrong legacy revision was accepted'
fi
if TEST_LEGACY_ORIGIN=https://github.com/example/hostile.git run_fixture \
    > "$fixture_parent/origin-failure.out" 2>&1; then
  fail 'wrong legacy origin was accepted'
fi
if TEST_LEGACY_DIRTY=1 run_fixture > "$fixture_parent/dirty-failure.out" 2>&1; then
  fail 'dirty legacy checkout was accepted'
fi
printf '%s\n' '# mutable controller manifest' >> "$fixture_repo/services/manifest.yml"
if run_fixture > "$fixture_parent/manifest-failure.out" 2>&1; then
  fail 'mutable controller manifest was accepted'
fi
cp "$repo_dir/services/manifest.yml" "$fixture_repo/services/manifest.yml"
ruby - "$fixture_repo/services/manifest.yml" <<'RUBY'
path = ARGV.fetch(0)
source = File.binread(path)
File.binwrite(path, source.sub("400f03f276ae1bb69f5460c175b9fb923d620f1a", "400f03f276ae1bb69f5460c175b9fb923d620f1z"))
RUBY
cp "$fixture_repo/services/manifest.yml" "$committed_manifest"
if run_fixture > "$fixture_parent/manifest-sha-failure.out" 2>&1; then
  fail 'non-hex manifest revision was accepted'
fi

printf '%s\n' 'Synthetic adoption integration: CI and wrapper contracts hold'
