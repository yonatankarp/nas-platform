# Gluetun and qBittorrent dossier — Phase 5, the torrent cutover

Derived from `qmcgaw/gluetun` **v3.41.3** and
`lscr.io/linuxserver/qbittorrent` **5.2.3_v2.0.14-ls473**, run as a real
two-container Compose stack with a shared network namespace. Read
[the marker convention](service-dossiers.md#how-to-read-the-evidence-markers)
first: **Confirmed** was executed, **Inferred** was reasoned, **Unverified**
was not settled.

Phase 5 differs from the other three dossiers in that it adds two containers to
an existing service project rather than promoting a planned one, so several of
its findings are about this repository's own checks rather than about the
images.

## Read this first: one unverified fact gates the whole phase

**`/dev/net/tun` on the AS6704T has not been checked.** It is present in Docker
Desktop's VM and on stock Linux, but ADM ships a vendor kernel. Without it
Gluetun cannot create a tunnel at all and nothing else in Phase 5 matters. It is
a one-line `ls -l /dev/net/tun` on the NAS and it should be the first thing
anyone does. `NAS_RENDER_DEVICE` is the existing pattern for parameterising a
device path if it turns out to need one.

Two further unknowns of the same kind: some WireGuard setups need
`sysctls: {net.ipv4.conf.all.src_valid_mark: 1}` (not needed under Docker
Desktop; whether the NAS kernel needs it is unverified), and whether Gluetun
tolerates `security_opt: [no-new-privileges:true]` was not tested — it should,
since it never re-execs with elevated privileges, but test it.

```
qmcgaw/gluetun:v3.41.3@sha256:fa19cc76b2af13d57a8d3dc3066f2ada061b1c761b8aecf989b3877c0486e027
lscr.io/linuxserver/qbittorrent:5.2.3_v2.0.14-ls473@sha256:304b19cf94bf4fda534e0b086cab9c5f1a9e139a8180c05c0ad7d2ba1526fa99
```

Gluetun's `latest` is newer than `v3.41.3` but is a moving tag, and everything
above it in the tag listing is a pull-request or test build. qBittorrent's
`lscr.io` and `linuxserver/` prefixes resolve to the same digest; use `lscr.io`
to match the SABnzbd line already in the file. Do **not** take the
`-libtorrentv1` variant — it is a separate tag lineage. Whether the LinuxServer
compound tag needs a Renovate `versioning` hint is **unverified**.

## Two checks in this repository forbid Phase 5 today

Neither is a detail, and both are cheaper to discover here than in a failing
run.

**`tests/policy_test.rb` forbids both containers from the downloaders Compose
file.** The CPU-policy check filters profiled non-job services *out* of the
expected Compose service set and then asserts **set equality** against the
services the file actually defines. Gluetun and qBittorrent carry
`compose_profile: torrent` in `config/media-acquisition.yml` and are not job
services, so the expected set for `downloaders` is `[sabnzbd, unpackerr]` and
adding the two containers fails `"downloaders: CPU policy must cover the exact
Compose service set"` on day one. Confirmed by reading the check. The design
anticipates the shape of the fix — profiled torrent services are checked against
the *active host* service set — and the current code conflates two different
questions: whether a service is expected in the file, and whether it is expected
to be running.

**The design's per-location transport selection is not deliverable as written.**
`config/media-acquisition.yml` gives Gluetun and qBittorrent a `torrent`
profile, but gives **SABnzbd and Unpackerr no profile at all**, and Compose
always starts profile-less services. So "each location may select Usenet,
torrent, or both" cannot be honoured: enabling torrent and disabling Usenet
still starts SABnzbd and Unpackerr. Confirmed from the catalog. Fixing it means
giving those two a `usenet` profile — which then trips the same set-equality
filter for *them*, changes their catalog entries, and changes the Phase 1 deploy
path. That is a real scope item the Phase 5 plan must budget for, not a detail.
Either budget for it or narrow the claim.

Related and inferred: the role currently gates the whole project deploy on
`media_usenet_enabled` alone, which must widen to include the torrent flag and
pass the profile list through (the Compose module supports `profiles` —
confirmed via `ansible-doc`). And the teardown path uses `remove_orphans: true`,
which does **not** remove profiled services that are merely outside the active
profile set — so turning the torrent flag back off would leave both containers
running. That needs its own `state: absent` call naming the profile.

## Containment is more provable than the design assumes

The design says "VPN routing and containment remain NAS-only acceptance because
the disposable Mac lane cannot establish the production tunnel." That is true of
the *positive* half only. **The negative half — the containment property that
actually matters — is provable anywhere, and was.**

Setup: Gluetun with `VPN_SERVICE_PROVIDER=custom`, `VPN_TYPE=wireguard`,
throwaway 32-byte keys and `WIREGUARD_ENDPOINT_IP=192.0.2.1` — TEST-NET-1, RFC
5737, guaranteed unroutable. Gluetun starts, installs its firewall, and never
connects. From a sidecar inside its namespace, confirmed:

```
curl -m 8 http://1.1.1.1/       → exit 28 (timeout), no response
curl -m 8 https://ipinfo.io/ip  → exit 6 (could not resolve)
```

The firewall it installed has `INPUT`, `FORWARD` and `OUTPUT` policies all
`DROP`, with `OUTPUT` accepting only loopback, established connections, the
container's own Docker subnets, the VPN endpoint on its UDP port, and `tun0`.
**The killswitch is a default-DROP output policy and it is in force from
container start, before the tunnel ever comes up.**

Four assertions follow, in increasing cost. The first two run in every lane.

**Structural, and free.** Read the qBittorrent container with
`community.docker.docker_container_info` — already used in this repository — and
assert that its network mode resolves to the Gluetun container, that its network
list is empty, and that it publishes no ports. That is a genuine `assert` over a
registered read, which is what `tests/policy_test.rb` accepts as verification,
and it cannot be satisfied by a container that has its own bridge. Mechanism
confirmed; the assertion itself is inferred.

**Killswitch, negative egress — demonstrated end to end.** In the disposable
lanes, deploy the torrent profile with the `custom` and TEST-NET configuration
above, relax `depends_on` from `service_healthy` to `service_started` in the lane
override (otherwise qBittorrent never starts, since the tunnel never comes up),
and assert both that a probe from inside the namespace cannot reach the internet
and that qBittorrent's web interface is nevertheless reachable through Gluetun's
publication. **The lane needs fake VPN inputs, not valid ones** — the values are
structurally shaped, not secret. That contradicts the design's "leave the torrent
profile disabled and therefore need no fake VPN credentials", and the
contradiction is worth raising: the cost is a handful of constant strings, and
the payoff is that the platform's most security-critical property stops being
attested by a human checklist while every lesser property gets a test.

**Positive egress identity — genuinely NAS-only.** Gluetun exposes the tunnel's
public address both as a file inside the namespace and on its control server.
With the tunnel down the value is the empty string, confirmed, so a non-empty
value is itself meaningful. The assertion is that Gluetun's reported address is
non-empty and differs from the host's own public address, which needs a working
tunnel and one outbound call from the host. It is also the weakest of the four:
it proves Gluetun's egress is not the host's, not that qBittorrent's is.

**Per-process binding — strongest, NAS-only, untested.** qBittorrent binds
whatever the namespace has, confirmed from its own log line. Setting its network
interface preference to `tun0` and reading it back through the preferences
object would turn "the namespace has no other route" into "the client is
explicitly bound to the tunnel". The preferences object round-trips exactly
(below), so the assertion is available — but binding to `tun0` was never tested,
because there was never a live tunnel.

On the NAS there is a fifth option worth naming: a live killswitch drill.
Gluetun's control server accepts `PUT /v1/vpn/status {"status":"stopped"}`
unauthenticated (see below), so the transition can be driven deliberately —
stop, assert the egress probe now fails, restart, assert the container returns
to healthy. That is destructive-but-recoverable and belongs in NAS acceptance,
not in every converge.

### The DNS leak path

Confirmed: with the output policy `DROP` and no tunnel, `getent hosts` from
inside the namespace fails as it should, but `nslookup example.com 127.0.0.11`
**succeeds**. Docker's embedded resolver lives in the namespace, but its
upstream queries are issued by `dockerd` on the host, outside Gluetun's
firewall.

Two mitigating facts, both confirmed. Gluetun rewrites `/etc/resolv.conf` to
point at its own resolver, and because a shared namespace makes Docker bind-mount
the *same* `resolv.conf` into both containers, qBittorrent inherits it — the two
containers showed identical content. And only an application that explicitly
addresses `127.0.0.11` leaks; qBittorrent does not (inferred). So the assertion
to write is about the *default* path — resolution through `resolv.conf` fails
when the tunnel is down and succeeds when it is up — and the `127.0.0.11` path
should be documented as an accepted residual risk rather than left undiscovered.

A side effect worth planning for, inferred: because Gluetun replaces the
nameserver, **container-name resolution on `media-control` stops working inside
the namespace**. qBittorrent needs to call nothing, so this is harmless — but it
makes the reverse direction the one that matters, and that direction needs an
alias.

## The sharpest trap: a Gluetun restart strands qBittorrent silently

The single highest-severity finding. Sequence executed, confirmed:

| step | gluetun | qbittorrent | web UI |
|---|---|---|---|
| steady state | `unhealthy` (fake tunnel) | `healthy` | `200` |
| `docker restart gluetun` | restarting | `healthy` | unreachable |
| +30s | up | `healthy` | unreachable |
| `docker compose up -d` (reports both `Running`) | up | `healthy` | unreachable |

After the restart, the qBittorrent container's namespace contained **only
`lo`** — `eth0`, `eth1` and `tun0` were gone. Its health log was an unbroken run
of exit code 0 throughout, because a probe that curls loopback still passes
inside an otherwise-empty namespace.

Three consequences. **The service is silently dead**: Dozzle's unhealthy-event
rule never fires and Beszel sees a running container, which is exactly the
failure mode this platform's verification policy exists to prevent. **The
Compose module cannot repair it**: its whole model is `compose up`, and
`compose up` reports no change — so the platform's converge-in-a-single-pass
property is violated by a condition the platform cannot even see. And
`restart: unless-stopped` on Gluetun makes it reachable in normal operation: any
crash, OOM or Docker daemon restart produces it.

The repair, inferred but built on a confirmed signal: read both containers with
`docker_container_info`, compare their start times, and restart qBittorrent when
it started before Gluetun did. That condition is false on a converged system and
true exactly once after a Gluetun restart, so a second converge reports
`changed=0`.

**And fix the probe so it cannot lie.** qBittorrent's healthcheck must traverse
something that dies with the namespace. The cheapest honest probe tests
Gluetun's control server alongside qBittorrent's own port, since the control
server is unreachable once the namespace is stranded. Both halves were confirmed
independently; the combined form was not run.

This is the architectural addition Phase 5 requires. Any plan that does not name
it ships a service that dies silently the first time Gluetun blinks.

## How the shared namespace constrains the Compose file

Three hard constraints, all confirmed by running `docker compose`:

- **`network_mode` and `networks` are mutually exclusive.** Compose rejects the
  project at parse time.
- **`networks: !reset null` does not rescue it** inside the same file. `!reset`
  is an override-merge affordance, not a same-file eraser.
- **`ports:` plus `network_mode` passes `docker compose config` and fails at
  runtime** with `conflicting options: port publishing and the container type
  network mode`. Loud, at least.

`services/downloaders/compose.yml` defines a shared defaults anchor carrying
`networks: [default, media-control]`, so **qBittorrent cannot use that anchor**.
Either split it into a networks-free base and a networks-carrying one, or write
qBittorrent's keys out in full. Small change; it stops a naive copy-paste dead.

qBittorrent therefore publishes nothing. All three publications belong to
Gluetun, which is what the catalog already encodes with `published_by: gluetun`.

**Host and container port must be identical for the web interface.** qBittorrent
5.x validates the `Host` header *including the port*, and publishing on a
different host port made every request — including a correct login — return
`401`, with the log saying `Invalid Host header, port mismatch`. Confirmed. That
is a nasty trap because it is indistinguishable from a bad password at the HTTP
layer. The catalog gets it right at `8082:8082`, and `WEBUI_PORT=8082` must be
set so the application agrees. **On the Mac lane this matters**: the port
allocator hands out an arbitrary host port, so the override must set both the
publication and `WEBUI_PORT` to that same number, or disable host-header
validation there. The existing acquisition Mac overrides only rewrite the host
side of the publication, and that shape is not sufficient here.

Publication through Gluetun works without opening firewall input ports —
confirmed, the web interface answered on the host — because Docker's DNAT lands
on the container's own address, which Gluetun's rules already permit. Inbound
*peer* traffic is different: it arrives on `tun0`, for which there is no input
rule, so accepting peers needs the VPN-side input port and generally provider
port forwarding. That was not tested (**unverified**). It is worth questioning
whether the peer port should be published on the host at all, since publishing
it opens a LAN-facing path into the isolated namespace and the design already
says no public ingress.

**The `media-control` alias is required.** Under the shared namespace the DNS
name on that network is `gluetun`, not `qbittorrent`, because qBittorrent has no
attachment of its own. Radarr and Sonarr would have to configure a download
client at `http://gluetun:8082`, which reads as a mistake and breaks the design's
promise of stable service names. Adding `aliases: [qbittorrent]` to Gluetun's
`media-control` attachment restores the expected name. The mechanism is standard
Compose; it was not tested in this configuration.

**Gluetun must have zero host state.** An existing check requires that no
`nas_storage` path is declared under Gluetun's directory, and the storage list is
compared for exact equality. So Gluetun gets no volumes at all. Consequences,
confirmed: its server list is written fresh at every start from data embedded in
the binary, so nothing is lost, but the updater period must stay at its default
of zero because updates could not persist; its control-server auth config file
**cannot be provided**, which decides the next section; and secret-file credential
delivery is unavailable, so environment variables it is. Port-forwarding state is
ephemeral, so a forwarded port is renegotiated each start (inferred).

**Gluetun's control server is unauthenticated for the routes that matter.** With
no auth config file — which the previous paragraph makes unavoidable — confirmed:

| request | result |
|---|---|
| `GET /v1/vpn/status` | `200 {"status":"running"}` |
| `GET /v1/publicip/ip` | `200` |
| **`PUT /v1/vpn/status {"status":"stopped"}`** | **`200 {"outcome":"stopped"}`** — tunnel stopped |
| `GET /v1/vpn/settings` | `401 Unauthorized` |

So v3.41's role-based auth protects the newer routes and leaves the legacy status
routes public **in both directions**: anyone who can reach the control port can
stop the tunnel. The mitigation is confirmed working — bind the control server to
loopback, after which it listens only on `127.0.0.1` and is reachable solely from
inside the shared namespace, which is exactly where the containment probes run.
Never publish it, and never let it bind the control-network interface.

**No `privileged: true` is needed**, which matters because the policy test
rejects it outright. Everything here ran with `cap_add: [NET_ADMIN]` and the tun
device mapped in, and the repository already permits both — `services/beszel/compose.yml`
uses `cap_add` alongside `devices:` and even host networking, and no policy check
touches `cap_add`, `devices`, `sysctls` or `network_mode`. Confirmed by reading
the compose policy block, which inspects only image, build, privileged, restart,
healthcheck, the Dozzle label, logging, the CPU keys and volumes. Beszel also
sets the bar for *how* to take an exception: its host networking carries a
three-line comment explaining why it exists and what compensates for it.
Gluetun's `NET_ADMIN` deserves the same.

## Probes: neither image takes the obvious one

Gluetun is busybox plus a single static Go binary. **`curl` is absent.** Use its
own subcommand:

```yaml
healthcheck:
  test: [CMD, /gluetun-entrypoint, healthcheck]
```

It is not a port probe — it runs a real reachability test through the tunnel and
drives Gluetun's self-repair loop, which was watched tearing down and re-dialing
on a roughly six-second cycle. Confirmed exiting 1 with the tunnel down and the
container reporting `unhealthy`. A port probe would report healthy with a dead
tunnel, which is the wrong failure in the most expensive place. The image's own
5s interval is far tighter than every other service here; loosen it to 30s and
give it a start period long enough to dial.

`depends_on: {gluetun: {condition: service_healthy}}` therefore means qBittorrent
will not start at all until the tunnel is genuinely up — the correct posture, and
also why the disposable lanes need the relaxation noted above.

qBittorrent has `curl`, but **every API route returns `403` unauthenticated**, so
`curl --fail` — which is what the SABnzbd probe in the same file uses — reports
unhealthy forever. Accept the status explicitly:

```yaml
healthcheck:
  test:
    - CMD-SHELL
    - >-
      curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8082/api/v2/app/version
      | grep -qE '^(200|403)$$'
```

Confirmed reporting `healthy` in the real stack. Note the doubled `$` — Compose
interpolates, and the SABnzbd probe already escapes the same way. And extend it
per the stranded-namespace section above, or it lies.

## Credentials

### qBittorrent broadcasts an administrator password unless the platform seeds one

qBittorrent 5.2.3 is **not** an unauthenticated writer. Confirmed on a fresh
config directory: every API route returns `403` without a session, including
from `127.0.0.1` **inside the container** — and that last one matters here,
because under a shared namespace "localhost" includes another container. Both
localhost-bypass preferences read false.

But the credential that does exist is broadcast. There is no default
`admin/adminadmin` any more; instead the application mints a **fresh random
nine-character password on every container start and prints it to stdout** —
which is to say into Docker's json-file log, which is to say into Dozzle, which
this platform publishes on the LAN. Confirmed, with a different value on each of
three starts. And the config file on first start contains no username and no
password hash at all, so the platform cannot know the value without reading it
back out of a running service, which the credential-direction rule forbids.

**The fix is declarative and was proven to suppress the message entirely.**
Compute the hash on the controller and seed the config file before first start:

```python
hash = hashlib.pbkdf2_hmac('sha512', password, salt, 100000, 64)
line = '@ByteArray(%s:%s)' % (b64(salt), b64(hash))
```

The parameters were verified by reproduction, not by reading documentation: a
password was set through the API, the resulting value read back out of the file,
and the exact hash re-derived — HMAC-SHA512, 100 000 iterations, a 16-byte salt,
a 64-byte key, both halves base64 and colon-separated inside `@ByteArray(...)`.
10 000 and 1 000 iterations produced different values.

Results, all confirmed: **the temporary-password message never appears in the
logs at all** — the broadcast is eliminated, not merely superseded; the vault
identity logs in and the API answers; anonymous still gets `403`; and after the
application rewrote its own config file and the container restarted, the hash
line was byte-identical.

This is CLAUDE.md's own rule applied literally — "Where a service would normally
hand a human a generated value to copy-paste, this platform supplies its own
instead" — and there is a direct in-project precedent: the role already seeds
SABnzbd's ini from a template with `force: false`, stat-guarded, seeding once and
never fighting the application afterwards. A qBittorrent template beside it with
the same shape is the answer. The salt should be vault-authored and stable; with
`force: false` the file is written only once anyway, so idempotence holds either
way, but a stable salt makes the artifact reproducible.

Reconciliation afterwards follows the existing probe pattern: present the vault
identity, probe anonymously, and assert the first is accepted and the second
refused. The password is **absent** from the preferences object — confirmed — so
it can never be read back, and presenting it is the only proof available. If the
vault identity is refused, the platform is holding an identity it did not author.
qBittorrent has one recovery path that a purely API-driven service lacks: the
password lives in a file the platform can rewrite while the container is stopped.
Whether to take that path or refuse loudly and demand operator action is a design
decision, and precedent argues for refusing.

### Gluetun's inputs are third-party and provider-varying

Gluetun is configured entirely by environment variables — its image carries
around 130 defaults and every provider input is one of them, with no config file
to template. Its inputs are also 100% third-party values that cannot be
generated. Confirmed by running the pinned image against eight providers with
nothing set and reading each validation error.

**WireGuard is supported for exactly nine providers** — airvpn, custom,
fastestvpn, ivpn, mullvad, nordvpn, protonvpn, surfshark, windscribe — and every
other provider in the image's 24-entry list is OpenVPN-only. Confirmed, along
with the required minimum per shape: a named WireGuard provider needs a private
key and an interface address; `custom` additionally needs the peer public key
and endpoint; OpenVPN needs a user and password, except airvpn which needs a
client certificate and key.

The way to express that without pinning the platform to one provider (inferred,
following the existing "operator-owned choice with platform-owned plumbing"
pattern): vault authors an **opaque map** rather than a fixed key set;
`roles/vault_contract` validates the *shape* rather than the provider — that the
provider is one of the known values, that the VPN type is one of two, that
WireGuard implies its two required keys and a provider from the nine, that
OpenVPN implies its own, and that every key and value matches a strict
single-line pattern, which is the existing malformed-value guard generalised;
and the role renders the map's pairs verbatim into the already-`0600` `.env`
under `no_log`. Secret-file delivery is the alternative and it is unavailable,
because Gluetun may have no volumes.

So four vault keys in total (inferred): the qBittorrent administrator username
and password, its password salt, and the VPN settings map. All four land in the
downloaders expectations file and in the credential chain
[Adding a service](adding-a-service.md#when-the-service-has-credentials)
enumerates.

## The reconcilable surface is genuinely idempotent

Tested live against an authenticated qBittorrent session.

**Preferences round-trip exactly.** The preferences object has 223 keys; writing
a subset writes only the named keys and a follow-up read returns exactly what was
written. Confirmed. So read, compare, write-only-if-different, and a second
converge reports `changed=0` — the same shape the SABnzbd reconciliation in this
role already uses.

Defaults worth owning explicitly, confirmed on a fresh install: the save path
and temporary path both default under `/downloads` and must move under the
acquisition tree; `temp_path_enabled` defaults false; `disk_cache` defaults to
`-1`, meaning proportional to RAM, which is exactly what the design forbids
leaving implicit; automatic torrent management should be on so categories drive
save paths; local service discovery is pointless inside the namespace; and
`bypass_local_auth` must **stay** false, because localhost here is shared with
Gluetun.

**Categories need read-then-reconcile.** Creating a category twice returns
`409`; editing one twice returns `200`; the listing is a full map. Confirmed all
three. So read once, create only names absent from the read, edit only where the
save path differs, and a converged system issues neither write. A blind create
loop would report changed forever *and* fail on the 409. The category names
mirror the existing SABnzbd map with the transport swapped, one per importer.

Two things the design's hardlink proof depends on, and **neither is a
qBittorrent setting** (both inferred). A hardlink needs source and destination on
one filesystem *and* inside one container's mount namespace, so qBittorrent must
see the same host paths at the same container paths the arrs do, or the path
Radarr is handed will not resolve. And seeding requires the source to survive, so
the arrs must be importing by hardlink rather than move — which is an `arr`-role
setting readable through their own API, and it must be part of the Phase 5 slice.
An end-to-end torrent download and an actual hardlink were **not** exercised;
that needs a real tracker and a live tunnel.

## Identity model

`PUID`/`PGID`, and the mechanism is **s6, not gosu**. Confirmed inside a running
container: the s6 init tree runs as root and drops the application to a user
whose uid and gid it has remapped to the supplied pair, and `gosu` is not
present. So `PUID`, `PGID`, `UMASK` and the port variables in the environment,
and **no Compose `user:`** — setting one would break the s6 init and prevent the
remap entirely.

Gluetun runs as root inside its own namespace and needs to; it manipulates routes
and iptables, writes no files here, and the design already exempts it from the
shared media identity.

Bind-mount writability was confirmed on the container side, but both mounts
reported `0:0` from inside the container while the host-side files were owned
otherwise — the known Docker Desktop behaviour. **The uid, gid and mode
assertions the design requires cannot be validated on a Mac** and must run in the
Linux integration lane or on the NAS.

## What remains unsettled

- **`/dev/net/tun` on the AS6704T.** Gates everything.
- Whether the NAS kernel needs the WireGuard `src_valid_mark` sysctl, and whether
  Gluetun tolerates `no-new-privileges`.
- Anything requiring a live tunnel: a real provider connection, the positive
  egress-IP comparison, port forwarding, inbound peer connectivity, and binding
  qBittorrent to `tun0`.
- Any end-to-end torrent download, import or hardlink.
- The `media-control` alias in this configuration.
- Renovate's handling of the LinuxServer compound tag.
- Why Gluetun's image source label points at a fork of the upstream repository.
  Noted, not explained.

Beyond that, Phase 5 is feasible under this repository's constraints. Nothing in
it requires breaking a rule the repository declares inviolable: no privileged
container, digest-pinned multi-arch images for both, a credential model that
reads nothing back from a running service, a reconcilable surface that converges
to `changed=0`, and real verification rather than a `debug` named "verify" — in
every lane, structurally always and behaviourally with a fake tunnel. What it
requires is the Gluetun-restart repair, the two policy changes above, and that
one `ls`.
