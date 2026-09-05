"""Shape validation for the portable scalar credentials carried in the vault.

`roles/vault_contract` previously expressed this as 49 Jinja conditions in a
single `assert` task. The task runs under `no_log`, and `no_log` censors the
result dictionary an `assert` would otherwise print, so a failure reported only
"Portable vault credentials are missing or malformed; values are redacted."
Finding out which of the 49 credentials was wrong meant editing the role to
bisect the condition list, on a task whose inputs are the platform's entire
credential set.

This module keeps the same rules as a declarative table and reports which key
failed. `no_log` does not suppress `fail_msg`, so naming the key is what turns
that message into "vault_paperless_db_name: does not match the required format".

Following `vault_managed_user_schema` and `immich_preference_schema`, no message
ever carries a value. Neither does one carry the literal a value was compared
against, even where that literal is already public in the repository: the rule
that keeps a diagnostic printable is that it names fields and nothing else, and
an exception for "this one is not really a secret" is how such a rule stops
holding. `JELLYFIN_ADMIN_USERNAME` and the OpenSubtitles and ComicVine
placeholders are the comparands, and they stay out of the output.

Semantics are matched to Ansible's Jinja tests, verified on ansible-core 2.21.3:
`is match` anchors at the start only, so patterns needing a full match carry
their own end anchor; `is search` is unanchored; `| length > 0` accepted
whitespace, so these rules reject only a zero length.

**The rules here are deliberately no stricter than the conditions they replace,
including where those conditions were accidentally lax.** Role argument
validation does not coerce or reject a non-string for a `type: str` option, so
three families of non-string value reach these rules and were accepted:

* `| length > 0` measures any sized value, so a non-empty list or mapping passed.
* `is match` compares the *text* of its subject, so `true` became `"True"` and
  `none` became `"None"`. Both satisfy `DATABASE_IDENTIFIER`, and a list of one
  address satisfies `EMAIL` through its `repr`.
* `is search` coerces the same way, so a container whose `repr` carries the
  OpenSSH marker passed.

Those are latent gaps, not intentions, and none of them is reachable from a vault
this repository generates or documents. Tightening them would change what
deploys, which is outside issue #27: this change has to be verdict-identical to
be reviewable as the refactor it is. `tests/vault_credential_schema_test.py`
pins the six cases so the next reader does not "fix" them silently, and the gaps
are reported for their own ticket.
"""

import re


BCRYPT_HASH = re.compile(r"^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$")
DATABASE_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
EMAIL = re.compile(r"^[^@ ]+@[^@ ]+$")
HEX_32 = re.compile(r"^[0-9a-f]{32}\Z")

# Two of the hex API keys are submitted to Bazarr's settings form, and Bazarr
# 1.6.0's `save_settings` casts every submitted string with `int()` unless the
# last dash-segment of its key is one of `app/config.py`'s `str_keys` -- `apikey`
# is not one. dynaconf then validates the whole schema, so a key of only decimal
# digits arrives as an `int`, fails `is_type_of str`, and the request is answered
# 406 for as long as that key is deployed. `openssl rand -hex 16` draws such a
# key about once in 3e-7, but the operator also mints these by hand, and this is
# the only place that sees a hand-authored one before it deploys.
HEX_LETTER = re.compile(r"[a-f]")

# SABnzbd's normalization rules used to live here, for the four provider values
# that are not credentials. They moved to filter_plugins/media_usenet_provider.py
# with those values (#298); `OptionStr` still strips the account name, which is
# why the two rules below are NONEMPTY rather than a pattern.
NTFY_TOKEN = re.compile(r"^tk_[a-z0-9]{29}$")
SSH_ED25519_PUBLIC_KEY = re.compile(r"^ssh-ed25519 [A-Za-z0-9+/]+={0,3}$")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}"
                  r"-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

OPENSSH_PRIVATE_KEY_MARKER = "BEGIN OPENSSH PRIVATE KEY"

# The Jellyfin server owns its administrator account name and the platform cannot
# rename it, so the vault has to agree with the deployed server rather than the
# other way round.
JELLYFIN_ADMIN_USERNAME = "Yonatan"

# vault.yml.example and templates/vault-plain.yml.j2 both ship an OpenSubtitles
# stand-in, because the credential belongs to a third-party account the platform
# cannot generate. Either literal reaching a deployment means the operator never
# supplied the real one, and Jellyfin would fail subtitle downloads silently.
OPENSUBTITLES_USERNAME_PLACEHOLDERS = ("example-opensubtitles-username",
                                       "replace-with-opensubtitles-username")
OPENSUBTITLES_PASSWORD_PLACEHOLDERS = ("example-opensubtitles-password",
                                       "replace-with-opensubtitles-password")

# The ComicVine key belongs to a third-party account too. Kapowarr refuses a key
# ComicVine does not recognize, so a stand-in reaching a deployment leaves the
# comics writer unable to identify anything it downloads.
COMICVINE_API_KEY_PLACEHOLDERS = ("example-comicvine-api-key",
                                  "replace-with-comicvine-api-key")

NONEMPTY = "nonempty"
PATTERN = "pattern"
EXACT = "exact"
CONTAINS = "contains"
NOT_PLACEHOLDER = "not_placeholder"
SEARCH = "search"

# One entry per portable scalar credential, in the order the role's conditions
# stood in, so a diagnostic reads in the order an operator would scan the vault.
# The key set is exhaustive by contract: `vault_credential_errors` rejects a
# candidate whose keys differ, which is what stops a credential from losing its
# rule by being dropped from the role's call.
CREDENTIAL_RULES = {
    "vault_audiobookshelf_admin_username": ((NONEMPTY, None),),
    "vault_audiobookshelf_admin_password": ((NONEMPTY, None),),
    "vault_dozzle_admin_username": ((NONEMPTY, None),),
    "vault_dozzle_admin_password": ((NONEMPTY, None),),
    "vault_dozzle_admin_password_hash": ((PATTERN, BCRYPT_HASH),),
    "vault_immich_admin_email": ((PATTERN, EMAIL),),
    "vault_immich_admin_password": ((NONEMPTY, None),),
    "vault_immich_db_name": ((PATTERN, DATABASE_IDENTIFIER),),
    "vault_immich_db_username": ((PATTERN, DATABASE_IDENTIFIER),),
    "vault_immich_db_password": ((NONEMPTY, None),),
    "vault_jellyfin_admin_username": ((EXACT, JELLYFIN_ADMIN_USERNAME),),
    "vault_jellyfin_admin_password": ((NONEMPTY, None),),
    "vault_jellyfin_opensubtitles_username": (
        (NONEMPTY, None),
        (NOT_PLACEHOLDER, OPENSUBTITLES_USERNAME_PLACEHOLDERS),
    ),
    "vault_jellyfin_opensubtitles_password": (
        (NONEMPTY, None),
        (NOT_PLACEHOLDER, OPENSUBTITLES_PASSWORD_PLACEHOLDERS),
    ),
    "vault_komga_admin_email": ((PATTERN, EMAIL),),
    "vault_komga_admin_password": ((NONEMPTY, None),),
    "vault_ntfy_admin_user": ((NONEMPTY, None),),
    "vault_ntfy_admin_password": ((NONEMPTY, None),),
    "vault_ntfy_admin_password_hash": ((PATTERN, BCRYPT_HASH),),
    "vault_ntfy_dozzle_password_hash": ((PATTERN, BCRYPT_HASH),),
    "vault_ntfy_beszel_password_hash": ((PATTERN, BCRYPT_HASH),),
    "vault_ntfy_deploy_password_hash": ((PATTERN, BCRYPT_HASH),),
    "vault_ntfy_seerr_password_hash": ((PATTERN, BCRYPT_HASH),),
    "vault_ntfy_dozzle_token": ((PATTERN, NTFY_TOKEN),),
    "vault_ntfy_beszel_token": ((PATTERN, NTFY_TOKEN),),
    "vault_ntfy_deploy_token": ((PATTERN, NTFY_TOKEN),),
    "vault_ntfy_seerr_token": ((PATTERN, NTFY_TOKEN),),
    "vault_beszel_superuser_email": ((PATTERN, EMAIL),),
    "vault_beszel_superuser_password": ((NONEMPTY, None),),
    "vault_beszel_app_user_email": ((PATTERN, EMAIL),),
    "vault_beszel_app_user_password": ((NONEMPTY, None),),
    "vault_beszel_agent_key": ((PATTERN, SSH_ED25519_PUBLIC_KEY),),
    "vault_beszel_universal_token": ((PATTERN, UUID),),
    "vault_beszel_hub_private_key": ((CONTAINS, OPENSSH_PRIVATE_KEY_MARKER),),
    "vault_paperless_admin_username": ((NONEMPTY, None),),
    "vault_paperless_admin_password": ((NONEMPTY, None),),
    "vault_paperless_admin_email": ((PATTERN, EMAIL),),
    "vault_paperless_db_name": ((PATTERN, DATABASE_IDENTIFIER),),
    "vault_paperless_db_username": ((PATTERN, DATABASE_IDENTIFIER),),
    "vault_paperless_db_password": ((NONEMPTY, None),),
    "vault_paperless_django_secret_key": ((NONEMPTY, None),),
    "vault_paperless_gmail_account": ((PATTERN, EMAIL),),
    "vault_paperless_gmail_app_password": ((NONEMPTY, None),),
    "vault_arr_radarr_api_key": ((PATTERN, HEX_32), (SEARCH, HEX_LETTER)),
    "vault_arr_radarr_admin_username": ((NONEMPTY, None),),
    "vault_arr_radarr_admin_password": ((NONEMPTY, None),),
    "vault_arr_sonarr_api_key": ((PATTERN, HEX_32), (SEARCH, HEX_LETTER)),
    "vault_arr_sonarr_admin_username": ((NONEMPTY, None),),
    "vault_arr_sonarr_admin_password": ((NONEMPTY, None),),
    "vault_arr_prowlarr_api_key": ((PATTERN, HEX_32),),
    "vault_arr_prowlarr_admin_username": ((NONEMPTY, None),),
    "vault_arr_prowlarr_admin_password": ((NONEMPTY, None),),
    "vault_arr_bazarr_api_key": ((PATTERN, HEX_32),),
    "vault_arr_bazarr_admin_username": ((NONEMPTY, None),),
    "vault_arr_bazarr_admin_password": ((NONEMPTY, None),),
    "vault_downloaders_sabnzbd_api_key": ((PATTERN, HEX_32),),
    "vault_downloaders_sabnzbd_admin_username": ((NONEMPTY, None),),
    "vault_downloaders_sabnzbd_admin_password": ((NONEMPTY, None),),
    "vault_downloaders_sabnzbd_server_username": ((NONEMPTY, None),),
    "vault_downloaders_sabnzbd_server_password": ((NONEMPTY, None),),
    "vault_bindery_api_key": ((PATTERN, HEX_32),),
    "vault_bindery_admin_username": ((NONEMPTY, None),),
    "vault_bindery_admin_password": ((NONEMPTY, None),),
    "vault_kapowarr_admin_username": ((NONEMPTY, None),),
    "vault_kapowarr_admin_password": ((NONEMPTY, None),),
    "vault_kapowarr_comicvine_api_key": (
        (NONEMPTY, None),
        (NOT_PLACEHOLDER, COMICVINE_API_KEY_PLACEHOLDERS),
    ),
    "vault_pinchflat_admin_username": ((NONEMPTY, None),),
    "vault_pinchflat_admin_password": ((NONEMPTY, None),),
    "vault_trailarr_api_key": ((PATTERN, HEX_32),),
    "vault_trailarr_admin_username": ((NONEMPTY, None),),
    "vault_trailarr_admin_password": ((NONEMPTY, None),),
    "vault_trailarr_admin_password_hash": ((PATTERN, BCRYPT_HASH),),
    "vault_seerr_api_key": ((PATTERN, HEX_32),),
}

# The Usenet provider account belongs to a paid third-party subscription, so a
# target that has not bought one has nothing to declare. That is a valid state,
# the same one an empty `media_arr_indexers` describes, and
# `inventory/group_vars/all/main.yml` expresses it by declaring both of these as
# empty strings so the vault can win over them without the contract losing a
# required key.
#
# The group is all-or-nothing on purpose: the rules are suppressed only when both
# are empty, so an account name with no password is reported field by field
# rather than accepted. "Which field did I forget" is the question an operator
# actually has, and the per-field rules answer it.
#
# What this group can no longer see is the host, because the host is operator
# policy rather than a credential (#298). So it can no longer be the thing that
# refuses a provider declared on one side and not the other. That agreement is
# asserted in roles/downloaders/tasks/main.yml, before anything reads
# `downloaders_usenet_provider_declared` -- three consumers take that variable
# as proof the credentials exist, and this tuple used to be why they could.
#
# tests/policy_vault_test.rb pins this tuple against its own OPERATOR_SUPPLIED_KEYS
# so the two cannot drift.
OPTIONAL_KEY_GROUPS = (
    ("vault_downloaders_sabnzbd_server_username",
     "vault_downloaders_sabnzbd_server_password"),
)

# The four publisher tokens authenticate four different ntfy identities. A
# duplicate would authorize one publisher as another, and the role's own
# publisher separation rule for managed users would then have nothing to
# separate.
DISTINCT_KEY_GROUPS = (
    ("vault_ntfy_dozzle_token", "vault_ntfy_beszel_token",
     "vault_ntfy_deploy_token", "vault_ntfy_seerr_token"),
    ("vault_arr_radarr_api_key", "vault_arr_sonarr_api_key",
     "vault_arr_prowlarr_api_key", "vault_arr_bazarr_api_key",
     "vault_downloaders_sabnzbd_api_key"),
    ("vault_arr_radarr_admin_password", "vault_arr_sonarr_admin_password",
     "vault_arr_prowlarr_admin_password", "vault_arr_bazarr_admin_password",
     "vault_downloaders_sabnzbd_admin_password"),
)


def _text(value):
    """Coerce as Ansible's `match` and `search` tests do before comparing.

    `str` reproduces `to_text` for every type YAML can carry into the vault, and
    the coercion is what the original conditions applied, so it is what the rules
    have to apply to reach the same verdicts.
    """
    return value if isinstance(value, str) else str(value)


def _is_undeclared(value):
    """Report whether a value declares nothing, as `NONEMPTY` measures emptiness.

    A zero length is the only undeclared shape, so `""` is undeclared and `"0"`
    is not. A value with no length to measure -- `none` above all -- stays
    declared, so `NONEMPTY` still reports it rather than an absent credential
    silently suppressing its own group's rules.
    """
    try:
        return len(value) == 0
    except TypeError:
        return False


def _suppressed_keys(value):
    """Return the keys whose rules an entirely undeclared group switches off."""
    suppressed = set()
    for key_group in OPTIONAL_KEY_GROUPS:
        if not all(key in value for key in key_group):
            continue
        if all(_is_undeclared(value[key]) for key in key_group):
            suppressed.update(key_group)
    return suppressed


def _apply(errors, key, value, kind, argument):
    if kind == NONEMPTY:
        # `| length > 0` errored for a value with no length, which failed the
        # assert, and measured every other value including containers.
        try:
            length = len(value)
        except TypeError:
            errors.append(f"{key}: has no length to measure")
            return
        if length == 0:
            errors.append(f"{key}: must not be empty")
    elif kind == PATTERN:
        if not argument.match(_text(value)):
            errors.append(f"{key}: does not match the required format")
    elif kind == EXACT:
        if value != argument:
            errors.append(f"{key}: must be the pinned administrator username")
    elif kind == CONTAINS:
        if argument not in _text(value):
            errors.append(f"{key}: is missing the required key marker")
    elif kind == SEARCH:
        if not argument.search(_text(value)):
            errors.append(f"{key}: must contain at least one a-f character, "
                          "because Bazarr casts an all-digit API key to an int "
                          "and then refuses it")
    elif kind == NOT_PLACEHOLDER:
        # `!=` against a non-string never matched, so only a string can be the
        # placeholder; the key's NONEMPTY rule is what rejects the rest.
        if value in argument:
            errors.append(f"{key}: is still the documented placeholder")


def vault_credential_errors(value):
    """Return every shape violation in the portable scalar vault credentials.

    `value` maps each credential's variable name to its value, which is how the
    role states the key set it is validating: a key dropped from that mapping is
    reported here rather than silently losing its rule.

    Never includes a value or a comparand, so the result is safe to print from a
    `fail_msg`. An empty list means every credential satisfies the contract,
    which includes an `OPTIONAL_KEY_GROUPS` group left entirely empty: that is a
    declaration of nothing, not a missing credential.
    """
    if not isinstance(value, dict):
        return ["vault credentials: must be a mapping"]

    errors = []
    missing = [key for key in CREDENTIAL_RULES if key not in value]
    if missing:
        errors.append(f"vault credentials: missing {', '.join(missing)}")
    unexpected = [str(key) for key in value if key not in CREDENTIAL_RULES]
    if unexpected:
        errors.append(f"vault credentials: unexpected {', '.join(unexpected)}")

    suppressed = _suppressed_keys(value)
    for key, rules in CREDENTIAL_RULES.items():
        if key not in value or key in suppressed:
            continue
        for kind, argument in rules:
            _apply(errors, key, value[key], kind, argument)

    # `| unique` deduplicates by equality rather than by hash, so this does too:
    # an unhashable value was compared, not rejected.
    for key_group in DISTINCT_KEY_GROUPS:
        if not all(key in value for key in key_group):
            continue
        distinct = []
        for credential in (value[key] for key in key_group):
            if credential not in distinct:
                distinct.append(credential)
        if len(distinct) != len(key_group):
            errors.append("vault credentials: "
                          f"{', '.join(key_group)} must all differ")
    return errors


class FilterModule:
    """Expose the portable vault credential shape validator to Ansible."""

    def filters(self):
        return {"vault_credential_errors": vault_credential_errors}
