#!/bin/sh
set -eu
set +x
umask 077

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)
runner=$mac_test_dir/run.sh
reporter=$mac_test_dir/report.rb

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-adoption-runner.XXXXXX")
temporary_parent=$(CDPATH= cd -- "$temporary_input" && pwd -P)
in_repo_input=
cleanup_fixture() {
  fixture_status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$in_repo_input" ] && [ -f "$in_repo_input" ] && [ ! -L "$in_repo_input" ]; then
    rm -f -- "$in_repo_input"
  fi
  if [ -d "$temporary_parent" ] && [ ! -L "$temporary_parent" ]; then
    find "$temporary_parent" -depth -mindepth 1 -delete
    rmdir -- "$temporary_parent"
  fi
  exit "$fixture_status"
}
trap cleanup_fixture EXIT HUP INT TERM

vault_file=$temporary_parent/deployment-vault.yml
parity_vault_file=$temporary_parent/parity-vault.yml
password_file=$temporary_parent/deployment-password
parity_password_file=$temporary_parent/parity-password
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$vault_file"
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$parity_vault_file"
printf '%s\n' disposable > "$password_file"
printf '%s\n' parity-disposable > "$parity_password_file"
chmod 0600 "$vault_file" "$parity_vault_file" "$password_file" "$parity_password_file"

expect_failure() {
  label=$1
  expected=$2
  shift 2
  output=$temporary_parent/output
  if "$@" >"$output" 2>&1; then
    fail "$label was accepted"
  fi
  if ! grep -F "$expected" "$output" >/dev/null; then
    actual=$(sed -n '/protected .* input/p' "$output" | head -n 1)
    fail "$label emitted the wrong diagnostic: ${actual:-none}"
  fi
}

ruby - "$runner" <<'RUBY'
source = File.read(ARGV.fetch(0))
fresh = "preflight deploy seed verify idempotence drift reconcile recreate persistence report cleanup"
adoption = "preflight legacy-deploy legacy-seed capture-baseline snapshot cutover verify " \
           "idempotence recreate persistence rollback report cleanup"
raise "fresh phase graph differs" unless source.match?(/^FRESH_PHASES=' #{Regexp.escape(fresh)} '$/)
raise "adoption phase graph differs" unless source.match?(/^ADOPTION_PHASES=' #{Regexp.escape(adoption)} '$/)
parser = source.index("while [ \"$#\" -gt 0 ]")
fresh_definition = source.index("FRESH_PHASES=")
adoption_definition = source.index("ADOPTION_PHASES=")
lane_validation = source.index("case $lane in")
phase_assignment = source.index("PHASES=$FRESH_PHASES")
raise "phase constants must precede parsing" unless [fresh_definition, adoption_definition].all? { |index| index && index < parser }
raise "phase selection must follow lane validation" unless lane_validation && phase_assignment && lane_validation < phase_assignment
RUBY

help_output=$temporary_parent/help
"$runner" --help > "$help_output"
grep -F -- '--parity-vault-file FILE' "$help_output" >/dev/null || fail 'usage omits parity vault option'
grep -F -- '--parity-vault-password-file FILE_OR_EXECUTABLE' "$help_output" >/dev/null ||
  fail 'usage omits parity password option'

expect_failure 'adoption without parity vault' 'adoption requires --parity-vault-file' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file"
expect_failure 'adoption without parity password' 'adoption requires --parity-vault-password-file' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file"
expect_failure 'fresh parity options' 'fresh lane rejects parity vault options' \
  "$runner" --lane fresh --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file"
expect_failure 'same explicit password path' 'unknown phase: not-a-phase' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$password_file" \
    --phase not-a-phase

parity_link=$temporary_parent/parity-link.yml
ln -s "$parity_vault_file" "$parity_link"
expect_failure 'symlink parity vault' 'parity vault file must be a readable, regular encrypted file' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_link" --parity-vault-password-file "$parity_password_file"
password_link=$temporary_parent/parity-password-link
ln -s "$parity_password_file" "$password_link"
expect_failure 'symlink parity password' 'parity vault password input must be a readable file or executable' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$password_link"
nonregular_input=$temporary_parent/nonregular-input
mkdir "$nonregular_input"
expect_failure 'nonregular parity vault' 'parity vault file must be a readable, regular encrypted file' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$nonregular_input" --parity-vault-password-file "$parity_password_file"
expect_failure 'nonregular parity password' 'parity vault password input must be a readable file or executable' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$nonregular_input"

in_repo_input=$(mktemp "$mac_test_dir/.adoption-parity.XXXXXX")
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$in_repo_input"
chmod 0600 "$in_repo_input"
expect_failure 'repository parity vault' 'parity vault file must remain outside the repository' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$in_repo_input" --parity-vault-password-file "$parity_password_file"
expect_failure 'repository parity password' 'parity vault password input must remain outside the repository' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$in_repo_input"
rm -f -- "$in_repo_input"
in_repo_input=

swap_fixture=$temporary_parent/swap-input.rb
cat > "$swap_fixture" <<'RUBY'
module AdoptionInputSwapFixture
  module_function

  def swap(path, stage)
    return unless ENV["PLATFORM_SWAP_STAGE"] == stage.to_s
    target = ENV.fetch("PLATFORM_SWAP_TARGET")
    return unless File.expand_path(path.to_s) == File.expand_path(target) ||
                  File.basename(path.to_s) == File.basename(target)
    return if @swapped

    @swapped = true
    File.rename(ENV.fetch("PLATFORM_SWAP_REPLACEMENT"), ENV.fetch("PLATFORM_SWAP_TARGET"))
  end
end

require "open3"
class << Open3
  alias adoption_input_original_popen3 popen3

  def popen3(*arguments, **keywords, &block)
    if ENV["PLATFORM_SWAP_STAGE"] == "parent_spawn"
      target = ENV.fetch("PLATFORM_SWAP_PARENT_TARGET")
      holding = ENV.fetch("PLATFORM_SWAP_PARENT_HOLDING")
      replacement = ENV.fetch("PLATFORM_SWAP_PARENT_REPLACEMENT")
      File.rename(target, holding)
      File.rename(replacement, target)
      begin
        return adoption_input_original_popen3(*arguments, **keywords, &block)
      ensure
        File.rename(target, replacement)
        File.rename(holding, target)
      end
    end

    if ENV["PLATFORM_SWAP_STAGE"] == "spawn"
      AdoptionInputSwapFixture.swap(ENV.fetch("PLATFORM_SWAP_TARGET"), :spawn)
    end
    adoption_input_original_popen3(*arguments, **keywords, &block)
  end
end

class << File
  alias adoption_input_original_open open

  def open(path, *arguments, **keywords, &block)
    AdoptionInputSwapFixture.swap(path, :open)
    adoption_input_original_open(path, *arguments, **keywords, &block)
  end
end

class File
  alias adoption_input_original_read read

  def read(*arguments, **keywords)
    AdoptionInputSwapFixture.swap(path, :read)
    adoption_input_original_read(*arguments, **keywords)
  end
end
RUBY

swapped_vault=$temporary_parent/swapped-parity-vault.yml
vault_replacement=$temporary_parent/parity-vault-replacement.yml
cp "$parity_vault_file" "$swapped_vault"
printf '%s\n%s\n' '$ANSIBLE_VAULT;1.1;AES256' replacement-ciphertext > "$vault_replacement"
chmod 0600 "$swapped_vault" "$vault_replacement"
expect_failure 'parity vault validation-to-open replacement' \
  'protected parity vault input changed while being pinned' \
  env RUBYOPT="-r$swap_fixture" PLATFORM_SWAP_STAGE=open \
    PLATFORM_SWAP_TARGET="$swapped_vault" PLATFORM_SWAP_REPLACEMENT="$vault_replacement" \
    PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$swapped_vault" --parity-vault-password-file "$parity_password_file" \
    --phase report
if grep -F replacement-ciphertext "$temporary_parent/output" >/dev/null; then
  fail 'parity vault replacement diagnostic leaked protected bytes'
fi

swapped_password=$temporary_parent/swapped-parity-password
password_replacement=$temporary_parent/parity-password-replacement
printf '%s\n' original-disposable > "$swapped_password"
printf '%s\n' replacement-disposable > "$password_replacement"
chmod 0600 "$swapped_password" "$password_replacement"
expect_failure 'parity password opened-descriptor replacement' \
  'protected parity password input changed while being pinned' \
  env RUBYOPT="-r$swap_fixture" PLATFORM_SWAP_STAGE=read \
    PLATFORM_SWAP_TARGET="$swapped_password" PLATFORM_SWAP_REPLACEMENT="$password_replacement" \
    PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$swapped_password" \
    --phase report
if grep -F replacement-disposable "$temporary_parent/output" >/dev/null; then
  fail 'parity password replacement diagnostic leaked protected bytes'
fi

provider_swap=$temporary_parent/provider-swap
provider_swap_replacement=$temporary_parent/provider-swap-replacement
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" original-provider-output' > "$provider_swap"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" replacement-provider-output' > "$provider_swap_replacement"
chmod 0700 "$provider_swap" "$provider_swap_replacement"
expect_failure 'parity provider validation-to-exec replacement' \
  'protected parity password input changed while being pinned' \
  env RUBYOPT="-r$swap_fixture" PLATFORM_SWAP_STAGE=spawn \
    PLATFORM_SWAP_TARGET="$provider_swap" PLATFORM_SWAP_REPLACEMENT="$provider_swap_replacement" \
    PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$provider_swap" \
    --phase report
if grep -F replacement-provider-output "$temporary_parent/output" >/dev/null; then
  fail 'replaced parity provider leaked stdout'
fi

during_provider=$temporary_parent/provider-during-exec
during_replacement=$temporary_parent/provider-during-exec-replacement
printf '%s\n' '#!/bin/sh' 'mv -f -- "${PLATFORM_PROVIDER_DURING_REPLACEMENT:?}" "$0"' \
  'printf "%s\\n" during-exec-output' > "$during_provider"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" replaced-output' > "$during_replacement"
chmod 0700 "$during_provider" "$during_replacement"
expect_failure 'parity provider during-exec replacement' \
  'protected parity password input changed while being pinned' \
  env PLATFORM_PROVIDER_DURING_REPLACEMENT="$during_replacement" \
    PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$during_provider" \
    --phase report
if grep -F during-exec-output "$temporary_parent/output" >/dev/null; then
  fail 'mutated parity provider leaked stdout'
fi

transient_root=$temporary_parent/transient-provider
transient_parent=$transient_root/current
transient_holding=$transient_root/held
transient_replacement=$transient_root/replacement
mkdir -p "$transient_parent" "$transient_replacement"
printf '%s\n' '#!/bin/sh' '"$(dirname -- "$0")/helper"' > "$transient_parent/provider"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" held-directory-output' > "$transient_parent/helper"
printf '%s\n' '#!/bin/sh' '"$(dirname -- "$0")/helper"' > "$transient_replacement/provider"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" transient-replacement-secret' > "$transient_replacement/helper"
chmod 0700 "$transient_parent/provider" "$transient_parent/helper" \
  "$transient_replacement/provider" "$transient_replacement/helper"
transient_sandbox=$temporary_parent/nas-platform-mac.FdA123
mkdir -m 0700 "$transient_sandbox"
printf 'schema=1\nproject=%s\n' nas-platform-mac-fda123 > "$transient_sandbox/.nas-platform-mac-owned"
chmod 0600 "$transient_sandbox/.nas-platform-mac-owned"
transient_output=$temporary_parent/transient-output
RUBYOPT="-r$swap_fixture" PLATFORM_SWAP_STAGE=parent_spawn \
  PLATFORM_SWAP_PARENT_TARGET="$transient_parent" \
  PLATFORM_SWAP_PARENT_HOLDING="$transient_holding" \
  PLATFORM_SWAP_PARENT_REPLACEMENT="$transient_replacement" \
  PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" \
    --parity-vault-password-file "$transient_parent/provider" \
    --phase report --sandbox "$transient_sandbox" > "$transient_output" 2>&1 ||
  fail 'transient provider parent swap did not preserve held-directory execution'
printf '%s\n' held-directory-output > "$temporary_parent/transient-expected"
cmp -s "$temporary_parent/transient-expected" \
  "$transient_sandbox/protected-inputs/parity-password" ||
  fail 'transient parent swap executed the replacement provider'
if grep -F transient-replacement-secret "$transient_output" >/dev/null; then
  fail 'transient replacement provider leaked output'
fi
[ -d "$transient_parent" ] && [ -d "$transient_replacement" ] && [ ! -e "$transient_holding" ] ||
  fail 'transient parent swap fixture did not restore the original pathname'

nonzero_provider=$temporary_parent/provider-nonzero
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" provider-nonzero-secret' \
  'printf "%s\\n" provider-nonzero-secret >&2' 'exit 7' > "$nonzero_provider"
chmod 0700 "$nonzero_provider"
expect_failure 'nonzero parity provider' 'protected parity password input provider failed' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$nonzero_provider" \
    --phase report
if grep -F provider-nonzero-secret "$temporary_parent/output" >/dev/null; then
  fail 'nonzero parity provider leaked stderr'
fi

timeout_provider=$temporary_parent/provider-timeout
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" provider-timeout-secret' \
  'printf "%s\\n" provider-timeout-secret >&2' 'sleep 10' > "$timeout_provider"
chmod 0700 "$timeout_provider"
expect_failure 'timed out parity provider' 'protected parity password input provider timed out' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$timeout_provider" \
    --phase report
if grep -F provider-timeout-secret "$temporary_parent/output" >/dev/null; then
  fail 'timed out parity provider leaked stderr'
fi

oversize_provider=$temporary_parent/provider-oversize
printf '%s\n' '#!/bin/sh' "$(command -v ruby) -e 'STDOUT.write(%q{x} * (1024 * 1024 + 1))'" \
  > "$oversize_provider"
chmod 0700 "$oversize_provider"
expect_failure 'oversized parity provider output' \
  'protected parity password input provider output exceeds the size limit' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$oversize_provider" \
    --phase report

git_revision=$(git -C "$repo_dir" rev-parse HEAD)
vault_checksum=$(shasum -a 256 "$vault_file" | awk '{print $1}')
parity_checksum=$(shasum -a 256 "$parity_vault_file" | awk '{print $1}')
legacy_commit=$(ruby -ryaml -e 'print YAML.safe_load_file(ARGV.fetch(0)).fetch("legacy_source").fetch("commit")' \
  "$repo_dir/services/manifest.yml")

pinning_vault=$temporary_parent/pinning-parity-vault.yml
pinning_vault_expected=$temporary_parent/pinning-parity-vault-expected.yml
pinning_vault_replacement=$temporary_parent/pinning-parity-vault-replacement.yml
pinning_password=$temporary_parent/pinning-parity-password
pinning_password_expected=$temporary_parent/pinning-parity-password-expected
pinning_password_replacement=$temporary_parent/pinning-parity-password-replacement
pinning_password_helper=$temporary_parent/pinning-password-helper
pinning_password_log=$temporary_parent/pinning-password.log
printf '%s\n%s\n' '$ANSIBLE_VAULT;1.1;AES256' pinned-original-ciphertext > "$pinning_vault"
cp "$pinning_vault" "$pinning_vault_expected"
printf '%s\n%s\n' '$ANSIBLE_VAULT;1.1;AES256' post-pin-replacement > "$pinning_vault_replacement"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" pinned-original-password' > "$pinning_password_helper"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" invoked >> "${PLATFORM_PINNING_PASSWORD_LOG:?}"' \
  '"$(dirname -- "$0")/pinning-password-helper"' > "$pinning_password"
printf '%s\n' pinned-original-password > "$pinning_password_expected"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" post-pin-password' > "$pinning_password_replacement"
chmod 0600 "$pinning_vault" "$pinning_vault_expected" "$pinning_vault_replacement"
chmod 0700 "$pinning_password" "$pinning_password_helper" "$pinning_password_replacement"
chmod 0600 "$pinning_password_expected"
pinning_checksum=$(shasum -a 256 "$pinning_vault_expected" | awk '{print $1}')

pinning_sandbox=$temporary_parent/nas-platform-mac.Pin123
pinning_project=nas-platform-mac-pin123
mkdir -m 0700 "$pinning_sandbox"
printf 'schema=1\nproject=%s\n' "$pinning_project" > "$pinning_sandbox/.nas-platform-mac-owned"
chmod 0600 "$pinning_sandbox/.nas-platform-mac-owned"
pinning_fake_bin=$temporary_parent/pinning-tools
mkdir -m 0700 "$pinning_fake_bin"
real_shasum=$(command -v shasum)
cat > "$pinning_fake_bin/shasum" <<'STUB'
#!/bin/sh
last=
for argument in "$@"; do last=$argument; done
if [ "$last" = "${PLATFORM_PINNED_PARITY_PATH:?}" ]; then
  mv -f -- "${PLATFORM_PINNING_VAULT_REPLACEMENT:?}" "${PLATFORM_PINNING_VAULT_SOURCE:?}"
  mv -f -- "${PLATFORM_PINNING_PASSWORD_REPLACEMENT:?}" "${PLATFORM_PINNING_PASSWORD_SOURCE:?}"
fi
exec "${PLATFORM_REAL_SHASUM:?}" "$@"
STUB
chmod 0755 "$pinning_fake_bin/shasum"
PLATFORM_REAL_SHASUM=$real_shasum \
  PLATFORM_PINNED_PARITY_PATH="$pinning_sandbox/protected-inputs/parity-vault.yml" \
  PLATFORM_PINNING_VAULT_SOURCE="$pinning_vault" \
  PLATFORM_PINNING_VAULT_REPLACEMENT="$pinning_vault_replacement" \
  PLATFORM_PINNING_PASSWORD_SOURCE="$pinning_password" \
  PLATFORM_PINNING_PASSWORD_REPLACEMENT="$pinning_password_replacement" \
  PLATFORM_PINNING_PASSWORD_LOG="$pinning_password_log" \
  PLATFORM_MAC_TMPDIR="$temporary_parent" PATH="$pinning_fake_bin:$PATH" \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$pinning_password" \
    --parity-vault-file "$pinning_vault" --parity-vault-password-file "$pinning_password" \
    --phase report --sandbox "$pinning_sandbox" >/dev/null 2>&1 ||
  fail 'post-pin source replacement changed the protected adoption inputs'
cmp -s "$pinning_vault_expected" "$pinning_sandbox/protected-inputs/parity-vault.yml" ||
  fail 'pinned parity ciphertext differs from the opened descriptor bytes'
cmp -s "$pinning_password_expected" "$pinning_sandbox/protected-inputs/parity-password" ||
  fail 'pinned executable parity password provider differs from the opened descriptor bytes'
if [ "$(uname -s)" = Darwin ]; then
  pinned_vault_mode=$(stat -f '%Lp' "$pinning_sandbox/protected-inputs/parity-vault.yml")
  pinned_password_mode=$(stat -f '%Lp' "$pinning_sandbox/protected-inputs/parity-password")
  pinned_deployment_password_mode=$(stat -f '%Lp' "$pinning_sandbox/protected-inputs/deployment-password")
else
  pinned_vault_mode=$(stat -c '%a' "$pinning_sandbox/protected-inputs/parity-vault.yml")
  pinned_password_mode=$(stat -c '%a' "$pinning_sandbox/protected-inputs/parity-password")
  pinned_deployment_password_mode=$(stat -c '%a' "$pinning_sandbox/protected-inputs/deployment-password")
fi
[ "$pinned_vault_mode" = 600 ] || fail 'pinned parity ciphertext mode is unsafe'
[ "$pinned_password_mode" = 600 ] || fail 'pinned provider output mode is unsafe'
[ "$pinned_deployment_password_mode" = 600 ] || fail 'pinned regular password input mode is unsafe'
[ "$(wc -l < "$pinning_password_log" | tr -d ' ')" = 1 ] ||
  fail 'executable parity password provider did not run exactly once'
recorded_pinning_checksum=$(ruby -rjson -e '
  print JSON.parse(File.read(ARGV.fetch(0))).fetch("parity_vault_checksum")
' "$pinning_sandbox.reports/phase-input.json")
[ "$recorded_pinning_checksum" = "$pinning_checksum" ] ||
  fail 'reported parity checksum does not bind the pinned ciphertext bytes'
[ ! -e "$pinning_vault_replacement" ] && [ ! -e "$pinning_password_replacement" ] ||
  fail 'post-pin replacement fixture did not execute'

initialize_adoption_state() {
  sandbox=$1
  recorded_parity_checksum=$2
  recorded_legacy_commit=$3
  recorded_vault_checksum=${4:-$vault_checksum}
  report_root=$sandbox.reports
  suffix=$(printf '%s' "${sandbox##*.}" | tr '[:upper:]' '[:lower:]')
  project_name=nas-platform-mac-$suffix
  mkdir -m 0700 "$sandbox" "$report_root"
  printf 'schema=1\nproject=%s\n' "$project_name" > "$sandbox/.nas-platform-mac-owned"
  chmod 0600 "$sandbox/.nas-platform-mac-owned"
  printf 'schema=1\nsandbox=%s\n' "$(basename -- "$sandbox")" \
    > "$report_root/.nas-platform-mac-report-owned"
  chmod 0600 "$report_root/.nas-platform-mac-report-owned"
  "$reporter" --init "$report_root/phase-input.json" --lane adoption \
    --sandbox-id "$(basename -- "$sandbox")" --git-revision "$git_revision" \
    --vault-checksum "$recorded_vault_checksum" --parity-vault-checksum "$recorded_parity_checksum" \
    --legacy-commit "$recorded_legacy_commit" --project-name "$project_name" \
    --beszel-port 38090 --ntfy-port 32586 --dozzle-port 38080 \
    --audiobookshelf-port 33378 --komga-port 35600 \
    --tinymediamanager-web-port 34000 --tinymediamanager-api-port 37878 \
    --jellyfin-port 38096 --immich-port 32283 --paperless-port 38000
}

deployment_sandbox=$temporary_parent/nas-platform-mac.Dep123
initialize_adoption_state "$deployment_sandbox" "$parity_checksum" "$legacy_commit" "$(printf '%064d' 0)"
expect_failure 'resumed adoption deployment checksum mismatch' \
  'resume vault checksum does not match the recorded run' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
    --phase report --sandbox "$deployment_sandbox"

checksum_sandbox=$temporary_parent/nas-platform-mac.Chk123
initialize_adoption_state "$checksum_sandbox" "$(printf '%064d' 0)" "$legacy_commit"
expect_failure 'resumed adoption parity checksum mismatch' \
  'resume parity vault checksum does not match the recorded run' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
    --phase report --sandbox "$checksum_sandbox"

legacy_sandbox=$temporary_parent/nas-platform-mac.Leg123
initialize_adoption_state "$legacy_sandbox" "$parity_checksum" "$(printf '%040d' 0)"
expect_failure 'resumed adoption legacy commit mismatch' \
  'resume legacy commit does not match the recorded run' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
    --phase report --sandbox "$legacy_sandbox"

matching_sandbox=$temporary_parent/nas-platform-mac.OkA123
initialize_adoption_state "$matching_sandbox" "$parity_checksum" "$legacy_commit"
env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
  --vault-file "$vault_file" --vault-password-file "$password_file" \
  --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
  --phase report --sandbox "$matching_sandbox" >/dev/null 2>&1 ||
  fail 'matching resumed adoption identity was rejected'
env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
  --vault-file "$vault_file" --vault-password-file "$password_file" \
  --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
  --phase report --sandbox "$matching_sandbox" >/dev/null 2>&1 ||
  fail 'repeated resumed adoption could not safely replace its pinned copies'

report_input=$temporary_parent/report-input.json
report_json=$temporary_parent/report.json
report_markdown=$temporary_parent/report.md
"$reporter" --init "$report_input" --lane adoption \
  --sandbox-id nas-platform-mac.Report1 --git-revision "$git_revision" \
  --vault-checksum "$vault_checksum" --parity-vault-checksum "$parity_checksum" \
  --legacy-commit "$legacy_commit" --project-name nas-platform-mac-report1 \
  --beszel-port 38090 --ntfy-port 32586 --dozzle-port 38080 \
  --audiobookshelf-port 33378 --komga-port 35600 \
  --tinymediamanager-web-port 34000 --tinymediamanager-api-port 37878 \
  --jellyfin-port 38096 --immich-port 32283 --paperless-port 38000
"$reporter" --input "$report_input" --json "$report_json" --markdown "$report_markdown"
ruby -rjson - "$report_json" "$parity_checksum" "$legacy_commit" <<'RUBY'
report, parity_checksum, legacy_commit = JSON.parse(File.read(ARGV.fetch(0))), ARGV.fetch(1), ARGV.fetch(2)
raise "JSON parity checksum differs" unless report["parity_vault_checksum"] == parity_checksum
raise "JSON legacy commit differs" unless report["legacy_commit"] == legacy_commit
RUBY
grep -F -- "- Parity vault checksum: $parity_checksum" "$report_markdown" >/dev/null ||
  fail 'Markdown omits parity vault checksum'
grep -F -- "- Legacy commit: $legacy_commit" "$report_markdown" >/dev/null ||
  fail 'Markdown omits legacy commit'
if find "$temporary_parent" -name '*.tmp.*' -print -quit | grep . >/dev/null; then
  fail 'protected input pinning left an unsafe temporary copy'
fi

printf '%s\n' 'Mac adoption runner: lane phases and protected resume identity hold'
