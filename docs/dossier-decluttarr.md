# Decluttarr dossier — before a container is added

Derived from `ghcr.io/manimatter/decluttarr` **v2.1.0**, run on 2026-09-14
against lab containers of this platform's own Sonarr 4.0.19, Radarr 6.3.0 and
SABnzbd 5.1.3 pins, plus the upstream tree at tag `v2.1.0` (commit `dd474de`,
which is the commit the image labels itself with). Read
[the marker convention](service-dossiers.md#how-to-read-the-evidence-markers)
first: **Confirmed** was executed, **Inferred** was reasoned, **Unverified**
was not settled.

```
image: ghcr.io/manimatter/decluttarr:v2.1.0@sha256:c06d48426b612b845f2406c2d045f266468a6390faf87aea796d497a2935ec95
```

The index publishes `linux/amd64` and `linux/arm64`, and `:latest` resolves to
the same digest today. There is no un-prefixed `2.1.0` tag. Confirmed. The lab
ran the arm64 image, so everything below marked Confirmed was observed on arm64
and not on the AS6704T.

#632 proposed Decluttarr for one job this platform has nobody doing, searching
the backlog, and asked for this file before any role. Its short answer is that
the search half is deployable, but three findings decide the shape more than
the feature list does:

- **A container refused at startup crash-loops, reports healthy and pages
  nobody.** A failure that arrives while it runs pages once, then joins that
  loop.
- **The search throttle is the arr's, not Decluttarr's**, and it only exists
  while an indexer answers.
- **The blocklist column in #632 was inverted**, which changes why
  `remove_failed_imports` has to stay off, though not the conclusion.

## A refusal at startup crash-loops, reports healthy, and pages nobody

Three properties compose, and each was measured separately.

**The image's healthcheck cannot fail.** The Dockerfile declares
`HEALTHCHECK CMD pgrep -f main.py || exit 1`. Docker runs a `CMD` string form
through `/bin/sh -c`, so the shell's own command line contains `main.py`, and
`pgrep` excludes only itself, not its parent. A container whose only process was
`sleep 600` reported `healthy`, exit 0, with `pgrep` printing the PID of the
healthcheck's own shell. Run by hand, the same thing names the match outright:

```
$ docker run --rm --entrypoint /bin/sh ghcr.io/manimatter/decluttarr:v2.1.0 -c 'pgrep -af main.py || exit 1'
1 /bin/sh -c pgrep -af main.py || exit 1
```

Confirmed. The health status says nothing about the application.

**Every startup refusal exits 0.** Decluttarr's refusals all go through
`wait_and_exit` in `src/utils/common.py`, which sleeps thirty seconds and calls
`sys.exit()` with no argument. Two were driven against the lab, and both logged
their reason, waited 30 seconds and exited `0`. Confirmed:

- a wrong Sonarr API key (`401 Client Error: Unauthorized`, with the tip
  `Have you configured the API_KEY correctly?`);
- Radarr's UI language set to a non-English value (`Decluttarr only works
  correctly if UI language is set to English`).

An unreachable SABnzbd and a configuration naming no arr at all take the same
helper. Inferred, from `_download_clients_sabnzbd.py` and `_instances.py`.

**Neither Docker nor Dozzle treats that as a failure.** `tests/policy_test.rb`
requires `restart: unless-stopped`, which restarts a container whatever its exit
code: under it the bad-key container restarted, and Docker emitted `die` with
`exitCode=0`. Confirmed. Dozzle's `die` rule excludes exit codes `0`, `130` and
`143` (`roles/dozzle/defaults/main.yml:107`). Confirmed, read from the tree.

So a Decluttarr that starts against a wrong key, an arr in another language, or
an arr it cannot reach restarts every thirty seconds indefinitely, reads
`healthy` whenever it is asked, and sends nothing.

**A failure after a clean start is different, and it does page once.** Each of
these was driven against a container that had already logged `OK | …` and run a
cycle:

- a proxy in front of Sonarr switched to a wrong key (`401 … /api/v3/wanted/missing`);
- the arr's container stopped (`ConnectionError`);
- the arr's container paused for fifty seconds (`Read timed out. (read timeout=15)`).

Every one ended in a traceback and exit `1`. Confirmed by the verification pass
on this file. Nothing in the job loop catches what `make_request` re-raises.
Inferred, from `src/utils/common.py` and `main.py`. Dozzle's `die` rule pages on
exit `1`. After that, a key that is still wrong puts the restarted container into
the exit-0 loop above. So a rotated key pages once and then goes quiet, and an
arr recreated by a converge or a digest automerge while Decluttarr runs will
probably page once too. Inferred.

The one refusal that *does* page is running it
as a non-root user: `/app` is root-owned, the log directory is the relative path
`./logs`, and under `--user 1000:1000` the process died at start with
`PermissionError: [Errno 13] Permission denied: 'logs'` and exit `1`. Confirmed.

It runs as **root**. The image sets no `USER` and no entrypoint, its command is
`python main.py`, and `id` inside it prints `uid=0(root)`. Confirmed. Upstream's
README shows `PUID` and `PGID` in its Compose example, and nothing in the source
reads either. Inferred, from a search of `src/` and `main.py`.

What a role should take from this: its verification cannot trust the health
status, nothing that watches exit codes will see a refusal loop, and
`RestartCount` cannot be the signal either, because a short arr outage moves it
too. What *does* distinguish the states is the log since the container's last
start:

- successful setup prints `OK | Sonarr (http://sonarr:8989)` for each instance;
- a refusal prints `Decluttarr will wait for 30 seconds and then exit.`

Both lines are Confirmed. A contract that requires one `OK |` line per
configured instance since the last start, and no refusal line after it, would
tell a working container from a looping one. That design is Inferred.

## Test mode suppresses every write, the search half included

`make_request` returns a dummy `200` for every `PUT`, `POST` and `DELETE` while
`TEST_RUN` is on. Inferred, from `src/utils/common.py`. The search commands are
`POST /api/v3/command`, so test mode sends none of them either. Confirmed with
`SEARCH_MISSING` on, through four cycles against Sonarr and Radarr:

- neither arr's command list gained an `EpisodeSearch` or `MoviesSearch`;
- each cycle logged `Job 'search_missing' triggered a search for 3 episodes`;
- the DEBUG log showed `[Test Run] Simulating POST request … 'EpisodeSearch',
  'episodeIds': [19, 20, 21]` for the same three IDs every time.

For removals it holds too, and the log cannot show that it held. A probe NZB
was added straight to SABnzbd in Sonarr's category, which makes it an orphan in
Sonarr's queue. Under `TEST_RUN=True`, `remove_orphans` logged:

```
INFO    | Job 'remove_orphans' triggered removal: Decluttarr.Orphan.Probe.S01E01.720p
```

The job stayed in SABnzbd's queue. With `TEST_RUN=False` the log printed that
same line, word for word, and the job was gone from SABnzbd's queue and history.
Confirmed.

The second test-mode cycle then reported `Removal Jobs: All jobs passed (Queue
is clean)` while the probe was still queued. Confirmed. The cause is that the
removal handler records the download as deleted whether or not the `DELETE`
went out. Inferred, from `src/jobs/removal_handler.py`. So a test-mode log is a
forecast for its first cycle only.

This is the #550 finding again from the other side. Radarr and Sonarr log
identically whether a dry run is on or off. So does Decluttarr at its default
`INFO` level, apart from the `TEST MODE IS ACTIVE` banner at start. Only at
`DEBUG` does each suppressed write log `[Test Run] Simulating …`. The only proof of a dry run is the
download client's queue and the arr's command history. A `TEST_RUN: true` first
deployment proves which items would be selected. It says nothing about search
volume, because no search is sent.

## The search throttle belongs to the arr, and needs an indexer to exist

Each cycle, `search_missing` does the following for every arr. Inferred, from
`src/jobs/search_handler.py` and `src/utils/wanted_manager.py`:

1. Reads the whole `wanted/missing` list, with `pageSize` set to its
   `totalRecords`.
2. Drops items already in the queue.
3. Drops items whose `lastSearchTime` is newer than
   `MIN_DAYS_BETWEEN_SEARCHES`.
4. Posts the first `MAX_CONCURRENT_SEARCHES` IDs as one `EpisodeSearch` or
   `MoviesSearch` command.

Decluttarr holds no state for any of this. The throttle is the arr's own
`lastSearchTime` field.

**With one indexer, progress is kept in the arr and survives a recreate.** A
Newznab stub was registered in Sonarr, and the backlog was Breaking Bad's 62
missing episodes. Confirmed:

| Container | Cycle | Episode IDs searched |
|---|---|---|
| First | 1 | 19, 20, 21 |
| First | 2 | 22, 23, 24 |
| First | 3 | 25, 26, 27 |
| Recreated | 1 | 27, 28, 29 |

Sonarr stamped `lastSearchTime` on each episode as its search ran. Episode 27
was searched twice. Its first search was still running when the recreated
container read the wanted list, so no timestamp had been written yet.
Decluttarr does not wait for a command to finish. At the default ten-minute
`TIMER` that overlap should be rare. Inferred.

**With no indexer, nothing throttles at all.** Before the stub existed, six
successive containers each sent `EpisodeSearch` for `[19, 20, 21]` on every
cycle. Sonarr completed every one of them and never set a `lastSearchTime`.
Confirmed.

The cause is in the arrs' own source at the pinned versions. Sonarr
`ReleaseSearchService.cs:533-541` at `v4.0.19.2979` and Radarr
`ReleaseSearchService.cs:117-125` at `v6.3.0.10514` both write the timestamp
only `if (indexers.Any())`. Inferred. When every indexer is disabled, the arr
also sends no indexer requests, so the loop churns arr commands without spending
API budget. Inferred.

**What a cycle costs.** Sonarr searched each episode in a command separately:
its log carried one `Searching indexers for [Breaking Bad : S01E01]` line per
episode, not one per season. Confirmed. That makes each cycle up to
`MAX_CONCURRENT_SEARCHES` searches per arr, multiplied by the number of active
indexers. At the defaults (`TIMER` 10, three per cycle) that is 432 a day per
arr per indexer while the backlog lasts. After that, roughly the wanted list
divided by seven per day. Inferred.

The arrs' indexers on this platform are Prowlarr's proxies. How many real
indexers stand behind them, and what each allows per day, is Unverified here and
decides the two values.

## #632's blocklist column was inverted

Every removal is `DELETE /api/v3/queue/{id}` with `removeFromClient: true` and a
per-job `blocklist` flag. At v2.1.0 the flags are these. Inferred, read from
`src/jobs/*.py`:

| Job | Blocklists at v2.1.0 | #632 said |
|---|---|---|
| `remove_failed_downloads` | **no** | yes |
| `remove_failed_imports` | **yes** | no |
| `remove_orphans` | **no** | yes |
| `remove_missing_files` | no | no |
| `remove_unmonitored` | no | no |
| `remove_stalled`, `remove_slow` | yes | yes |
| `remove_metadata_missing`, `remove_bad_files` | yes | n/a |

The `remove_orphans` row is also Confirmed: after the live removal above,
Sonarr's blocklist held zero records.

**`remove_failed_imports` still stays off, and the reason changes.** The job
takes items that are `completed` with `trackedDownloadStatus: warning` in an
import state. Its default `message_patterns` is `["*"]`, which matches every
message. Inferred, from `_jobs.py` and `remove_failed_imports.py`.

#632 argued that a non-blocklisting removal re-grabs the same release and loops.
A blocklisting one never takes the same release twice. Instead it walks the
available releases, blocklisting each in turn. Read that way against the nine
stuck imports of 2026-09-06 (all Inferred):

1. **Payload deleted after SABnzbd reported success.** Removal recovers it, and
   blocklists a release that was fine.
2. **Hash-named files in a season pack.** A different release may import. Of the
   five, this is the case removal plausibly helps.
3. **`seriesType: anime` on a standard-numbered show.** A configuration fault.
   Every release fails the same way and is blocklisted in turn, which is worse
   than a loop.
4. **ID-matched import block.** It still destroys the one payload Manual Import
   could have rescued, and now blocklists it too.
5. **Sample-detection false positive.** It blocklists a good release.

`remove_failed_downloads` removes `failed` queue items *without* blocklisting.
The platform already sets `removeFailedDownloads: True` on the SABnzbd client
(`filter_plugins/acquisition_servarr.py:246`, Confirmed). Fresh lab Sonarr and
Radarr containers report `autoRedownloadFailed: true`, which means the arr
itself blocklists and re-searches a failed download. Confirmed, but on lab
containers only: nothing in `roles/` or `filter_plugins/` owns the key, so the
NAS's value is Unverified. Where the arr handles the failure, Decluttarr's
deletion can only race it. If Decluttarr wins, the release is removed without a
blocklist entry. Inferred. It stays off.

`remove_orphans` removes, on its first sighting and with no strikes, anything in
an arr's download-client category that the arr did not grab. Sonarr lists such
an item only when `includeUnknownSeriesItems=true`. The probe NZB showed
`seriesId: null` there and zero records without the parameter. Confirmed. Its
cost here is not rarity. An NZB a person drops into SABnzbd under the TV or
movie category is deleted within one `TIMER`. Whether anyone on this platform
does that is Unverified.

## Configuration: the environment reaches the arrs and not SABnzbd

Configuring through the rendered `.env` works for the instances. `SONARR` takes
a YAML list, and the one-line flow form below, rendered into a `.env` and
interpolated by Compose as `SONARR: ${DECLUTTARR_SONARR:?}`, produced
`OK | Sonarr (http://sonarr:8989)` and a search cycle. Confirmed:

```
DECLUTTARR_SONARR=[{base_url: "http://sonarr:8989", api_key: "<key>"}]
```

**There is no environment variable for SABnzbd.** The mapping in
`src/settings/_user_config.py` gives `download_clients` a single key,
`QBITTORRENT`. Inferred. A `SABNZBD` variable set beside `SONARR` produced no
`DOWNLOAD CLIENT SETTINGS` section in the settings dump, which is printed before
any instance is contacted. Confirmed.
A SABnzbd client therefore needs a mounted `config.yaml`, which disables every
environment variable, because the file wins outright. Inferred, from
`get_user_config`.

That is acceptable for a first slice, because nothing in it needs a download
client. `remove_orphans` removed the probe with no SABnzbd configured in
Decluttarr at all. Confirmed. Only `remove_slow` reads SABnzbd directly.

Two further configuration facts, both Confirmed:

- The settings dump prints `api_key: '*****'`, and DEBUG request logs print the
  `X-Api-Key` header as `[**redacted**]`.
- Every line is also written to `/app/logs/logs.txt` in the container's writable
  layer, which held 36 KB after four DEBUG cycles.

That file rotates at 50 MiB with two backups, so it is capped at 150 MiB.
Inferred, from `src/utils/log_setup.py`. It duplicates what `json-file` logging
already keeps and is lost on recreate, so nothing needs to be mounted for it.

## Resources and stop

- **Memory.** 25 MiB and 2 PIDs between cycles, with two arrs configured, at
  0% CPU. Confirmed, arm64 lab. It is a Python poller rather than a
  self-sizing runtime, so no `mem_limit` is called for.
- **Stop.** `main.py` installs a SIGTERM handler that calls `sys.exit(0)`.
  `docker stop` returned in 0.14 s with exit `0` and the log line
  `Termination signal received`. Confirmed. So this is not the `alert-relay` or
  `nextcloud-cron` shape, and no `init` or `stop_signal` is needed.
- **Minimum versions.** Decluttarr's minimum versions are Sonarr `4.0.9.2332`
  and Radarr `5.10.3.9171`. Inferred, from `src/settings/_constants.py`. The
  platform's pins passed setup. Confirmed.
- **Wiring.** No port, no volume and no data directory. It needs only to reach
  the arrs by name, which the `arr` project's `media-control` network already
  provides. Inferred.
- **`detect_deletions` is not gated by its setting.** `main.py` tests
  `if settings.jobs.detect_deletions:`. That is a job object whose truth value
  is `True` even when `enabled` is `False`, so the file watcher's setup runs on
  every start. Confirmed with
  `JobParams()` printing `enabled=False` and `bool=True` inside the image. Every
  run without `DETECT_DELETIONS` logged `WARNING | Job 'detect_deletions' on
  Sonarr … does not have access to this path … '/data/tv'`. Confirmed. Only the
  missing mount keeps the watcher inert. Mounting the library at the arrs' paths
  would switch it on, and a Dozzle log rule on `WARNING` would fire on every
  start.

## The shape this repository should take

#632's shape holds, with these corrections and additions:

- **A container in the `arr` project, with no `nas_storage` entry and no new
  vault key.** `roles/arr/meta/argument_specs.yml` already requires
  `vault_arr_sonarr_api_key` and `vault_arr_radarr_api_key`. Confirmed.
- **Configuration through the rendered `.env`**, in the one-line flow form
  above.
- **Search only in the first slice:** `SEARCH_MISSING` and possibly
  `SEARCH_UNMET_CUTOFF`. Every removal job off, including `remove_orphans`
  until the manual-drop question is answered.
- **A verification that reads the log, not the health status.** An `OK |` line
  per configured instance since the last start, and no refusal line after it.
  Without it, a key that is wrong at start is a silent outage.
- **No library mount, ever**, since that alone would switch on
  `detect_deletions`.
- **`depends_on` the arrs with `condition: service_healthy`.** Their
  healthchecks probe `/ping` over HTTP and do mean something. Without the
  condition, a converge that recreates the project can start Decluttarr ahead
  of Sonarr and spend one refusal cycle. Inferred.
- **`TEST_RUN: true` for one converge, not a week.** It shows which items would
  be searched and nothing else.
- **`MIN_DAYS_BETWEEN_SEARCHES` and `MAX_CONCURRENT_SEARCHES` chosen from the
  indexers' limits**, and not left at the defaults by omission.
- **A CPU ceiling:** `cpus:` in `services/arr/compose.yml`, and
  `container_cpus` in `tests/expected/arr.yml`. `platform_container_cpu_budget`
  sizes the shared cpuset and is not changed by a container.

## What remains unsettled

- **The NAS's own `autoRedownloadFailed` and `uiLanguage`.** Fresh containers
  of the pins report `true` and `1`, and nothing in this repository owns either
  key. The second decides whether Decluttarr starts at all. The source refuses
  only values above `1`.
- **The real size of `wanted/missing` and `wanted/cutoff` on each arr**, and
  the daily API limit of every indexer behind Prowlarr. Together they turn the
  per-cycle arithmetic above into a real figure. The cutoff list may be large,
  because Configarr owns the quality profiles its cutoffs come from.
- **Whether a Dozzle rule can match the refusal line.** If it can, it would
  make the loop page without waiting for a verification run.
- **Whether a `tmpfs` at `/app/logs` lets the container run as a non-root
  `user:`.** Root inside a `no-new-privileges` container with no mounts is a
  small surface, but it is still a choice.
- **Strike persistence.** The strike tracker is an in-memory object per
  instance and is cleared whenever the queue is empty. Inferred, from
  `src/settings/_instances.py` and `src/job_manager.py`. It was not observed
  across a recreate, because no strike-counting job fits a Usenet-only
  platform. Search progress, the part that matters for this slice, does
  survive, because it lives in the arr.
- **Whether anyone adds NZBs to SABnzbd by hand**, under a category an arr
  watches.
- **Whether Decluttarr's Readarr calls work against Bindery.** Out of scope, as
  #632 said.

## Reproducing the confirmations

The lab was the three pinned images on one user-defined network, with named
volumes for `/config`. SABnzbd needs `host_whitelist = sabnzbd,` in
`sabnzbd.ini`, and a `tv` category, before Sonarr accepts it as a client.

```sh
IMG=ghcr.io/manimatter/decluttarr:v2.1.0

# the healthcheck with no application running: healthy
docker run -d --name hc --health-interval=2s --health-start-period=1s "$IMG" sleep 600
docker inspect -f '{{.State.Health.Status}}' hc

# a refusal exits 0 after 30 seconds, and unless-stopped restarts it
docker run -d --name loop --restart unless-stopped --network lab \
  -e 'SONARR=[{base_url: "http://sonarr:8989", api_key: "wrong"}]' "$IMG"
docker inspect -f 'restarts={{.RestartCount}} exit={{.State.ExitCode}}' loop

# test mode: the arr's command list does not change
docker run -d --name t --network lab -e LOG_LEVEL=DEBUG -e TEST_RUN=True -e TIMER=0.25 \
  -e SEARCH_MISSING=True -e "SONARR=[{base_url: \"http://sonarr:8989\", api_key: \"$SONARR_KEY\"}]" "$IMG"
curl -s -H "X-Api-Key: $SONARR_KEY" http://127.0.0.1:8989/api/v3/command

# live search: lastSearchTime advances, but only once an indexer exists
curl -s -H "X-Api-Key: $SONARR_KEY" "http://127.0.0.1:8989/api/v3/episode?seriesId=1"

# an orphan: an NZB added straight to SABnzbd under the tv category
curl -s -F name=@probe.nzb "http://sabnzbd:8080/api?mode=addfile&cat=tv&output=json&apikey=$SAB_KEY"
curl -s -H "X-Api-Key: $SONARR_KEY" "http://127.0.0.1:8989/api/v3/queue?includeUnknownSeriesItems=true"
```

Sonarr refuses to save an indexer whose test returns no results, even with
`forceSave=true`. The Newznab stub therefore served one unrelated release, and
its `pubDate` had to name the correct weekday: Sonarr rejects
`Mon, 01 Sep 2026` because that day was a Tuesday.
