# Issue 120 Registry Retry Design

## Goal

Make the integration-suite image pre-pull survive realistic transient registry
throttling without hiding a registry that remains unavailable.

## Scope

This change owns only the retry behavior in `tests/integration.sh` and its
repository tests. A separate change is adding Docker registry authentication,
so this work will not modify `.github/workflows/ci.yml`, login actions,
credentials, or permissions. Authentication reduces the probability of a
refusal; the retry remains the fallback for authenticated pulls and for
registries without credentials.

Image pulls remain serial. Registry-aware parallelism is intentionally deferred:
it changes scheduling as well as failure handling and is not needed to close the
reliability gap in issue #120.

## Retry behavior

`pull_image` will capture and replay the failed `docker pull` diagnostic so it
can inspect a registry-provided `retry-after` duration. A small parser will
accept the duration forms Docker has emitted for this failure, including
nanoseconds, `us` or `µs`, milliseconds, seconds, and minutes. An absent or
unrecognized value falls back to the local policy.

The local policy uses six attempts by default. Its exponential delays begin at
five seconds and grow as 5, 10, 20, 40, and 60 seconds; the local component is
capped at sixty seconds so one image cannot consume the entire suite timeout.
Parsed registry durations are rounded up to whole seconds. For each retry, the
base wait is the greater of that registry delay and the local exponential delay.
Random jitter from `/dev/urandom`, between one second and one quarter of the base
wait, is then added so jobs that were refused together do not retry in lockstep.

The existing environment overrides for attempt count and initial delay remain
supported and floored at two attempts and one second respectively. A new maximum
local-delay override defaults to sixty seconds and cannot be configured below
the initial delay. Malformed values fall back to their safe defaults. After the
final failed attempt, the function reports the image and exhausted attempt count
and returns failure; the pre-pull stops before requesting later images.

## Portability and cleanup

The implementation remains POSIX `sh` compatible on macOS, Ubuntu runners, and
the Alpine-based integration environment. It uses standard shell utilities
already available to the harness. Any temporary diagnostic file is removed on
success and failure, and pull output remains visible to CI operators.

## Tests

`tests/integration_suite_test.sh` will continue to drive the production retry
path with a stub `docker`. Its pre-pull fixture will also stub sleeping and the
random source so timing assertions are deterministic and do not slow the suite.
Coverage will prove:

- immediate success performs no sleep;
- a microsecond `retry-after` is parsed without shortening the local backoff;
- a longer registry delay takes precedence;
- exponential delays grow beyond twenty seconds and jitter is added;
- transient refusals succeed within the widened default budget;
- malformed delay and attempt overrides fall back to safe defaults; and
- permanent refusal stops exactly at the configured attempt budget and does not
  pull later images.

The focused verification set is `tests/integration_suite_test.sh`,
`ruby tests/policy_ci_test.rb`, and `ruby tests/ci/workflow_test.rb`.
