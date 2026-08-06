# Beginner Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add versioned, zero-assumption Ansible guidance with equal Mac and NAS walkthroughs and link it from the root README.

**Architecture:** Keep `README.md` as the concise project entry point. Put shared orientation and terminology in two focused documents, while separate Mac and NAS guides own their environment-specific commands and safety boundaries. Repository paths and commands are authoritative; official external documentation is supplementary.

**Tech Stack:** Markdown, Ansible Core, Ansible Vault, `community.docker`, Docker Desktop, SSH, POSIX shell, Ruby policy checks.

---

### Task 1: Write the shared beginner orientation

**Files:**
- Create: `docs/getting-started.md`
- Create: `docs/ansible-basics.md`

- [x] **Step 1: Write the landing page**

Create `docs/getting-started.md` with these concrete sections: safety boundary, repository status, terminology, shared prerequisites, clone/install commands, how to choose the Mac or NAS path, secrets rules, reading Ansible output, and recovery navigation. Link both walkthroughs and the concepts guide using relative repository links.

- [x] **Step 2: Write the concepts guide**

Create `docs/ansible-basics.md` explaining controller/managed host, inventory, group variables, playbooks, tasks, roles, modules, collections, templates, facts, registered values, handlers, idempotence, check/diff mode, tags, Vault, recaps, and failure diagnosis. For each concept, cite a current path in this repository and link to official Ansible documentation.

- [x] **Step 3: Verify repository references**

Run:

```sh
for path in \
  README.md site.yml verify.yml requirements.yml \
  inventory/local.yml inventory/remote.yml inventory/mac.yml \
  inventory/group_vars/all/vault.yml.example \
  docs/getting-started-mac.md docs/getting-started-nas.md \
  tests/mac/manual-review.md; do
  test -e "$path"
done
```

Expected: exit 0.

### Task 2: Write equal Mac and NAS walkthroughs

**Files:**
- Create: `docs/getting-started-mac.md`
- Create: `docs/getting-started-nas.md`

- [x] **Step 1: Write the Mac walkthrough**

Document official prerequisites; collection installation; creation of an encrypted vault from the exact example contract; safe external vault-password command; full `tests/mac/run.sh --lane fresh` invocation; ordered phases; expected report; manual review; resume; failure behavior; validated cleanup; and NAS-only limitations. State that the physical NAS is not contacted.

- [x] **Step 2: Write the NAS walkthrough**

Document NAS Docker/Python prerequisites; workstation Ansible installation; SSH connectivity; `PLATFORM_NAS_ADDRESS` and `PLATFORM_NAS_USER`; migration vault population from current credentials; brand-new generation as a distinct opt-in path; encryption; inventory graph/ping; production `--check --diff`; apply; `verify.yml`; second-run idempotence; backups; troubleshooting; and rollback/recovery boundaries.

- [x] **Step 3: Check shell examples**

Extract multiline fenced `sh` examples that contain no placeholders requiring operator input into a temporary script and run `sh -n`. Manually verify placeholder-bearing examples use descriptive values and cannot be mistaken for real credentials.

Expected: all extracted scripts parse; no plaintext secret appears.

### Task 3: Link, validate, and publish the documentation

**Files:**
- Modify: `README.md`
- Test: `tests/policy_test.rb`

- [x] **Step 1: Add the README entry point**

Add a prominent `New to Ansible?` section before `Design`, linking to:

```markdown
- [Beginner starting point](docs/getting-started.md)
- [Disposable Mac walkthrough](docs/getting-started-mac.md)
- [Physical NAS walkthrough](docs/getting-started-nas.md)
- [Ansible concepts used here](docs/ansible-basics.md)
```

- [x] **Step 2: Add documentation policy assertions**

Extend `tests/policy_test.rb` to require all four guides, the four README links, both inventory names in the landing page, safety language forbidding plaintext vault commits, and official Ansible documentation links in the concepts guide.

- [x] **Step 3: Run verification**

Run:

```sh
ruby tests/policy_test.rb
tests/validate-policy.sh
git diff --check
```

Expected: all commands exit 0.

- [x] **Step 4: Review documentation as a beginner**

Follow both walkthroughs on paper from a fresh clone. Confirm every command states where it runs, whether it changes production, expected success, and the next recovery action. Confirm current implementation status is explicit and no unfinished service is presented as proven.

- [x] **Step 5: Commit and push**

```sh
git add README.md docs/getting-started.md docs/getting-started-mac.md \
  docs/getting-started-nas.md docs/ansible-basics.md tests/policy_test.rb \
  docs/superpowers/plans/2026-08-06-beginner-documentation.md
git commit -m "docs: add beginner Ansible guides"
git push origin main
```
