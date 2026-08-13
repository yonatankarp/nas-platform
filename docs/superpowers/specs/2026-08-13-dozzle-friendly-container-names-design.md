# Dozzle Friendly Container Names Design

## Goal

Show every container in Dozzle using its exact Docker Compose service key, such as `paperless-gotenberg`, instead of the sandbox-prefixed physical container name, such as `nas-platform-mac-czajo0-paperless-gotenberg`.

## Design

The physical Docker container names remain unchanged. In particular, Mac proof containers retain their per-sandbox project prefix so concurrent and retained proof environments cannot collide.

Every service visible to Dozzle receives the label:

```yaml
dev.dozzle.name: paperless-gotenberg
```

For each service, the label value must exactly equal that service's key in the Compose `services` mapping. Existing `dev.dozzle.group` labels remain unchanged, so stacks retain their current grouping while individual entries receive stable, concise names. The label is part of the shared service definition wherever practical so NAS, Mac, integration, and adoption deployments present the same names.

Dozzle v10.7.1 supports `dev.dozzle.name` as the official display-name override. No Dozzle database, browser state, or physical Docker name rewrite is required.

## Reconciliation

Compose label changes require affected containers to be recreated. The normal deployment workflow performs that reconciliation. Dozzle then discovers the labels through Docker metadata and displays the aliases without further user configuration.

## Validation

Static policy tests render every supported effective Compose configuration and require each Dozzle-visible service to have exactly one `dev.dozzle.name` label whose value equals its Compose service key. They also continue to enforce the existing group labels and reject duplicate or malformed display-name labels.

Runtime verification inspects deployed container metadata and confirms the effective display-name labels. The Mac proof verifies the friendly aliases while retaining prefixed physical names, proving both presentation and sandbox isolation.

## Non-goals

- Removing Mac sandbox prefixes from physical container names.
- Changing existing Dozzle group names or grouping behavior.
- Adding manual or browser-local Dozzle configuration.
- Renaming Compose service keys.
