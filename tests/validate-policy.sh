#!/bin/sh
set -eu

ruby tests/policy_test.rb
ruby tests/ci/classify_changes_test.rb
ruby tests/secrets_docs_test.rb
ruby tests/policy_manifest_test.rb
ansible-playbook -i localhost, -c local tests/compose_metadata_filter_test.yml
ruby tests/run_contracts_test.rb
ruby tests/run_contracts.rb --validate-only
ruby tests/dozzle_quality_test.rb
tests/integration_lock_test.sh
tests/mac/config-isolation.sh
tests/mac/run-phase-status-test.sh
tests/mac/dozzle-drift-hook-test.sh
tests/mac/audiobookshelf-drift-hook-test.sh
tests/contracts/audiobookshelf-audio-test.sh
ruby tests/mac/report.rb --self-test
tests/mac/cleanup.sh --self-test
tests/mac/snapshot-immich.sh --self-test
ruby tests/mac/sanitize-logs.rb --self-test
