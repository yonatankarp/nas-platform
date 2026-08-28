# Bazarr subtitle providers

`media_bazarr_providers` is validated strictly but against no list of known
providers: any lowercase name with a non-empty settings mapping is accepted. A
misspelled key therefore converges successfully and fetches nothing, which is
the worst of both outcomes.

This file pins what the deployed Bazarr actually accepts, so a provider is
declared from a reviewed schema rather than from a session in its web
interface. It is the same treatment `roles/arr/files/configarr/` gives the
pinned TRaSH documents, for the same reason.

Derived from Bazarr **1.6.0**, the version `services/arr/compose.yml` pins.
`tests/bazarr_provider_schema_test.rb` fails if that pin moves without this
file being re-derived, because provider settings are upstream's to rename.

## What the operator supplies

Account credentials, and nothing else. This repository does not choose a
subtitle provider — that is a regional and legal decision — but which keys a
chosen provider needs is a property of the pinned version, not a decision, so
it belongs here rather than in an export from a running service.

Add the block for each provider you want to the vault, replace the credential
values, and converge. Providers you do not declare are left alone, including any
enabled by hand.

```sh
ansible-vault edit inventory/group_vars/all/vault.yml
```

## Declared form

Bazarr 1.6.0 splits form keys on hyphens, so neither a provider name nor a
setting suffix may contain one: the key is `settings-<provider>-<suffix>` and
both `<provider>` and `<suffix>` must match `^[a-z][a-z0-9_]*$`. Booleans may
be written as `true`/`false` or as the strings `"true"`/`"false"`.

## OpenSubtitles.com

Free account required at opensubtitles.com. Covers most languages.

```yaml
media_bazarr_providers:
  - name: opensubtitlescom
    settings:
      settings-opensubtitlescom-username: replace-me
      settings-opensubtitlescom-password: replace-me
      settings-opensubtitlescom-use_hash: "true"
      settings-opensubtitlescom-include_ai_translated: "false"
      settings-opensubtitlescom-include_machine_translated: "false"
```

## Ktuvit

Hebrew. Account required at ktuvit.me. `hashed_password` is the hashed value
Bazarr expects, not the account password; Bazarr's own provider page explains
how to obtain it.

```yaml
  - name: ktuvit
    settings:
      settings-ktuvit-email: replace-me
      settings-ktuvit-hashed_password: replace-me
```

## Subdl

```yaml
  - name: subdl
    settings:
      settings-subdl-api_key: replace-me
```

## Subsource

Note the suffix is `apikey`, without the underscore that Subdl uses. Upstream
spells them differently and this file records that rather than correcting it.

```yaml
  - name: subsource
    settings:
      settings-subsource-apikey: replace-me
```

## Languages

`media_bazarr_languages` takes the lowercase two-letter codes Bazarr exposes
as `code2`, for example:

```yaml
media_bazarr_languages:
  - en
  - he
```

A code Bazarr does not expose can be declared but will never converge, because
verification compares the enabled set against the declared one.

## When Bazarr is upgraded

Renovate bumps the pinned image. `tests/bazarr_provider_schema_test.rb` then
fails until the version recorded here matches, which is the prompt to re-derive
the keys above from that release's `bazarr/app/config.py` rather than assume
they carried over.
