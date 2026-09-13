#!/usr/bin/env ruby
# frozen_string_literal: true

# The deployment record is what a human actually reads after a deployment, so
# what it says — and when it stays silent — is a contract. Two messages make it
# up: one per-service report, and the run-level summary behind them. Both are
# delivered to Pushover by roles/ntfy/tasks/pushover_publish.yml, and the second
# half of this file runs that delivery against a local fixture speaking
# Pushover's shapes: an authoritative refusal fails the converge, and nothing
# that is not an answer does.

require "fileutils"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "uri"
require "yaml"

require_relative "policy_support"
require_relative "http_fixture_support"

include HttpFixtureSupport
include TestScaffold

DIGEST_A = "@sha256:#{'a' * 64}"
DIGEST_B = "@sha256:#{'b' * 64}"
# Sentinels rather than anything shaped like a real pair, so a transcript
# containing one is unambiguous.
TOKEN = "probe-pushover-token-never-valid"
USER_KEY = "probe-pushover-user-key-never-valid"
ENDPOINT_PATH = "/1/messages.json"
ACCEPTED = [200, JSON.generate({ "status" => 1, "request" => "fixture" })].freeze
NON_VERDICT = "This is not a refusal and is not a failure"
REFUSAL = "Pushover refused the deployment notification."

failures = []

# Every row answers from this probe. What the test reads afterwards is what
# arrived, decoded the way Pushover decodes a form POST.
def with_http_probe(expected_count, answer: ACCEPTED, &block)
  requests = []
  with_http_fixture(->(port) { block.call(port, requests) }) do |method, target, headers, body|
    requests << { "method" => method, "target" => target, "headers" => headers,
                  "form" => URI.decode_www_form(body).to_h }
    answer
  end
  raise "deployment record probe request count differs: #{requests.length}" unless
    requests.length == expected_count
end

def endpoint(port)
  "http://127.0.0.1:#{port}#{ENDPOINT_PATH}"
end

def manifest(images)
  YAML.dump(
    "git_sha" => "0" * 40,
    "services" => images.map { |name, containers| { "name" => name, "images" => containers } }
  )
end

def write_release(deploy_root, revision, images)
  release = File.join(deploy_root, "releases", revision)
  FileUtils.mkdir_p(release)
  File.write(File.join(release, "manifest.yml"), manifest(images))
  release
end

# A real repository, because the summary reads the commit subjects a deployment
# carries from the controller checkout rather than from the target.
def with_controller_repository
  Dir.mktmpdir("nas-platform-deployment-summary-") do |directory|
    repository = File.join(directory, "controller")
    FileUtils.mkdir_p(repository)
    environment = {
      "GIT_AUTHOR_NAME" => "Fixture", "GIT_AUTHOR_EMAIL" => "fixture@example.invalid",
      "GIT_COMMITTER_NAME" => "Fixture", "GIT_COMMITTER_EMAIL" => "fixture@example.invalid"
    }
    run = lambda do |*command|
      _out, err, status = Open3.capture3(environment, "git", "-C", repository, *command)
      raise "git #{command.first} failed: #{err}" unless status.success?
    end
    Open3.capture3("git", "init", "-q", "-b", "main", repository)
    File.write(File.join(repository, "README"), "first\n")
    run.call("add", "README")
    run.call("commit", "-qm", "feat: first release")
    previous = Open3.capture3("git", "-C", repository, "rev-parse", "HEAD").first.strip
    File.write(File.join(repository, "README"), "second\n")
    run.call("commit", "-qam", "fix: pin jellyfin 10.11.0")
    File.write(File.join(repository, "README"), "third\n")
    run.call("commit", "-qam", "chore(deps): update immich to v1.122.0")
    current = Open3.capture3("git", "-C", repository, "rev-parse", "HEAD").first.strip
    yield directory, repository, previous, current
  end
end

def run_ntfy_task(tasks_from, variables, *arguments)
  report = [{
    "name" => "Report the deployment",
    "ansible.builtin.include_role" => { "name" => "ntfy", "tasks_from" => tasks_from }
  }]
  run_playbook(report, variables, *arguments, prefix: "nas-platform-deployment-summary-play-")
end

def run_summary(variables, *arguments)
  run_ntfy_task("deployment_summary", variables, *arguments)
end

def run_report(variables, *arguments)
  run_ntfy_task("deployment_report", variables, *arguments)
end

# The form every delivery must be, whichever message it carries.
def check_delivery_form(failures, label, request, priority)
  form = request["form"] || {}
  check(failures, request["method"] == "POST" && request["target"] == ENDPOINT_PATH,
        "#{label} must POST to the Pushover message API, got " \
        "#{request['method']} #{request['target']}")
  check(failures, request.dig("headers", "content-type").to_s
                         .start_with?("application/x-www-form-urlencoded"),
        "#{label} must be a form POST, which is what Pushover's API reads")
  check(failures, form["token"] == TOKEN && form["user"] == USER_KEY,
        "#{label} must carry vault_pushover_token as token and vault_pushover_user_key as user")
  check(failures, form["priority"] == priority,
        "#{label} must be sent at Pushover priority #{priority}, got #{form['priority'].inspect}")
  check(failures, (form.keys & %w[topic tags html]).empty?,
        "#{label} must carry no ntfy-only field and no html flag: #{form.keys.inspect}")
  check(failures, !form["message"].to_s.strip.empty? && !form["title"].to_s.strip.empty?,
        "#{label} must never send an empty title or message; Pushover refuses one")
end

PREVIOUS_IMAGES = {
  "jellyfin" => { "jellyfin" => "docker.io/jellyfin/jellyfin:10.10.3#{DIGEST_A}" },
  "ntfy" => { "ntfy" => "docker.io/binwiederhier/ntfy:v2.28.0#{DIGEST_A}" }
}.freeze
CURRENT_IMAGES = {
  "jellyfin" => { "jellyfin" => "docker.io/jellyfin/jellyfin:10.11.0#{DIGEST_B}" },
  "ntfy" => { "ntfy" => "docker.io/binwiederhier/ntfy:v2.28.0#{DIGEST_A}" }
}.freeze

# A Renovate batch in miniature, sized so both halves overrun Pushover's limits
# by construction. The headline is three 77-character names plus "+37", which is
# 253 characters: past 250, but inside the five characters of leeway Jinja's
# truncate grants by default, so the row also proves that leeway is off. Forty
# change lines of about 90 characters put the body past 1024.
LONG_NAMES = (1..40).map { |index| format("service-%02d-%s", index, "x" * 66) }
LONG_HEADLINE = "NAS deployed: #{LONG_NAMES.first(3).join(', ')} +37"
LONG_PREVIOUS = LONG_NAMES.to_h { |name| [name, { name => "docker.io/example/#{name}:1.0.0#{DIGEST_A}" }] }
LONG_CURRENT = LONG_NAMES.to_h { |name| [name, { name => "docker.io/example/#{name}:2.0.0#{DIGEST_B}" }] }

with_controller_repository do |directory, repository, previous, current|
  deploy_root = File.join(directory, "deploy")
  write_release(deploy_root, previous, PREVIOUS_IMAGES)
  release_dir = write_release(deploy_root, current, CURRENT_IMAGES)

  base = lambda do |port, overrides|
    {
      "platform_deploy_root" => deploy_root,
      "platform_release_dir" => release_dir,
      "platform_release_id" => current,
      "ntfy_deployment_summary_checkout" => repository,
      "ntfy_deployment_pushover_api_url" => endpoint(port),
      "vault_pushover_token" => TOKEN,
      "vault_pushover_user_key" => USER_KEY
    }.merge(overrides)
  end

  with_http_probe(1) do |port, requests|
    _stdout, stderr, status = run_summary(
      base.call(port, "deployment_bundle_previous_release_id" => previous)
    )
    check(failures, status.success?,
          "deployment summary fixture failed: #{stderr.lines.last&.strip}")
    published = requests.first || {}
    form = published["form"] || {}
    message = form["message"].to_s
    check_delivery_form(failures, "the summary", published, "0")
    check(failures, form["title"] == "NAS deployed: jellyfin",
          "the summary title must name what moved: #{form['title'].inspect}")
    check(failures, message.include?("jellyfin 10.10.3 → 10.11.0"),
          "the summary must state the versions a service moved between")
    check(failures, !message.include?("ntfy"),
          "the summary must omit services the release did not move")
    check(failures, message.include?("fix: pin jellyfin 10.11.0") &&
                    message.include?("chore(deps): update immich to v1.122.0"),
          "the summary must carry the commit subjects of the release")
    check(failures, !message.include?("feat: first release"),
          "the summary must carry only the commits this deployment adds")
    check(failures, message.include?(current[0, 12]) && message.include?(previous[0, 12]),
          "the summary must name the release and the one it replaced")
    check(failures, message.start_with?("Images\n- ") && message.include?("\n\nChanges\n- "),
          "the summary must read as plain text lists, not markup: #{message.inspect}")
  end

  # A converge that reinstalls the same revision recreated nothing, and the
  # per-service reports stay silent for it too.
  with_http_probe(0) do |port, _requests|
    _stdout, stderr, status = run_summary(
      base.call(port, "deployment_bundle_previous_release_id" => current)
    )
    check(failures, status.success?,
          "unchanged deployment summary fixture failed: #{stderr.lines.last&.strip}")
  end

  # A selective converge never rebuilds the bundle, so nothing names the release
  # it replaced. Reporting every image as newly installed would be a lie.
  with_http_probe(0) do |port, _requests|
    _stdout, stderr, status = run_summary(base.call(port, {}))
    check(failures, status.success?,
          "selective deployment summary fixture failed: #{stderr.lines.last&.strip}")
  end

  # A first install has no predecessor: every image is genuinely new, and the
  # absent Git range must not fail the run.
  with_http_probe(1) do |port, requests|
    _stdout, stderr, status = run_summary(
      base.call(port, "deployment_bundle_previous_release_id" => "")
    )
    check(failures, status.success?,
          "first-install deployment summary fixture failed: #{stderr.lines.last&.strip}")
    form = (requests.first || {})["form"] || {}
    check(failures, form["title"].to_s.start_with?("NAS deployed: jellyfin"),
          "a first install must report its images as new: #{form['title'].inspect}")
    check(failures, form["message"].to_s.include?("(new)"),
          "a first install must mark its images new rather than moved")
  end

  # Check mode reviews a deployment. Publishing during a review would announce
  # a deployment that never happened.
  with_http_probe(0) do |port, _requests|
    _stdout, stderr, status = run_summary(
      base.call(port, "deployment_bundle_previous_release_id" => previous), "--check"
    )
    check(failures, status.success?,
          "check-mode deployment summary fixture failed: #{stderr.lines.last&.strip}")
  end

  # Over Pushover's limits. Unbounded, this is a 400 with status 0 -- an
  # authoritative refusal that fails the converge after every service already
  # deployed -- so the fixture answers exactly that for an overlong field, and
  # the row proves the cut happened before the request rather than trusting it.
  long_root = File.join(directory, "deploy-long")
  write_release(long_root, previous, LONG_PREVIOUS)
  long_release = write_release(long_root, current, LONG_CURRENT)
  over_limit = lambda do |form|
    form["title"].to_s.length > 250 || form["message"].to_s.length > 1024
  end
  long_requests = []
  with_http_fixture(lambda { |port|
    stdout, stderr, status = run_summary(
      base.call(port, "platform_deploy_root" => long_root, "platform_release_dir" => long_release,
                      "deployment_bundle_previous_release_id" => previous)
    )
    check(failures, status.success?,
          "an overlong summary must be cut, not refused: #{(stdout + stderr).lines.last(3).join.strip}")
  }) do |_method, _target, _headers, body|
    form = URI.decode_www_form(body).to_h
    long_requests << form
    over_limit.call(form) ? [400, JSON.generate({ "status" => 0, "errors" => ["too long"] })] : ACCEPTED
  end
  long_form = long_requests.first || {}
  expected_lines = LONG_NAMES.map { |name| "- #{name} 1.0.0 → 2.0.0" }.join("\n")
  check(failures, long_requests.length == 1 && expected_lines.length > 1024 &&
                  LONG_HEADLINE.length.between?(251, 255),
        "the overlong row must actually overrun both limits to prove anything")
  check(failures, long_form["title"].to_s.length.between?(1, 250) &&
                  long_form["message"].to_s.length.between?(1, 1024),
        "an overlong summary must be cut to 250/1024 characters, got " \
        "#{long_form['title'].to_s.length}/#{long_form['message'].to_s.length}")
  check(failures, long_form["message"].to_s.start_with?("Images\n- service-01-") &&
                  long_form["message"].to_s.end_with?("…") &&
                  long_form["title"].to_s.end_with?("…"),
        "a cut summary must keep its beginning and end with a visible marker")
end

# The per-service report is the detail behind the summary, and only a service
# Compose actually recreated has any detail to give. The summary already says a
# deployment happened and which images it moved, so a service left running
# unchanged publishes nothing rather than one "already current" message per
# service on every release.
RELEASE = "c" * 40
PREDECESSOR = "d" * 40

def report_variables(url, overrides)
  {
    "platform_release_id" => RELEASE,
    "ntfy_deployment_pushover_api_url" => url,
    "vault_pushover_token" => TOKEN,
    "vault_pushover_user_key" => USER_KEY,
    "ntfy_deployment_report_service" => "Komga",
    "ntfy_deployment_report_changed" => false
  }.merge(overrides)
end

def check_report(failures, label, variables_overrides, expected_count, *arguments)
  with_http_probe(expected_count) do |port, requests|
    _stdout, stderr, status = run_report(
      report_variables(endpoint(port), variables_overrides), *arguments
    )
    check(failures, status.success?,
          "#{label} report fixture failed: #{stderr.lines.last&.strip}")
    yield requests.first || {} if block_given?
  end
end

RECREATED = {
  "deployment_bundle_previous_release_id" => PREDECESSOR,
  "ntfy_deployment_report_changed" => true
}.freeze

check_report(failures, "recreated", RECREATED, 1) do |request|
  form = request["form"] || {}
  check_delivery_form(failures, "a service report", request, "-1")
  check(failures, form["title"] == "Komga deployed (recreated)",
        "a recreated service must say so: #{form['title'].inspect}")
  check(failures, form["message"].to_s.include?("Compose recreated Komga") &&
                  form["message"].to_s.include?(RELEASE[0, 12]),
        "a recreated service must name what happened and at which release")
end

# The release moved, but Compose left this service running the image it already
# had. The summary speaks for the release; this service stays quiet.
check_report(failures, "already current", {
               "deployment_bundle_previous_release_id" => PREDECESSOR
             }, 0)

# A converge that reinstalls the installed revision deployed nothing, so only a
# service Compose actually touched has anything to report.
check_report(failures, "unmoved release", {
               "deployment_bundle_previous_release_id" => RELEASE
             }, 0)
check_report(failures, "unmoved release with a recreation", {
               "deployment_bundle_previous_release_id" => RELEASE,
               "ntfy_deployment_report_changed" => true
             }, 1) do |request|
  check(failures, (request["form"] || {})["title"] == "Komga deployed (recreated)",
        "a recreation outside a release move must still be reported")
end

# A selective converge never rebuilds the bundle, so nothing moved.
check_report(failures, "selective converge", {}, 0)

# Check mode reviews a deployment rather than performing one.
check_report(failures, "check mode", RECREATED, 0, "--check")

# --- what Pushover answers, and what the converge makes of it --------------
#
# Run through the report because it is the cheaper caller; the summary includes
# the same task file. The accepted row is asserted by what it does not say: a
# delivered message is silent, and the non-verdict notice appearing would mean
# an answer was misread.
def check_answer(failures, label, output, status, expect_failure:, expect_text:, forbid_text:)
  check(failures, status.success? != expect_failure,
        "#{label} must #{expect_failure ? 'fail' : 'not fail'} the converge")
  check(failures, output.include?(expect_text), "#{label} must report #{expect_text.inspect}") if expect_text
  check(failures, !output.include?(forbid_text), "#{label} must not report #{forbid_text.inspect}") if forbid_text
  [TOKEN, USER_KEY].each do |secret|
    check(failures, !output.include?(secret), "#{label} disclosed a Pushover credential")
  end
end

[
  { label: "a message Pushover accepts", answer: ACCEPTED,
    expect_failure: false, expect_text: nil, forbid_text: NON_VERDICT },
  { label: "a message Pushover authoritatively refuses",
    answer: [400, JSON.generate({ "status" => 0, "errors" => ["application token is invalid"] })],
    expect_failure: true, expect_text: REFUSAL, forbid_text: NON_VERDICT },
  { label: "a 5xx, which is not an answer", answer: [500, JSON.generate({ "status" => 0 })],
    expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL },
  # Pushover's own quota answer: this message was not delivered, but nothing
  # about the credentials was refused.
  { label: "a 429 over the monthly quota", answer: [429, JSON.generate({ "status" => 0 })],
    expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL },
  # A captive portal or proxy, with an authoritative-looking code and no verdict.
  { label: "a 200 carrying HTML", answer: [200, "<html><body>Sign in</body></html>", "text/html"],
    expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL },
  { label: "a 403 carrying HTML", answer: [403, "<html><body>Blocked</body></html>", "text/html"],
    expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL }
].each do |row|
  with_http_probe(1, answer: row.fetch(:answer)) do |port, _requests|
    stdout, stderr, status = run_report(report_variables(endpoint(port), RECREATED))
    check_answer(failures, row.fetch(:label), stdout + stderr, status,
                 **row.slice(:expect_failure, :expect_text, :forbid_text))
  end
end

# The refusal names the keys to fix. Checked apart from the row above so a
# message that lost the key names is its own diagnostic.
with_http_probe(1, answer: [400, JSON.generate({ "status" => 0 })]) do |port, _requests|
  stdout, stderr, = run_report(report_variables(endpoint(port), RECREATED))
  output = stdout + stderr
  check(failures, output.include?("vault_pushover_token") && output.include?("vault_pushover_user_key"),
        "a refusal must name vault_pushover_token and vault_pushover_user_key")
end

closed_port = begin
  probe = TCPServer.new("127.0.0.1", 0)
  probe.addr.fetch(1)
ensure
  probe&.close
end
# An outage, and the #521 shape: a uri that refuses before it makes any request
# registers no status at all, which must read as no verdict rather than as a
# refusal.
{
  "a Pushover that refuses the connection" => "http://127.0.0.1:#{closed_port}#{ENDPOINT_PATH}",
  "a url the module refuses to parse" => "not-a-url-at-all"
}.each do |label, url|
  stdout, stderr, status = run_report(report_variables(url, RECREATED))
  check_answer(failures, label, stdout + stderr, status,
               expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL)
end

# --- every site.yml caller under tests/ redirects the endpoint -------------
#
# The role default is Pushover itself, and the Mac lane converges with the
# operator's real vault, so a caller that loses its override pushes a
# notification to the household's devices for every service a lane recreates.
# Read out of the function each lane converges through, so a line moved outside
# it does not satisfy the check. tests/mac/run.sh and the Mac drift hooks reach
# site.yml only through mac_ansible_playbook, and tests/integration_controller.sh
# only through run_play.
DEPLOYMENT_ENDPOINT_OVERRIDES = {
  "tests/integration_controller_lib.sh" => [
    /^run_play\(\) \{\n(.*?)^\}/m,
    /-e ntfy_deployment_pushover_api_url="\$integration_deployment_pushover_api_url"/,
    %r{^integration_deployment_pushover_api_url='http://127\.0\.0\.1:1/1/messages\.json'$}
  ],
  "tests/mac/lib.sh" => [
    /^mac_ansible_playbook\(\) \{\n(.*?)^\}/m,
    %r{-e 'ntfy_deployment_pushover_api_url=http://127\.0\.0\.1:1/1/messages\.json'},
    nil
  ]
}.freeze

DEPLOYMENT_ENDPOINT_OVERRIDES.each do |relative, (function, argument, value)|
  source = File.read(File.join(ROOT, relative))
  body = source[function, 1].to_s
  check(failures, body.match?(argument) && (value.nil? || source.match?(value)),
        "#{relative} converges site.yml without redirecting ntfy_deployment_pushover_api_url " \
        "away from Pushover; every recreated service would notify real devices")
end

if failures.empty?
  puts "Deployment record: only a recreated service reports, one summary says what " \
       "shipped, and only an authoritative Pushover refusal fails the converge"
else
  failures.each { |failure| puts "FAIL #{failure}" }
  puts "#{failures.length} deployment summary violation(s)"
  exit 1
end
