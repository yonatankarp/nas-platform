# Ansible concepts used by this repository

This is a project map, not a general Ansible course. Each concept points to the
place where it is used here and to the corresponding official documentation.

## Controller and managed host

The **controller** runs Ansible. The **managed host** receives the changes.
With [`inventory/remote.yml`](../inventory/remote.yml), your workstation is the
controller and the NAS is the managed host over SSH. With
[`inventory/mac.yml`](../inventory/mac.yml), the Mac is both. Ansible itself
does not need to run in a container. See
[managed nodes and control nodes](https://docs.ansible.com/ansible/latest/network/getting_started/basic_concepts.html).

## Inventory and group variables

An **inventory** defines hosts, groups, connection type, and coordinates. This
project has `local.yml`, `remote.yml`, and `mac.yml` inventories. Values shared
by every platform live in
[`inventory/group_vars/all/main.yml`](../inventory/group_vars/all/main.yml),
while machine capabilities live under `nas_hosts` or `mac_hosts`. See
[How to build your inventory](https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html)
and [Using variables](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_variables.html).

## Playbooks, plays, and tasks

A **playbook** is a YAML file containing plays. A **play** targets a host group
and runs ordered **tasks** and roles. [`site.yml`](../site.yml) targets
`platform_hosts`; [`verify.yml`](../verify.yml) runs verification without
converging the deployment. See
[Intro to playbooks](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_intro.html).

## Roles

A **role** groups tasks, templates, defaults, handlers, and validation for one
responsibility. For example, [`roles/ntfy`](../roles/ntfy) owns the ntfy
configuration and [`roles/preflight`](../roles/preflight) rejects unsafe host
assumptions before deployment. `site.yml` calls roles in dependency order. See
[Roles](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html).

## Modules and collections

A **module** is one operation, such as `ansible.builtin.file` or
`community.docker.docker_compose_v2`. Built-in modules ship with Ansible Core.
A **collection** packages additional modules and roles; `requirements.yml` pins
`community.docker` for reproducible Compose behavior. See the
[module index](https://docs.ansible.com/ansible/latest/collections/index_module.html)
and [collection guide](https://docs.ansible.com/ansible/latest/collections_guide/index.html).

## Variables, templates, facts, and registered values

**Variables** make one definition reusable on several machines. A Jinja
**template** renders those variables into a concrete file, such as a Compose
environment file. **Facts** are properties Ansible discovers about a host.
A task can **register** its result under a variable for a later task to inspect.
See [variables](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_variables.html),
[the template module](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/template_module.html),
[facts](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_vars_facts.html),
and [registered variables](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_conditionals.html#registering-variables).

## Handlers and idempotence

A **handler** runs only when a task reports a relevant change, commonly to
restart a service after configuration changes. **Idempotence** means that once
the declared state exists, another run makes no changes. The Mac harness and
integration test require a second run with `changed=0`. See
[handlers](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_handlers.html)
and [Ansible concepts](https://docs.ansible.com/ansible/latest/getting_started/basic_concepts.html#desired-state-and-idempotency).

## Check mode, diff mode, and tags

`--check` asks modules to predict changes without applying them. `--diff` shows
safe before/after detail for supported files. Check mode is a required review,
not a guarantee that every external system can simulate perfectly.

**Tags** select part of a playbook. For example, `site.yml` tags the preflight
role `preflight`, but its `always` safety tasks still run when other tags are
selected. See [check and diff mode](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_checkmode.html)
and [tags](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_tags.html).

## Ansible Vault

**Ansible Vault** encrypts YAML at rest. The encrypted
`inventory/group_vars/all/vault.yml` can be loaded directly by a play; it does
not need to be decrypted onto disk. `--ask-vault-pass` prompts interactively,
while `--vault-password-file` can read a protected file or an executable that
prints the password. Vault protects only stored files; output and rendered
files still need `no_log` and strict permissions. See
[Protecting sensitive data with Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html).

## Reading failures and the recap

Ansible stops a host at the first unhandled failure and prints the task name,
module message, and a final recap. `unreachable` usually means SSH, DNS, or
authentication failed before tasks ran. `failed` means a task ran but could not
meet its contract. `changed` is not an error. Increase diagnostic detail with
`-v`, then `-vv`, but do not publish verbose output until you have checked it
for secrets. See
[controlling output verbosity](https://docs.ansible.com/ansible/latest/reference_appendices/logging.html)
and [error handling](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_error_handling.html).
