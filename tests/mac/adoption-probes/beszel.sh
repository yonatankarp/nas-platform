#!/bin/sh
set -eu
set +x
umask 077
dir=${PLATFORM_ADOPTION_SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)}
if [ -n "${PLATFORM_ADOPTION_CONTRACT_FILE:-}" ]; then
  export PLATFORM_KIND=mac
  export PLATFORM_CONTRACT_VAULT_FILE=${PLATFORM_MAC_VAULT_FILE:?}
  export PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=${PLATFORM_MAC_VAULT_PASSWORD_FILE:?}
  run_contract() { /bin/sh "$PLATFORM_ADOPTION_CONTRACT_FILE" "$@"; }
else
  run_contract() { "$dir/run-beszel-contract.sh" "$@"; }
fi
if ! run_contract verify >/dev/null 2>&1; then
  printf '%s\n' 'adoption-probe-error: beszel evidence unavailable' >&2
  exit 1
fi
exec ruby "${PLATFORM_ADOPTION_BASELINE_FILE:-$dir/adoption-baseline.rb}" --emit-probe beszel
