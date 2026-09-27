# Host clean-up after a removed service

Removing a service is a repository change, and leaving its data is a host one;
only the first happens on merge. `host_prep` creates directories and never
deletes them, so a retired stack's data, and any secret-bearing file in it,
stays on the NAS until an operator removes it by hand. The rule is in
`CLAUDE.md`'s security boundary; these are the worked examples, moved out of it
by #838 with their commands unchanged.

## AdGuard Home (#577)

**A removed service does not take its files with it, and AdGuard Home is the
worked example.** #577 deleted that stack -- role, Compose, contract, lane and
the `nas_storage` entries -- but `host_prep` creates directories and never
deletes them, so `{{ nas_docker_root }}/adguard` is still on the NAS and so are
the two secret-bearing files inside it: `work/data/sessions.db`, whose bearer
tokens for the web interface make a copy of it a login, and the 0600
`AdGuardHome.yaml` beside it, which holds the administrator's bcrypt hash --
a hash rather than a secret, but still what an offline guess would be made
against. Nothing in this repository will remove either, and the service they
belonged to is no longer described here at all, so the usual route of reading
the role is gone too. `rm -rf {{ nas_docker_root }}/adguard` on the host is the
whole tidy-up; both directories are `recovery: cache`, so nothing is lost by
it. The general rule this records is that removing a service is a repository
change and leaving its data is a host one, and only the first of them happens
on merge.

## ntfy (#558)

**ntfy is the second worked example, and its data was not a cache.** #558
turned the stack off in stage 4a and deleted it in stage 4c -- role, Compose,
the eleven `vault_ntfy_*` credentials and `vault_managed_ntfy_users`, the lane
tag, the poller's and the prune's publisher configs and the `nas_storage`
entries -- and the same rule holds: nothing in this repository removes what it
left on the host. `{{ nas_docker_root }}/ntfy/data` was `recovery: critical`: it
holds `auth.db`, every account's bcrypt hash and every access token.
`{{ nas_docker_root }}/ntfy/cache` beside it was `recovery: cache`. The rendered
`.env` under `nas-platform/runtime/services/ntfy` carries those hashes and the
publisher tokens in clear, and the deploy account's
`~/.config/nas-platform/ntfy.curl` and `ntfy-prune.curl` each carry the deploy
publisher's bearer token at mode 0600. The operator has decided to delete all
of it rather than archive it, since nothing any longer runs that those
credentials open. Once `docker ps -a --filter
label=com.docker.compose.project=ntfy` on the NAS prints nothing, the tidy-up is,
as the deploy account:

```sh
rm -rf /volume1/Docker/nas-platform/runtime/services/ntfy
rm -rf /volume1/Docker/ntfy
rm -f "$HOME/.config/nas-platform/ntfy.curl" "$HOME/.config/nas-platform/ntfy-prune.curl"
```
