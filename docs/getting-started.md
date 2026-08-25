# Getting started with NAS platform

This is the starting point if Ansible is new to you. You do not need to learn
Ansible before using this repository; learn the few project concepts in
[Ansible basics](ansible-basics.md) as you encounter them.

## Before running anything

This repository manages service configuration and containers. It does **not**
back up photos, media, databases, or other application data. Back up the NAS
and confirm that the backup can be restored before a production migration.

The eight active services are ntfy, Beszel, Dozzle, Audiobookshelf, Komga,
Jellyfin, Immich, and Paperless-ngx. The production retirement checkpoint has
passed and the former metadata manager's repository declarations are gone; its
preserved application state remains outside repository management and was not
deleted. The authoritative status is
[`services/manifest.yml`](../services/manifest.yml).

Phase 0 is an inert media-acquisition foundation. It creates the derived
`media-control` bridge network and the classified acquisition/final directory
tree, extends generated-vault and immutable validation contracts, and adds CI
scaffolding. All seven acquisition projects remain `planned`, both acquisition
enablement flags are literal `false`, and no acquisition container or download
is started. Jellyfin keeps Open Subtitles until Bazarr is proven in Phase 1.

The two supported routes are deliberately separate:

- [`inventory/mac.yml`](../inventory/mac.yml) proves the reusable deployment
  locally with Docker Desktop. It does not contact the physical NAS. Its
  application data is disposable, but it can use the same application
  identities and credentials as the NAS.
- [`inventory/remote.yml`](../inventory/remote.yml) connects to the physical
  NAS over SSH and can change production. Use it only after the Mac proof and
  after reading the production walkthrough.

## Four terms you need first

- **Controller:** the Mac or workstation where you run `ansible-playbook`.
- **Managed host:** the machine Ansible configures: either the local Mac or the
  physical NAS.
- **Inventory:** the file that tells Ansible which managed host to use.
- **Playbook:** an ordered description of the desired system. `site.yml`
  converges the platform; `verify.yml` only verifies it.

The [concepts guide](ansible-basics.md) explains the rest with examples from
this repository.

## Install the shared tools

Run these commands from the repository root on your Mac or workstation. Python
virtual environments keep the pinned Ansible version isolated from the rest of
your computer.

```sh
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install 'ansible-core==2.21.2' 'ansible-lint==26.6.0'
ansible-galaxy collection install -r requirements.yml
ansible-playbook --version
docker compose version
```

Success means both final commands print versions. Activate the environment
again with `. .venv/bin/activate` in each new terminal. See the official
[Ansible installation guide](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html),
[Python `venv` guide](https://docs.python.org/3/library/venv.html), and
[Docker Compose installation guide](https://docs.docker.com/compose/install/)
if a prerequisite is missing.

## Choose your walkthrough

### Prove it safely on a Mac

Follow the [disposable Mac walkthrough](getting-started-mac.md). It creates an
isolated Docker Desktop deployment, verifies alert wiring to its own ntfy
instance, tests convergence and recovery, and emits a sanitized report. It
never copies production application data and never contacts the NAS.

### Prepare the physical NAS

Follow the [physical NAS walkthrough](getting-started-nas.md). It explains SSH,
the production inventory, backups, check mode, the apply step, verification,
and the boundary around rollback. Do not start a production cutover while a
required service is still marked `planned`.

## Secrets: one portable contract

[`inventory/group_vars/all/vault.yml.example`](../inventory/group_vars/all/vault.yml.example)
is the exact credential schema for both environments. To recover an existing
deployment, use the current NAS values from your password manager and the
deployed configuration. This is what preserves existing logins and integrations.
Do not run the brand-new secret generator for a recovery.

For the Paperless Gmail app password, you may paste Google's four
space-separated groups into the vault. Provisioning removes those display
spaces before sending the credential to Paperless.

Never commit a plaintext vault, vault password, rendered `.env` file, private
key, token, or application data. An encrypted vault begins with
`$ANSIBLE_VAULT;` and may be committed; its password must stay outside this
repository in a password manager or a mode-`0600` file.

## Reading a run

Ansible prints the name of each task and ends with a `PLAY RECAP`. For each
host:

- `ok` means the desired state was already present or was checked successfully;
- `changed` means Ansible changed something, or predicts a change in check mode;
- `failed=0` and `unreachable=0` are required for success;
- `changed=0` on the second complete run proves idempotence.

On failure, start with the first red `FAILED` task, not the final recap. Read
its message, fix only that cause, and rerun the same command. The Mac harness
records completed phases and prints a validated cleanup command when it
preserves a failed sandbox. The NAS guide tells you when to stop rather than
attempt an unsafe repair.
