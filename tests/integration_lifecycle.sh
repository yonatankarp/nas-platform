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
    case "$lifecycle_state:$lifecycle_event" in
      start:seed-retirement-fixture) lifecycle_state=seeded ;;
      start:converge) lifecycle_state=converged ;;
      seeded:start-retirement-fixture) lifecycle_state=fixture-started ;;
      seeded:converge) lifecycle_state=converged ;;
      fixture-started:converge) lifecycle_state=retirement-converged ;;
      retirement-converged:assert-retired) lifecycle_state=retirement-asserted ;;
      converged:success|retirement-asserted:success) lifecycle_state=succeeded ;;
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
