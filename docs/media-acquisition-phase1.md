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
requires.

The Usenet server SABnzbd downloads through is one of those declarations, and it
is the one that costs money: it is a paid third-party subscription. It arrives
in two halves, because only one is secret. The account name and its password are
vault-authored (`vault_downloaders_sabnzbd_server_username` and `_password`,
documented in [secrets](secrets.md)). The host, port, connection count and TLS
flag are not credentials -- the host is published by the provider, the port is
563 or 119, the connection count is a subscription tier -- so they are ordinary
operator policy in `group_vars/all/main.yml` under `media_usenet_provider`,
beside the three empty lists above and for the same reason.

They are typed there rather than carried as strings: `port` and `connections`
are integers and `ssl` is a boolean. The boolean matters more than it looks,
because SABnzbd parses a server flag with `bool_conv(int_conv())` and stores any
other spelling as 0 -- so a declaration reading as TLS-on would deploy TLS-off
in silence. The role renders it as an integer at the request.

**An undeclared provider is a valid state.** With `media_usenet_provider.host`
empty and the credential pair empty, SABnzbd starts with no server, exactly as
an empty `media_arr_indexers` starts Prowlarr with no indexer. Nothing else
about the platform is affected: this is a declaration the operator has not made,
not a broken one, and the other eight service stacks deploy as usual. The useful
consequence of the split is that "is a provider declared?" is now answerable
without the vault password, because the host is state rather than secret.

The two halves must agree. The credential contract accepts both credentials
empty or both valid, and the downloaders role refuses a host with no account and
an account with no host, so there is no state in between.

Declaring one changes three things. The provider credentials are held to
SABnzbd's own INI and normalization rules before anything is pushed; the
downloaders role reconciles both halves into SABnzbd's `servers` section on
every run, so a server added or edited in the web interface is replaced by the
declared one; and verification asserts the declared server is present and
matches, which is what makes a SABnzbd with no provider fail a run instead of
converging quietly. With none declared, verification asserts the complement —
that no server carries the name the platform owns — so neither state converges
with nothing checked.

Emptying the declaration again does not delete a server the platform already
created: the reconciliation only ever upserts. Verification then fails and names
both remedies, because a server standing with nothing declared is a real
inconsistency and removing it is an operator decision rather than a side effect
of clearing a declaration.

Nothing has to be configured by hand before a proof download; the provider
account has to exist and be recorded in the vault.

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
leave automatic search off, and correct mismatches one title at a time. Bulk
rename is the half this repository gates; keep its default until that review is
accepted:

```yaml
media_arr_automatic_rename_enabled: false
```

Monitoring carries no such flag. It is a setting inside Radarr and Sonarr, and
no task here turns it on, so review it in their own interfaces.

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
- a **manual** ADM share check, from a client signed in as a
  non-administrator SMB account, confirms that `ls /Volumes/Media/.acquisition`
  and `ls /Volumes/Books/.acquisition` are denied or invisible. This one is not
  automatable and the platform does not claim it: both trees are declared mode
  `0755` under a NAS-owned media root, so `o+rx` means no POSIX permission
  refuses an ordinary local account and the denial rests on ADM share
  configuration alone. Listing `usenet torrents` is the finding, and the fix is
  in ADM share permissions rather than in this repository. What the tagged
  verification run does assert is that both directories exist by name, are real
  directories rather than symlinks, carry mode `0755`, and claim no owner or
  group; see
  [the NAS handoff](getting-started-nas.md#7-verify-and-prove-idempotence);
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
