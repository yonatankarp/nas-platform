# CI performance history

The evidence behind the CI performance rules in `CLAUDE.md` (section *CI
performance: the rules*): dated occurrences, run IDs, per-check second counts
and the measurement narratives each rule was drawn from. It was moved here
unchanged apart from its heading levels and a few references that pointed at
the rest of `CLAUDE.md` (#652). The rules live there; this is the record of why,
and every figure below is a reading on the date and run it names, not a
statement about the tree today.

## The `static` budget, and the one way it keeps being blown

`static` is expected to finish in 10–15 minutes and has blown that budget four
times. Every time the cause was the same shape, so recognise it rather than
rediscovering it:

> **A check that spawns a subprocess per case, serially, becomes the floor for
> the whole job.** `tests/validate-policy.sh` packs its checks into a pool of
> `nproc` workers, and a GitHub `ubuntu-latest` runner has four. A pool cannot
> finish faster than its longest single item, so one check that grows a case
> list grows `static` no matter how well the other hundred are packed.

The occurrences, and what actually fixed each:

- **2026-08-27** — the media acquisition reconciliation contract landed and
  `static` was cancelled at 45 minutes. Raising the budget (`65adc2f`) unblocked
  CI and fixed nothing.
- **2026-08-28** — splitting that contract into three files (`2460800`) took
  `static` from 88 to 32 minutes "and no further"; sizing the pool *down* to
  leave room made it worse. Only moving it to its own job (`fc52071`), then one
  runner per file (`b0a0152`), removed it from the gate's floor.
- **2026-08-30** — `static` was ~26 minutes, of which the `Check policy
  properties` step was 24m32s (measured from the run's step timings, not
  estimated). The dominant check was `tests/policy_manifest_test.rb`: it plants a
  defect in a throwaway copy of the repository and runs the whole eight-script
  policy set against it, once per mutation, and over 150 mutations run the full
  set. One case cost 5.5s locally, of which 3.96s was `tests/policy_integration_test.rb`
  alone — which itself spends most of its time booting Ansible twice to render
  role defaults. Fixed by running the policy set concurrently inside `run_policy`
  (5.5s → 3.45s per case) and moving the harness to its own `mutation` job. The
  gate went from 1472s to **630s wall, 2122s of check time across 107 checks on
  four workers**, with the slowest single check at 307s.
- **2026-09-03** — `static` was 20m29s and the gate printed 1086s wall, 3955s of
  check time across 147 checks. Read against the entry above that looks like the
  total-work state — 3955s over four workers is a 989s floor, the run took 1086s,
  and the slowest single check was 414s, well under it — and #319 read it that
  way. It was wrong, and the arithmetic is why: **the seconds the gate records
  for a check are its wall time while three other checks are running**, so
  contention inflates the total and the floor derived from that total in the same
  breath. Those numbers cannot tell a hundred slow checks apart from one check
  waiting. Varying the pool width can: `tests/seerr_contract_test.rb --self-test`
  took 554s at one case worker and 368s at four, eight and sixteen, while the
  same file without `--self-test` took 10s. Two of its planted regressions drop a
  `${VAR:?}` requirement from `tests/contracts/seerr.sh`, so the wrapper stops
  refusing, execs the runtime half against a port nothing is listening on, and
  spends `READY_TIMEOUT_SECONDS` there — 180 of them, twice.
  `tests/trailarr_contract_test.rb --self-test` was the same shape at 120. Fixed
  by making that budget an environment input, which is how those programs already
  take every other input, and giving the run-mode environment rows ten seconds,
  because every invocation in that helper must end in a refusal: 368s → 26s and
  247s → 27s, both still detecting all 33 planted regressions. The rest of the
  ten slowest were genuinely subprocess-per-case and went through the worker pool
  the paragraph below prescribes, sharing one `tests/case_pool_support.rb` rather
  than adding eight more copies of it — measured alone on a 12-core Mac: media
  managed users 159s → 46s, contract structure mutations 231s → 42s, Dozzle
  quality 141s → 32s, Audiobookshelf initial scan 81s → 15s, database managed
  users 70s → 17s. On that Mac at `POLICY_JOBS=4` the gate went from **922s wall,
  3134s of check time** to **492s wall, 1922s of check time** — both over the same
  148 checks, measured an hour apart before `deployment_lock_probe_test.py` and
  `deployment_lock_refusal_test.sh` landed, so a run today prints 164 and is not
  comparable check-for-check — and no converted check is in its slowest ten any
  more.
- **2026-09-07** — the gate's largest wait and its hard floor, taken together
  (#485, #488), after #486's rebalance of the same shards won nothing measurable.
  Both were found in the first uncontended per-check table this repository has
  had, and both lower the gate's *total*, which no partition can do.
  `beszel_contract_test.rb` and its `--self-test` cost ~209s of check time
  between them, of which ~171s was one hardcoded literal: `beszel-runtime.rb`
  polled persisted telemetry for 90 seconds, and exactly one row per deadline
  reaches it and can never satisfy it — a fixture serving `system_stats: []`, so
  the record stays nil and the poll runs its deadline out at 3 seconds a sleep.
  The 403/404 rows raise instead, which is why they were always cheap. Both
  budgets became `PLATFORM_BESZEL_*` environment inputs defaulted to the
  deployment's own numbers, the #319 shape: 99.6s → 19.6s and 101.5s → 31.8s.
  `config_managed_users_test.rb --self-test` was the floor at 241-305s on CI and
  87.6s alone. Its issue scoped the fix to the mutation section, which is worth
  only 17s of that 87.6s: the manifest registers the `--self-test` line, and that
  invocation runs the whole main body first, so the check's cost is ~45 serial
  Ansible fixture runs and not the mutations. Converting all of it through
  `tests/case_pool_support.rb` gave 87.6s → 19.0s at eight workers and 27.6s at
  the four a runner has.

Three things that generalise, the first of which replaces the width sweep the
fourth occurrence prescribed:

- **`time`'s user+sys column separates a wait from work in one pair of runs.**
  Sleep consumes no CPU and contention does not change that, so a low ratio of
  CPU to elapsed names a wait however loaded the machine was. The beszel pair was
  14.5s of CPU in 99.6s elapsed and 19.1s in 101.5s before the fix, and 13.9s in
  19.6s and 18.5s in 31.8s after it: the same work, the sleep gone. A width sweep
  says the same thing in six runs and is confounded by a check's own pool cap.
  The converse identifies work just as well — the managed-users conversion took
  CPU *up*, 76.1s to 107.2s, because more of it now runs at once.
- **A pooled case that assigns a name the script already carries shares one
  binding across every thread.** Ruby resolves an already-declared local outward
  rather than making a fresh one, and an `if` body opens no scope, so four cases
  writing their subprocess result into a script-level `status` were writing and
  reading one variable. The loss is silent, not loud: every mutant those cases
  run is supposed to fail, so a sibling's failing status reads as this case's own
  detection and a mutation that stopped biting is still reported as detected.
  Declaring block-locals in the parameter list (`do |item, failures; status|`)
  makes the class impossible rather than avoided. An AST dump of the script's
  local table catches a case that *adds* a name; it cannot catch one that reuses
  a name already there, which needs the other question asked — for each case, is
  every name it assigns declared somewhere on the path from the case down to that
  assignment. Position, not set membership: a nested block's declarations shadow
  only inside that block, so a rule that unions every nested scope's table lets a
  case write outward to any name a nested block happens to take as a parameter.
  That is not hypothetical — it was this checker's second defect, and it masked
  exactly `status`, `output` and `_tmp`, the names of the bug above.
- **Show an AST checker a real defect before trusting it.** The analyzer written
  to answer that second question — `tests/case_pool_locals_test.rb` — passed the
  known-buggy revision on its first attempt, carrying two mistakes at once:
  inside a block Ruby emits `DASGN`, not `LASGN`, and a multiple assignment's
  targets hang off the `MASGN`'s second child. Running it against the commit
  whose bug is known is what makes its clean report mean anything. Only the first
  of those is observable in the shipped checker, and its self-test says so rather
  than claiming both: the second was planted back in and changed no verdict,
  because the subtree walk special-cases nothing and finds those targets anyway.
  A self-test that claims more coverage than a planted defect demonstrates is the
  same vacuous pass in miniature.

The fourth occurrence's `POLICY_JOBS=4` figures are still the useful baseline,
read with the caveat that occurrence paid for: the totals are sums of contended
wall times, so they cannot separate a gate bound by its **total** work from a
gate waiting on **one** item. Ask a suspect check's CPU column first, per the
occurrence above — it costs two runs. Vary the width when you need to confirm it
— `POLICY_JOBS` for the gate's own pool and `CASE_POOL_WORKERS` for a check's
— and a cost that does not move when the width does is a wait, not work. Each
pooled check used to resolve a `*_CASE_WORKERS` of its own; #637 retired those
along with the fourteen private pools that read them, so there is one knob. There is nothing to parallelise in a wait: find the
timeout and let the harness shorten it. For the
work half, run the cases through a worker pool — `in_parallel_cases` in
`tests/case_pool_support.rb` is the one copy, and its comment records why the
worker count must never exceed the core count. The pattern started in
`tests/media_acquisition_reconciliation_support.rb`; the checks converted for
#319 shared it, `tests/config_managed_users_test.rb` joined in #488, and #637
moved the last fourteen -- so a change to the pool is now one change rather than
fifteen. That mattered twice: #514's fix and `POLICY_JOBS=1` had both reached
only the shared copy.

Two consequences worth keeping:

- **The gate reports its own slowest checks.** `tests/validate-policy.sh` prints
  its wall time, its total check time and its ten slowest checks on every run,
  pass or fail. Read that first: the first three fixes above began by timing the
  checks by hand, because the gate printed nothing about where its time went, and
  the fourth began by reading that report and then varying the pool width to find
  out which kind of cost it was naming. `POLICY_JOBS=1` serialises the pool when
  a failure only appears under load, and reaches into `case_pool_support.rb` so
  the converted checks serialise with it.
- **Extraction is the fix when one check is the floor; sharding is the fix when
  nothing is.** Once a check is the floor, it moves to its own job so it gets a
  runner's four cores to itself. That costs four files kept in agreement: the
  manifest in `tests/validate-policy.sh`, `tests/policy_ci_test.rb` (which must
  assert both that the gate no longer runs it *and* that CI still does — a check
  in neither place is a guard that silently stopped running),
  `tests/ci/workflow_test.rb`, and the `needs` and `validate_results.rb`
  arguments of the `validate` job. Which of the two fixes applies is a
  measurement, not a preference, and the fifth occurrence below is the one where
  the reflex was wrong.

## The fifth occurrence, where extraction was the wrong reflex

**2026-09-07** — `static` was at or over the ceiling on four of five runs
(16m52s, 15m39s, 19m30s, 18m01s against one 11m48s), and none of the day's merges
had added work. The distinguishing measurement is that **the slowdown was uniform
across unrelated checks**: fast run against slow run, the slowest ten went
247→333, 160→195, 152→208, 125→168, 114→191. No check had gained work, so there
was no floor to extract — extracting one would have moved a single check to its
own runner and left the other 154 exactly as slow. And the pool had no slack to
tune: 2342s of check time on four workers is a 585s floor, and it finished in
611s, 4.4% overhead. **A pool at 96% efficiency is work-bound**, so the only
levers were fewer checks or more cores.

Fixed with more cores: `static` is a matrix of three shards, each a runner with
its own four workers running part of the manifest. Three is where it stops
paying, and the reason is a floor rather than a name: no shard finishes faster
than its own slowest check however finely the rest is divided, and the slowest
check runs about 290–325s on a runner, so a fourth shard buys nothing. **Do not
re-attach that claim to a check's name.** It was written naming
`config_managed_users_test.rb --self-test` at 247s, then 305s, and #488 converted
that check to 78–113s four hundred lines earlier in `CLAUDE.md`, where this
record then lived, while the sentence
went on quoting it (#517). Today's floor is `immich_release_helper_test.rb` and
it will move again; the number is what the argument rests on, and the gate's own
report is where to read it.

That floor is also the ceiling on rebalancing, which is a different quantity from
the floor and moves on its own. #484 measured a perfect three-way split as worth
about 90s against a worst observed shard wall of 394s and declined to collect it.
By #517 the worst leg was a median 436s across four `main` runs, the shards were
53/54/57 checks carrying a 2.2x spread of work, and the gate's two slowest checks
were in the same shard — so the same split was worth about 110s, twice the 59s
of run-to-run range and five times its standard deviation, and it was collected.
The lesson is that a partition balancing *count* drifts as checks are added and
made faster, because nothing in it balances *cost*; expect to re-measure rather
than to trust the last verdict.

**The guard is the point, and it was written before the partition.** Sharding is
an unusually efficient way to manufacture the defect this repository keeps
closing: drop a line from the partition and it runs nowhere, the gate goes green,
and it goes green *faster* than before. So the manifest is partitioned as three
literal heredocs in `tests/validate-policy.sh`, restated as three literal lists
in `tests/gate_manifest_coverage_test.rb`, and that file asserts their union is
the whole manifest in both directions, that no check is claimed twice, and a
floor under each shard — a stated number, because a shard that should hold fifty
checks and holds one passes every non-emptiness test there is. The runner refuses
an undeclared shard identifier and refuses an empty one, both proved in
`tests/policy_runner_test.sh`; `tests/ci/workflow_test.rb` derives the expected
matrix from the manifest, so a matrix short of the partition fails rather than
silently dropping a third of the gate. `tests/validate-policy.sh` with no
argument still runs everything, which is what to run locally, and adding a check
now means one shard of the manifest and the matching shard of the declaration.

Rebalancing the partition as checks change is a manual act, informed by the
gate's own slowest-checks report. The current split was drawn by #517 against
four post-merge `main` runs, and those figures are recorded in
`tests/gate_manifest_coverage_test.rb` beside the lists they justify. It
balances cost rather than count, which is why the shards hold uneven numbers of
checks. Read that count off `ruby tests/gate_manifest_coverage_test.rb`'s own
summary line, which prints it; **this sentence deliberately no longer states
it**, and #652 is why. It was 53/53/61 over 167 when #517 drew the split, and
the restatement that used to follow that figure went on claiming 51/52/61 long
after the split had moved, then went stale three times more inside #548 alone -- once within
one pull request of being corrected, again in the pull request that corrected
it, and a third time when #547's Vaultwarden checks merged in beside #548's
AdGuard ones without either branch being able to see the other's additions.
Nothing in this repository compares a count in prose against the lists it
describes, in any of the three places that stated it, so #652 deleted all three
rather than correcting them once more. Three things
constrain a future rebalance, all three stated beside the lists: a check's
recorded seconds are its wall time at that shard's load rather
than work that can be carried elsewhere, so an arithmetic projection from that
report overshoots; each shard's leg is a *different runner*, so the three columns
of one run are three machines and only a shard's share of its own run's total
compares across them; and **waits must be spread**, because a waiting check holds
a worker slot without consuming the CPU the other three compete for, so two long
waits in one shard halve its effective pool. #484 carries the isolated per-check
table that separates work from wait, measured 2026-09-07; #517 adds that
contention only pushes the CPU-to-elapsed ratio down, so a high ratio proves work
whatever the load while a low one on a busy machine is a lower bound and not a
verdict. One run also cannot confirm a rebalance: shard-level runner variance is
around 30%, so read two or three and ask whether the *worst* leg fell.

The job wall exceeds the gate wall the report prints, so budget against the
gate's own figure rather than the job's. That residual used to be stated here as
122 to 154 seconds attributed to "checkout, tooling and collection install", and
both halves were wrong (#653). The attribution was incomplete: eight steps sat
outside the gate, and the six of them that did not vary by shard — lint, the
three syntax checks, and three single-command checks now in the manifest — cost
148, 142 and 111 seconds on the three legs of push run `35038260896`, all of it
inside that residual. And the range does not
hold once they are removed, because what is left is dominated by one step whose
cost swings: `Install Ansible tooling` ran 136/201/193s on `35038260896` and
38/35/44s on `35041492555`, which moved the residual from 139/205/198s to
45/41/52s over the same three legs. **Read it off the run rather than from here**
— job wall minus the gate's printed wall, per shard — and expect the answer to
track that install rather than a fixed number. One run each, a push against a
pull request, so treat both as observations and not as a range.

## The suites carry no such budget, and their clock is mostly queue

Everything above is about `static`. **The `suites` matrix has never had a stated
budget** and carries `timeout-minutes: 90`; reading the 10–15 minutes at it is a
category error that has already been made once. What it does have is a shape
worth knowing before optimising anything, measured on the nightly sweep
`34454075921` of 2026-09-10 — 29 jobs, 246 runner-minutes, 45.2 minutes of run
wall:

- **A lane's elapsed time is mostly waiting to start.** Every suite leg queued
  12–18 minutes before it ran; `smoke` was 16.5 queued against 19.4 running and
  `idempotence-check` 12.4 against 20.6. Even `changes`, first in the run with
  nothing ahead of it, queued 4.7 minutes, which only happens when the account is
  already saturated — that morning the nightly was *created* at 08:14:15 and the
  merge run for #542 at 08:14:00. Peak concurrency across the overlapping runs
  was exactly 20. So quote a lane as queue and run separately, or the number
  names GitHub's scheduler rather than anything in this repository.
- **The nightly is the only unconditional sweep.** A push to `main` classifies
  the merge it landed, so it is routed like any pull request: the #544 merge ran
  four suite legs. `--full` comes from `schedule` and `workflow_dispatch` only.
  Deleting the nightly would leave nothing running the whole matrix against a
  tree no routing decision chose.
- **A `cron` is a lower bound on when the sweep lands, not a time.** GitHub has
  *created* this workflow's scheduled runs 4h21m to 5h22m after the cron on each
  of the last ten days, and 12h06m once (2026-08-28). At `23 3 * * *` that was
  07:44–08:45 UTC every day, squarely in the merge window; the cron is now
  `47 17 * * *`, which lands it at 22:08–23:09 under those delays, at 05:47 under
  the worst one observed, and at 17:47 if the delay ever disappears. Choosing an
  hour whose whole plausible fire window misses 07:00–10:00 UTC is the property;
  the hour itself is not. Check it rather than trusting it:
  `gh run list --workflow=ci.yml --event=schedule --json createdAt`.

Two costs were found inside a lane and both are fixed; the shape of each is the
part worth keeping.

- **The image pre-pull was serial.** `prepull_images` in `tests/integration.sh`
  ran one `docker pull` at a time: 272 seconds of `smoke`'s 1151 and 270 of
  `idempotence-check`'s 1222 — 33 images each, about 22% of the two longest
  lanes — and 18.5 runner-minutes across the run. It now fetches
  `image_pull_width` at once, defaulting to four and bounded like every other
  budget beside it, through `INTEGRATION_IMAGE_PULL_WIDTH`. Concurrency costs one
  property: under a rate limit the serial loop stopped at the refusing image, and
  a batch can now overshoot it by `image_pull_width - 1` pulls.

  **Four wide bought 26%, not 75%, and a wider one would buy less.** Measured on
  run `34467333883`: the same fourteen lanes went from 1112 seconds of pre-pull to
  828, and smoke's two longest-lane siblings from 272 and 270 to 200 and 192. The
  concurrency is not the part that fell short — smoke's completion timestamps show
  eight clean bursts of four — the arithmetic is. A runner pulls at a fixed network
  throughput, so overlapping pulls recovers per-request latency and leaves the
  bytes where they were. This is the shape to expect from any I/O-bound fan-out
  here, and it is why the width is capped at eight rather than left open.
  `tests/integration_suite_test.sh` asserts the width in both directions through a
  rendezvous in its `docker` stub rather than a clock, because a peak of four
  proves nothing unless a width of one is still observable as one.
- **`toolchain` no longer waits for `changes`.** Every lane's start is that job's
  finish, and it was spending 2.6 minutes of eighteen lanes' time to order a
  registry probe behind a classification: `changes` finished at 4.8 minutes, the
  toolchain job started at 7.4, and its publish step took **0 seconds** because
  the tag is a digest over the harness's own pins and was already published. The
  `suites != '[]'` term went with the edge, which is the whole cost: a run that
  dispatches no suite now probes too, and that probe is the same 0 seconds unless
  the pins changed — and a pin change routes to the suites anyway.

## The untagged idempotence lane is sharded; the tagged one never needed to be

`idempotence-check` converges the whole site, re-converges it and runs it under
`--check --diff`, so it costs three full passes and is the critical path of any
run that dispatches it untagged. Measured on run `34471042365`, which queued for
one second and so is nearly pure run time: **32.3 minutes**, against a
next-longest job of 16.5 and a run wall of 32.5. The lane *was* the run.

Its 1939 seconds divide as 189 setup and image pre-pull, 850 phase 1, 548 phase 2
and 348 phase 3. Read that before proposing a target: **deleting phases 2 and 3
outright still leaves about 17 minutes**, and a *routed* run of the same lane —
one service, 1289 task-results against 4280 — measured 13.05 minutes on run
`34464098157`. Both bound it from below, and 10 minutes is under both. The lane
is task-count-bound rather than hot-spot-bound: phase 3 does no container work at
all and still costs 324ms per task-result, which is the same slope phase 1 pays.
There is nothing to extract.

So the fix is the `static` one — more runners — with the difference that the
partition is over *site.yml tags* rather than over a check list, and that only
the untagged form is sharded:

- **A routed run was never the problem.** It already narrows to the changed
  service and lands at 8–14 minutes. It still dispatches the single
  `idempotence-check` and is untouched.
- **An unmapped path falls open to the shards.** That is the case that hurt: on
  2026-09-10, 8 of 29 `idempotence-check` jobs ran untagged, and every one of
  them was 32–37 minutes. Both sampled causes were legitimate rather than routing
  misses — one pull request changed `tests/integration.sh` and
  `tests/integration_controller.sh`, which are the harness every lane runs, and
  the other added a service and touched `site.yml`, `services/manifest.yml` and
  the vault schema. There was no one-line route to add. Four of the eight were
  pushes to `main`, which classify the merge they landed and inherit the cause.
- **`--full` keeps the single unsharded pass.** The nightly and
  `workflow_dispatch` are where nothing is waiting on the answer, and they are
  now the only place the site is proved idempotent *as a whole*. A role in one
  shard interfering with a role in another is invisible to every shard. That is
  the property the decomposition spends, and it is why it is spent where a
  35-minute job costs nobody anything.

`--full` is therefore no longer literally every lane, and that is the one
exception to it: the two forms cover the same ground by different routes, so
running both would converge the site six times to learn what three converges
already said. `everything(selection, sharded:)` in `tests/ci/classify_changes.rb`
is where the fork lives, and it is at the two `return` sites rather than threaded
through as a mode.

**The guard came before the partition, for the reason the static shards record.**
Sharding manufactures the defect this repository keeps closing: drop a tag and
nothing converges it, every shard passes, and the gate goes green *faster*.
`tests/idempotence_shard_partition_test.rb` derives the tag universe from
`site.yml`'s own roles and post_tasks and fails on any tag no shard converges, in
both directions, with a stated shard count under it. It is **derived** rather
than restated on purpose: adding a service already touches the number of files
`docs/adding-a-service.md` counts, and one more list would be the one nobody
edits. What it deliberately does *not*
assert is exclusivity — `arr` appears in more than one shard because seerr reads
it and jellyfin, so a prerequisite converges wherever it is needed. Duplication
costs time; omission costs coverage, and only one of those is silent. What it
also does not check is that a rebalance keeps a service *with* its prerequisites;
that failure is loud at runtime rather than silent, so it was left, and
`suites.conf`'s own service rows are already the dependency declaration a future
guard would read.

That guard's own `--self-test` is worth reading before writing another one. Its
first three plants were bare substring edits — `",immich\n"`, `",komga\n"`,
`"ntfy,beszel"` — and every one landed on the *service* row of the same name,
which appears earlier in `suites.conf`, so `sub` mangled a row the checker does
not read and the self-test reported three defects undetected. A checker that
passes its own plants has proved nothing until the plants are shown to bite.

**`smoke` binds the fall-open wall, and that caps what this change can buy.** A
fall-open selection turns `foundation` on, which empties `selected_tags`, which
sends the smoke leg down the untagged branch of the workflow's `case "$SUITE"` —
so smoke converges the whole site: 16.5 minutes on `34471042365` and **19.1 on
`34514486089`**, where it was the longest-running job in the run and every shard
beat it.
The wall of a fall-open run is therefore `max(slowest shard, 16.5)`, not the
shard wall. Smoke is a strict prefix of this lane — same workflow branch, same
arguments, `exit 0` at the line where phase 2 begins — and its routing is a
subset, so it proves nothing this lane does not. Reclaiming that leg is the next
move, and it costs edits to `suites.conf`, `classify_changes.rb`,
`tests/ci/workflow_test.rb`, `tests/policy_ci_test.rb` and the lane roster in
`CLAUDE.md`.

**Measured on run `34514486089`, the first that dispatched them, when the split
was five shards rather than today's.** Read the figures below as that run and
not as the partition in the tree, which `tests/ci/suites.conf` holds and
`tests/idempotence_shard_partition_test.rb` counts. Those five ran 14.1, 9.9,
9.7, 9.9 and 7.5 minutes, so the
projected 14–16 held at the top and was pessimistic everywhere else. Each
converged real work and then reported `changed=0`: phase 1 changed 43, 37, 19,
28 and 30 things against phase-1 task counts of 697, 547, 375, 521 and 500. The
run wall fell from 32.5 minutes to **24.1**.

Two projections in the paragraph this replaces were wrong, and the shape of the
error is worth more than the numbers. The repeated prerequisites were estimated
from the corrupted per-role table at roughly three times what that run then
measured, so the asymptote was nearer 6 minutes than the 10 claimed and more
shards would still buy something. A sixth was cut out of shard 1 afterwards, for
the reason `suites.conf` records beside the rows. (The runs compared were
different trees, one before AdGuard and one after, so that was a magnitude and
not a figure.) The estimate came from a table this document
already records as unreliable, which is precisely the trap: a projection built
on data known to be corrupt reads exactly like a measurement once it is written
down.

**Queue is now a visible term.** On that same run `idempotence-1` finished last
at 18:50:01 despite running only 14.1 minutes, because it did not start until
18:35:54 — the matrix had grown by four legs against an account that peaked at
exactly 20 concurrent jobs, so some of the shard win converts into waiting
rather than into wall. Every shard added since pays that again.

**The shards are numbered rather than named, and the split balances estimated
cost.** The three heavyweights by the phase-1 role table — paperless at 120.5s,
immich at 104.8 and jellyfin at 102.8 — have to land in three different shards,
and no honest category groups them that way: the first split put paperless,
nextcloud and immich together as "documents" at roughly 229s against 58 for the
lightest, a 3.9x spread in the one direction that sets the wall. Numbering makes
a rebalance free, which matters here because a named partition that stops
matching its names is the same stale claim `CLAUDE.md` has had to correct twice
already — and the partition has been rebalanced since, which is the reason the
spread it achieves is not quoted here.

**The split is provisional and its weights are estimates rather than measurements.** The only
per-role timings available are corrupted: with `display_skipped_hosts = False`
the default callback prints no banner for a fully skipped task, so every visible
gap in the log absorbs the skips after it, and a task that reads 26 seconds can
be a loop measured at 1.5ms an item. Rebalance from the first sharded run's own
numbers the way #517 rebalanced the static shards, and read the caveats there
about contended wall times first. `ANSIBLE_DISPLAY_SKIPPED_HOSTS=true` passed
into the harness's `docker run` is the one-line way to make the log self-timing
when somebody needs real numbers; it is not set today.

## A guard that was green while proving 6% of what it claimed

`tests/integration_controller.sh` read `[ -n $INTEGRATION_TAGS ]` unquoted. On an
empty value that is `[ -n ]` — POSIX's one-argument `test`, true because the
string `-n` is non-empty (SC2070) — so the *untagged* path took the *tagged*
branch and ran `ansible-playbook --tags ""`, which selects only the `always`
pre_tasks. On nightly run `34454075921` phase 1 reported `ok=1495 changed=115`
and phases 2 and 3 reported `ok=88` each, then printed `IDEMPOTENT: second run
changed nothing` and `CHECK MODE OK`. The harness's other two promises were being
proved over 88 of 1495 tasks on every nightly and every `--full` push to `main`,
while the same lane under narrow routing was correct.

Three things about it generalise:

- **The bug was known and its consequence was not.** `tests/integration_controller_execution_test.sh`
  named the SC2070, pinned the behaviour deliberately rather than the correct one,
  and said it was waiting for the fix; the shellcheck exclusion listed the code.
  Nothing anywhere connected that to what the nightly was actually asserting. A
  defect with an owner and a comment is not a defect with a measurement.
- **Correct is slower.** A phase 2 that re-converges all 1495 tasks costs
  550–720 seconds and phase 3 another 420–580, so `idempotence-check` on a full
  run goes from ~20 minutes to roughly 35–45 — measured at 33.4 on run
  `34467333883`, whose phases now report `ok=1556` and `ok=1075` against the 88
  each of them reported before. The `suites` budget went from 60 to
  90 for it, because a lane killed at its ceiling would read as the fix
  regressing rather than as the guard working, and because the pre-pull's own
  retry ladder can add another five minutes on a rate-limited image. Any future
  reading of "the suites are slow" has to start after that, not before it.
- **`perform_initial_converge` was accidentally right, which is not the same as
  right.** Its `[ -z $INTEGRATION_TAGS ]` degenerated identically and happened to
  land on the branch that was already correct, so no plant can prove its quoting;
  the case comment says so rather than implying coverage a plant does not give.
