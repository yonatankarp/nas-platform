#!/bin/sh

mac_die() {
  printf '%s\n' "$1" >&2
  return 1
}

mac_validate_lexical_path() {
  mac_path=$1
  mac_label=$2
  case $mac_path in
    /*) ;;
    *) mac_die "$mac_label must be absolute" ;;
  esac
  case $mac_path in
    /) ;;
    */|*//*|*/./*|*/../*|*/.|*/..) mac_die "$mac_label must be lexically normalized" ;;
  esac
}

mac_owner_id() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

mac_file_mode() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

mac_canonical_directory() {
  mac_validate_lexical_path "$1" "$2" || return 1
  [ -d "$1" ] && [ ! -L "$1" ] || mac_die "$2 is unavailable or unsafe"
  CDPATH= cd -- "$1" 2>/dev/null && pwd -P
}

mac_temporary_parent() {
  mac_parent_input=${PLATFORM_MAC_TMPDIR:-${TMPDIR:-/tmp}}
  mac_parent_input=${mac_parent_input%/}
  [ -n "$mac_parent_input" ] || mac_parent_input=/
  mac_canonical_directory "$mac_parent_input" 'Mac temporary parent'
}

mac_validate_sandbox() {
  mac_requested=${1-}
  [ -n "$mac_requested" ] || mac_die 'refusing to remove unowned Mac sandbox: empty path'
  mac_validate_lexical_path "$mac_requested" 'Mac sandbox' || return 1
  [ "$mac_requested" != / ] || mac_die 'refusing to remove unowned Mac sandbox: /'
  [ -d "$mac_requested" ] && [ ! -L "$mac_requested" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"

  mac_parent=$(mac_temporary_parent) || return 1
  mac_physical=$(CDPATH= cd -- "$mac_requested" 2>/dev/null && pwd -P) ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  [ "$mac_physical" = "$mac_requested" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  [ "$(dirname -- "$mac_physical")" = "$mac_parent" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  case $(basename -- "$mac_physical") in
    nas-platform-mac.??????) ;;
    *) mac_die "refusing to remove unowned Mac sandbox: $mac_requested" ;;
  esac
  mac_suffix=${mac_physical##*.}
  case $mac_suffix in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*)
      mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
      ;;
  esac
  [ "$(mac_owner_id "$mac_physical")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$mac_physical")" = 700 ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"

  mac_marker=$mac_physical/.nas-platform-mac-owned
  [ -f "$mac_marker" ] && [ ! -L "$mac_marker" ] &&
    [ "$(mac_owner_id "$mac_marker")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$mac_marker")" = 600 ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  grep -qx 'schema=1' "$mac_marker" ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  mac_project=$(sed -n 's/^project=//p' "$mac_marker")
  case $mac_project in
    nas-platform-mac-[abcdefghijklmnopqrstuvwxyz0123456789]*) ;;
    *) mac_die "refusing to remove unowned Mac sandbox: $mac_requested" ;;
  esac
  mac_project_suffix=$(printf '%s' "$mac_suffix" | tr '[:upper:]' '[:lower:]')
  [ "$mac_project" = "nas-platform-mac-$mac_project_suffix" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  printf '%s\n' "$mac_physical"
}

mac_shell_quote() {
  case $1 in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./-]*)
      printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

mac_integration_gateway() {
  mac_gateway=$(docker network inspect bridge \
    --format '{{ (index .IPAM.Config 0).Gateway }}') ||
    mac_die 'integration Docker host address is unavailable'
  mac_validate_integration_callback "$mac_gateway"
}

mac_validate_integration_callback() {
  mac_gateway=$1
  ruby -ripaddr -e '
    value = ARGV.fetch(0)
    address = IPAddr.new(value)
    abort unless address.ipv4? && value == address.to_s &&
      value != "0.0.0.0" && !address.loopback? &&
      !IPAddr.new("224.0.0.0/4").include?(address)
    puts value
  ' "$mac_gateway" 2>/dev/null || mac_die 'integration Docker host address is invalid'
}

# Lane-requested state, not inventory (tests/policy_platform_test.rb refuses it there):
# - nas_compose_minimum: the mac/integration overrides use `!override` (Compose 2.24.4).
# - *_deployment_enabled: the lane requests the stacks its hooks account for.
# - vaultwarden_domain: the role refuses an IPv4 literal (WebAuthn needs a domain).
# - empty Tailscale candidates: otherwise a Mac with /usr/local/bin/tailscale would
#   run `tailscale serve` against the operator's REAL tailnet.
# - *_pushover_*: this lane uses the REAL vault; never page the household's devices.
#   Dozzle's port is tests/contracts/dozzle.sh's recorder; the dozzle_contract,
#   deployment_summary and seerr_contract tests refuse losing these lines.
mac_ansible_playbook() {
  set -- "$@" -e nas_compose_minimum=2.24.4 -e nextcloud_deployment_enabled=true \
    -e vaultwarden_deployment_enabled=true \
    -e karakeep_deployment_enabled=true \
    -e vaultwarden_domain=https://vaultwarden.mac.invalid \
    -e 'dozzle_pushover_api_url=http://{{ platform_callback_host }}:32587/1/messages.json' \
    -e 'deployment_pushover_api_url=http://127.0.0.1:1/1/messages.json' \
    -e '{"seerr_pushover_access_token": "", "seerr_pushover_user_key": ""}' \
    -e '{"vaultwarden_tailscale_binary_candidates": []}'
  case ${PLATFORM_PROOF_PLATFORM:-mac} in
    mac)
      case ${PLATFORM_CALLBACK_HOST:-host.docker.internal} in
        host.docker.internal) ;;
        *) mac_die 'Mac callback host is invalid'; return 1 ;;
      esac
      command ansible-playbook "$@"
      ;;
    integration)
      mac_callback_host=${PLATFORM_CALLBACK_HOST:-}
      [ -n "$mac_callback_host" ] || {
        mac_die 'integration callback host is unavailable'
        return 1
      }
      mac_callback_host=$(mac_validate_integration_callback "$mac_callback_host") || return 1
      command ansible-playbook "$@" \
        -e platform_kind=mac -e platform_compose_kind=integration \
        -e deployment_bundle_test_mode=true \
        -e platform_manage_linux_ownership=true \
        -e "platform_callback_host=$mac_callback_host"
      ;;
    *) mac_die 'proof platform is invalid' ;;
  esac
}

mac_compose_files() {
  mac_current=$1
  set -- -f "$mac_current/compose.yml"
  mac_compose_kind=${PLATFORM_COMPOSE_KIND:-mac}
  case $mac_compose_kind in mac|integration) ;; *) mac_die 'compose kind is invalid' ;; esac
  if [ -f "$mac_current/compose.$mac_compose_kind.yml" ] &&
     [ ! -L "$mac_current/compose.$mac_compose_kind.yml" ]; then
    set -- "$@" -f "$mac_current/compose.$mac_compose_kind.yml"
  fi
  printf '%s\n' "$@"
}

# Both disposable lanes name every container after the Compose project.
mac_target_container_names() {
  mac_project=$1
  case ${PLATFORM_PROOF_PLATFORM:-mac} in
    integration | mac)
      printf '%s\n' "$mac_project-beszel" "$mac_project-beszel-agent-intel" \
        "$mac_project-beszel-agent-portable" "$mac_project-beszel-socket-proxy" \
        "$mac_project-dozzle-alert-relay" \
        "$mac_project-dozzle" "$mac_project-dozzle-socket-proxy" \
        "$mac_project-audiobookshelf" "$mac_project-komga" "$mac_project-jellyfin" \
        "$mac_project-immich-server" "$mac_project-immich-machine-learning" \
        "$mac_project-immich-redis" "$mac_project-immich-postgres" \
        "$mac_project-paperless-redis" "$mac_project-paperless-postgres" \
        "$mac_project-paperless-webserver" "$mac_project-paperless-gotenberg" \
        "$mac_project-paperless-tika" "$mac_project-pinchflat" \
        "$mac_project-kapowarr" "$mac_project-bindery" "$mac_project-trailarr" \
        "$mac_project-seerr" "$mac_project-nextcloud" \
        "$mac_project-nextcloud-cron" "$mac_project-nextcloud-db" \
        "$mac_project-nextcloud-cache" "$mac_project-karakeep" \
        "$mac_project-karakeep-chrome" "$mac_project-karakeep-meilisearch"
      ;;
    *) mac_die 'proof platform is invalid' ;;
  esac
}

# Every service with a published host port, in the one order allocation, report.rb,
# exports and the resume state all use. Entries are port names (radarr..sabnzbd are
# containers in arr/downloaders); a second port of a service takes `<name>_<suffix>`,
# which tests/policy_mac_test.rb holds report.rb to.
MAC_SERVICE_PORT_ORDER='beszel dozzle audiobookshelf komga jellyfin immich
paperless radarr sonarr prowlarr bazarr sabnzbd pinchflat kapowarr bindery
trailarr seerr nextcloud vaultwarden karakeep'

# How many services the roster holds.
mac_service_port_count() {
  # shellcheck disable=SC2086
  set -- $MAC_SERVICE_PORT_ORDER
  printf '%s\n' "$#"
}

# The resolved port of every roster service, one per line; a missing one aborts by name.
mac_service_ports() {
  for mac_port_service in $MAC_SERVICE_PORT_ORDER; do
    eval "printf '%s\\n' \"\${${mac_port_service}_port:?${mac_port_service}_port is required}\""
  done
}

# Export PLATFORM_<SERVICE>_PORT for every roster service.
mac_export_service_ports() {
  for mac_port_service in $MAC_SERVICE_PORT_ORDER; do
    mac_port_variable=PLATFORM_$(printf '%s' "$mac_port_service" |
      tr '[:lower:]' '[:upper:]')_PORT
    eval "export $mac_port_variable=\"\${${mac_port_service}_port:?${mac_port_service}_port is required}\""
  done
}

# The container identity for one Compose service; both lanes prefix the project.
mac_container_name() {
  mac_container_base=$1
  case ${PLATFORM_PROOF_PLATFORM:-mac} in
    integration | mac)
      printf '%s\n' "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}-$mac_container_base"
      ;;
    *) mac_die 'proof platform is invalid' ;;
  esac
}

# Services the Mac lane covers that the contract registry does not: Vaultwarden
# holds no credential to sign in with and Karakeep's verify.yml already signs in,
# so verify.sh runs their platform_verify_<name> tags instead.
MAC_UNREGISTERED_SERVICES='vaultwarden karakeep'

# Infrastructure hooks run ahead of the shared contract runner; the foundation hook
# covers no registered service, so it is coverage-neutral.
MAC_VERIFY_INFRASTRUCTURE_HOOKS='10-beszel.sh
15-media-acquisition-foundation.sh
20-dozzle.sh'
MAC_VERIFY_COVERAGE_NEUTRAL_HOOKS='15-media-acquisition-foundation.sh'

# Mac aliases of every service in tests/contracts/registry.yml. The registry is
# deliberately not extended with Mac data. Needs mac_script_dir set to tests/mac.
mac_registry_services() {
  ruby -ryaml -e '
    registry = YAML.safe_load_file(ARGV.fetch(0), aliases: false)
    entries = registry.is_a?(Hash) ? registry["contracts"] : nil
    abort "contract registry does not list contracts" unless
      entries.is_a?(Array) && !entries.empty?
    names = entries.map do |entry|
      abort "contract registry entry is not a mapping" unless entry.is_a?(Hash)
      service = entry["service"]
      abort "contract registry entry has no service" unless
        service.is_a?(String) && !service.empty?
      # paperless-ngx is the one registered service whose Mac alias drops the
      # suffix, the same exception tests/policy_support.rb applies to the
      # contract basename.
      service == "paperless-ngx" ? "paperless" : service
    end
    abort "contract registry services are not unique" unless names.uniq.length == names.length
    puts names
  ' "$mac_script_dir/../contracts/registry.yml"
}

# The contract path for one Mac alias, read from the registry; unknown aliases are refused.
mac_registry_contract_path() {
  ruby -ryaml -e '
    registry = YAML.safe_load_file(ARGV.fetch(0), aliases: false)
    requested = ARGV.fetch(1)
    entries = registry.is_a?(Hash) ? registry["contracts"] : nil
    abort "contract registry does not list contracts" unless entries.is_a?(Array)
    match = entries.find do |entry|
      next false unless entry.is_a?(Hash)
      service = entry["service"]
      next false unless service.is_a?(String)
      (service == "paperless-ngx" ? "paperless" : service) == requested
    end
    abort "unknown Mac contract service: #{requested}" unless match
    path = match["path"]
    abort "contract registry path is unusable for #{requested}" unless
      path.is_a?(String) && !path.empty?
    puts path
  ' "$mac_script_dir/../contracts/registry.yml" "$1"
}

# Collapsed table-driven hooks account for themselves against the registry, so a
# dropped service stays visible. Args: group self ran exempt [infrastructure]
# [coverage-neutral]. Sibling NN-service.sh hooks are credited automatically.
mac_assert_service_coverage() {
  mac_coverage_group=$1
  mac_coverage_self=$2
  mac_coverage_ran=$3
  mac_coverage_exempt=$4
  mac_coverage_infrastructure=${5-}
  mac_coverage_neutral=${6-}
  mac_coverage_registry=$(mac_registry_services) || return 1
  MAC_COVERAGE_REGISTRY=$mac_coverage_registry \
  MAC_COVERAGE_UNREGISTERED=$MAC_UNREGISTERED_SERVICES \
  MAC_COVERAGE_RAN=$mac_coverage_ran \
  MAC_COVERAGE_EXEMPT=$mac_coverage_exempt \
  MAC_COVERAGE_INFRASTRUCTURE=$mac_coverage_infrastructure \
  MAC_COVERAGE_NEUTRAL=$mac_coverage_neutral \
    ruby -e '
      group, group_dir, self_basename = ARGV
      registry = ENV.fetch("MAC_COVERAGE_REGISTRY").split
      unregistered = ENV.fetch("MAC_COVERAGE_UNREGISTERED").split
      ran = ENV.fetch("MAC_COVERAGE_RAN").split
      exempt = ENV.fetch("MAC_COVERAGE_EXEMPT").lines.map(&:strip).reject(&:empty?).to_h do |line|
        service, reason = line.split("=", 2)
        abort "mac #{group} hook exemption has no reason: #{line}" if reason.nil? || reason.empty?
        [service, reason]
      end
      infrastructure = ENV.fetch("MAC_COVERAGE_INFRASTRUCTURE").split
      neutral = ENV.fetch("MAC_COVERAGE_NEUTRAL").split

      expected = (registry + unregistered).uniq.sort
      siblings = Dir.children(group_dir).sort.reject { |name| name == self_basename }
                    .select { |name| name.end_with?(".sh") }
      unless infrastructure.empty?
        abort "mac #{group} infrastructure hook roster contains duplicates" unless
          infrastructure.uniq.length == infrastructure.length
        abort "mac #{group} coverage-neutral hook roster contains duplicates" unless
          neutral.uniq.length == neutral.length
        unknown_neutral = neutral - infrastructure
        abort "mac #{group} coverage-neutral hooks are not infrastructure hooks: #{unknown_neutral.join(", ")}" unless
          unknown_neutral.empty?
        missing_infrastructure = infrastructure - siblings
        extra_infrastructure = siblings - infrastructure
        abort "mac #{group} infrastructure hook roster differs (missing: #{missing_infrastructure.join(", ")}; extra: #{extra_infrastructure.join(", ")})" unless
          missing_infrastructure.empty? && extra_infrastructure.empty?
      end
      delegated_hooks = infrastructure.empty? ? siblings : infrastructure - neutral
      delegated = delegated_hooks.map do |name|
        match = /\A\d+-(?<service>[a-z0-9-]+)\.sh\z/.match(name)
        abort "mac #{group} hook is not named NN-service.sh: #{name}" unless match
        match[:service]
      end
      neutral.each do |name|
        abort "mac #{group} coverage-neutral hook is not named NN-service.sh: #{name}" unless
          /\A\d+-[a-z0-9-]+\.sh\z/.match?(name)
      end

      abort "mac #{group} hooks ran a service twice: #{(ran.tally.select { |_s, n| n > 1 }.keys).join(", ")}" unless
        ran.uniq.length == ran.length
      overlap = ran & delegated
      abort "mac #{group} hooks run and delegate the same service: #{overlap.join(", ")}" unless overlap.empty?
      stray = delegated - expected
      abort "mac #{group} hooks delegate to unregistered services: #{stray.join(", ")}" unless stray.empty?

      covered = (ran + delegated).sort
      surplus = covered - expected
      abort "mac #{group} hooks ran unregistered services: #{surplus.join(", ")}" unless surplus.empty?
      missing = expected - covered - exempt.keys
      abort "mac #{group} hooks did not cover: #{missing.join(", ")}" unless missing.empty?
      stale = exempt.keys - (expected - covered)
      abort "mac #{group} hook exemptions are stale: #{stale.join(", ")}" unless stale.empty?
      accounted = covered.length + exempt.length
      abort "mac #{group} hook accounting does not add up: #{accounted} of #{expected.length}" unless
        accounted == expected.length

      puts "mac #{group} hooks: covered #{accounted} of #{expected.length} registered services " \
           "(ran #{ran.length}, delegated #{delegated.length}, exempt #{exempt.length})"
      exempt.sort.each { |service, reason| puts "mac #{group} hooks: #{service} exempt because #{reason}" }
    ' "$mac_coverage_group" "$mac_script_dir/hooks/$mac_coverage_group" "$mac_coverage_self"
}

mac_run_hooks() {
  mac_hook_group=$1
  shift
  mac_hook_root=$mac_script_dir/hooks/$mac_hook_group
  [ -d "$mac_hook_root" ] || mac_die "No Mac hooks registered for $mac_hook_group"
  mac_hook_count=0
  for mac_hook in "$mac_hook_root"/*.sh; do
    [ -f "$mac_hook" ] || continue
    [ ! -L "$mac_hook" ] && [ -x "$mac_hook" ] ||
      mac_die "unsafe or non-executable Mac hook: $mac_hook"
    mac_hook_count=$((mac_hook_count + 1))
    "$mac_hook" "$@" || return 1
  done
  [ "$mac_hook_count" -gt 0 ] || mac_die "No Mac hooks registered for $mac_hook_group"
}
