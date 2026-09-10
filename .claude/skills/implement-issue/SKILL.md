---
name: implement-issue
description: Use when asked to implement, pick up, or work on a GitHub issue in this repository, such as "implement #493", "do issue 500", or being handed an issue number with no further instruction. Also use when a change is meant to reach the NAS.
---

# Implementing an issue

## Overview

**Merging is deploying.** There is no staging environment and nothing reads the
diff: CodeRabbit's automatic review is off here, so a green check means no human
and no machine looked. `roles/production_auto_deploy` converges the newest
CI-released `main` every five minutes, which makes the merge the deploy button.

So the unit of work is not "the issue" but **the smallest change that is safe to
converge on the NAS**. Merge when that is true and CI is green.

Read the CLAUDE.md sections a diff touches before editing. This file does not
restate them, because a copy is a claim nothing bumps, which is what
`tests/docs_links_test.rb` refuses elsewhere in this repository.

**Not for:** a typo fix, or work the user is driving themselves edit by edit.

## One-way rules

Refuse these rather than weighing them.

1. **Never change anything by hand on the NAS.** A broken `main` is repaired by
   merging to `main`. The poller runs the plays from the candidate checkout, so a
   fix heals the host on its next tick with nobody touching it.
2. **Never make `site.yml`, `verify.yml` or `validate-vault.yml` depend on
   anything `install-production-auto-deploy.yml` installs.** A chunk sequence is
   the machine for reproducing #327, whose failure mode is every five-minute tick
   failing identically on a live host. See CLAUDE.md, *Deploying / reviewing*.
3. **Never split across pull requests a set the gate asserts in both
   directions:** the shard manifest and its declaration, `BASE_FIXTURE_PATHS`,
   the two pinned Ruby name lists, a service's file ledger. That yields one red
   gate, not two deployable states.
4. **One full gate run at a time**, across the whole task and every subagent.
5. **Never merge with an item from Stop and ask still open.**
6. **Never `git stash`.** The stash is one stack for the whole repository —
   worktrees isolate the working tree and the branch, not `refs/stash`. A `pop`
   in an isolated worktree takes whatever is on top, which may be a peer
   session's uncommitted work. It has already happened here; it only avoided
   data loss because the apply conflicted, so the entry survived. Commit
   instead, or copy to the scratchpad.
7. **Never delete a check because it stopped matching.** A diff that renames or
   re-nests a task breaks every assertion anchored to the old shape, and those
   failures look exactly like the check finding a defect. Re-anchor it. Deleting
   it is the fastest green there is.

## Procedure

1. **Read the issue.** `gh issue view <n> --comments`. An issue can be stale, so
   check its claims against the tree before designing around them.

2. **Isolate.** Own worktree, own branch off `origin/main`. Echo the working
   directory and pin its absolute path before the first edit, because a
   session's working directory is not stable for a whole task and an agent has
   written into the main checkout this way.

3. **Decide the chunks. The default is one.** Split only by one of these:
   - **Land dark, then flip.** The `<service>_deployment_enabled` idiom. The
     first pull request lands the whole stack converging nothing; the second
     flips the flag in inventory. Preferred, because it never fights the gate's
     atomicity. `roles/nextcloud/defaults/main.yml` records why the flag belongs
     inside the role rather than on the `site.yml` entry.
   - **Independent issues in sequence.** One pull request each.

   Chunks are strictly serial: branch the next one off `main` only after the
   previous one's push run is green. They are sequential by construction, so
   parallel chunk agents buy nothing and cross each other's messages.

4. **Implement in a subagent.** Fresh context, test-driven, committing as it
   goes. Commit before running any mutation self-test, because those revert the
   tree and take uncommitted work with the planted defect. Never edit a script
   while a run of it is executing.

5. **Verify with two subagents concurrently**, neither of them the implementer:
   - a **gate runner** walking CLAUDE.md's test ladder in order, stopping at the
     first failure, keeping ten minutes of output out of this context;
   - an **adversarial verifier** with no authorship stake, whose job is to prove
     the change is *not* deployable. Give it *How a fix goes wrong* below as its
     attack list, and require it to **run** each attack rather than read for it:
     the four failures recorded there were all defensible on a reading.

6. **Merge when deployable and green.** All of:
   - the lane's integration suite passes. It asserts converge, second run
     changes nothing, and `--check --diff` works, which is what deployable means;
   - `--check --diff` read for any diff touching `roles/`, `services/`,
     `site.yml` or `inventory/`;
   - anything landed dark is dark in *both* the role defaults and inventory;
   - no half-landed atomic set, and a new file a check reads is in
     `BASE_FIXTURE_PATHS`;
   - CI green on the pull request, and CodeRabbit's status *description* read and
     reported, since its state is `pass` for reviews it declined to perform;
   - nothing from Stop and ask open.

7. **Verify the deploy, which the merge does not.** The poller reads the *push*
   run on `main` for the merge commit and requires exactly one `success`. Wait
   for it.
   - Red or superseded: the NAS will not deploy and nothing anywhere reports
     that. Fix forward to `main`.
   - Green: confirm the tick picked it up with `nas-platform-deploy --status`
     when `PLATFORM_NAS_ADDRESS` and `PLATFORM_NAS_USER` are exported. Otherwise
     report that command as the step left unverified.

8. Next chunk, or report what merged and what deployed.

## How a fix goes wrong

Every one of these shipped here, past a green local run and a reading. None was
caught by review; each was caught by running something. Attack the fix on these
four before believing it — they are what the adversarial verifier is for.

**1. The fix reintroduces the bug through another door.** A guard that
*replaces* built-in behaviour inherits responsibility for every case that
behaviour handled. #521 added `failed_when: rc | default(0) != 0` to make a
Compose exec fail on a nonzero exit — but `failed_when` replaces the module's
own verdict *and* re-enables `changed_when`, so a module that refuses before it
runs anything sets no `rc` at all and the fix reported that refusal as a
successful change. Ten of the twelve carried `no_log`, so what an operator saw
was a green `changed` line and nothing else: strictly worse than the defect.
`default(1)` was the whole fix. **Ask: what does my replacement do in the states
the original mechanism handled?**

**2. The obvious fix does not work, and only running it says so.** #516's first
attempt was a SIGTERM handler that raises. It hung: `socketserver` catches any
exception raised while it dispatches and keeps serving, and calling
`server.shutdown()` from the handler deadlocks instead. Reproduced once in eight
attempts, found with a `faulthandler` dump. **Measure the mechanism on the real
runtime, before and after, and put both numbers in the report.**

**3. The happy path is a path.** #536's refusal message used a subscript into a
table with no row for the success state — and Ansible finalizes task arguments
*before* deciding whether an assertion holds, so it died on the passing path,
at task 658, after every assertion before it had passed. Every local measurement
had driven a refusal, where the key exists. The same session shipped a fixture
stub whose `exit_json` omitted `rc`, invisible until a fix made a missing `rc`
mean failure. **When a fix changes what a task reads, exercise the path where
there is nothing to report, and check the fixtures that fake that reading.**

**4. The claim you designed around is about a different artifact.** `CLAUDE.md`
says `verify.yml` is "structurally incapable of converging". That is the
*playbook*. `roles/<svc>/tasks/verify.yml` is imported by `main.yml` and runs
inside `site.yml` — so a design that moved a fatal probe there would have
stranded exactly the stacks it was chosen to protect. One
`ansible-playbook … --list-tasks --tags <role>` showed it. **Before designing
around a documented property, confirm the thing you are pointing at is the thing
the document is about.**

The shape they share: each was defensible on a reading and false on a run. A
green local run proves the states you exercised, and the states you exercised
are the ones you had in mind while writing the fix.

## Fix it and say so in the pull request body

Mechanical, no decision. These do not block.

| Finding | Fix |
|---|---|
| `--self-test` output identical to its plain run | Make it print what it detected |
| Dynamic subject list with no floor | Assert its known member count, not non-emptiness |
| A prose claim about code that is false | Correct the prose |
| A new file a check reads, absent from `BASE_FIXTURE_PATHS` | Add it |
| Missing `no_log: true`, `changed_when: false`, lint, formatting | Apply it |
| A pooled case assigning a name the script already carries | Declare it as a block-local after the `;` |
| A check whose anchor the diff moved (renamed or re-nested task) | Re-anchor it — walk `flatten_tasks`, match the new name. Never delete it |
| A fixture stub that fakes a module less faithfully than the fix now requires | Make the stub match the real module, and say what it still cannot prove |
| A pull request body reading `Closes #A and #B` | Only `#A` closes. Write `Closes #A, closes #B` — one keyword each |

## Stop and ask

Report, do not merge, do not start the next chunk.

- **A new vault credential.** The value is the user's to author, and it lands in
  ten places.
- The issue cannot be delivered in deployable states without splitting a set the
  gate asserts both ways.
- The only route to deployability changes what converges beyond what the issue
  asked, such as flipping a gate flag or moving a budget in
  `inventory/group_vars/nas_hosts/main.yml`.
- Two defensible designs with different operational consequences.
- A local gate failure that is neither clearly environmental nor clearly the
  diff.
- CI red for a reason outside the diff.
- The issue asks for something the repository rules out.

**The test: would two reasonable people pick differently?** If yes, stop.

## Red flags

| Thought | Reality |
|---|---|
| "CI is green, so it's ready" | Green means nobody read the diff. Deployable is a separate question with its own list. |
| "The self-test passed" | A self-test whose output matches its plain run proves nothing. Six such passed here in one day. |
| "I'll note it in the final report" | For a Stop and ask item, nobody reads the report before the next chunk merges. |
| "The gate got faster" | A dropped check is the fastest green there is. |
| "These chunks are independent, so run them in parallel" | One gate run at a time. |
| "I'll just fix it on the NAS" | Never. Merge the fix and the poller heals the host. |
| "The pull request merged, so it deployed" | The poller needs exactly one green *push* run on the merge commit. |
| "It passes locally, so the fix is right" | It proves the states you exercised, which are the ones you had in mind while writing it. See *How a fix goes wrong*. |
| "That check failing is the check doing its job" | Sometimes it is the diff moving the check's anchor. Read the failure before believing it found a defect. |
| "This test timed out — the machine is loaded" | Twice in one day that was a leaked load generator from an earlier agent, found with `ps`. Check before accepting the same explanation a second time. |
| "The obvious fix is obviously right" | #516's was, and it hung. Run it. |
