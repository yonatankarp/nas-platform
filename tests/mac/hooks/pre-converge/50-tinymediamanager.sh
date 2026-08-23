#!/bin/sh
set -eu

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

"$mac_script_dir/run-tinymediamanager-contract.sh" seed-retirement-fixture
PLATFORM_CONTRACT_REPO_DIR=$mac_repo_dir \
  PLATFORM_REPORT_ROOT=$PLATFORM_TINYMEDIAMANAGER_REPORT_ROOT \
  mac_ansible_playbook -i localhost, \
  "$mac_repo_dir/tests/tinymediamanager_retirement_fixture.yml"
