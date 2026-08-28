# Phase One Final Hardening Design

## Problem

The final review of PR #95 found four important gaps after the original CI
portability failures were repaired.

Configarr and Unpackerr embed the current numeric NAS identity instead of
consuming the platform identity variables. Configarr also lives in a separate
Compose file, contrary to the approved media-acquisition design, which lets the
job escape the canonical bounded-logging and resource-policy checks.

Enabled Arr reconciliation does not compare every owned field, several API
writes always report a change, and the live suites do not perform a second
normal enabled convergence. Masked credentials and opaque provider settings
need an explicit idempotence model rather than being silently ignored.

Finally, the integration cleanup added common production container and network
names to an unconditional deletion list. A failed integration run can therefore
delete an unrelated local Radarr or downloader resource with the same name.

## Scope and Structure

This hardening keeps PR #95 focused on the services and cleanup entries it
introduces. It does not refactor unrelated reader services or every legacy
integration resource. Those broader consistency changes will be captured in
separate GitHub issues.

The implementation has three independently testable units:

1. canonical Compose identity and policy;
2. complete enabled reconciliation and idempotence; and
3. ownership-labelled Arr/downloader integration resources and cleanup.

All three must pass before the branch is pushed for authoritative GitHub CI.

## Canonical Compose and Filesystem Identity

Configarr and Unpackerr will use the same direct-user pattern already used by
Dozzle and ntfy:

```yaml
user: "${NAS_UID:?}:${NAS_GID:?}"
```

The values continue to originate in `nas_uid` and `nas_gid`, are rendered once
to each service environment file, and are not duplicated as numbers in
Compose. Linuxserver containers retain their image-supported `PUID`, `PGID`,
and `UMASK` mechanism.

Configarr will move from `services/arr/compose.jobs.yml` into
`services/arr/compose.yml` under `profiles: [jobs]`, as the original platform
design requires. A job-specific extension will provide `cpuset`, its CPU limit,
bounded `json-file` logging, and the media-control network without adding a
restart policy or published ports. The Arr role will run Configarr from the
ordinary `platform_service_compose_files['arr']` set. Deployment-bundle logic,
image pre-pulling, contracts, and manifest verification will stop carrying a
special `compose.jobs.yml` exception.

Policy tests will inspect the effective canonical Compose definition and require
Configarr to be the sole `jobs`-profile service, digest-pinned, CPU-bounded,
unpublished, non-restarting, bounded-log, and dynamically identified. Effective
Compose tests will render Configarr and Unpackerr with non-default UID/GID values
and require those exact values in the resolved `user` field.

Audiobookshelf, Jellyfin, and Komga currently retain legacy hardcoded direct-user
identities. Changing those readers is outside this PR because their image and
NAS permission compatibility needs separate acceptance testing. A GitHub issue
will track migrating all three to the platform identity variables.

## Reconciliation Ownership Model

Every managed relationship will have one declared desired body and one
normalized owned projection. The projection includes every non-secret field the
role writes, not merely the fields currently needed to find the resource.
Duplicate names or competing owned URLs remain fail-closed.

The owned projections are:

- Prowlarr applications: name, enable state, sync level, implementation,
  implementation name, config contract, tags, Prowlarr URL, Arr base URL,
  authentication blanks, and sync categories.
- Radarr and Sonarr SABnzbd clients: name, enable state, protocol, priority,
  completed/failed removal flags, implementation, implementation name, config
  contract, tags, host, port, SSL, URL base, and category.
- Operator Prowlarr indexers: name, enable state, priority, implementation,
  implementation name, config contract, tags, and every declared field whose
  value is visible in the API response.
- Bazarr: authentication type and username, Radarr/Sonarr enablement, host,
  port, base URL and SSL, identical-path mappings, languages, enabled provider
  names, and every readable operator-provider setting.
- Configarr: the named quality profile, quality definitions, custom formats,
  and naming flags already declared as Configarr-owned state.

Before mutation, the role reads the current resource, validates the response
schema, normalizes the owned projection, and compares it with the normalized
desired projection. Post-convergence verification re-reads and asserts the same
projection so reconciliation and verification cannot drift apart.

## Masked Secrets and Private Desired-State Digests

APIs often mask saved passwords or API keys. The role must not treat a masked
value as proof that the desired secret is installed, nor log secret-bearing
bodies to make comparison easier.

For each credential-bearing relationship class, Ansible will compute a
canonical SHA-256 digest of the complete desired input, including secret fields,
under `no_log`. Only the digest is persisted under the Arr runtime directory;
files are owned by `nas_uid:nas_gid`, mode `0600`, and written only after a
successful apply and complete post-read verification. A missing or changed
digest forces reconciliation. Failed or partial reconciliation never advances
the digest.

Where an application exposes a persisted-resource connectivity test, the role
will use it with `changed_when: false`. Where saved credentials cannot be tested
or read, the role may safely resubmit the complete idempotent desired body on
each enabled convergence, but its Ansible `changed` result is determined by the
owned projection and desired digest rather than by the mere HTTP request. This
keeps secret drift repair conservative without falsely reporting perpetual
changes.

Configarr receives one digest covering its pinned image, bundled config,
rendered secrets, and declared owned-state inputs. The role pre-reads the
Configarr-owned projection and runs the one-shot job only when that projection
drifts or the digest changes or is absent. A successful job is followed by the
existing full readback before the digest is committed. A stable second
convergence skips the job and reports no change.

Bazarr provider settings and operator Prowlarr indexers receive equivalent
private desired-input digests where their APIs mask declared fields.

## Enabled Idempotence Acceptance

The Arr and downloader suites will run a second ordinary enabled convergence,
not check mode. The first convergence may create and repair resources. The
second uses the same vault, enabled transport flags, and desired declarations
and must finish with `changed=0` while retaining all runtime verification.

Check mode remains useful as an additional no-mutation contract but is not a
substitute for the second normal convergence. Fixture APIs will include drift
cases for every owned non-secret field and desired-secret digest changes.
Stable cases must prove Configarr does not run and the role reports no change.
Resources whose complete state is readable must also produce no PUT or POST.
When a masked credential must be safely resubmitted because persisted state
cannot be tested, the fixture instead requires the exact desired body and
`changed=0` after the successful unchanged resubmission.

## Integration Namespace and Cleanup Ownership

The integration harness will derive a lowercase project namespace from the
already validated six-character sandbox suffix. Arr and downloader roles will
receive that value through `platform_project_name`. Their integration Compose
overrides will use namespace-derived container names, matching the established
Mac override pattern, instead of the production names `radarr`, `sonarr`,
`prowlarr`, `bazarr`, `sabnzbd`, and `unpackerr`.

Cleanup will no longer add those production names or the unscoped
`arr_default`/`downloaders_default` networks to the unconditional legacy lists.
It will discover only resources carrying the exact expected
`com.docker.compose.project` label for the derived Arr or downloader project.
Before deletion it will require the expected project label and the exact
namespace-derived container or network identity. A missing label, mismatched
label, unexpected resource name, or invalid sandbox suffix causes cleanup to
refuse rather than broaden deletion.

Tests will seed unrelated containers and networks named `radarr`, `sabnzbd`,
`arr_default`, and `downloaders_default` and prove that integration cleanup
leaves them untouched. Separate fixtures will prove labelled sandbox resources
are removed and label/name mismatches are refused.

Other pre-existing services still use the legacy fixed-name cleanup mechanism.
A second GitHub issue will track moving all remaining integration resources to
derived namespaces and ownership-label cleanup without expanding PR #95.

## Failure Behavior

- Missing UID/GID variables make Compose rendering fail immediately.
- Configarr cannot start outside the canonical `jobs` profile and never gains a
  restart policy or host port.
- Unsupported API response shapes, duplicate owned identities, failed
  connectivity probes, failed writes, and incomplete readback stop convergence.
- Desired-state digests are private, contain no reversible secret material, and
  advance only after verified success.
- Cleanup refuses resources it cannot prove belong to the exact disposable
  project.
- Production NAS media declarations remain owner/group-free, and this hardening
  does not broaden the synthetic integration ownership boundary.

## Verification

Test-first changes will prove:

- Configarr and Unpackerr resolve arbitrary non-default `NAS_UID:NAS_GID` values;
- no acquisition Compose file embeds `1000:100`;
- Configarr lives only in canonical Arr Compose and receives the full one-shot
  resource and logging policy;
- each relationship's complete owned projection detects every field mutation;
- secret-input digest changes force a verified apply while stable digests do
  not report changes;
- a second normal enabled convergence reports `changed=0`;
- unrelated exact-name Docker resources survive cleanup;
- only exact labelled sandbox Arr/downloader resources are removed; and
- the documented targeted commands are:

```sh
tests/integration.sh --suite arr site.yml
tests/integration.sh --suite downloaders site.yml
```

Focused policy, Compose, API-fixture, cleanup, syntax, strict lint, and both
correctly targeted live suites must pass. After local review, PR #95 will be
pushed and the complete GitHub x86 matrix must finish green before the branch is
considered deployable.

No commit may contain a `Co-Authored-By` trailer.
