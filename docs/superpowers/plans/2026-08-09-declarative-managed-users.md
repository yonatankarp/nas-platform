# Declarative Managed Users Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconcile explicit per-service user allowlists while preserving unmanaged users and refusing password replacement for existing accounts.

**Architecture:** One vault_managed_users mapping contains service-specific lists. Each multi-user role delegates to a focused managed_users.yml file that lists, de-duplicates, creates, authenticates, and reconciles only non-secret properties through a pinned supported API, CLI, or declarative configuration interface.

**Tech Stack:** Ansible, application HTTP APIs/CLIs, Jinja2, Ruby contract tests.

---

### Task 1: Pin the capability matrix

**Files:**
- Create: config/managed-user-capabilities.yml
- Create: tests/managed_user_capabilities_test.rb
- Modify: tests/validate-policy.sh

- [ ] **Step 1: Write the failing matrix test**

Require exact service entries and these modes:

~~~yaml
audiobookshelf: api
beszel: api
dozzle: declarative_file
immich: api
jellyfin: api
komga: api
ntfy: declarative_environment
paperless-ngx: django_cli
tinymediamanager: single_shared_login
~~~

For each multi-user service require list/create/authenticate/reconcile interface
names, preserved unmanaged users, and password_rotation: refuse. Require
tinyMediaManager to name its existing shared credential contract and no allowlist.

Run: ruby tests/managed_user_capabilities_test.rb

Expected: FAIL because the matrix is absent.

- [ ] **Step 2: Add the matrix**

Record the pinned interfaces already exercised by roles, plus these user paths:
Audiobookshelf api/users and login; Beszel PocketBase users collection;
Dozzle data/users.yml and api/token; Immich admin/users and auth/login; Jellyfin
Users/New, Users/id/Policy, and Users/AuthenticateByName; Komga api/v2/users and
api/v2/users/me; ntfy NTFY_AUTH_USERS/ACCESS/TOKENS; and Paperless Django
get_user_model plus api/token. Mark password update endpoints forbidden for an
existing identity.

- [ ] **Step 3: Register, verify, and commit**

~~~bash
ruby tests/managed_user_capabilities_test.rb
git add config/managed-user-capabilities.yml tests/managed_user_capabilities_test.rb tests/validate-policy.sh
git commit -m "test: pin managed-user capabilities"
~~~

If a pinned service probe contradicts this matrix, stop and obtain an explicit
manual-exception decision; do not silently downgrade the capability.

### Task 2: Add the service-specific vault contract

**Files:**
- Modify: inventory/group_vars/all/vault.yml.example
- Modify: roles/vault_contract/meta/argument_specs.yml
- Modify: roles/vault_contract/tasks/main.yml
- Modify: tests/generate-ephemeral-vault.sh
- Modify: tests/secrets_docs_test.rb
- Modify: docs/secrets.md
- Create: tests/managed_users_vault_test.rb

- [ ] **Step 1: Write the failing schema test**

Require vault_managed_users with exactly eight service keys and these exact
entry fields:

~~~yaml
audiobookshelf: [username, password, type, is_active, permissions]
beszel: [email, password, role, verified]
dozzle: [username, password, password_hash, email, name, filter, roles]
immich: [email, password, name, quota_size]
jellyfin: [username, password, policy]
komga: [email, password, roles]
ntfy: [username, password, password_hash, role, access, tokens]
paperless_ngx: [username, password, email, is_active, is_staff, is_superuser, groups]
~~~

Require unique normalized identities, supported role values, non-empty
passwords, bcrypt shapes where used, and no duplicate of primary administrator,
Beszel primary app user, or ntfy publisher. Require synthetic ephemeral entries
for every service and documentation of every field.

Run: ruby tests/managed_users_vault_test.rb

Expected: FAIL because vault_managed_users is absent.

- [ ] **Step 2: Add sanitized example and ephemeral values**

Add one clearly synthetic user per service to vault.yml.example and the
ephemeral generator. Use only example.invalid identities, example passwords,
valid-shaped synthetic hashes/tokens, least-privilege roles, and empty group or
token lists where allowed.

- [ ] **Step 3: Validate at role entry**

Add a required dict argument and no-log assertions. Resolve each service list
into a named fact only after validating exact keys, identity uniqueness,
administrator separation, and supported values. Error messages name only service
and invalid field, never a value.

- [ ] **Step 4: Document, verify, and commit**

~~~bash
ruby tests/managed_users_vault_test.rb
ruby tests/secrets_docs_test.rb
tests/generate-ephemeral-vault.sh --self-test
ansible-playbook validate-vault.yml -e @inventory/group_vars/all/vault.yml.example
git add inventory roles/vault_contract tests/generate-ephemeral-vault.sh \
  tests/managed_users_vault_test.rb tests/secrets_docs_test.rb docs/secrets.md
git commit -m "feat: define managed application users"
~~~

### Task 3: Remove existing Beszel password-reset behavior

**Files:**
- Modify: roles/beszel/tasks/main.yml
- Create: tests/beszel_password_preservation_test.rb
- Modify: tests/validate-policy.sh

- [ ] **Step 1: Write the failing preservation test**

Require an existing primary app user with failed authentication to trigger an
assertion containing credential-migration guidance. Parse the Beszel task file
and reject any PATCH body for an existing user containing password or
passwordConfirm. Also require superuser creation to occur only after a
non-secret empty-database probe, never merely after failed authentication.

Run: ruby tests/beszel_password_preservation_test.rb

Expected: FAIL on the current credential PATCH and superuser upsert condition.

- [ ] **Step 2: Separate absence from authentication failure**

Add an exact existing-superuser probe through the pinned Beszel/PocketBase CLI.
Create only when the probe reports zero identities. If the identity exists and
auth returns non-200, fail. For the primary application user, create with
password only when absent; authenticate when present; assert success before any
role/verified PATCH; and patch only role and verified.

The existing-user assertion is:

~~~yaml
- name: Require preserved Beszel application-user credentials
  ansible.builtin.assert:
    that:
      - beszel_app_user_auth.status | int == 200
    fail_msg: >-
      Existing Beszel application user does not accept its preserved vault
      password. Run the reviewed credential-migration procedure; Ansible will
      not reset it automatically.
  when: beszel_user_id | length > 0
  no_log: true
~~~

- [ ] **Step 3: Verify and commit**

~~~bash
ruby tests/beszel_password_preservation_test.rb
tests/run-beszel-contract.sh
git add roles/beszel/tasks/main.yml tests/beszel_password_preservation_test.rb tests/validate-policy.sh
git commit -m "fix: preserve existing Beszel passwords"
~~~

### Task 4: Reconcile config-backed Dozzle and ntfy users

**Files:**
- Create: roles/dozzle/tasks/managed_users.yml
- Modify: roles/dozzle/tasks/main.yml
- Modify: roles/dozzle/templates/users.yml.j2
- Create: roles/ntfy/tasks/managed_users.yml
- Modify: roles/ntfy/defaults/main.yml
- Modify: roles/ntfy/tasks/main.yml
- Create: tests/config_managed_users_test.rb

- [ ] **Step 1: Write failing rendered-contract tests**

For Dozzle, require merging allowlisted users into the existing users mapping,
preserving keys outside the allowlist, refusing a hash change for an existing
allowlisted identity, rendering exact non-secret fields, and authenticating every
managed plaintext password at api/token. For ntfy, require conversion to
provisioning entries, duplicate/admin/publisher separation, token ownership, and
Basic-auth verification of each managed user.

Run: ruby tests/config_managed_users_test.rb

Expected: FAIL because the role files and template loops are absent.

- [ ] **Step 2: Implement Dozzle preservation**

Before rendering, safe-load an existing regular data/users.yml when present.
Reject malformed or duplicate normalized names. For an existing allowlisted
entry, require its stored password hash to equal the vault hash; otherwise fail
before template mutation. Preserve non-allowlisted entries verbatim. Merge
non-secret allowlisted fields and render with to_json quoting. Restart only when
the resulting file changes, then authenticate every allowlisted user.

- [ ] **Step 3: Implement ntfy provisioning**

Combine the administrator, publishers, and allowlisted users into
ntfy_auth_users, ntfy_auth_access, and ntfy_auth_tokens. Reject identity/token
collisions. Existing provisioning remains declarative; authenticate each managed
user and verify only its declared topic access. Never delete identities outside
the provisioning ownership set.

- [ ] **Step 4: Verify and commit**

~~~bash
ruby tests/config_managed_users_test.rb
tests/run-dozzle-contract.sh
tests/run-ntfy-contract.sh
git add roles/dozzle roles/ntfy tests/config_managed_users_test.rb
git commit -m "feat: manage Dozzle and ntfy users"
~~~

### Task 5: Reconcile Audiobookshelf, Jellyfin, and Komga users

**Files:**
- Create: roles/audiobookshelf/tasks/managed_users.yml
- Modify: roles/audiobookshelf/tasks/main.yml
- Create: roles/jellyfin/tasks/managed_users.yml
- Modify: roles/jellyfin/tasks/main.yml
- Create: roles/komga/tasks/managed_users.yml
- Modify: roles/komga/tasks/main.yml
- Create: tests/media_managed_users_test.rb

- [ ] **Step 1: Write failing per-service contracts**

For each service require: complete list; duplicate refusal; absent-only create;
existing-user authentication with the user's own password; refusal on auth
failure; non-secret-only repair; final exact allowlist verification; and no
assertion that unmanaged users are absent. Reject password fields in PATCH/Policy
calls for existing users.

Run: ruby tests/media_managed_users_test.rb

Expected: FAIL because the managed-user task files are absent.

- [ ] **Step 2: Implement Audiobookshelf**

Use the administrator bearer to GET and POST api/users. Match username exactly.
Create absent users with password and desired fields. Authenticate existing users
through login before PATCH. PATCH only type, isActive, and permissions. Verify
each managed identity once while preserving all others.

- [ ] **Step 3: Implement Jellyfin**

Use the administrator token to list Users. POST Users/New and set the initial
password only for an absent identity. Existing identities must pass
Users/AuthenticateByName. POST Users/id/Policy only with the desired policy.
Verify exact normalized policy fields and one identity.

- [ ] **Step 4: Implement Komga**

Use administrator Basic auth to list api/v2/users. POST absent users with initial
password. Existing users must authenticate at api/v2/users/me. PATCH only roles
and other declared non-secret properties. Verify exact email and roles.

- [ ] **Step 5: Verify and commit**

~~~bash
ruby tests/media_managed_users_test.rb
tests/run-audiobookshelf-contract.sh
tests/run-jellyfin-contract.sh
tests/run-komga-contract.sh
git add roles/audiobookshelf roles/jellyfin roles/komga tests/media_managed_users_test.rb
git commit -m "feat: manage media application users"
~~~

### Task 6: Reconcile Immich, Paperless, and additional Beszel users

**Files:**
- Create: roles/immich/tasks/managed_users.yml
- Modify: roles/immich/tasks/main.yml
- Create: roles/paperless_ngx/tasks/managed_users.yml
- Modify: roles/paperless_ngx/tasks/main.yml
- Create: roles/beszel/tasks/managed_users.yml
- Modify: roles/beszel/tasks/main.yml
- Create: tests/database_managed_users_test.rb

- [ ] **Step 1: Write failing contracts**

Require the same list/create/authenticate/refuse/repair/verify lifecycle. Require
Paperless Django commands to receive values through environment variables rather
than command text. Require Beszel additional users not to receive universal
tokens, settings, systems, or alerts owned by the primary app user unless those
fields are explicitly added in a later reviewed design.

Run: ruby tests/database_managed_users_test.rb

Expected: FAIL because the task files are absent.

- [ ] **Step 2: Implement Immich**

List users with the administrator token, match normalized email, create absent
users at admin/users with initial password/name, authenticate existing users at
auth/login, update only name/quota/active properties, and verify exact state.
Never change administrator status through the allowlist.

- [ ] **Step 3: Implement Paperless**

Use one Django shell command to list sanitized identity state and another to
create absent users with set_password. For existing users, authenticate through
api/token before changing email, active/staff/superuser flags, or groups. Never
call set_password for an existing user. Verify group names and flags exactly.

- [ ] **Step 4: Implement additional Beszel users**

Reuse the complete PocketBase collection read. Create absent entries with
password, authenticate existing entries, patch only role and verified, and
verify one exact identity per allowlist entry. Keep the primary app-user
configuration block unchanged except for Task 3 password preservation.

- [ ] **Step 5: Verify and commit**

~~~bash
ruby tests/database_managed_users_test.rb
tests/run-immich-contract.sh
tests/run-paperless-contract.sh
tests/run-beszel-contract.sh
git add roles/immich roles/paperless_ngx roles/beszel tests/database_managed_users_test.rb
git commit -m "feat: manage database-backed application users"
~~~

### Task 7: Verify all managed-user behavior

**Files:** none

- [ ] **Step 1: Run static and synthetic behavior checks**

~~~bash
ruby tests/managed_user_capabilities_test.rb
ruby tests/managed_users_vault_test.rb
ruby tests/beszel_password_preservation_test.rb
ruby tests/config_managed_users_test.rb
ruby tests/media_managed_users_test.rb
ruby tests/database_managed_users_test.rb
tests/validate-policy.sh
ansible-lint --strict
ansible-playbook -i inventory/local.yml site.yml --syntax-check
tests/integration.sh site.yml
git diff --check
git status --short
~~~

Expected: all checks pass, second convergence reports zero changes, every
synthetic managed user authenticates, and unmanaged fixture users remain.

- [ ] **Step 2: Record capability exceptions honestly**

If any pinned API cannot satisfy the committed matrix, stop this plan. Add no
database workaround. Prepare an owner decision naming the service, missing
property, supported manual action, verification evidence, and production release
gate before continuing to the adoption lane.
