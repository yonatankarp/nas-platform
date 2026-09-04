# Kapowarr dossier — Phase 2, after the promotion

Derived from `docker.io/mrcas/kapowarr` **v1.3.1**, the digest
[`services/kapowarr/compose.yml`](../services/kapowarr/compose.yml) pins, run as
a virgin container against an empty `/comics` mount. Read
[the marker convention](service-dossiers.md#how-to-read-the-evidence-markers)
first: **Confirmed** was executed, **Inferred** was reasoned, **Unverified**
was not settled.

Every transcript below was captured under the mount layout this platform ran
until #264 — the comics library bound at `/comics` and staging at
`/app/temp_downloads` — and the container paths in them are quoted as they were
executed rather than rewritten. That layout is gone: the library is reached at
`/data/books/Comics` and staging at `/data/books/.acquisition/usenet/comics`,
both inside one bind mount of the Books share, because `rename(2)` refuses to
cross a mount boundary and a mount per directory made every import a byte copy.
Nothing an observation established changed with the paths; only the paths did.
[Migrating the stored library prefix](#migrating-the-stored-library-prefix)
below is the consequence for a deployment that predates the change.

Like [the Pinchflat dossier](dossier-pinchflat.md), this is written after the
promotion rather than before it, and asks what the running application holds
that Ansible does not own. Kapowarr answers that question almost exactly
opposite to Pinchflat: it has a complete, typed, partial-update settings API,
and nearly its whole configuration surface is reconcilable. What
`roles/kapowarr` reconciles today is the administrator identity and one library
root. Everything else in the list at the end of this file is reachable and
unclaimed.

## The settings API is a partial merge, and that is the load-bearing fact

`PUT /api/settings` updates only the keys present in the body. Sending one key
changed one key and dropped none:

```
PUT /api/settings {"volume_padding":3}   → 200
diff against the settings read before it: {"volume_padding": [2, 3]}
keys dropped: []
```

Confirmed by reading the full settings object before and after and comparing
every key. This is the property that makes an incremental role possible: a task
that declares two naming templates cannot silently reset a proxy configuration
or a download folder it never mentioned. Had it been a full replace, every
future settings task would have had to send the whole object, and every upstream
release that added a key would have been a silent regression.

Repeating an identical `PUT` returns `200` and changes nothing. Confirmed. The
endpoint is safe to re-send, but it is **not** self-reporting: a no-op write and
a real write are both `200` with an identical body, so `changed_when` has to
come from a read-then-decide, exactly as
[the four planned projects require](service-dossiers.md#what-the-four-have-in-common).

## Validation is strict, typed, and returns the offending key

Every rejection names what it rejected, which makes these usable as assertions
rather than as guesses:

```
{"not_a_setting": 1}              → 400  KeyNotFound          {"key": "not_a_setting"}
{"volume_padding": "three"}       → 400  InvalidKeyValue      {"key": …, "value": "three"}
{"volume_folder_naming":
   "{not_a_field}"}               → 400  InvalidKeyValue
{"download_folder": "/nope"}      → 404  FolderNotFound       {"folder": "/nope"}
```

All Confirmed. Two consequences for a role. Naming templates are validated
against a known placeholder set, so a typo in a declared template fails the
converge loudly instead of producing a library full of literal `{not_a_field}`
directories — that is a good property and worth relying on. And `download_folder`
must already exist inside the container, so any declared path has to be a real
mount, not merely a string.

Numeric keys are range-checked, not merely type-checked. `volume_padding` took
`3` and refused `4` with `InvalidKeyValue`; both are integers, so the type was
never the objection. Confirmed. The exact bound was not mapped — Unverified —
but a declaration cannot assume any integer is acceptable.

**A multi-key write is atomic.** A body carrying one valid key and one invalid
key was refused whole, and the valid key was *not* applied:

```
issue_padding = 4  (from an earlier accepted write)
PUT {"issue_padding": 3, "file_naming": "{series_name}"}  → 400 InvalidKeyValue
issue_padding = 4  (unchanged)
```

Confirmed. This is the best property in the API for a role's purposes: a
converge that declares eight settings applies all eight or none, so a rejected
declaration can never leave the application half-configured in a state no run
authored. It also means the declaration must be validated as a set — one bad
value fails the whole task, which is the correct and loud outcome.

## `service_preference` must be a complete permutation

The one genuine trap in the settings surface, and it would not be found by
reading the value back and assuming a list means a list.

```
{"service_preference": ["GetComics", "Pixeldrain"]}   → 400 InvalidKeyValue
{"service_preference": ["GetComics", "Pixeldrain", "Mega",
                        "MediaFire", "WeTransfer",
                        "GetComics (torrent)"]}       → 200
```

Confirmed. A subset is refused; only a reordering of the *entire* known service
set is accepted. So "prefer GetComics" is not expressible as a short list — it
is expressible only as a total ordering of all six.

That matters beyond ergonomics. A role that hard-codes those six names in
`defaults/main.yml` is pinned to this version's service list, and the next
Kapowarr release that adds or renames a download service breaks the converge on
a `400` with no obvious cause. The safe shape is to read the deployed
`service_preference`, apply a declared *partial* ordering to it, and write back
the permutation that results — so the declaration says "these first, the rest in
whatever order the application already had" and an upstream addition lands at
the end instead of failing.

## Reading settings back masks the credentials

The finding most likely to produce a role that reports `changed` forever:

```
GET /api/settings → {"auth_username": "********", "auth_password": "********"}
```

Confirmed. Both halves of the administrator identity read back as eight literal
asterisks, not as the stored value and not as an empty string. Any
reconciliation that reads the settings object and compares it field-by-field
against what vault declares will see a mismatch on every run, rewrite the
credentials on every run, and never converge.

`roles/kapowarr` sidesteps this today by never comparing those fields — it
probes `POST /api/auth` with the authored pair and treats a `200` as proof. That
is the right shape and it should stay that way; a settings-reconciliation task
added beside it must **exclude every masked field from its comparison**, and the
list of masked fields is a property of the version, not a constant.

Whether `comicvine_api_key` also masks once set is Unverified — it reads back as
`""` while unset, and no valid key was available to test with.

## The API key cannot be authored, only earned

Kapowarr generates `api_key` at first start and refuses to be told a different
one:

```
PUT /api/settings {"api_key": "0123…"}
→ {"error": "InvalidSettingModification",
   "result": {"key": "api_key", "instead": "POST /settings/api_key"}}
```

Confirmed. `POST /api/settings/api_key` exists and rotates it to a new random
value, which is a reset, not a declaration — it cannot be pointed at a
vault-authored string. Confirmed: the key changed from one random value to
another.

So this platform cannot hold Kapowarr's API key in vault, and the only way to
obtain it is `POST /api/auth`, which returns it on a successful login.
Confirmed. That is an authentication exchange rather than a configuration
read-back, which is why it does not collide with the rule the
[Bindery dossier](dossier-bindery.md) found genuinely unsatisfiable — nothing
about the platform's *desired* state is being learned from the application.

The key survives the identity being authored: the same key answered before and
after `auth_username`/`auth_password` were set. Confirmed. Only an explicit
rotation changes it.

## The bootstrap window is real and the promotion closes it

On a virgin database, `POST /api/auth` with an **empty body** returns the API
key, and that key authorizes every route behind `/api`:

```
authentication_method: 0    POST /api/auth {} → 200 {"api_key": "…"}
```

Confirmed. A Kapowarr that is merely running, before anything is configured,
hands full control of the comics library to whoever asks first on the LAN.

After the vault pair is written the window shuts, and every assertion
`roles/kapowarr` makes about it holds:

```
authentication_method: 0 → 2
POST /api/auth {}                                 → 401 PasswordInvalid
POST /api/auth {authored username + password}     → 200 {"api_key": "…"}
POST /api/auth {authored username, wrong password}→ 401 PasswordInvalid
GET  /api/settings   (no key)                     → 401 ApiKeyInvalid
```

All Confirmed against the running container. `authentication_method` is `0` for
none, `1` for a bare password and `2` for the username-and-password pair — and
the role is right that only `2` puts the authored username in force, because at
`1` the username is not checked at all.

This is the same shape as three of the four planned projects: the converge that
starts the container must close the identity in the same play. There is no safe
"deploy now, secure later".

## `comicvine_api_key` rejects a well-formed key it cannot verify

The promotion declines to push this credential and explains why. The behaviour
is confirmed:

```
PUT /api/settings {"comicvine_api_key": "<40 hex characters>"}
→ 400 InvalidKeyValue
```

Confirmed with a syntactically valid, 40-character hexadecimal value — the shape
ComicVine issues — from a container with working outbound network. The value was
refused, so the check is not a format check. That the mechanism is an outbound
call to `comicvine.gamespot.com` is Inferred, but the conclusion the role draws
does not depend on the mechanism: a converge that set this key would fail
whenever a third party was unreachable, rate-limiting, or simply having a bad
day, and no disposable lane could prove the task without a real key and real
egress.

Vault remains its authority — it is where the operator's key is recorded and
recovered from — and the application is where it is entered. That split should
be left alone.

## Root folders

```
POST /api/rootfolder {"folder": "/comics"}        → 201  {"id": 1, "folder": "/comics/"}
POST /api/rootfolder {"folder": "/comics"} again  → 400  RootFolderInvalid
POST /api/rootfolder {"folder": "/comics/sub"}    → 404  FolderNotFound
GET  /api/rootfolder                              → [{"id", "folder", "size": {…}}]
```

All Confirmed. The stored form carries a trailing separator, which is why the
role compares on the separator-free form — that is correct and should not be
"simplified" away.

One claim in the role's own comment is **not** confirmed here: that Kapowarr
refuses a root that is a parent or child of an existing one. The nested attempt
above failed as `FolderNotFound` because `/comics/sub` did not exist on disk,
which says nothing about the parent/child rule. It may well be true; this
investigation did not test it. Unverified.

## Migrating the stored library prefix

#264 moved both container paths under one bind mount of the Books share. Kapowarr
stores the old prefix, so a deployment that predates the change has to be
relabelled before `roles/kapowarr` will converge it — the role refuses the run
rather than declaring the new root beside the old one.

**Three columns hold a path, and they are the whole migration.** Read from
`DB_SCHEMA` in `backend/internals/db.py`: `root_folders.folder`, `volumes.folder`
and `files.filepath`. A fourth, `remote_mappings.local_path`, exists only for
external download clients and is empty on this platform, which declares none.
The `download_folder` value in `config` is a fifth, and it is the one the
platform owns: `kapowarr_settings` declares it and a converge writes it.

**No API can do this.** Confirmed by reading v1.3.1:

- `PUT /api/rootfolder/<id>` is `RootFolders.rename()`, which calls
  `samefile(current, new)` before anything else. The old path no longer resolves
  in the container, so the call raises rather than relabelling. Keeping the old
  bind mount alongside the new one does not help: both paths then resolve to the
  same inode, `samefile` returns True and the function returns having changed
  nothing.
- Past that, `rename()` hands every volume to `Volume.change_root_folder()`,
  which moves each file with `shutil.move`. Every stored `filepath` points at a
  path that no longer exists, so each move raises `FileNotFoundError`; with both
  mounts present the destination exists instead and `shutil` raises
  `Destination path already exists`. Either way it fails **after** the new root
  folder row is inserted, leaving two roots.
- Deleting the file rows first (`DELETE /api/files/<id>`, which removes only the
  row when the path does not resolve) makes `change_root_folder()` a pure column
  rewrite — but the only thing that rebuilds the issue-to-file matching is
  `refresh_and_scan`, which fetches from ComicVine first and whose task swallows
  `InvalidComicVineApiKey` silently. That is precisely the third-party dependency
  this role refuses to take on for the ComicVine key itself, so it is not a
  migration the platform will perform.

**The procedure.** Stop the container first: SQLite is not safe to rewrite under
a running Kapowarr, and the application caches the root folder mapping in
process.

```sh
# platform_current_dir, which is {{ nas_docker_root }}/nas-platform/current.
current=/volume1/Docker/nas-platform/current
docker compose --project-name kapowarr \
  -f "$current/services/kapowarr/compose.yml" stop kapowarr

# {{ nas_docker_root }}/kapowarr/config, and the capitalisation is load-bearing:
# inventory/group_vars/nas_hosts/main.yml declares nas_docker_root as
# /volume1/Docker, the NAS is case-sensitive, and sqlite3 hands a missing path a
# brand-new empty database rather than an error. Every UPDATE below would then
# succeed against empty tables, COMMIT, print three zeroes and look exactly like
# a finished migration. Both guards in this script exist for that one failure.
db=/volume1/Docker/kapowarr/config/Kapowarr.db
test -f "$db" || { printf 'no Kapowarr database at %s\n' "$db" >&2; exit 1; }
cp -p "$db" "$db.pre-264"                           # the whole rollback

# The rows to relabel, counted before anything is written and required to be
# more than none. A zero-to-zero transition is indistinguishable from a
# completed migration, so zero here means the migration has already run or this
# is not the database you meant, and either way nothing below should execute.
pending=$(sqlite3 -bail "$db" "
  SELECT (SELECT count(*) FROM root_folders WHERE folder   =    '/comics/')
       + (SELECT count(*) FROM volumes      WHERE folder   LIKE '/comics/%')
       + (SELECT count(*) FROM files        WHERE filepath LIKE '/comics/%');")
printf 'rows to relabel: %s\n' "$pending"
[ "${pending:-0}" -gt 0 ] || { printf 'nothing is stored under /comics\n' >&2; exit 1; }

sqlite3 -bail "$db" <<'SQL'
BEGIN;
UPDATE root_folders SET folder = '/data/books/Comics/'
  WHERE folder = '/comics/';
UPDATE volumes SET folder = '/data/books/Comics' || substr(folder, length('/comics') + 1)
  WHERE folder LIKE '/comics/%';
UPDATE files SET filepath = '/data/books/Comics' || substr(filepath, length('/comics') + 1)
  WHERE filepath LIKE '/comics/%';
COMMIT;
SQL

# Must print three zeroes. Deliberately '/comics%' rather than '/comics/%', so a
# row left holding the bare prefix is counted too.
sqlite3 -bail "$db" "
  SELECT (SELECT count(*) FROM root_folders WHERE folder   LIKE '/comics%'),
         (SELECT count(*) FROM volumes      WHERE folder   LIKE '/comics%'),
         (SELECT count(*) FROM files        WHERE filepath LIKE '/comics%');"
```

The final `SELECT` must print three zeroes, and the `rows to relabel` line above
it must have printed something other than `0` — a run that reports both zero and
zero has migrated nothing and told you nothing.

Confirmed, against three synthetic databases carrying the schema above rather
than against the NAS: a mistyped path refuses and creates nothing, an
already-migrated database reports `rows to relabel: 0` and refuses, and a
database holding the old prefix reports five rows, rewrites the root folder to
`/data/books/Comics/`, both volume folders and both file paths — the nested
`extras/` file included — and prints `0|0|0`. The trailing separator on the
root folder row is not optional — `RootFolders.add()` stores
`force_suffix(abspath(folder))` and the application compares against that form.
Then converge normally; the role finds the declared root, the refusal does not
fire, and `--tags platform_verify_kapowarr` proves the result.

No file moves. The comics never leave `Books/Comics` on the host — only the label
Kapowarr reads them by changes — which is why the rollback is the copied database
and nothing else.

**The empty library is not data loss.** Between the deployment and the relabel,
Kapowarr's web interface shows a library with nothing in it, and it created that
emptiness itself: `RootFolders.__gather_extra_data()` calls `create_folder()`
whenever a stored root folder is not a directory, so the first read of
`GET /api/rootfolder` — the platform's own, or a browser's — conjures an empty
`/comics` in the container's writable layer. Confirmed by reading
`backend/implementations/root_folders.py`. It disappears with the container.

## Renaming an existing volume folder, and why it is not the rename task

The sharpest item this file used to leave open. A settings write renames
nothing, so a `volume_folder_naming` change reaches only volumes added after it
— and Kapowarr offers **two** surfaces that re-derive an existing volume's
folder, which are not interchangeable.

```
POST /api/system/tasks {"cmd": "mass_rename", "volume_id": 1}   → a queued task id
PUT  /api/volumes/1    {"volume_folder": null}                  → 200, synchronous
```

Both are Confirmed to exist against the pinned image. `roles/kapowarr` uses the
second, and the reasons are worth keeping because the first is the one the name
suggests:

- **`mass_rename` renames every file as well as the folder.** It is
  `preview_mass_rename()` applied, so it moves the volume folder *and* renames
  each file onto `file_naming`. On a 4 TB library that is thousands of file
  renames to fix a directory name.
- **`mass_rename` skips the folder for a volume carrying a custom folder.**
  `preview_mass_rename()` re-derives the folder only `if not
  volume_data.custom_folder`, so a library-imported volume is silently left
  nested. `change_volume_folder(None)` ignores that flag and always re-derives.
- **`mass_rename` is a queued task**, so a converge would have to poll
  `GET /api/system/tasks` for completion. The `PUT` runs in the request thread
  and answers when the move is done.
- **`mass_rename` deletes more.** It calls `delete_empty_parent_folders()`
  unconditionally after any rename.

What `PUT /api/volumes/<id> {"volume_folder": null}` does, all Confirmed against
the pinned image with a seeded nested library: it regenerates the folder path
from the *current* template, moves the files with a rename rather than a copy,
updates their paths in its database, and **returns early when the derived path
is the one already stored** — so a second call is a no-op inside the application
as well as in Ansible. It renames no file. It answers `{"error": null, "result":
null}`, which says nothing about what it did; the folder has to be read back.

Two behaviours a caller has to know about.

**It deletes the directory it empties, and empty parents above it.** Not the
files — `delete_empty_child_folders()` then `delete_empty_parent_folders()` walk
up from the old folder, stop at the library root, and stop at the first
directory that still holds anything. Confirmed: with two volumes under one
`Invincible/` parent, moving the first left the parent alone and moving the
second removed it, and an empty `extras/` subdirectory of a moved volume folder
went with it. A directory belonging to no volume is never reached —
`/comics/_oneshots/…` survived the whole migration untouched. There is no way to
move a volume folder through Kapowarr without this cleanup, and moving the
directory behind Kapowarr's back instead would desynchronise the absolute path
it stores per volume.

**It marks the volume as carrying a custom folder, which is a bug.**
`change_volume_folder()` overwrites its `new_volume_folder` argument with the
generated path before computing `'custom_folder': new_volume_folder is not
None`, so the flag is set for a folder the application derived itself. A volume
marked that way is one `preview_mass_rename()` stops re-deriving, so the next
template change would converge silently wrong. Sending `custom_folder: false` on
the same request repairs it: the route applies leftover keys through
`Volume.update()` *after* the folder move, and `custom_folder` is an accepted
`VolumeData` field. Confirmed — the flag reads back `0` in the database
afterwards.

`GET /api/volumes/<id>/rename` is the read that makes this convergent. It is
`preview_mass_rename()` without the apply, and it builds every suggested file
path underneath the folder the current template derives — so a suggested path
outside the volume's stored folder is Kapowarr saying the folder must move, and
names where to. Confirmed: a nested volume previewed
`/comics/Invincible (2003)/…`, and the same volume after the move previewed
paths inside its own folder. That is what lets a role compare against the
application's own derivation instead of reimplementing an arbitrary format
string and the illegal-character rules in Jinja.

Its one blind spot: a volume holding no files previews `{}`, because the route
returns only file renames and there are none — the new folder it computed is
discarded by the route. Confirmed. So a file-less volume needs the second,
template-agnostic reading that `roles/kapowarr` also uses: the declared template
names one directory level, so a folder Kapowarr derived is always a direct child
of the library root.

Finally, the move does not touch ownership, permissions or file dates on this
platform. `change_volume_folder()` ends in `mass_process_files()`, but all three
of its steps return early on an unset setting, and `chmod_folder`, `chown_group`
and `change_file_date` are all unset at v1.3.1's defaults, which is what this
platform declares. Confirmed by reading them back from the running container.

## What the promotion left unowned

Everything below is reachable through `PUT /api/settings`, typed, validated, and
currently set by hand on first login or left at the application's default:

- `volume_folder_naming`, `file_naming`, `file_naming_empty`,
  `file_naming_special_version`, `file_naming_vai` — where every comic lands and
  what it is called. The five that decide whether Komga, reading the same
  directory, sees a coherent library.
- `volume_padding`, `issue_padding`, `long_special_version`,
  `replace_illegal_characters`, `rename_downloaded_files`
- `service_preference` (subject to the permutation rule above),
  `format_preference`, `convert`, `extract_issue_ranges`
- `download_folder`, `concurrent_direct_downloads`, `failing_download_timeout`,
  `delete_completed_downloads`, `seeding_handling`
- `create_empty_volume_folders`, `delete_empty_folders`,
  `unmonitor_deleted_issues`, `date_type`, `log_level`
- `chmod_folder`, `chown_group`, `change_file_date` — file ownership on a NAS
  whose media root this platform deliberately does not own
- `flaresolverr_base_url`, and the six `proxy_*` keys
- External download clients and stored service credentials, which live in their
  own `external_download_clients` and `credentials` tables rather than in
  `config`, and were not investigated

That list is the surface as this investigation found it, before
`roles/kapowarr` claimed most of it; `kapowarr_settings` in the role's defaults
is what the platform declares today. `download_folder` is claimed for a reason
worth naming here: the parent mount of #264 removed the `/app/temp_downloads`
bind the application's default pointed into, so an undeclared download folder
would stage into the container's writable layer — a cross-device copy on import,
and a download lost on the next recreate.

The naming group is the one with a consequence outside Kapowarr, because Komga
indexes the directory Kapowarr writes. A hand-edited template there changes what
a second platform service sees, and nothing reverts it.

## What remains unsettled

- Whether `comicvine_api_key` masks on read once set. Decides whether a settings
  reconciliation can compare it at all.
- The full set of masked fields at this version. Assumed to be the credential
  group; only `auth_username` and `auth_password` were observed.
- Whether Kapowarr refuses a root folder nested under an existing one, as the
  role's comment claims. Untested for the reason above.
- The `external_download_clients` and `credentials` API surfaces — not probed.
  These carry third-party credentials and would each need a vault key.
- Whether the placeholder set accepted by the naming templates is stable across
  versions. If it is not, a declared template can start failing on an upgrade,
  which turns a good validation property into an upgrade hazard.
- Whether `mass_rename` is safe to trigger against this library. It is not used
  and its blast radius is the reason, but it was never *run*: everything above
  about it is read from `backend/implementations/naming.py` and
  `backend/features/tasks.py` rather than executed. If a file-naming migration
  is ever wanted, that route needs its own investigation, including how a queued
  task reports completion.
- What a rename does while Komga is mid-scan. Komga sees every series move at
  once, and the migration does not coordinate with it; the operator rescans
  afterwards. Whether a scan running *during* the move leaves Komga with
  duplicate or orphaned series was not tested.
- Whether the suggested paths a rename preview returns can all sit below the
  volume folder rather than in it. `preview_mass_rename()` puts a loose image
  file that belongs to an issue in a subfolder of its own, so a volume whose
  every file is a loose page would preview one level deeper than its folder.
  This library holds archives, so it was not observed; a role reading the
  shallowest previewed directory as the target would name a subfolder in that
  case. The other rewriter of a suggested path, `same_name_indexing()`, is not a
  risk here: it appends ` (N)` to the basename through `splitext` and never
  touches the directory. Confirmed by reading it.

  Settled by the section above, and no longer open: that a settings write does
  not rename an existing library. Confirmed twice over — the task queue and
  history gained nothing across a naming write on an empty library, and on the
  NAS a download that completed after the template changed still landed in its
  volume's stored folder.
- The accepted range for each numeric key. `volume_padding` refused `4` and took
  `3`; nothing else was probed.

## Reproducing the confirmations

Several findings below and in
[Migrating the stored library prefix](#migrating-the-stored-library-prefix) were
settled by reading the application's own source rather than by probing it. The
upstream git tag is **`V1.3.1`**, capital `V` — `v1.3.1` is a 404, even though
the image tag this platform pins is lowercase. Both spellings appear on the same
release, so check the case before concluding the tag is missing:

```sh
curl -sSL -o kapowarr.tar.gz \
  https://github.com/Casvt/Kapowarr/archive/refs/tags/V1.3.1.tar.gz
```

```sh
# The mount shape the platform runs since #264: one bind of the Books share, with
# the library and its staging directory inside it. The transcripts above were
# captured with a leaf mount each, at /comics and /app/temp_downloads; the paths
# in them read differently here, nothing else does.
mkdir -p books/Comics books/.acquisition/usenet/comics db
docker run -d --name kw-probe -p 15656:5656 -e TZ=UTC \
  -v "$PWD/db:/app/db" -v "$PWD/books:/data/books" \
  docker.io/mrcas/kapowarr:v1.3.1

# the bootstrap window: an empty body returns the key that authorizes everything
K=$(curl -s -X POST http://127.0.0.1:15656/api/auth \
     -H 'Content-Type: application/json' -d '{}' \
     | grep -o '"api_key": "[^"]*"' | sed 's/.*: "//;s/"//')

# partial merge: read, write one key, read again, diff every key
curl -s "http://127.0.0.1:15656/api/settings?api_key=$K" -o before.json
curl -s -X PUT "http://127.0.0.1:15656/api/settings?api_key=$K" \
  -H 'Content-Type: application/json' -d '{"volume_padding":3}' -o /dev/null
curl -s "http://127.0.0.1:15656/api/settings?api_key=$K" -o after.json

# the permutation rule
curl -s -X PUT "http://127.0.0.1:15656/api/settings?api_key=$K" \
  -H 'Content-Type: application/json' \
  -d '{"service_preference":["GetComics","Pixeldrain"]}'          # 400
curl -s -X PUT "http://127.0.0.1:15656/api/settings?api_key=$K" \
  -H 'Content-Type: application/json' \
  -d '{"service_preference":["GetComics","Pixeldrain","Mega","MediaFire","WeTransfer","GetComics (torrent)"]}'

# the identity, before and after
curl -s http://127.0.0.1:15656/api/public                          # method 0
curl -s -X PUT "http://127.0.0.1:15656/api/settings?api_key=$K" \
  -H 'Content-Type: application/json' \
  -d '{"auth_username":"platform","auth_password":"platform-secret"}'
curl -s http://127.0.0.1:15656/api/public                          # method 2
curl -s -X POST http://127.0.0.1:15656/api/auth \
  -H 'Content-Type: application/json' -d '{}'                      # 401
# and the credentials read back as ******** from here on
```

The rename confirmations need a *populated* library, which is what blocked them
before: adding a volume through the application needs a valid ComicVine key and
real downloads. Seeding Kapowarr's own database instead needs neither, and the
API reads the library from there.

```sh
# nested volumes, mirroring the shape the NAS library was in, plus a directory
# under the root that belongs to no volume
mkdir -p comics/'Invincible/Volume 01 (2003)/extras' comics/'Invincible/Volume 01 (2018)' \
         comics/_oneshots/Avatar
: > comics/'Invincible/Volume 01 (2003)/Invincible 001.cbr'
: > comics/'Invincible/Volume 01 (2018)/Invincible 001.cbr'
: > comics/_oneshots/Avatar/avatar.cbr

docker exec -i kw-probe python3 - <<'PY'
import sqlite3
c = sqlite3.connect("/app/db/Kapowarr.db")
c.execute("INSERT INTO volumes (id, comicvine_id, title, year, publisher, volume_number,"
          " description, site_url, monitored, monitor_new_issues, root_folder, folder,"
          " custom_folder, special_version, special_version_locked)"
          " VALUES (1,900001,'Invincible',2003,'Image',1,'','',1,1,1,"
          "'/comics/Invincible/Volume 01 (2003)',0,NULL,0);")
c.execute("INSERT INTO issues (id, volume_id, comicvine_id, issue_number,"
          " calculated_issue_number, title, date, description, monitored)"
          " VALUES (1,1,910001,'1',1.0,'Issue','2003-01-01','',1);")
c.execute("INSERT INTO files (id, filepath, size)"
          " VALUES (1,'/comics/Invincible/Volume 01 (2003)/Invincible 001.cbr',10);")
c.execute("INSERT INTO issues_files (file_id, issue_id, forced) VALUES (1,1,0);")
c.commit()
PY
docker restart kw-probe        # the application caches the library on start

# the preview names the folder the template derives, and renames nothing
curl -s "http://127.0.0.1:15656/api/volumes/1/rename?api_key=$K"

# the move, and the bookkeeping repair on the same request
curl -s -X PUT "http://127.0.0.1:15656/api/volumes/1?api_key=$K" \
  -H 'Content-Type: application/json' \
  -d '{"volume_folder": null, "custom_folder": false}'

# repeat it: the same 200, and nothing on disk or in the database changes
docker exec kw-probe python3 -c "import sqlite3; print(sqlite3.connect(
  '/app/db/Kapowarr.db').execute('SELECT folder, custom_folder FROM volumes').fetchall())"
```
