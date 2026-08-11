#!/bin/sh
set -eu
set +x
umask 077

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/adoption-failure-stop.XXXXXX")
fixture=$(CDPATH= cd -- "$fixture" && pwd -P)
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  find "$fixture" -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir "$fixture" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
fail() { printf '%s\n' "$1" >&2; exit 1; }

ruby - "$test_dir/run.sh" > "$fixture/functions.sh" <<'RUBY'
source = File.read(ARGV.fetch(0))
run_site = source.match(/^run_site\(\) \{\n.*?^\}/m) or raise "run_site is unavailable"
mapping = source.match(/^enable_adoption_mapping\(\) \{\n.*?^\}/m) or raise "mapping is unavailable"
execute_phase = source.index("execute_phase()") or raise "execute_phase is unavailable"
cutover = source[execute_phase..].match(/^    cutover\)\n(?<body>.*?)^      ;;/m) or raise "cutover is unavailable"
puts run_site[0]
puts "execute_cutover() {"
puts cutover[:body]
puts "}"
raise "cutover does not stop at mapping failure" unless cutover[:body].include?("enable_adoption_mapping cutover || return")
raise "cutover does not stop at target failure" unless cutover[:body].include?("run_site || return")
raise "cutover does not preserve verifier failure" unless
  cutover[:body].include?("cutover_verify_status") && cutover[:body].include?("adoption-stop-targets.sh")
raise "run_site does not stop failed adoption targets" unless run_site[0].include?("adoption-stop-targets.sh")
raise "mapping activation masks cutover validation failure" unless
  mapping[0].include?('adoption.sh" cutover || return') && mapping[0].scan(/return 1/).length >= 3
RUBY

mkdir -m 0700 "$fixture/bin" "$fixture/helpers"
cat > "$fixture/bin/ansible-playbook" <<'SH'
#!/bin/sh
printf '%s\n' ansible >> "${FAILURE_ORDER_LOG:?}"
[ "${LATE_ANSIBLE_FAILURE:-false}" != true ] || exit 7
exit 0
SH
cat > "$fixture/helpers/adoption-container-attest.sh" <<'SH'
#!/bin/sh
printf '%s\n' attester >> "${FAILURE_ORDER_LOG:?}"
exit 0
SH
cat > "$fixture/helpers/adoption-stop-targets.sh" <<'SH'
#!/bin/sh
printf '%s\n' stop-targets >> "${FAILURE_ORDER_LOG:?}"
exit 0
SH
cat > "$fixture/helpers/verify.sh" <<'SH'
#!/bin/sh
printf '%s\n' verifier >> "${FAILURE_ORDER_LOG:?}"
[ "${LATE_VERIFY_FAILURE:-false}" != true ] || exit 6
exit 0
SH
chmod 0700 "$fixture/bin/ansible-playbook" "$fixture/helpers"/*.sh

FAILURE_ORDER_LOG=$fixture/cutover-order.log
export FAILURE_ORDER_LOG
PATH="$fixture/bin:$PATH"
export PATH
lane=adoption
mac_script_dir=$fixture/helpers
mac_repo_dir=$fixture/repo
vault_password_file=$fixture/password
vault_file=$fixture/vault
enable_adoption_mapping() { printf '%s\n' mapping >> "$FAILURE_ORDER_LOG"; }
. "$fixture/functions.sh"
cutover_state=$fixture/cutover-state.json
"$test_dir/report.rb" --init "$cutover_state" --lane adoption \
  --sandbox-id nas-platform-mac.Fail42 --git-revision "$(printf '%040d' 1)" \
  --vault-checksum "$(printf '%064d' 2)" --parity-vault-checksum "$(printf '%064d' 3)" \
  --legacy-commit "$(printf '%040d' 4)" --project-name nas-platform-mac-fail42 \
  --beszel-port 31001 --ntfy-port 31002 --dozzle-port 31003 --audiobookshelf-port 31004 \
  --komga-port 31005 --tinymediamanager-web-port 31006 --tinymediamanager-api-port 31007 \
  --jellyfin-port 31008 --immich-port 31009 --paperless-port 31010
"$test_dir/report.rb" --record "$cutover_state" --phase cutover --status running
LATE_ANSIBLE_FAILURE=true
export LATE_ANSIBLE_FAILURE
if execute_cutover; then
  "$test_dir/report.rb" --record "$cutover_state" --phase cutover --status passed
else
  "$test_dir/report.rb" --record "$cutover_state" --phase cutover --status failed
fi
ruby -rjson -e '
  phase = JSON.parse(File.read(ARGV.fetch(0))).fetch("phases").find { |entry| entry["name"] == "cutover" }
  abort unless phase.fetch("status") == "failed"
' "$cutover_state" || fail 'late Ansible failure recorded cutover as passed'
[ "$(tr '\n' ' ' < "$FAILURE_ORDER_LOG")" = 'mapping ansible attester stop-targets ' ] ||
  fail 'cutover failure order differs or verifier ran after a failed target operation'

: > "$FAILURE_ORDER_LOG"
LATE_ANSIBLE_FAILURE=false
LATE_VERIFY_FAILURE=true
export LATE_ANSIBLE_FAILURE LATE_VERIFY_FAILURE
if execute_cutover; then
  fail 'failed cutover verifier was accepted'
fi
[ "$(tr '\n' ' ' < "$FAILURE_ORDER_LOG")" = 'mapping ansible attester verifier stop-targets ' ] ||
  fail 'verifier failure did not stop all target projects in order'

mkdir -m 0700 -p "$fixture/hook-tree/hooks/fixtures-recreate"
cp "$test_dir"/hooks/fixtures-recreate/*.sh "$fixture/hook-tree/hooks/fixtures-recreate/"
cat > "$fixture/hook-tree/adoption-container-attest.sh" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$fixture/hook-tree/adoption-stop-targets.sh" <<'SH'
#!/bin/sh
printf '%s\n' "${CURRENT_HOOK:?}" >> "${HOOK_STOP_LOG:?}"
SH
cat > "$fixture/hook-tree/run-beszel-contract.sh" <<'SH'
#!/bin/sh
exit 8
SH
chmod 0700 "$fixture/hook-tree"/*.sh
cat > "$fixture/bin/docker" <<'SH'
#!/bin/sh
[ -z "${HOSTILE_DOCKER_MARKER:-}" ] || printf '%s\n' "$*" >> "$HOSTILE_DOCKER_MARKER"
case " $* " in
  *' compose '*' up -d --force-recreate --wait '*) exit 8 ;;
  *) exit 0 ;;
esac
SH
chmod 0700 "$fixture/bin/docker"
mkdir -m 0700 "$fixture/docker-root"
HOOK_STOP_LOG=$fixture/hook-stops.log
export HOOK_STOP_LOG
for hook in "$fixture/hook-tree/hooks/fixtures-recreate"/[1-8]0-*.sh; do
  CURRENT_HOOK=$(basename -- "$hook")
  export CURRENT_HOOK
  if PLATFORM_PROOF_LANE=adoption PLATFORM_DOCKER_ROOT=$fixture/docker-root \
    PLATFORM_PROJECT_NAME=nas-platform-mac-failure PATH="$fixture/bin:$PATH" "$hook"; then
    fail "$CURRENT_HOOK accepted a partial Compose recreation"
  fi
done
[ "$(wc -l < "$HOOK_STOP_LOG" | tr -d ' ')" = 8 ] ||
  fail 'not every recreation hook stopped all adoption targets after partial Compose failure'

hostile_sandbox=$fixture/nas-platform-mac.Safe12
mkdir -m 0700 "$hostile_sandbox"
printf 'schema=1\nproject=nas-platform-mac-safe12\n' > "$hostile_sandbox/.nas-platform-mac-owned"
chmod 0600 "$hostile_sandbox/.nas-platform-mac-owned"
rm -f "$fixture/hostile-docker-calls"
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_ADOPTION_ENABLED=true PLATFORM_ADOPTION_ROOT=$hostile_sandbox \
  PLATFORM_PROJECT_NAME=nas-platform-mac-hostile PATH="$fixture/bin:$PATH" \
  HOSTILE_DOCKER_MARKER=$fixture/hostile-docker-calls \
  "$test_dir/adoption-stop-targets.sh" >/dev/null 2>&1; then
  fail 'stop-all helper accepted a project not bound to the owned sandbox'
fi
[ ! -e "$fixture/hostile-docker-calls" ] || fail 'mismatched project reached Docker stop operations'
if PLATFORM_MAC_TMPDIR=$fixture PLATFORM_ADOPTION_ENABLED=true PLATFORM_ADOPTION_ROOT=$fixture/missing-sandbox \
  PLATFORM_PROJECT_NAME=nas-platform-mac-safe12 PATH="$fixture/bin:$PATH" \
  HOSTILE_DOCKER_MARKER=$fixture/hostile-docker-calls \
  "$test_dir/adoption-stop-targets.sh" >/dev/null 2>&1; then
  fail 'stop-all helper accepted an invalid adoption sandbox'
fi
[ ! -e "$fixture/hostile-docker-calls" ] || fail 'invalid sandbox reached Docker stop operations'
PLATFORM_MAC_TMPDIR=$fixture PLATFORM_ADOPTION_ENABLED=true PLATFORM_ADOPTION_ROOT=$hostile_sandbox \
  PLATFORM_PROJECT_NAME=nas-platform-mac-safe12 PATH="$fixture/bin:$PATH" \
  HOSTILE_DOCKER_MARKER=$fixture/hostile-docker-calls \
  "$test_dir/adoption-stop-targets.sh" >/dev/null 2>&1 ||
  fail 'stop-all helper rejected the exact owned adoption context'
[ "$(wc -l < "$fixture/hostile-docker-calls" | tr -d ' ')" = 9 ] ||
  fail 'valid owned adoption context did not inspect all target projects'

printf '%s\n' 'Adoption failure stop: cutover and recreation failures stop targets'
