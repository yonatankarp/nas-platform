# Media acquisition platform design

## Status

Approved on 2026-08-21. This document supersedes the unmerged
`2026-08-18-media-acquisition-design.md` on
`origin/docs/media-acquisition-design`.

## Goal

Add automated acquisition for movies, series, subtitles, trailers, YouTube,
comics, ebooks, and audiobooks without weakening the platform's existing
contracts for declarative credentials, immutable releases, storage ownership,
resource controls, monitoring, recovery, selective CI, or disposable Mac
proofs.

Usenet is the initial transport. Torrent support is added later and proved in
parallel before Usenet is optionally retired. The library never moves during
that transition.

## Decisions

| Area | Decision |
|---|---|
| Movies and series | Radarr and Sonarr |
| Indexers | Prowlarr; provider choice remains operator-owned |
| Subtitles | Bazarr from the initial phase |
| Existing subtitle plugin | Remove Jellyfin Open Subtitles after Bazarr is proved |
| Declarative profiles | Configarr |
| Initial downloads | SABnzbd with Unpackerr |
| Later downloads | qBittorrent behind Gluetun, added beside SABnzbd |
| Trailers | Trailarr; the archived Jellyfin TMDb Trailers plugin is not used |
| YouTube | Pinchflat |
| Comics and manga | Kapowarr |
| Ebooks and audiobooks | Bindery |
| Requests | Seerr, with immediate approval for the two declared household users |
| Existing metadata manager | Retire tinyMediaManager after a controlled handoff |
| Existing readers | Jellyfin, Komga, and Audiobookshelf remain read-only readers |
| Remote access | Existing mesh VPN and `platform_public_host`; no public ingress |

Readarr is not included because it is retired. Calibre-Web Automated,
Listenarr, and separate ebook/audiobook managers are not included because
Bindery covers both acquisition paths with one metadata model and one set of
download-client integrations. Youtarr is not included because Pinchflat is a
smaller, self-contained filesystem integration and native Jellyfin playlist
mirroring is not required.

## Compose boundaries

The design uses lifecycle-oriented Compose projects. Closely coupled
components share a project; optional writers and user-facing applications have
independent projects.

```text
services/
├── arr/             Radarr, Sonarr, Prowlarr, Bazarr, and the Configarr job
├── downloaders/     SABnzbd, Unpackerr; later Gluetun and qBittorrent
├── bindery/         Bindery
├── kapowarr/        Kapowarr
├── pinchflat/       Pinchflat
├── trailarr/        Trailarr
└── seerr/           Seerr
```

Each directory has one manifest entry, one Ansible role, one long-running
Compose project, one platform verification tag, and one service-owned CI suite.
This produces seven new manifest entries rather than one entry per container or
one all-encompassing media stack. Configarr is declared in
`services/arr/compose.yml` under a `jobs` Compose profile. A profiled service is
never started by the project deployment, so the job stays out of the
long-running service set while remaining inside the file the static contracts
actually read.

A separate `arr/compose.jobs.yml` was considered and rejected.
`roles/deployment_bundle/tasks/main.yml` ships exactly `compose.yml` and
`compose.{{ platform_compose_kind }}.yml` for each service, plus two named
per-file exceptions, so a third Compose file would never reach the deployed
release and the job could not run on the NAS at all. The compose policy block in
`tests/policy_test.rb` also opens `compose.yml` alone, so the job would silently
escape digest pinning, `cpuset`, its CPU ceiling, bounded logging, and
volume-source parameterization, while the `services/*/compose.*.yml` override
loop would fail it for having no canonical image to match.

One project per container would create unnecessary role, CI, and networking
overhead. One project for the entire subsystem would couple independent
writers, upgrades, health, and recovery. The selected boundaries keep the
functional `arr` and downloader units together while preserving independent
lifecycle control for the remaining services.

`community.docker.docker_compose_v2` remains the deployment mechanism for
long-running projects. Every role consumes `platform_service_compose_files`,
uses a project name derived from `platform_project_name`, revalidates its
deployed release and runtime paths, and verifies its effective container CPU
policy. The sole job-container exception is Configarr, which Ansible runs with
`community.docker.docker_compose_v2_run` following the existing one-shot
precedent in `roles/ntfy/tasks/main.yml`.

## Shared control network

`host_prep` creates an external bridge network before any service deployment.
Its name derives from `platform_project_name`, so disposable Mac runs can
coexist without collisions. Every participating Compose file declares it as an
external network through a required environment value:

```yaml
networks:
  media-control:
    external: true
    name: ${PLATFORM_MEDIA_NETWORK:?}
```

The control network carries only service API traffic. It provides stable names
such as `radarr`, `sonarr`, `prowlarr`, `sabnzbd`, and `audiobookshelf` across
Compose projects. Cross-project `depends_on` is not attempted; Ansible owns
deployment order and waits for every upstream readiness endpoint before it
configures a downstream integration.

The existing Jellyfin and Audiobookshelf Compose definitions also join this
network: Seerr needs Jellyfin's API and Bindery needs Audiobookshelf's API.
Their existing host publications and read-only media mounts remain unchanged.
Komga does not join because discovery is schedule-driven rather than called by
a new service.

Only user-facing interfaces receive host port mappings. Configarr and Unpackerr
publish no ports. Host publication follows the existing platform pattern;
application-to-application calls use the control network instead of published
host ports.

## Storage and ownership

The existing `{{ nas_media_root }}/Media` and `{{ nas_media_root }}/Books` NAS
shares remain separate.
That boundary allows different users to receive different share permissions.
The acquisition layout preserves it while keeping each import source on the
same filesystem and in the same container mount as its destination.

```text
{{ nas_media_root }}/
├── Media/
│   ├── .acquisition/
│   │   ├── usenet/{movies,series,audiobooks}/
│   │   └── torrents/{movies,series,audiobooks}/
│   ├── Movies/
│   ├── Series/
│   ├── Audiobooks/
│   └── YouTube/
└── Books/
    ├── .acquisition/
    │   ├── usenet/{ebooks,comics}/
    │   └── torrents/{ebooks,comics}/
    ├── Ebooks/
    └── Comics/
```

NAS ACLs deny ordinary SMB users access to the `.acquisition` trees. Their dot
prefix is a convenience, not the security boundary. Because CI cannot prove a
NAS ACL, the denial is a manual NAS acceptance check. These trees are
regenerable working state and have `recovery: cache`. Final libraries remain
NAS-owned user data with `recovery: user`; Ansible creates their directories
without claiming owner or group.

Two spellings of the same root appear in this document by design. Compose
volume sources must use `${NAS_MEDIA_ROOT:?}` and `${NAS_DOCKER_ROOT:?}`, which
the compose policy enforces by rejecting any hardcoded `/volume<n>` source; the
Jinja `{{ nas_media_root }}` form belongs in the storage inventory, role
variables, and prose about host paths.

Writers see a parent that contains both their source and destination:

| Writer | Writable Compose mount |
|---|---|
| Radarr and Sonarr | `${NAS_MEDIA_ROOT:?}/Media:/data/media` |
| Bazarr | Movies and Series through the same `/data/media` namespace |
| Trailarr | Movies and Series; writes only `Trailers/` children |
| Pinchflat | `${NAS_MEDIA_ROOT:?}/Media/YouTube` |
| Bindery | `${NAS_MEDIA_ROOT:?}/Books` and `${NAS_MEDIA_ROOT:?}/Media/Audiobooks` |
| Kapowarr | `${NAS_MEDIA_ROOT:?}/Books` |

Download clients see only `.acquisition` bind sources, mounted at the exact
paths reported to importing applications. For example, SABnzbd may see the host
books acquisition directory as `/data/books/.acquisition`; Bindery sees the
entire host Books share as `/data/books`. Both therefore refer to an ebook as
`/data/books/.acquisition/usenet/ebooks/<file>` while Bindery can import it to
`/data/books/Ebooks/...`.

Jellyfin, Komga, and Audiobookshelf retain read-only media mounts. No reader
becomes a second library writer.

### Shared filesystem identity

Every container that exchanges acquisition or library files runs as the
platform's already-declared filesystem identity, `nas_uid` and `nas_gid` from
`inventory/group_vars/all/main.yml`, currently `1000` and `100`, with an
effective umask of `022`. This design does not introduce a media-specific
identity constant. The numbers are not written into Compose files: they reach a
container as `${NAS_UID:?}` and `${NAS_GID:?}`, which `services/ntfy/compose.yml`
and `services/dozzle/compose.yml` already do. The reasoning is the same one that
forbids hardcoded `/volume<n>` volume sources, and it is what keeps the Mac lane
and the NAS reading one source of truth.

The implementation selects the mechanism supported by each image:

| Containers | Identity mechanism |
|---|---|
| Radarr, Sonarr, Prowlarr, Bazarr, SABnzbd, qBittorrent | `PUID=${NAS_UID:?}`, `PGID=${NAS_GID:?}`, `UMASK=022`; do not override the s6 init user |
| Trailarr and Kapowarr | Image-supported `PUID` and `PGID` from the same variables; set an image-supported umask when available, otherwise verify created modes |
| Unpackerr | `user: "${NAS_UID:?}:${NAS_GID:?}"` plus explicit file mode `0644` and directory mode `0755` |
| Bindery | `user: "${NAS_UID:?}:${NAS_GID:?}"`; `BINDERY_PUID` and `BINDERY_PGID` are sanity checks, not privilege switching |
| Pinchflat | `user: "${NAS_UID:?}:${NAS_GID:?}"` |
| Configarr job | `user: "${NAS_UID:?}:${NAS_GID:?}"` |

Seerr writes only its critical configuration and uses the selected image's
supported non-root mechanism; it is not part of the hardlink contract. Gluetun
mounts no download or library path and is exempt from the shared media identity;
qBittorrent owns the files. Integration and NAS acceptance read back effective
UID/GID, inspect representative `0644` files and `0755` directories, and prove
that the importing application can create, modify, and remove client-created
files. NAS ACLs grant `nas_uid`/`nas_gid` the required rights; `host_prep` does
not recursively chown NAS-owned media.

## Stateful application contract

Ansible owns Compose definitions, external paths, initial credentials,
inter-service connections, declared profiles, permissions, ports, health
checks, and selected stable settings. The applications own their continuously
mutated databases, queues, histories, monitoring selections, matches, and
download records.

Configarr narrows this exception for Radarr, Sonarr, and Prowlarr by applying
naming, quality, and custom-format configuration from repository-owned files.
It does not make the applications' SQLite databases disposable.

Every application config directory is stored below
`{{ nas_docker_root }}/<service>` and classified `recovery: critical`. A role
refuses silent fresh initialization when its critical state is absent while the
corresponding final library is nonempty. Recovery then requires an explicit
state restore or a controlled adoption run with
`media_acquisition_adopt_existing_libraries: true`.

That input defaults to `false`, is never stored as a permanent host setting,
and bypasses the guard for one convergence only. During adoption, automatic
monitoring and renaming remain disabled until existing items have been matched
and reviewed. Phase 1 deliberately uses this lane for the existing Movies and
Series libraries; later Bindery or Kapowarr adoption uses the same contract.
The Mac fresh lane starts with empty libraries and keeps the input false, while
a separate adoption lane seeds representative existing files, proves the guard
fails without the input, then proves the controlled adoption path.

This includes the later qBittorrent configuration. Download payloads,
incomplete work, unpack directories, and client caches remain under the
per-share `.acquisition` trees and are not critical state.

## Service design

### `arr`

The long-running `arr` project contains Radarr, Sonarr, Prowlarr, and Bazarr.
Radarr owns Movies, Sonarr owns Series, Bazarr owns subtitle sidecars, and the
repository owns Configarr's profile inputs. Prowlarr synchronizes indexers to
Radarr and Sonarr and supplies indexers to Bindery.

Configarr is a one-shot job, not a daemon. It is declared in the `arr` Compose
file under the `jobs` profile with no restart policy, health check, Dozzle event
expectation, or published port, and the role invokes it with
`community.docker.docker_compose_v2_run`. The invocation mirrors the repository's
existing one-shot precedent at `roles/ntfy/tasks/main.yml`: `service: configarr`,
the role's `platform_service_compose_files` entry, `cleanup: true`,
`no_deps: true`, `service_ports: false`, and `interactive: true` with
`tty: false`, because the pinned Compose version does not accept the
`--no-interactive` flag that `interactive: false` produces.

Two properties of that module drive the rest of the contract. It does not
support check mode, so Ansible skips the task under `--check`; the role therefore
guards it with `not ansible_check_mode` and reports the predicted change through
the repository's existing planned-change idiom so the Mac check-mode lane still
proves something. And Compose interpolation runs against the newly published
bundle while the on-disk `.env` can still be the previous deployment's, so the
task supplies `PLATFORM_CONTAINER_CPUSET` in its own environment rather than
relying on the rendered file, exactly as the ntfy listing does.

The role treats a nonzero exit as deployment failure, captures bounded output
redacted of the arr API keys Configarr echoes, and then reads the arr APIs to
verify the desired profiles. The one-shot class is exempt only from the
long-running assertions that cannot apply to it: `restart: unless-stopped`, the
health check, and the Dozzle event expectation. It keeps the digest-pinned
image, `cpuset`, an explicit CPU ceiling, bounded `json-file` logging, and
parameterized volume sources, because it sits in the same Compose file those
checks already read. The exemption is keyed on a declared job set rather than on
a filename, so adding a second job cannot widen it by accident.

Bazarr is part of the initial deployment rather than an optional later phase.
It replaces the unreliable Jellyfin Open Subtitles plugin and removes that
plugin's Ansible reconciliation. Bazarr uses the same media paths as Radarr and
Sonarr, so path mappings are unnecessary.

Bazarr language profiles and provider credentials are declared inventory and
vault inputs. Their exact values are operator content preferences rather than
Compose or storage architecture; changing them does not alter this design.

tinyMediaManager is retired because its useful automation requires a recurring
license and overlaps the declarative arr workflow. During its handoff, Radarr
may temporarily publish a non-default host port because tinyMediaManager
currently occupies 7878; that conflict is a migration detail, not the reason
for retirement. Both applications must never write the same library
concurrently. The handoff stops tinyMediaManager before Radarr or Sonarr
receives write access.

Posterizarr is rejected because it duplicates artwork and metadata ownership
already assigned to the library managers. Tdarr is rejected because transcoding
is not an acquisition requirement and rewriting imported media could break the
hardlink between a torrent payload and its seeded library file.

The initial Configarr quality policy is HD Bluray + WEB at 1080p for both
Radarr and Sonarr. UHD is a per-item Radarr exception rather than a second
automatically populated library. Naming and custom-format definitions are
taken from the current TRaSH definitions when implemented instead of copying
time-sensitive strings into this document.

### `downloaders`

The initial project contains SABnzbd and Unpackerr. Categories are `movies`,
`series`, `ebooks`, `audiobooks`, and `comics`, with completed paths matching
the `.acquisition/usenet` layout. Incomplete work remains under an acquisition
tree and never uses `{{ nas_docker_root }}`, whose failure would affect
application databases.

SABnzbd cache and concurrent-job settings are explicitly bounded. Unpackerr
uses vault-authored Radarr and Sonarr API keys and has no published port.

The host-scoped booleans `media_usenet_enabled` and `media_torrent_enabled`
select transports. Initially Usenet is true and torrent is false. The later
torrent change adds Gluetun and qBittorrent to the same project under the
`torrent` Compose profile. qBittorrent uses
`network_mode: service:gluetun`; Gluetun publishes its Web UI and peer ports and
joins `media-control`. Torrent categories write beneath the per-share
`.acquisition/torrents` paths. Prowlarr can retain Usenet and torrent indexers
simultaneously, and importing applications can retain both download clients
during the proving period.

Mac and integration runs leave the `torrent` profile disabled and therefore
need no fake VPN credentials; their CPU and service-set checks receive the
active service list. Static tests still validate the profiled Compose
definition. VPN routing and containment remain NAS-only acceptance because the
disposable Mac lane cannot establish the production tunnel.

This is a client cutover, not a library migration. Usenet is retired only after
the torrent path has passed representative import, permission, and hardlink
proofs.

### Trailarr

Trailarr is an independent project deployed after Radarr and Sonarr. The
archived Jellyfin TMDb Trailers plugin is not used. Trailarr may create and
manage only a `Trailers/` subdirectory beneath each Radarr- or Sonarr-owned item
directory. It does not rename media, rewrite primary metadata, or manage other
extras.

Because Trailarr runs as the same filesystem identity and needs a writable
Movies/Series bind, the bind mount cannot enforce that subdirectory boundary.
It is a logical application boundary, verified through Trailarr configuration
and representative behavior; Trailarr technically has write access to the
mounted libraries.

Initial monitoring is restricted to one selected title. General monitoring is
enabled only after Jellyfin recognizes the resulting local trailer correctly.

### Pinchflat

Pinchflat is a self-contained project with a writable YouTube library and no
Jellyfin API dependency. It writes media-center-compatible files and local
metadata beneath `{{ nas_media_root }}/Media/YouTube`; Jellyfin reads them
through a dedicated library.

The initial source is one channel or playlist with an explicit cutoff date and
defined policies for Shorts, livestreams, retention, subtitles, and
SponsorBlock. Broader subscriptions are enabled only after one download is
verified in Jellyfin.

### Kapowarr

Kapowarr owns `{{ nas_media_root }}/Books/Comics` and its comic metadata and
filenames. Komga retains read-only access. Its ComicVine credential is authored
in vault. Kapowarr may use direct downloads initially and joins `media-control`
for any configured Prowlarr or download-client integration.

Monitoring starts with one selected series or volume. Komga must discover the
result before general monitoring is enabled.

### Bindery

Bindery is the single acquisition manager for ebooks and audiobooks. It uses
SQLite, Prowlarr, SABnzbd initially, and qBittorrent later. Ebook and audiobook
formats have separate destination roots and download categories.

Bindery writes ebooks to `{{ nas_media_root }}/Books/Ebooks` and audiobooks to
`{{ nas_media_root }}/Media/Audiobooks`. It requests an Audiobookshelf library
scan after an audiobook import. Komga changes from its current single `/data`
library to two exactly reconciled libraries: Comics rooted at `/data/Comics`
and Ebooks rooted at `/data/Ebooks`. Both receive a conservative six-hour scan
schedule. The sibling `/data/.acquisition` tree therefore sits outside both
library roots; a `.acquisition` scan exclusion is also declared as
defense-in-depth. The Komga reconciliation contract changes from one pinned
library to this exact two-library model.

That change cannot be reached by converging the new desired state, and the
migration is part of this design rather than an implementation detail. The
deployed library is named `Comics` and rooted at `/data`. Komga's reconciliation
refuses to proceed when a library matching the desired name has a different
root, and its repair payload can only patch a library that was resolved by root,
which is impossible when the root is the thing that changed. A plain converge
therefore aborts with nothing mutated.

The role gains a one-convergence input, `komga_library_root_migration_allowed`,
defaulting to `false` and never stored as a permanent host setting, matching the
adoption input used for the existing Movies and Series libraries. With the input
set, reconciliation may repair the root of a library matched by name; the Ebooks
library is created new in the same run. The comic files keep their absolute
paths, so this is a narrowing of the library root rather than a file move, but
whether Komga preserves read progress across a root change is not established
here. The migration therefore backs up Komga's critical state first, runs before
Bindery is granted write access, and treats read progress on a known-partial
series as an explicit post-migration check; if it is lost, the fallback is to
restore the backup and keep one library scoped to `/data` with a `.acquisition`
scan exclusion. The Mac lane proves both halves: that the guard refuses the root
move without the input, and that the migration completes with it.
`tests/komga_library_reconciliation_test.rb` is rewritten against the
two-library model as part of this slice.

Bindery uses its image's built-in `/bindery healthcheck`, which verifies
`/api/v1/health`; its role also reads the API during integration verification.
Because one single-maintainer application holds critical acquisition state for
two library types, its state is backed up before every upgrade and an upgrade
does not proceed unless that backup succeeds.

Unattended auto-grab is disabled initially. One ebook and one audiobook must
complete search, download, import, naming, reader discovery, and playback
before author monitoring or automatic grabs are enabled.

### Seerr

The request frontend is Seerr, the maintained successor to Jellyseerr and
Overseerr. It is an independent project deployed only after the Radarr/Sonarr
path is stable.

Seerr imports the two declared Jellyfin household identities. Both users may
request movies and series with immediate automatic approval and no quota. The
owner remains the Seerr administrator; the second user receives request and
auto-approval permissions without service-administration permissions. Newly
discovered Jellyfin users do not inherit these permissions automatically.

Seerr uses `media-control` for Jellyfin, Radarr, and Sonarr API traffic. Its
user-facing URL is:

```yaml
seerr_app_url: "http://{{ platform_public_host }}:{{ seerr_port }}"
```

The published host port is reached through the existing mesh VPN in the same
way as other platform services. This work adds no reverse proxy, router port
forward, public DNS, TLS termination, or Internet ingress.

Seerr receives an explicit service-owned integration check: its role verifies
the declared Jellyfin server, both arr connections, and the two-user permission
split through the API rather than stopping at HTTP health.

## Secrets and identities

Credentials are authored in Ansible Vault and flow one way into applications.
The required set includes administrator credentials where an application needs
them, deterministic API keys for inter-service access, download-client
credentials, the ComicVine key, and the two explicit Seerr permission
identities.

Every new key follows the complete vault contract: sanitized example,
plain-vault template, vault role argument specification, service role argument
specification, validation assertion, ephemeral test vault, expected-key policy,
generation recipe where safe, and secrets documentation. Tasks that handle
credentials use `no_log: true`.

The implementation must not start an application, scrape a generated key from
its database or UI, and persist it back into repository state. When an
application accepts a preseeded configuration file, Ansible supplies the
vault-authored value before first start. Otherwise the role uses a supported
local bootstrap API that accepts the declared value.

## Resource policy

Every long-running container has a digest-pinned image with a human-readable
version tag, `cpuset: ${PLATFORM_CONTAINER_CPUSET:?}`, an explicit `cpus`
ceiling, `restart: unless-stopped`, bounded `json-file` logging, a Dozzle
display label, and a meaningful health check. The Configarr job follows the
separate one-shot policy defined under `arr`.

Initial CPU ceilings are:

| Container | CPUs |
|---|---:|
| Radarr | 1.0 |
| Sonarr | 1.0 |
| Prowlarr | 0.5 |
| Bazarr | 1.0 |
| SABnzbd | 2.0 |
| Unpackerr | 1.0 |
| Bindery | 1.0 |
| Kapowarr | 1.0 |
| Pinchflat | 1.0 |
| Trailarr | 1.0 |
| Seerr | 1.0 |
| Configarr, job | 0.5 |
| Gluetun, later | 0.5 |
| qBittorrent, later | 1.5 |

The Configarr row is not optional. The CPU contract asserts that its map covers
the exact Compose service set of each file, and a profiled service is still a
service in that file, so the job is listed here rather than described in
prose.

These are ceilings rather than reservations. The implementation adds the exact
container map to the platform CPU contract and verifies the effective runtime
values after every deployment. SABnzbd's article cache and qBittorrent's disk
cache are configured explicitly rather than left proportional to available
RAM. This design does not create a new-service-only `mem_limit` convention;
container memory ceilings require a separate platform-wide policy if Beszel
evidence shows they are needed. Beszel headroom is checked before enabling
unattended acquisition and again before adding the torrent containers.

## Monitoring and notifications

Every long-running container has a service-specific health check. Existing
Dozzle Docker-event rules therefore publish unhealthy, recovery, and OOM events
through the authenticated alert relay to ntfy without a parallel alerting
system. Beszel continues to cover system and container resource pressure.

Seerr uses its native ntfy support for request events. Other application-level
completion notifications are optional and do not block the first release;
platform health notifications are mandatory. A failed download is represented
in the owning application's queue and history rather than translated into a
second custom notification relay.

## Deployment order

The steady-state role order is:

1. preflight, vault contract, host preparation, deployment bundle;
2. ntfy, Beszel, and Dozzle;
3. Audiobookshelf and Komga readers;
4. `arr`, followed by its synchronous Configarr job;
5. `downloaders`;
6. Bindery, Kapowarr, and Pinchflat;
7. Trailarr;
8. Jellyfin;
9. Seerr;
10. unrelated existing services.

Each downstream role waits for the upstream APIs it consumes. Verification
roles remain inert under `verify.yml` except when selected by their
`platform_verify_<service>` tag.

## Rollout and rollback

### Phase 0: foundation

Create the external control network, `.acquisition` paths, final library paths,
vault keys, storage classifications, release-bundle inputs, CPU contract, and
service-owned CI suites. No acquisition is enabled.

### Phase 1: movies, series, and subtitles over Usenet

Deploy `arr` plus SABnzbd and Unpackerr with
`media_acquisition_adopt_existing_libraries: true` for this convergence only.
Add the existing Movies and Series roots with renaming and automatic monitoring
disabled. Match and review existing items, stop tinyMediaManager, then grant
Radarr and Sonarr write access. Apply naming and quality configuration through
the synchronous Configarr job and perform a controlled rename.

Prove one new movie and episode end to end. Prove Bazarr sidecar subtitles in
the required languages, then remove the Jellyfin Open Subtitles plugin. Keep
the stopped tinyMediaManager state until the handoff is accepted; rollback
stops Radarr/Sonarr writers before restarting tinyMediaManager.

### Phase 2: additional libraries

Migrate Komga to the two-library model with
`komga_library_root_migration_allowed: true` for that convergence only, before
Bindery receives write access, and confirm both libraries and their read
progress. Then deploy Bindery, Kapowarr, and Pinchflat. Prove one ebook,
audiobook, comic, and YouTube item before enabling unattended monitoring. Enable
the Komga scan interval and verify the Audiobookshelf scan integration.

### Phase 3: local trailers

Deploy Trailarr, prove one selected movie or series trailer, then enable the
approved monitoring profile.

### Phase 4: requests

Deploy Seerr, import the two Jellyfin users, apply the exact permission split,
and prove an automatically approved movie and series request end to end.

### Phase 5: torrent cutover

Enable `media_torrent_enabled` for a selected location and add Gluetun and
qBittorrent without removing SABnzbd. Add torrent indexers and client
categories, then prove routing, VPN containment, permissions, imports, and
hardlinks for each applicable library. After this phase, each location may
select Usenet, torrent, or both through its host-scoped inputs. A torrent-only
location intentionally waits for Phase 5; this preserves the Usenet-first
delivery order. Retire Usenet only through a later explicit per-location
decision.

## Repository integration and retirement impact

Each service slice must account for more than its Compose and role files:

- every published port updates the hardcoded publication allow-list in
  `tests/policy_test.rb`, service defaults, inventory, Mac variables, and the
  nested `allocate_service_port` call chain in `tests/mac/run.sh`;
- every long-running container updates the exact service and CPU maps in
  `tests/policy_test.rb`, while profiled torrent services are checked against
  the active host service set;
- every service is added to `site.yml` and `verify.yml` with an asserted tag,
  manifest and storage entries, vault plumbing where needed, a contract, and a
  selective CI suite;
- every new host-scoped input, including `media_usenet_enabled` and
  `media_torrent_enabled`, is added to `HOST_SCOPED_VARS` in
  `tests/policy_test.rb`, since a host group's variables may not contain a key
  outside that list; declaring either as a platform capability additionally
  requires both host groups to define it and
  `roles/preflight/meta/argument_specs.yml` to mark it required;
- the one-shot job class adds its own exemption and checks to
  `tests/policy_test.rb`, keyed on a declared job set rather than a filename;
- per-service reconciliation unit tests change with the contracts they pin,
  including `tests/komga_library_reconciliation_test.rb` for the two-library
  Komga model;
- selective routing updates `tests/ci/classify_changes.rb`, its tests, the fixed
  tags in `tests/integration.sh`, `tests/integration_suite_test.sh`, and the
  authoritative `INTEGRATION_SUITES` constant in `tests/ci/workflow_test.rb`;
- retiring Open Subtitles removes its complete vault key chain, Jellyfin role
  inputs and reconciliation tasks, managed-user and plugin contracts, runtime
  probes, and documentation only after Bazarr passes acceptance; and
- retiring tinyMediaManager removes its manifest/storage entries, role,
  Compose definitions, ports, contract, CI routing and suite, Mac lifecycle and
  isolation coverage, and documentation only after the arr handoff is accepted.

## Verification

Every implementation slice follows the repository's test ladder:

```sh
ruby tests/policy_test.rb
tests/validate-policy.sh
ansible-lint --strict
tests/integration.sh --suite <service> site.yml
tests/mac/run.sh --lane fresh --vault-file <path> --vault-password-file <path>
```

The new CI lanes update every current routing contract:

- `tests/ci/classify_changes.rb`;
- `tests/ci/classify_changes_test.rb`;
- the fixed suite tags in `tests/integration.sh`;
- `tests/integration_suite_test.sh`;
- `tests/ci/workflow_test.rb` and its `INTEGRATION_SUITES` constant.

Each service receives either structural tagged verification or a registered
workflow contract under `tests/contracts/registry.yml`. Workflow contracts
cover real API behavior rather than only returning HTTP 200.

The complete Mac lifecycle, with torrent disabled, proves first converge, clean
reconverge, check mode, owned drift repair, critical-state persistence, service
recreation, credential redaction, sanitized reporting, the separate
existing-library adoption lane, and the Komga library root migration in both its
refused and permitted forms. Check mode additionally asserts that the Configarr
job, which its module cannot run under `--check`, still reports its predicted
change rather than passing silently. NAS-only acceptance additionally proves:

- the two NAS shares and their ACL boundary remain intact;
- `.acquisition` is not exposed to ordinary share users;
- representative imports are readable by their serving applications;
- the torrent client has no non-VPN egress;
- source and imported torrent files have the same inode and a link count of at
  least two when hardlinking applies;
- the importing application can modify and delete files created by the client;
- the application's hardlink setting is read back through its API;
- Seerr is reachable through `platform_public_host` over the mesh VPN and is
  not reachable through any newly introduced public ingress.

## Out of scope

- Choosing Usenet providers, indexers, trackers, or content sources.
- Choosing Bazarr subtitle languages and subtitle-provider accounts.
- Public Internet exposure or reverse-proxy deployment.
- A unified request interface for books, comics, audiobooks, or YouTube.
- Music acquisition and a music-serving application.
- Reorganizing the NAS's `Media` and `Books` share boundary.
- Backing up downloaded working files.
- Enabling torrent acquisition in the initial release.

## Acceptance criteria

The design is complete when all new services are represented in the manifest,
immutable deployment bundle, storage inventory, CPU policy, vault contract,
site and verification playbooks, selective CI, Mac lifecycle, monitoring, and
recovery documentation; the approved representative workflows pass; all
reader mounts remain read-only; tinyMediaManager and the Open Subtitles plugin
are retired only after their replacements are proved; and no unresolved
application, storage, access, transport, or trailer choice remains.
