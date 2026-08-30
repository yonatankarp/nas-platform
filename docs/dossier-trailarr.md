# Trailarr dossier — Phase 3

Derived from `nandyalu/trailarr` **0.11.3** — a running container, plus the
upstream tree at `main` `6aa5e06`, which is the same tree the image carries
under `/app/backend` and `/app/scripts`. Read
[the marker convention](service-dossiers.md#how-to-read-the-evidence-markers)
first: **Confirmed** was executed, **Inferred** was reasoned, **Unverified**
was not settled.

The registry is Docker Hub, not GHCR: `ghcr.io/nandyalu/trailarr` returns
`denied` for anonymous pulls and upstream's publish workflow sets
`REGISTRY: docker.io`. Confirmed.

```
image: docker.io/nandyalu/trailarr:0.11.3@sha256:86d6ae3dffa583261f3281017106ebefc68693018e3fe8d1c58c6e731d88e4b1
```

Two Renovate notes. Upstream pushes `latest` and `nightly` on every `master`
push, not only on releases, so a rule matching only `X.Y.Z` is the only safe
one. And Trailarr's own build derives from an unpinned `FROM
nandyalu/python-ffmpeg:latest`, so two Trailarr releases at the same version can
rest on different base contents — which does not weaken our digest pin, but is
worth one sentence in the role comment. Both inferred, the first from the tag
listing and the second from `Dockerfile:32`.

## `/config/.env` inverts the repository's core invariant

This is the finding that decides the shape of the role, and it is the reason
this file exists.

`scripts/start.sh`, running as the application user *after* the container
environment is already in place, does this:

```bash
ENV_FILE="${APP_DATA_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
```

`set -o allexport` plus `source` means **every key present in `/config/.env`
overwrites the Compose-supplied value**, permanently. And the application writes
to that file: every settings mutation goes through a helper that calls
`set_key(ENV_PATH, …)`, and the configuration object itself unconditionally
persists `API_KEY`, `LOG_LEVEL`, `WAIT_FOR_MEDIA` and `YT_COOKIES_PATH` on every
boot. `settings.py` also calls `load_dotenv(..., override=False)`, which reads
as though the environment wins — it is a decoy, because the shell has already
clobbered it.

The file lives inside the `critical` config volume. Three experiments, all
confirmed:

**A vault rotation has no effect after first boot.** Started with one `API_KEY`,
which persisted into `/config/.env`. Recreated the container with a different
`API_KEY` and the same volume: the old key authenticated, the new one returned
`401`, and `/config/.env` still held the old value. So rotating the credential in
vault would change nothing on a deployed Trailarr, and `verify.yml` would keep
passing against the stale one.

**Hand-made drift survives a converge.** With the vault identity in the Compose
environment, `PUT /api/v1/settings/updatelogin` changed the login and
`PUT /api/v1/settings/update` set `monitor_enabled`. Both appended to
`/config/.env`. After a restart with the vault values still declared:

```
vault identity      -> 401
the hand-made one   -> 200
monitor_enabled     -> True   (Compose said False)
```

That is a directly disqualifying result against CLAUDE.md's "Configuration
changed by hand in a service's web UI is reverted by the next run — that is what
makes the repository describe reality."

**The repair works and is a fixed point.** Removing the platform-owned keys from
`/config/.env` — `API_KEY`, `LOG_LEVEL`, `WAIT_FOR_MEDIA`, `YT_COOKIES_PATH`,
`WEBUI_USERNAME`, `WEBUI_PASSWORD`, `MONITOR_ENABLED`, `DOWNLOADS_ENABLED` —
and restarting restored the vault identity and every Compose value. The file the
application then wrote back contained exactly the declared values, which is why
the reconcile converges: the steady state is a fixed point, and the next run
finds the four persisted keys already matching.

**So the role must own `/config/.env`, not just the Compose environment.** The
shape that follows (inferred design, on confirmed behaviour): before the
`docker_compose_v2` task, parse the file and, for the four keys the application
persists on every boot, rewrite the line only on a value mismatch; for the keys
it persists **only** when a human changes something — `WEBUI_USERNAME`,
`WEBUI_PASSWORD`, `MONITOR_ENABLED`, `DOWNLOADS_ENABLED`, `WEBUI_DISABLE_AUTH`,
the `DELETE_TRAILER_*` pair, `CREATE_MISSING_FOLDERS`, `URL_BASE` — require them
**absent**, because removing one *is* the drift repair; and never touch
`YTDLP_VERSION` or the `GPU_*` block, which the entrypoint rewrites on every
start.

Do not `template:` the whole file. The entrypoint rewrites the GPU block through
a `grep -v` and a move on every start, and the yt-dlp version line with it, so a
whole-file template reports changed forever. This is the one place in the role
where a hand-rolled parse and compare is correct rather than lazy.

Two ordering consequences. The file is read at process start, so the reconcile
must run before Compose brings the container up. And because the file lives
under a bind mount rather than in the Compose spec, `docker_compose_v2` will not
recreate the container when it changes — **the role must restart the service
explicitly when the reconcile changed something**, or the repair silently does
not take effect until some unrelated recreation. Register the file in
`deployment_target_extra_paths` beside the config directory.

The Mac drift hook should be built on this, because it is the only test that
would have caught the inversion: change the login through the API, restart, and
require the converge to restore the vault identity.

## The published default administrator

Trailarr ships `admin` / `trailarr`, and the hash of that password is a literal
in `backend/config/settings.py`. Confirmed: `POST /api/v1/auth/login` with that
pair returned `200` and a `trailarr_session` cookie on a fresh container.

Strictly, an unmanaged Trailarr is not an unauthenticated writer — anonymous
`GET /api/v1/settings/` and `GET /api/v1/auth/status` both return `401`. The
distinction protects nothing. That session is a full write session over the same
Movies and Series trees Radarr and Sonarr own: `POST /media/{id}/download`,
`DELETE /media/{id}/trailer`, `DELETE /files/delete`, `POST /files/rename` and
`POST /connections/` are all behind the same dependency. So the accurate
`docs/secrets.md` sentence is not Pinchflat's "with either half empty the
application serves its web interface to anyone" but: *left unmanaged, Trailarr
accepts a published default administrator and hands a full write session, over
the same media tree Radarr and Sonarr own, to anyone who can reach the port.*

There is also a hard kill switch, `WEBUI_DISABLE_AUTH`, which mints a session
for any caller when true. The role must never set it and the contract should
assert it is absent or `False`.

The identity is fully declarative, which is the good news. `API_KEY`,
`WEBUI_USERNAME` and `WEBUI_PASSWORD` are plain `os.getenv`-backed properties.
Confirmed live: with all three pushed, `admin`/`trailarr` returned `401` and the
vault pair returned `200`. Note that an `API_KEY` shorter than 32 characters is
silently replaced by a random one.

### Four vault keys, and two opposite escaping rules

`WEBUI_PASSWORD` **must be a bcrypt hash, never a plaintext**. `verify_password`
calls `bcrypt.checkpw` against the environment value directly; nothing hashes
it. `WEBUI_PASSWORD=hunter2` does not fail loudly — it makes login permanently
impossible.

bcrypt is salted, so computing the hash at converge time returns a different
string every run and `.env` would report changed forever. The hash therefore
lives in vault, exactly as `vault_ntfy_admin_password_hash` and
`vault_dozzle_admin_password_hash` already do, with `generate-secrets.yml`
producing the plaintext and its hash together. That gives four keys:
`vault_trailarr_admin_username`, `vault_trailarr_admin_password` (the plaintext,
so the contract and the drift hook can log in and a human can recover the
account), `vault_trailarr_admin_password_hash` (the value actually pushed), and
`vault_trailarr_api_key`.

The two escaping rules are the easiest thing in the whole role to get backwards,
and getting them backwards produces a container that starts healthy and refuses
every login:

- The **Compose `.env`** is interpolated, so every `$` must be doubled —
  `{{ vault_trailarr_admin_password_hash | replace('$', '$$') }}`, as `roles/ntfy`
  already documents. Confirmed that a raw hash is silently **truncated**, not
  rejected: `$zJH9U4CaxWYYi6Yt8IFDf` expanded to the empty string.
- **`/config/.env`** is sourced by bash, so the same hash must be single-quoted
  and **not** doubled.

Two files, two rules, opposite directions.

Trailarr needs Radarr's and Sonarr's API keys, and the repository already
authors exactly those. The role should reference `vault_arr_radarr_api_key` and
`vault_arr_sonarr_api_key` directly and declare them `required: true` in its own
argument spec; minting `vault_trailarr_radarr_api_key` would let the two drift.
Whether the derived vault-key checks tolerate the same key appearing under two
services in `tests/expected/*.yml` is **unverified**, and it is the single most
likely place the promotion first fails — check it before writing anything.

**No third-party credential.** Confirmed by enumerating every literal URL in
`backend/core`: the complete outbound set is `api.github.com`, `github.com`,
`raw.githubusercontent.com`, `nandyalu.github.io`, `discord.com` and
`www.youtube.com`. Trailer discovery is a yt-dlp `ytsearch` query, not an API
call; TMDB appears only as identifiers parsed out of Radarr and Sonarr payloads,
and TMDB integration is roadmap-only. Two options are worth disabling for a
different reason: `UPDATE_YTDLP` and `YTDLP_NIGHTLY` make the container
`pip install` yt-dlp from the network at start, which is exactly what a
digest-pinned platform exists to prevent.

## Health probe and identity

Confirmed by executing inside the container: `curl`, `python3` and `bash` are
present; `wget`, `nc` and `busybox` are **not**. So the repository's usual
`curl --fail` probe is correct here and an ntfy-style `wget` probe would report
unhealthy forever. `/status` is the only unauthenticated route besides
`/api/v1/auth/*`, `/api/v1/openapi.json` and the SPA; there is no
`/api/v1/health`. Confirmed that `curl --fail --silent --show-error
http://127.0.0.1:7889/status` returns `{"status":"healthy"}` and that the
container reported `healthy`.

One trap in that endpoint, inferred from `backend/main.py`: when the hourly
nvidia probe fails, `/status` raises **404**, not 503. `curl --fail` still
behaves correctly, but an Ansible readiness task written as `status_code: 200`
would produce a "404" diagnostic rather than a health message. The NAS has no
NVIDIA GPU, so the path should not fire; name the possibility in the
readiness task's `fail_msg` anyway.

Identity is `PUID`/`PGID` with a real gosu re-exec. The entrypoint reuses an
existing user or group when the supplied id is already taken, chowns the data
directory, and `exec gosu`es. Confirmed with `PUID=1000 PGID=100`: PID 1 runs
as `1000:100`, taking the "reuse the existing `users` group" branch, which is
what the design's shared-identity table requires. **No `user:` key** — it would
run the entrypoint as non-root and break the whole sequence.

`UMASK` is **not** supported: it appears nowhere in `scripts/` or
`settings.py`. Setting it would be a no-op that a reader mistakes for a control.
`/proc/1/status` reports `Umask: 0022` anyway, inherited from the Docker
default, so the correct move is the branch the design already anticipates —
verify created modes instead. One twist: a newly created `Trailers/` directory
inherits the *parent's* permissions rather than the umask, and the parent is a
Radarr-created item directory, so the assertion belongs on the produced file.
Ownership assertions cannot run on the local Mac at all — Docker Desktop's bind
mounts reported `/config` as `0 0` inside the container while the host showed
`501` — so keep them in the integration and NAS lanes.

## The reconcilable surface splits three ways

Getting this split right is the design of the role.

**Global settings are environment, not API.** Every global setting is a property
whose getter is a live `os.getenv`, so all of them are settable from the
container environment — including `MONITOR_ENABLED`, `DOWNLOADS_ENABLED`,
`CREATE_MISSING_FOLDERS`, the `DELETE_TRAILER_*` pair and `FFMPEG_TIMEOUT`.
Reconcile them through the environment plus the `/config/.env` ownership above,
and never through the API. Mixing the two is what produced the drift above.

Two reasons not to call `PUT /api/v1/settings/update`, both confirmed. First,
**it reports failure with HTTP 200**: an unknown key returns `200` with the body
`"Error updating setting: Invalid key 'bogus_key'! …"`, because the handler
returns prose strings and never a 4xx. A `uri` task asserting `status_code: 200`
passes on every failure — and that is exactly the shape `tests/policy_test.rb`
accepts as verification, so it would satisfy the policy test while proving
nothing. Second, every call writes to `/config/.env`, which is the drift
mechanism. Also note that the handler ignores an empty value, so `URL_BASE` and
`YT_COOKIES_PATH` cannot be cleared through the API at all.

**Connections to Radarr and Sonarr are API-only, and not idempotent by
construction.** They live in the SQLite `connection` table with no environment
variable and no config file. Four behaviours the reconciler must handle, all
confirmed:

- `POST /api/v1/connections/` **validates with a live call** — a real
  `GET {url}/api/v3/system/status` with the API key, checking `appName`. Against
  a stub Radarr it returned 201 with the version; against an unreachable host,
  `400 {"detail":"Connection Refused while connecting to API."}`. So Radarr and
  Sonarr must be up and reachable from inside the Trailarr container when the
  role reconciles, and under `--check` the reconcile cannot run at all — the role
  emits the explicit `debug` prediction the platform requires.
- **It has no uniqueness check.** Three identical POSTs produced ids 1, 2 and 3.
  Read, match on `name`, then `PUT /{id}` or `POST /`.
- `PUT /{id}` with an identical body is safe and repeatable, but it always claims
  success, so the `changed` decision must come from the comparison rather than
  from the response.
- **`path_mappings` are normalized with a trailing slash on write.** Sending
  `/data/media/Movies` reads back `/data/media/Movies/`, so a naive comparison
  reports drift forever. Best avoided entirely: mount Movies and Series at the
  same container paths Radarr and Sonarr use and send `path_mappings: []`, since
  identity mappings are filtered out anyway.
- `DELETE /{id}` is **asynchronous**. Two deletes returned 200 and the list was
  unchanged; it was correct eight seconds later. A delete-then-read reconciler
  sees stale state.

Because it calls the arrs by name, Trailarr joins `media-control` — a deliberate
departure from both existing acquisition contracts, **which assert the absence
of a `networks` key**. Do not copy that assertion. Address the arrs by their
Compose *service* names, following `arr_sabnzbd_host: sabnzbd`; Compose
registers the service name as a network alias regardless of the `container_name`
override the disposable lanes apply. Inferred from that precedent, not executed
in the Mac lane.

**Task schedules are database state, reconcilable by compare-then-PUT.** Six
tasks are seeded with intervals; unlike the settings endpoint this one uses real
status codes. Note the mandatory `task_id` query parameter, which is runtime
state read from `GET /api/v1/tasks-data` rather than a stable identifier — so
this reconcile has a read dependency the others do not.

## What "the approved monitoring profile" actually denotes

The design says "deploy Trailarr, prove one selected trailer, then enable the
approved monitoring profile". In 0.11 that is not one setting but four layers,
and the implementation has to say which it means.

`MONITOR_ENABLED` is a hard gate at the top of the download task.
`DOWNLOADS_ENABLED` is softer: when false the task runs in **preview mode**,
computing and publishing what it *would* download while scans and syncs keep
running, and manual downloads still work because they are explicit user intent.
That is a genuinely useful "would-download" report and the honest way to make
check mode meaningful for a service whose real action is an outbound download.

`monitor_new_media` is per connection, and it is **applied once, when an item is
first created, and never rewritten** — upstream's docstring is explicit that
monitor is user intent and syncs never write the flag afterwards. So whatever
"enable the approved monitoring profile" means, it cannot mean "flip this and
existing items become monitored". Per-item monitor flags address items by
Trailarr's own numeric id, assigned when the arr sync first sees them and not
derivable from anything vault or inventory knows, so the design's "initial
monitoring is restricted to one selected title" is a manual acceptance step, not
a converge.

**Trailer Profiles are the object that actually decides what gets a trailer and
how it is encoded.** Two are seeded by an unguarded migration on a fresh
database, and confirmed by reading them out of a fresh container, **the two ship
with different folder behaviour**: "Movie Trailers" has `folder_enabled: false`
and "Series Trailers" has it `true`. That alone means the role must reconcile
them. `GET`/`PUT /api/v1/trailerprofiles/{id}` reads and full-object-replaces
idempotently — confirmed, two identical PUTs left identical state — while
`POST /` has no dedupe, so never create; always compare-then-PUT against the two
seeded ids. Cross-field validators reject `mp4` with vp8/vp9, force opus for
webm, and require at least sixty seconds between the duration bounds, so
`file_format`, `video_format` and `audio_format` must move together in one PUT.

The staged shape that follows (inferred): a proof stage with `MONITOR_ENABLED`
and `DOWNLOADS_ENABLED` false and `monitor_new_media` false, where the operator
monitors one title by hand and triggers the download explicitly; then a single
host-scoped boolean flipping all three, which is one decision, is a converge and
is idempotent. The profiles are reconciled in both stages, so the encoding and
output layout are declared from the first converge rather than at the moment
monitoring is switched on.

## Where trailers land, and what Jellyfin does with them

Confirmed from `trailer_file.py`: trailers go inside the media item's own
folder, never a separate tree unless `custom_folder` is changed. With
`folder_enabled: false` the file lands beside the movie; with it true, in a
`Trailers/` subdirectory. `custom_folder` is the only way to write outside the
library and it is a formatted template with full media fields, so the static
contract should pin it to `{media_folder}`.

Two things narrow the design's "only a `Trailers/` subdirectory beneath each
item directory" boundary as far as the filesystem allows. Mount Movies and
Series **separately** rather than the whole media tree — the container paths
still match Radarr's and Sonarr's root folders exactly, so `path_mappings` stay
empty, while Music, YouTube, Audiobooks and the `.acquisition` tree stay out of
reach. And reconcile `folder_enabled: true` on *both* seeded profiles, since the
Movie profile would otherwise drop the trailer beside the movie file on the very
first download. Keep `create_missing_folders`, `delete_trailer_connection` and
`delete_trailer_media` at their `False` defaults: the first makes Trailarr a
creator of library directories, the other two make it a deleter.

Jellyfin needs no change at all. Confirmed against the Jellyfin source at the
deployed pin: the `Trailers/` folder name matches case-insensitively; the
`-trailer` filename suffix is one of four registered tokens and also matches, so
keeping both gives two independent ways for Jellyfin to type the file; extras
discovery descends into extras folders for both movies and series; a `Trailers/`
subfolder is never mistaken for a season or an alternate version, guarded three
separate ways; container and codec are irrelevant at index time; and **no
library option needs enabling** — there is no "enable extras" flag anywhere in
Jellyfin's configuration model, so `roles/jellyfin/defaults/main.yml` is
untouched. The media mount stays read-only; Trailarr writes into the same host
tree from the other side.

Three caveats survive that, though.

**Jellyfin will not see the trailer until a scan is triggered.** The role sets
`EnableRealtimeMonitor: false` and `AutomaticRefreshIntervalDays: 0`, and its own
refresh fires only after a *managed library change*, which adding a trailer is
not. Extras are recomputed only during a metadata refresh of the owning item. So
"prove one trailer" is: write it, trigger a library refresh, then check. Budget
that step explicitly or a correct trailer reads as a failure.

**A movie stored as a bare file gets no local extras at all.** Extras discovery
requires the item not to be in a mixed folder, and a movie resolved directly out
of a shared directory is. Radarr's default layout gives every movie its own
folder, so this holds in principle — but the Phase 1 library was *adopted*, not
created, so whether every movie in it lives in its own folder is **unverified**.
Confirm before choosing the title to prove.

**The seeded profiles encode mkv / vp9 / opus.** That indexes fine, but the
N5105 has no VP9 encode path, so any client that cannot direct-play VP9 software
transcodes every trailer under a 1.0-CPU ceiling. Reconciling both profiles to
mp4 / h264 / aac is the inferred recommendation, in one PUT because the
validator rejects the intermediate states.

## What remains unsettled

- Whether the derived vault-key checks tolerate the same `vault_arr_*` key
  listed under two services. Most likely first failure of the promotion.
- Whether every movie in the adopted library lives in its own folder.
- Whether Compose service-name aliases resolve across projects on the external
  `media-control` network in the Mac and integration lanes.
- Whether the Movies and Series paths are already in the integration-writer
  register from Phase 1 — this promotion may need **zero** `nas_storage` changes,
  unlike its predecessors.
- A real trailer download end to end. Not run; no arr with real media was
  available, and the acceptance step is a manual proof by design.
- Whether the dotenv writer ever emits a form `bash source` mis-parses. It writes
  `KEY='value'`, which is safe, but the application defensively strips stray
  quotes from `WEBUI_PASSWORD`, which suggests this has bitten upstream users.
  Worth one contract assertion that the deployed line is single-quoted and
  matches the vault hash.

One further trap with no home above: a failed alembic migration restores the
backup and then **sleeps forever instead of exiting**. The container stays
running, so `restart: unless-stopped` never fires, but nothing is listening, so
`wait: true` times out. Give the readiness task a `fail_msg` naming this, or an
operator will chase a phantom network problem.

## Reproducing the confirmations

```sh
docker buildx imagetools inspect docker.io/nandyalu/trailarr:0.11.3

docker run -d --name trailarr -e TZ=UTC -e PUID=1000 -e PGID=100 \
  -e APP_DATA_DIR=/config -p 17889:7889 \
  -v "$PWD/config:/config" -v "$PWD/media:/data/media" \
  nandyalu/trailarr:0.11.3

# the published default administrator is accepted
curl -i -X POST http://127.0.0.1:17889/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"trailarr"}'

# the settings endpoint reports errors as HTTP 200
curl -X PUT -H "X-API-KEY: $KEY" -H 'Content-Type: application/json' \
  -d '{"key":"bogus_key","value":"x"}' \
  http://127.0.0.1:17889/api/v1/settings/update

# /config/.env beats the container environment:
#   start with one API_KEY, let it persist, recreate with another and the same
#   volume, then observe that only the first one authenticates
```
