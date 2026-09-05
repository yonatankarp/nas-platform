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

mac_ansible_playbook() {
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

# Both disposable lanes deploy through a Compose project namespace and name
# every container after it, so one roster serves the Mac and integration proof
# platforms alike. Only production keeps the canonical Compose names.
mac_target_container_names() {
  mac_project=$1
  case ${PLATFORM_PROOF_PLATFORM:-mac} in
    integration | mac)
      printf '%s\n' "$mac_project-beszel" "$mac_project-beszel-agent-intel" \
        "$mac_project-beszel-agent-portable" "$mac_project-beszel-socket-proxy" \
        "$mac_project-ntfy" "$mac_project-dozzle-alert-relay" \
        "$mac_project-dozzle" "$mac_project-dozzle-socket-proxy" \
        "$mac_project-audiobookshelf" "$mac_project-komga" "$mac_project-jellyfin" \
        "$mac_project-immich-server" "$mac_project-immich-machine-learning" \
        "$mac_project-immich-redis" "$mac_project-immich-postgres" \
        "$mac_project-paperless-redis" "$mac_project-paperless-postgres" \
        "$mac_project-paperless-webserver" "$mac_project-paperless-gotenberg" \
        "$mac_project-paperless-tika" "$mac_project-pinchflat" \
        "$mac_project-kapowarr" "$mac_project-bindery" "$mac_project-trailarr" \
        "$mac_project-seerr"
      ;;
    *) mac_die 'proof platform is invalid' ;;
  esac
}

# Every service the disposable lanes publish a host port for, in the one order
# everything derived from this roster uses: ports are allocated in this order,
# handed to report.rb in this order, exported in this order, reserved in this
# order, and read back from the resume state in this order.
#
# tests/mac/run.sh used to spell the roster out ten times, and -- worse -- in two
# divergent hand-written orders: the positional integration handoff listed the
# original eight services alphabetically and appended the rest, while allocation
# and the exports used the order the services were added. Nothing enforced that
# the two agreed, and a mismatch does not fail: the positional unpack would just
# bind every service to another service's port in silence. One order removes
# that failure mode rather than documenting it. It is safe to have exactly one
# because the positional handoff is internal to read_integration_ports and its
# single consumer, and the on-disk integration ports file is keyed by name, so
# no caller outside that function can observe an order at all.
MAC_SERVICE_PORT_ORDER='beszel ntfy dozzle audiobookshelf komga jellyfin immich
paperless radarr sonarr prowlarr bazarr sabnzbd pinchflat kapowarr bindery
trailarr seerr'

# How many services the roster holds, for callers validating a list length
# against it. Resetting the positional parameters inside a function does not
# touch the caller's.
mac_service_port_count() {
  # shellcheck disable=SC2086
  set -- $MAC_SERVICE_PORT_ORDER
  printf '%s\n' "$#"
}

# The resolved host port of every roster service, one per line, in roster order.
# Reads the "<service>_port" shell variables the runner has already resolved; a
# service on the roster with no resolved port aborts by name instead of
# contributing an empty field to a docker filter or a port reservation.
mac_service_ports() {
  for mac_port_service in $MAC_SERVICE_PORT_ORDER; do
    eval "printf '%s\\n' \"\${${mac_port_service}_port:?${mac_port_service}_port is required}\""
  done
}

# Export PLATFORM_<SERVICE>_PORT for every roster service from the same
# "<service>_port" variables. This replaces fifteen hand-written export lines
# whose only guard was that a human kept them in step with the roster.
mac_export_service_ports() {
  for mac_port_service in $MAC_SERVICE_PORT_ORDER; do
    mac_port_variable=PLATFORM_$(printf '%s' "$mac_port_service" |
      tr '[:lower:]' '[:upper:]')_PORT
    eval "export $mac_port_variable=\"\${${mac_port_service}_port:?${mac_port_service}_port is required}\""
  done
}

# The container identity for one Compose service. Both disposable lanes prefix
# the isolated Compose project, so the identity no longer forks by proof
# platform. Every wrapper used to carry its own copy of that case statement, so
# a new service either repeated it or quietly used the wrong lane's identity.
mac_container_name() {
  mac_container_base=$1
  case ${PLATFORM_PROOF_PLATFORM:-mac} in
    integration | mac)
      printf '%s\n' "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}-$mac_container_base"
      ;;
    *) mac_die 'proof platform is invalid' ;;
  esac
}

# The Mac lane covers one service the contract registry does not: ntfy has no
# contract suite of its own, so tests/contracts/registry.yml never lists it, yet
# the lane deploys, recreates and verifies it. Coverage accounting keyed only to
# the registry would report a clean full pass while silently skipping the service
# whose push-routing bug the contract suites caught, so the addition is named.
MAC_UNREGISTERED_SERVICES='ntfy'

# Verification keeps four infrastructure-specific hooks ahead of the shared
# contract runner. This is the one canonical roster used both by verify.sh for
# dispatch and by 30-services.sh for exact coverage accounting. The foundation
# hook verifies infrastructure rather than a registered service, so it is named
# separately as coverage-neutral instead of being disguised as an exemption.
MAC_VERIFY_INFRASTRUCTURE_HOOKS='10-beszel.sh
15-media-acquisition-foundation.sh
15-ntfy.sh
20-dozzle.sh'
MAC_VERIFY_COVERAGE_NEUTRAL_HOOKS='15-media-acquisition-foundation.sh'

# The Mac aliases of every service in tests/contracts/registry.yml. The registry
# is the platform's authoritative roster, and it is deliberately not extended
# with Mac-lane data: its entries are constrained to exactly a service and a path
# by both tests/policy_test.rb and tests/run_contracts.rb, and coupling the
# integration contract registry to Mac scaffolding would be the wrong trade. The
# per-service Mac data lives in the tables in run-contract.sh and in the hooks;
# the registry is what those tables are held to.
#
# Like mac_run_hooks, this and mac_registry_contract_path need the caller to have
# set mac_script_dir to tests/mac: the registry is resolved relative to it.
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

# The canonical contract path for one Mac service alias, read from the registry
# so the runner never carries a second copy of the service-to-script mapping.
# An alias the registry does not know is refused here rather than dispatched.
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

# Collapsing a group of per-service hook files into one table-driven hook removes
# the only thing that used to make a dropped service visible: mac_run_hooks
# refuses a group with no files at all, but a collapsed group satisfies it with a
# single file no matter how few services that file actually ran. Every collapsed
# hook therefore accounts for itself here, against the registry rather than
# against the table that produced its work, and prints how many services it
# covered in the same "N of M" form tests/validate-policy.sh uses.
#
#   group   the hook group, which is also its directory name
#   self    this hook's own basename, excluded from the sibling scan
#   ran     the services this hook executed, one per line
#   exempt  service=reason lines for services this group deliberately skips
#   infrastructure  optional exact sibling-hook basename roster, which a group
#                   that never collapsed declares in full rather than only for
#                   the hooks that sort ahead of a table
#   coverage-neutral optional infrastructure hooks that do not represent a service
#
# Services still handled by their own NN-service.sh file in the same group are
# credited automatically from the sibling filenames, so delegating one service
# back out to its own hook needs no bookkeeping here.
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
