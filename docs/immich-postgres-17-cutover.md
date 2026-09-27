# Immich PostgreSQL 14 to 17 cutover

This is the operator procedure for the pull request that moves the Immich
database image from the 14 line to the 17 line (#839). A PostgreSQL major is an
on-disk format change: the 17 image cannot open a 14 data directory, and nothing
converts one in place. The data moves as a dump and a restore. The dump is the
one Immich writes itself, and the restore is the one `roles/immich` already runs
for a fresh data directory.

The old data directory is moved aside, never deleted. It is the rollback, and
`immich/postgres` is `recovery: critical`.

Every command runs on the NAS as the deploy account unless it says otherwise.
The paths below are the production ones: `nas_docker_root` is `/volume1/Docker`,
and the Immich dumps are in `/volume2/Immich-backups/database`.

## What the repository does for you, and what it does not

- `services/immich/classify_restore.py` finds an empty data directory and
  existing originals, and selects the newest dump. It accepts a dump from an
  older major than the pinned image, but not from a newer one.
  `roles/immich/tasks/restore.yml` then loads that dump in one transaction,
  checks the restored rows and the source files, and starts the server.
- The same classifier refuses an existing data directory whose `PG_VERSION`
  names a different major than the pin (`postgres-major-mismatch`). The refusal
  comes before any Compose operation, so the running containers stay up.
- **That refusal needs the deploy account to be able to read `PG_VERSION`.**
  When it is denied, the classifier warns and proceeds instead. The converge
  then stops the application and starts the 17 image on the 14 directory.
  PostgreSQL refuses to start there and does not modify the files, but Immich is
  down, and no 14 container is left to take a fresh dump from. Prerequisite 4
  finds out which case you are in. The default order below does not depend on
  the answer.
- The poller tries each revision once. A failed revision is quarantined, not
  retried every tick. `nas-platform-deploy --retry-failed <full sha>` retries it
  once, after you fix the cause.

## Prerequisites (before the pull request merges)

1. **No leftover pgvecto.rs extension.** The 17 image does not ship
   pgvecto.rs. Immich writes its dump with `pg_dump --clean --if-exists`, so an
   installed `vectors` extension lands in the dump as `CREATE EXTENSION`, and
   the single-transaction restore aborts on it. The pinned Immich server no
   longer knows that extension, so it never drops a leftover one itself.

   ```sh
   docker exec immich_postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dx"'
   ```

   Only `vchord`, `vector`, `cube`, `earthdistance` and `plpgsql` should appear.
   If `vectors` is listed, drop it. Leave out `CASCADE`, so the drop fails
   loudly if anything still depends on it:

   ```sh
   docker exec immich_postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP EXTENSION vectors;"'
   ```

   Then take a new dump (Cutover step 1) before the rehearsal.

2. **Check the newest dump for the same thing:**

   ```sh
   newest=$(ls -t /volume2/Immich-backups/database | head -1); echo "$newest"
   gzip -dc "/volume2/Immich-backups/database/$newest" | grep -n 'CREATE EXTENSION'
   ```

   `vectors` must not appear.

3. **Rehearse the restore into a throwaway 17 container.** This pipe is the one
   in `roles/immich/tasks/restore.yml`, including its `search_path` rewrite.
   Nothing touches the live cluster. Take the image reference from the pull
   request's `services/immich/compose.yml` `database.image`, digest included.

   ```sh
   image='<database.image from the pull request>'
   newest=$(ls -t /volume2/Immich-backups/database | head -1)
   docker run -d --name immich-pg17-rehearsal -e POSTGRES_PASSWORD=rehearsal \
     -e POSTGRES_DB=immich -v /volume2/Immich-backups/database:/b:ro "$image"
   until docker exec immich-pg17-rehearsal pg_isready -U postgres -d immich; do
     docker inspect -f '{{.State.Running}}' immich-pg17-rehearsal | grep -q true || break
     sleep 2
   done
   time docker exec immich-pg17-rehearsal bash -o pipefail -ec "
     gzip -dc -- /b/$newest |
     sed \"s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g\" |
     psql -U postgres -d immich --single-transaction --set=ON_ERROR_STOP=on >/dev/null
     echo LOADED"
   docker exec immich-pg17-rehearsal psql -U postgres -d immich -c '\dx' \
     -c 'SELECT count(*) FROM asset;'
   docker rm -f immich-pg17-rehearsal
   ```

   It must print `LOADED`. The `\dx` output shows the VectorChord version the
   restored indexes were built with. The `time` figure is roughly how long step
   6 of the cutover will take. A failure here means the cutover would fail in
   the same way, so stop and fix it first.

4. **Can the deploy account read `PG_VERSION`?**

   ```sh
   cat /volume1/Docker/immich/postgres/PG_VERSION
   ```

   Write down the result. `14` means the mismatch guard is live. `Permission
   denied` means it is not, and the default order below is required rather
   than just preferred.

5. **Nothing else is queued.** Run `nas-platform-deploy --status` and check
   that it names no revision as `retrying`. Hold every other merge to `main`
   until the cutover is done: a revision still pinned to 14 that converges
   after step 4 would restore the dump into a fresh 14 cluster.

6. **Keep the `immich-server` pin fixed** from the dump through the cutover.
   The classifier requires the dump's `v<X.Y.Z>` to equal the pinned server.

## Cutover (default order: move the data aside, then merge)

Immich is down from step 2 until step 6 finishes. Uploads made between step 1
and step 2 are not in the dump, so keep that gap short.

1. In the Immich web UI, open Administration, then Jobs, then Database Backup,
   and run it. Wait for a new `immich-db-backup-<timestamp>-v<pin>-pg14.<minor>.sql.gz`
   to appear in `/volume2/Immich-backups/database`.
2. Stop the writers:

   ```sh
   docker stop immich_server immich_machine_learning
   ```

3. Confirm the newest file is the one step 1 wrote, and that nothing under the
   originals changed after it was written. The second command is the
   classifier's own `stale-newest-backup` rule (#900). It must print nothing;
   if it prints a directory, start Immich again, take the dump again, and
   repeat from step 2. A restore of a stale dump is what failed the first
   attempt at this cutover: the storage template had moved originals after
   the nightly dump.

   ```sh
   ls -lt /volume2/Immich-backups/database | head -3
   newest="/volume2/Immich-backups/database/$(ls -t /volume2/Immich-backups/database | head -1)"
   find /volume2/Immich/library /volume2/Immich/upload -type d -newer "$newest"
   ```

4. Stop the database and move its directory aside:

   ```sh
   docker stop immich_postgres
   mv /volume1/Docker/immich/postgres /volume1/Docker/immich/postgres.pg14-$(date +%Y%m%d)
   ```

5. Recreate the directory empty. `host_prep` would also create it, with the
   same mode:

   ```sh
   mkdir -m 0700 /volume1/Docker/immich/postgres
   ```

6. Merge the pull request, then converge the merge commit. Either wait for the
   poller, which runs it once CI has released that commit
   (`$HOME/.local/bin/nas-platform-deploy --status` shows progress), or
   converge it yourself now, under the poller's lock. The launcher runs from
   the controller checkout and its own `.venv` (#902), and prints that
   checkout's HEAD before it runs anything. Run it with `--check --diff` first,
   and go on only if that line names the merge commit:

   ```sh
   $HOME/.local/bin/nas-platform-deploy --converge -- -i inventory/local.yml site.yml --check --diff --ask-vault-pass
   $HOME/.local/bin/nas-platform-deploy --converge -- -i inventory/local.yml site.yml --ask-vault-pass
   ```

   The classifier sees an empty data directory and existing originals. The
   role restores the pg14 dump into 17, checks it, and starts the server.
   The restore task has no timeout of its own, so let it run.

7. Verify:
   - `nas-platform-deploy --verify` passes.
   - `docker exec immich_postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SHOW server_version; SELECT extname, extversion FROM pg_extension ORDER BY 1;"'`
     reports a 17 server and `vchord` at the version in the tag.
   - In the web UI, a smart search and a face search both return results.
     The server may log `Reindexing clip_index` and `Reindexing face_index` for
     a while on first start. That is expected.

8. Keep `postgres.pg14-<date>` until the new cluster has been in use for a
   while and a pg17 dump exists in `/volume2/Immich-backups/database`. Removing
   it is a separate decision, not part of this procedure.

### Alternative order (only when prerequisite 4 printed `14`)

Merge first. The converge of the merge commit refuses at classification with
`postgres-major-mismatch`, and Immich keeps running on 14. The poller
quarantines that revision. Then do cutover steps 1 to 5, and retry the
quarantined revision:

```sh
nas-platform-deploy --retry-failed <full sha of the merge commit>
```

This keeps Immich up while CI releases the merge commit. It depends entirely on
the guard reading `PG_VERSION`. If the account cannot read it, this order ends
in the crash loop described at the top.

## If the converge fails

- **At the restore.** The role writes `/volume1/Docker/immich/.restore-failed`,
  naming the stage, and refuses every later run (`previous-failed-restore`)
  until an operator clears it. Read the stage, then either fix the cause and
  retry, or roll back.
- **At classification.** The category it prints names the cause, for example
  `incompatible-newest-backup` when the newest dump's server version does not
  equal the pin. Nothing has been started, so fix the cause and retry.

## Rollback

Rollback returns to the moved-aside 14 directory. Anything written to the 17
cluster after the cutover is lost. That includes rows for photos uploaded
since; their original files stay on disk, but Immich no longer knows about
them.

1. Revert the pull request on `main`, and let nothing else merge in between.
2. Stop the stack and swap the directories back, **before** converging the
   revert. Otherwise the 14 pin meets a 17 directory, and the mismatch guard
   refuses, or the container crash-loops.

   ```sh
   docker stop immich_server immich_machine_learning immich_postgres
   mv /volume1/Docker/immich/postgres /volume1/Docker/immich/postgres.pg17-failed-$(date +%Y%m%d)
   mv /volume1/Docker/immich/postgres.pg14-<date> /volume1/Docker/immich/postgres
   ```

3. Converge the revert, through the poller or with `nas-platform-deploy
   --converge` as in cutover step 6. The classifier finds a 14 directory under
   a 14 pin and deploys it as `existing`.
4. If a `.restore-failed` marker is present, the converge refuses until you
   remove it. Remove it only once the directories have been swapped back.

## Assumptions this procedure has not proven

- VectorChord index definitions from a 0.4.3 dump load under the 1.x extension
  in the new image. Prerequisite 3 is the proof.
- How long the single-transaction restore and the reindex take on the real
  library. Prerequisite 3 measures the restore.
- Whether the deploy account can read `PG_VERSION`. Prerequisite 4 answers it.
- Immich's own CI runs only against its default 14 image. The 17 line is inside
  the ranges the pinned server enforces at startup, but upstream has not tested
  this combination.
