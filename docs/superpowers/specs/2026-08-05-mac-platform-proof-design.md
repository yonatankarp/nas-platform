# Mac Platform Proof Design

## Purpose

Prove that `nas-platform` can deploy, configure, reconcile, and preserve the
complete NAS application platform before it is allowed to replace the existing
Portainer-managed deployment.

The proof runs all nine current stacks on Docker Desktop using disposable data.
It covers both a fresh installation and adoption of state created by the current
`nas-infrastructure` Compose definitions. Automated checks and a manual
application review are both release gates.

The physical NAS migration is a separate design. It will be written only after
this proof produces evidence about service behavior, state adoption, and the
remaining NAS-only risks.

## Scope

The proof covers:

- Audiobookshelf
- Beszel hub, agent-compatible monitoring behavior, and socket proxy
- Dozzle and its socket proxy
- Immich server, machine learning, Valkey, and PostgreSQL
- Jellyfin
- Komga
- ntfy
- Paperless-ngx, PostgreSQL, Valkey, Tika, and Gotenberg
- tinyMediaManager

It uses the same encrypted deployment credentials and managed configuration as
the NAS, together with small disposable fixtures. It does not copy production
photos, documents, media, databases, or application state from the NAS.

## Architecture

Every stack has one canonical production Compose definition. Docker Desktop
differences are isolated in narrowly scoped override files:

```text
services/<service>/compose.yml       canonical production definition
services/<service>/compose.mac.yml   Docker Desktop compatibility override
roles/<service>/                     shared deployment and configuration role
inventory/group_vars/nas/            NAS paths and capabilities
inventory/group_vars/mac/            disposable paths and Mac capabilities
```

Mac overrides may redirect host paths, assign non-conflicting test ports, remove
unavailable Linux devices, select CPU implementations, or adapt networking that
Docker Desktop cannot reproduce. They must not redefine image versions,
container-side persistent paths, application security policy, or managed
application configuration.

Ansible deploys a versioned bundle from the controller checkout. It does not
trust an arbitrary repository checkout already present on the target. The bundle
manifest records the Git commit, included services, pinned images, and rendered
file checksums. Test reports reference this manifest.

Each Mac run receives a unique Compose project namespace and a generated sandbox
under a disposable root. It reuses the deployment credentials by design, but it
cannot reuse production paths, project names, published ports, or application
data.

## Credential and Configuration Parity

The encrypted Ansible vault is portable platform configuration and supplies both
NAS and Mac deployments. The Mac proof must reuse application usernames and
passwords, database credentials, application secret keys, ntfy identities and
tokens, Beszel keys and tokens, and configured third-party integration
credentials. A fresh Mac deployment must accept the same user logins without
regeneration or manual re-entry.

Environment-specific variables are limited to unavoidable machine facts such as
host address, published test ports, storage roots, Docker Desktop networking
adaptation, and hardware capabilities. These variables must not silently change
application identities or managed behavior.

The vault remains encrypted at rest. Ansible renders secrets only into
mode-`0600` runtime files. Test reports, diagnostics, and captured logs redact
secrets, authorization headers, private keys, password hashes, and rendered
environment values. Cleanup removes all rendered Mac-side secret material but
never modifies the shared encrypted vault.

Paperless receives the same Gmail credential, mail account, and mail-rule
configuration as the NAS. Automated verification proves that the account and
rule are present and that Gmail authentication and connectivity succeed. It does
not initiate inbox consumption or import real messages. A real fetch is an
explicit optional manual test.

## Components

### Deployment bundle

The controller assembles and copies the exact committed Compose definitions,
platform overrides, and rendered environment files needed by a run. Deployment
roles consume only this bundle. The target does not fetch or update Git.

### Environment adapter

Inventory variables describe storage roots, published ports, render-device
availability, network capabilities, and the platform identifier. Roles select
behavior from explicit capabilities rather than inferring that all non-NAS hosts
are test hosts.

### Service roles

Each service role owns:

- Its storage declarations and permissions.
- Secret and environment rendering.
- Compose deployment.
- Supported first-run identity and application provisioning.
- Application-level health verification.
- Drift reconciliation for settings the application exposes through a stable
  CLI, environment contract, or API.

If a setting cannot be provisioned reliably, the role reports an explicit manual
exception. It must not silently leave an application partially configured.

### Disposable fixtures

The harness creates reproducible, non-sensitive fixtures for the application's
real purpose: an audiobook, a comic or book, a short video, a photo, and
documents suitable for German, English, and Hebrew OCR. Fixture checksums make
persistence and migration assertions deterministic.

### Verification harness

The harness executes named phases:

```text
preflight -> deploy -> seed -> verify -> idempotence
          -> inject drift -> reconcile -> recreate
          -> verify persistence -> manual review -> cleanup
```

It emits a machine-readable report containing phase results, the deployment
manifest identity, image versions, and sanitized diagnostic locations.

On failure, the harness captures Compose state, health status, and sanitized
logs, then preserves the sandbox by default. Cleanup is an explicit command.
Secrets, authorization headers, private keys, password hashes, and rendered
environment values must not appear in reports or captured logs.

## Proof Lanes

### Fresh-install lane

The fresh-install lane starts with an empty sandbox. Ansible must prepare all
storage, deploy every stack, install the vault-authored identities, configure
integrations, and leave every application ready for the manual acceptance
review. No login or integration credential may be regenerated for the Mac.

### State-adoption lane

The state-adoption lane models the Portainer-to-Ansible transition:

1. Deploy the current `nas-infrastructure` Compose definitions with Mac path and
   platform overrides.
2. Perform the minimum supported first-run setup and seed disposable state.
3. Record application users, settings, metadata, alert rules, database records,
   and fixture checksums.
4. Stop the old Compose projects without deleting persistent directories.
5. Preserve a coordinated pre-cutover copy of every state directory.
6. Deploy `nas-platform` against the same persistent directories.
7. Verify that existing application state remains usable and that Ansible's
   managed configuration is applied.
8. Re-run Ansible and require zero changes.
9. Perform automated and manual acceptance checks.
10. Exercise rollback by restoring the coordinated pre-cutover copy.

Ansible must have an explicit adoption path for identities that already exist.
It must not silently replace keys, tokens, passwords, or database identities.

Paperless and Immich rollback restores a complete coordinated snapshot. Older
application images are never started against databases that may have been
migrated by newer versions.

## Monitoring and Alerting Contract

The disposable ntfy instance is the only notification destination. Mobile push
is outside the Mac proof.

Ansible provisions:

- An ntfy administrator.
- Dedicated write-only publisher identities and tokens.
- Deny-by-default anonymous access.
- The `nas-critical` topic.
- Beszel's notification destination and CPU, memory, disk, and status alerts.
- Dozzle's ntfy destination and OOM, unexpected-exit, unhealthy, and recovery
  event alerts, including configured cooldowns.

Verification publishes and reads test messages through the disposable ntfy API.
It proves anonymous denial, publisher write access, publisher read denial, and
the delivery of generated Beszel and Dozzle test events.

## Automated Acceptance Gate

The Mac proof passes only when all of the following hold:

- All nine stacks and every non-hardware-specific container start.
- Mac-specific CPU behavior works for Jellyfin, Immich, and Beszel without
  changing the production GPU definitions.
- Storage, ports, health checks, restart behavior, logging, and security policy
  match the declared platform contract where Docker Desktop supports them.
- Required identities, ACLs, tokens, webhooks, users, and alert rules exist.
- Representative application data survives container recreation.
- Immich and Paperless database state survives Ansible redeployment.
- Paperless ingestion, German/English/Hebrew OCR, preview, search, Tika,
  Gotenberg, export, and optional Ollama configuration work.
- Paperless provisions the NAS-equivalent Gmail account and mail rule, and a
  non-consuming authentication/connectivity check succeeds.
- Every managed application accepts the same operator credentials as the NAS.
- Authenticated alert delivery works entirely within the disposable platform.
- A second Ansible run reports zero changes.
- Supported deliberate configuration drift is repaired on the next run.
- Check mode reports intended changes without mutation.
- Both the fresh-install and state-adoption lanes pass.
- Cleanup removes containers, networks, rendered credentials, and disposable
  data without leaving privileged or root-owned residue.
- Local validation and CI pass.

## Manual Acceptance Gate

The harness exposes every application on documented localhost URLs and produces
a review checklist tied to the deployment manifest. The operator records pass or
fail, notes, timestamp, and the manifest Git commit.

The review covers:

- **Audiobookshelf:** scan an audiobook, browse metadata, play it, and retain
  progress after recreation.
- **Komga:** scan a disposable library, open a book, and retain library settings.
- **Jellyfin:** scan media, play direct-stream content, exercise CPU transcoding,
  and retain users and libraries.
- **tinyMediaManager:** scan Movies and Series, fetch or edit metadata, write it
  to disposable media, and retain settings.
- **Immich:** create or use the managed account, upload photo and video fixtures,
  generate thumbnails, exercise CPU machine learning, search and browse, and
  retain assets after recreation.
- **Paperless:** create or use the managed administrator, consume documents,
  verify German/English/Hebrew OCR, preview and search, process an Office document
  through Tika and Gotenberg, create an export, and inspect the provisioned Gmail
  account and mail rule without consuming the real inbox.
- **ntfy:** sign in, confirm anonymous denial, subscribe to `nas-critical`, and
  read authenticated test messages.
- **Beszel:** sign in, view Mac and container metrics, inspect thresholds, and
  send a test notification to disposable ntfy.
- **Dozzle:** sign in, view logs, confirm shell/actions/MCP remain disabled,
  inspect all four event rules, and trigger a container event delivered to ntfy.

The review must not require undocumented web-UI setup. Any unavoidable manual
first-run action is documented, tested, and recorded as an explicit exception.

## NAS-Only Evidence

Docker Desktop cannot prove:

- Intel GPU device access and hardware transcoding.
- Beszel Intel GPU metrics and Linux performance capabilities.
- ASUSTOR ADM Defender and host-network behavior.
- Native `/volume1` and `/volume2` mount and permission behavior.
- Tailscale reachability.
- Behavior with production-scale data.
- Real Gmail inbox consumption, external Ollama availability, mobile push, or
  complete NAS outage detection.

These become mandatory gates in the later NAS migration design. They are listed
explicitly in Mac reports and are never represented as passing or silently
skipped.

## Delivery Tranches

The proof is implemented in independently testable tranches:

1. Repair CI, establish the service manifest, implement versioned deployment
   bundles, and create the shared Mac harness.
2. Complete ntfy, Beszel, and Dozzle, including alerting and drift repair.
3. Add Audiobookshelf, Komga, and tinyMediaManager with disposable fixtures.
4. Add Jellyfin with Mac CPU behavior and NAS GPU policy retained.
5. Add Immich with database persistence, state adoption, and rollback tests.
6. Add Paperless with OCR, document conversion, persistence, adoption, export,
   and rollback tests.
7. Run the complete fresh-install and state-adoption suites, then complete the
   manual acceptance report.

Each tranche must pass its local automated checks before the next tranche begins.
The NAS migration design starts only after tranche seven is accepted.

## Out of Scope

- Copying production NAS application data or databases to the Mac.
- Deploying to or changing the physical NAS during this proof.
- Public ingress, reverse proxying, or router configuration.
- Mobile notification delivery.
- Backup-provider selection or implementation.
- Replacing Docker Compose with another container orchestrator.

## Completion

The design is complete when the automated report is green, the manual checklist
is accepted, all NAS-only limitations are recorded, and the resulting evidence
is sufficient to write the separate physical NAS migration design and rollback
plan.
