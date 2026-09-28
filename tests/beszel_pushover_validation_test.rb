#!/usr/bin/env ruby
# Runs roles/beszel's Pushover credential check (tasks parsed from the shipped file):
# an authoritative refusal must fail the run, and anything that is not an answer must not,
# or deployment becomes coupled to Pushover's uptime. Nothing here reaches Pushover itself.

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
# Per-token sentinels: a verdict pinned to the wrong key is visible.
TOKENS = {
  "vault_pushover_alerts_token" => "probe-alerts-token-never-valid",
  "vault_pushover_containers_token" => "probe-containers-token-never-valid",
  "vault_pushover_deployments_token" => "probe-deployments-token-never-valid",
  "vault_pushover_media_token" => "probe-media-token-never-valid",
  "vault_pushover_golem_token" => "probe-golem-token-never-valid"
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

  # failed_when: false is what keeps a 5xx or DNS failure from failing the run.
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

  # A fail_msg reaching into the response is templated on the passing path too.
  fail_msg = verify.dig("ansible.builtin.assert", "fail_msg").to_s
  check(failures, !fail_msg.include?("beszel_pushover_validation"),
        "#{VERIFY} fail_msg must not reach into the response; it is evaluated on the passing path too")
  check(failures, !fail_msg.match?(/vault_pushover_[a-z_]+\s*\}\}/) && !fail_msg.include?("lookup("),
        "#{VERIFY} fail_msg must name the credentials without printing them")
  check(failures, Array(ask["loop"]).sort == TOKENS.keys.sort,
        "#{ASK} must ask about every application token by vault key name, got #{ask['loop'].inspect}")

  # The harness must inherit the role's tags from site.yml, or `--tags beszel` selects
  # nothing and the zero-request rows below pass vacuously.
  site_roles = YAML.safe_load_file(File.join(ROOT, "site.yml"))
              .flat_map { |play| Array(play["roles"]) }
  beszel_entry = site_roles.find { |entry| entry.is_a?(Hash) && entry["role"] == "beszel" }
  ROLE_TAGS = Array(beszel_entry && beszel_entry["tags"]).freeze
  check(failures, ROLE_TAGS.length >= 2,
        "site.yml must still give roles/beszel the tags this harness inherits, got #{ROLE_TAGS.inspect}")

  def with_role_tags(shipped)
    shipped.map { |task| task.merge("tags" => (Array(task["tags"]) | ROLE_TAGS)) }
  end

  def run_tasks(shipped, url, tags: "platform_verify_beszel", extra: {})
    run_playbook(shipped,
                 { "beszel_pushover_validation_url" => url,
                   "platform_download_timeout" => 10,
                   "vault_pushover_user_key" => USER_KEY }.merge(TOKENS).merge(extra),
                 "--tags", tags)
  end

  # Inherited role tags make any of these strings request a `never` task, so only the
  # ansible_run_tags gate keeps them out; --list-tasks cannot see that. Zero requests,
  # not zero failures, is the property.
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

  # The converse: the poller's tag does reach Pushover, once per token.
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

  # Bodies are pre-generated JSON: the shared fixture writes `payload.to_s`, and a Hash
  # would stringify to inspect syntax uri cannot parse.
  [
    # no_log suppresses success_msg, so acceptance is asserted by the absent notice.
    { label: "a pair Pushover accepts", status: 200,
      body: JSON.generate({ "status" => 1, "devices" => ["phone"] }),
      expect_failure: false, forbid_text: "This is not a refusal and is not a failure" },
    { label: "a user key Pushover authoritatively refuses", status: 400,
      body: JSON.generate({ "status" => 0, "errors" => ["user identifier is not a valid user"] }),
      expect_failure: true, expect_text: "#{REFUSAL} #{TOKENS.keys.join(', ')}." },
    { label: "a 5xx, which is not an answer", status: 500,
      body: JSON.generate({ "status" => 0 }),
      expect_failure: false, expect_text: "This is not a refusal and is not a failure" },
    # A captive portal or proxy: authoritative code, no verdict. Not a refusal.
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

  # Two different keys prove the name comes from the verdict, not the loop position.
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

  # refusing_port proves a connect is refused before handing the port over.
  closed_port = refusing_port
  # The last three refuse before any request and register no status (#521), which is
  # why the summarize task defaults to -1; none may become a verdict.
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
