# Secrets Starter Guide Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `docs/secrets.md` into a from-scratch setup guide with exact generation commands, an existing-deployment recovery branch, an add-secret workflow, and workstation and NAS-local invocation paths.

**Architecture:** Keep `docs/secrets.md` as the canonical operator guide and retain its exact vault-key inventory. Extend the Ruby documentation contract before changing prose, then satisfy it with a linear fresh-platform workflow and reference sections. Include the encrypted repository vault only after header, permission, and redacted contract validation pass.

**Tech Stack:** Markdown, Ruby policy tests, Ansible Vault, pinned `ansible-core==2.21.2`, Docker Compose, POSIX shell, OpenSSL, OpenSSH

---

## File Structure

- Modify `tests/secrets_docs_test.rb`: enforce the starter, recipe, add-secret,
  controller, and safety sections without reading decrypted values.
- Modify `docs/secrets.md`: own the complete secrets lifecycle.
- Add `inventory/group_vars/all/vault.yml`: include only the already encrypted
  operator vault; the password remains outside the repository.

### Task 1: Extend the documentation contract first

**Files:**
- Modify: `tests/secrets_docs_test.rb`
- Test: `tests/secrets_docs_test.rb`

- [ ] **Step 1: Add structural and command assertions**

After the existing link checks, add:

```ruby
required_sections = [
  "## Start here: choose fresh or migration",
  "## Brand-new platform starter",
  "## Individual secret recipes",
  "## Existing deployment recovery",
  "## Add a new secret",
  "## Use the vault",
  "### Workstation controller",
  "### NAS-local controller"
]

required_sections.each do |heading|
  check(failures, secrets_guide.include?(heading),
        "canonical secrets guide must include #{heading}")
end

required_commands = [
  "python3 -m venv .venv",
  "openssl rand -base64 48",
  "ansible-playbook generate-secrets.yml -e generate_brand_new_platform=true",
  "user hash",
  "token generate",
  "ssh-keygen",
  "ansible-vault encrypt",
  "ansible-vault edit",
  "inventory/remote.yml",
  "inventory/local.yml",
  "--ask-vault-pass"
]

required_commands.each do |command|
  check(failures, secrets_guide.include?(command),
        "canonical secrets guide must document #{command}")
end

append_contract_paths = [
  "inventory/group_vars/all/vault.yml.example",
  "roles/vault_contract/meta/argument_specs.yml",
  "roles/vault_contract/tasks/main.yml",
  "templates/vault-plain.yml.j2",
  "tests/generate-ephemeral-vault.sh"
]

append_contract_paths.each do |path|
  check(failures, secrets_guide.include?(path),
        "add-secret workflow must identify #{path}")
end

[
  "do not run the generator",
  "no separate Beszel agent API secret",
  "permanent",
  "outside the repository",
  "Never decrypt a vault onto disk"
].each do |phrase|
  check(failures, secrets_guide.include?(phrase),
        "canonical secrets guide must include safety rule: #{phrase}")
end
```

Keep the existing exact-once backticked vault-key comparison unchanged.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```sh
ruby tests/secrets_docs_test.rb
```

Expected: nonzero exit for missing new headings and commands, while the
existing vault schema comparison remains valid.

### Task 2: Write the from-scratch starter

**Files:**
- Modify: `docs/secrets.md`
- Test: `tests/secrets_docs_test.rb`

- [ ] **Step 1: Add the starting-condition gate**

Open with `## Start here: choose fresh or migration`. Define a new platform as
having no deployed users, databases, agents, tokens, keys, or integrations. If
any exist, point to `## Existing deployment recovery` and state “do not run
the generator.” Keep every backticked `vault_*` key in the canonical inventory
exactly once.

- [ ] **Step 2: Add project setup using the repository venv**

```sh
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
. .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install 'ansible-core==2.21.2' 'ansible-lint==26.6.0'
ansible-galaxy collection install -r requirements.yml
ansible-playbook --version
```

Explain that `.venv` is the project operator environment; `pipx` is not
required for this workflow.

- [ ] **Step 3: Add guarded Vault-password generation**

```sh
export PLATFORM_VAULT_DIR="$HOME/.config/nas-platform"
export PLATFORM_VAULT_FILE="$PLATFORM_VAULT_DIR/vault.yml"
export PLATFORM_VAULT_PASSWORD_FILE="$PLATFORM_VAULT_DIR/vault-password"

umask 077
mkdir -p "$PLATFORM_VAULT_DIR"
chmod 700 "$PLATFORM_VAULT_DIR"

if [ -e "$PLATFORM_VAULT_PASSWORD_FILE" ]; then
  printf 'STOP: vault password already exists: %s\n' \
    "$PLATFORM_VAULT_PASSWORD_FILE" >&2
else
  openssl rand -base64 48 > "$PLATFORM_VAULT_PASSWORD_FILE"
  chmod 600 "$PLATFORM_VAULT_PASSWORD_FILE"
fi
```

Call this a password rather than an SSH key. Require a password-manager backup
before it protects the only vault copy, and forbid rerunning it over an existing
password.

- [ ] **Step 4: Generate and immediately encrypt the complete vault**

Retain overwrite guards, then use the canonical invocation:

```sh
ansible-playbook generate-secrets.yml -e generate_brand_new_platform=true
```

Immediately protect the generated plaintext:

```sh
if [ -e "$PLATFORM_VAULT_FILE" ]; then
  printf 'STOP: encrypted external vault already exists: %s\n' \
    "$PLATFORM_VAULT_FILE" >&2
elif [ ! -f inventory/group_vars/all/vault-plain.yml ]; then
  printf 'STOP: generated plaintext vault is unavailable\n' >&2
else
  mv inventory/group_vars/all/vault-plain.yml "$PLATFORM_VAULT_FILE"
  chmod 600 "$PLATFORM_VAULT_FILE"
  ansible-vault encrypt \
    --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
    "$PLATFORM_VAULT_FILE"
fi
```

- [ ] **Step 5: Add encrypted review, quoting, and validation**

Use `ansible-vault edit` for identity and integration review. Require
single-quoted text scalars, doubled apostrophes, literal bcrypt dollar signs,
and an indented `|` block for the OpenSSH private key. Retain header, mode,
ciphertext checksum, redacted `validate-vault.yml`, backup, Mac proof, and
repository-install gates. Keep “Never decrypt a vault onto disk.”

### Task 3: Add individual value recipes and migration sources

**Files:**
- Modify: `docs/secrets.md`
- Test: `tests/secrets_docs_test.rb`

- [ ] **Step 1: Document matching password/hash pairs**

Resolve the pinned image from Compose and invoke ntfy's own hasher:

```sh
platform_ntfy_image=$(
  docker compose -f services/ntfy/compose.yml config --images
)
docker run --rm -it "$platform_ntfy_image" user hash
unset platform_ntfy_image
```

Explain that ntfy declarative users and Dozzle's users file consume bcrypt
hashes, while clear administrator passwords remain necessary for login and
verification. Run once per pair and never replace only one side of a deployed
pair.

- [ ] **Step 2: Document ntfy tokens**

```sh
platform_ntfy_image=$(
  docker compose -f services/ntfy/compose.yml config --images
)
docker run --rm "$platform_ntfy_image" token generate
unset platform_ntfy_image
```

Generate separate Dozzle and Beszel tokens for a new platform and transfer each
directly into the encrypted editor. Existing deployments recover them.

- [ ] **Step 3: Document Beszel token and keypair material**

State that the current contract has two hub users, a permanent universal token,
the agent's two-field public key, and the matching hub private key. There is no
separate Beszel agent API secret. Generate a new pair only for a new platform:

```sh
umask 077
platform_beszel_key_dir=$(mktemp -d)
ssh-keygen -t ed25519 -N '' -C 'beszel hub' \
  -f "$platform_beszel_key_dir/id_ed25519"
```

Never print the private key. For migration, locate its protected source:

```sh
sudo docker inspect beszel \
  --format '{{range .Mounts}}{{println .Type .Name .Source "->" .Destination}}{{end}}'
```

Explain that the source mounted at `/beszel_data` owns `id_ed25519`; the
observed source was `/volume1/Docker/beszel/hub`. Choose permanent, not
ephemeral, persistence for a stable Ansible-managed universal token.

- [ ] **Step 4: Document Paperless material**

Explain that the Django signing value becomes `PAPERLESS_SECRET_KEY`, is not a
login password, and may be generated for a fresh service with:

```sh
openssl rand -base64 48
```

Existing Paperless must recover its current value. Define mail account and rule
names as stable UI labels, the Gmail address as identity, and the Google app
password as the credential.

- [ ] **Step 5: Move existing authoritative sources into recovery**

Under `## Existing deployment recovery`, retain the service-by-service sources
and the rule that deployed users, databases, hashes, tokens, and keypairs are
copied exactly. A missing or ambiguous source remains a stop condition.

### Task 4: Add new-secret and controller workflows

**Files:**
- Modify: `docs/secrets.md`
- Test: `tests/secrets_docs_test.rb`

- [ ] **Step 1: Add the schema-first add-secret checklist**

Under `## Add a new secret`, explain that ciphertext alone is insufficient.
List these change surfaces:

```text
inventory/group_vars/all/vault.yml.example
roles/vault_contract/meta/argument_specs.yml
roles/vault_contract/tasks/main.yml
the consuming role's meta/argument_specs.yml, templates, and tasks
generate-secrets.yml
templates/vault-plain.yml.j2
tests/generate-ephemeral-vault.sh
service contract and policy tests
docs/secrets.md
```

Then append the real value only through:

```sh
ansible-vault edit \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  inventory/group_vars/all/vault.yml
```

Run redacted validation and `tests/validate-policy.sh` afterward.

- [ ] **Step 2: Add workstation-controller commands**

```sh
export PLATFORM_NAS_ADDRESS=nas.example.internal
export PLATFORM_NAS_USER=nasadmin
ansible-playbook -i inventory/remote.yml site.yml \
  --check --diff \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
```

Explain that the workstation decrypts and the NAS does not need the password
file. Show apply only after check-mode review.

- [ ] **Step 3: Add NAS-local commands**

```sh
export PLATFORM_NAS_ADDRESS=nas.example.internal
ansible-playbook -i inventory/local.yml site.yml \
  --check --diff --ask-vault-pass
```

Recommend interactive input. For unattended runs, permit only a mode-`0600`
file or executable password-manager provider outside the repository, and state
that the NAS account and root can then decrypt the vault.

- [ ] **Step 4: Run focused GREEN verification**

```sh
ruby tests/secrets_docs_test.rb
```

Expected: `secrets docs: canonical guide and vault schema agree`.

### Task 5: Validate and commit the guide, test, and encrypted vault together

**Files:**
- Add: `inventory/group_vars/all/vault.yml`
- Modify: `docs/secrets.md`
- Modify: `tests/secrets_docs_test.rb`

- [ ] **Step 1: Verify safe vault metadata**

```sh
vault_file=inventory/group_vars/all/vault.yml
IFS= read -r vault_header < "$vault_file"
case "$vault_header" in
  '$ANSIBLE_VAULT;'*) printf 'header=encrypted\n' ;;
  *) printf 'STOP: vault is not encrypted\n' >&2; exit 1 ;;
esac
unset vault_header
ls -l "$vault_file"
```

Expected: encrypted header and mode `-rw-------`.

- [ ] **Step 2: Run redacted vault validation**

```sh
.venv/bin/ansible-playbook validate-vault.yml \
  --vault-password-file "$HOME/.config/nas-platform/vault-password" \
  -e @inventory/group_vars/all/vault.yml \
  -e "platform_vault_file=inventory/group_vars/all/vault.yml"
```

Expected: `failed=0` and no decrypted value in output.

- [ ] **Step 3: Run full policy and syntax verification**

```sh
tests/validate-policy.sh
find tests -type f -name '*.sh' -exec sh -n {} +
git diff --check
```

Expected: policy and secrets-doc contracts pass; every command exits zero.

- [ ] **Step 4: Stage and inspect the exact implementation set**

```sh
git add docs/secrets.md \
  tests/secrets_docs_test.rb \
  inventory/group_vars/all/vault.yml
git diff --cached --stat
git diff --cached --check
```

Confirm the password file is absent. Do not print the encrypted blob in a full
diff; its ciphertext is safe but provides no useful review signal.

- [ ] **Step 5: Commit without co-author metadata**

```sh
git commit -m "docs: expand secrets starter workflow"
```

- [ ] **Step 6: Verify the committed result**

```sh
git status --short --branch
git show --stat --oneline HEAD
ruby tests/secrets_docs_test.rb
tests/validate-policy.sh
```

Expected: clean tree, exactly the three intended files in the implementation
commit, and both validation commands exiting zero.
