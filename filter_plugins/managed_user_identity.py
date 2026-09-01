"""The one identity-ambiguity decision the six HTTP-driven roles share.

Komga, Audiobookshelf, Jellyfin, Beszel, Paperless and Immich each reconcile
managed users against a different API, and issue #143 proposed folding all six
into one parameterised role. They are not one algorithm: Paperless lists through
`docker_compose_v2_exec` rather than HTTP and its authentication returns only a
JWT with no identity to echo back; Jellyfin carries a forbidden-policy-fields
completeness subsystem and gates on a `preflight` phase the others do not have;
Immich reconciles preferences and an avatar on top of the user record. What they
*do* share is this single decision, spelled out as two Jinja conditions in five
of them and one in the sixth:

    matches | length <= 1
    listing | map(attribute=A) | map('trim') | map('lower') |
      select('equalto', identity | trim | lower) | list | length ==
      matches | length

Read together those say: **the managed identity selected exactly one listed
user, and no other listed user would have collided with it under case folding
and trimming.** The second half is the part worth having in one place — it is
what stops a service that treats `Alice@example.com` and `alice@example.com` as
one account from being reconciled as if they were two, which would let a repair
land on the wrong record.

Immich reaches the same guarantee by construction: it indexes the listing by
normalised email first, so its match list *is* the normalised bucket and the
second condition is identically true. Calling this from Immich therefore adds no
behaviour, and keeps the sixth role from being the one that drifts.

Audiobookshelf additionally asserted `matches[0].username == identity`. Its
matches come from `selectattr('username', 'equalto', identity)`, so that was
provably redundant and is not reproduced here. It cannot be reproduced: Immich's
matches are normalised, so an exact-equality rule would be false for the very
case Immich is designed to fold.

What this module deliberately does **not** absorb:

* **The safe-identifier regex.** Four roles spell four different patterns
  (`^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$`, `^[A-Fa-f0-9-]{32,36}$`,
  `^[A-Za-z0-9_-]{1,64}$`, `^[0-9A-Fa-f-]{36}$`) and Paperless has none, because
  its identifier is a database primary key. Moving a regex behind a parameter
  moves no decision.
* **Match resolution itself.** Five roles build the match map with a looped
  `set_fact`; Immich builds a normalised index instead. Those are different
  semantics, not different arguments.
* **Listing completeness, authentication and repair.** One, four and five
  conditions respectively across the six, against different transports, request
  bodies and response shapes.
* **The sixteen-step skeleton itself.** Parse all six files and bucket their
  151 tasks by content with the service name masked, and 16 (11%) land in a
  bucket some other service shares. Mask the identity attribute, the ID field
  and the four safe-identifier regexes too and it is 22 (15%). Drop every value
  and keep only the keys, the module, the control keywords and the list lengths
  and it is 89 (59%) — that last is what "sixteen identical steps" measures,
  and it is the shape of an Ansible task, not shared behaviour. Line-level
  overlap reads higher still: 1,812 of the 2,498 significant lines have a twin
  in another role. But those 1,812 occurrences are only 149 distinct texts,
  of which `no_log: true` (126), `loop_control:` (117),
  `label: <svc>-managed-user` (115) and `when:` (86) are already a quarter.

Four task bodies are genuinely shared, spanning six, five, four and three
services. The `debug` reporting planned creation is the only one of the 151
with a twin in every other role — and even it needs the identity attribute
masked, because until then it splits into an `email` half and a `username`
half. The opening phase-validate assert spans five: every role but Jellyfin,
which declares `['preflight', 'reconcile', 'verify']` where the other five
declare `['reconcile', 'verify']`. The safe-identifier assert spans four,
Audiobookshelf, Beszel, Jellyfin and Komga, and only once its four different
regexes are masked away; unmasked it shares with nothing. The binding-facts
initializer, `{{ x | default({}) }}` over the `initial_` ID map, spans three:
Beszel, Immich and Paperless.

That second bucket is the warning, because the phase gate is not uniform where
it matters most. `Authenticate existing <svc> managed users` is gated three
ways: Komga and Audiobookshelf run it only under `reconcile`; Jellyfin under
`preflight` or `reconcile`; Beszel, Paperless and Immich under no phase gate at
all, only `not ansible_check_mode` and a match count of one. The three ungated
ones are deliberate. Their `Verify exact` asserts compare the listed record's
id against `<svc>_authenticated_managed_user_ids` — Beszel and Immich against
the `initial_` companion as well — and nothing but authentication sets those
facts, so authentication must run during `verify` too. The three roles carrying
the binding-facts initializer are exactly those three, for the same reason. A
shared entry point that unified the gate would either break `verify.yml` for
Beszel, Paperless and Immich or begin proving credentials during verify for
Komga and Audiobookshelf. Only one of the six gates is pinned:
`tests/contracts/audiobookshelf-runtime.rb` asserts Audiobookshelf's
authenticate `when:` list in full, phase literal included. The other five are
pinned only for the presence of `not ansible_check_mode`, so five of the six
would ship green and the sixth would read like a contract that merely needed
updating.

`tests/policy_test.rb` closes the remaining door. A tasks file gating on a
`*_phase` variable must open with an unconditional assert naming the phases it
implements, and its callers must pass exactly that set — callers resolved only
through `ansible.builtin.include_tasks` against a path relative to the
including file. A shared `roles/managed_users/` reached by `include_role` with
`tasks_from` is invisible to that resolution, so it would declare phases and
fail with "declares … but its callers pass none". Parameterising the six would
mean first weakening the guard that makes an unrecognised phase loud, in the
same change that makes phase handling uniform.

Every string this can return names the API attribute and a count. No identity
value, and nothing drawn from the listing, ever reaches the result, so callers
can print it from a `fail_msg` while the task runs under `no_log` — the same
contract `immich_response_schema` carries and for the same reason.
"""

import importlib.util
from pathlib import Path


# Filter plugins cannot import module_utils/ by name, and putting the repository
# root on sys.path to reach it would shadow site-packages with library/, roles/,
# services/ and tests/ for the whole Ansible process. Loading the file by path
# shares the guards with no global side effect. tests/policy_test.rb executes
# every filter plugin and fails if one of them touches sys.path.
_GUARDS_SPEC = importlib.util.spec_from_file_location(
    "nas_platform_schema_guards",
    Path(__file__).resolve().parents[1] / "module_utils" / "schema_guards.py",
)
_GUARDS = importlib.util.module_from_spec(_GUARDS_SPEC)
_GUARDS_SPEC.loader.exec_module(_GUARDS)


def _normalize(value):
    """Jinja's `trim | lower`, which is `str.strip()` then `str.lower()`.

    `vault_managed_user_schema._normalized_identities` already folds the same
    identities the same way, for the same reason and against the same Jinja
    chain. The two must agree or the vault would accept a pair of identities
    this module then refuses at reconciliation time, so a test pins them
    together on an identity no ASCII-only fixture would catch.
    """
    return value.strip().lower()


def managed_user_ambiguity_errors(listing, attribute, identity, matches):
    """Return every ambiguity violation for one managed identity, as text.

    `listing` is the service's full user collection, already unwrapped from
    whatever envelope it arrived in. `attribute` is the API attribute the
    identity lives under — `email`, `username` or Jellyfin's `Name`. `identity`
    is the value authored in the vault. `matches` is the list the role resolved
    for it.

    An empty list means exactly one listed user answers to this identity, or
    none does and the role may create it.
    """
    attribute = _GUARDS.string(attribute, "managed user identity attribute")
    identity = _GUARDS.string(identity, f"managed user {attribute}")
    listing = _GUARDS.sequence(listing, "managed user listing", noun="a list")
    matches = _GUARDS.sequence(
        matches, f"resolved {attribute} matches", noun="a list"
    )

    errors = []
    if len(matches) > 1:
        errors.append(
            f"{attribute}: {len(matches)} listed users match this managed "
            "identity, and at most one may"
        )

    unreadable = []
    normalized = 0
    for index, entry in enumerate(listing):
        if not _GUARDS.is_mapping(entry):
            unreadable.append(f"listed user {index}: must be a mapping")
            continue
        value = entry.get(attribute)
        if not _GUARDS.is_string(value):
            # Jinja's `trim` renders a missing or null attribute as the literal
            # "None", which folds to "none" and can collide with a real
            # identity. Refusing the listing is the only safe reading.
            unreadable.append(
                f"listed user {index}: {attribute} must be a string"
            )
            continue
        if _normalize(value) == _normalize(identity):
            normalized += 1

    # A listing this module cannot read is reported as itself; the collision
    # count derived from it would be an understatement, so it is not reported.
    if unreadable:
        return errors + unreadable
    if normalized != len(matches):
        errors.append(
            f"{attribute}: {normalized} listed users normalize to this managed "
            f"identity but {len(matches)} match it, so a repair could land on "
            "the wrong record"
        )

    return errors


class FilterModule:
    """Expose the shared managed-user ambiguity decision to Ansible."""

    def filters(self):
        return {"managed_user_ambiguity_errors": managed_user_ambiguity_errors}
