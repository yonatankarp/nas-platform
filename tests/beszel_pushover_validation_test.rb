#!/usr/bin/env ruby
# The Pushover credential check in roles/beszel, run rather than read.
#
# Everything else in that role compares the stored webhook to the intended
# webhook, and Beszel stores whatever it is PATCHed, so all of it stays green
# when the credentials inside that string stop working. These four tasks are
# the only thing that can tell those states apart, and the property that makes
# them safe is narrower than "they work": an authoritative refusal must fail the
# run, and everything that is not an answer must not. Getting the second half
# wrong couples this NAS's deployment to Pushover's uptime, on a five-minute
# poller, which is worse than having no check at all.
#
# THE TASKS ARE PARSED OUT OF THE SHIPPED FILE, not restated here. A copy would
# pass forever after the role stopped matching it, which is the failure this
# repository keeps closing; the extraction below fails loudly if a task is
# renamed or moved out of the block.
#
# What the passing path proves is bounded, and the bound is stated rather than
# implied: the "accepted" row answers from a local fixture speaking Pushover's
# documented success shape, so it proves this task's own branch and not that any
# particular credential is good. Nothing here reaches Pushover itself -- the
# refusal against the real endpoint was measured by hand and is recorded in the
# pull request, because a check that calls a third party on every gate run is a
# check that fails when that third party is down.

require "json"
require "uri"
require "yaml"
require_relative "policy_support"
require_relative "http_fixture_support"

include PolicySupport
include TestScaffold
include HttpFixtureSupport

CONFIGURE = File.join(ROOT, "roles", "beszel", "tasks", "configure.yml")
ASK = "Ask Pushover whether it still accepts the managed credentials"
SUMMARIZE = "Summarize the Pushover answer without the credentials it carried"
NO_ANSWER = "Report that Pushover did not answer, which is not a refusal"
VERIFY = "Verify Pushover still accepts the managed credentials"
TASK_NAMES = [ASK, SUMMARIZE, NO_ANSWER, VERIFY].freeze
REFUSAL = "Pushover refused the managed credentials for"
# One sentinel per application token, keyed by the vault name the refusal must
# carry. The fixture answers per token, so a verdict pinned to the wrong key --
# or a refusal that named every key whatever was refused -- is visible.
TOKENS = {
  "vault_pushover_alerts_token" => "probe-alerts-token-never-valid",
  "vault_pushover_containers_token" => "probe-containers-token-never-valid",
  "vault_pushover_deployments_token" => "probe-deployments-token-never-valid",
  "vault_pushover_media_token" => "probe-media-token-never-valid"
}.freeze
USER_KEY = "probe-user-key-never-valid"
ACCEPT = [200, JSON.generate({ "status" => 1, "devices" => ["phone"] })].freeze
REFUSE = [400, JSON.generate({ "status" => 0, "errors" => ["application token is invalid"] })].freeze

failures = []

tasks = flatten_tasks(YAML.safe_load_file(CONFIGURE))
selected = TASK_NAMES.map { |name| tasks.find { |task| task["name"] == name } }
missing = TASK_NAMES.zip(selected).select { |_name, task| task.nil? }.map(&:first)
check(failures, missing.empty?,
      "roles/beszel/tasks/configure.yml must still carry #{missing.join(', ')}")

if missing.empty?
  ask, _summarize, _no_answer, verify = selected

  # The shape that makes the verdict the assert's rather than the module's.
  # failed_when: false is what stops a 5xx or a DNS failure failing the run, and
  # it is the line whose deletion turns this guard into the outage it exists to
  # prevent.
  check(failures, ask["failed_when"] == false,
        "#{ASK} must state failed_when: false, or an unreachable Pushover fails the converge")
  check(failures, ask["changed_when"] == false, "#{ASK} must be a read")
  check(failures, ask["check_mode"] == false,
        "#{ASK} must really run under --check, or its register has no status to read")
  check(failures, ask["no_log"] == true, "#{ASK} sends both credentials and must carry no_log")
  status_codes = Array(ask.dig("ansible.builtin.uri", "status_code"))
  check(failures, status_codes.sort == [200, 400],
        "#{ASK} must accept 200 and 400 as data so a refusal reaches the assert, got #{status_codes.inspect}")

  # The whole point of the `never`: site.yml is every service's deployment path.
  TASK_NAMES.zip(selected).each do |name, task|
    tags = Array(task["tags"])
    check(failures, tags.include?("never") && tags.include?("platform_verify_beszel"),
          "#{name} must carry both never and platform_verify_beszel, got #{tags.inspect}")
  end

  # The finalize trap: a fail_msg reaching into the response is templated on the
  # passing path too. Only the two derived booleans and literal prose are
  # allowed to appear in it.
  fail_msg = verify.dig("ansible.builtin.assert", "fail_msg").to_s
  check(failures, !fail_msg.include?("beszel_pushover_validation"),
        "#{VERIFY} fail_msg must not reach into the response; it is evaluated on the passing path too")
  check(failures, !fail_msg.match?(/vault_pushover_[a-z_]+\s*\}\}/) && !fail_msg.include?("lookup("),
        "#{VERIFY} fail_msg must name the credentials without printing them")
  check(failures, Array(ask["loop"]).sort == TOKENS.keys.sort,
        "#{ASK} must ask about every application token by vault key name, got #{ask['loop'].inspect}")

  # THE HARNESS HAS TO INHERIT THE ROLE'S TAGS OR IT PROVES NOTHING, and this is
  # not a hypothetical: without it the tag-gate rows below passed against a
  # deliberately planted defect. A throwaway playbook has no role, so the tasks
  # carry only their own [never, platform_verify_beszel] and `--tags beszel`
  # selects nothing -- the rows were measuring tag selection in the harness
  # rather than the when: gate in the role, and "zero requests" was true because
  # nothing ran at all.
  #
  # Read out of site.yml rather than written here, so a rename or a retagging of
  # the role reaches this instead of leaving it quietly testing the wrong thing.
  site_roles = YAML.safe_load_file(File.join(ROOT, "site.yml"))
              .flat_map { |play| Array(play["roles"]) }
  beszel_entry = site_roles.find { |entry| entry.is_a?(Hash) && entry["role"] == "beszel" }
  ROLE_TAGS = Array(beszel_entry && beszel_entry["tags"]).freeze
  check(failures, ROLE_TAGS.length >= 2,
        "site.yml must still give roles/beszel the tags this harness inherits, got #{ROLE_TAGS.inspect}")

  def with_role_tags(shipped)
    shipped.map { |task| task.merge("tags" => (Array(task["tags"]) | ROLE_TAGS)) }
  end

  # Run the shipped tasks. --tags is passed rather than the tags being stripped,
  # so the gating is exercised instead of being worked around.
  def run_tasks(shipped, url, tags: "platform_verify_beszel", extra: {})
    run_playbook(shipped,
                 { "beszel_pushover_validation_url" => url,
                   "platform_download_timeout" => 10,
                   "vault_pushover_user_key" => USER_KEY }.merge(TOKENS).merge(extra),
                 "--tags", tags)
  end

  # THE TAG IS NOT THE GATE, AND THAT IS THE POINT OF THIS SECTION.
  # Ansible inherits the role's own tags onto every task in it, so these also
  # carry beszel and monitoring, and naming ANY inherited tag counts as
  # explicitly requesting a `never` task. The beszel CI lane converges with
  # exactly the first tag string below, against an ephemeral vault, so before the
  # ansible_run_tags gate it asked Pushover about credentials that were never
  # real and failed the lane. A --list-tasks check cannot see any of this: it
  # does not evaluate when:, and it still lists these tasks under those tags.
  #
  # The fixture counts requests, because "the run passed" is also true of a gate
  # that let the task through to an endpoint that happened to answer. Zero
  # requests is the property, not zero failures.
  {
    "the beszel CI lane's own tag string" => "host_prep,deployment_bundle,beszel",
    "the role tag alone" => "beszel",
    "the group tag the role also carries" => "monitoring"
  }.each do |label, tags|
    requests = 0
    with_http_fixture(lambda { |port|
      _stdout, _stderr, status = run_tasks(
        with_role_tags(selected), "http://127.0.0.1:#{port}/1/users/validate.json", tags: tags
      )
      check(failures, status.success?, "#{label} must not fail the converge")
    }) { |_method, _target, _headers, _body|
      requests += 1
      [200, JSON.generate({ "status" => 0 })]
    }
    check(failures, requests.zero?,
          "#{label} must not reach Pushover at all; it made #{requests} request(s)")
  end

  # The converse, so the gate is shown open as well as closed: the tag the
  # poller actually asks for does let the requests through, once per token and
  # each with the shared user key.
  asked = []
  with_http_fixture(lambda { |port|
    run_tasks(selected, "http://127.0.0.1:#{port}/1/users/validate.json")
  }) { |_method, _target, _headers, body|
    asked << URI.decode_www_form(body.to_s).to_h
    ACCEPT
  }
  check(failures, asked.map { |form| form["token"] }.sort == TOKENS.values.sort &&
                  asked.all? { |form| form["user"] == USER_KEY },
        "--tags platform_verify_beszel must ask Pushover once per application token with the user key, " \
        "asked about #{asked.map { |form| TOKENS.key(form['token']) || 'something else' }.inspect}")

  # A fixture speaking Pushover's documented shapes, so the two branches that
  # cannot be reached from the real endpoint without a real account are still
  # exercised against the real task.
  # The body is generated here rather than handed over as a Hash: the shared
  # fixture writes `payload.to_s`, and a Ruby Hash stringifies to inspect syntax
  # that uri cannot parse, which registers no json key at all. That is a fixture
  # that answers something other than what it claims to answer -- it is how the
  # 200-with-no-verdict row below was found, and it would otherwise have made
  # the accepted row fail for a reason having nothing to do with the role.
  [
    # The accepted path is asserted by what it does NOT say. no_log suppresses
    # success_msg -- measured, not assumed -- so a valid pair is silent by
    # design, and the thing that would be wrong is the non-verdict notice
    # appearing when Pushover did in fact answer.
    { label: "a pair Pushover accepts", status: 200,
      body: JSON.generate({ "status" => 1, "devices" => ["phone"] }),
      expect_failure: false, forbid_text: "This is not a refusal and is not a failure" },
    { label: "a user key Pushover authoritatively refuses", status: 400,
      body: JSON.generate({ "status" => 0, "errors" => ["user identifier is not a valid user"] }),
      expect_failure: true, expect_text: "#{REFUSAL} #{TOKENS.keys.join(', ')}." },
    { label: "a 5xx, which is not an answer", status: 500,
      body: JSON.generate({ "status" => 0 }),
      expect_failure: false, expect_text: "This is not a refusal and is not a failure" },
    # 200 from something that is not Pushover: a captive portal or an
    # interception proxy. Authoritative code, no verdict in it. Reading this as
    # a refusal is the invention the whole design forbids, and the task did read
    # it that way until this row existed.
    { label: "a 200 carrying no Pushover verdict", status: 200,
      body: "<html><body>Sign in to continue</body></html>",
      expect_failure: false, expect_text: "This is not a refusal and is not a failure" }
  ].each do |row|
    with_http_fixture(lambda { |port|
      stdout, stderr, status = run_tasks(selected, "http://127.0.0.1:#{port}/1/users/validate.json")
      output = stdout + stderr
      check(failures, status.success? != row.fetch(:expect_failure),
            "#{row.fetch(:label)} must #{row.fetch(:expect_failure) ? 'fail' : 'pass'} the verification")
      if row[:expect_text]
        check(failures, output.include?(row.fetch(:expect_text)),
              "#{row.fetch(:label)} must report #{row.fetch(:expect_text).inspect}")
      end
      if row[:forbid_text]
        check(failures, !output.include?(row.fetch(:forbid_text)),
              "#{row.fetch(:label)} must not report #{row.fetch(:forbid_text).inspect}")
      end
      # No credential may reach the transcript on any path.
      [*TOKENS.values, USER_KEY].each do |secret|
        check(failures, !output.include?(secret),
              "#{row.fetch(:label)} disclosed a credential in its diagnostic")
      end
    }) { |_method, _target, _headers, _body| [row.fetch(:status), row.fetch(:body)] }
  end

  # One application's token refused while the others are accepted -- a token
  # regenerated in one application's console. The refusal must name that key
  # and no other, and a second row with a different key proves the name comes
  # from the verdict rather than from a position in the loop.
  %w[vault_pushover_media_token vault_pushover_alerts_token].each do |refused_key|
    with_http_fixture(lambda { |port|
      stdout, stderr, status = run_tasks(selected, "http://127.0.0.1:#{port}/1/users/validate.json")
      output = stdout + stderr
      label = "only #{refused_key} refused"
      check(failures, !status.success?, "#{label} must fail the verification")
      check(failures, output.include?("#{REFUSAL} #{refused_key}."),
            "#{label} must name #{refused_key} in the refusal")
      (TOKENS.keys - [refused_key]).each do |other|
        check(failures, !output.include?(other), "#{label} must not name #{other}")
      end
      check(failures, [*TOKENS.values, USER_KEY].none? { |secret| output.include?(secret) },
            "#{label} disclosed a credential in its diagnostic")
    }) { |_method, _target, _headers, body|
      URI.decode_www_form(body.to_s).to_h["token"] == TOKENS.fetch(refused_key) ? REFUSE : ACCEPT
    }
  end

  # A refusal and a non-answer in the same run: the refusal still fails, it
  # names only the refused key, and the non-answer is still reported as one.
  with_http_fixture(lambda { |port|
    stdout, stderr, status = run_tasks(selected, "http://127.0.0.1:#{port}/1/users/validate.json")
    output = stdout + stderr
    check(failures, !status.success? && output.include?("#{REFUSAL} vault_pushover_containers_token.") &&
                    !output.include?("vault_pushover_deployments_token"),
          "a refusal beside a non-answer must fail naming only the refused key")
    check(failures, output.include?("Pushover did not answer for 1 of"),
          "a non-answer beside a refusal must still be reported as one")
  }) { |_method, _target, _headers, body|
    case URI.decode_www_form(body.to_s).to_h["token"]
    when TOKENS.fetch("vault_pushover_containers_token") then REFUSE
    when TOKENS.fetch("vault_pushover_deployments_token") then [503, "unavailable"]
    else ACCEPT
    end
  }

  # Nothing listening: the connection-refused path, which is the shape a Pushover
  # outage takes and the one that must never be read as a refusal. The port is
  # bound and released so it is free rather than merely unlikely.
  closed_port = begin
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr.fetch(1)
    probe.close
    port
  end
  # Five shapes, not one. The first two are an outage: a refused connection and a
  # name that does not resolve reach uri through different failure paths, and
  # either is how Pushover being down presents.
  #
  # The last three are the #521 shape, and they are the reason this list is not
  # two rows long. A module that refuses BEFORE it makes any request registers no
  # status at all -- not a zero, not a failure code, nothing -- which is exactly
  # why the summarize task defaults to -1 rather than 0. That default was
  # reasoned about in a comment and proved by nothing until these rows existed,
  # and a comment is what this repository has watched fail twelve times over.
  # None of them may become a verdict either.
  {
    "a Pushover that refuses the connection" =>
      "http://127.0.0.1:#{closed_port}/1/users/validate.json",
    "a Pushover whose name does not resolve" =>
      "https://api.pushover.net.invalid/1/users/validate.json",
    "a url the module refuses to parse" => "not-a-url-at-all",
    "an empty url" => "",
    "a scheme the module does not speak" => "gopher://example.invalid/validate"
  }.each do |label, url|
    stdout, stderr, status = run_tasks(selected, url)
    output = stdout + stderr
    check(failures, status.success?,
          "#{label} must not fail the verification; that would put this NAS's deployment "\
          "behind a third party's uptime")
    check(failures, output.include?("This is not a refusal and is not a failure"),
          "#{label} must report a non-verdict rather than claiming a pass")
    check(failures, !output.include?(REFUSAL),
          "#{label} must never be reported as a credential refusal")
  end
end

report(failures, "Beszel Pushover validation: the refusal fails, and nothing else does",
       "Beszel Pushover validation violation(s)")
