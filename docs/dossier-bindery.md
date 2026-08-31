# Bindery dossier — Phase 2 unit B

Derived from `ghcr.io/vavallee/bindery` **v1.33.2** and from the upstream Go
source at that tag, against a live container and a live
`ghcr.io/advplyr/audiobookshelf:2.36.0` beside it. Read
[the marker convention](service-dossiers.md#how-to-read-the-evidence-markers)
first: **Confirmed** was executed, **Inferred** was reasoned, **Unverified**
was not settled.

`vavallee/bindery` is a clean-room Go and React replacement for the archived
Readarr, and it is the right project: upstream's `BINDERY_PORT` default is
`8787`, which is the port `config/media-acquisition.yml` already pins for this
entry; its Dockerfile declares `HEALTHCHECK CMD ["/bindery", "healthcheck"]`,
which is the probe the design describes; it carries separate ebook and audiobook
destination roots and download categories; and it ships an Audiobookshelf scan
trigger. Confirmed. It is not the `bindery` npm layout library or the Rust crate
of the same name.

```
image: ghcr.io/vavallee/bindery:v1.33.2@sha256:3778b97d8651cf51da57910ce4e4a5b175b42f9bbba55c5c9b07b16309144013
```

## The image has no shell, so the usual probe cannot run

The runtime stage is `gcr.io/distroless/static-debian12:nonroot`. `/bin`,
`/sbin`, `/usr/bin` and `/usr/sbin` all exist and are all **empty directories**;
the only executable in the whole image is `/bindery`. Confirmed by exporting the
container filesystem and by `docker run --entrypoint /bin/sh`, which fails with
`stat /bin/sh: no such file or directory`.

A `CMD-SHELL` healthcheck therefore cannot run at all. Copying the shape every
other service in this repository uses produces a container that is unhealthy
forever, and because deployment goes through `docker_compose_v2` with
`wait: true`, the failure surfaces as a timeout that says nothing about the
cause. The probe is the binary's own subcommand, in exec form:

```yaml
healthcheck:
  test: ["CMD", "/bindery", "healthcheck"]
```

`runHealthcheck` builds `http://127.0.0.1:${BINDERY_PORT}/api/v1/health` with a
five-second timeout and exits 0 on HTTP 200; it opens no database, so it is
cheap and follows a port override. `/api/v1/health` is on the
allow-unauthenticated path, so the probe needs no credential — confirmed
anonymously against the running container, and confirmed exiting 1 with no
server listening. The image declares the same healthcheck itself, but
`tests/policy_test.rb` requires every service to declare a non-empty
`healthcheck` mapping of its own, so it must be written out.

The same absence has a second consequence. There is no entrypoint script, no
root phase and no `gosu`, so the container **cannot chown anything**. Identity
is a Compose `user: "${NAS_UID:?}:${NAS_GID:?}"`. `BINDERY_PUID` and
`BINDERY_PGID` are not a remap: `checkPUIDPGID` compares them against the actual
uid and gid at startup and exits 1 on a mismatch. Setting them alongside `user:`
is worth doing precisely because it turns a dropped `user:` line into a loud
boot failure instead of files silently written as the image's uid 65532.
Confirmed running as an arbitrary `--user 501:20` with five host bind mounts,
all four configured directories reporting `writable: true`.

That inability to self-repair is the ownership trap. `nas_uid`/`nas_gid` are
`1000`/`100`, and `Books/Ebooks` and `Media/Audiobooks` are declared in
`nas_storage` at mode `0755` with no `owner`/`group`, because CLAUDE.md says the
NAS owns files under the media root. A linuxserver.io image papers over a bad
owner by starting as root. Bindery cannot. If those two paths are not writable
by 1000:100 on the real NAS, imports fail permission-denied and nothing in the
container can fix it. Their deployed ownership is **unverified** and should be
`stat`ed against the NAS before promotion. `GET /api/v1/system/storage` is an
admin-only read that reports `exists` and `writable` per configured directory
plus a live hardlink probe, and it is a far better verification assertion than a
bare 200.

## The setup land-grab

With no credentials configured at all, a fresh Bindery is **not** an
unauthenticated writer. Confirmed against a live container: `/api/v1/books`,
`/api/v1/settings`, `/api/v1/rootfolders`, `POST /api/v1/authors` and `/opds/`
all answer `401`, and only `/api/v1/health` and `/api/v1/auth/status` answer
anonymously. `bootstrapAuth` writes `auth.mode = 'enabled'` on first boot, which
upstream's own comment calls a "safe default, forces first-run setup".

The hole is a different shape, and it is irreversible. `/api/v1/auth/setup` is
on the always-allow-unauthenticated path and its only guard is "does any user
exist yet". Confirmed, in one run:

```
POST /api/v1/auth/setup {"username":"attacker",…}  → 200 + session cookie, role=admin
POST /api/v1/auth/setup {"username":"platform",…}  → 409 {"error":"setup already complete"}
```

Between container start and the platform declaring its administrator, any host
that can reach port 8787 can claim the account permanently. 409 is forever; the
only recovery is deleting the database. That window opens on every first deploy,
on every disposable lane, and after any restore that loses the `users` table.

It is closable, and the platform must close it inside the same converge.
`BINDERY_API_KEY` seeds `auth.api_key` on first boot, and the seeded key then
creates the vault-authored administrator. Confirmed end to end in one run: the
log line `seeded API key from BINDERY_API_KEY env var`, then
`POST /api/v1/auth/users` with `role: "admin"` returning 201, then
`/auth/setup` returning 409 and the vault identity logging in successfully.

Two adjacent exposures belong in the role's comments. `auth.mode = local-only`
grants **admin to every private-network peer with no credential**, and
`GET /api/v1/auth/config` returns the API key in clear to any admin — so
`local-only` hands the API key to the LAN. Both halves confirmed. The role must
pin `auth.mode = enabled` and assert it from the credential-free
`GET /api/v1/auth/status`. And the login rate limiter is per-IP at five failures
per fifteen minutes, after which it returns **429 to the correct password too**
— confirmed. So the "anonymous is refused" verification probe must be a
credential-free GET on a protected route, never a deliberately wrong password;
budget at most one failed login per converge.

## Credentials

Bindery keeps every credential in its own SQLite database. The only one it reads
from the environment is the API-key seed.

| Credential | Platform-authorable | Mechanism |
|---|---|---|
| API key | yes, **on first boot only** | `BINDERY_API_KEY` env seed |
| Administrator username and password | yes | `POST /api/v1/auth/users` with the seeded key |
| Prowlarr API key | yes, the platform's own `vault_arr_prowlarr_api_key` | `POST /api/v1/prowlarr` |
| SABnzbd API key | yes, `vault_downloaders_sabnzbd_api_key` | `POST /api/v1/downloadclient` |
| Audiobookshelf API key | **no** — see below | `PUT /api/v1/abs/config` |

Three new vault keys, following the existing naming: `vault_bindery_api_key`
(32-char lowercase hex, matching the `HEX_32` rule the arr and SABnzbd keys
already use), `vault_bindery_admin_username` and `vault_bindery_admin_password`
(both `NONEMPTY`; the application enforces a minimum of eight characters, so the
role should refuse a short one up front rather than let the API 400 it inside a
`no_log` task). **No `NOT_PLACEHOLDER` rule is needed** — nothing Bindery holds
is a third-party value, because the default metadata stack (OpenLibrary, Google
Books, DNB, Audnex, Audible) is keyless.

The API-key seed is a one-way door. It seeds only when `auth.api_key` is absent
or empty; after a restart with the variable still set, no re-seed occurs and the
stored value is retained. Confirmed. There is no "set this key" route, only
`regenerate`, which mints a random value — so a key rotated in the web interface
cannot be pushed back. The recovery path exists and was proven: log in with the
vault administrator identity and read the deployed key from
`GET /api/v1/auth/config` with the session cookie. A drifted administrator
password is separately repairable with `PUT /api/v1/auth/users/{id}/reset-password`
using the API key, without knowing the old one — confirmed, and that is exactly
what a Mac drift hook needs. If neither the vault key nor the vault identity
works, the role should refuse loudly rather than converge: Bindery is then
holding an identity this platform did not author.

### The Audiobookshelf key is an open architectural question

This is the one finding that does not have a settled answer, and it should not
be implemented as though it does.

The design requires Bindery to trigger an Audiobookshelf library scan after an
audiobook import. The mechanism is `Scanner.pushToABS`, which calls
`POST /api/libraries/{id}/scan` on ABS, gated on `abs.enabled` and a non-empty
`abs.library_ids`; **failures are logged at WARN and swallowed**, on the
reasoning that the ABS handoff must never roll back an otherwise-good import.
That is the converge-cleanly-and-do-nothing failure mode: a wrong credential
here produces a green run, a healthy container, and a scan that never happens.

Three candidate ABS credentials exist and only one works. Confirmed, all three:

| Candidate | Verdict |
|---|---|
| `POST /login` → `user.accessToken` | Broken. The JWT decodes to a **3600-second** lifetime, so the trigger dies after an hour, silently. |
| `POST /login` → `user.token` (legacy) | Works, no `exp` claim — but it is the deprecated pre-2.26 path with no upstream commitment. |
| `POST /api/api-keys` | Correct. `expiresAt: null`; authenticated both `GET /api/libraries` and `POST /api/libraries/{id}/scan`. |

The ABS role's existing token handling is a red herring: it reads
`login.json.user.accessToken` and uses it *within the same play run*, which is
fine. Persisting that same token into Bindery is not.

The catch is that `POST /api/api-keys` returns the plaintext **only at
creation**. `GET /api/api-keys` afterwards returns metadata only, with no
`apiKey` field — confirmed. And Bindery reports only `apiKeyConfigured: true`,
never the value. So this credential can be authored by neither side: ABS signs
it with a per-install secret that does not exist until ABS's own first boot, and
it cannot be read back from either service afterwards.

That collides directly with CLAUDE.md's "Nothing is ever read back from a
running service, which is why a run converges in a single pass." **This needs an
explicit decision before the role is written, not a decision made inside it.**
The shape that would converge, if the deviation is accepted, is a
create-if-absent pair keyed on two reads — ABS's key list and Bindery's
`apiKeyConfigured` — creating a new key and pushing it only when either side is
missing, which reaches a steady state at `changed=0`. The alternative, the
legacy non-expiring `user.token`, is also ABS-generated, so it does not avoid
the deviation; it only avoids the read-once half, at the cost of depending on a
deprecated path. Both are departures. Choosing one is the promotion's first
task.

The library id is a UUID minted by ABS at library-creation time, so it must be
resolved by name at converge time rather than pinned;
`roles/audiobookshelf/tasks/main.yml` already reads `GET /api/libraries` and
matches on name, and reusing that is the smaller change.
`POST /api/v1/abs/test` is a live end-to-end check returning server version,
username and default library id — confirmed against ABS 2.36.0 — and makes a
good assertion. Do not call `POST /api/v1/abs/import`: `abs.enabled` also arms
Bindery's ABS *catalogue import*, which is a much larger behaviour, but it runs
only when that route is called.

## Nothing is create-if-absent

Every mutation must be read-then-decide, and the two failure modes differ:

| Resource | Duplicate write | Consequence |
|---|---|---|
| user (`POST /auth/users`) | **500** | the play fails on run 2 |
| root folder (`POST /rootfolder`) | **500** | the play fails on run 2 |
| Prowlarr (`POST /prowlarr`) | **201, silent duplicate row** | the config grows every run |
| download client (`POST /downloadclient`) | **201, silent duplicate row** | the config grows every run |
| ABS config (`PUT /abs/config`) | 200, singleton | genuinely idempotent |
| setting (`PUT /setting/{key}`) | 200, upsert | compare before writing |

Every row was executed. Neither failure mode is visible to lint.

What reconciles cleanly to `changed=0`: the administrator identity from
`GET /auth/users`; `auth.mode` from the credential-free `/auth/status`; both
destination roots from `GET /rootfolder` compared on `path` (note that
`POST /rootfolder` `os.Stat`s the path inside the container and 400s if it is
missing, so the bind mounts must exist first, which `host_prep` guarantees); the
Prowlarr instance and SABnzbd client matched on `name`; and the ABS config.

Credential *values* never read back. `apiKey` and `password` are write-only
across Prowlarr, indexers and download clients — every create returned
`"apiKey":""` with `"apiKeyConfigured":true`. So the role can prove a key is
set, never that it is the right one. The compensating control is that a PUT
treats a blank submitted key as "keep the stored one", so a drift repair of the
non-credential fields will not wipe the credential.

Two settings are mandatory rather than optional. **The auto-grab kill switch
fails open**: `autoGrabEnabled` returns `true` for a missing row, a read error,
*or* an unattached repository, so silence means enabled and
`PUT /setting/autoGrab.enabled {"value":"false"}` must be reconciled explicitly.
And **telemetry is on by default**, with a daily ping; the live install wrote
`telemetry.install_id` at first boot. Set `BINDERY_TELEMETRY_DISABLED=true` in
the environment, which takes effect before the first ping in a way the settings
row cannot, *and* reconcile `telemetry.enabled=false` for durability.

Leave indexers alone: they are synced from Prowlarr by
`POST /prowlarr/{id}/sync` and carry Prowlarr's own per-indexer overrides, so
declaring them directly fights the sync. And `library.defaultRootFolderId`
stores a database-assigned integer, not a path — resolve it from
`GET /rootfolder` each run, never pin a literal.

## The write-time DNS check couples the role's ordering

The single most surprising runtime behaviour found. Both
`POST /api/v1/prowlarr` and `POST /api/v1/downloadclient` resolve the supplied
host at write time and reject on failure:

```
POST /api/v1/prowlarr {"url":"http://prowlarr:9696",…}
 → 400 {"error":"invalid indexer URL: url not allowed: dns lookup failed: …"}
```

The same bodies with resolvable addresses returned 201. Confirmed both ways. So
Bindery **must** join `media-control` and **must** converge after `arr` and
`downloaders`, which makes it the first Phase 2 project that genuinely needs the
control network — Kapowarr and Pinchflat both deliberately stay off it. Under
`--check` the writes cannot run at all, so the role reports what a live run
would declare with an explicit `debug` task, as the platform requires for
external systems that cannot be simulated.

Also worth writing into the role: omitting `BINDERY_AUDIOBOOK_DIR` or
`BINDERY_AUDIOBOOK_DOWNLOAD_DIR` silently falls back to the ebook equivalents,
collapsing the two libraries into one — the thing the design forbids. Both
fallbacks are logged at INFO. And a per-author root folder overrides
`BINDERY_AUDIOBOOK_DIR`, so that variable is a default, not a constraint.

## Backup before upgrade, and what a backup contains

The design requires state to be backed up before every upgrade, with the upgrade
refusing to proceed unless the backup succeeded. Upstream provides
`POST /api/v1/backup`, admin-only, with an optional label; confirmed returning
201 with the filename, size and duration, and confirmed to land on the host bind
mount at `${BINDERY_DATA_DIR}/backups/`, so no extra volume is needed.

Two implementation details decide the shape. It is `VACUUM INTO`, not a file
copy — SQLite runs in WAL mode, so copying `bindery.db` silently omits whatever
is still in `bindery.db-wal`, which is why an `ansible.builtin.copy` of the
database file is wrong. And it stages to a temporary name and renames, so an
aborted run leaves no partial file masquerading as a backup.

The gate has to be conditional on an actual upgrade or it fires on every
converge and is not idempotent; keying it on a difference between the deployed
image digest and the pinned one is the obvious choice. Nothing in the
repository exposes that digest, but nothing needs to: Compose records the image
reference it created the container from, digest included, so
`docker container inspect`'s `.Config.Image` compared against
`services.bindery.image` in the deployed Compose definition names an upgrade
exactly. Confirmed, and it is what the promotion's gate does. It must run
before `docker_compose_v2` starts the new image, because Bindery applies its
schema migrations on startup (81 of them at v1.33.2, a few hundred milliseconds
on a fresh database) and by the time the API answers again the old schema is
gone. The role's *first* task is still the
`deployment_bundle` re-include; that is invariant.

**A backup is a whole-database copy and Bindery stores every credential in the
database in plaintext** — indexer and Prowlarr keys, download-client passwords,
the session signing secret, its own API key, and the Audiobookshelf token.
Upstream states this is a deliberate posture and that redaction is off the
table. Under this repository's security boundary that puts
`{{ nas_docker_root }}/bindery/config` in the same class as Dozzle's users file
and Beszel's private key: secret-bearing at runtime, and so are its backups.
That belongs in `docs/secrets.md` and in the disaster-recovery notes, not only
in the `recovery: critical` class it already carries.

## Smaller items worth carrying into the role

- Secret settings reject the generic settings API: `PUT /api/v1/setting/abs.api_key`
  returns 403 and `GET` returns 404. Use the dedicated route. Confirmed.
- `/opds/` is a second door onto the library — an OPDS catalogue that serves
  book files. It sits behind the same middleware and answered 401 anonymously on
  a fresh install, and it belongs in the "refuses an unauthenticated caller"
  probe.
- The container paths matter more than the reproducing recipe below suggests.
  Its flat `/books` and `/downloads` mounts are fine for a probe, but SABnzbd
  reports a finished download by *its own* container path and Bindery reads that
  path straight off the filesystem, so the two have to agree or every import
  needs a `pathRemap`. Mount the libraries and staging roots at the paths
  `services/downloaders/compose.yml` already uses — `/data/books/...` and
  `/data/media/...` — rather than at Bindery's defaults. Confirmed against a
  deployed pair.
- `BINDERY_URL_BASE` and `BINDERY_TRUSTED_PROXY` both stay empty. An over-broad
  trusted-proxy entry disables the per-IP rate limiter, and upstream warns about
  it at boot.
- The live hardlink probe reported `hardlinkable: false` with an EXDEV
  explanation, but that was on Docker Desktop for macOS, a known source of
  spurious EXDEV. Whether it reproduces on the NAS kernel is **unverified**.
  Moot for the initial transport, and not only because `auto` and `hardlink` are
  both remapped to `move` for a usenet client: `MoveFileCtx` catches EXDEV and
  falls back to a copy (`internal/importer/renamer.go`), so an import across two
  separate bind mounts still completes. Confirmed. It matters when qBittorrent
  arrives and seeding must be preserved.
- `tests/expected/bindery.yml` currently carries `vault_keys: []`, and the
  planned-tree guard fails a `planned` project whose role or service directory
  exists — so the directory tree, the status flips and the expectations file all
  land in one commit. `tests/policy_ci_test.rb` additionally asserts that a
  planned acquisition lane has zero service image sources, so that list drops
  `bindery` in the same change.

## What remains unsettled

1. **The Audiobookshelf credential.** The first credential on this platform that
   is neither vault-authored nor re-readable. Decide the deviation explicitly and
   comment it in the role, or reject the design that needs it.
2. **Ownership of `Books/Ebooks` and `Media/Audiobooks` on the real NAS.** The
   image cannot repair it. `stat` before promoting.
3. ~~**Whether the pre-upgrade backup gate can read the deployed image digest**
   from something that already exists.~~ Settled: Compose's `.Config.Image`
   carries the pinned reference, so no new helper is needed.
4. **Whether the Komga two-library migration lands in this unit or beside it.**
   The design ties them together — the migration runs before Bindery is granted
   write access — and it calls for rewriting
   `tests/komga_library_reconciliation_test.rb` against a two-library model. That
   is a large slice on its own and was not investigated.

## Reproducing the confirmations

```sh
gh repo clone vavallee/bindery -- --depth 1 --branch v1.33.2

docker run -d --name bindery-probe -p 18787:8787 -u "$(id -u):$(id -g)" \
  -v "$S/config:/config" -v "$S/books:/books" -v "$S/audiobooks:/audiobooks" \
  -v "$S/downloads:/downloads" -v "$S/abdownloads:/abdownloads" \
  -e BINDERY_API_KEY=... -e BINDERY_PUID="$(id -u)" -e BINDERY_PGID="$(id -g)" \
  -e BINDERY_LIBRARY_DIR=/books -e BINDERY_AUDIOBOOK_DIR=/audiobooks \
  -e BINDERY_DOWNLOAD_DIR=/downloads -e BINDERY_AUDIOBOOK_DOWNLOAD_DIR=/abdownloads \
  ghcr.io/vavallee/bindery:v1.33.2

docker export bindery-probe | tar -tv | grep -E ' (bin|sbin|usr/bin|usr/sbin)/'
```

An `ghcr.io/advplyr/audiobookshelf:2.36.0` container on the same user-defined
network supplied the scan-trigger half. Both were removed afterwards.

Upstream files that answer the recurring questions, at `v1.33.2`: `Dockerfile`
for the base, probe and user; `internal/config/config.go` and
`internal/config/validate.go` for every environment variable and its default;
`cmd/bindery/main.go` for the auth bootstrap, the route table and the ABS
notifier wiring; `internal/auth/middleware.go` for the auth modes and their
precedence; `internal/api/auth.go` for the first-run setup;
`internal/importer/scanner_handoff.go` for the scan trigger and the usenet
import-mode remap; `internal/scheduler/scheduler.go` for the auto-grab switch;
`internal/api/backup.go` for `VACUUM INTO`; and `cmd/bindery/uidcheck.go` for
the PUID/PGID assertion.
