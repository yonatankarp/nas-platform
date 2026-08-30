# Documentation-Only CI Fast Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the required `validate` job present while making changes confined to `README.md` and `docs/**` run only fast documentation contracts.

**Architecture:** A small Ruby classifier consumes the NUL-delimited changed-path set computed by GitHub Actions. The workflow always runs the classifier and chooses either the documentation suite or the unchanged full validation steps; mixed, empty, malformed, and executable changes always select the full lane.

**Tech Stack:** GitHub Actions, POSIX shell, Ruby 4-compatible tests, Git.

**Status:** the fast path this plan built treated everything under `docs/` as
inert, and the documentation checks it deferred to were later registered in the
policy gate. A document the gate reads but the routing dropped could then break
`main` and still merge green. The routing now sends `README.md` and every path
under `docs/` to a `docs` job of its own, which runs the link and secrets-guide
checks on a checkout and Ruby alone; the documents a heavyweight policy check
reads by name select the `static` job as well.

---

### Task 1: Add the fail-closed change classifier

**Files:**
- Create: `tests/ci_change_scope.rb`

- [ ] **Step 1: Create the failing classifier contract**

Create `tests/ci_change_scope.rb` with only the self-test cases and an undefined
`classify` call:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

def check(actual, expected, label)
  raise "#{label}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

if ARGV == ["--self-test"]
  check(classify(["README.md"]), true, "README")
  check(classify(["docs/guide.md", "docs/nested/page.md"]), true, "docs")
  check(classify(["docs/guide.md", "roles/ntfy/tasks/main.yml"]), false, "mixed")
  check(classify([".github/workflows/ci.yml"]), false, "workflow")
  check(classify([]), false, "empty")
  check(classify(["docs"]), false, "docs directory literal")
  puts "CI change scope: fail-closed classification holds"
  exit
end
```

- [ ] **Step 2: Run the self-test and verify RED**

Run: `ruby tests/ci_change_scope.rb --self-test`

Expected: FAIL with `undefined method 'classify'`.

- [ ] **Step 3: Implement exact NUL-delimited classification**

Insert before the self-test block:

```ruby
def classify(paths)
  !paths.empty? && paths.all? do |path|
    path == "README.md" || path.start_with?("docs/")
  end
end
```

Append after the self-test block:

```ruby
abort "usage: ci_change_scope.rb [--self-test]" unless ARGV.empty?

input = STDIN.binmode.read
paths = input.split("\0", -1)
paths.pop if paths.last == ""
abort "changed paths must be NUL-delimited" if paths.any?(&:empty?)
abort "changed paths must be relative" if paths.any? { |path| path.start_with?("/") }
abort "changed paths contain control bytes" if paths.any? { |path| path.match?(/[[:cntrl:]]/) }
abort "changed paths contain an unsafe component" if paths.any? do |path|
  path.split("/").any? { |component| [".", "..", ""].include?(component) }
end

puts "docs_only=#{classify(paths)}"
puts "changed_count=#{paths.length}"
```

- [ ] **Step 4: Verify GREEN and malformed-input refusal**

Run:

```bash
ruby tests/ci_change_scope.rb --self-test
printf 'docs/page.md\0README.md\0' | ruby tests/ci_change_scope.rb
if printf 'docs/page.md\n' | ruby tests/ci_change_scope.rb; then exit 1; fi
```

Expected: the self-test passes, the valid input prints `docs_only=true` and
`changed_count=2`, and newline-delimited input is refused.

- [ ] **Step 5: Commit**

```bash
git add tests/ci_change_scope.rb
git commit -m "test: classify documentation-only changes"
```

### Task 2: Add focused documentation validation

**Files:**
- Create: `tests/docs_links_test.rb`
- Create: `tests/validate-docs.sh`

- [ ] **Step 1: Write the failing documentation-suite entry point**

Create `tests/validate-docs.sh`:

```sh
#!/bin/sh
set -eu

ruby tests/policy_test.rb
ruby tests/secrets_docs_test.rb
ruby tests/docs_links_test.rb
ruby tests/ci_change_scope.rb --self-test
```

Run: `chmod +x tests/validate-docs.sh && tests/validate-docs.sh`

Expected: FAIL because `tests/docs_links_test.rb` does not exist.

- [ ] **Step 2: Implement local Markdown-link validation**

Create `tests/docs_links_test.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "uri"

ROOT = Pathname.new(File.expand_path("..", __dir__))
SOURCES = [ROOT.join("README.md"), *ROOT.join("docs").glob("**/*.md")].freeze
failures = []

SOURCES.each do |source|
  source.read.scan(/\[[^\]]*\]\(([^)]+)\)/).flatten.each do |raw_target|
    target = raw_target.strip
    target = target[1...-1] if target.start_with?("<") && target.end_with?(">")
    next if target.empty? || target.start_with?("#")
    next if target.match?(/\A(?:https?|mailto):/)

    path_text = URI.decode_www_form_component(target.split("#", 2).first)
    resolved = source.dirname.join(path_text).cleanpath
    unless resolved.to_s.start_with?("#{ROOT}/") && (resolved.file? || resolved.directory?)
      failures << "#{source.relative_path_from(ROOT)}: broken local link #{raw_target}"
    end
  rescue ArgumentError
    failures << "#{source.relative_path_from(ROOT)}: malformed local link #{raw_target}"
  end
end

if failures.empty?
  puts "docs links: all local targets exist"
else
  warn failures.join("\n")
  exit 1
end
```

- [ ] **Step 3: Verify documentation contracts GREEN**

Run:

```bash
sh -n tests/validate-docs.sh
tests/validate-docs.sh
```

Expected: all four commands report success, ending with the classifier self-test.

- [ ] **Step 4: Commit**

```bash
git add tests/docs_links_test.rb tests/validate-docs.sh
git commit -m "test: add focused documentation validation"
```

### Task 3: Route the required workflow without skipping the job

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add the classifier step and verify the workflow contract is RED**

Add `fetch-depth: 0` to checkout and this step immediately afterwards:

```yaml
      - name: Classify changed paths
        id: scope
        env:
          EVENT_NAME: ${{ github.event_name }}
          PR_BASE_SHA: ${{ github.event.pull_request.base.sha }}
          PUSH_BEFORE_SHA: ${{ github.event.before }}
        run: |
          case "$EVENT_NAME" in
            pull_request) base_sha=$PR_BASE_SHA ;;
            push) base_sha=$PUSH_BEFORE_SHA ;;
            *) base_sha= ;;
          esac
          if ! printf '%s' "$base_sha" | grep -Eq '^[0-9a-f]{40}$' ||
             printf '%s' "$base_sha" | grep -Eq '^0{40}$'; then
            printf 'docs_only=false\nchanged_count=0\n' >> "$GITHUB_OUTPUT"
          else
            git diff --name-only -z "$base_sha" "$GITHUB_SHA" |
              ruby tests/ci_change_scope.rb >> "$GITHUB_OUTPUT"
          fi
```

Run: `ruby tests/ci_change_scope.rb --self-test && rg -n 'paths-ignore' .github/workflows/ci.yml`

Expected: classifier passes and `rg` returns no matches. The routing is still
incomplete because no step consumes `scope.outputs.docs_only`.

- [ ] **Step 2: Add the fast documentation step**

Add after classification:

```yaml
      - name: Validate documentation
        if: steps.scope.outputs.docs_only == 'true'
        run: tests/validate-docs.sh
```

- [ ] **Step 3: Guard every existing full-validation step**

Add this condition to each existing step after classification, from `Validate
shell syntax` through `Converge against a disposable sandbox`:

```yaml
        if: steps.scope.outputs.docs_only != 'true'
```

Do not condition checkout or classification. Do not add workflow-level
`paths`, `paths-ignore`, a second job, or a renamed job; `validate` must always
be created for branch protection.

- [ ] **Step 4: Validate YAML semantics and lane selection**

Run:

```bash
ruby -e 'require "yaml"; YAML.safe_load_file(".github/workflows/ci.yml", aliases: true)'
tests/validate-docs.sh
tests/validate-policy.sh
```

Expected: YAML parses, docs validation passes, and the unchanged full policy
suite passes.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add documentation-only fast path"
```

### Task 4: Pin the CI routing contract against regressions

**Files:**
- Create: `tests/ci_workflow_test.rb`
- Modify: `tests/validate-policy.sh`

- [ ] **Step 1: Write the workflow contract**

Create `tests/ci_workflow_test.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

workflow = File.read(File.expand_path("../.github/workflows/ci.yml", __dir__))
parsed = YAML.safe_load(workflow, aliases: true)
validate = parsed.fetch("jobs").fetch("validate")
steps = validate.fetch("steps")
failures = []

failures << "validate job was renamed or removed" unless validate
failures << "workflow-level path filtering is forbidden" if workflow.match?(/^\s+paths(?:-ignore)?:/)
failures << "checkout must fetch the comparison base" unless workflow.include?("fetch-depth: 0")
failures << "classifier is not wired to GITHUB_OUTPUT" unless workflow.include?("ruby tests/ci_change_scope.rb >> \"$GITHUB_OUTPUT\"")
failures << "documentation suite is absent" unless steps.any? do |step|
  step["run"] == "tests/validate-docs.sh" && step["if"] == "steps.scope.outputs.docs_only == 'true'"
end

heavy = steps.select { |step| step["name"]&.match?(/Converge|Lint Ansible|playbook syntax/i) }
failures << "heavy steps are not fail-closed" unless heavy.all? do |step|
  step["if"] == "steps.scope.outputs.docs_only != 'true'"
end

if failures.empty?
  puts "CI workflow: required job and docs-only boundary hold"
else
  warn failures.join("\n")
  exit 1
end
```

- [ ] **Step 2: Register the contract and verify GREEN**

Add immediately after `ruby tests/secrets_docs_test.rb` in
`tests/validate-policy.sh`:

```sh
ruby tests/ci_workflow_test.rb
```

Run:

```bash
ruby tests/ci_workflow_test.rb
tests/validate-policy.sh
git diff --check
```

Expected: both suites pass and the diff has no whitespace errors.

- [ ] **Step 3: Commit**

```bash
git add tests/ci_workflow_test.rb tests/validate-policy.sh
git commit -m "test: enforce CI lane separation"
```

### Task 5: Verify the complete fast-path change

**Files:** none

- [ ] **Step 1: Run local verification**

```bash
find tests -type f -name '*.sh' -exec sh -n {} +
tests/validate-docs.sh
tests/validate-policy.sh
tests/integration_cleanup_test.sh
git diff --check
git status --short
```

Expected: every command exits `0`; status shows only intentionally unpushed
commits and no uncommitted files.

- [ ] **Step 2: Push as its own reviewed change**

Push the branch and open or update the focused PR. Confirm the first run takes
the full lane because executable workflow/test files changed. After merge, use a
one-file docs-only PR to confirm that the same required `validate` job runs the
documentation step and skips Ansible installation and convergence.
