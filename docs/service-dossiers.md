# Service investigation dossiers

Four media-acquisition projects remain `planned` in
[`services/manifest.yml`](../services/manifest.yml). Each was investigated once,
against upstream source *and* a running container, before any promotion was
attempted. The files below are what those investigations found, so the person
who writes the promotion does not have to repeat them.

A dossier is not a design and not an approval. It records what the deployed
version of a service actually does, which of the repository's own rules that
behaviour collides with, and which questions were left open. Where it proposes
a shape, the shape is a suggestion carrying whatever evidence it has, and the
promotion is still free to choose differently.

- [Bindery](dossier-bindery.md) — Phase 2 unit B, ebooks and audiobooks
- [Trailarr](dossier-trailarr.md) — Phase 3, local trailers
- [Seerr](dossier-seerr.md) — Phase 4, requests
- [Gluetun and qBittorrent](dossier-gluetun-qbittorrent.md) — Phase 5, the
  torrent cutover

The design they are read against is
[the media acquisition platform design](superpowers/specs/2026-08-21-media-acquisition-platform-design.md).
[Adding a service](adding-a-service.md) is the mechanics; a dossier is the part
that mechanics cannot tell you.

## How to read the evidence markers

Every non-obvious claim in these files is marked, and the marker is the point.
A reader must be able to tell a measurement from an argument, because the two
fail differently: a measurement goes stale when the version moves, and an
argument was never true in the first place if its premise was wrong.

**Confirmed** means observed — a request that was actually issued against a
running container, a value read out of a running process, or a line read out of
a file in this repository. Every HTTP status quoted under this marker was
returned by a real server.

**Inferred** means reasoned from upstream source or from repository precedent,
but not executed. Upstream source is a strong premise and still only a premise:
each dossier found at least one place where the source read one way and the
running container behaved another, which is why the distinction is kept.

**Unverified** means the investigation could not settle it and says so rather
than guessing. These are the items that gate a promotion, and they are collected
at the end of each file.

## The pins these files rest on

Behaviour is a property of a version. Each dossier is derived from exactly one
image, digest-pinned the way `tests/policy_test.rb` requires — a readable tag
for humans and Renovate, and the top-level manifest-list digest for
reproducibility. When Renovate moves one of these, the findings are suspect
until re-derived, in the same way
[the Bazarr provider schemas](bazarr-providers.md) are re-derived when that pin
moves.

```
ghcr.io/vavallee/bindery:v1.33.2@sha256:3778b97d8651cf51da57910ce4e4a5b175b42f9bbba55c5c9b07b16309144013
docker.io/nandyalu/trailarr:0.11.3@sha256:86d6ae3dffa583261f3281017106ebefc68693018e3fe8d1c58c6e731d88e4b1
ghcr.io/seerr-team/seerr:v3.4.1@sha256:f4768de5f616248d723e05891f3345a1402123775d03bf0890dbfedc0831bda1
qmcgaw/gluetun:v3.41.3@sha256:fa19cc76b2af13d57a8d3dc3066f2ada061b1c761b8aecf989b3877c0486e027
lscr.io/linuxserver/qbittorrent:5.2.3_v2.0.14-ls473@sha256:304b19cf94bf4fda534e0b086cab9c5f1a9e139a8180c05c0ad7d2ba1526fa99
```

All five publish `linux/amd64` and `linux/arm64`, so one pin resolves on the
AS6704T and on an arm64 Mac lane. Each was taken from the top-level `Digest:`
of `docker buildx imagetools inspect`, never a per-platform entry. Confirmed
for all five.

## What the four have in common

These are the findings that repeated, and they are worth knowing before reading
any single file.

**Three of the four hand the administrator account to whoever arrives first.**
Bindery's `POST /api/v1/auth/setup` is anonymous until a user exists and then
409s forever. Seerr's `POST /api/v1/auth/jellyfin` must be anonymous and takes
the Jellyfin hostname from the request body, so the caller supplies the server
that vouches for them. Trailarr is the mirror image: it ships a *published*
default administrator, so there is no window to win — it is simply open. In all
three the converge that starts the container has to close the identity in the
same play. There is no safe "deploy now, secure on the next run".

**Every one of them puts a credential somewhere the security boundary has to
learn about.** Bindery's backup is a whole-database copy and it stores every
credential in plaintext. Seerr's `settings.json` is mode `0644` and holds its
API key, the Jellyfin token it minted for itself, `sessionSecret` and
`vapidPrivate`. Trailarr writes the administrator's bcrypt hash into
`/config/.env`. qBittorrent prints a fresh random administrator password to
stdout on every start, which on this platform means into Dozzle. Each of those
belongs beside Dozzle's users file and Beszel's private key in the runtime
secret-bearing list, not merely in a `critical` recovery class.

**No probe copied from an existing service survives contact with these images.**
Bindery is distroless and has no shell at all. Seerr has BusyBox `wget` and no
`curl`. Gluetun has no `curl`. qBittorrent answers `403` on every API route
without a session, so `curl --fail` reports unhealthy forever. Trailarr is the
only one where the repository's usual `curl --fail` shape is correct. Read what
is in the image before writing the healthcheck.

**Reaching another platform service is the normal case here, not the exception.**
Pinchflat's Compose comment says it "calls no other platform service, so it
stays off the media-control network". Bindery, Trailarr and Seerr all call one,
so all three join `media-control` — and both existing acquisition contracts
assert the *absence* of a `networks` key, so those assertions must not be
copied.

**Nothing in any of the four is create-if-absent.** Bindery 500s on a duplicate
user or root folder and silently duplicates a Prowlarr instance. Trailarr's
`POST /api/v1/connections/` produced ids 1, 2 and 3 from three identical
requests. Seerr's `POST /api/v1/settings/radarr` appends unconditionally.
qBittorrent's `createCategory` 409s the second time. Every mutation in every one
of these roles is read-then-decide, and none of that is visible to
`--syntax-check` or `ansible-lint` — only the idempotence lane finds it.
