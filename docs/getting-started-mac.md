# Disposable Mac proof

This walkthrough runs the platform in an isolated Docker Desktop sandbox on
your Mac. It does not SSH to or otherwise contact the physical NAS. Service
data is disposable; credentials may deliberately match the NAS so that reused
logins, ntfy tokens, Beszel keys, and future integrations are proven portable.

This proof covers all nine implemented services in
[`services/manifest.yml`](../services/manifest.yml): Audiobookshelf, Beszel,
Dozzle, Immich, Jellyfin, Komga, ntfy, Paperless-ngx, and tinyMediaManager. It
sends test alerts to the sandbox's own ntfy instance. Mobile delivery is
outside scope.

## 1. Install and verify prerequisites

Install [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/)
and start it. From the repository root, install the pinned Ansible tools:

```sh
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install 'ansible-core==2.21.2' 'ansible-lint==26.6.0'
ansible-galaxy collection install -r requirements.yml
docker version
docker compose version
ansible-playbook --version
```

Stop if any command fails. Docker must be running, and `ansible-playbook` must
report Core 2.21.2.

## 2. Prepare the external vault

The proof commands below consume these two protected inputs outside the
checkout:

- `$HOME/.config/nas-platform/vault-password`
- `$HOME/.config/nas-platform/vault.yml`

The canonical guide is the sole owner of creating the protected directory,
password input, and encrypted vault. Read the
[secrets and encrypted-vault guide](secrets.md), following it from
[Prepare protected external files](secrets.md#prepare-protected-external-files)
through the
[Preparation and validation handoff](secrets.md#preparation-and-validation-handoff),
then return here for step 3.

Generate the vault password in your password manager and back it up there. Do
not pass it as a command argument or paste it into shell history. A
password-manager-backed executable is preferable to a plaintext password file
for unattended long-term use.

Do **not** use `generate-secrets.yml` for migration: it is only for a brand-new
platform and would break the requirement that current NAS credentials continue
to work. After review, the external ciphertext may become the NAS vault; never
commit its password or a plaintext vault.

## 3. Run the complete fresh proof

From the repository root:

```sh
tests/mac/run.sh \
  --lane fresh \
  --vault-file "$HOME/.config/nas-platform/vault.yml" \
  --vault-password-file "$HOME/.config/nas-platform/vault-password"
```

The harness creates unique paths and ports, then runs these phases in order:
`preflight`, `deploy`, `seed`, `verify`, `idempotence`, `drift`, `reconcile`,
`recreate`, `persistence`, `report`, and `cleanup`.

Success means all phases pass, the idempotence phase reports `changed=0`, and
cleanup removes the service-data sandbox. The sibling `.reports` directory is
retained and contains `report.md` and `report.json`; the harness prints its
absolute path. Reports are sanitized and contain no application log bodies.

## 4. Perform the manual review

The complete run above proves the automated lifecycle and cleans its containers.
For a manual review, start a second proof one phase at a time. Run `preflight`
first:

```sh
tests/mac/run.sh \
  --lane fresh \
  --vault-file "$HOME/.config/nas-platform/vault.yml" \
  --vault-password-file "$HOME/.config/nas-platform/vault-password" \
  --phase preflight
```

The command prints `Sandbox preserved at ...`. Copy that absolute path into the
next command, then run through `persistence`:

```sh
export PLATFORM_MAC_SANDBOX=/absolute/path/printed-by-preflight
for phase in deploy seed verify idempotence drift reconcile recreate persistence; do
  tests/mac/run.sh \
    --lane fresh \
    --vault-file "$HOME/.config/nas-platform/vault.yml" \
    --vault-password-file "$HOME/.config/nas-platform/vault-password" \
    --sandbox "$PLATFORM_MAC_SANDBOX" \
    --phase "$phase" || break
done
```

Use [`tests/mac/manual-review.md`](../tests/mac/manual-review.md) while all nine
services are running. Record the reviewer, manifest commit, decision, and
non-secret notes. Credential continuity requires a private check for every
service:

- Audiobookshelf, Jellyfin, and Komga: sign in with each deployed administrator
  identity and confirm the disposable libraries remain usable after recreation.
- Beszel: sign in with both deployed hub identities, confirm the existing agent
  key and token connect the disposable agent, and send only a disposable ntfy
  event.
- Dozzle: sign in with the deployed administrator password represented by the
  installed hash, inspect its managed event rules, and send only a disposable
  ntfy event.
- Immich: sign in with the deployed administrator identity and confirm the
  existing database identity retains the disposable assets after recreation.
- ntfy: confirm the deployed administrator login, anonymous denial, and the
  existing distinct Beszel and Dozzle tokens using disposable messages.
- Paperless-ngx: sign in with the deployed administrator identity, confirm its
  database-backed fixtures survive recreation, and inspect the existing Gmail
  account and mail rule without fetching mail.
- tinyMediaManager: confirm the deployed API password still authorizes the
  client and that disposable settings persist after recreation.

After the review, produce the report and clean only the validated sandbox:

```sh
tests/mac/run.sh \
  --lane fresh \
  --vault-file "$HOME/.config/nas-platform/vault.yml" \
  --vault-password-file "$HOME/.config/nas-platform/vault-password" \
  --sandbox "$PLATFORM_MAC_SANDBOX" \
  --phase report
tests/mac/run.sh \
  --lane fresh \
  --vault-file "$HOME/.config/nas-platform/vault.yml" \
  --vault-password-file "$HOME/.config/nas-platform/vault-password" \
  --sandbox "$PLATFORM_MAC_SANDBOX" \
  --phase cleanup
```

## 5. Resume or clean a failed proof

Failures preserve the sandbox and print exactly one validated `Cleanup command`.
Copy that exact command when you are finished inspecting it. Do not replace it
with `rm -rf` or edit the path.

To resume, use the same Git revision, lane, vault, password input, and absolute
sandbox path printed by the failed run. With no `--phase`, the harness starts
at the first incomplete phase:

```sh
tests/mac/run.sh \
  --lane fresh \
  --vault-file "$HOME/.config/nas-platform/vault.yml" \
  --vault-password-file "$HOME/.config/nas-platform/vault-password" \
  --sandbox /absolute/path/printed-by-the-failed-run
```

Passed phases are skipped. A changed vault or Git revision is intentionally
rejected so evidence from different deployments cannot be mixed.

## What this does not prove

Docker Desktop cannot prove NAS GPU access, host networking, ADM Defender,
native NAS mounts, Tailscale behavior, production-scale performance, mobile
push, or a full NAS outage. It also does not consume Gmail or copy production
media/application data. These boundaries are recorded in the manual review.
