# Manual Validation Corrections Design

**Date:** 2026-08-11

## Goal

Make fresh and adopted deployments converge to the application state observed
during manual review, prove the state through supported application interfaces,
and leave the fresh Mac proof running after verification so an operator can log
in as every managed user before drift and cleanup phases continue.

The work covers Audiobookshelf, Beszel, Dozzle, Immich, Jellyfin, Komga, ntfy,
Paperless-ngx, and the currently outdated container images. Paperless tags are
explicitly outside scope.

## Selected architecture

Use supported API reconciliation with explicit field ownership. Each role:

1. starts its pinned containers and waits for health;
2. authenticates through the application's supported interface;
3. reads current state and rejects ambiguous matches;
4. merges only fields declared as Ansible-owned;
5. writes only when those fields differ; and
6. reads the result back and verifies the owned fields.

Fresh and adoption lanes call the same reconcilers. Fresh creates missing
objects. Adoption updates uniquely identified managed objects while preserving
unmanaged users, preferences, libraries, subscriptions, plugins, and settings.
Direct application-database edits and browser-driven configuration are not
fallbacks. An unsupported or changed API fails before mutation.

Nonsecret policy belongs in role defaults or normal inventory. Passwords,
external account credentials, and password hashes remain in the encrypted
deployment vault. The Jellyfin avatar is a nonsecret repository asset.

## Shared identity and ambiguity rules

A managed identity or named object must resolve to zero or one record. More
than one candidate fails with record identifiers and a redacted explanation.
Roles do not guess which duplicate to keep. Adoption does not delete unknown
objects.

All managed-user collections retain their existing uniqueness and primary-admin
separation rules. Every entry in `vault_managed_users.immich` must be a
non-administrator; the separately managed primary Immich account remains the
only administrator managed by this repository.

Failure output and retained reports may name a capability, username-safe label,
or record identifier. They must not contain passwords, password hashes, tokens,
mail credentials, authorization headers, or decrypted vault content.

## Audiobookshelf

The Audiobookshelf role owns the following server settings from the approved
manual-review screenshot:

| Setting | Desired value |
| --- | --- |
| Store covers with item | enabled |
| Store metadata with item | enabled |
| Ignore prefixes when sorting | disabled |
| Parse subtitles | enabled |
| Find covers | enabled |
| Cover provider | Google Books (`google`) |
| Prefer matched metadata | enabled |
| Automatically watch libraries | enabled |
| Chromecast support | enabled |
| Allow embedding in an iframe | enabled |
| Home page bookshelf view | bookshelf/detail view (`1`) |
| Library bookshelf view | bookshelf/detail view (`1`) |
| Date format | `dd/MM/yyyy` |
| Time format | `HH:mm` |
| Default server language | English (`en-us`) |

Audiobookshelf 2.36.0 does not expose `GET /api/settings`. The role reads the
current `serverSettings` through authenticated `POST /api/authorize`, constructs
a partial patch from these owned keys, applies `PATCH /api/settings` only on
drift, and performs a fresh authorization read to verify the same keys. It never
treats the PATCH response as authoritative. The role continues to own the
existing Audiobooks library and its existing library-specific settings.

Automatic backups are enabled with cron expression `0 3 * * *`, interpreted in
the container's configured `Europe/Berlin` timezone. Seven backups are retained.
The host directory is `/volume1/Docker/audiobookshelf/backups`; it is exposed to
the container as `/metadata/backups`, and the API-owned backup path is
`/metadata/backups`. Mac and adoption overrides map the same container path to
their disposable state roots. The backup directory is classified `critical` in
the central `nas_storage` inventory, so `host_prep` alone owns its creation,
permissions, and disaster-recovery classification. The service validates the
effective source, including the adoption source, before any runtime file
mutation. Authoritative authorization responses must report the configured
`Europe/Berlin` timezone; that derived field is verified but never patched.

## Beszel

The role distinguishes platform capability from application health.

The Mac proof requires recent, nonempty Core, Disk, and Containers telemetry.
GPU telemetry is neither configured nor required because a Linux container in
Docker Desktop cannot observe the Apple GPU as a native Linux DRM device.

The AS6704T deployment requires recent, nonempty Core, Disk, Containers, and
Intel GPU telemetry. The Intel agent keeps `/dev/dri/renderD128`, the Intel
agent image, the socket proxy, and both volume capacity mounts. Verification
checks persisted telemetry collections and their category-specific fields; a
healthy agent container alone is insufficient.

## Dozzle

Disposable isolation continues to use unique Compose project names and
container names. UI grouping is made independent of those names with the
supported `dev.dozzle.group` label.

Every container in a multi-container stack receives its stable service group:

- `beszel`
- `dozzle`
- `immich`
- `paperless`

Single-container services retain Dozzle's ordinary Running Containers group.
The contract inspects effective Docker labels and verifies that every member of
each multi-container stack has exactly the expected group. This produces the
short left-side group names without weakening proof isolation.

## Immich managed-user preferences

The encrypted `vault_managed_users.immich` array remains the source of managed
user identity, password, display name, and quota; it does not gain nonsecret
preferences. Profile definitions live in normal inventory under
`immich_managed_user_preference_profiles`. A normal-inventory mapping named
`immich_managed_user_preference_profile_by_email` selects a profile for a
managed email and defaults every unmapped managed user to `standard`. An
optional `immich_managed_user_preference_overrides` mapping, also keyed by
managed email, overrides individual leaves without duplicating credentials.

The `standard` profile declares every preference supported by pinned Immich
v3.1.0:

```yaml
albums:
  defaultAssetOrder: desc
avatar:
  color: primary
cast:
  gCastEnabled: false
download:
  archiveSize: 4294967296
  includeEmbeddedVideos: false
emailNotifications:
  enabled: true
  albumInvite: true
  albumUpdate: true
folders:
  enabled: false
  sidebarWeb: false
memories:
  enabled: true
  duration: 5
people:
  enabled: true
  sidebarWeb: false
  minimumFaces: 3
purchase:
  showSupportBadge: true
  hideBuyButtonUntil: "2022-02-12T00:00:00.000Z"
ratings:
  enabled: false
recentlyAdded:
  sidebarWeb: false
sharedLinks:
  enabled: true
  sidebarWeb: false
tags:
  enabled: false
  sidebarWeb: false
```

Before mutation, validation rejects unknown profile names, override emails not
present in the encrypted managed-user array, administrator fields, and keys
outside the pinned preference schema. The role uses the administrator endpoint
for the target user's preferences, patches the merged profile, and verifies all
declared leaves. Pinned Immich v3.1.0 splits `avatar.color` from the preference
document: the update DTO accepts that spelling, but the preference response and
persistence projection omit it, while the supported administrator user document
durably exposes the same value as `avatarColor`. The role therefore translates
only that policy leaf to a separate drift-only `PATCH /admin/users/:id`, verifies
it with an authoritative `GET /admin/users/:id`, and sends every other leaf
through `GET/PATCH /admin/users/:id/preferences`. It does not authenticate as
each user to configure settings. Legitimate pinned preference leaves omitted by
a selected partial profile, plus unrelated user properties, remain untouched
during adoption; unknown preference keys are not used as persistence sentinels.

## Jellyfin

### Identity, branding, and libraries

The primary administrator is reconciled to the exact case-sensitive username
`Yonatan`. Before deployment, `vault_jellyfin_admin_username` in the external
deployment vault must also be changed to `Yonatan`; its password is preserved.
A conflicting separate `Yonatan` account or multiple matches fail; the role
does not merge accounts. The server name is `Yonflix 2.0`.

The supplied `/Users/yonatankarp-rudin/Documents/upscale.jpeg` is copied into
the repository as `roles/jellyfin/files/yonatan-avatar.jpeg`. The role uploads
it through `POST /UserImage?userId=...` when the current image tag or returned
content hash differs, then verifies that the administrator has an image and
that the served content matches the repository asset.

Jellyfin has exactly these two Ansible-managed media-library declarations:

| Name | Collection type | Container path |
| --- | --- | --- |
| Movies | `movies` | `/media/Movies` |
| Shows | `tvshows` | `/media/Series` |

Adoption identifies an owned library primarily by normalized path and then
reconciles its name and options. Duplicate path matches or a desired name bound
to another path fail. Other adoption libraries are preserved but remain
unmanaged. Collections are auto-created by Jellyfin and are not declared or
reconciled by Ansible.

### Hardware acceleration

The AS6704T Compose variant passes `/dev/dri/renderD128` into Jellyfin. The role
reads the current named `encoding` configuration, preserves unrelated fields,
and owns this Jasper Lake policy:

- acceleration type `qsv` and device `/dev/dri/renderD128`;
- hardware decoding for H.264, HEVC, MPEG-2, VC-1, VP8, and VP9;
- HEVC 10-bit and VP9 10-bit decoding enabled;
- hardware encoding enabled;
- HEVC encoding enabled and AV1 encoding disabled;
- Intel low-power H.264 and HEVC encoding enabled; and
- VPP tone mapping enabled while generic OpenCL tone mapping remains disabled.

Preflight requires the render device. Verification runs the Jellyfin FFmpeg
hardware-device probe and checks the effective encoding configuration. On Mac,
the role owns a CPU fallback: acceleration `none`, no required render device,
and no GPU proof requirement.

### Plugins

The package repository list is merged by URL. It must contain the enabled
Jellyfin stable repository and the enabled Intro Skipper repository at
`https://intro-skipper.org/manifest.json`. Unrelated repositories are
preserved; duplicate URLs fail.

The role ensures that `Intro Skipper` and `Open Subtitles` are installed. It
requests the latest compatible catalog version only when a plugin is absent.
It never supplies a version to the install API, downgrades a plugin, or rewrites
an installed version. Jellyfin's scheduled plugin updater owns subsequent
versions.

If installation reports that a restart is required, the role performs one
controlled container restart, waits for health, authenticates again, and
re-reads the installed plugin list. The role then configures the OpenSubtitles
plugin with `vault_jellyfin_opensubtitles_username` and
`vault_jellyfin_opensubtitles_password` through the installed plugin's
configuration API. Both values are required non-placeholder vault fields.
Verification checks configuration presence and a successful plugin credential
validation response without retaining either value.

## Komga

The declared library name changes from `Books` to `Comics`. Fresh creates
`Comics`. Adoption matches the managed library by normalized root path `/data`
and renames it in place, preserving its identifier and content. More than one
path match, or a separate `Comics` library at another path, fails before
mutation. Existing library scanning and format settings remain owned as before.

## ntfy synchronized subscriptions

ACL access and account subscription state are separate contracts. Every
interactive entry in `vault_managed_users.ntfy` that has read access to
`nas-critical` receives a synchronized account subscription:

```yaml
base_url: "{{ ntfy_base_url }}"
topic: nas-critical
```

The role authenticates as that managed user and reads `GET /v1/account`. It
posts to `/v1/account/subscription` only when the exact base URL and topic are
absent. One exact match is success, and unrelated subscriptions are preserved.
Multiple exact matches fail. HTTP 409 is accepted only after a fresh account
read proves that the desired subscription now exists, covering a concurrent
create safely.

Verification authenticates every applicable managed user and confirms the
subscription in the account response. This guarantees that the topic appears
after an authenticated UI synchronizes on another browser or device.

Browser notification permission and Web Push endpoint enrollment remain
client-device state. The role does not fabricate browser permission or push
endpoint records.

## Paperless mail and storage

The existing Gmail mail account and mail rule remain declarative. The
credential probe uses Paperless's synchronous mail-account test response as its
success signal. Before and after the probe, it confirms that the managed mail
account and rule records themselves were not created, removed, or altered by
the test. It does not compare document counts or the global task table, because
unrelated consumers and scheduled `mail_fetch` jobs may legitimately change
those global resources while the synchronous test runs.

Only after the credential probe succeeds may the role persist or repair the
managed mail account and rule. Verification checks the exact nonsecret account
and rule fields, uniqueness, enabled state, and association with the managed
account. Credentials remain redacted.

Effective storage ownership is:

| Data | Host volume |
| --- | --- |
| Originals and archive | `/volume2/Documents/archive` |
| Consume inbox | `/volume2/Documents/inbox` |
| Export output | `/volume2/Documents/export` |
| PostgreSQL, Redis, application data, caches, and OCR models | `/volume1/Docker/paperless-ngx` |

Contracts inspect the effective container mounts and Paperless paths, rather
than merely checking inventory strings. They reject any document-bearing mount
whose source resolves under volume1. Paperless tags are neither created,
exported, merged, backed up, nor verified by Ansible in this change.

## Container image refresh

The implementation updates these stable image releases:

| Image | Current | Desired |
| --- | --- | --- |
| `amir20/dozzle` | `v10.6.14` | `v10.7.1` |
| `gotson/komga` | `1.25.0` | `1.26.1` |
| `gotenberg/gotenberg` | `8.34` | `8.35.0` |
| `tinymediamanager/tinymediamanager` | `5.3.0` | `5.3.1` |

Gotenberg 8.35.0 is required because it contains upstream archive-path and
scope-matching security fixes. The other application and dependency images
were current for their selected release lines on 2026-08-11 and remain
unchanged.

Each updated reference contains the exact version tag and registry-provided
immutable multi-architecture manifest digest. The resolver verifies `amd64` and
`arm64` coverage before the reference is committed. All occurrences of the
tinyMediaManager image, including Mac and integration overrides, move together.
The image refresh passes policy checks, Compose rendering, service contracts,
fresh proof, and adoption proof; a successful pull alone is not acceptance.

## Error handling and idempotence

An API response outside the explicitly accepted status set, malformed response,
missing capability, unsupported schema, failed credential validation, or
ambiguous match stops the role. No direct database or config-file fallback is
attempted.

Every mutation is followed by an authoritative read. A second full Ansible run
must report zero changes. Drift hooks alter each newly owned category and prove
that reconciliation repairs only the managed leaves while sentinel unmanaged
state survives.

## Fresh and adoption acceptance

Both lanes verify:

- authentication for every primary and managed account without printing
  credentials;
- Audiobookshelf settings and automatic backup policy;
- Dozzle group labels and resulting group names;
- Immich non-admin status and the complete selected preference profile;
- Jellyfin username, avatar, server name, libraries, platform hardware policy,
  repositories, plugins, and OpenSubtitles configuration;
- Komga's `Comics` library with no duplicate at the managed root;
- the synchronized ntfy `nas-critical` subscription for each eligible managed
  user;
- Paperless mail configuration and effective volume2 document mounts; and
- service health and persistence after recreation.

Beszel expectations remain platform-specific: Core, Disk, and Containers on
Mac; Core, Disk, GPU, and Containers on the NAS.

Adoption additionally seeds unmanaged sentinel records and verifies their
preservation after reconciliation, idempotence, recreation, and rollback.

## Manual-validation handoff

The Mac runner gains `--manual-validation`, valid only for the fresh lane and a
full unselected-phase run. It executes through `verify`, marks the sandbox for
preservation, releases the integration lock, and exits successfully before
`idempotence`, `drift`, `reconcile`, `recreate`, `persistence`, `report`, and
`cleanup`.

The handoff prints:

- the sandbox and report roots;
- every service URL;
- the nonsecret primary and managed usernames for each service;
- an exact resume command using `--sandbox`; and
- an exact cleanup command.

It never prints passwords. The operator retrieves those from the encrypted
source already supplied to the run.

The requested proof therefore starts as:

```sh
tests/mac/run.sh \
  --lane fresh \
  --manual-validation \
  --vault-file "$HOME/.config/nas-platform/vault.yml" \
  --vault-password-file "$HOME/.config/nas-platform/vault-password"
```

After manual acceptance, the printed resume command supplies the same external
vault inputs and `--sandbox` path. The runner skips completed phases and
continues at idempotence. Cleanup remains an explicit operator action until the
resumed proof reaches its cleanup phase.

## Upstream interface references

- Dozzle custom group label:
  <https://dozzle.dev/guide/container-groups>
- Beszel GPU support:
  <https://beszel.dev/guide/gpu>
- ntfy synchronized account subscriptions:
  <https://github.com/binwiederhier/ntfy/blob/v2.27.0/server/server_account.go>
- Jellyfin Intel acceleration:
  <https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/intel/>
- Intro Skipper repository and installation:
  <https://github.com/intro-skipper/intro-skipper/wiki/Installation>
- Gotenberg 8.35.0 security release:
  <https://github.com/gotenberg/gotenberg/releases/tag/v8.35.0>

## Non-goals

- Managing, merging, or backing up Paperless tags.
- Exposing an Apple GPU to the Linux Beszel or Jellyfin containers on Mac.
- Creating Jellyfin Collections explicitly.
- Pinning or downgrading Jellyfin plugin versions.
- Deleting unmanaged adoption state.
- Automating browser notification permission or device-specific Web Push
  enrollment.
