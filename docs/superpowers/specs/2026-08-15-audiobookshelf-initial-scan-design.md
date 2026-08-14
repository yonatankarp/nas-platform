# Audiobookshelf Initial Scan Design

## Problem

The Audiobookshelf role creates and verifies the managed `Audiobooks` library at
`/audiobooks`, but it never requests an initial scan. The runtime contract hides
this gap by issuing `POST /api/libraries/<id>/scan` itself. A clean production
deployment can therefore finish successfully while the library remains empty.

## Design

The role will request a scan after creating the managed library and after a
repair that changes its folder binding. It will not scan on every unchanged
convergence. After requesting a scan, the role will poll Audiobookshelf's task
and library-item APIs until the scan has finished. Completion means that no
unfinished `library-scan` task remains for the managed library; an empty source
directory remains a valid result.

The wait will be bounded and failures will report only safe diagnostics: the
managed library ID, whether a scan is active, and the observed item count. No
credentials, media names, or metadata will appear in failure output.

## Verification

The Audiobookshelf integration fixture will exist before deployment. The
contract's unconditional scan request and retry scans will be removed, so the
fixture can be discovered only if the role initiated the scan. Static tests
will require the scan trigger, bounded wait, and create/folder-repair guards.
Existing idempotence, playback, persistence, drift, and check-mode proofs remain
in place.
