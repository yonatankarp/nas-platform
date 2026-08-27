# Media acquisition Phase 1 operator handoff

Phase 1 deploys Radarr, Sonarr, Prowlarr, Bazarr, Configarr, SABnzbd, and
Unpackerr. It is deliberately safe by default: Usenet is disabled, provider
lists are empty, existing titles are not monitored automatically, automatic
rename is disabled, and Jellyfin keeps Open Subtitles.

Completing the code or a deployment does not claim provider connectivity.
It does not claim content acquisition. It does not claim NAS ACL correctness.
It does not claim Open Subtitles retirement. Those are NAS operator acceptance
decisions backed by the evidence below.

## 1. Prepare one target without committing provider choices

Choose one NAS target and create a mode-`0600`, Ansible-Vault-encrypted extra
variables file outside source control. Do not put provider credentials in a
command-line `-e` value, a plaintext inventory file, or shell history.

```sh
umask 077
export PLATFORM_ACQUISITION_VARS="$HOME/.config/nas-platform/acquisition.yml"
ansible-vault create "$PLATFORM_ACQUISITION_VARS"
```

The encrypted file must begin with this activation and the operator-reviewed
values for the three lists:

```yaml
media_usenet_enabled: true
media_arr_indexers: []
media_bazarr_languages: []
media_bazarr_providers: []
```

Replace the empty lists only with schemas exported from the matching deployed
Prowlarr and Bazarr versions and reviewed for this target. Provider/indexer
credentials and Bazarr language/provider preferences stay in that encrypted
file outside source control. This repository does not choose a Usenet provider,
indexer, subtitle language, or Bazarr provider. Configure the SABnzbd server
connection through its protected application configuration before attempting a
proof download.

Always pass this file to Phase 1 convergence and verification. The existing
automatic-deployment poller does not load this external artifact; keep automatic
deployment disabled for this target until its protected-input procedure is
extended and reviewed.

The Arr runtime directory stores private SHA-256 digests for opaque desired
inputs. It also stores `.configarr-owned-state.sha256`, which is different: it
is the hash of the last completely read back and verified Configarr-owned API
state. `.configarr-opaque-context.sha256` is different again: it preserves
continuity for strictly validated Servarr-generated quality-definition
identities and metadata that cannot be derived from the pinned Configarr
inputs. Neither state hash contains a desired secret, but both use the same
owner-only mode and atomic, non-symlink loader protections.

Never copy any hash between targets or edit one to force convergence. A missing
opaque-context hash permits a one-time baseline only after all source-derived
invariants and the complete API type, shape, and identity checks pass. Once
installed, opaque-context continuity is enforced independently of desired-input
changes; a mismatch fails closed instead of establishing a new baseline.

## 2. Adopt existing Movies and Series once

Back up the media and application state and test the restore first. On the first
activation only, run one convergence with the explicit adoption input:

```sh
ansible-playbook -i inventory/remote.yml site.yml \
  --tags media_acquisition_phase1 \
  --ask-vault-pass -e @"$PLATFORM_ACQUISITION_VARS" \
  -e media_acquisition_adopt_existing_libraries=true
```

`media_acquisition_adopt_existing_libraries=true` is for one convergence only.
Remove it from every subsequent command. It authorizes initialization beside
existing content; it does not authorize a rename, search, deletion, or metadata
rewrite.

In Radarr and Sonarr, match and review the existing Movies and Series libraries
before enabling rename or monitoring. Confirm paths and title matches manually,
leave automatic search off, and correct mismatches one title at a time. Keep
these defaults until that review is accepted:

```yaml
media_arr_automatic_monitoring_enabled: false
media_arr_automatic_rename_enabled: false
```

Run later convergence without the adoption override:

```sh
ansible-playbook -i inventory/remote.yml site.yml \
  --tags media_acquisition_phase1 \
  --ask-vault-pass -e @"$PLATFORM_ACQUISITION_VARS"
```

## 3. Verify declared application state

The verification play is read-only with respect to reconciliation:

```sh
ansible-playbook -i inventory/remote.yml verify.yml \
  --tags platform_verify_arr,platform_verify_downloaders \
  --ask-vault-pass -e @"$PLATFORM_ACQUISITION_VARS"
```

Require `failed=0` and `unreachable=0`. This proves the repository-owned root
folders, authentication, connections, categories, naming policy, quality
profiles, and declared provider settings. It does not prove that an external
provider will return or download content.

## 4. Record NAS acceptance evidence

Use deliberately selected, legally accessible test content. Record identifiers
and pass/fail outcomes without credentials, provider response bodies, media
listings, or private filenames. Acceptance requires all of the following:

- one movie completes through SABnzbd and imports into Movies;
- one episode completes through SABnzbd and imports into Series;
- Bazarr writes one required-language subtitle sidecar beside each applicable
  proof item, and Jellyfin detects the sidecar;
- an ordinary SMB account cannot access `Media/.acquisition` or
  `Books/.acquisition`, while the service identity can traverse its required
  paths;
- a second convergence without the adoption override succeeds, followed by a
  passing tagged verification run.

Only after this evidence is reviewed may the operator separately enable
monitoring or rename. Make one controlled change, preview it in Radarr or
Sonarr, back up first, and inspect the resulting Jellyfin match before expanding
the scope.

## 5. Bazarr handoff and Open Subtitles

Keep `media_bazarr_handoff_accepted: false` and keep the Jellyfin Open Subtitles
declarations until the required-language sidecar evidence above is recorded on
the physical NAS. After review, record the decision by setting
`media_bazarr_handoff_accepted: true` in the operator-controlled deployment
input. That record is a prerequisite for a separate cleanup change; it does not
itself delete or disable Open Subtitles.

Do not remove the Jellyfin plugin, its vault keys, role tasks, or verification
until that cleanup is reviewed and deployed as its own phase.

## Failure recovery

Preserve the first failing task, container health, and bounded application
status before changing anything. Do not expose `.env` files, API keys, provider
fields, or logs containing private filenames.

If acquisition must be rolled back, stop Radarr and Sonarr writers before any
legacy writer is restored. Then stop the downloader project, preserve all Arr
and SABnzbd critical state, and leave final media untouched. Restore a legacy
writer only after confirming there is exactly one writer for each library.
Reverting `media_usenet_enabled` to `false` on the same target stops the two
managed projects on the next full convergence; it does not delete their state
or media.
