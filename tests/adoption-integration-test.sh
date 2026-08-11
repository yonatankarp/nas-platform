#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)

ruby -ryaml - "$repo_dir/.github/workflows/ci.yml" <<'RUBY'
workflow = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
jobs = workflow.fetch("jobs")
steps = jobs.fetch("validate").fetch("steps")

def one_step(steps, name)
  matches = steps.select { |step| step.is_a?(Hash) && step["name"] == name }
  raise "CI adoption contract: requires exactly one #{name.inspect} step" unless matches.length == 1
  matches.first
end

guard = "steps.scope.outputs.docs_only != 'true'"
legacy_revision = "400f03f276ae1bb69f5460c175b9fb923d620f1a"
checkout = one_step(steps, "Check out pinned legacy infrastructure")
raise "CI adoption contract: legacy checkout must use the full-lane guard" unless checkout["if"] == guard
checkout_run = checkout.fetch("run")
raise "CI adoption contract: legacy checkout uses a mutable ref" unless
  checkout_run.include?(legacy_revision) &&
    !checkout_run.match?(/\b(?:main|master|HEAD|latest)\b/)
raise "CI adoption contract: legacy checkout is not a non-repository sibling" unless
  checkout_run.include?('"$GITHUB_WORKSPACE/../nas-infrastructure"')
raise "CI adoption contract: legacy checkout repository differs" unless
  checkout_run.include?("https://github.com/yonatankarp/nas-infrastructure.git")

fresh = one_step(steps, "Converge against a disposable sandbox")
adoption = one_step(steps, "Converge synthetic legacy adoption")
raise "CI adoption contract: adoption must use the full-lane guard" unless adoption["if"] == guard
raise "CI adoption contract: adoption command changed" unless adoption["run"] == "tests/adoption-integration.sh"
raise "CI adoption contract: adoption must follow fresh convergence" unless steps.index(adoption) > steps.index(fresh)
environment = adoption.fetch("env")
expected_environment = {
  "NAS_INFRASTRUCTURE_DIR" => "${{ github.workspace }}/../nas-infrastructure",
  "ADOPTION_DIAGNOSTICS_DIR" => "${{ runner.temp }}/nas-platform-adoption-diagnostics"
}
raise "CI adoption contract: adoption environment is not closed" unless environment == expected_environment

upload = one_step(steps, "Upload sanitized adoption diagnostics")
raise "CI adoption contract: diagnostic upload guard changed" unless
  upload["if"] == "failure() && steps.scope.outputs.docs_only != 'true'"
raise "CI adoption contract: diagnostic uploader is not commit-pinned" unless
  upload.fetch("uses").match?(/\Aactions\/upload-artifact@[0-9a-f]{40}\z/)
upload_options = upload.fetch("with")
raise "CI adoption contract: raw adoption output could be uploaded" unless
  upload_options == {
    "name" => "synthetic-adoption-diagnostics",
    "path" => "${{ runner.temp }}/nas-platform-adoption-diagnostics/sanitized.txt",
    "if-no-files-found" => "ignore",
    "retention-days" => 1
  }
raise "CI adoption contract: diagnostic upload must follow convergence" unless steps.index(upload) > steps.index(adoption)
RUBY

[ -x "$repo_dir/tests/adoption-integration.sh" ] || {
  printf '%s\n' 'adoption integration contract: wrapper is missing or not executable' >&2
  exit 1
}
sh -n "$repo_dir/tests/adoption-integration.sh"
ruby - "$repo_dir/tests/mac/run.sh" "$repo_dir/tests/mac/legacy-seed.sh" <<'RUBY'
runner, legacy_seed = ARGV.map { |path| File.binread(path) }
run_site = runner[/^run_site\(\) \{.*?^\}/m]
integration_branch = run_site && run_site[/if \[ "\$proof_platform" = integration \]; then.*?\n  fi/m]
raise "runner contract: integration site branch is missing" unless integration_branch
raise "runner contract: integration compose mode is missing" unless
  integration_branch.include?("platform_compose_kind=integration") &&
    integration_branch.include?("deployment_bundle_test_mode=true")
raise "runner contract: test mode escaped integration branch" unless
  runner.scan("deployment_bundle_test_mode=true").length == 1
raise "runner contract: dirty-controller bypass is enabled" if
  runner.include?("deployment_bundle_allow_dirty_controller=true")
raise "runner contract: legacy seed does not preserve Mac capabilities" unless
  legacy_seed.include?("platform_kind=mac") && legacy_seed.include?("platform_compose_kind=integration")
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
for argument in "$@"; do printf '<%s>' "$argument" >> "${FAKE_COORDINATOR_LOG:?}"; done
printf '\n' >> "${FAKE_COORDINATOR_LOG:?}"
[ "${FAKE_COORDINATOR_FAIL:-0}" = 0 ]
SH
cat > "$fixture_repo/tests/mac/cleanup.sh" <<'SH'
#!/bin/sh
set -eu
printf 'sandbox:%s\n' "$1" >> "${FAKE_CLEANUP_LOG:?}"
find "$1" -depth -mindepth 1 -delete
rmdir -- "$1"
report=$1.reports
if [ -d "$report" ]; then find "$report" -depth -mindepth 1 -delete; rmdir -- "$report"; fi
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
chmod 0755 "$fake_bin/uname" "$fake_bin/git" "$fake_bin/ansible-vault"

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
: > "$vault_log"; : > "$import_log"; : > "$coordinator_log"; : > "$cleanup_log"

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
[ "$(grep -c '^generate:' "$vault_log")" -eq 1 ] || fail 'deployment vault was not generated once'
[ "$(grep -c '^import:' "$import_log")" -eq 1 ] || fail 'parity vault was not imported once'
deployment_root=$(sed -n 's/^generate:\([^:]*\)\/vault.yml:.*/\1/p' "$vault_log")
parity_root=$(sed -n 's/^import:[^:]*:\([^:]*\)\/vault.yml:.*/\1/p' "$import_log")
[ -n "$deployment_root" ] && [ -n "$parity_root" ] && [ "$deployment_root" != "$parity_root" ] ||
  fail 'deployment and parity credentials share a namespace'
grep -F 'coordinator-argv:<--lane><adoption><--platform><integration><--integration-ports-file>' \
  "$coordinator_log" >/dev/null || fail 'coordinator did not receive full integration mode'
fixture_legacy_physical=$(CDPATH= cd -- "$fixture_legacy" && pwd -P)
runner_parent_physical=$(CDPATH= cd -- "$runner_parent" && pwd -P)
grep -F "coordinator-env:$fixture_legacy_physical:$runner_parent_physical/" "$coordinator_log" >/dev/null ||
  fail 'coordinator did not receive the pinned sibling or owned root'
[ "$(grep -c '^vault-cleanup:' "$cleanup_log")" -eq 2 ] ||
  fail 'credential namespaces were not cleaned exactly once'
grep -c '^sandbox:' "$cleanup_log" | grep -qx 1 || fail 'coordinator sandbox cleanup differs'
grep -c '^outer:' "$cleanup_log" | grep -qx 1 || fail 'outer contained cleanup differs'

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
