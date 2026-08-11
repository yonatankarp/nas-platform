# Legacy State Adoption Design

**Date:** 2026-08-09

## Goal

Prove that `nas-platform` can adopt the effective production configuration and
disposable legacy state of all nine Portainer stacks without rotating existing
identities, losing application data, duplicating users, or weakening rollback.

This design extends Task 14 of the Mac platform proof. The original task modeled
state created from the pinned `nas-infrastructure` Compose files. Production
behavior also depends on Portainer stack environment values and application
users created outside those files. A valid adoption proof must therefore model:

```text
pinned nas-infrastructure Compose
+ external Portainer stack environment
+ application-managed state and allowlisted users
= effective legacy behavior to adopt
```

The proof remains disposable. It does not read data from, connect to, deploy to,
or modify the physical NAS. The production migration remains a separate design.

## Services

The adoption lane covers exactly these stacks:

- Audiobookshelf
- Beszel
- Dozzle
- Immich
- Jellyfin
- Komga
- ntfy
- Paperless-ngx
- tinyMediaManager

Normal local runs require protected inputs for every stack. CI and explicit
self-tests use synthetic values and fixtures; they must never be described as
proof of actual production parity.

## Selected architecture

Use two bounded components and two external encrypted artifacts.

1. A parity-intake component converts nine protected Portainer `.env` exports
   into a temporary encrypted parity vault.
2. An adoption component builds disposable legacy stacks from the pinned
   Compose source and parity vault, then deploys `nas-platform` against the same
   state using the canonical deployment vault.

The deployment vault remains the long-term source of truth for credentials,
managed users, and application configuration. The parity vault is temporary
migration evidence: it preserves the exact Portainer inputs needed to prove
equivalence, but it is never consumed by production roles.

This is preferred over reading plaintext `.env` files on every run, which would
keep secrets exposed for the lifetime of the project, and over copying all
Portainer values into the permanent deployment vault, which would make obsolete
Portainer concepts part of the target platform.

## External input lifecycle

The operator creates one external `.env` file for each stack:

```text
portainer-env/
├── audiobookshelf.env
├── beszel.env
├── dozzle.env
├── immich.env
├── jellyfin.env
├── komga.env
├── ntfy.env
├── paperless-ngx.env
└── tinymediamanager.env
```

The source directory and files must be regular, non-symlink files outside the
repository with directory mode `0700` and file mode `0600`. The intake command
parses them without evaluating shell syntax, validates the complete mapping,
and writes a new external Ansible Vault artifact such as
`portainer-parity.yml`. It uses a mode-`0600` temporary file and publishes the
encrypted result only after encryption and validation succeed.

The parity artifact preserves values under their stack identity so repeated
names such as `TZ`, `PUID`, or `DB_PASSWORD` cannot collide. It also records the
exact `legacy_source.commit` from the service manifest. It may use the deployment
vault password by default because both artifacts protect the same production
trust domain, while the command interface allows a separate parity password file
for future access separation or rotation.

The intake command never overwrites an existing parity vault and never changes
or deletes the source exports. After independently verifying the encrypted
artifact, the operator explicitly removes the plaintext exports. After the
production migration is accepted and its rollback window expires, the operator
explicitly destroys the parity vault and its backups. Tooling retains only its
ciphertext checksum and non-secret pass/fail evidence; it never performs either
destructive lifecycle step automatically.

## Strict `.env` parser

The parser accepts:

- one `KEY=value` record per line;
- blank lines and full-line comments;
- empty values; and
- literal spaces, `$`, `#`, and additional `=` characters after the first `=`.

It rejects malformed names, duplicate keys within a stack, NUL bytes, multiline
records, symlinks, non-regular files, unexpected files, and missing stack files.
It does not perform shell expansion, quote removal, escape processing,
interpolation, command substitution, or `source` the files.

Multiline secrets such as private keys remain canonical deployment-vault inputs;
they are not represented in `.env` exports. The mapping contract must account
explicitly for the corresponding legacy behavior.

## Mapping contract

A committed contract accounts for every expected Portainer variable by stack.
Every entry has exactly one classification:

- `vault`: equals a named value in the canonical deployment vault;
- `inventory`: equals, or is transformed by a named rule into, a NAS inventory
  value;
- `role`: corresponds to an explicitly managed role setting;
- `test_adapter`: is replaced only by a documented disposable-host value such
  as a path, published port, or host address; or
- `excluded`: is intentionally not migrated and has a mandatory reason.

Unknown Portainer variables fail preflight. Missing expected variables also fail
unless the contract marks them optional and defines the precise absence
semantics. Mapping entries without a target, transform, or exclusion reason are
invalid. All production values remain external; Git stores only names,
classifications, targets, comparison rules, and synthetic fixtures.

Exact non-secret comparisons may happen in memory. Secret equality is checked in
redacted Ansible operations or, preferably, by authenticating to the disposable
application with the canonical credential. Reports include a variable or
capability name and pass/fail status only. They never include raw values,
password hashes, secret-derived fingerprints, authorization material, or
decrypted parity content. The only retained vault identity is a checksum of the
encrypted artifact bytes.

## Declarative managed users

Application users that must survive migration belong in permanent declarative
configuration, not the temporary parity vault. The deployment vault gains
service-specific allowlists only for applications that support multiple
accounts. Existing primary-administrator variables remain stable, and an
allowlisted identity may not duplicate the primary administrator.

Each service uses the fields its supported interface can manage, for example:

```yaml
username: example
email: example@example.invalid
password: encrypted-vault-value
role: reader
permissions:
  - library
enabled: true
```

There is no artificial cross-service schema when applications expose different
identity models. Vault validation enforces required fields, uniqueness,
supported roles and permissions, and administrator separation for each service.
Services with one shared login remain under their existing credential contract.

Before implementation, a service capability matrix must identify the stable,
supported API or CLI for listing, creating, reconciling, and authenticating
users. For each supported service, the role:

1. lists existing accounts and refuses ambiguous duplicate identities;
2. creates an absent allowlisted account;
3. reconciles supported non-secret properties such as email, role, permissions,
   and enabled state;
4. verifies the preserved vault password when the application permits it;
5. fails with credential-migration guidance when an existing password differs;
   and
6. preserves users outside the allowlist without managing or deleting them.

Roles do not reset an existing password automatically. Credential rotation is a
separate explicit procedure. If a required property cannot be automated through
a stable supported interface, the capability audit blocks Task 14 rather than
using direct database edits or silently claiming parity. An owner-approved
manual exception must name the limitation, operator action, verification
evidence, and production release gate.

## Adoption architecture and data flow

A normal adoption run requires:

```text
--vault-file
--vault-password-file
--parity-vault-file
--parity-vault-password-file
```

The parity password option may resolve to the same external password input as
the deployment vault. Self-test and CI modes create explicit synthetic
artifacts. They may not fall back silently when a normal run omits protected
inputs.

Preflight verifies that both artifacts are encrypted regular files outside the
repository, their password inputs satisfy the existing external-input contract,
the parity vault covers all nine services, and its legacy commit matches the
manifest. It also requires a clean `nas-infrastructure` checkout at
`400f03f276ae1bb69f5460c175b9fb923d620f1a`. Local runs accept an explicit
`NAS_INFRASTRUCTURE_DIR`; CI checks out that exact revision separately.

Nine committed overrides adapt only disposable paths, project names, ports,
host addresses, and host capabilities. They retain the legacy images and
application behavior needed for adoption. Legacy containers receive parity
values only inside the disposable sandbox. The target deployment receives only
canonical inventory and deployment-vault inputs.

The lane executes these phases:

```text
preflight
-> legacy-deploy
-> legacy-seed
-> capture-baseline
-> snapshot
-> cutover
-> verify
-> idempotence
-> recreate
-> persistence
-> rollback
-> report
-> cleanup
```

The fresh lane retains its existing phases and behavior.

## State capture and verification

The legacy seed phase creates only disposable fixtures and the allowlisted users
needed for the proof. Before cutover, service-specific probes record non-secret
identity and authorization state, durable settings, database record counts, and
fixture checksums. They also record the pinned source revision and legacy image
set.

Cutover stops legacy projects without deleting persistent directories, creates
a coordinated pre-cutover snapshot, and deploys `nas-platform` over those
directories. Post-cutover probes require:

- canonical administrator and allowlisted-user authentication;
- no duplicate identities or integrations;
- no missing accounts or privilege drift;
- preservation of records, fixtures, and durable application settings;
- application-specific managed configuration;
- a second Ansible run with zero changes; and
- equivalent state after container recreation.

Beszel additionally proves key and token adoption without duplicate systems.
ntfy proves the existing authentication state and declarative ACLs. Dozzle
proves its persisted notification destination and rules. The remaining services
use their existing fixture and persistence contracts plus capability-matrix
user assertions.

## Rollback

Rollback restores the coordinated pre-cutover copy into a new disposable
sandbox so the cutover state cannot contaminate the proof. It starts the matching
legacy image set and verifies the captured baseline again.

Immich and Paperless restore their complete coordinated application, database,
and supporting-service state. An older Immich or Paperless image is never
attached to a database that a newer image may have migrated. Failed rollback
setup leaves the evidence sandbox available for sanitized diagnosis and never
mutates the original snapshot.

## Failure and disclosure behavior

The intake and adoption components fail closed on incomplete inputs, parser or
mapping errors, vault decryption or encryption failures, unsafe permissions,
dirty or mismatched legacy source, unsupported required capabilities, baseline
drift, failed adoption assertions, non-idempotence, persistence loss, or rollback
failure.

A failed intake removes only unpublished temporary files owned by that
invocation. It leaves the source exports, deployment vault, and pre-existing
parity outputs unchanged. A failed adoption retains only the existing sanitized
diagnostic set and the disposable sandbox when requested by the operator.

Secret-bearing operations use the repository's redaction and log-sanitization
contracts. Tests inject distinctive synthetic canaries and require their absence
from command output, reports, diagnostics, rendered artifacts retained after
cleanup, and CI artifacts. Empty values are tested as mapping cases but are not
used as redaction canaries.

## Testing and CI

Testing is layered:

- parser tests cover spaces, `$`, `#`, `=`, empty values, comments, malformed
  records, duplicates, NUL bytes, unexpected files, and symlinks;
- mapping mutation tests cover missing, extra, duplicate, invalid, optional, and
  unmapped variables;
- intake tests cover permissions, atomic publication, overwrite refusal,
  ciphertext validation, and disclosure canaries;
- capability tests cover each service's supported user lifecycle and refusal
  paths;
- sequence self-tests use fake Docker and Ansible commands to assert phase order,
  interruption behavior, cleanup ownership, and report state;
- per-service tests verify baseline capture, adoption, idempotence, recreation,
  persistence, and rollback; and
- CI runs complete synthetic legacy-to-platform convergence with ephemeral
  vaults and no production values.

The final local proof uses both real external encrypted artifacts and remains a
required release gate. Its report records the Git revision, pinned legacy
commit, service image set, ciphertext checksums, phase results, and sanitized
diagnostic locations.

Before the Task 14 feature branch, implement the separately approved docs-only
CI fast path as a focused change. The required `validate` job remains present.
Changes confined to `docs/**` and `README.md` run documentation contracts and
skip heavy convergence; any mixed or executable change runs the complete suite.
Workflow-level `paths-ignore` is not used because it can leave a required check
absent.

## Acceptance gates

Task 14 succeeds only when:

- all nine stack exports have complete explicit mappings;
- every supported allowlisted user is created or reconciled declaratively;
- the capability audit has no unapproved required gap;
- the synthetic adoption lane passes in CI;
- the local adoption lane passes with both real external encrypted vaults;
- configuration, identities, records, fixtures, and settings survive cutover,
  idempotence, recreation, persistence checks, and rollback;
- reruns create no duplicate users, records, systems, or integrations;
- reports and artifacts satisfy every disclosure canary; and
- the physical NAS remains untouched.

## Out of scope

- Performing the production NAS migration.
- Connecting to or copying production application data from the physical NAS.
- Automatically rotating existing passwords or keys.
- Managing or deleting users outside explicit allowlists.
- Automatically deleting plaintext exports, the parity vault, or its backups.
- Bypassing unsupported account APIs with direct database edits.
- Manual application-workflow acceptance, which remains Task 15.
- Changing unrelated service behavior or refactoring completed roles without an
  adoption requirement.

## Delivery boundary

Deliver the work as two independently reviewed changes:

1. the approved docs-only CI fast path; and
2. parity intake, managed-user capabilities, and the Task 14 adoption lane.

After both changes pass their applicable checks and the real-vault local proof,
stop at the Task 14 handoff. Do not perform the production migration, retire
external evidence, or begin Task 15 without a separate instruction.
