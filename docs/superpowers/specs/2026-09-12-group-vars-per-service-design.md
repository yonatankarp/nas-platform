# Split `inventory/group_vars/all/main.yml` per service

Status: design, approved 2026-09-12. The vault split is the deliberate follow-on
and is out of scope here; see "Sequencing" below.

## What this changes, and what it does not

`inventory/group_vars/all/main.yml` is 870 lines. This change reduces it to the
genuinely cross-cutting remainder and moves everything service-scoped into one
file per service, storage entries included. It changes no service behaviour, no
credential, no deployment path and no compose definition. Every variable keeps
its name and its value; only the file it is written in changes. `nas_storage` is
the one exception and only in how it is assembled: its entries are unchanged, but
they arrive concatenated in contributor-name order rather than in the order they
were hand-written. `host_prep` creates directories from this list and is order
independent, which the verification step below proves rather than assumes.

It does not touch the vault, `docs/secrets.md`, or the `platform_vault_file`
contract. It does not restructure `nas_storage` entries themselves.

## The measurements this rests on

Taken 2026-09-12 against `35c199b`.

- `main.yml` is 870 lines. `nas_storage` runs from line 491 to the end, so one
  variable is 44% of the file.
- The service-scoped keys come to roughly 430 lines across eleven owners:
  `media_*` (acquisition, split across arr and downloaders), `komga_*`,
  `kapowarr_*`, `ntfy_*`, `paperless_*`, `immich_*`, `trailarr_*`, `nextcloud_*`,
  `vaultwarden_*`, and the two `vault_*` overrides at lines 79-80 and 109.
- The genuinely cross-cutting remainder is about 60 lines: `nas_timezone`,
  `nas_uid`, `nas_gid`, the `platform_*` group, and `nas_python_minimum` /
  `nas_compose_minimum`.
- Fifteen files under `tests/` read `nas_storage` by static parse, with 22 call
  sites. Twelve are Ruby checks doing `YAML.safe_load_file(...).fetch("nas_storage")`
  and expecting a list of dicts. Two are mutation harnesses that mutate the list
  in place (`policy_mutation_support.rb`, `policy_manifest_test.rb`). One is a
  shell drift hook, `tests/mac/hooks/drift/15-media-acquisition-foundation.sh`.
- Nothing in the repository currently defines a variable matching `^nas_storage_`,
  so the namespace the composition claims is clean today.
- `nas_storage` holds 62 entries. 37 sit under `nas_docker_root` and are owned by
  exactly one service each, across 21 container directories that map to the 17
  implemented roles (`arr` owns radarr, sonarr, prowlarr and bazarr;
  `downloaders` owns sabnzbd and qbittorrent). Every one of the 17 roles owns at
  least one, so no service is storage-free today.
- 25 sit under `nas_media_root`, but only 19 of those are genuinely shared. The
  other six are single-owner and go into their owner's file like any docker-root
  entry: `Immich` and `Immich-backups/database` (immich), `.beszel` (beszel), and
  `Documents/{archive,inbox,export}`, which `roles/paperless_ngx/tasks/storage.yml`
  and that role's defaults are the only references to anywhere in the tree.
- The shared 19 are exactly the `nas_media_root` entries carrying
  `media_acquisition_foundation: true`, and they divide cleanly along their own
  recovery class: 7 are `recovery: user` library roots (`Media/Movies`,
  `Media/Series`, `Media/YouTube`, `Media/Audiobooks`, `Books`, `Books/Ebooks`,
  `Books/Comics`) and 12 are `recovery: cache` staging under
  `Media/.acquisition` and `Books/.acquisition`.
- So 43 of the 62 entries are single-owner and 19 are shared.

## Layout

```
inventory/group_vars/all/
  main.yml                  # cross-cutting only, plus the two composition lines
  media_libraries.yml       # nas_storage_media_libraries:   7 user library roots
  media_acquisition.yml     # nas_storage_media_acquisition: 12 staging paths
  service_<role>.yml        # one per service: its settings and its storage entries
  vault.yml                 # unchanged by this spec
  vault.yml.example         # unchanged by this spec
```

Only 19 entries are genuinely shared, and they take two files rather than one.
The split is along a boundary the data already carries rather than one invented
here: the 7 library roots are `recovery: user` and hold irreplaceable household
media, while the 12 staging paths are `recovery: cache` and are disposable
transit. `CLAUDE.md` records that the recovery class drives the disaster-recovery
documentation, so a file that mixes the two mixes what can be rebuilt with what
cannot.

Those 19 are shared by construction and cannot be pushed down to an owner:
`arr` mounts the whole media root and `jellyfin` mounts all of `Media`, `komga`
mounts all of `Books`, and `downloaders` writes the `.acquisition` trees that
`arr` then reads. Assigning them to any one service would be an arbitrary choice
the next reader has to undo.

The six single-owner `nas_media_root` entries are not in either file. They sit
with their owners, in `service_immich.yml`, `service_beszel.yml` and
`service_paperless_ngx.yml`.

Both shared contributors are picked up by the prefix glob with no special case in
the composition and none in the Ruby helper. `media_acquisition_foundation_test.rb`
selects on the `media_acquisition_foundation` flag rather than on position, so
splitting the group across two variables does not disturb it.

The file is named for the **role**, not the manifest service directory, because
Ansible variable names cannot contain hyphens and the storage variable inside
must be `nas_storage_paperless_ngx`. `services/manifest.yml` already maps the two,
and `EXPECTED_FIXTURE_ROLES` in `tests/policy_mutation_support.rb` already pins
that mapping in both directions, so nothing new has to state it.

Each service file holds that service's settings and its `nas_storage_<role>`
list together. Keeping them in one file is the point: a reader asking what Immich
is configured to do and where Immich writes gets one file rather than two.

## Composition

`main.yml` carries exactly two lines for storage:

```yaml
platform_storage_names: "{{ q('varnames', '^nas_storage_') | sort }}"
nas_storage: "{{ q('vars', *platform_storage_names) | flatten(levels=1) }}"
```

No list of services appears anywhere, in Ansible or in Ruby. Adding a service
means adding one file.

This shape was probed empirically on 2026-09-12 against ansible-core 2.21.3
(pinned: 2.21.4) rather than assumed, because two more obvious forms do not work:

- The bare `vars` dictionary (`map('extract', vars)`) emits
  `The internal "vars" dictionary is deprecated. This feature will be removed
  from ansible-core version 2.24` and points at the `vars` and `varnames`
  lookups as the replacement. A form on a removal clock is not worth adopting.
- `hostvars[inventory_hostname]` raises `'hostvars' is undefined` when evaluated
  inside a `group_vars` definition, because host vars are still being assembled
  at that point.

The `q('vars', *names)` form emits no warning, resolves lazily across files, and
ordered correctly by variable name in the probe. Cross-file lazy resolution is
already load-bearing here: `nas_storage` references `nas_docker_root`, which is
defined in `inventory/group_vars/nas_hosts/main.yml`.

`vars` and `varnames` are `ansible.builtin` lookups, not experimental APIs.

## The Ruby side reads the same rule, not a list

A shared helper, `tests/nas_storage_support.rb`, implements the identical rule:
glob `inventory/group_vars/all/*.yml`, collect every top-level key matching
`^nas_storage_`, sort by key name, concatenate the values. The fifteen readers
call it instead of parsing `main.yml` themselves.

That helper is a strict improvement on its own terms. Twelve copies of the same
`YAML.safe_load_file(...).fetch("nas_storage")` become one, and the twelfth copy
was the place a future shape change would have been missed.

Deriving on both sides rather than restating a service list is deliberate, and it
follows the rule `CLAUDE.md` already states for
`tests/idempotence_shard_partition_test.rb`: adding a service touches 59 files,
and a sixtieth list is the one nobody edits.

## Guards this change must add

**A floor, because the derived composition is silent when it loses everything.**
Probed: deleting every contributing file leaves `nas_storage` as `[]` and the
play reports `ok=1` with no error and no warning. This is the failure mode the
repository keeps closing, and non-emptiness does not catch it. So:

The floor is a membership check against an independent subject list, not a count,
because a count goes stale the moment a service is added:

- `tests/nas_storage_support.rb` asserts that every implemented and accepted role
  in `services/manifest.yml` contributes a `nas_storage_<role>` variable, and that
  every contributor names such a role unless it appears in a declared
  `SHARED_STORAGE_CONTRIBUTORS` list, which holds exactly
  `nas_storage_media_libraries` and `nas_storage_media_acquisition` and is
  asserted in both directions so a third shared file cannot appear unnoticed.
  Both directions on the roles too. A service legitimately owning no storage is admitted by name
  through a declared `STORAGE_FREE_SERVICES` list, which is empty today and is
  asserted in both directions so it cannot fill up or empty quietly. This mirrors
  `CREDENTIAL_FREE_SERVICES` in `tests/policy_support.rb` exactly, including the
  reason: a service that loses its last entry must fail as loudly as one that
  gains a first.
- `host_prep` asserts `platform_storage_names | length` against a stated minimum
  before it creates anything. This is the crude backstop for total collapse, which
  the membership check cannot catch on the Ansible side because Ansible does not
  read the manifest. A stated number is acceptable here precisely because it is a
  floor and not an equality: it only has to be large enough that an empty or
  nearly empty composition fails.

**A prefix reservation, because `varnames` reads what is in scope.** A role
default named `nas_storage_*` would join the composition partway through a run,
which would make `nas_storage` evaluate differently depending on where it is
read. A new check in `tests/policy_test.rb` refuses any definition of a variable
matching `^nas_storage_` outside `inventory/group_vars/all/`. The namespace is
clean today, so this check starts green and stays cheap.

**Existing coverage that does not need extending.** `tests/policy_test.rb`
already walks every volume mount in every `services/*/compose.yml`, rewrites
`${NAS_DOCKER_ROOT:?}` to `{{ nas_docker_root }}`, and asserts the result is
declared in `nas_storage`. Its subject list is the compose files, which this
change does not touch. So a service dropped out of the composition fails there
with `is not declared in nas_storage`, per mount, from an independently anchored
subject list. That is what makes a derived composition safe here.

## Migration

1. `tests/nas_storage_support.rb`, with its floor, written first and proved
   against the current single-file layout so the helper is known-good before
   anything moves.
2. The twelve Ruby readers and the shell drift hook move to the helper.
3. The two mutation harnesses become service-aware: planting a defect loads that
   service's file, mutates, and writes it back. `policy_mutation_support.rb`
   currently does `storage.fetch("nas_storage") << {...}`; it must now name which
   service it is planting into, which is more precise than mutating an anonymous
   position in a 380-line list.
4. `fixture_paths` gains `inventory/group_vars/all/service_<role>.yml` inside the
   loop it already runs over `services/manifest.yml`. The permanent per-service
   obligation is therefore zero, and `BASE_FIXTURE_PATHS` stays the literal list
   of genuinely global files its own comment describes.
5. The service files are created and `main.yml` is reduced, one service per
   commit, so a bisect lands on one service.
6. `main.yml` gains the two composition lines and loses `nas_storage`.

Every prose comment moves with the declaration it justifies. No comment is
relocated away from its subject, because that is the documented way a claim in
this repository goes stale.

## Verification

- `ruby tests/policy_test.rb` after each service moves.
- `ansible-playbook -i inventory/local.yml site.yml --syntax-check`.
- `ansible-lint --strict`.
- A rendered-equality proof: dump `nas_storage` before and after the whole
  migration and assert the two are identical as sets and as ordered lists. The
  ordering is `sort` by variable name, which is not the current hand-written
  order, so the ordered comparison is expected to differ and must be reviewed
  rather than asserted equal. `host_prep` creates directories from this list and
  ordering does not affect that, but the check is what proves it.
- `tests/validate-policy.sh` in full.
- `tests/integration.sh --suite smoke site.yml`, which converges `host_prep`
  against a real `/proc/mounts` and real uid/gid.
- `ruby tests/policy_manifest_test.rb --audit`, because the mutation rows change.

## Sequencing

The vault split is a separate spec and a separate pull request, done after this
one merges. The two share only a directory. This half touches no encryption, no
`.gitignore` pattern, no `PLATFORM_VAULT_FILE` contract, no `shasum` in the mac
lane and no `generate-secrets.yml`; the vault half needs all of them, and a
mistake there is a security-boundary regression rather than a failed check.

`vault_managed_users` is the vault's equivalent of `nas_storage`: one dict keyed
by service, so unsplittable as it stands for the same `hash_behaviour` reason.
It takes the same treatment, with each per-service vault file carrying a
single-key dict (`vault_managed_users_immich: {immich: [...]}`) and the shared
file composing with `q('vars', *names) | combine`, so the service key stays in
the data rather than being derived from a variable name. Proving the pattern
here is most of why this half goes first.

## Alternatives rejected

**Leave `nas_storage` whole and move it to `storage.yml`.** One file, every
reader changes one path constant, no new guard. Rejected because it leaves the
largest block monolithic and does not deliver the per-service layout, and the
reader cost it avoids is roughly the reader cost this design pays anyway.

**Restate the service list in Ruby.** A literal list in
`tests/nas_storage_support.rb` matching a literal Jinja composition, asserted
equal both directions. Rejected as the sixtieth list.

**Derive the composition from `services/manifest.yml` via
`lookup('vars', 'nas_storage_' ~ name) | default([])`.** Rejected because
`default([])` makes a missing contributor contribute silently nothing, which is
the failure this design spends a floor to prevent.

## As built, 2026-09-13

Five things the design did not anticipate. Each is a decision the implementation
had to make, recorded here rather than left for the next reader to reverse-engineer.

**The composition sorts by path, which the design did not call for.** The
hand-written inventory kept the two `.acquisition` roots ahead of their leaves on
purpose, and its own comment says why: `ansible.builtin.file` applies a declared
mode to an intermediate parent only at the moment it creates it. Ordering
contributors by variable name broke that for `/Books`, whose `.acquisition`
children sort ahead of it. `| sort(attribute='path')` makes the invariant
structural instead, because a parent path is a prefix of its children. The
composed list has zero parent-after-child pairs, against zero in the original.

**"The shared inventory" had to become the directory in more than one place.**
`tests/policy_vault_test.rb` sweeps the non-secret inventory for `vault_`-prefixed
names and requires each to be a credential the contract validates. Reading
`main.yml` alone would have left nineteen files free to reintroduce exactly the
lie #298 and #353 removed, so `NasStorage.shared_inventory` merges the directory
and the sweep covers all of it. It raises on a duplicate key, which Ansible would
resolve silently by load order.

**Not every reader wanted the composed list.** A contract that only asserts its
own service's paths now reads that service's file and its own
`nas_storage_<role>`: `paperless-static.rb`, `audiobookshelf-static.rb` and the
Komga and Kapowarr migration flags. That is a narrower claim than scanning a
shared list for a path, and it made those wrappers pass one file rather than
gaining an argument. `kapowarr-static.rb` and `nextcloud-static.rb` kept the
composed view because the paths they check are shared media groups.

**`tests/nas_storage_support.rb` is in `BASE_FIXTURE_PATHS`, not derived.** The
derivation covers the per-service files; the helper itself is a global file every
policy script requires. Omitting it produced the documented symptom exactly: all
465 mutation rows failed at once with a `LoadError` naming the sandbox path.

**One mutation row had to widen.** "media library leaves removed from storage"
empties every `{{ nas_media_root }}/Media/` entry to prove Jellyfin's mount goes
undeclared. Split across two contributors, emptying `media_libraries.yml` alone
left the staging paths still sitting under `/Media` and covering the mount, so
the plant stopped biting. It now reaches every contributor. This is the failure
mode the repository's own rule warns about: a plant that no longer reproduces its
defect reports a pass.

### Verified

- 62 entries before and after, set-identical, nothing lost or gained; every other
  key and value unchanged and no key defined twice across the directory.
- The Ruby helper produces byte-identical content and ordering to what Ansible
  composes, checked against a live `ansible-playbook` dump.
- Five planted defects detected with the right message: a contributor removed
  while its file remains, a contributor renamed to a non-role name, a shared
  contributor renamed out from under `SHARED_CONTRIBUTORS`, and the prefix taken
  by a role default.
- `tests/policy_manifest_test.rb`: 282 mutations at 196 call sites, all detected.
- `ansible-lint --strict`: 0 failures, production profile.
- `ansible-playbook -i inventory/local.yml site.yml --syntax-check`.

### Not done here

The integration suites need Docker and have not been run from this machine;
`tests/integration.sh --suite smoke site.yml` is the one that converges
`host_prep` against a real `/proc/mounts` and real uid/gid, and it is the check
that would catch an ordering or ownership regression the static gate cannot see.
CI runs it on the pull request.
