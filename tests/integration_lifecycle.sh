#!/bin/sh

consume_integration_lifecycle_plan() {
  if lifecycle_plan=$("$@"); then
    lifecycle_producer_status=0
  else
    lifecycle_producer_status=$?
  fi
  [ "$lifecycle_producer_status" -eq 0 ] || {
    printf 'integration lifecycle producer failed with status %s\n' \
      "$lifecycle_producer_status" >&2
    return 1
  }

  lifecycle_state=start
  validated_lifecycle_plan=
  while IFS= read -r lifecycle_event; do
    # The table is the specification, and the orderings it omits are the point.
    #
    # An ordinary lane is converge then success. The upgrade lane (#773) inserts
    # the three events that make a migration observable: seed writes rows through
    # the service's own API while the BASE pin is serving, repin swaps the pinned
    # image to the head one, and the second converge is where the container runs
    # its own migration against a store the previous version wrote. verify reads
    # those rows back.
    #
    # Every one of those has to come after the one before it or it proves
    # nothing, and "proves nothing" is the failure this repository keeps closing:
    # a repin before a seed migrates an empty store, which is exactly the
    # fresh-install path every existing lane already takes, and it would pass.
    # A verify before the second converge reads the rows back from the image that
    # wrote them. Both are green runs that assert nothing, so neither is
    # expressible here rather than merely unused -- there is no state in which
    # those events are accepted.
    #
    # stop is the sixth, and it is the shutdown half of #671 (#781). The head
    # container is running when verify ends, so that is the one moment its stop
    # can be measured; the BASE container's cannot be, because Compose removes it
    # inside the same recreate. It comes last and there is no `verified:success`
    # any more, so an upgrade lane that ends at verify -- which is every upgrade
    # lane before #781 -- is now as unrepresentable as one that ends at the
    # repin. A stop before the verify is refused for the mirror reason: it reads
    # the seeded rows back out of a container that is no longer running.
    case "$lifecycle_state:$lifecycle_event" in
      start:converge) lifecycle_state=converged ;;
      converged:success) lifecycle_state=succeeded ;;
      converged:seed) lifecycle_state=seeded ;;
      seeded:repin) lifecycle_state=repinned ;;
      repinned:converge) lifecycle_state=upgraded ;;
      upgraded:verify) lifecycle_state=verified ;;
      verified:stop) lifecycle_state=stopped ;;
      stopped:success) lifecycle_state=succeeded ;;
      *)
        printf 'invalid integration lifecycle transition: %s -> %s\n' \
          "$lifecycle_state" "$lifecycle_event" >&2
        return 1
        ;;
    esac
    if [ -z "$validated_lifecycle_plan" ]; then
      validated_lifecycle_plan=$lifecycle_event
    else
      validated_lifecycle_plan="$validated_lifecycle_plan
$lifecycle_event"
    fi
  done <<EOF
$lifecycle_plan
EOF

  [ "$lifecycle_state" = succeeded ] || {
    printf 'integration lifecycle ended in state %s instead of success\n' \
      "$lifecycle_state" >&2
    return 1
  }
  printf '%s\n' "$validated_lifecycle_plan"
}
