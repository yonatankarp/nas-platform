# Phase One CI Portability Design

## Problem

PR #95 exposes two independent portability defects.

On Linux, bind mounts preserve numeric ownership. The integration controller
creates media directories as root, while Radarr, Sonarr, SABnzbd, and Unpackerr
run as `1000:100`. Ownerless mode-0755 library and acquisition directories are
therefore read-only to the applications. Radarr rejects `/data/media/Movies`
with `FolderWritableValidator`; Sonarr has the same defect for Series, and the
downloaders suite fails while converging its Arr prerequisite. Docker Desktop
remaps macOS bind ownership to the container identity, which hid the defect.

Separately, `roles/arr/files/configarr/config.yml` is an opaque Configarr
application payload containing valid `!secret` tags. Ansible lint discovers the
file as ordinary YAML and fails before linting the playbooks.

## Integration Writer Ownership

The central storage inventory will mark only paths that active or planned media
acquisition services must write. The exact writer set is Movies, Series, and
every `.acquisition` cache path under the Media and Books roots. These entries
remain free of `owner` and `group`, preserving the production NAS ownership
contract.

Host preparation will derive an integration-writer mode only when all of these
conditions hold:

- `platform_kind` is `nas`;
- `platform_compose_kind` is `integration`;
- `deployment_bundle_test_mode` is true; and
- `nas_media_root` ends in an exact six-character
  `nas-platform-integration.<id>/volume2` sandbox path.

When that mode is active, host preparation assigns only marked writer paths to
`nas_uid:nas_gid`, retaining their declared mode. Outside that boundary it uses
the existing ownership behavior unchanged. A failed sandbox-path assertion
stops before directory ownership changes.

After convergence, integration mode will inspect the marked paths and require
their numeric UID, GID, directory type, non-symlink identity, and mode to match
the application writer contract. Production declarations remain ownerless and
the production role never claims media ownership.

## Configarr Lint Boundary

`.ansible-lint` will exclude exactly
`roles/arr/files/configarr/config.yml`. It will not exclude `roles/arr/files/`
or relax the unskippable YAML load failure globally. This follows the existing
`services/` exclusion for opaque Compose payloads while preserving lint
coverage for every other Arr file.

The Configarr contract test remains responsible for the payload's application
schema and exact `!secret` references. The CI workflow policy test will require
the exact lint exclusion so it cannot disappear or broaden silently.

## Failure Behavior

An integration run with the writer mode enabled but an unexpected media-root
path fails before mutation. A production or Mac run never activates the
synthetic ownership path. A malformed or semantically incorrect Configarr
payload continues to fail its dedicated contract even though Ansible lint does
not parse that file.

## Verification

Test-first regressions will prove:

- the writer marker exists on exactly Movies, Series, and every acquisition
  cache path;
- marked production storage entries still omit `owner` and `group`;
- integration ownership is guarded by all four boundary conditions;
- post-convergence assertions require the application UID/GID and mode;
- the exact Configarr payload is excluded from Ansible lint while broad Arr
  exclusions are absent; and
- the Configarr contract still validates both `!secret` tags.

Focused policy tests, pinned `ansible-lint --strict`, the live Arr and downloader
integration suites, the full GitHub CI matrix, and branch integrity checks must
pass before the PR is considered deployable. No commit may contain a
`Co-Authored-By` trailer.
