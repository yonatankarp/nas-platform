# Disposable Mac proof

This walkthrough runs the platform in an isolated Docker Desktop sandbox on
your Mac. It does not SSH to or otherwise contact the physical NAS. Service
data is disposable; credentials may deliberately match the NAS so that reused
logins, ntfy tokens, Beszel keys, and future integrations are proven portable.

Today this proof covers ntfy, Beszel, Dozzle, and Audiobookshelf. It sends test
alerts to the sandbox's own ntfy instance. Mobile delivery is outside scope.
Services marked `planned` in [`services/manifest.yml`](../services/manifest.yml)
cannot yet be manually accepted on the Mac.

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

## 2. Create the external password input

Keep both proof inputs outside the checkout. The following uses a protected
plaintext vault-password file for the first proof. A password-manager-backed
executable is preferable for unattended long-term use.

```sh
mkdir -p "$HOME/.config/nas-platform"
chmod 700 "$HOME/.config/nas-platform"
umask 077
${EDITOR:-vi} "$HOME/.config/nas-platform/vault-password"
chmod 600 "$HOME/.config/nas-platform/vault-password"
```

Enter one strong password on one line. Do not pass it as a command argument or
paste it into shell history. Back it up in your password manager.

## 3. Author the portable vault

Open
[`inventory/group_vars/all/vault.yml.example`](../inventory/group_vars/all/vault.yml.example)
in a second window. Then create an encrypted file directly:

```sh
ansible-vault create \
  --vault-password-file "$HOME/.config/nas-platform/vault-password" \
  "$HOME/.config/nas-platform/vault.yml"
```

Your editor opens inside `ansible-vault`. Copy every key from the example and
replace every example value with its exact current NAS value from your password
manager and Portainer definitions. Preserve hashes, tokens, database passwords,
the Beszel keypair, application identities, and Gmail fields exactly. Saving and
closing writes ciphertext, not plaintext.

Do **not** use `generate-secrets.yml`: it is for a brand-new platform and would
break the requirement that current NAS credentials continue to work. Confirm
encryption without displaying secrets:

```sh
head -n 1 "$HOME/.config/nas-platform/vault.yml"
```

Success starts with `$ANSIBLE_VAULT;`. Never commit the vault password or any
plaintext vault. The encrypted external file may later become the NAS vault
after review.

## 4. Run the complete fresh proof

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

## 5. Perform the manual review

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

Use [`tests/mac/manual-review.md`](../tests/mac/manual-review.md) while those
services are running. Record the reviewer, manifest commit, decision, and
non-secret notes. Only implemented services can pass today; leave planned
services explicitly unproved rather than marking them successful.

For the current services, confirm existing credentials log in, Audiobookshelf
use works after recreation, Beszel and Dozzle are configured, authentication is
enforced, and disposable alerts arrive in this deployment's ntfy client.

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

## 6. Resume or clean a failed proof

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
