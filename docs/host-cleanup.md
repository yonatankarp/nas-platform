# Host clean-up after a removed service

Removing a service is a repository change, and leaving its data is a host one;
only the first happens on merge unless a task is written to do the second.
`host_prep` creates directories and deletes only what a task names, so a retired
stack's data, and any secret-bearing file in it, stays on the NAS until an
operator or such a task removes it. The rule is in `CLAUDE.md`'s security
boundary; these are the worked examples, moved out of it by #838. AdGuard's is
still a manual tidy-up; ntfy's is now done by the repository.

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
entries -- and the same rule held: none of that removed what it left on the
host. `{{ nas_docker_root }}/ntfy/data` was `recovery: critical`: it
holds `auth.db`, every account's bcrypt hash and every access token.
`{{ nas_docker_root }}/ntfy/cache` beside it was `recovery: cache`. The rendered
`.env` under `nas-platform/runtime/services/ntfy` carries those hashes and the
publisher tokens in clear, and the deploy account's
`~/.config/nas-platform/ntfy.curl` and `ntfy-prune.curl` each carry the deploy
publisher's bearer token at mode 0600. The operator decided to delete all of it
rather than archive it, since nothing any longer runs that those credentials
open, and the NAS was found still running the container. **The repository now does the tidy-up**, so there is nothing to
run by hand:

- `roles/host_prep/tasks/retire_ntfy.yml` removes every container and network
  labelled with ntfy's Compose project (`ntfy` on the NAS), stopping each
  within its own 30s grace period, then refuses to go further while any container
  still mounts `{{ nas_docker_root }}/ntfy`, then removes that directory and
  `{{ platform_runtime_dir }}/services/ntfy`. Under `--check` it reports each
  removal and changes nothing; on a host without the residue it is a no-op.
- `roles/production_auto_deploy` removes `ntfy.curl` and `roles/image_prune`
  removes `ntfy-prune.curl` from the deploy account's
  `~/.config/nas-platform`. Both run in the install play, the last one each
  poller tick runs.

If `host_prep` refuses because a container still mounts the directory, that
container was not started by the ntfy Compose project; the message names it.
Stop and remove it, and the next tick finishes the job.
