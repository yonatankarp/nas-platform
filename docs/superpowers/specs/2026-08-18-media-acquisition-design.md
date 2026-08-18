# Adding automated media acquisition to nas-platform

## Context

The NAS runs nine Ansible-owned stacks. Media is curated by hand: tinyMediaManager scrapes movie
and series metadata, Jellyfin plays it read-only, Komga serves books and comics read-only,
Audiobookshelf serves audiobooks read-only. Nothing acquires anything. There is no download client,
no indexer, no VPN and no request frontend anywhere in the repository, confirmed by a broad grep
across every file type.

The ask is automated acquisition for movies, series, audiobooks, ebooks, comics, trailers and
YouTube, plus media sources not named. Below is what to include, what has no answer, and what the
repository charges per service.

The headline finding is the cost, not the app list. This repository is not a compose-file
collection. Adding one `status: implemented` service touches a dozen or so files, several of them
hardcoded literal lists in a 2000-line policy test, and one of them (`EXPECTED_FIXTURE_ROLES` in
`tests/policy_manifest_test.rb:104-108`) aborts an entire test suite rather than failing an
assertion when you forget it. Retiring a service costs about the same. So the plan below is
deliberately shorter than the app ecosystem allows, and it groups services into stacks to amortise
that cost.

## Recommendation in one paragraph

Three new manifest entries, not ten. Bundle Radarr, Sonarr, Prowlarr and Bazarr into a single
`arr` stack the way `paperless-ngx` already ships five containers under one entry. Add the download
client with its sidecar (gluetun on the torrent branch, Unpackerr on the usenet branch) as a second
stack. Add Kapowarr for comics as a third. Get YouTube from Youtarr, trailers from either the
Jellyfin plugin or Trailarr but never both, and podcasts free from Audiobookshelf. Say out loud that
ebooks and audiobooks have no answer. Retire tinyMediaManager.

## Conformance to TRaSH Guides

The design follows [TRaSH Guides](https://trash-guides.info/). Three parts of the guide are
load-bearing here and are folded into the sections below rather than restated: the single shared
root that makes hardlinks and atomic moves possible, the permission requirement that makes them
work in practice, and the naming and quality configuration the guide publishes for machine sync.

Deliberately not adopted, because it does not apply to this deployment: the Plex sections (this box
runs Jellyfin), the anime quality profiles and custom formats (no anime library), and per-indexer
tuning beyond API limits, since indexer choice is explicitly out of scope at the end of this plan.
"Follow all of TRaSH" cannot mean literally all of it, and the excluded parts are named here rather
than silently skipped.

One structural deviation is taken knowingly and is described under Storage layout: the guide's root
has `media/` as a sibling of the download trees, and this design flattens the existing media
libraries into the root because they are pre-existing NAS shares. Everything that depends on the
single-root property still holds. What is lost is the ability to hand Jellyfin and Komga a
`media`-only mount, and the mitigation is that every library must be declared per folder.

## The candidate list, adjudicated

Two structural observations about the shortlist before the per-app verdicts.

**Nothing on it downloads movies or TV.** Radarr, Bazarr, Prowlarr, Readarr and Listenarr are all
clients of a download client, and no client was listed. Prowlarr finds a release and hands off a
URL; Radarr waits for a finished file to appear. Kapowarr and Youtarr are the only two that fetch
bytes themselves. If the goal is auto-download rather than better metadata, the client is item one.

**Sonarr is absent.** Series were in the original ask, and tmm is currently the thing managing
`/volume2/Media/Series`. Retiring tmm with Radarr but no Sonarr leaves Series with no metadata
manager at all, and leaves Bazarr covering movie subtitles only.

| Candidate | Verdict |
|---|---|
| Radarr | Include. Phase A |
| **Sonarr** (not listed) | Include. Retiring tmm without it orphans the Series library |
| Kapowarr | Include. Phase A. ComicVine key is a pre-deploy prerequisite |
| Youtarr | Include. Phase A. See the YouTube section for the maintenance trade against Pinchflat |
| Bazarr | Include, lowest priority of the includes. Overlaps the Jellyfin Open Subtitles plugin already running |
| Prowlarr | Include, but Phase B. It does nothing until a download client exists |
| Trailarr | Either/or with the Jellyfin plugin. Defensible; see the Trailers section |
| Readarr | Do not adopt. Archived upstream, so its indexer definitions will never update again |
| Listenarr | Defer. Audiobookshelf integration was an unchecked roadmap item, and it needs Prowlarr plus a client |
| SuggestArr | Defer. Needs a Seerr instance you do not run, and auto-requests fill disks unasked |
| Jellyswarrm | Drop. It federates multiple Jellyfin servers; you have one |

## What to include

### Movies and series

| App | Port | Notes |
|---|---|---|
| Radarr | 7878 | Replaces tinyMediaManager for movies. Scrapes, renames, writes NFO and artwork |
| Sonarr | 8989 | Same for series |
| Prowlarr | 9696 | Shared indexer manager. Also serves anything added later |
| Bazarr | 6767 | Subtitles. Needs Radarr and Sonarr but **not** a download client |

**Bundle these four into one stack**, `services/arr/compose.yml` with four containers, one role
`roles/arr/`, one manifest entry, one `platform_verify_arr` tag whose verification block hits all
four HTTP endpoints. Precedent: `services/paperless-ngx/compose.yml` runs five containers
(broker, db, webserver, gotenberg, tika) under a single manifest entry and a single role.

The reason is arithmetic. Per manifest entry you must touch `services/manifest.yml`,
`EXPECTED_SERVICES` and `EXPECTED_SERVICE_MAPPINGS` (`tests/policy_test.rb:107,111`),
`EXPECTED_FIXTURE_ROLES` (`tests/policy_manifest_test.rb:104`), `EXPECTED_SERVICES` in
`tests/managed_user_capabilities_test.rb:18`, `nas_storage` in
`inventory/group_vars/all/main.yml`, `site.yml`, `verify.yml`, `tests/ci/classify_changes.rb`,
`README.md:20`, and the Mac hook groups under `tests/mac/hooks/`. Four entries means four rounds of
that. One entry means one.

Two updates to this paragraph since it was written. The three parity files it used to name
(`config/portainer-parity.yml`, `tests/portainer_parity_mapping_test.rb`, `docs/portainer-parity.md`)
are gone as of `02d60e2`, so the per-entry cost is genuinely lower than the plan first assessed. It
is not low, and the bundling argument survives intact. And `docs/adding-a-service.md` now documents
the same job, which is the better thing to follow for shape — but **its enumeration is narrower than
this one**: it omits `tests/managed_user_capabilities_test.rb`, `README.md` and the Mac hook groups.
Use the guide, cross-check against this list, and expect the guide to be the copy that goes stale,
since nothing asserts it against the tests it describes.

The cost of bundling: `platform_verify_arr` covers four apps rather than one, a compose restart
touches all four, and CI lane granularity is coarser. Those are acceptable. The four apps are a
single functional unit and are never usefully deployed apart.

Bazarr is a real but not urgent addition, because Jellyfin already has the Open Subtitles plugin
installed and managed (`roles/jellyfin/defaults/main.yml:57-59`). Bazarr is better (per-item
tracking, upgrades over time, sidecar files that survive a Jellyfin rebuild) but it is an upgrade,
not a gap. If the first change needs to be smaller, drop Bazarr from the stack and add it later;
the stack shape does not change.

### tinyMediaManager retires

**The reason is the licence, not the ports.** tinyMediaManager is the only paid dependency in the
platform: a recurring subscription whose free tier is TMDB-scraper only, with no subtitle download,
no Trakt and no alternative scrapers. A self-hosted platform that pins its own image digests and
authors every credential in its own vault should not have a rented feature set at the centre of its
media pipeline. Radarr and Sonarr do the same job, better, for nothing. That holds even if every
technical argument below disappeared.

Two technical arguments reinforce it. tmm runs `network_mode: host` with no `ports:` stanza and
occupies host **4000** (web) and **7878** (API) directly, with a healthcheck asserting a listener
on `:7878` (`services/tinymediamanager/compose.yml:14,35`); 7878 is Radarr's default. And tmm is the
declared owner of metadata writes into a tree Jellyfin mounts read-only
(`services/jellyfin/compose.yml:24-25`), ownership Radarr and Sonarr want. Two writers into
`/volume2/Media` is the defect being removed, not a state to pass through.

Budget for the removal honestly. It means deleting the role, the manifest entry, the `nas_storage`
entry, the Mac hook scripts, the `vault_tinymediamanager_password` key from every vault source plus
`EXPECTED_VAULT_KEYS` (`tests/policy_test.rb:122`), and dropping the literal `43` in
`tests/secrets_docs_test.rb:72-73` to 42. Roughly the same work as an addition. Verified 2026-08-18:
the `43` literal survived the Portainer removal, so the vault arithmetic in the Comics section still
holds. The `docs/portainer-parity.md` entry this paragraph used to list is gone with that doc; the
only surviving mention of `tinymediamanager.env` is in a design spec under `docs/superpowers/specs/`,
which is a historical record and should be left alone.

If you want an overlap period for confidence rather than a clean swap, give Radarr 7879 temporarily
and stop the tmm container without deleting the role. Do not run both writing into
`/volume2/Media/Movies` at once.

### Trailers: pick exactly one route

Two routes, and running both means duplicate trailers, so this is a genuine either/or rather than a
recommendation plus a rejection.

**Route A, the Jellyfin TMDB Trailers plugin.** Streams on demand, adds no container, writes nothing
into the media tree. Weaknesses: it depends on a plugin surviving Jellyfin major-version bumps,
which plugins routinely do not, and it needs network at playback time.

**Route B, Trailarr.** Writes trailer files next to each item, so they are format-stable, work
offline, and survive both Jellyfin upgrades and TMDB API changes. Weaknesses: it is a third writer
into `/volume2/Media`, a tree Jellyfin mounts read-only precisely to guarantee a single writer; it
requires Radarr and Sonarr; every trailer is a video file Jellyfin will scan and store; and it is
another manifest entry, though it could reasonably live as a fifth container inside the `arr` stack
since it depends on Radarr and Sonarr anyway.

The multi-writer objection is softer for Trailarr than for Posterizarr or Tdarr, because Trailarr
writes only into a per-item subfolder and never touches the media files themselves. If you take
Route B, state the write ownership explicitly in `docs/stateful-services.md`: Radarr and Sonarr own
item folders and naming, Trailarr owns the trailer subfolder within them, nothing else writes.

Route A is the smaller change and the default below. Route B is defensible and is the better pick if
offline playback matters or you distrust plugin longevity. What is not defensible is both.

If Route A: the plugin state is fully API-managed with a self-check, so the change is four
coordinated edits. The
declared defaults are asserted equal to a literal copy pinned inside the task itself, so the change
is four coordinated edits:

- `jellyfin_plugins` and `jellyfin_plugin_packages` in `roles/jellyfin/defaults/main.yml:57-68`
- the inlined `jellyfin_required_plugin_packages` copy at `roles/jellyfin/tasks/main.yml:150-156`
- the exact-list assertions at `roles/jellyfin/tasks/main.yml:111-114`, currently pinning
  `['Intro Skipper', 'Open Subtitles']`
- the verify-phase exact-state assertion in `roles/jellyfin/tasks/settings.yml` around line 1055

**Verify before planning the edit:** `jellyfin_plugin_repositories` is asserted to be exactly two
entries (`roles/jellyfin/tasks/main.yml:87-107`), Jellyfin Stable and Intro Skipper. If the trailer
plugin ships in the Jellyfin Stable manifest, nothing else changes. If it needs its own repository,
that two-entry assertion widens to three as well. Check the stable manifest first.

### YouTube

**Youtarr**, port 3087. Subscribes to channels and playlists and mirrors them into Jellyfin as
native playlists, which is its actual differentiator and the reason to prefer it here. Needs no
indexer and no download client. Its own manifest entry.

The trade against **Pinchflat**, the alternative: Pinchflat has the larger community and more
maintenance activity, and also writes Jellyfin-readable NFO, but does not do the native-playlist
mirroring. Youtarr is a much smaller project, and in a repository that pins image digests an
abandoned image becomes a frozen dependency rather than a slowly aging one. Youtarr is the right
pick if the Jellyfin playlist integration is what you want; switch to Pinchflat if the maintenance
profile matters more.

**Verify before writing the role:** whether Youtarr requires Docker socket access. This repository
permits exactly two socket readers, Beszel and Dozzle, and both go through a read-only
linuxserver socket-proxy with mutation refused and no publication beyond loopback
(`services/beszel/compose.yml:115-144`, `services/dozzle/compose.yml:78-104`). A service needing a
writable socket would need its own explicit exception, which is a much bigger conversation than a
new role.

Not TubeArchivist either way: it brings Elasticsearch and Redis, which is wrong on a memory-bound
box that already runs Immich's ML container and Paperless' Postgres, Redis, Gotenberg and Tika.

### Comics

**Kapowarr**, port 5656. Acquires from GetComics, which it fetches itself, so in its default mode
it needs neither indexer nor download client. Its own manifest entry.

A ComicVine API key is a deployment prerequisite, not post-install configuration, and it goes
through the eleven-step vault chain documented at `docs/secrets.md:1113-1132`: the key must appear
in `vault.yml.example`, `templates/vault-plain.yml.j2`,
`roles/vault_contract/meta/argument_specs.yml`, `tests/generate-ephemeral-vault.sh`,
`EXPECTED_VAULT_KEYS`, an assert in `roles/vault_contract/tasks/main.yml`, and exactly once in
`docs/secrets.md`, with the `43` literal in `tests/secrets_docs_test.rb:73` adjusted.

That vault count interacts with the tinyMediaManager retirement below. Removing
`vault_tinymediamanager_password` drops the literal to 42 and adding the ComicVine key raises it to
43. Land both in the same change and the literal never moves; land them separately and it moves
twice, in opposite directions, which reads as a confusing test failure if you are not expecting it.

Kapowarr becomes the writer for the comics tree while Komga stays read-only, the same ownership
handover as Radarr taking Movies from tmm. Do not add a second comic manager against that library.

### Ebooks and audiobooks: the gap, stated

There is no live *arr for either. Readarr was retired in 2025 with no successor.

Ebooks: the non-*arr options are Calibre-Web-Automated with a downloader, or LazyLibrarian.
Audiobooks: the available tools (AudioBookRequest, ReadMeABook) are request frontends that still
need Prowlarr and a download client behind them.

None fit the declarative contract, and each wants to be a second writer into a tree Komga or
Audiobookshelf already owns. Recommendation: leave both manual, and revisit only after the
acquisition subsystem exists and has proven itself on movies and series. Automating a library with
no maintained tool is how you acquire an unmaintained dependency in a repository that pins image
digests specifically to avoid that.

### Not asked for, worth having

| Addition | Cost | Why |
|---|---|---|
| **Podcasts via Audiobookshelf** | Zero containers, zero manifest entries | Audiobookshelf already does podcast subscription and scheduled episode download. This is a library declaration next to the existing one at `roles/audiobookshelf/defaults/main.yml:29-33` plus a writable mount. Best value in the plan by a wide margin |
| **Jellyseerr** (5055) | One manifest entry | The piece that makes the rest usable from a phone. Without it, requesting a film means opening Radarr's admin UI. Phase it last, after the acquisition path works end to end |
| **Configarr** | Fits inside the `arr` stack as a fifth container | **Promoted from optional to required by the TRaSH conformance above.** It is one of the guide's three supported sync tools, and it is how naming, quality definitions, custom formats and profiles get into the *arr databases from a file this repository owns. Two arguments now point the same way: TRaSH compliance needs a sync mechanism, and the repo needs to reclaim part of the converge-on-every-run property the *arr SQLite state costs |

Music stays out: Lidarr needs a music server the NAS does not have, so it is two services and a new
library. Manga stays out: Kapowarr covers western publishers, manga would mean Suwayomi as another
stack.

### Acquisition, branch-agnostic

| Piece | Port | Branch |
|---|---|---|
| qBittorrent | 8081 | Torrent |
| gluetun | publishes the client's ports | Torrent, second container in the same stack. Mandatory in Germany, optional in Israel |
| SABnzbd | 8081 | Usenet |
| Unpackerr | none | Usenet, second container in the same stack. Without it the *arr apps never finish an import from a rar set |

The branch is undecided and location-dependent: usenet if the NAS sits in Germany, torrent if it
sits in Israel. That is a coherent split rather than an unresolved question, and it does not gate
anything in this plan. Design for either, and note that **both at once is supported without design
change**: Prowlarr manages newznab and torrent indexers side by side, and Radarr and Sonarr accept
multiple download clients with per-client category routing. Adding the second later is a new
container in the same stack, not a redesign.

Because the VPN or extractor is a second container in the client's own stack, neither costs an extra
manifest entry.

**The one place the branch actually changes the storage design.** Torrent and usenet want different
incomplete-directory placement, and this is a real decision, not a preference:

- **Torrent:** both the in-progress and the completed file must sit inside the shared
  `/volume2/Media:/data` mount, because seeding continues from the very file Radarr hardlinks. Set
  qBittorrent's default save path to `/data/torrents` and let the categories `movies` and `tv`
  create `/data/torrents/movies` and `/data/torrents/tv`. Per the guide, category save paths are
  entered as the subfolder only and are resolved against the default save path, and **Default
  Torrent Management Mode must be `Automatic`** or downloads land in the root and ignore the
  category folder entirely.

  A separate incomplete directory is optional here. TRaSH rates *"Keep incomplete torrents in"* as
  **"Personal preference"**, warning that it *"could be useful if you want your downloads to use a
  separate SSD/Feeder disk, but this also results in extra unnecessary moves or in worse cases a
  slower and more I/O intensive copy + delete."* The "worse case" is an incomplete directory on a
  different mount, which this design does not do. So if you want one, `/data/torrents/incomplete`
  is compliant and costs one rename per completed torrent; if you do not, qBittorrent writes
  straight into the category folder and nothing is lost. Do **not** put it on `/volume1`: on the
  torrent branch the completed file is the file that gets hardlinked, so a cross-volume incomplete
  directory converts every completion into a full copy.
- **Usenet:** use the guide's layout unchanged. `/data/usenet/incomplete` for the temporary folder
  and `/data/usenet/complete/{movies,tv}` for the completed output, with SABnzbd's categories named
  to match, so both sit inside the shared mount.

  This reverses an earlier version of this plan, which put the incomplete directory on `/volume1` for
  the NVMe I/O. The reasoning behind that was sound in isolation and is still true: the *arr apps
  hardlink from `complete`, never from `incomplete`, and unpacking rewrites the payload anyway, so
  splitting them loses no hardlink. What kills it is the size of `/volume1`. At 1 TB usable, shared
  with every service's state, a couple of concurrent jobs at the top of the quality profile can claim
  a few hundred gigabytes of unpacking scratch, and the thing that breaks when `/volume1` fills is
  Paperless' Postgres and Immich's database rather than the download. Trading a slower unpack for a
  chance of corrupting unrelated services is not a trade worth making, and the HDD array is not the
  bottleneck for a usenet feed anyway.

  If the NVMe placement is ever wanted back, it needs two guards rather than none: SABnzbd's minimum
  free space set high enough to protect the service-state floor, and a cap on concurrent jobs. Absent
  both, keep it on `/volume2`.

Getting that backwards on the torrent branch is the silent-copy failure again: an incomplete
directory outside the shared mount means the finished file is in a different bind mount from the
library, `link()` returns `EXDEV`, and every import doubles disk.

**On recurring cost**, connecting to the tinyMediaManager reasoning above. Usenet cannot be
paid-free: SABnzbd is free software but useless without a paid provider and in practice a paid
indexer. Torrent in Israel has no equivalent requirement, and notably no requirement for a paid VPN
either, because the residential-IP copyright-claim industry that makes gluetun effectively mandatory
in Germany does not operate there the same way. So the split you have arrived at is also the
cost-coherent one: **torrent in Israel is the branch with no recurring cost at all; usenet in
Germany is the paid-but-low-exposure branch.** The principle that retires tmm (refusing a licence
that gates features in code running on your own hardware) does not object to either, because
retention and bandwidth are transit, not software.

One consequence: gluetun is genuinely optional on a torrent-in-Israel deployment and genuinely not
optional on torrent-in-Germany. Since the branch tracks location, treat gluetun as conditional on
the deployment location rather than on the branch. Where it is used, the cost is that the client runs
`network_mode: service:gluetun`, its ports are published on the gluetun container, and the role's
verification `uri` task must target gluetun's published port rather than the client's own.

Aside from cost and exposure: torrent is materially better for books and audiobooks if those
libraries are ever automated, and usenet has no seeding obligation and no exposure of your address
to peers.

Port note: 8080 is Dozzle (`services/dozzle/compose.yml:48`) and both clients default to 8080, so
the client moves regardless of branch. Host 8081 is free; Dozzle's alert-relay uses 8081 only
inside its container network with no `ports:` stanza.

### Explicitly rejected

| Candidate | Reason |
|---|---|
| Posterizarr, Tdarr | Second writers into `/volume2/Media` with no offsetting benefit. Posterizarr fetches artwork Radarr already fetches; Tdarr rewrites the media files themselves. **The hardlink design sharpens the Tdarr objection specifically:** a hardlinked file shares its data blocks with the seeding copy, so an in-place transcode does not produce a new library file, it rewrites the torrent you are still seeding. Trailarr is treated separately above because its write pattern is narrow and its benefit is real |
| Readarr | Archived upstream. The failure mode is specific: indexer definitions rot and will never be updated again, in a repository that pins digests precisely so dependencies cannot drift. Check whether a fork has real maintenance traction before reconsidering |
| Listenarr | Not rejected, deferred. Audiobookshelf integration was an unchecked roadmap item, and it needs its own indexers plus a download client, so Phase B at the earliest. It is the only tool that attempts audiobook automation, which is the argument for revisiting it later rather than never |
| SuggestArr | Needs a Seerr instance you do not run, so two installs from useful. Separately, it auto-requests from watch history, meaning downloads nobody asked for on a four-bay NAS. Add Jellyseerr, live with manual requests, then decide |
| Jellyswarrm | Federates multiple Jellyfin servers. You have one |
| ReadMeABook, AudioBookRequest | Request frontends over a Prowlarr and client stack that does not exist yet |
| Huntarr, Cleanuparr, Decluttarr, Maintainerr, autobrr, cross-seed | Operational polish on a stack that does not exist yet, and each costs a full contract round. **Maintainerr and Cleanuparr get an explicit revisit trigger:** the array is 16 TB across four full bays, so capacity is fixed for its life and automated acquisition is precisely the thing that fills it silently. When `/volume2` passes ~80%, a retention policy stops being polish and becomes the difference between choosing what to delete and having the array choose for you |
| Flaresolverr | A headless Chrome container for a problem not yet observed |
| Homarr | Reasonable, but a dashboard is not a media source. Separate change |

## Storage layout: the decision that cannot be retrofitted

### The governing rule for both volumes

**Service state lives on `/volume1` (NVMe). Permanent content lives on `/volume2` (HDD).** Every
container's config, database and cache goes to `/volume1/Docker/<name>/`, which is where small
random I/O belongs and what the RAID1 mirror is for. The media libraries, photographs and documents
stay on `/volume2`, where the capacity and the parity are.

This settles most placement questions before they are asked, and it happens to agree with TRaSH
rather than fight it. The one case it does not decide by itself is the download trees, which are
neither service state nor permanent content: they are transient bulk. The hardlink rule decides
those, and it puts them on `/volume2`, because a hardlink cannot cross a filesystem and the library
is there. So both principles point the same way, and the earlier idea of parking usenet scratch on
the NVMe violated both.

Two consequences worth writing down rather than rediscovering:

- **Recovery classification follows the split.** `/volume1` paths hold state that no download can
  reproduce, so they are `recovery: critical`. The `torrents/` and `usenet/` trees on `/volume2` are
  reproducible by definition and must not be classified the same way, or every backup carries a
  transient working set.
- **It applies to every service added later, not just these.** A new container puts its config on
  `/volume1` and its content on `/volume2`, and any service that wants to do otherwise is asking for
  an exception that should be argued explicitly.

### The hardlink conditions

Import wants a hardlink so a finished download costs no extra disk and seeding can continue. Two
conditions must both hold:

1. Source and destination on one filesystem. Already satisfied: `nas_media_root` is `/volume2` and
   every library lives beneath it (`inventory/group_vars/nas_hosts/main.yml:5-6`).
2. Source and destination inside **one bind mount**, addressed by an identical container path in
   both the client and the *arr. This is the condition that fails silently. `link()` returns
   `EXDEV` across two separate bind mounts even on the same underlying filesystem, and the *arr
   apps respond by copying, doubling disk on every import. Radarr stores absolute paths, so
   retrofitting means re-importing the library.

No files need to move. Jellyfin already has the right shape:
`${JELLYFIN_MEDIA_PATH}:/media:ro` is one mount of `/volume2/Media`, and `jellyfin_libraries`
(`roles/jellyfin/defaults/main.yml:80-86`) points at `/media/Movies` and `/media/Series`
individually.

So:

- The `arr` stack and the download client each mount `/volume2/Media:/data` read-write, one mount.
  TRaSH is explicit that the container path itself is free choice: *"Pick one path layout and use it
  for all of them. It doesn't matter if you prefer to use `/data`, `/shared`, `/storage` or
  whatever."* What matters is that it is one mount and identical in every container.
- **The download trees follow the guide's names and separation**, which is a change from the earlier
  single `Downloads/` directory:

  ```
  /volume2/Media            ->  /data          (arr stack + client, rw)
  ├── torrents/                                 torrent branch
  │   ├── movies/
  │   └── tv/
  ├── usenet/                                   usenet branch
  │   ├── incomplete/
  │   └── complete/
  │       ├── movies/
  │       └── tv/
  ├── Movies/                                   existing library, Radarr root folder
  ├── Series/                                   existing library, Sonarr root folder
  └── Audiobooks/                               existing library, untouched
  ```

  Torrent and usenet get separate trees rather than one shared `Downloads/` because the two have
  opposite lifetimes: a torrent file must persist for seeding and its hardlink is the library copy,
  while a usenet payload is disposable once imported. Collapsing them puts a live seed and a
  deletable unpack output in the same directory, which matters precisely because this plan says both
  branches can coexist later.
- This part is decided in Phase A, before any client exists, and is the reason the mount shape is
  established with Radarr and Sonarr rather than deferred to Phase B.
- Jellyfin, Komga and Audiobookshelf keep their existing read-only mounts unchanged. Jellyfin's
  libraries are declared per folder, so the new `torrents` and `usenet` directories are invisible to
  it.
- Immich (`/volume2/Immich`) and Paperless (`/volume2/Documents`) stay outside the mount, so a
  compromised client or a bad rename cannot reach photographs or documents. That is the reason to
  scope at `/volume2/Media` rather than `/volume2`.

**The one deviation from the guide's structure, stated.** TRaSH's root holds `media/` as a *sibling*
of `torrents/` and `usenet/`, and hands the media servers only `/data/media`. Here the libraries sit
at the root instead, because `Movies`, `Series` and `Audiobooks` are existing NAS shares. Two
consequences, and only the first is a real cost:

1. Jellyfin's `/volume2/Media:/media:ro` mount necessarily contains the download trees. It is
   read-only and its libraries are declared per folder, so nothing scans them today. But the
   property is now a *convention that must be maintained* rather than a structural guarantee: any
   library declared at the mount root instead of a subfolder starts indexing partial downloads. Say
   this in `docs/stateful-services.md` alongside the write-ownership statement, because Komga is
   already the counter-example, declaring its library at `/data` itself.
2. Directory naming is mixed case (`torrents/` beside `Movies/`). Cosmetic, and not worth renaming
   existing shares over.

**The strictly compliant alternative, and when it is worth taking.** Create one share
`/volume2/Data` holding `media/` (the three libraries moved in), `torrents/` and `usenet/`, and
mount `/volume2/Data:/data`. That is the guide's structure exactly, keeps Immich and Documents
outside the blast radius, and restores the `media`-only mount for Jellyfin and Komga. On one
filesystem the move is a rename rather than a copy, so the data cost is nil; the cost is updating
`JELLYFIN_MEDIA_PATH`, `KOMGA_LIBRARY_PATH`, the Audiobookshelf paths, the `nas_storage` entries and
the tests that pin them. **Flip to this layout if the top-level directories under `/volume2` turn
out to be movable** — see Assumptions, since on ADM they are shared folders with their own ACLs and
SMB exports, and that is the thing that decides it.

Two mechanical constraints on the compose files. Volume sources must be `${...}` parameterized and
must not literally start with `/volume` (`tests/policy_test.rb:848`), and any
`${NAS_DOCKER_ROOT:?}`-rooted source must resolve to a declared `nas_storage` path or a child of
one (`:851-864`). Also, `roles/host_prep/tasks/main.yml:15-23` **refuses** to claim owner or group
on any path under `/volume2`, so the new `torrents` and `usenet` entries declare `mode` and
`recovery` only. Write access comes from NAS permission controls, exactly as it already does for tmm
writing into `/volume2/Media/Movies` as 1000:100, and the permissions section below turns that from
an aside into a stated contract with a verification step.

Comics are the one place needing a host-side restructure, and only if a download client is ever
added for them. Komga's library root is `/volume2/Books` mounted at `/data`, and
`tests/komga_library_reconciliation_test.rb` asserts a single managed library named `Comics` rooted
at `/data`. A downloads directory under `/volume2/Books` would make Komga scan partial downloads.
Fix: move content to `/volume2/Books/Comics`, point `KOMGA_LIBRARY_PATH` there, put downloads at
`/volume2/Books/downloads`. The container path stays `/data`, so the reconciliation test's
expectations are untouched.

## Permissions: the second condition for hardlinks, and the one this plan had missed

The mount shape above is necessary and not sufficient. The guide states the other half plainly:
hardlinks and atomic moves *"depend on permissions: every app must be able to read — and the apps
that import, upgrade, or delete must be able to write — each other's files."* A correct single mount
with wrong permissions fails as an import error, or worse as a silent fallback to copy.

TRaSH sanctions exactly two models and rejects a third:

| Model | UMASK | Result | Use when |
|---|---|---|---|
| One shared user for every app | `022` | dirs `755`, files `644` | Every container runs as the same UID/GID |
| Per-app user in a shared group | `002` | dirs `775`, files `664` | Containers run as different users |
| `UMASK 000` | — | world-writable | Never. The guide warns against it explicitly |

**Take the shared-user model.** The tree already has a single writing identity (tmm writes into
`/volume2/Media/Movies` as `1000:100`), so `PUID=1000`, `PGID=100`, `UMASK=022` on every container in
the `arr` stack and the client stack keeps that property and needs no NAS-side group work. Switch to
the shared-group model only if the client ever has to run as a different user, which on the torrent
branch is a live possibility since it runs `network_mode: service:gluetun`.

**This has to be asserted, not set.** `roles/host_prep/tasks/main.yml:15-23` refuses to claim owner or
group on any path under `/volume2`, which is correct and stays. So the three ids go in `env.j2` and
the ACL that makes them effective is established once on the NAS side, exactly as it already is for
tmm. The role's verification block must therefore *check* it rather than assume it, which is a new
requirement on the verify design and is covered under Verification below.

## Naming, quality and the settings the guide owns

This is the half of TRaSH that is not about paths, and the plan previously said nothing about it. All
of it lives in the *arr databases, so it belongs to the state exception in work item 1 and is the
strongest argument for Configarr, which is one of the guide's three supported sync tools. The guide
publishes custom formats, custom format groups, quality profiles with their upgrade settings, quality
definitions (file sizes) and naming patterns specifically to be consumed by them.

**Naming, Phase A.** The recommended file names carry quality, custom format, release group and
edition tokens because that information is *non-recoverable from the file later*; omitting it causes
repeat downloads of releases you already have and breaks re-import after a rebuild. A folder per
movie is standard. Radarr, movie folder and file:

```
{Movie CleanTitle} ({Release Year}) [tmdbid-{TmdbId}]
{Movie CleanTitle} {(Release Year)} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}
```

Sonarr, series folder, season folder and standard episode:

```
{Series CleanTitleWithoutYear} {(Series Year)} [tvdbid-{TvdbId}]
Season {season:00}
{Series CleanTitleWithoutYear} {(Series Year)} - S{season:00}E{episode:00} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}
```

Multi-episode style: Prefixed Range. **Use the Jellyfin token spellings, not Emby's** — Jellyfin
wants `[tmdbid-…]`, `[imdbid-…]` and `[tvdbid-…]`, Emby wants `[tmdb-…]`, `[imdb-…]` and `[tvdb-…]`,
and the wrong one is silently ignored by the server. This box runs Jellyfin. Take the exact current
strings from the guide when the change is written rather than from this plan, since they are revised
upstream.

**Renaming the existing library is a migration, not a setting, and it lands at the worst moment.**
The library is tmm-named today, and adopting the scheme above means Radarr and Sonarr rename every
existing file at the same handover where tmm stops writing. On one filesystem the rename is cheap,
but a mismatched item renames to the wrong identity and Jellyfin's per-item metadata and watch state
are keyed on the old paths. Order it explicitly: import the existing library with renaming **off**,
confirm every item matched the right TMDB/TVDB id, then enable renaming and let it run once.

**Quality definitions, Phase A.** The guide's file-size limits per quality tier exist because the
defaults let low-quality and fake releases through. They are Phase A relevant even with no download
client, since they also bound what an import from disk is allowed to be.

**Custom formats and quality profiles, Phase B.** These decide *between candidate releases*, and in
Phase A there are no candidates, so syncing them earlier imports configuration that cannot be
exercised and produces a verify step that passes while asserting nothing. Land them with Prowlarr and
the client. Pick one profile per library from the guide's four (HD Bluray + WEB, UHD Bluray + WEB,
Remux + WEB 1080p, Remux + WEB 2160p), set Upgrade Until Custom Format Score to `10000` as the guide
does, and note that *Quality Trumps All*: resolution outranks every custom format score.

**One setting that is the whole point of the storage section**: Radarr and Sonarr must have "Use
Hardlinks instead of Copy" enabled under Media Management. It is on by default, it lives in the
database rather than in `config.xml`, and nothing in this design currently asserts it. Read it back
over the API in the verify block, since a silent flip to copy is exactly the failure the mount shape
was designed to prevent.

**Prowlarr, Phase B.** Sync indexers to Radarr and Sonarr through Apps rather than configuring them
per app. For any indexer with a capped API, set its Query Limit and Grab Limit to the indexer's own
values, and use the guide's two-sync-profile pattern: one profile with RSS disabled and automatic
plus interactive search enabled, one with only interactive search, assigned per indexer. Indexer
choice itself stays out of scope; the limits are infrastructure.

## Hardware: known, and it decides two things this plan had left open

| Component | Spec | Consequence |
|---|---|---|
| Asustor AS6704T, Intel N5105 | QuickSync, already in use (`platform_render_device_path: /dev/dri/renderD128`) | CPU is not the constraint |
| 16 GB DDR4 | Installed. Officially the maximum; 32 GB is widely reported to work | Budget for 16 GB, but headroom exists as an unsupported escape hatch |
| 16 TB usable, 4-bay RAID5 | `/volume2`, shared with Immich and Paperless | Sets the quality profile, permanently |
| 1 TB usable NVMe RAID1 | `/volume1`, all Docker service state | Too small to also hold usenet unpacking |

Record these in the repository while they are in hand. The plan previously noted that no memory fact
exists anywhere and there is no `host_vars` directory, and the fix is to add one rather than to
re-derive the numbers next time somebody plans against this box.

**Memory: the gate is met and therefore closed, and it converts into a budget with an escape hatch.**
Intel specifies 16 GB for the N5105 and Asustor documents the same, but memory vendors list 32 GB
modules for this model and users report them working. Treat that as real but unsupported: design the
stack to fit in 16 GB, and keep 32 GB in reserve as the answer if it stops fitting, rather than as a
plan. Existing tenants are
Immich's ML container, Komga on the JVM, Paperless with Postgres, Redis, Gotenberg and Tika, plus
Jellyfin and the small services. The additions run roughly 1.5-2.5 GB together: the `arr` stack is
about 1 GB across Radarr, Sonarr, Prowlarr, Bazarr and a periodic Configarr, the client stack is
0.3-1 GB depending on branch, and Kapowarr and Youtarr are a couple of hundred megabytes each. That
fits. What makes it stop fitting is not the container count but two tunables that default to scaling
with available RAM:

- **Cap the download client's cache explicitly.** qBittorrent's disk cache and SABnzbd's article
  cache are the largest single knobs in this stack and both default to automatic. Pin them.
- **Set `mem_limit` on the new stacks.** Without it, a large torrent count or a heavy unpack can push
  Paperless' Postgres into reclaim, and the service that suffers is not the one that misbehaved.

If pressure appears anyway there are two answers, and the cheap one comes first: drop Bazarr, which
is an upgrade over the Jellyfin Open Subtitles plugin rather than a gap. The second is the 32 GB
upgrade. Reach for the software answer before the unsupported hardware one, but note that the
hardware answer existing at all is what stops the memory budget from being a hard design ceiling.

**Storage: 16 TB fixes the quality profile, and this is the decision with the longest tail.** Against
TRaSH's four profiles, and reserving roughly 15% because a RAID5 array that runs full is also an
array whose rebuild window is longest exactly when a second drive is most likely to fail:

| Profile | Per film | Films in ~13 TB workable | Verdict here |
|---|---|---|---|
| HD Bluray + WEB | 6-15 GB | ~1,300 | **Take this one** |
| UHD Bluray + WEB | 20-60 GB | ~370 | Only as a per-item exception |
| Remux + WEB 1080p | 20-40 GB | ~430 | No |
| Remux + WEB 2160p | 40-100 GB | ~185 | No |

Those counts are films alone, and series are what actually consume the array: a 1080p WEB season
runs 30-50 GB, so a few hundred seasons is another several terabytes, on a volume that also holds
photographs and documents. **So the profile is HD Bluray + WEB for both Radarr and Sonarr**, with
UHD available per item in Radarr for the handful of films worth it. QuickSync means a 2160p profile
would *play* here, which is exactly what makes the expensive answer tempting; playability is not the
constraint, capacity is. A second point in the same direction: 2160p HDR transcoding to a
non-HDR client makes the N5105 tone-map, which is the one job that does strain it.

Note what the four bays imply. They are full, so growing the array means replacing every drive
rather than adding one, and the budget above is fixed for the life of the array. That is the
argument for the retention trigger recorded in the rejected-candidates table.

**NVMe: 1 TB is the number that reverses a decision made earlier in this plan.** `/volume1` holds
every service's state, so it is not spare space. A single UHD usenet job needs roughly double its
size transiently while unpacking, and two concurrent jobs on a 60 GB profile can claim a few hundred
gigabytes. Filling `/volume1` does not degrade downloads, it takes out Paperless' Postgres and
Immich's database, which is a far worse failure than a slow unpack. See the acquisition section: the
usenet incomplete directory moves back onto `/volume2` and into TRaSH's own layout.

## Work items

### 0. Let the repository describe a service it did not inherit (mostly done, and not by this plan)

**Status, 2026-08-18: the schema half of this item has landed on `main`, from a different
workstream.** Commit `02d60e2` ("refactor: remove the Portainer migration") deleted the migration
apparatus outright and took the contract that blocked a native service with it. Verified on `main`
at `bc4d8ce`:

- `REQUIRED_MANIFEST_FIELDS` is now `%w[name role status]` (`tests/policy_test.rb:167`).
  `legacy_path`, `tranche` and `legacy_source` appear nowhere in that file or in
  `services/manifest.yml`, and no role under `roles/` asserts `legacy_path` any more.
- The parity apparatus is gone: no `scripts/portainer-parity.rb`, no `config/portainer-parity.yml`,
  no `tests/portainer_parity_*`. **The one real widening this item named no longer exists to widen.**

So two arguments this item used to make are retired: setting `legacy_path: compose/arr/compose.yml`
on a native service, and adding an `origin: legacy|native` field for the parity check. Nothing here
needs a schema change, and nothing needs to ship alone for reviewability.

**What is left is mechanical, and the repository now documents it.** `docs/adding-a-service.md` (591
lines, added the same day) enumerates the touchpoints independently. Follow that and treat this list
as the cross-check rather than the source:

- `EXPECTED_SERVICES` (`tests/policy_test.rb:107`), unconditional set-equality that fires for
  `planned` entries too, plus `EXPECTED_SERVICE_MAPPINGS` (`:111`), which survived the removal in
  reduced form
- `EXPECTED_FIXTURE_ROLES` (`tests/policy_manifest_test.rb:104`), where a missing entry raises
  `"unsafe manifest fixture identity"` and aborts the whole suite rather than failing one check
- `EXPECTED_SERVICES` in `tests/managed_user_capabilities_test.rb:18`
- `README.md:20` ("All nine service stacks")
- the Mac hook groups under `tests/mac/hooks/`, which are `drift`, `fixtures-persistence`,
  `fixtures-recreate`, `fixtures-seed` and `verify`

**This item no longer blocks Phase A**, which is the practical change: the first *arr change can be
the service itself rather than a contract change followed by a service.

**One caution, true when this was written on 2026-08-18 and expected to expire.** A separate change
was in flight, uncommitted, replacing the hardcoded image pins in `tests/policy_test.rb` with a
property check and touching `tests/policy_manifest_test.rb`, eight `tests/contracts/*.sh` and a new
`renovate.json`. It edits one of the files this item edits. If it has since landed, this note is
spent. If it has not, land on top of it rather than around it, and do not revert those hunks.

### 1. Document the state exception

The *arr apps hold indexers, quality profiles, custom formats and the library in SQLite the app
mutates continuously. Ansible can render `config.xml` and pre-seed the API key from vault, which is
the same shape as the existing Beszel pre-placed-keypair pattern, so the credential half fits the
vault-first design cleanly. The state half cannot be owned, and that contradicts the README's claim
that a web-UI change is reverted by the next run.

Write `docs/stateful-services.md`: what Ansible owns (compose, `config.xml`, API key, mounts,
ports), what the application owns (everything else), and that Configarr narrows the gap by
declaring profiles and custom formats in a config file. Add every new `*/config` path to
`nas_storage` with `recovery: critical`, since that state is now irreplaceable and the README
explicitly says application state is not backed up by this repository.

### 2. Phase A: library-only, no acquisition

The `arr` stack in library-only mode (Radarr, Sonarr, Configarr, optionally Bazarr, but not
Prowlarr, which is inert until a download client exists), Youtarr, Kapowarr, the chosen trailer
route, and the Audiobookshelf podcast library. Retire tinyMediaManager. Reword Jellyfin's read-only
mount comment and `jellyfin_library_options`: the single-writer property survives, the owner changes
from tmm to Radarr and Sonarr.

Establish the `/volume2/Media:/data` mount shape here, before any download client exists, together
with the `torrents/` and `usenet/` trees even though nothing writes into them yet. Creating them now
is what makes the mount shape reviewable while it is still free to change.

Configarr is in this phase rather than later because naming and quality definitions are Phase A
work, and its config file is the artifact this repository owns. Custom formats and quality profiles
are deliberately **not** synced yet, per the naming section: with no indexer and no client there is
nothing for them to choose between.

Ordered, because the sequence matters more than the settings:

1. Deploy the stack with `PUID`/`PGID`/`UMASK` set and hardlinking enabled, and assert the mount and
   permissions before pointing anything at the library.
2. Add the existing `/data/Movies` and `/data/Series` as root folders with renaming **off**.
3. Confirm every item matched the correct TMDB or TVDB id. This is the step that cannot be undone
   cheaply, since a wrong match plus renaming moves a file under another film's identity.
4. Apply the naming schemes and quality definitions through Configarr, then enable renaming and let
   it run once.
5. Confirm the NFO and artwork output is what you want, and that Jellyfin still resolves every item,
   before going further.

Follow the existing role pattern, using `roles/tinymediamanager` or `roles/dozzle` as the reference
rather than `roles/jellyfin`, whose `tasks/main.yml` is 55 KB. The ordered shape is: derive the
state root behind the `platform_verify_*` tag, re-assert it, revalidate deployment paths via
`deployment_bundle` `tasks_from: target` with `deployment_target_extra_paths`, stat the
platform-specific compose override, prepare state directories with ownership gated on
`platform_kind == 'nas' or platform_manage_linux_ownership`, render `env.j2` to the runtime dir at
mode 0600 with `no_log: true`, deploy via `community.docker.docker_compose_v2` (never a shell-out,
`tests/policy_test.rb:917`), then verify with `uri` plus `assert`.

Per-service checklist beyond the role itself: `services/<name>/compose.yml` digest-pinned with a
human tag, `restart: unless-stopped`, `json-file` logging with both `max-size` and `max-file`,
`roles/<role>/meta/argument_specs.yml` with a non-empty options hash and every consumed `vault_*`
key marked required, `nas_storage` entries, a verification task named `Verify ...` tagged
`platform_verify_<name>` (or the alternative branch, `tests/contracts/<name>.sh` plus a
`tests/contracts/registry.yml` entry), a `site.yml` role line tagged `media` placed after `ntfy`, a
`verify.yml` entry with `tags: [never]`, a lane in `tests/ci/classify_changes.rb` (omitting it
forces the full CI matrix rather than failing), and Mac hook scripts under
`tests/mac/hooks/*/NN-<name>.sh`. Note that nothing asserts a manifest service appears in
`site.yml` or `verify.yml`, so forgetting that surfaces only at converge time. Also note that
`compose.mac.yml` must contain no `image:` key unless you extend the `platform_image_overrides`
allowlist at `tests/policy_test.rb:875-882`.

Two consequences of bundling that the generic checklist hides, both of which otherwise surface as a
test failure after the directories already exist:

- **Storage paths must nest under the manifest name.** `tests/policy_test.rb:773-774` requires a
  declared `nas_storage` path containing `/<name>/` or ending `/<name>`, where `<name>` is the
  manifest name. With one entry named `arr`, `/volume1/Docker/radarr/config` satisfies nothing. Use
  `/volume1/Docker/arr/{radarr,sonarr,prowlarr,bazarr}/config`, each `recovery: critical`.
- **One verification task covers four apps.** The tag is `platform_verify_arr`, since
  `contract_basename` has only the `paperless-ngx` exception. A single task must carry that tag, and
  to satisfy branch A of `role_has_verification?` (`tests/policy_test.rb:544-568`) every `that`
  condition in it must be a non-tautological comparison over a register produced by a `uri` task
  that has an explicit `status_code`. So register four `uri` results and assert over all four in one
  `assert` block.

### 3. Phase B: acquisition

Prowlarr joins the `arr` stack here (it is inert before this point), then the download client stack
on the chosen branch, with gluetun or Unpackerr as its second container. Wire Prowlarr to Radarr and
Sonarr, and the client to both, from vault-authored API keys. Memory needs no confirmation now, but
check headroom on Beszel before adding the client, since this is the phase that adds the two
cache-hungry containers.

The rest of the TRaSH configuration lands here, because this is where it first has something to act
on: custom formats and quality profiles via Configarr, on **HD Bluray + WEB for both Radarr and
Sonarr** per the hardware section, Prowlarr's two sync profiles with per-indexer query and grab
limits, and the client's categories (`movies`, `tv`) matching the download paths in the storage
section, with Torrent Management Mode set to Automatic on the torrent branch. Cap the client's cache
and set `mem_limit` in the same change rather than after the first memory incident.

Branch selection follows deployment location: usenet if the NAS is in Germany, torrent if it is in
Israel. Nothing earlier in the plan depends on which, and both can coexist later. Only two things
are branch-specific: the sidecar container, and the incomplete-directory placement described in the
acquisition section.

### 4. Phase C: Jellyseerr

Requests from a phone, wired to Jellyfin, Radarr and Sonarr.

## Verification

Per change, in this order:

```sh
ruby tests/policy_test.rb        # the contract widening lands here first
tests/validate-policy.sh         # the full policy suite, policy_test.rb runs first inside it
ansible-lint --strict
tests/integration.sh site.yml    # converges, re-converges clean, then --check --diff
```

The re-converge assertion matters most for these services. A role that writes `config.xml` on every
run against an app that rewrites it will fail idempotence, which is the correct outcome and tells
you the file must be seeded on first run only.

After a vault key is added, also run `ansible-playbook validate-vault.yml --vault-password-file ...`
per `docs/secrets.md:1151-1157`.

Then the full lifecycle:

```sh
tests/mac/run.sh --lane fresh --vault-file <path> --vault-password-file <path>
```

Two blind spots, both directly relevant. The README states the Mac proof does not cover host
networking or native mounts, and the shared `/volume2/Media:/data` bind is exactly a native-mount
concern. So after the NAS run, verify hardlinking empirically rather than trusting the config.
Import one file, then compare inode and link count inside the container. The container name comes
from the compose project, which the role derives the same way `roles/dozzle/defaults/main.yml` does,
so resolve it with `docker ps` rather than guessing `radarr`:

```sh
docker exec <arr-project>-radarr-1 \
  stat -c '%i %h %n' /data/torrents/movies/<file> /data/Movies/<path>/<file>
```

Same inode with a link count of 2 means it hardlinked. Two inodes means it copied, the mount shape
is wrong, and it is much cheaper to fix before the library grows.

Three checks, not one, because the guide's requirement is broader than "a hardlink was created":

- **Run the `stat` comparison from both containers**, the *arr and the client. The failure this
  design exists to prevent is a path mismatch *between* them, and a check run from one side cannot
  see it.
- **Probe the write, not just the link.** TRaSH requires that the importing app can write the
  other's files, and an upgrade or a delete later is what exercises that. A hardlink can succeed
  while the subsequent upgrade fails on permissions, so create and remove a file as the *arr's uid
  in the media directory as part of the same verification.
- **Read "Use Hardlinks instead of Copy" back over the API.** It lives in the database, not in
  `config.xml`, so nothing in the converge asserts it, and a flip to copy is silent by construction:
  imports keep succeeding and disk use doubles.

End to end once Phase C lands: request a film in Jellyseerr, watch Prowlarr search, the client
download, Radarr import by hardlink, Bazarr fetch subtitles, and the result appear in Jellyfin with
artwork and a streamable trailer.

## Assumptions

- `/volume2` is a single filesystem rather than a pool of separate mounts. Confirm with `df` and
  `/proc/mounts` on the NAS before Phase A, since the hardlink design rests on it.
- The top-level directories under `/volume2` are ADM shared folders with their own ACLs and SMB
  exports, which is why `Movies`, `Series` and `Audiobooks` are treated as immovable and the layout
  is flattened rather than nested under a `Data` share. This is assumed, not verified from this
  host. Check it before Phase A: if those directories can be relocated into one share without
  losing their exports and permissions, take the strictly compliant layout described under Storage
  layout instead, since it is the guide's structure exactly and it restores a `media`-only mount for
  Jellyfin and Komga.
- The TRaSH naming strings quoted in this plan were read on 2026-08-17 and are revised upstream.
  Take them from the guide at the moment the change is written rather than from here.
- Hardware is now known rather than assumed: AS6704T, 16 GB installed, 16 TB usable on a four-bay
  RAID5 `/volume2`, 1 TB usable on an NVMe RAID1 `/volume1`. The memory gate is closed.
- 16 GB is the officially supported maximum for the N5105, and 32 GB is reported to work by users
  and listed by memory vendors for this model. The plan designs for 16 GB and treats 32 GB as an
  unsupported escape hatch rather than a supported upgrade path. Nobody here has tested it.
- The two capacity figures are read as **usable** capacity after RAID, which is what the quality
  profile recommendation is calculated from. If "16 TB" instead means four 16 TB drives, usable is
  nearer 48 TB and the profile choice reopens: UHD Bluray + WEB becomes affordable and the retention
  trigger moves out by years. Nothing else in the plan changes.
- The Jellyfin trailer plugin ships in the Jellyfin Stable manifest. If it does not, the exactly-two
  `jellyfin_plugin_repositories` assertion widens as well.
- The acquisition branch is undecided and tracks deployment location (usenet in Germany, torrent in
  Israel). Everything before Phase B is branch-agnostic, so this needs no resolution now.
- Indexer, tracker and provider selection is yours. This plan builds infrastructure and stays out of
  source choice.
