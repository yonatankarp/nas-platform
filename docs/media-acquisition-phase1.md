# Media acquisition Phase 1 operator handoff

Phase 1 deploys Radarr, Sonarr, Prowlarr, Bazarr, Configarr, SABnzbd, and
Unpackerr. It is deliberately safe by default: the transport flags default to
disabled, provider lists are empty, existing titles are not monitored
automatically, automatic rename is disabled, and Jellyfin keeps Open Subtitles.

The physical NAS has been through this handoff and is activated:
[`inventory/group_vars/nas_hosts/main.yml`](../inventory/group_vars/nas_hosts/main.yml)
sets `media_usenet_enabled: true`, so those seven containers run there.
`media_torrent_enabled` is `false` on every host, and
[`inventory/group_vars/mac_hosts/main.yml`](../inventory/group_vars/mac_hosts/main.yml)
leaves both flags `false`, so the disposable Mac proof stays inert. Read this
handoff before activating a transport on any further host, and before changing
the flags on the NAS.

Completing the code or a deployment does not claim provider connectivity.
It does not claim content acquisition. It does not claim NAS ACL correctness.
It does not claim Open Subtitles retirement. Those are NAS operator acceptance
decisions backed by the evidence below.

## 1. Prepare one target

Activation is an inventory value: `media_usenet_enabled: true` in
`inventory/group_vars/nas_hosts/main.yml` deploys the stacks on a host that has
been through this handoff. The policy tests pin the expected value per host and
per transport, so a host that has not been through it cannot be activated by a
merge, and an accepted one cannot be switched off unnoticed.

Provider and preference choices are credentials, and go where every other
credential on this platform goes:

```sh
ansible-vault edit inventory/group_vars/all/vault.yml
```

```yaml
media_arr_indexers: []
media_bazarr_languages: []
media_bazarr_providers: []
```

`group_vars/all/main.yml` carries the same three names as empty lists, which is
what starts the applications without unattended acquisition on a target that has
declared nothing. Ansible loads both files and the vault wins, so a declaration
here overrides that default without removing it.

Replace the empty lists only with values reviewed for this target.
[Bazarr provider schemas](bazarr-providers.md) records the exact keys the
deployed Bazarr accepts, derived from the pinned version rather than exported
from a running service. This repository does not choose a Usenet provider,
indexer, subtitle language, or Bazarr provider; it does record what a chosen one
requires. Configure the SABnzbd server connection through its protected
application configuration before attempting a proof download.

Do not put provider credentials in a command-line `-e` value, a plaintext
inventory file, or shell history.

The vault is committed, so the deployment poller carries these on every cycle:
there is no external artifact for it to miss, and no reason to leave automatic
deployment disabled while acquisition is configured. Keep it disabled while
adopting an existing library in step 2, where a convergence arriving partway
through the review is the thing to avoid, and turn it back on once the review is
accepted.

Publishing the ciphertext is uninteresting because the vault password is 384
random bits that never enter the repository. A credential that must not be
committed under any circumstances is one this platform should not be holding.

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
  --ask-vault-pass \
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
  --ask-vault-pass
```

## 3. Verify declared application state

The verification play is read-only with respect to reconciliation:

```sh
ansible-playbook -i inventory/remote.yml verify.yml \
  --tags platform_verify_arr,platform_verify_downloaders \
  --ask-vault-pass
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
