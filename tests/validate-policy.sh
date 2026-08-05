#!/bin/sh
set -eu

ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
ruby tests/run_contracts_test.rb
ruby tests/run_contracts.rb --validate-only
tests/integration_lock_test.sh
