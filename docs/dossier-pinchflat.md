# Pinchflat dossier — Phase 2, after the promotion

Derived from `ghcr.io/kieraneglin/pinchflat` **v2025.6.6**, the digest
[`services/pinchflat/compose.yml`](../services/pinchflat/compose.yml) pins, run
as a virgin container with the basic-auth pair set and nothing else. Read
[the marker convention](service-dossiers.md#how-to-read-the-evidence-markers)
first: **Confirmed** was executed, **Inferred** was reasoned, **Unverified**
was not settled.

This file is written after its promotion rather than before it, which makes it a
different kind of document from the four that gate a `planned` project. It does
not ask whether Pinchflat should be deployed — it is deployed. It asks the
question the promotion did not: **what does the running application hold that
Ansible does not own**, and how much of that gap is closable at all.

The short answer is that the gap is real, large, and mostly not closable. The
promotion authored the one credential Pinchflat has and stopped, and stopping
was correct, because everything past that credential is behind an interface with
no machine contract.

## There is no configuration API

The router at v2025.6.6 defines exactly one route under its `:api` pipeline:

```
GET /healthcheck → HealthController :check
```

Everything an operator configures is a `:browser` route —
`resources /media_profiles`, `resources /sources`, and a `/settings` singleton
with `show` and `update`. Inferred from `lib/pinchflat_web/router.ex` at the
tag.

Confirmed against the running container, which is the part that matters, because
a router file does not tell you what a reverse proxy or a plug does to a request
in production:

```
/api                    500
/api/v1                 500
/api/v1/sources         500
/api/v1/media_profiles  500
/api/sources            500
/healthcheck            200   (and 200 without credentials)
```

Note the status. These are `500`, not `404` — a Phoenix `NoRouteError` rendered
through the `:api` pipeline, which has no error view for it. Anyone probing for
an API and reading `500` as "the server is broken" will conclude the wrong
thing; it means the route does not exist.

The one thing that looked like a JSON surface is not one. Phoenix will accept a
format suffix on a `resources` route, and both of these answer `200`:

```
/sources.json          200
/media_profiles.json   200
```

Both return **HTML** — the full `<!DOCTYPE html>` application shell, `<title>`
and all. Confirmed. There is no JSON representation of anything in this
application. Asking for one explicitly is refused rather than ignored:
`Accept: application/json` against `/media_profiles` returns `406`. Confirmed.

## The environment configures the container, never the application

`config/runtime.exs` at the tag reads 22 environment variables. Every one of
them is plumbing: `PORT`, `PHX_SERVER`, `SECRET_KEY_BASE`, the seven `*_PATH`
variables, `LOG_LEVEL`, `JOURNAL_MODE`, `BASE_ROUTE_PATH`, `ENABLE_IPV6`,
`ENABLE_PROMETHEUS`, `DNS_CLUSTER_QUERY`, `RUN_CONTEXT`, `TZ_DATA_PATH`,
`EXPOSE_FEED_ENDPOINTS`, `YT_DLP_WORKER_CONCURRENCY`, and the
`BASIC_AUTH_USERNAME`/`BASIC_AUTH_PASSWORD` pair the promotion authors.
Inferred from upstream source.

Not one of them sets a media profile, a source, an output path template, a
resolution, a codec preference, or a subtitle language. **There is no
environment variable this repository is failing to set.** The promotion's
Compose file is not incomplete; the application simply does not accept its
configuration that way.

## What a virgin container actually holds

Started clean, with the basic-auth pair and nothing else, the SQLite database at
`/config/db/pinchflat.db` holds:

```
settings.onboarding = 1        media_profiles = 0 rows
                               sources        = 0 rows
```

Confirmed. `onboarding = 1` is the first-login wizard, and it is the thing an
operator meets on a converged, healthy, fully verified deployment.

`sources.media_profile_id` is `NOT NULL`, so the ordering is forced: no source
can exist until a media profile exists, and no media profile exists until
somebody creates one through the browser. A Pinchflat that passes every task in
`roles/pinchflat` downloads nothing, and will download nothing, until a human
opens it. Confirmed.

The configuration surface is 13 settings columns, 24 `media_profiles` columns
and 29 `sources` columns. The settings the browser form actually exposes are
seven: `video_codec_preference`, `audio_codec_preference`, `youtube_api_key`,
`apprise_server`, `download_throughput_limit`,
`extractor_sleep_interval_seconds` and `restrict_filenames`. Confirmed by
reading the field names out of `GET /settings`.

Two columns in that table are not on the form and are worth knowing about.
`route_token` is generated at first start — the container under test produced
`5b33ac2d-…` — and it authorizes the token-protected `/sources/opml` route.
`pro_enabled` exists and is `0`. Neither is settable through any interface this
investigation found.

## The browser form is a writable interface, and it does work

This is the finding that makes the recommendation a judgement rather than a
constraint. Pinchflat's forms can be driven from Ansible. A media profile was
created end to end with `uri`-shaped requests:

```
GET  /media_profiles/new    → scrape _csrf_token   (56 bytes)
POST /media_profiles        → 302, row 1 present with exactly the submitted values
```

Confirmed — the row came back out of SQLite carrying the submitted
`output_path_template`, `shorts_behaviour` and `media_container`. The settings
singleton works the same way, with Phoenix's `_method=put` override:

```
POST /settings  _method=put  setting[restrict_filenames]=true → 302
                             restrict_filenames 0 → 1 in the database
```

Confirmed.

**The trap that will cost somebody an afternoon**: Phoenix binds the CSRF token
to the session cookie, so the token must be fetched and posted across one cookie
jar. Without that, every POST returns `500 InvalidCSRFTokenError`, which is
indistinguishable from an application fault and is not one. Confirmed — the same
request failed `500` without a shared jar and succeeded `302` with one. Any role
driving these forms needs cookie handling, which `ansible.builtin.uri` does not
do for you.

Creation is not blindly duplicating, either. A second identical media-profile
POST returns `200` with the form re-rendered and `has already been taken` in the
body, and the row count stays at 1. Confirmed. So the name is unique and a
repeat is refused rather than doubled — better than
[what the four planned projects do](service-dossiers.md#what-the-four-have-in-common),
where nothing is create-if-absent.

So why not do it? Because **writes work and reads do not**. There is no JSON
anywhere, so deciding whether a profile already matches its declaration means
either parsing the application's HTML or reading its SQLite schema directly.
The first breaks on any upstream template change and cannot be lint-checked; the
second couples this repository to an internal schema upstream migrates freely,
and would do it in the one direction — reads for the change decision — where the
coupling is invisible until it silently reports converged. Neither gives the
`changed_when` a task on this platform is required to compute honestly.

## A source cannot be declared offline, by anyone

The strongest reason not to reach further. `sources.collection_id`,
`collection_name` and `collection_type` are not operator inputs — Pinchflat
derives them by calling yt-dlp against the submitted URL when the source is
created. A source pointing at a channel that does not exist is **refused**:

```
POST /sources  original_url=https://www.youtube.com/@thischanneldoesnotexist000000
→ 200, form re-rendered, sources = 0 rows
```

Confirmed. The application resolved the URL, failed, and stored nothing.

The consequence is not about elegance. **No disposable lane can prove source
reconciliation**, because proving it requires reaching YouTube and resolving a
real channel from CI, from the Mac lane, and from the integration container.
That is a third-party dependency inside a convergence test, and it is the same
class of argument `roles/kapowarr` already makes about the ComicVine key. A
declared source would also be untestable in exactly the lanes that exist to
catch the bugs `--syntax-check` and `ansible-lint` cannot see.

Seeding the rows directly into SQLite does not escape this — it makes it worse.
It would write `collection_*` values that the application derives, which means
inventing values for columns whose authority is yt-dlp, not the operator.

## The three files under `/config/extras` are the honest surface

The container creates these on first start, all empty:

```
/config/extras/yt-dlp-configs/base-config.txt
/config/extras/cookies.txt
/config/extras/user-scripts/lifecycle          (mode 0755)
```

Confirmed present and empty on a virgin container. These are ordinary files on a
bind mount, which means they are exactly the kind of thing this repository
already knows how to own: a template rendered to a path, with a mode, that a
converge rewrites and a hand edit loses.

That they are *consumed* is Inferred, not Confirmed — proving it requires a real
download. Attempting to raise that to Confirmed by reading the release is a dead
end worth recording so nobody repeats it: `grep` for `base-config` across
`/app/lib` (2023 `.beam` files) returns nothing, because BEAM literal chunks are
zlib-compressed. The string is there; grep cannot see it.

`cookies.txt` is the one that carries a credential. A populated cookies file is
a logged-in YouTube session, and it belongs in the runtime secret-bearing list
beside Dozzle's users file and Beszel's private key — not merely in a recovery
class. It is also the file most likely to be created by hand, since a user
exports it from a browser.

## The shape this repository should take

Own the three extras files; document the rest as operator-owned and say so in
the role, not only in a dossier.

That boundary is defensible in a way "own everything" and "own nothing" both are
not. The extras files are declarative with no caveats — a template, a mode, a
converge that reverts drift, and an assertion that reads the file back. Media
profiles and sources are neither declarative nor testable, for the two separate
reasons above, and a role that half-owned them would be claiming a control
plane it does not have.

What that leaves unowned should be stated plainly wherever an operator will meet
it: **a converged Pinchflat is an empty Pinchflat**, and the media profile and
sources created on first login survive every subsequent convergence untouched.
That is the opposite of what
[`CLAUDE.md`](../CLAUDE.md) promises about this platform, and the exception
should be written down as an exception rather than left to be discovered.

## What remains unsettled

- Whether `base-config.txt`, `cookies.txt` and the `lifecycle` script are
  actually read at download time, and in what order they compose with a media
  profile's own options. Inferred only. Settling it needs one real download.
- Whether Pinchflat rewrites any of the three extras files itself. If it does,
  a template that owns them fights the application every converge — the failure
  mode [the Trailarr dossier](dossier-trailarr.md) found in `/config/.env`. Not
  tested; the container was never given work to do.
- Whether `route_token` rotates. If it is stable, it is a secret in the database
  and the security boundary should name it; if it rotates per start, it is not.
- Whether an upstream API is coming. The absence is a deliberate-looking
  omission in a project that otherwise has feed endpoints and a health route,
  and the recommendation above is worth revisiting if one lands.
- Whether the promotion's basic-auth pair protects the extras files at all — it
  does not, and nothing else does either. Anything with write access to
  `nas_docker_root/pinchflat/config` can supply yt-dlp arguments and a lifecycle
  script that Pinchflat will execute. Not a finding against the promotion, but
  the blast radius of that directory is larger than a config folder usually is.

## Reproducing the confirmations

```sh
docker run -d --name pf-probe -p 18945:8945 \
  -e TZ=UTC -e BASIC_AUTH_USERNAME=probe -e BASIC_AUTH_PASSWORD=probepass \
  -v "$PWD/config:/config" -v "$PWD/downloads:/downloads" \
  ghcr.io/kieraneglin/pinchflat:v2025.6.6

# no API: 500 is "no such route", not a fault
for p in /api /api/v1/sources /api/v1/media_profiles; do
  curl -s -o /dev/null -w "$p %{http_code}\n" -u probe:probepass "http://127.0.0.1:18945$p"
done

# the .json suffix answers 200 with HTML
curl -s -u probe:probepass http://127.0.0.1:18945/media_profiles.json | head -1

# a virgin database, read without disturbing the WAL
sqlite3 "file:config/db/pinchflat.db?mode=ro" \
  'select onboarding from settings;
   select count(*) from media_profiles;
   select count(*) from sources;'

# the form POST works, but only across one cookie jar
CSRF=$(curl -s -u probe:probepass -c jar.txt \
  http://127.0.0.1:18945/media_profiles/new \
  | grep -o '_csrf_token" type="hidden" hidden value="[^"]*"' \
  | sed 's/.*value="//;s/"//')
curl -s -u probe:probepass -b jar.txt -c jar.txt -o /dev/null -w '%{http_code}\n' \
  -X POST http://127.0.0.1:18945/media_profiles \
  --data-urlencode "_csrf_token=$CSRF" \
  --data-urlencode 'media_profile[name]=Platform declared' \
  --data-urlencode 'media_profile[output_path_template]={{ title }}.{{ ext }}' \
  --data-urlencode 'media_profile[preferred_resolution]=1080p'
# omit -b/-c and the identical request is 500, not 403

# a source against a channel that does not exist stores nothing
```
