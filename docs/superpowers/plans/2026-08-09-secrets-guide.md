# Canonical Secrets Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish one complete, migration-safe guide for authoring, encrypting, validating, backing up, and deploying every required platform credential.

**Architecture:** `docs/secrets.md` becomes the canonical operator reference. A focused Ruby documentation contract keeps its key inventory synchronized with the vault schema and requires the README and both platform walkthroughs to link to it; the existing guides retain only context-specific safety and command guidance.

**Tech Stack:** Markdown, Ruby 4, YAML/Psych, POSIX shell, Ansible Vault

---

### Task 1: Add the documentation contract

**Files:**
- Create: `tests/secrets_docs_test.rb`
- Modify: `tests/validate-policy.sh:4-6`

- [ ] **Step 1: Write the failing documentation contract**

Create `tests/secrets_docs_test.rb` with a focused assertion helper. Load
`inventory/group_vars/all/vault.yml.example`, extract every key beginning with
`vault_`, extract the same identifiers from `docs/secrets.md`, and fail with key
names only when either set differs. Require `README.md` to link to
`docs/secrets.md`, both getting-started guides to link to `secrets.md`, and the
canonical guide to put `Migration workflow` before `Brand-new platform`.

The test must not print YAML values. Its core comparison is:

```ruby
example = YAML.safe_load_file(File.join(ROOT, "inventory/group_vars/all/vault.yml.example"))
expected_keys = example.keys.grep(/^vault_/).sort
documented_keys = File.read(File.join(ROOT, "docs/secrets.md")).scan(/`(vault_[a-z0-9_]+)`/).flatten.uniq.sort
check(failures, documented_keys == expected_keys,
      "secrets guide vault-key inventory differs: " \
      "missing=#{expected_keys - documented_keys} unexpected=#{documented_keys - expected_keys}")
```

Add `ruby tests/secrets_docs_test.rb` immediately after `ruby tests/policy_test.rb`
in `tests/validate-policy.sh`.

- [ ] **Step 2: Run the test to verify RED**

Run:

```sh
ruby tests/secrets_docs_test.rb
```

Expected: exit 1 because `docs/secrets.md` does not exist. The test must emit a
bounded failure message rather than a Ruby stack trace, so handle the absent file
as an empty document.

- [ ] **Step 3: Commit the failing contract**

```sh
git add tests/secrets_docs_test.rb tests/validate-policy.sh
git commit -m "test: define canonical secrets documentation contract"
```

### Task 2: Write the canonical secrets guide

**Files:**
- Create: `docs/secrets.md`
- Reference: `inventory/group_vars/all/vault.yml.example`
- Reference: `roles/vault_contract/tasks/main.yml`
- Reference: `generate-secrets.yml`

- [ ] **Step 1: Add the migration safety boundary and preparation**

Start with `# Secrets and encrypted vault` and a prominent `## Migration
workflow` section. State that migration copies current values and must not run
`generate-secrets.yml`. Document activation of `.venv`, collection from the
password manager, Portainer, Compose environment, databases, ntfy, Beszel, and
Paperless, plus the prohibition on chat, shell `-e` arguments, logs, tickets,
and PRs.

Use these external paths consistently:

```sh
export PLATFORM_VAULT_DIR="$HOME/.config/nas-platform"
export PLATFORM_VAULT_FILE="$PLATFORM_VAULT_DIR/vault.yml"
export PLATFORM_VAULT_PASSWORD_FILE="$PLATFORM_VAULT_DIR/vault-password"
```

- [ ] **Step 2: Document all required service credentials**

Add one subsection per service and name every key from
`vault.yml.example` exactly once in inline code. Include the enforced shapes:
bcrypt hashes, distinct `tk_` tokens, database identifiers, emails, Beszel UUID
and Ed25519 keypair, the Paperless Django key and Gmail app password, and
TinyMediaManager password. Explain that deployed values must be copied exactly
and missing migration material is a stop condition. Link the Gmail requirement
to Google's official app-password guidance at
`https://support.google.com/accounts/answer/185833`.

- [ ] **Step 3: Document direct encrypted authoring**

Document protected directory creation, an operator-authored strong vault
password, refusal to overwrite existing files, and:

```sh
ansible-vault create \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  "$PLATFORM_VAULT_FILE"
```

Explain YAML scalar quoting, literal `$` hashes, the two-field Beszel agent key,
and the `|` block required for the private key. List every sanitized placeholder
family that must be removed.

- [ ] **Step 4: Document validation, backup, proof, and NAS installation**

Include header and mode checks, then the exact redacted contract command:

```sh
ansible-playbook validate-vault.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_VAULT_FILE" \
  -e "platform_vault_file=$PLATFORM_VAULT_FILE"
```

Explain manual `ansible-vault edit` review, ciphertext SHA-256, separate encrypted
artifact/password backups, the `tests/mac/run.sh --lane fresh` proof, and later
`install -m 600` into `inventory/group_vars/all/vault.yml`.

- [ ] **Step 5: Add the brand-new-platform exception**

End with `## Brand-new platform` and state its strict no-existing-state
precondition. Document the explicit generator opt-in, private review of identity
and Gmail placeholders, immediate move to the external vault path, encryption,
and rerunning the same validation. Repeat that this path rotates credentials and
is forbidden for migration.

- [ ] **Step 6: Run the focused contract to verify GREEN**

Run:

```sh
ruby tests/secrets_docs_test.rb
```

Expected: `secrets docs: canonical guide and vault schema agree`.

- [ ] **Step 7: Commit the canonical guide**

```sh
git add docs/secrets.md
git commit -m "docs: add canonical encrypted-vault guide"
```

### Task 3: Link the operator entry points

**Files:**
- Modify: `README.md:67-129`
- Modify: `docs/getting-started-mac.md:33-77`
- Modify: `docs/getting-started-nas.md:51-98`

- [ ] **Step 1: Replace README duplication with the canonical link**

Keep a short warning that migrations reuse current values and generators are
brand-new-only. Link `[complete secrets and encrypted-vault guide](docs/secrets.md)`
from the first-run and secrets sections. Preserve the explanation of ciphertext,
unrecoverable password loss, runtime plaintext locations, and executable password
providers, but remove the obsolete suggestion to decrypt the vault onto disk.

- [ ] **Step 2: Point the Mac proof at the canonical workflow**

Retain the external paths and the Mac proof command. Replace duplicated authoring
instructions with a link to `[secrets and encrypted-vault guide](secrets.md)` and
state that the guide's migration workflow must be completed before phase 4.

- [ ] **Step 3: Point the NAS walkthrough at the reviewed artifact flow**

Link to `[secrets and encrypted-vault guide](secrets.md)`, retain credential
continuity and `install -m 600`, and remove the duplicated generator recipe from
the migration walkthrough.

- [ ] **Step 4: Run the focused contract again**

Run `ruby tests/secrets_docs_test.rb`.

Expected: `secrets docs: canonical guide and vault schema agree`.

- [ ] **Step 5: Commit the entry-point links**

```sh
git add README.md docs/getting-started-mac.md docs/getting-started-nas.md
git commit -m "docs: link platform guides to secrets workflow"
```

### Task 4: Verify the complete documentation change

**Files:**
- Verify: `docs/secrets.md`
- Verify: `README.md`
- Verify: `docs/getting-started-mac.md`
- Verify: `docs/getting-started-nas.md`
- Verify: `tests/secrets_docs_test.rb`

- [ ] **Step 1: Scan for unfinished or unsafe prose**

Run:

```sh
rg -n 'TBD|TODO|FIXME|example-password|example-only-not-a-real-private-key' \
  docs/secrets.md README.md docs/getting-started-mac.md docs/getting-started-nas.md
```

Expected: no matches. Sanitized format examples must use ellipses rather than
values accepted by the real vault contract.

- [ ] **Step 2: Run portable validation**

Run:

```sh
export PATH="$PWD/.venv/bin:$PATH"
ruby tests/secrets_docs_test.rb
ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
find tests -type f -name '*.sh' -exec sh -n {} +
ansible-lint --strict
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ansible-playbook generate-secrets.yml --syntax-check
git diff --check HEAD~3
```

Expected: all commands exit 0. The mutation test reports `policy manifest: all
mutation checks hold`, Ansible lint reports zero failures and warnings, and both
playbooks parse successfully.

- [ ] **Step 3: Review the final history and content**

Confirm no commit contains `Co-Authored-By`, no file resembling a vault or
password was added, all links resolve, and `git status --short` is empty.

- [ ] **Step 4: Push and monitor CI**

```sh
git push origin agent/task-13-paperless
```

Monitor PR #3 until the documentation contract and full CI workflow complete.
