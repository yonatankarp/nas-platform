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
grep -F -- 'exact #!/bin/sh shebang without options or NUL bytes' "$help_output" >/dev/null ||
  fail 'usage omits the executable password provider format'

expect_failure 'adoption without parity vault' 'adoption requires --parity-vault-file' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file"
expect_failure 'adoption without parity password' 'adoption requires --parity-vault-password-file' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file"
expect_failure 'fresh parity options' 'fresh lane rejects parity vault options' \
  "$runner" --lane fresh --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file"
expect_failure 'fresh ambient adoption mapping' 'reserved adoption mapping environment must be unset' \
  env PLATFORM_ADOPTION_ROOT="$temporary_parent/hostile" "$runner" --lane fresh \
    --vault-file "$vault_file" --vault-password-file "$password_file"
expect_failure 'ambient comparison self-test' 'reserved adoption mapping environment must be unset' \
  env PLATFORM_ADOPTION_COMPARE_SELF_TEST=1 "$runner" --lane fresh \
    --vault-file "$vault_file" --vault-password-file "$password_file"
expect_failure 'ambient probe script root' 'reserved adoption mapping environment must be unset' \
  env PLATFORM_ADOPTION_SCRIPT_DIR="$temporary_parent" "$runner" --lane fresh \
    --vault-file "$vault_file" --vault-password-file "$password_file"
expect_failure 'ambient target probe mode' 'reserved adoption mapping environment must be unset' \
  env PLATFORM_ADOPTION_PROBE_TARGET=true "$runner" --lane fresh \
    --vault-file "$vault_file" --vault-password-file "$password_file"
expect_failure 'ambient ntfy probe container' 'reserved adoption mapping environment must be unset' \
  env PLATFORM_ADOPTION_NTFY_CONTAINER=hostile "$runner" --lane fresh \
    --vault-file "$vault_file" --vault-password-file "$password_file"
expect_failure 'ambient ntfy probe environment' 'reserved adoption mapping environment must be unset' \
  env PLATFORM_ADOPTION_NTFY_ENV_FILE="$temporary_parent/hostile.env" "$runner" --lane fresh \
    --vault-file "$vault_file" --vault-password-file "$password_file"
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
    if ENV["PLATFORM_SWAP_STAGE"] == "child_spawn"
      target = ENV.fetch("PLATFORM_SWAP_CHILD_TARGET")
      holding = ENV.fetch("PLATFORM_SWAP_CHILD_HOLDING")
      replacement = ENV.fetch("PLATFORM_SWAP_CHILD_REPLACEMENT")
      File.rename(target, holding)
      File.rename(replacement, target)
      begin
        return adoption_input_original_popen3(*arguments, **keywords, &block)
      ensure
        File.rename(target, replacement)
        File.rename(holding, target)
      end
    end
    if ENV["PLATFORM_SWAP_STAGE"] == "logical_parent_spawn"
      target = ENV.fetch("PLATFORM_SWAP_LOGICAL_PARENT_TARGET")
      holding = ENV.fetch("PLATFORM_SWAP_LOGICAL_PARENT_HOLDING")
      replacement = ENV.fetch("PLATFORM_SWAP_LOGICAL_PARENT_REPLACEMENT")
      File.rename(target, holding)
      File.rename(replacement, target)
      begin
        return adoption_input_original_popen3(*arguments, **keywords, &block)
      ensure
        File.rename(target, replacement)
        File.rename(holding, target)
      end
    end
    if ENV["PLATFORM_SWAP_STAGE"] == "child_in_place_spawn"
      target = ENV.fetch("PLATFORM_SWAP_CHILD_TARGET")
      replacement = ENV.fetch("PLATFORM_SWAP_CHILD_REPLACEMENT")
      original = File.binread(target)
      File.binwrite(target, File.binread(replacement))
      begin
        return adoption_input_original_popen3(*arguments, **keywords, &block)
      ensure
        File.binwrite(target, original)
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

child_swap_root=$temporary_parent/transient-child-provider
mkdir "$child_swap_root"
child_swap_provider=$child_swap_root/provider
child_swap_holding=$child_swap_root/provider-held
child_swap_replacement=$child_swap_root/provider-replacement
child_swap_marker=$temporary_parent/child-swap-marker
printf '%s\n' '#!/bin/sh' \
  'printf "%s\\n" original >> "${PLATFORM_CHILD_SWAP_MARKER:?}"' \
  'printf "%s\\n" held-provider-inode-output' > "$child_swap_provider"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\\n" replacement >> "${PLATFORM_CHILD_SWAP_MARKER:?}"' \
  'printf "%s\\n" transient-child-replacement-secret' \
  > "$child_swap_replacement"
chmod 0700 "$child_swap_provider" "$child_swap_replacement"
child_swap_sandbox=$temporary_parent/nas-platform-mac.FdC123
mkdir -m 0700 "$child_swap_sandbox"
printf 'schema=1\nproject=%s\n' nas-platform-mac-fdc123 > "$child_swap_sandbox/.nas-platform-mac-owned"
chmod 0600 "$child_swap_sandbox/.nas-platform-mac-owned"
child_swap_output=$temporary_parent/child-swap-output
if RUBYOPT="-r$swap_fixture" PLATFORM_SWAP_STAGE=child_spawn \
  PLATFORM_SWAP_CHILD_TARGET="$child_swap_provider" \
  PLATFORM_SWAP_CHILD_HOLDING="$child_swap_holding" \
  PLATFORM_SWAP_CHILD_REPLACEMENT="$child_swap_replacement" \
  PLATFORM_CHILD_SWAP_MARKER="$child_swap_marker" \
  PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" \
    --parity-vault-password-file "$child_swap_provider" \
    --phase report --sandbox "$child_swap_sandbox" > "$child_swap_output" 2>&1; then
  fail 'transient provider entry swap was not rejected'
fi
grep -Fx original "$child_swap_marker" >/dev/null ||
  fail 'transient child-entry swap did not execute the inspected provider bytes'
if grep -Fx replacement "$child_swap_marker" >/dev/null; then
  fail 'transient child-entry swap executed the replacement provider'
fi
if grep -F transient-child-replacement-secret "$child_swap_output" >/dev/null; then
  fail 'transient child-entry replacement leaked output'
fi
[ -f "$child_swap_provider" ] && [ -f "$child_swap_replacement" ] && [ ! -e "$child_swap_holding" ] ||
  fail 'transient child-entry swap fixture did not restore the original pathname'

logical_parent_root=$temporary_parent/logical-provider-parent
logical_parent_real=$logical_parent_root/real
logical_parent_other=$logical_parent_root/other
logical_parent_link=$logical_parent_root/current
logical_parent_holding=$logical_parent_root/current-held
logical_parent_replacement=$logical_parent_root/current-replacement
mkdir -p "$logical_parent_real" "$logical_parent_other"
printf '%s\n' '#!/bin/sh' '"$(dirname -- "$0")/helper"' > "$logical_parent_real/provider"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" logical-parent-output' > "$logical_parent_real/helper"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" logical-parent-replacement-secret' \
  > "$logical_parent_other/provider"
chmod 0700 "$logical_parent_real/provider" "$logical_parent_real/helper" \
  "$logical_parent_other/provider"
ln -s "$logical_parent_real" "$logical_parent_link"
ln -s "$logical_parent_other" "$logical_parent_replacement"
logical_parent_sandbox=$temporary_parent/nas-platform-mac.FdL123
mkdir -m 0700 "$logical_parent_sandbox"
printf 'schema=1\nproject=%s\n' nas-platform-mac-fdl123 > "$logical_parent_sandbox/.nas-platform-mac-owned"
chmod 0600 "$logical_parent_sandbox/.nas-platform-mac-owned"
logical_parent_output=$temporary_parent/logical-parent-output
RUBYOPT="-r$swap_fixture" PLATFORM_SWAP_STAGE=logical_parent_spawn \
  PLATFORM_SWAP_LOGICAL_PARENT_TARGET="$logical_parent_link" \
  PLATFORM_SWAP_LOGICAL_PARENT_HOLDING="$logical_parent_holding" \
  PLATFORM_SWAP_LOGICAL_PARENT_REPLACEMENT="$logical_parent_replacement" \
  PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" \
    --parity-vault-password-file "$logical_parent_link/provider" \
    --phase report --sandbox "$logical_parent_sandbox" > "$logical_parent_output" 2>&1 ||
  fail 'logical symlink parent was not safely bound through its canonical directory'
printf '%s\n' logical-parent-output > "$temporary_parent/logical-parent-expected"
cmp -s "$temporary_parent/logical-parent-expected" \
  "$logical_parent_sandbox/protected-inputs/parity-password" ||
  fail 'logical parent swap changed provider execution'
if grep -F logical-parent-replacement-secret "$logical_parent_output" >/dev/null; then
  fail 'logical parent replacement leaked output'
fi
[ -L "$logical_parent_link" ] && [ -L "$logical_parent_replacement" ] && \
  [ ! -e "$logical_parent_holding" ] || fail 'logical parent fixture was not restored'

descriptor_provider=$temporary_parent/provider-descriptor-check
descriptor_helper=$temporary_parent/provider-descriptor-helper
cat > "$descriptor_helper" <<'SH'
#!/bin/sh
# provider-source-argv-env-probe-9f4a21
case $(ps -o command= -p "$PPID") in
  *provider-source-argv-env-probe-9f4a21*) exit 11 ;;
esac
if IFS= read -r unexpected_input; then
  exit 12
fi
ruby -e '
  cwd = File.stat(".")
  provider = File.stat(ENV.fetch("PLATFORM_DESCRIPTOR_PROVIDER"))
  (3..255).each do |descriptor|
    begin
      opened = IO.for_fd(descriptor, autoclose: false).stat
      exit 9 if [opened.dev, opened.ino] == [cwd.dev, cwd.ino]
      exit 10 if [opened.dev, opened.ino] == [provider.dev, provider.ino]
    rescue SystemCallError, IOError, ArgumentError
      next
    end
  end
'
SH
cat > "$descriptor_provider" <<'SH'
#!/bin/sh
# provider-source-argv-env-probe-9f4a21
printf 'argc=%s first=%s\n' "$#" "${1+x}" > "${PLATFORM_DESCRIPTOR_MARKER:?}"
[ "$#" -eq 0 ] && [ "${1+x}" != x ] || exit 8
if /usr/bin/find "${PLATFORM_DESCRIPTOR_PROTECTED_ROOT:?}" -name '.provider-*' -print | grep . >/dev/null; then
  printf '%s\n' named-snapshot >> "${PLATFORM_DESCRIPTOR_MARKER:?}"
  exit 11
fi
case $(ps -o command= -p $$)$(env) in
  *provider-source-argv-env-probe-9f4a21*)
    printf '%s\n' process-bytes >> "${PLATFORM_DESCRIPTOR_MARKER:?}"
    exit 12
    ;;
esac
if IFS= read -r unexpected_input; then
  printf '%s\n' stdin-open >> "${PLATFORM_DESCRIPTOR_MARKER:?}"
  exit 13
fi
"$(dirname -- "$0")/provider-descriptor-helper" || exit 9
printf '%s\n' descriptor-safe-output
SH
chmod 0700 "$descriptor_provider" "$descriptor_helper"
descriptor_sandbox=$temporary_parent/nas-platform-mac.FdD123
mkdir -m 0700 "$descriptor_sandbox"
printf 'schema=1\nproject=%s\n' nas-platform-mac-fdd123 > "$descriptor_sandbox/.nas-platform-mac-owned"
chmod 0600 "$descriptor_sandbox/.nas-platform-mac-owned"
descriptor_marker=$temporary_parent/provider-descriptor-marker
PLATFORM_DESCRIPTOR_PROVIDER="$descriptor_provider" PLATFORM_DESCRIPTOR_MARKER="$descriptor_marker" \
  PLATFORM_DESCRIPTOR_PROTECTED_ROOT="$descriptor_sandbox/protected-inputs" \
  PLATFORM_MAC_TMPDIR="$temporary_parent" \
  "$runner" --lane adoption \
  --vault-file "$vault_file" --vault-password-file "$password_file" \
  --parity-vault-file "$parity_vault_file" \
  --parity-vault-password-file "$descriptor_provider" \
  --phase report --sandbox "$descriptor_sandbox" >/dev/null 2>&1 || {
  grep -Fx 'argc=0 first=' "$descriptor_marker" >/dev/null ||
    fail 'provider received positional arguments from the launcher'
  if grep -Fx named-snapshot "$descriptor_marker" >/dev/null; then
    fail 'provider observed a named private snapshot'
  fi
  fail 'provider or helper inherited an inspected descriptor'
}
printf '%s\n' descriptor-safe-output > "$temporary_parent/descriptor-expected"
cmp -s "$temporary_parent/descriptor-expected" \
  "$descriptor_sandbox/protected-inputs/parity-password" ||
  fail 'provider descriptor check produced unexpected output'

in_place_provider=$temporary_parent/provider-in-place
in_place_replacement=$temporary_parent/provider-in-place-replacement
in_place_marker=$temporary_parent/provider-in-place-marker
printf '%s\n' '#!/bin/sh' \
  'printf "%s\\n" original >> "${PLATFORM_IN_PLACE_MARKER:?}"' \
  'printf "%s\\n" original-in-place-output' > "$in_place_provider"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\\n" replacement >> "${PLATFORM_IN_PLACE_MARKER:?}"' \
  'printf "%s\\n" replacement-in-place-secret' > "$in_place_replacement"
chmod 0700 "$in_place_provider" "$in_place_replacement"
in_place_sandbox=$temporary_parent/nas-platform-mac.FdI123
mkdir -m 0700 "$in_place_sandbox"
printf 'schema=1\nproject=%s\n' nas-platform-mac-fdi123 > "$in_place_sandbox/.nas-platform-mac-owned"
chmod 0600 "$in_place_sandbox/.nas-platform-mac-owned"
in_place_output=$temporary_parent/in-place-output
if RUBYOPT="-r$swap_fixture" PLATFORM_SWAP_STAGE=child_in_place_spawn \
  PLATFORM_SWAP_CHILD_TARGET="$in_place_provider" \
  PLATFORM_SWAP_CHILD_REPLACEMENT="$in_place_replacement" \
  PLATFORM_IN_PLACE_MARKER="$in_place_marker" PLATFORM_MAC_TMPDIR="$temporary_parent" \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" \
    --parity-vault-password-file "$in_place_provider" \
    --phase report --sandbox "$in_place_sandbox" > "$in_place_output" 2>&1; then
  fail 'in-place provider mutation was not rejected'
fi
grep -Fx original "$in_place_marker" >/dev/null ||
  fail 'in-place mutation did not execute the inspected provider snapshot'
if grep -Fx replacement "$in_place_marker" >/dev/null; then
  fail 'in-place mutation executed changed provider bytes'
fi
if grep -F replacement-in-place-secret "$in_place_output" >/dev/null; then
  fail 'in-place provider replacement leaked output'
fi
if /usr/bin/find "$temporary_parent" -name '.provider-*' -print | grep . >/dev/null; then
  fail 'private provider snapshot remained after provider execution'
fi

reader_failure_provider=$temporary_parent/provider-reader-failure
reader_failure_marker=$temporary_parent/provider-reader-failure-marker
reader_failure_sandbox=$temporary_parent/nas-platform-mac.RdF123
mkdir -m 0700 "$reader_failure_sandbox"
printf 'schema=1\nproject=%s\n' nas-platform-mac-rdf123 \
  > "$reader_failure_sandbox/.nas-platform-mac-owned"
chmod 0600 "$reader_failure_sandbox/.nas-platform-mac-owned"
cat > "$reader_failure_provider" <<'SH'
#!/bin/sh
printf '%s\n' partial-reader-executed > "${PLATFORM_READER_FAILURE_MARKER:?}"
exit 0
# provider-reader-failure-secret-tail
SH
chmod 0700 "$reader_failure_provider"
reader_failure_tools=$temporary_parent/provider-reader-failure-tools
mkdir -m 0700 "$reader_failure_tools"
cat > "$reader_failure_tools/cat" <<'SH'
#!/bin/sh
/usr/bin/dd bs=1 count=100 2>/dev/null
exit 7
SH
chmod 0700 "$reader_failure_tools/cat"
expect_failure 'partial nonzero provider reader' 'protected parity password input provider failed' \
  env PLATFORM_READER_FAILURE_MARKER="$reader_failure_marker" \
    PLATFORM_MAC_TMPDIR="$temporary_parent" PATH="$reader_failure_tools:$PATH" \
    "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" \
    --parity-vault-password-file "$reader_failure_provider" --phase report \
    --sandbox "$reader_failure_sandbox"
[ ! -e "$reader_failure_marker" ] || fail 'partial nonzero provider reader executed its prefix'
[ ! -e "$reader_failure_sandbox/protected-inputs/parity-password" ] ||
  fail 'partial nonzero provider reader pinned output'
if grep -F provider-reader-failure-secret-tail "$temporary_parent/output" >/dev/null; then
  fail 'partial nonzero provider reader leaked protected bytes'
fi

nul_provider=$temporary_parent/provider-nul
printf '#!/bin/sh\nprintf before\000after\n' > "$nul_provider"
chmod 0700 "$nul_provider"
expect_failure 'NUL-bearing executable parity provider' \
  'protected parity password input provider contains unsupported NUL bytes' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" \
    --parity-vault-password-file "$nul_provider" --phase report

no_newline_provider=$temporary_parent/provider-no-final-newline
printf '#!/bin/sh\nprintf "%%s\\n" no-final-newline-output' > "$no_newline_provider"
chmod 0700 "$no_newline_provider"
no_newline_sandbox=$temporary_parent/nas-platform-mac.NoN123
mkdir -m 0700 "$no_newline_sandbox"
printf 'schema=1\nproject=%s\n' nas-platform-mac-non123 > "$no_newline_sandbox/.nas-platform-mac-owned"
chmod 0600 "$no_newline_sandbox/.nas-platform-mac-owned"
PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
  --vault-file "$vault_file" --vault-password-file "$password_file" \
  --parity-vault-file "$parity_vault_file" \
  --parity-vault-password-file "$no_newline_provider" \
  --phase report --sandbox "$no_newline_sandbox" >/dev/null 2>&1 ||
  fail 'provider without a final source newline was not preserved'
printf '%s\n' no-final-newline-output > "$temporary_parent/no-newline-expected"
cmp -s "$temporary_parent/no-newline-expected" \
  "$no_newline_sandbox/protected-inputs/parity-password" ||
  fail 'provider without a final source newline produced unexpected output'

trailing_newline_provider=$temporary_parent/provider-trailing-newlines
printf '#!/bin/sh\nprintf "%%s\\n" trailing-newline-output\n\n\n' > "$trailing_newline_provider"
chmod 0700 "$trailing_newline_provider"
trailing_newline_sandbox=$temporary_parent/nas-platform-mac.TrN123
mkdir -m 0700 "$trailing_newline_sandbox"
printf 'schema=1\nproject=%s\n' nas-platform-mac-trn123 \
  > "$trailing_newline_sandbox/.nas-platform-mac-owned"
chmod 0600 "$trailing_newline_sandbox/.nas-platform-mac-owned"
PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
  --vault-file "$vault_file" --vault-password-file "$password_file" \
  --parity-vault-file "$parity_vault_file" \
  --parity-vault-password-file "$trailing_newline_provider" \
  --phase report --sandbox "$trailing_newline_sandbox" >/dev/null 2>&1 ||
  fail 'provider trailing source newlines were not preserved'
printf '%s\n' trailing-newline-output > "$temporary_parent/trailing-newline-expected"
cmp -s "$temporary_parent/trailing-newline-expected" \
  "$trailing_newline_sandbox/protected-inputs/parity-password" ||
  fail 'provider trailing source newlines produced unexpected output'

unsupported_provider=$temporary_parent/provider-unsupported
printf '%s\n' '#!/bin/bash' 'printf "%s\\n" unsupported-provider-secret' > "$unsupported_provider"
chmod 0700 "$unsupported_provider"
expect_failure 'unsupported executable parity provider' \
  'protected parity password input provider must use the exact #!/bin/sh executable format' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" \
    --parity-vault-password-file "$unsupported_provider" --phase report
if grep -F unsupported-provider-secret "$temporary_parent/output" >/dev/null; then
  fail 'unsupported executable parity provider leaked output'
fi

option_provider=$temporary_parent/provider-option
printf '%s\n' '#!/bin/sh -e' 'printf "%s\\n" option-provider-secret' > "$option_provider"
chmod 0700 "$option_provider"
expect_failure 'option-bearing executable parity provider' \
  'protected parity password input provider must use the exact #!/bin/sh executable format' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" \
    --parity-vault-password-file "$option_provider" --phase report
if grep -F option-provider-secret "$temporary_parent/output" >/dev/null; then
  fail 'option-bearing executable parity provider leaked output'
fi

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
timeout_child_marker=$temporary_parent/provider-timeout-child
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" provider-timeout-secret' \
  'printf "%s\\n" provider-timeout-secret >&2' \
  'sleep 10 & child=$!; printf "%s\\n" "$child" > "${PLATFORM_TIMEOUT_CHILD_MARKER:?}"; wait "$child"' \
  > "$timeout_provider"
chmod 0700 "$timeout_provider"
expect_failure 'timed out parity provider' 'protected parity password input provider timed out' \
  env PLATFORM_TIMEOUT_CHILD_MARKER="$timeout_child_marker" PLATFORM_MAC_TMPDIR="$temporary_parent" \
    "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$timeout_provider" \
    --phase report
if grep -F provider-timeout-secret "$temporary_parent/output" >/dev/null; then
  fail 'timed out parity provider leaked stderr'
fi
timeout_child=$(sed -n '1p' "$timeout_child_marker")
case $timeout_child in *[!0-9]*|'') fail 'timed out provider did not record its child' ;; esac
if kill -0 "$timeout_child" 2>/dev/null; then
  fail 'timed out provider left a child process running'
fi
if /usr/bin/find "$temporary_parent" -name '.provider-*' -print | grep . >/dev/null; then
  fail 'private provider snapshot remained after timeout cleanup'
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

preflight_fake_bin=$temporary_parent/preflight-tools
mkdir -m 0700 "$preflight_fake_bin"
cat > "$preflight_fake_bin/docker" <<'STUB'
#!/bin/sh
case ${1-} in
  info|version) exit 0 ;;
  ps) exit 0 ;;
  *) exit 2 ;;
esac
STUB
cat > "$preflight_fake_bin/ansible-playbook" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod 0700 "$preflight_fake_bin/docker" "$preflight_fake_bin/ansible-playbook"
expect_failure 'adoption preflight without legacy checkout' 'NAS_INFRASTRUCTURE_DIR is required' \
  env -u NAS_INFRASTRUCTURE_DIR PLATFORM_MAC_TMPDIR="$temporary_parent" \
    PATH="$preflight_fake_bin:$PATH" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
    --phase preflight

preflight_legacy_root=$temporary_parent/nas-infrastructure
mkdir -p "$preflight_legacy_root/.git"
ruby -ryaml -rfileutils - "$repo_dir/services/manifest.yml" "$preflight_legacy_root" <<'RUBY'
manifest = YAML.safe_load_file(ARGV.fetch(0))
manifest.fetch("services").each do |service|
  path = File.join(ARGV.fetch(1), service.fetch("legacy_path"))
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "services: {}\n")
end
RUBY
cat > "$preflight_fake_bin/git" <<'STUB'
#!/bin/sh
case " $* " in
  *' remote get-url origin ')
    printf '%s\n' 'https://github.com/yonatankarp/nas-infrastructure.git'
    ;;
  *' rev-parse --show-toplevel ')
    printf '%s\n' "${FAKE_LEGACY_ROOT:?}"
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
    cat "${FAKE_LEGACY_ROOT:?}/${object#HEAD:}"
    ;;
  *' ls-tree HEAD -- '*)
    for argument in "$@"; do path=$argument; done
    printf '100644 blob %040d\t%s\n' 0 "$path"
    ;;
  *) exit 2 ;;
esac
STUB
cat > "$preflight_fake_bin/ansible-vault" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod 0700 "$preflight_fake_bin/git" "$preflight_fake_bin/ansible-vault"
expect_failure 'adoption preflight with invalid parity' 'legacy parity rendering failed' \
  env NAS_INFRASTRUCTURE_DIR="$preflight_legacy_root" FAKE_LEGACY_ROOT="$preflight_legacy_root" \
    PLATFORM_MAC_TMPDIR="$temporary_parent" PATH="$preflight_fake_bin:$PATH" \
    "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
    --phase preflight

printf '%s\n' 'Mac adoption runner: lane phases and protected resume identity hold'
