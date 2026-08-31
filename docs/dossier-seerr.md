# Seerr dossier — Phase 4

Derived from `ghcr.io/seerr-team/seerr` **v3.4.1**, run against a live Jellyfin
with a completed wizard, an administrator and a non-administrator second user —
the two-identity shape the design describes. Read
[the marker convention](service-dossiers.md#how-to-read-the-evidence-markers)
first: **Confirmed** was executed, **Inferred** was reasoned, **Unverified**
was not settled.

## It is neither Overseerr nor Jellyseerr

Seerr is the merged successor project at `github.com/seerr-team/seerr`. Both
predecessors are deprecated, and Seerr auto-migrates their config on first
start. The design names it directly and rules out both forks by name, the
foundation plan already cites upstream's own installation page as the source of
container port 5055, and the lineage is decidable from the inside: Overseerr is
Plex-only with no Jellyfin user import at all, while the running container
carries a `mediaServerType` enum including `JELLYFIN` and a
`POST /api/v1/user/import-from-jellyfin` route. Confirmed.

The practical consequence is that **the conventions differ from the images this
repository would otherwise reach for**. Overseerr and Jellyseerr API knowledge
transfers, because the codebase is recognisably Overseerr's — but do not pin
either image, and do not copy a `fallenbagel/jellyseerr` Compose file. The
LinuxServer-style `PUID`/`PGID` and `JELLYFIN_TYPE` conventions of those images
do not apply here. This is a young project: v3.0.0 shipped in February 2026 and
v3.4.1 in July.

```
image: ghcr.io/seerr-team/seerr:v3.4.1@sha256:f4768de5f616248d723e05891f3345a1402123775d03bf0890dbfedc0831bda1
```

The tag is `v`-prefixed and `:3.4.1` does **not** exist — a naive pin fails at
pull time with `not found`. Confirmed. Renovate's datasource must be given the
`v`-prefixed versioning or it will silently never offer an update.
`docker.io/seerr/seerr` is a mirror at the same index digest.

The image ships **no `HEALTHCHECK`** (`.Config.Healthcheck` is `null`,
confirmed), so `docker_compose_v2` with `wait: true` returns as soon as the
container is running — and Seerr takes several seconds after "running" to answer
HTTP, which means the next task races the server. The Compose file must supply
one, and the role should additionally keep a `uri` readiness loop.

## The API key is a genuine one-way credential

This is the best finding in the file. Seerr reads `API_KEY` from the
environment, and it does so on **every** start: a virgin config takes the value
as its key, and a stored value that has drifted is overwritten with the
environment's. Confirmed live — started with a vault-shaped value,
`GET /api/v1/settings/main` returned that exact key, and a wrong key returned
`403`.

So the credential is authored in vault, rendered into `.env` at `0600`, and
never read back. That satisfies the platform's hardest rule with no
compromise, and it is why Phase 4 needs **exactly one new vault key**,
`vault_seerr_api_key`. Seerr imposes no format — it compares the key as an
opaque string — so the platform's existing 32-hex convention is the right choice
for consistency with the `vault_arr_*` keys.

Two properties of the auth middleware the role depends on, both confirmed:
`X-API-Key` authenticates **as user id 1** and therefore inherits `ADMIN`; and
`X-API-User: <id>` impersonates any user. The second is how a contract test can
prove the second household user's permission split from the outside, and raise a
request *as that user*, without ever holding that user's password.

Everything else Seerr needs, the vault already holds: the Jellyfin administrator
pair, the single `vault_managed_users.jellyfin` entry, the Radarr and Sonarr API
keys, and an ntfy token. **Seerr needs no administrator password of its own** —
the owner row is created with a Jellyfin user type and no local password, and
the local-login route requires an email and password pair that only exists if
someone sets one. Confirmed. The design's "two explicit Seerr permission
identities" therefore resolve to identities that already exist.

## The pre-bootstrap takeover window

A virgin Seerr is not an unauthenticated *writer*. Every mutating route sits
behind an authentication check, and measured anonymously against the running
container, only `/api/v1/status` and `/api/v1/settings/public` answer 200 —
`/settings/main`, `/settings/jellyfin`, `/user`, `/request` and
`POST /request` all return 401. That specific hole is absent.

The exposure is different and it is structural. `POST /api/v1/auth/jellyfin` is
mounted **without** the authentication check, by necessity — it is how the first
administrator is created — and **the hostname of the Jellyfin server is taken
from the anonymous request body**. Its first-run branch fires whenever no user
exists or the media server type is unconfigured, and the only check it makes is
that the supplied account is an administrator *on the server the caller named*.

So between container start and the moment an administrator exists, any host that
can reach port 5055 can point Seerr at a Jellyfin server **they** control, be an
administrator there, and become Seerr's owner with full `ADMIN` — and thereby
attach Radarr and Sonarr and issue auto-approved requests. They never need a
household credential. Confirmed: the benign bootstrap performed during the
investigation *is* this attack, executed against a Jellyfin Seerr had no prior
knowledge of, returning `200` with `{"permissions":2,"id":1,…}`.

Confirmed that the window closes on its own once bootstrap has happened — the
same request with a foreign hostname afterwards returns
`500 {"error":"Jellyfin hostname already configured"}`.

Two consequences. The converge that starts the container **must complete the
bootstrap in the same play, before it yields**; there is no declarative way to
pre-close the window, because preseeding `settings.json` does not help — the
guard tests whether the user table is empty, regardless of what `settings.json`
says. And **a restore that brings back `settings.json` but not `db/db.sqlite3`
reopens the window**. Only the existence of user row 1 in the database closes
it, so the storage class must keep both, which it does: the config path is
already `critical`.

The design's own words — "Seerr is the most exposed of the set if it is ever
published beyond the LAN" — are correct afterwards and understated before.

`settings.json` in that config volume is written mode `0644` and holds the Seerr
API key, the Jellyfin token Seerr minted for itself, the session secret, the
VAPID private key, and later the Radarr and Sonarr keys and the ntfy token.
Confirmed. A `settings.old.json` is written beside it at the same mode with the
same contents one revision behind — **found during the promotion**, and it
belongs in the same class. It belongs in the runtime secret-bearing list beside Dozzle's users
file and Beszel's private key, not only in the `critical` recovery class.

## The wizard is bypassable, but not purely declaratively

Exactly one step must be an API call carrying a vault-authored credential, and
the design already sanctions that shape ("the role uses a supported local
bootstrap API that accepts the declared value"). Two pieces of state must exist
before the API is usable, in this order, both established by experiment:

1. **A user row with id 1.** Without it, a correct `X-API-Key` gets `403`,
   because the key resolves to user 1 and finds nothing. Measured on a fresh
   container with the correct key.
2. **A configured media server type**, or the Jellyfin route keeps re-entering
   its first-run branch.

`settings.public.initialized` is not a gate on the API at all — it only controls
whether the frontend redirects to `/setup`. It is set by
`POST /api/v1/settings/initialize`, which is reachable with the API key and is
an unconditional write, so guard it on the current value for `changed=0`.

Seeding the SQLite database directly was considered and rejected: it is a TypeORM
database with migrations and live WAL files, and the schema is not a stable
interface. So the bootstrap is `POST /api/v1/auth/jellyfin` with the
vault-authored Jellyfin administrator credentials, confirmed end to end.

**Corrected during the promotion.** The request body must carry
`serverType: 2` — `MediaServerType.JELLYFIN`. Without it the route answers
`500 {"message":"NO_ADMIN_USER"}`, which reads as "this account is not an
administrator on that server" and is not: `routes/auth.js` reaches that throw
only *after* passing the `IsAdministrator` check, when `body.serverType` is
neither `JELLYFIN` nor `EMBY`. Measured both ways against the pinned image with
an account that genuinely is a Jellyfin administrator.

The guard that makes it idempotent, both branches confirmed:

```
GET /api/v1/settings/main with X-API-Key
  → 403  not bootstrapped  ⇒ run the bootstrap        (changed: true)
  → 200  bootstrapped      ⇒ skip                     (changed: false)
```

Repeating the bootstrap is not harmful — it falls into an "update their info"
branch — but it is a write that mints a Jellyfin device session and makes the
play unconditionally changed.

### The one thing that is read back

At bootstrap Seerr calls Jellyfin and **creates a Jellyfin API token named
"Seerr" for itself**, storing it in its own settings. Confirmed on both sides:
Seerr reported the key and Jellyfin's key list showed it.

This does not violate the repository's rule as written — nothing is scraped back
into repository state, and the value lives only inside Seerr's own config — but
it deserves stating plainly in the promotion commit, because **Seerr's Jellyfin
access survives independently of `vault_jellyfin_admin_password` and is not
revoked by rotating it**. There is no environment variable to preseed it.
`POST /api/v1/settings/jellyfin` accepts an `apiKey` field, so a role could
overwrite it with a token the `jellyfin` role authors, but that is extra scope
that Phase 4 does not require.

## Users, and the permission split

`POST /api/v1/user/import-from-jellyfin` takes Jellyfin user GUIDs, which are
discovered rather than guessed: `GET /api/v1/settings/jellyfin/users` returns
username and id, so the role matches on username against
`vault_managed_users.jellyfin[*].username` and never hardcodes a GUID.

The import is cleanly idempotent — it creates only when absent and the response
body is the list of *newly created* users, so run 1 returned one entry and run 2
returned an empty list. Confirmed, not inferred. So `changed_when` keys on the
response length; the status code is `201` in both cases, so it cannot key on
that.

The permission API is idempotent only if the role reads first.
`GET /api/v1/user/:id/settings/permissions` is a clean comparable read, and the
matching write is `POST` to the *same* path — **corrected during the
promotion**: `PUT` there answers `405 PUT method not allowed`, and the route is
`userSettingsRoutes.post('/permissions', ...)`. The write is unconditional and
returns 200 with the same body on an identical request, so: read, compare,
write only on drift, which is the same shape the `arr` and `jellyfin` roles
already use.

The owner is the exception and cannot be written at all. `POST
/api/v1/user/1/settings/permissions` answers
`403 {"message":"You do not have permission to modify this user"}` — measured —
because the route refuses to modify the owner row. The bootstrap has already
set `ADMIN`, so the role asserts the owner's value rather than repairing it.

Permissions are bit flags, and `ADMIN` short-circuits every check, so the owner
needs the single bit `2` and nothing else — which is exactly what the bootstrap
set. The design asks that both users may request movies and series with
immediate automatic approval and no quota, with the second user holding no
service-administration permissions. That maps to:

| Identity | Value | Composition |
|---|---:|---|
| Owner, user id 1 | **2** | `ADMIN` |
| Second household user | **160** | `REQUEST` (32) + `AUTO_APPROVE` (128) |

Confirmed applied and read back. The broad `REQUEST` and `AUTO_APPROVE` bits
cover both movies and series; the narrower `*_MOVIE`/`*_TV` variants exist for
when you want one and not the other. 160 deliberately excludes every 4K bit and
every `MANAGE_*` bit, which is the "without service-administration permissions"
half. If issues are wanted later, `CREATE_ISSUES` and `VIEW_ISSUES` add to
`6291616`; the tighter value is the better starting point.

"No quota" means the quota fields left null, and confirmed: posting zeroes
stores them as null, because zero means unlimited. The defaults are already
null, so asserting them rather than omitting them turns a clause of the design
into a checked fact.

### The trap that would ship something passing every test and violating the design

`defaultPermissions` ships as `32` (`REQUEST`) and `newPlexLogin` ships as
`true`. Together they defeat the design's "newly discovered Jellyfin users do not
inherit these permissions automatically" clause twice over: the import path uses
`defaultPermissions`, and `newPlexLogin` means **any Jellyfin user who signs in
is silently created in Seerr** with those permissions. Confirmed from source and
from the live settings. The role must set `defaultPermissions: 0` **and**
`newPlexLogin: false`; confirmed applied and read back. `newPlexLogin` is named
for Plex but gates the Jellyfin path too: the branch is
`else if (!settings.main.newPlexLogin) { return next({status: 403, message:
'Access denied.'}) }`, reached for a Jellyfin account with no Seerr row.

**Added during the promotion, and it is the trap behind the trap.** There is a
third switch, `mediaServerLogin`, which also ships `true`, is exposed
anonymously beside the other two, and looks like the one to turn off. It is
not. It does not auto-create anybody; it enables Jellyfin sign-in *at all*, and
`routes/auth.js` returns `500 {"error":"Jellyfin login is disabled"}` for every
caller when it is false — the two imported household identities included.
Turning it off alongside `localLogin: false` would leave nobody able to reach
the service. The design's clause is carried by `defaultPermissions` and
`newPlexLogin` alone, so `mediaServerLogin` stays true and the role asserts
that it is.

Both halves of the clause were then proved from the outside rather than read
from the source, because every other proof in this file authenticates with the
API key or impersonates with `X-API-User` and both of those bypass sign-in
entirely. Against a live instance holding exactly the platform's settings — the
household user imported, `defaultPermissions: 0`, `newPlexLogin: false`,
`localLogin: false` — `POST /api/v1/auth/jellyfin` for the imported household
identity answered `200` with `{"id":2,"permissions":160}`, and the same request
for a Jellyfin account the platform never declared answered
`403 {"message":"Access denied."}`. Confirmed.

`localLogin` also ships `true`, leaving a second password-based authentication
path open on the most exposed service in the set. Nothing here sets a Seerr local
password, so set it false.

## Identity model, and the probe

**Neither `PUID`/`PGID` nor a gosu re-exec — use a Compose `user:`.** The image
sets `User: node:node`, uid 1000 and gid 1000; the entrypoint is the stock Node
one, which only prepends `node` to the command, never starts as root, and
performs no re-exec. Neither `gosu` nor `su-exec` is present. Upstream's own
docs confirm it from the other side by telling operators to chown the config
directory, because the container cannot adapt to the host. All confirmed.

The uid happens to match this platform's `nas_uid: 1000`; **the gid does not**
(1000 against `nas_gid: 100`). Left alone, Seerr would group-own its files
outside the platform's media group. So `user: "${NAS_UID:?}:${NAS_GID:?}"`,
confirmed writable — running with `--user 1000:100` started clean and created
`settings.json`, the database and the log directory. `UMASK` is not honoured by
this image; copying it from the arr services would be dead configuration a
reader mistakes for an enforced mode.

For the probe: `curl` is **missing** and `wget` is the **BusyBox applet, not
GNU wget** — `wget --version` fails with `unrecognized option`. Confirmed, along
with `node`, `nc` and `busybox` present and `python3`, `gosu` and `su-exec`
absent. Upstream's documented probe uses BusyBox-compatible flags and works:

```yaml
healthcheck:
  test:
    - CMD-SHELL
    - >-
      wget --no-verbose --tries=1 --spider
      http://127.0.0.1:5055/api/v1/settings/public || exit 1
```

Address `127.0.0.1` rather than `localhost`: `localhost` resolved to `::1` in
the container, and a v6-only resolution is a latent flake. The endpoint choice
matters — `/api/v1/settings/public` returns 200 anonymously both before and
after bootstrap, confirmed in both states, so the container never reports
unhealthy merely because it has not been configured yet.

## Everything else that must be read before it is written

Confirmed from source unless noted. `POST /api/v1/settings/radarr` and
`/sonarr` **blindly append**, computing the new id from the last element, so a
role that POSTs every converge grows a duplicate server per run and can never
report `changed=0`. Read, match on `name`, then `PUT /settings/radarr/:id`, or
POST only when absent. `POST /settings/radarr/test` validates connectivity
without writing and is the right readiness probe against the arrs.

`POST /api/v1/settings/main` is a deep merge, not a replace — confirmed, the API
key survived a partial post. Partial posts are therefore safe, but a nested
field cannot be unset by omitting it.

`POST /api/v1/settings/main/regenerate` rotates the API key from the web
interface, which breaks Ansible until the next container start re-asserts
`API_KEY`. Worth a line in the role's comment so a future reader knows why the
key comes back.

Seerr's ntfy agent **does** support authentication even though the defaults hide
it: a fresh instance returns only url, topic, priority and locale, which reads
as "cannot authenticate". It can — either basic or a bearer token, confirmed
accepted and persisted. The field names are `authMethodToken` (a boolean) with
`token` beside it, or `authMethodUsernamePassword` with `username` and
`password`; the agent builds `Bearer <token>` from the first. This platform's
ntfy is deny-all, so an unauthenticated agent would publish nothing and fail
silently.

**Corrected during the promotion.** `POST /api/v1/settings/notifications/ntfy`
*replaces* the agent object rather than merging into it — a body without
`embedPoster` dropped that key from the read-back — so the role sends the whole
declaration every converge and compares against the same shape. Unlike
`/settings/main`, which really is a deep merge.

`POST /api/v1/settings/radarr` does not validate connectivity either, which the
"read, match on name" rule already covers but is worth stating: a row naming a
host that does not exist was accepted with `201`, twice, producing ids 0 and 1.

The bootstrap, the import and the permission write are all real HTTP writes
against an external system and cannot be simulated, so under `--check` the role
emits a `debug` naming the predicted change, and the read tasks carry both
`changed_when: false` and `check_mode: false` so the comparison actually runs
during a review. Nearly every task in this role carries a credential — the
bootstrap carries the Jellyfin administrator password and every other request
carries the API key — so `no_log: true` is effectively universal, and each
redacted task should be preceded by a comment saying what is hidden, or a
redacted failure is unreadable.

`init: true` appears in upstream's Compose example and is worth carrying,
because `npm start` forks and without an init the container accumulates zombies.
Whether `tests/policy_test.rb` tolerates the key is **unverified** — no current
service uses it.

## The converge sequence

Every step below was confirmed reachable. Steps 8 and 9 are the only pair that
is not idempotent by construction, and the guard makes them `changed=0` on
reconverge; 10 through 18 are all read-compare-then-write.

```
 1 deployment_bundle tasks_from: target
 2 assert the vault credentials are single-line                       no_log
 3 render env.j2 → runtime .env, mode 0600
 4 docker_compose_v2 state: present, wait: true
 5 ntfy deployment report
 6 container_cpu verify
 7 wait: GET /api/v1/status until 200      changed_when: false, check_mode: false
 8 probe: GET /api/v1/settings/main with X-API-Key   403 → 9, 200 → 10
 9 bootstrap: POST /api/v1/auth/jellyfin with the vault Jellyfin admin
   and serverType 2, without which it answers 500 NO_ADMIN_USER
10 GET /settings/main; POST on drift: defaultPermissions 0,
   newPlexLogin false, localLogin false, the application URL
11 GET /settings/radarr; POST-if-absent or PUT-if-drifted
12 GET /settings/sonarr; POST-if-absent or PUT-if-drifted
13 GET /settings/jellyfin/users → map usernames to GUIDs
14 POST /user/import-from-jellyfin      changed_when: json | length > 0
15 GET /user → locate the two rows
16 GET /user/<id>/settings/permissions; POST the same path only on drift
   (160). The owner's 2 is asserted, never written: that route refuses it
17 GET /settings/notifications/ntfy; POST on drift, with the token
18 GET /settings/public; POST /settings/initialize when not initialized
19 platform_verify_seerr: assert the Jellyfin server is declared, both arr
   connections are present, both permission values are exact, and — through
   X-API-User — that the second user can raise an auto-approved request
```

Ordering: after Jellyfin in `site.yml`. The role waits on Jellyfin's, Radarr's
and Sonarr's readiness endpoints rather than using a cross-project `depends_on`.

## What remains unsettled

Two of the five entries this section carried were settled by the promotion and
are recorded here rather than deleted, because what they turned out to be is
the useful part.

- `tests/policy_test.rb` accepts `init: true`. **Settled.** The Compose checks
  are a list of required properties, not an allowlist of permitted keys, so
  nothing had to be taught the key.
- The ntfy topic for request events. **Settled by the operator on 2026-08-31:**
  Seerr gets its own ntfy user, ACL entry and token on a new `nas-requests`
  topic, minted by ntfy's own generator like the other three publishers. The
  platform's ntfy is deny-all, so an unauthenticated agent publishes nothing
  and fails silently; and a dedicated identity can be revoked without touching
  deployment reporting, which reusing `vault_ntfy_deploy_token` could not.
- Ownership and mode of the files Seerr creates on a real Linux bind mount.
  Docker Desktop masks it; only that `--user 1000:100` starts and writes was
  confirmed, and re-confirmed against the pinned digest during the promotion.
  Assert it in the Linux integration lane.
- `GET /api/v1/settings/jellyfin/library?sync=true` returned `404` in the
  sandbox, whose Jellyfin had no libraries at all, so "route requires configured
  libraries" and "route moved" could not be distinguished. Nothing in the Phase 4
  acceptance criteria depends on it.
- The end-to-end request proof — an auto-approved request producing a Radarr or
  Sonarr grab — was not executed, because no arr stack was running. The
  *authorisation* half was confirmed, and re-confirmed through `X-API-User`
  during the promotion; the *fulfilment* half belongs in the contract test's
  Linux lane.
