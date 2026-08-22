#!/bin/sh
set -eu
mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

mac_ansible_playbook -i localhost, \
  "$mac_repo_dir/tests/tinymediamanager_retirement_fixture.yml"
case ${PLATFORM_PROOF_PLATFORM:-mac} in
  integration) tinymediamanager_container=tinymediamanager ;;
  mac) tinymediamanager_container=$PLATFORM_PROJECT_NAME-tinymediamanager ;;
  *) mac_die 'proof platform is invalid' ;;
esac
docker container inspect "$tinymediamanager_container" >/dev/null
printf '%s\n' 'TINYMEDIAMANAGER_RETIREMENT_DRIFT_INSTALLED'
