#!/bin/sh
set -eu
set +x
umask 077

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$test_dir/../.." && pwd -P)
coordinator=$test_dir/adoption.sh

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

ansible_playbook=$(command -v ansible-playbook 2>/dev/null || true)
ansible_vault=$(command -v ansible-vault 2>/dev/null || true)
[ -x "$ansible_playbook" ] && [ -x "$ansible_vault" ] ||
  fail 'pinned Ansible is required for legacy parity rendering tests'
ansible_version=$("$ansible_playbook" --version 2>/dev/null | sed -n '1p')
case $ansible_version in
  'ansible-playbook [core 2.21.2]') ;;
  *) fail 'ansible-core 2.21.2 is required for legacy parity rendering tests' ;;
esac

temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-adoption-render.XXXXXX")
temporary_root=$(CDPATH= cd -- "$temporary_input" && pwd -P)
cleanup() {
  test_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$temporary_root" ] && [ ! -L "$temporary_root" ]; then
    /usr/bin/find "$temporary_root" -depth -delete
  fi
  exit "$test_status"
}
trap cleanup EXIT HUP INT TERM

legacy_root=$temporary_root/nas-infrastructure
mkdir -p "$legacy_root/.git"
ruby -ryaml -rfileutils - "$repo_dir/services/manifest.yml" "$legacy_root" <<'RUBY'
manifest = YAML.safe_load_file(ARGV.fetch(0))
manifest.fetch("services").each do |service|
  path = File.join(ARGV.fetch(1), service.fetch("legacy_path"))
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "services: {}\n")
end
RUBY

fake_bin=$temporary_root/bin
mkdir -m 0700 "$fake_bin"
cat > "$fake_bin/git" <<'SH'
#!/bin/sh
case " $* " in
  *' remote get-url origin ')
    printf '%s\n' 'https://github.com/yonatankarp/nas-infrastructure.git'
    ;;
  *' rev-parse --show-toplevel ')
    printf '%s\n' "${NAS_INFRASTRUCTURE_DIR:?}"
    ;;
  *' rev-parse HEAD ')
    printf '%s\n' '400f03f276ae1bb69f5460c175b9fb923d620f1a'
    ;;
  *' status --porcelain=v1 --untracked-files=all ') ;;
  *' ls-files --error-unmatch -- '*)
    for argument in "$@"; do path=$argument; done
    printf '%s\n' "$path"
    ;;
  *' ls-files -v -- '*)
    for argument in "$@"; do path=$argument; done
    printf 'H %s\n' "$path"
    ;;
  *' cat-file blob HEAD:'*)
    for argument in "$@"; do object=$argument; done
    cat "${NAS_INFRASTRUCTURE_DIR:?}/${object#HEAD:}"
    ;;
  *' ls-tree HEAD -- '*)
    for argument in "$@"; do path=$argument; done
    printf '100644 blob %040d\t%s\n' 0 "$path"
    ;;
  *) exit 2 ;;
esac
SH
cat > "$fake_bin/docker" <<'SH'
#!/bin/sh
[ "$*" = version ]
SH
chmod 0700 "$fake_bin/git" "$fake_bin/docker"

parity_root=$temporary_root/parity
parity_password=$parity_root/password
mkdir -m 0700 "$parity_root"
printf '%s\n' real-parity-disposable > "$parity_password"
chmod 0600 "$parity_password"
ruby -ryaml - "$repo_dir/config/portainer-parity.yml" "$parity_root" <<'RUBY'
mapping = YAML.safe_load_file(ARGV.fetch(0))
root = ARGV.fetch(1)
stacks = mapping.fetch("stacks").to_h do |stack, rules|
  [stack, rules.keys.to_h { |key| [key, "value-secret-canary"] }]
end
valid = {
  "schema" => 1,
  "legacy_commit" => mapping.fetch("legacy_commit"),
  "stacks" => stacks,
}
fixtures = {
  "valid" => valid,
  "extra-root" => valid.merge("unexpected" => "value-secret-canary"),
  "allowlist-escape" => {
    "schema" => 1,
    "legacy_commit" => mapping.fetch("legacy_commit"),
    "stacks" => {"../escaped" => {"A" => "value-secret-canary"}},
    "legacy_expected_services" => ["../escaped"],
  },
  "wrong-service-set" => valid.merge("stacks" => stacks.reject { |name, _values| name == "komga" }),
  "malformed-stack" => valid.merge("stacks" => stacks.merge("komga" => ["value-secret-canary"])),
}
fixtures.each do |name, document|
  File.write(File.join(root, "#{name}.yml"), YAML.dump(document), mode: "w", perm: 0o600)
end
RUBY
for fixture in valid extra-root allowlist-escape wrong-service-set malformed-stack; do
  "$ansible_vault" encrypt --vault-password-file "$parity_password" \
    --output "$parity_root/$fixture.vault" "$parity_root/$fixture.yml" >/dev/null
  rm -f -- "$parity_root/$fixture.yml"
done

create_sandbox() {
  sandbox=$temporary_root/nas-platform-mac.$1
  project_suffix=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  mkdir -m 0700 "$sandbox"
  printf 'schema=1\nproject=nas-platform-mac-%s\n' "$project_suffix" \
    > "$sandbox/.nas-platform-mac-owned"
  chmod 0600 "$sandbox/.nas-platform-mac-owned"
  printf '%s\n' "$sandbox"
}

run_render() {
  vault=$1
  sandbox=$2
  env PATH="$fake_bin:$(dirname -- "$ansible_playbook"):$PATH" \
    NAS_INFRASTRUCTURE_DIR="$legacy_root" PLATFORM_MAC_TMPDIR="$temporary_root" \
    PLATFORM_MAC_SANDBOX="$sandbox" PLATFORM_MAC_PARITY_VAULT_FILE="$vault" \
    PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE="$parity_password" "$coordinator" render
}

expect_validation_failure() {
  label=$1
  fixture=$2
  suffix=$3
  sandbox=$(create_sandbox "$suffix")
  output=$temporary_root/output
  if run_render "$parity_root/$fixture.vault" "$sandbox" > "$output" 2>&1; then
    fail "$label was accepted"
  fi
  grep -F value-secret-canary "$output" >/dev/null && fail "$label leaked a parity value"
  if [ -d "$sandbox/legacy-env" ] &&
     /usr/bin/find "$sandbox/legacy-env" -type f -print -quit | grep . >/dev/null; then
    fail "$label wrote a file inside publication"
  fi
  [ ! -e "$sandbox/escaped.env" ] || fail "$label escaped the publication root"
}

expect_validation_failure 'extra parity root field' extra-root ExRt01
expect_validation_failure 'parity allowlist path traversal' allowlist-escape Escp01
expect_validation_failure 'wrong parity service set' wrong-service-set Serv01
expect_validation_failure 'malformed parity stack mapping' malformed-stack Stak01

valid_sandbox=$(create_sandbox Vld001)
valid_output=$temporary_root/valid-output
if ! run_render "$parity_root/valid.vault" "$valid_sandbox" > "$valid_output" 2>&1; then
  valid_diagnostic=$(sed -n '1p' "$valid_output")
  fail "valid encrypted parity fixture was rejected: ${valid_diagnostic:-none}"
fi
grep -F value-secret-canary "$valid_output" >/dev/null && fail 'valid parity render leaked a value'
[ "$(/usr/bin/find "$valid_sandbox/legacy-env" -type f -name '*.env' | wc -l | tr -d ' ')" = 9 ] ||
  fail 'valid encrypted parity fixture did not render nine environments'

printf '%s\n' 'Mac adoption render: pinned Ansible rejects malicious parity fixtures'
