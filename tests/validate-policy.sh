#!/bin/sh
set -eu

ruby tests/policy_test.rb
ruby tests/ci/classify_changes_test.rb
ruby tests/ci/validate_results_test.rb
ruby tests/ci/workflow_test.rb
ruby tests/secrets_docs_test.rb
ruby tests/ci_workflow_test.rb
tests/adoption-integration-test.sh
tests/mac/integration-context-test.sh
tests/mac/adoption-bind-prep-test.rb
tests/mac/snapshot-paperless-context-test.sh
ruby tests/policy_manifest_test.rb
python3 tests/deployment_target_validator_test.py
ruby tests/portainer_parity_mapping_test.rb
ruby tests/managed_user_capabilities_test.rb --self-test
ruby tests/managed_users_vault_test.rb
ruby tests/beszel_password_preservation_test.rb --self-test
ruby tests/config_managed_users_test.rb --self-test
ruby tests/media_managed_users_test.rb
ruby tests/media_managed_users_test.rb --self-test
ruby tests/database_managed_users_test.rb
ruby tests/database_managed_users_test.rb --self-test
ruby tests/ntfy_verify_execution_test.rb
ansible_playbook=$(command -v ansible-playbook) || {
  printf '%s\n' 'ansible-playbook is required for managed-user behavior tests' >&2
  exit 1
}
ansible_python=$(
  "$ansible_playbook" --version |
    sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p'
)
[ -x "$ansible_python" ] || {
  printf '%s\n' 'the ansible-playbook Python interpreter is unavailable' >&2
  exit 1
}
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/managed_user_state_filter_test.py
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/safe_slurp_test.py
tests/portainer_parity_import_test.sh
ansible-playbook -i localhost, -c local tests/compose_metadata_filter_test.yml
ruby tests/run_contracts_test.rb
ruby tests/run_contracts.rb --validate-only
ruby tests/dozzle_quality_test.rb
tests/integration_lock_test.sh
tests/integration_suite_test.sh
tests/mac/config-isolation.sh
tests/mac/run-phase-status-test.sh
tests/mac/adoption-self-test.sh
tests/mac/adoption.sh --self-test
tests/mac/legacy-seed-test.sh
tests/mac/legacy-fixture-path-test.sh
ruby tests/mac/legacy-secure-copy-test.rb
tests/mac/dozzle-drift-hook-test.sh
tests/mac/audiobookshelf-drift-hook-test.sh
tests/contracts/audiobookshelf-audio-test.sh
ruby tests/mac/report.rb --self-test
tests/mac/cleanup.sh --self-test
tests/mac/snapshot-immich.sh --self-test
ruby tests/mac/sanitize-logs.rb --self-test
