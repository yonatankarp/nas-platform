# Container CPU Limits Design

**Date:** 2026-08-20

## Objective

Prevent Docker workloads from consuming every CPU on the ASUSTOR AS6704T while
allowing compute-heavy services to use otherwise-idle container capacity. Every
managed container must have an explicit, workload-appropriate hard ceiling.

The existing Beszel alert at 90% remains informational: sustained high CPU is
allowed, but container workloads alone must leave capacity for ADM, SSH,
storage, and Ansible.

## Host and aggregate budget

The production NAS has four logical CPUs. All managed containers will share the
CPU set `0-2`, limiting container work in aggregate to three logical CPUs (75%
of the host). CPU 3 remains free of container processes, although the host may
continue scheduling its own processes on any CPU.

Docker Compose's `cpuset` control provides this aggregate boundary without an
ADM-specific parent cgroup or a persistent host-side cgroup service. The exact
CPU set is derived and rendered by Ansible rather than hard-coded into portable
Compose definitions.

The NAS inventory declares a container CPU budget of three. Preflight reads the
logical CPU count reported by Docker and refuses a production configuration
that has fewer than four CPUs, requests more CPUs than exist, or leaves no CPU
outside the container set. Disposable Mac environments use the CPUs assigned
to Docker Desktop rather than reserving a macOS CPU outside Docker's VM.

## Individual hard ceilings

Each Compose service declares `cpuset: ${PLATFORM_CONTAINER_CPUSET:?}` and an
explicit `cpus` ceiling. Ceilings are assigned by workload class:

| Workload class | Ceiling | Containers |
| --- | ---: | --- |
| Heavy | 3.0 | Immich server, Immich machine learning, Jellyfin, Paperless webserver, tinyMediaManager |
| Medium | 2.0 | Immich PostgreSQL, Paperless PostgreSQL, Gotenberg, Tika |
| Moderate | 1.5 | Komga, Audiobookshelf |
| Light | 1.0 | Dozzle, ntfy, Beszel hub |
| Minimal | 0.5 | Immich Redis/Valkey, Paperless Redis/Valkey, Beszel agents, Dozzle alert relay, socket proxies |

Heavy services can borrow the entire three-CPU container set when other
services are idle. Multiple busy services contend within that set but cannot
consume CPU 3. Lower ceilings prevent a lightweight or auxiliary service from
unexpectedly monopolizing the container budget.

All containers retain Docker's default, equal CPU shares. Shares are deliberately
not tuned without production contention evidence: they are relative scheduler
weights rather than limits, and the aggregate CPU set plus hard ceilings already
provide the required safety properties.

## Ansible and Compose data flow

1. Platform inventory provides the production container CPU budget.
2. Preflight reads Docker's available logical CPU count, validates host
   headroom, and derives the effective CPU-set string.
3. Every service role renders the effective value as
   `PLATFORM_CONTAINER_CPUSET` in its managed `.env` file.
4. Every Compose service consumes the required variable through `cpuset` and
   declares its version-controlled `cpus` ceiling.
5. Compose recreates affected containers stack by stack so Docker applies the
   new HostConfig values.

The CPU-set variable is required interpolation. A missing rendered value causes
Compose to fail instead of silently deploying an unlimited container.

## Validation and failure behavior

Preflight fails before target mutation when Docker CPU metadata is missing or
invalid, the production host has fewer than four logical CPUs, the requested
budget exceeds the available CPUs, or the budget leaves no host headroom.

Repository policy tests enumerate every Compose service and require both the
shared CPU-set expression and its exact hard ceiling. This makes a newly added
container fail CI until its resource class is chosen explicitly.

Rendered Compose tests verify that the CPU set and fractional quotas survive
interpolation and override merging. Runtime verification inspects every managed
container and compares Docker's effective CPU set and quota with policy. A
runtime that ignores or changes the requested values is a deployment failure,
not a warning.

## Test strategy

Implementation will be test-driven and cover:

- policy failure when any Compose service omits `cpuset` or `cpus`;
- policy failure when a service's ceiling differs from its pinned class;
- preflight acceptance of a four-CPU host with a three-CPU production budget;
- preflight rejection of invalid, oversized, and zero-headroom budgets;
- rendered Compose values for NAS and disposable Mac configurations;
- runtime inspection of effective Docker CPU-set and quota values;
- Ansible syntax checks and the full `tests/validate-policy.sh` gate;
- affected integration contracts where Compose definitions and rendered
  environment files participate in deployment.

## Rollout and scope

The Ansible run recreates containers stack by stack. Persistent volumes, bind
mounts, application state, memory settings, and application worker counts are
unchanged. CPU enforcement begins when each container is recreated.

This change does not introduce dynamic quota adjustment, custom cgroup
management, CPU-share prioritization, or memory limits. Production telemetry can
inform later tuning of individual ceilings without changing the aggregate
three-CPU safety boundary.
