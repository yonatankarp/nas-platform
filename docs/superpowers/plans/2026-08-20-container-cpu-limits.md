# Container CPU Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every managed container an explicit CPU ceiling while restricting all production containers to a shared three-logical-CPU set on the four-core NAS.

**Architecture:** An Ansible filter derives a validated contiguous CPU set from Docker's reported capacity and the platform inventory budget. Every Compose service consumes that rendered set and declares a pinned hard quota; a reusable post-deploy role compares Docker's effective HostConfig with the tracked Compose policy.

**Tech Stack:** Ansible, Python filter plugins, Docker Compose v2, Docker CLI inspection, Ruby policy tests, YAML, POSIX shell

---

## File structure

- `filter_plugins/container_cpu.py`: pure CPU-set derivation and sanitized runtime-policy comparison.
- `tests/container_cpu_filter_test.py`: behavior tests for valid budgets, invalid budgets, and runtime drift.
- `inventory/group_vars/nas_hosts/main.yml`: production three-CPU budget.
- `inventory/group_vars/mac_hosts/main.yml`: Docker Desktop proof policy using all VM CPUs.
- `roles/preflight/tasks/main.yml`: read Docker CPU capacity and derive the effective CPU set before mutation.
- `roles/preflight/meta/argument_specs.yml`: validate the required inventory budget input.
- `roles/container_cpu/tasks/main.yml`: reusable read-only post-deploy inspection.
- `roles/container_cpu/meta/argument_specs.yml`: contract for the reusable verification role.
- `roles/*/templates/env.j2`: render the effective CPU set into every stack environment.
- `services/*/compose.yml`: declare `cpuset` and the service-specific `cpus` ceiling.
- `roles/*/tasks/main.yml`: invoke the reusable verifier after each final Compose deployment.
- `tests/policy_test.rb`: pin complete service coverage, exact ceilings, inventory ownership, environment propagation, and verifier inclusion.
- `tests/contracts/dozzle.sh`, `tests/contracts/paperless.sh`: provide the required CPU-set interpolation input to standalone Compose fixtures.
- `tests/validate-policy.sh`: run the new Python behavior test under Ansible's interpreter.
- `README.md`: document the production budget, ceilings, and inspection command.

### Task 1: Build the validated CPU-set filter

**Files:**
- Create: `tests/container_cpu_filter_test.py`
- Create: `filter_plugins/container_cpu.py`
- Modify: `tests/validate-policy.sh`

- [ ] **Step 1: Write the failing CPU-set behavior test**

Create `tests/container_cpu_filter_test.py` with direct plugin loading and exact acceptance/rejection cases:

```python
#!/usr/bin/env python3
"""Behavior tests for container CPU policy filters."""

import importlib.util
import pathlib

from ansible.errors import AnsibleFilterError


ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN_PATH = ROOT / "filter_plugins" / "container_cpu.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location("container_cpu", PLUGIN_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("container CPU filter cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_rejected(function, *arguments):
    try:
        function(*arguments)
    except AnsibleFilterError:
        return
    raise AssertionError(f"accepted invalid CPU policy: {arguments!r}")


plugin = load_plugin()
derive = plugin.platform_container_cpuset

assert derive(4, 3, True) == "0-2"
assert derive(1, 0, False) == "0"
assert derive(6, 0, False) == "0-5"
assert derive(8, 3, True) == "0-2"

for arguments in [
    (True, 3, True),
    (4, False, True),
    (4, 3, "yes"),
    (0, 0, False),
    (4, -1, False),
    (4, 5, False),
    (4, 4, True),
    (4, 0, True),
]:
    require_rejected(derive, *arguments)

print("Container CPU-set derivation behavior passed")
```

- [ ] **Step 2: Register the test in the policy gate and verify it fails**

Add this line immediately after `tests/managed_user_state_filter_test.py` in `tests/validate-policy.sh`:

```sh
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/container_cpu_filter_test.py
```

Run:

```bash
ansible_python=$(ansible-playbook --version | sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p')
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/container_cpu_filter_test.py
```

Expected: FAIL because `filter_plugins/container_cpu.py` does not exist.

- [ ] **Step 3: Implement the minimal derivation filter**

Create `filter_plugins/container_cpu.py`:

```python
"""Filters for deriving and verifying the managed container CPU policy."""

from ansible.errors import AnsibleFilterError


def _require_integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int):
        raise AnsibleFilterError(f"{label} must be an integer")
    return value


def platform_container_cpuset(available_cpus, requested_budget, require_headroom):
    """Return a contiguous zero-based CPU set after validating host headroom."""
    available = _require_integer(available_cpus, "Docker CPU count")
    budget = _require_integer(requested_budget, "container CPU budget")
    if not isinstance(require_headroom, bool):
        raise AnsibleFilterError("container CPU headroom policy must be boolean")
    if available < 1:
        raise AnsibleFilterError("Docker must report at least one logical CPU")
    if budget < 0:
        raise AnsibleFilterError("container CPU budget cannot be negative")
    if budget == 0:
        if require_headroom:
            raise AnsibleFilterError("production container CPU budget must be explicit")
        budget = available
    if budget > available:
        raise AnsibleFilterError("container CPU budget exceeds Docker CPU capacity")
    if require_headroom and budget >= available:
        raise AnsibleFilterError("production container CPU budget leaves no host headroom")
    return "0" if budget == 1 else f"0-{budget - 1}"


class FilterModule:
    """Expose managed container CPU policy filters."""

    def filters(self):
        return {"platform_container_cpuset": platform_container_cpuset}
```

- [ ] **Step 4: Run the focused test and policy test**

Run:

```bash
ansible_python=$(ansible-playbook --version | sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p')
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/container_cpu_filter_test.py
ruby tests/policy_test.rb
```

Expected: `Container CPU-set derivation behavior passed` and `policy: all properties hold`.

- [ ] **Step 5: Commit the filter boundary**

```bash
git add filter_plugins/container_cpu.py tests/container_cpu_filter_test.py tests/validate-policy.sh
git commit -m "feat: derive validated container CPU sets"
```

### Task 2: Derive and propagate the platform CPU set

**Files:**
- Modify: `tests/policy_test.rb`
- Modify: `inventory/group_vars/nas_hosts/main.yml`
- Modify: `inventory/group_vars/mac_hosts/main.yml`
- Modify: `roles/preflight/meta/argument_specs.yml`
- Modify: `roles/preflight/tasks/main.yml`
- Modify: `roles/audiobookshelf/templates/env.j2`
- Modify: `roles/beszel/templates/env.j2`
- Modify: `roles/dozzle/templates/env.j2`
- Modify: `roles/immich/templates/env.j2`
- Modify: `roles/jellyfin/templates/env.j2`
- Modify: `roles/komga/templates/env.j2`
- Modify: `roles/ntfy/templates/env.j2`
- Modify: `roles/paperless_ngx/templates/env.j2`
- Modify: `roles/tinymediamanager/templates/env.j2`

- [ ] **Step 1: Add failing inventory, preflight, and environment policy assertions**

In `tests/policy_test.rb`, add `platform_container_cpu_budget` to
`PLATFORM_CAPABILITIES`. In the host-group loop, assert the exact platform
policy:

```ruby
expected_cpu_budget = platform_kind == "nas" ? 3 : 0
check(failures, host_vars["platform_container_cpu_budget"] == expected_cpu_budget,
      "#{relative_path} platform_container_cpu_budget must be #{expected_cpu_budget}")
```

After loading the preflight role source, require the Docker capacity read and
filter use:

```ruby
check(failures,
      preflight_body.include?("docker, info, --format, json") &&
        preflight_body.include?("platform_container_cpuset") &&
        preflight_body.include?("platform_effective_container_cpuset"),
      "preflight must derive the effective container CPU set from Docker capacity")
```

For every implemented role, require the environment template to contain one
exact assignment:

```ruby
env_path = File.join(role_root, "templates", "env.j2")
env_source = File.file?(env_path) ? File.read(env_path) : ""
check(failures,
      env_source.lines.map(&:strip).count(
        "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}"
      ) == 1,
      "#{name}: environment must render the effective container CPU set exactly once")
```

- [ ] **Step 2: Run the policy test to verify the new contract fails**

Run: `ruby tests/policy_test.rb`

Expected: failures for both host-group budgets, missing preflight derivation, and
all nine missing environment assignments.

- [ ] **Step 3: Declare platform budgets and the preflight argument**

Add to `inventory/group_vars/nas_hosts/main.yml`:

```yaml
# Three of four logical CPUs are available to containers; one stays container-free.
platform_container_cpu_budget: 3
```

Add to `inventory/group_vars/mac_hosts/main.yml`:

```yaml
# Docker Desktop already isolates its VM from macOS; use all CPUs assigned to the VM.
platform_container_cpu_budget: 0
```

Add to `roles/preflight/meta/argument_specs.yml` under `options`:

```yaml
      platform_container_cpu_budget:
        type: int
        required: true
        description: >-
          Logical CPUs available to managed containers. Zero means every CPU
          reported by Docker and is allowed only on non-production platforms.
```

- [ ] **Step 4: Read Docker capacity and derive the effective set before mutation**

Immediately after the existing Docker daemon reachability task in
`roles/preflight/tasks/main.yml`, add:

```yaml
- name: Read Docker logical CPU capacity
  ansible.builtin.command:
    argv: [docker, info, --format, json]
  register: preflight_docker_info
  changed_when: false
  check_mode: false

- name: Derive the managed container CPU set
  ansible.builtin.set_fact:
    platform_effective_container_cpuset: >-
      {{ ((preflight_docker_info.stdout | from_json).NCPU)
         | platform_container_cpuset(
             platform_container_cpu_budget,
             platform_kind == 'nas') }}

- name: Report the managed container CPU boundary
  ansible.builtin.debug:
    msg: >-
      Managed containers use CPUs {{ platform_effective_container_cpuset }} of
      {{ (preflight_docker_info.stdout | from_json).NCPU }} reported by Docker.
```

The filter provides the failure messages for malformed Docker metadata,
oversized budgets, implicit production budgets, and zero host headroom.

- [ ] **Step 5: Render the effective set into every stack environment**

Add this exact non-secret line once to all nine `roles/*/templates/env.j2`
files listed above:

```jinja2
PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}
```

- [ ] **Step 6: Run focused validation**

Run:

```bash
ruby tests/policy_test.rb
ansible-playbook -i inventory/local.yml site.yml --syntax-check
```

Expected: policy passes and syntax check ends with `failed=0`.

- [ ] **Step 7: Commit platform CPU-set propagation**

```bash
git add inventory/group_vars roles/preflight roles/*/templates/env.j2 tests/policy_test.rb
git commit -m "feat: propagate platform container CPU set"
```

### Task 3: Pin hard ceilings in every Compose service

**Files:**
- Modify: `tests/policy_test.rb`
- Modify: `services/audiobookshelf/compose.yml`
- Modify: `services/beszel/compose.yml`
- Modify: `services/dozzle/compose.yml`
- Modify: `services/immich/compose.yml`
- Modify: `services/jellyfin/compose.yml`
- Modify: `services/komga/compose.yml`
- Modify: `services/ntfy/compose.yml`
- Modify: `services/paperless-ngx/compose.yml`
- Modify: `services/tinymediamanager/compose.yml`
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/contracts/paperless.sh`

- [ ] **Step 1: Add the failing complete Compose policy map**

Add this constant near the other finite platform policy constants in
`tests/policy_test.rb`:

```ruby
EXPECTED_CONTAINER_CPUS = {
  "audiobookshelf" => { "audiobookshelf" => 1.5 },
  "beszel" => {
    "hub" => 1.0,
    "agent-portable" => 0.5,
    "agent-intel" => 0.5,
    "socket-proxy" => 0.5
  },
  "dozzle" => { "alert-relay" => 0.5, "dozzle" => 1.0, "socket-proxy" => 0.5 },
  "immich" => {
    "immich-server" => 3.0,
    "immich-machine-learning" => 3.0,
    "redis" => 0.5,
    "database" => 2.0
  },
  "jellyfin" => { "jellyfin" => 3.0 },
  "komga" => { "komga" => 1.5 },
  "ntfy" => { "ntfy" => 1.0 },
  "paperless-ngx" => {
    "broker" => 0.5,
    "db" => 2.0,
    "webserver" => 3.0,
    "gotenberg" => 2.0,
    "tika" => 2.0
  },
  "tinymediamanager" => { "tinymediamanager" => 3.0 }
}.freeze
```

Immediately after each Compose file's `containers` map is loaded, add:

```ruby
expected_cpus = EXPECTED_CONTAINER_CPUS.fetch(name)
check(failures, containers.keys.sort == expected_cpus.keys.sort,
      "#{name}: CPU policy must cover the exact Compose service set")
```

Inside the existing `containers.each` loop, add:

```ruby
check(failures, spec["cpuset"] == "${PLATFORM_CONTAINER_CPUSET:?}",
      "#{label}: must require the Ansible-rendered platform CPU set")
check(failures, spec["cpus"] == expected_cpus.fetch(container),
      "#{label}: CPU ceiling must be #{expected_cpus.fetch(container)}")
check(failures, !spec.key?("cpu_shares"),
      "#{label}: must retain Docker's equal default CPU shares")
```

- [ ] **Step 2: Run the policy test to prove every container is currently unlimited**

Run: `ruby tests/policy_test.rb`

Expected: one missing CPU-set and one wrong-ceiling failure for each of the 21
Compose services.

- [ ] **Step 3: Add the required CPU set and exact ceiling to every service**

For every service in the nine base Compose files, place these keys directly
after `image` using the value from `EXPECTED_CONTAINER_CPUS`:

```yaml
    cpuset: ${PLATFORM_CONTAINER_CPUSET:?}
    cpus: 3.0
```

Use `3.0`, `2.0`, `1.5`, `1.0`, or `0.5` exactly as mapped. Do not add
`cpu_shares`; equal Docker defaults are the approved policy. Do not repeat the
keys in `compose.mac.yml` or `compose.integration.yml`, so overrides inherit the
base policy.

- [ ] **Step 4: Supply CPU-set interpolation to standalone Compose contracts**

In the `env` prefix inside `render_group_contract` in
`tests/contracts/dozzle.sh` and inside `render_paperless_mounts` in
`tests/contracts/paperless.sh`, add:

```sh
PLATFORM_CONTAINER_CPUSET=0-2
```

This is fixture-only input; the deployed stacks receive the value from their
Ansible-rendered `.env` files.

- [ ] **Step 5: Run the policy and Compose contract tests**

Run:

```bash
ruby tests/policy_test.rb
ruby tests/run_contracts_test.rb
ruby tests/run_contracts.rb --validate-only
```

Expected: policy reports all properties hold, the contract harness tests pass,
and every registered contract validates.

- [ ] **Step 6: Commit the hard ceilings**

```bash
git add services tests/policy_test.rb tests/contracts/dozzle.sh tests/contracts/paperless.sh
git commit -m "feat: cap every managed container CPU workload"
```

### Task 4: Verify Docker's effective runtime policy

**Files:**
- Modify: `tests/container_cpu_filter_test.py`
- Modify: `filter_plugins/container_cpu.py`
- Create: `roles/container_cpu/tasks/main.yml`
- Create: `roles/container_cpu/meta/argument_specs.yml`

- [ ] **Step 1: Add failing sanitized runtime-comparison tests**

Extend `tests/container_cpu_filter_test.py` with a Compose service fixture and
Docker inspection fixture:

```python
verify_runtime = plugin.platform_container_cpu_runtime_errors
compose_services = {
    "server": {"cpuset": "0-2", "cpus": 3.0},
    "worker": {"cpuset": "0-2", "cpus": 1.5},
}
inspections = [
    {
        "Config": {"Labels": {"com.docker.compose.service": "server"}},
        "HostConfig": {"CpusetCpus": "0-2", "NanoCpus": 3_000_000_000},
    },
    {
        "Config": {"Labels": {"com.docker.compose.service": "worker"}},
        "HostConfig": {"CpusetCpus": "0-2", "NanoCpus": 1_500_000_000},
    },
]
assert verify_runtime(compose_services, inspections, "0-2") == []

drifted = [dict(inspections[0]), dict(inspections[1])]
drifted[1] = {
    "Config": inspections[1]["Config"],
    "HostConfig": {"CpusetCpus": "0-3", "NanoCpus": 0},
}
errors = verify_runtime(compose_services, drifted, "0-2")
assert errors == [
    "worker: effective CPU set is 0-3, expected 0-2",
    "worker: effective CPU quota is 0, expected 1500000000 nanocpus",
]

require_rejected(verify_runtime, [], inspections, "0-2")
require_rejected(verify_runtime, compose_services, [], "0-2")
require_rejected(verify_runtime, compose_services, inspections, "")
```

Run the focused test and expect failure because the new filter is absent.

- [ ] **Step 2: Implement strict, sanitized runtime comparison**

Add imports and the runtime filter to `filter_plugins/container_cpu.py`:

```python
from decimal import Decimal, InvalidOperation


NANOCPUS_PER_CPU = 1_000_000_000


def _expected_nanocpus(service, spec):
    try:
        cpus = Decimal(str(spec["cpus"]))
    except (KeyError, InvalidOperation, TypeError, ValueError) as error:
        raise AnsibleFilterError(f"{service}: Compose CPU quota is invalid") from error
    nanocpus = cpus * NANOCPUS_PER_CPU
    if cpus <= 0 or nanocpus != nanocpus.to_integral_value():
        raise AnsibleFilterError(f"{service}: Compose CPU quota is invalid")
    return int(nanocpus)


def platform_container_cpu_runtime_errors(compose_services, inspections, expected_cpuset):
    """Return non-secret drift messages for running Compose containers."""
    if not isinstance(compose_services, dict) or not compose_services:
        raise AnsibleFilterError("Compose CPU service policy must be a nonempty mapping")
    if not isinstance(inspections, list) or not inspections:
        raise AnsibleFilterError("runtime CPU inspection must contain managed containers")
    if not isinstance(expected_cpuset, str) or not expected_cpuset:
        raise AnsibleFilterError("effective container CPU set must be nonempty")

    errors = []
    seen = set()
    for inspection in inspections:
        if not isinstance(inspection, dict):
            raise AnsibleFilterError("runtime CPU inspection entry must be a mapping")
        service = inspection.get("Config", {}).get("Labels", {}).get(
            "com.docker.compose.service"
        )
        if not isinstance(service, str) or service not in compose_services or service in seen:
            raise AnsibleFilterError("runtime CPU inspection has an unknown or duplicate service")
        seen.add(service)
        expected_nano = _expected_nanocpus(service, compose_services[service])
        host_config = inspection.get("HostConfig", {})
        actual_set = host_config.get("CpusetCpus")
        actual_nano = host_config.get("NanoCpus")
        if actual_set != expected_cpuset:
            errors.append(
                f"{service}: effective CPU set is {actual_set}, expected {expected_cpuset}"
            )
        if actual_nano != expected_nano:
            errors.append(
                f"{service}: effective CPU quota is {actual_nano}, "
                f"expected {expected_nano} nanocpus"
            )
    return sorted(errors)
```

Expose it from `FilterModule.filters()` alongside `platform_container_cpuset`.

- [ ] **Step 3: Run the filter behavior test**

Run the same focused command from Task 1.

Expected: both derivation and runtime-comparison assertions pass.

- [ ] **Step 4: Create the reusable runtime verification role contract**

Create `roles/container_cpu/meta/argument_specs.yml`:

```yaml
---
argument_specs:
  main:
    short_description: Verify effective Docker CPU controls for one Compose project
    options:
      container_cpu_service_name:
        type: str
        required: true
      container_cpu_project_name:
        type: str
        required: true
      platform_effective_container_cpuset:
        type: str
        required: true
      platform_current_dir:
        type: path
        required: true
```

- [ ] **Step 5: Create read-only collection and fail-closed verification tasks**

Create `roles/container_cpu/tasks/main.yml`:

```yaml
---
- name: Read the deployed base Compose CPU policy
  ansible.builtin.slurp:
    path: "{{ platform_current_dir }}/services/{{ container_cpu_service_name }}/compose.yml"
  register: container_cpu_compose_source

- name: Resolve the deployed Compose CPU policy
  ansible.builtin.set_fact:
    container_cpu_compose_services: >-
      {{ (container_cpu_compose_source.content | b64decode | from_yaml).services }}

- name: List running containers in the managed Compose project
  ansible.builtin.command:
    argv:
      - docker
      - container
      - ls
      - --quiet
      - --filter
      - "label=com.docker.compose.project={{ container_cpu_project_name }}"
  register: container_cpu_running_ids
  changed_when: false
  check_mode: false

- name: Require running containers for CPU verification
  ansible.builtin.assert:
    that:
      - container_cpu_running_ids.stdout_lines | length > 0
    fail_msg: >-
      {{ container_cpu_service_name }} has no running containers in Compose
      project {{ container_cpu_project_name }}.

- name: Inspect effective Docker CPU controls
  ansible.builtin.command:
    argv: "{{ ['docker', 'container', 'inspect'] + container_cpu_running_ids.stdout_lines }}"
  register: container_cpu_inspection
  changed_when: false
  check_mode: false
  no_log: true

- name: Resolve sanitized container CPU drift
  ansible.builtin.set_fact:
    container_cpu_runtime_errors: >-
      {{ container_cpu_compose_services
         | platform_container_cpu_runtime_errors(
             container_cpu_inspection.stdout | from_json,
             platform_effective_container_cpuset) }}
  no_log: true

- name: Require effective Docker CPU controls
  ansible.builtin.assert:
    that:
      - container_cpu_runtime_errors | length == 0
    fail_msg: "Container CPU policy drift: {{ container_cpu_runtime_errors | join('; ') }}"
```

The raw `docker inspect` result stays under `no_log` because it contains
container environment values. Only service names and CPU-control mismatches are
allowed into the assertion message.

- [ ] **Step 6: Run syntax and focused tests**

Run:

```bash
ansible_python=$(ansible-playbook --version | sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p')
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/container_cpu_filter_test.py
ansible-playbook -i inventory/local.yml site.yml --syntax-check
```

Expected: filter behavior passes and syntax check ends with `failed=0`.

- [ ] **Step 7: Commit the runtime verifier**

```bash
git add filter_plugins/container_cpu.py tests/container_cpu_filter_test.py roles/container_cpu
git commit -m "feat: verify effective container CPU controls"
```

### Task 5: Verify every deployed Compose project

**Files:**
- Modify: `tests/policy_test.rb`
- Modify: `roles/audiobookshelf/tasks/main.yml`
- Modify: `roles/beszel/tasks/main.yml`
- Modify: `roles/dozzle/tasks/main.yml`
- Modify: `roles/immich/tasks/main.yml`
- Modify: `roles/jellyfin/tasks/main.yml`
- Modify: `roles/komga/tasks/main.yml`
- Modify: `roles/ntfy/tasks/main.yml`
- Modify: `roles/paperless_ngx/tasks/main.yml`
- Modify: `roles/tinymediamanager/tasks/main.yml`

- [ ] **Step 1: Add a failing policy requirement for runtime verification**

In the implemented-role loop in `tests/policy_test.rb`, require one reusable
role inclusion and exact service-name input:

```ruby
check(failures,
      tasks_owned && File.read(tasks_path).scan(/name:\s*container_cpu\b/).length == 1 &&
        File.read(tasks_path).include?("container_cpu_service_name: #{name}"),
      "#{name}: role must verify its effective container CPU policy exactly once")
```

Run `ruby tests/policy_test.rb` and expect nine missing-verifier failures.

- [ ] **Step 2: Include verification after each final Compose deployment**

Immediately after the final `community.docker.docker_compose_v2` deployment in
each service role, add this block, substituting the existing project-name
variable shown below:

```yaml
- name: Verify SERVICE effective container CPU policy
  ansible.builtin.include_role:
    name: container_cpu
  vars:
    container_cpu_service_name: SERVICE
    container_cpu_project_name: "{{ PROJECT_VARIABLE }}"
  when: not ansible_check_mode
```

Use these exact substitutions:

| `SERVICE` | `PROJECT_VARIABLE` |
| --- | --- |
| `audiobookshelf` | `audiobookshelf_compose_project_name` |
| `beszel` | `beszel_compose_project_name` |
| `dozzle` | `dozzle_compose_project_name` |
| `immich` | `immich_compose_project_name` |
| `jellyfin` | `jellyfin_compose_project_name` |
| `komga` | `komga_compose_project_name` |
| `ntfy` | `ntfy_compose_project_name` |
| `paperless-ngx` | `paperless_compose_project_name` |
| `tinymediamanager` | `tinymediamanager_compose_project_name` |

For Paperless, insert after the full five-service deployment, not after the
initial broker/database deployment. For Beszel, insert after the selected hub,
proxy, and agent deployment. The role intentionally verifies only running
containers, so the inactive Beszel agent variant remains absent.

- [ ] **Step 3: Run policy, syntax, and service contract validation**

Run:

```bash
ruby tests/policy_test.rb
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ruby tests/run_contracts.rb --validate-only
```

Expected: all commands exit zero.

- [ ] **Step 4: Commit runtime verification wiring**

```bash
git add roles/*/tasks/main.yml tests/policy_test.rb
git commit -m "feat: enforce runtime CPU policy after deployment"
```

### Task 6: Document operations and run the complete verification ladder

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add operator-facing CPU policy documentation**

Add a `Container CPU policy` subsection under `## Design` in `README.md`:

````markdown
### Container CPU policy

Production containers are restricted to logical CPUs `0-2` on the four-core
AS6704T, leaving one logical CPU free of container processes. Every Compose
service also has a workload-specific hard ceiling between 0.5 and 3.0 CPUs.
Compute-heavy services may use the full three-CPU container set when it is idle;
lighter services cannot monopolize it. Docker's default equal CPU shares remain
unchanged.

Ansible derives and validates the effective CPU set before deployment, then
checks Docker's applied CPU set and quota after each stack starts. Inspect one
container manually with:

```sh
docker inspect --format '{{json .HostConfig}}' immich_server
```

Change the production budget only through
`inventory/group_vars/nas_hosts/main.yml`; the next Ansible run recreates and
verifies affected containers.
````

- [ ] **Step 2: Run formatting and focused tests**

Run:

```bash
git diff --check
ruby tests/policy_test.rb
ansible_python=$(ansible-playbook --version | sed -n 's/^  python version = .* (\(\/[^()]*\))$/\1/p')
PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/container_cpu_filter_test.py
ansible-playbook -i inventory/local.yml site.yml --syntax-check
```

Expected: no whitespace errors; policy and filter tests pass; syntax check ends
with `failed=0`.

- [ ] **Step 3: Run the repository policy gate**

Run outside restricted socket sandboxes because several existing tests bind
ephemeral localhost ports:

```bash
tests/validate-policy.sh
```

Expected: exit 0, including `policy: all properties hold`, `Container CPU-set
derivation behavior passed`, and all existing service contracts.

- [ ] **Step 4: Run affected integration suites**

Run:

```bash
tests/integration.sh --suite full site.yml
```

Expected: the full suite converges every stack, reconverges with no changes, and
completes its check-mode pass. The runtime verifier must accept Docker's
effective `CpusetCpus` and `NanoCpus` in every deployed project.

- [ ] **Step 5: Inspect the final change set**

Run:

```bash
git status --short
git diff --stat main...HEAD
git diff --check main...HEAD
```

Expected: only the planned CPU-policy, test, and documentation files differ;
there are no whitespace errors or unrelated changes.

- [ ] **Step 6: Commit documentation and any evidence-driven corrections**

```bash
git add README.md
git commit -m "docs: explain container CPU policy"
```

If a verification command required a correction to a Task 1-5 file, stage that
specific file with `README.md` and describe the correction in the commit body.
