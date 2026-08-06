# Beginner documentation design

## Goal

Make `nas-platform` usable by an operator who knows almost nothing about
Ansible, without requiring them to infer setup, safety, or recovery steps from
roles and playbooks.

The repository documentation is authoritative. A future GitHub Wiki may provide
navigation and background material, but it must link to the versioned guides
rather than duplicate commands that can drift from the code.

## Audience and assumptions

The primary reader understands basic terminal use but may not know Ansible,
inventories, playbooks, roles, idempotence, check mode, collections, or Ansible
Vault. The guides explain every project-specific command, what it changes, what
success looks like, and how to stop or recover safely.

The two supported entry paths have equal status:

1. Prove the platform in a disposable Docker Desktop sandbox on macOS.
2. Prepare and deploy the physical NAS.

Neither guide silently crosses into the other environment. Mac commands must
not contact the NAS, and NAS commands must clearly identify production-impacting
steps.

## Documentation structure

### Root README

Keep the architecture overview concise and add a prominent **New to Ansible?**
section linking to the beginner landing page. Existing quick commands remain a
reference for experienced operators, not the beginner tutorial.

### `docs/getting-started.md`

Act as the beginner landing page. It will:

- explain what the repository manages and does not back up;
- define the minimum terminology needed to choose a path;
- list shared prerequisites and safety rules;
- present the Mac and NAS walkthroughs as equal choices;
- link to the concepts guide and official documentation;
- explain where to resume after a failure.

### `docs/getting-started-mac.md`

Provide a complete copy-paste walkthrough for the disposable Mac proof:

- install and verify Docker Desktop, Python, Ansible, and collections;
- create an encrypted disposable credential vault without printing secrets;
- run preflight and the full ordered lifecycle;
- find and interpret the sanitized report;
- perform the manual application review;
- clean or resume a failed owned sandbox safely;
- describe what the Mac proof does and does not prove about the NAS.

### `docs/getting-started-nas.md`

Provide a complete production walkthrough:

- prepare Docker, Python, SSH access, NAS paths, and connection variables;
- create, review, and encrypt the exact vault contract;
- validate connectivity and preflight assumptions;
- run `--check --diff` before applying;
- deploy and run verification;
- explain idempotence, expected changes, recovery, rollback, and when to stop;
- state clearly that application data and the vault password require separate
  backups.

Commands that can change the NAS receive an explicit production warning.

### `docs/ansible-basics.md`

Explain only concepts used by this repository:

- controller and managed host;
- inventory and group variables;
- playbooks, plays, tasks, roles, and tags;
- modules and collections;
- variables, templates, registered results, and facts;
- handlers and idempotence;
- check mode and diff mode;
- Ansible Vault and vault password files;
- how to read a recap and locate the failing task.

Each concept includes a small example from this repository and a link to the
corresponding official Ansible documentation. Docker prerequisites link to
official Docker documentation. External links are supplementary; the operator
can still complete the workflow using the repository guides alone.

## Safety and secret handling

The guides must never instruct the reader to paste credentials into shell
history, commit plaintext vault data, copy production data to the Mac, or use a
broad destructive cleanup command. Examples use placeholders and existing safe
helpers. Cleanup commands operate only on validated, owned sandboxes.

The NAS guide distinguishes read-only validation, check mode, deployment, and
recovery. The Mac guide distinguishes disposable application data from the real
credential schema used to prove reusable behavior.

## Verification

Documentation verification will include:

- checking every referenced repository path and executable command exists;
- checking inventory names and environment variables against current code;
- checking shell examples for syntax where practical;
- checking all external links point to official project documentation;
- scanning for placeholder secrets, stale service claims, and contradictions;
- confirming the README links reach every beginner guide.

## Wiki policy

The GitHub Wiki is optional and deferred until the migration is complete. If
created, it should contain a short landing page and conceptual navigation, with
links to the repository guides on `main`. Version-sensitive commands, inventory
names, and recovery procedures remain only in the repository.

