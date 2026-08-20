# Renovate Native Auto-Merge Design

## Goal

Automatically rebase-merge safe Renovate pull requests after the repository's
required CI check passes. Use Renovate's built-in GitHub-native auto-merge
support, without a custom workflow or additional credentials, and keep major
or manually coupled upgrades under human control.

## Scope

Eligible Renovate update types are:

- `minor`
- `patch`
- `pin`
- `pinDigest`
- `digest`
- `lockFileMaintenance`

The following changes remain manual:

- major updates;
- Renovate configuration migrations;
- replacements and rollbacks;
- the existing Immich updates marked as requiring manual coupling;
- any update not explicitly matched by the auto-merge package rule.

## Architecture

Renovate owns both dependency classification and merge orchestration. A package
rule in `renovate.json` sets `automerge` to `true` only for eligible update
types. Renovate creates a pull request and enables GitHub's native auto-merge
for it.

GitHub owns the final merge decision. The existing `main` ruleset is changed
from disabled to active enforcement and continues to require the aggregate
`validate` status check. GitHub completes the merge only after this required
check and the ruleset's other requirements are satisfied.

No change is made to `yonatankarp/github-actions`. No custom merge workflow,
PAT, repository secret, eligibility label, or `GITHUB_TOKEN` write permission
is needed.

## Renovate Configuration

The root configuration retains `"automerge": false`, making manual handling the
default. The following root settings make the intended behavior explicit:

```json
{
  "automerge": false,
  "automergeType": "pr",
  "platformAutomerge": true,
  "automergeStrategy": "rebase",
  "rebaseWhen": "behind-base-branch"
}
```

A package rule opts in the eligible update types:

```json
{
  "description": "Automerge routine non-major updates after required checks pass.",
  "matchUpdateTypes": [
    "minor",
    "patch",
    "pin",
    "pinDigest",
    "digest",
    "lockFileMaintenance"
  ],
  "automerge": true
}
```

The existing Immich manual-coupling rule explicitly sets `"automerge": false`.
It appears after the general eligibility rule so the more specific safety policy
wins when both rules match. Its existing `needs-manual-coupling` label remains
as a visible explanation for maintainers.

Major updates, configuration migrations, replacements, and rollbacks do not
match the eligibility rule and therefore inherit the root `automerge: false`.

The existing `rebaseWhen: conflicted` setting changes to
`behind-base-branch`. The enforced ruleset requires strict, up-to-date status
checks, so an eligible Renovate branch must be rebased whenever `main` advances,
not only when Git reports a content conflict.

## CI and Merge Flow

The flow is:

1. Renovate opens or updates a pull request.
2. The existing pull-request CI runs and produces the aggregate `validate`
   result.
3. For an eligible update, Renovate asks GitHub to enable native rebase
   auto-merge.
4. The enforced `main` ruleset prevents the merge while `validate` is absent,
   pending, or failing.
5. GitHub rebase-merges the pull request after `validate` succeeds and all
   other merge requirements are met.

The repository already allows auto-merge. The only repository-setting change
is activating the existing `main` ruleset. That ruleset continues to:

- require the `validate` status check and require it to be up to date;
- require changes to arrive through a pull request;
- require review conversations to be resolved;
- require zero approving reviews;
- disallow branch deletion and non-fast-forward updates.

The required `validate` check is the authoritative CI gate. It already
summarizes the dynamically selected static and integration jobs, so individual
matrix jobs do not need to be added to the ruleset.

## Error Handling and Safety

- Auto-merge is opt-in by update type; unmatched updates remain manual.
- The specific Immich rule overrides the general rule and disables auto-merge.
- GitHub ruleset enforcement, rather than Renovate polling timing, prevents
  merging before CI succeeds.
- Renovate and GitHub perform the merge without introducing a repository PAT.
- There is no administrator bypass or direct-merge fallback.
- A conflict, failed check, or unresolved review conversation leaves the pull
  request open.
- Renovate rebases an eligible branch that falls behind `main`, allowing the
  strict required check to run against the current base.
- GitHub-native merging preserves normal post-merge event behavior for the
  existing `push` workflow.

## Verification

Static verification will cover:

- JSON syntax and Renovate schema validity;
- the exact eligible update-type list;
- explicit PR, platform-native, and rebase auto-merge settings;
- the Immich rule's later `automerge: false` override;
- the absence of a custom auto-merge workflow;
- active ruleset enforcement with `validate` as the required check.

End-to-end verification will use Renovate-generated pull requests:

- An eligible update must show auto-merge enabled and merge only after
  `validate` succeeds.
- A major update must remain open without auto-merge enabled.
- An Immich update must retain `needs-manual-coupling` and remain open without
  auto-merge enabled.
- A failed or pending `validate` check must prevent merging.

## Rollout

1. Update and validate `renovate.json`.
2. Enable enforcement for the existing `main` ruleset.
3. Let Renovate refresh its open pull requests on its next run.
4. Observe the next eligible and ineligible Renovate pull requests to confirm
   both paths.

The configuration change and ruleset activation must be coordinated. Enabling
Renovate auto-merge without an enforced required check could allow GitHub to
merge before CI finishes.
