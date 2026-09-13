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
# One sentinel per application, so a message sent with the wrong application's
# token is visible as that token rather than as "a token".
CONTAINERS_TOKEN = "probe-pushover-containers-token-never-valid"
DEPLOYMENTS_TOKEN = "probe-pushover-deployments-token-never-valid"
ALERTS_TOKEN = "probe-pushover-alerts-token-never-valid"
TOKENS = {
  "vault_pushover_alerts_token" => ALERTS_TOKEN,
  "vault_pushover_containers_token" => CONTAINERS_TOKEN,
  "vault_pushover_deployments_token" => DEPLOYMENTS_TOKEN
}.freeze
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

# The form every delivery must be, whichever message it carries. `token` names
# the vault variable whose sentinel must arrive; `extras` is the exact set of
# optional fields (html, ttl) the caller sends, so a field that leaks into the
# other caller is as visible as one that goes missing.
def check_delivery_form(failures, label, request, priority, token:, extras: {})
  form = request["form"] || {}
  check(failures, request["method"] == "POST" && request["target"] == ENDPOINT_PATH,
        "#{label} must POST to the Pushover message API, got " \
        "#{request['method']} #{request['target']}")
  check(failures, request.dig("headers", "content-type").to_s
                         .start_with?("application/x-www-form-urlencoded"),
        "#{label} must be a form POST, which is what Pushover's API reads")
  sent_with = TOKENS.key(form["token"]) || form["token"].inspect
  check(failures, form["token"] == TOKENS.fetch(token) && form["user"] == USER_KEY,
        "#{label} must carry #{token} as token and vault_pushover_user_key as user, " \
        "got #{sent_with}")
  check(failures, form["priority"] == priority,
        "#{label} must be sent at Pushover priority #{priority}, got #{form['priority'].inspect}")
  check(failures, (form.keys & %w[topic tags]).empty?,
        "#{label} must carry no ntfy-only field: #{form.keys.inspect}")
  check(failures, form.slice("html", "ttl") == extras,
        "#{label} must send exactly #{extras.inspect} of html and ttl, got #{form.slice('html', 'ttl').inspect}")
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
      "vault_pushover_user_key" => USER_KEY
    }.merge(TOKENS).merge(overrides)
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
    check_delivery_form(failures, "the summary", published, "0",
                        token: "vault_pushover_deployments_token")
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

  # A refused summary names the Deployments token, the one it was sent with.
  with_http_probe(1, answer: [400, JSON.generate({ "status" => 0 })]) do |port, _requests|
    stdout, stderr, status = run_summary(
      base.call(port, "deployment_bundle_previous_release_id" => previous)
    )
    output = stdout + stderr
    check(failures, !status.success? && output.include?("Check vault_pushover_deployments_token against") &&
                    !output.include?("vault_pushover_containers_token"),
          "a refused summary must fail naming vault_pushover_deployments_token and no other token")
    check(failures, TOKENS.values.none? { |secret| output.include?(secret) },
          "a refused summary disclosed a Pushover token")
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
    "vault_pushover_user_key" => USER_KEY,
    "ntfy_deployment_report_service" => "Komga",
    "ntfy_deployment_report_changed" => false
  }.merge(TOKENS).merge(overrides)
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

REPORT_EXTRAS = { "html" => "1", "ttl" => "86400" }.freeze

check_report(failures, "recreated", RECREATED, 1) do |request|
  form = request["form"] || {}
  check_delivery_form(failures, "a service report", request, "-1",
                      token: "vault_pushover_containers_token", extras: REPORT_EXTRAS)
  check(failures, form["title"] == "Komga deployed (recreated)",
        "a recreated service must say so: #{form['title'].inspect}")
  check(failures, form["message"] == "<b>Komga</b>\nCompose recreated it at release #{RELEASE[0, 12]}",
        "a recreated service must name itself in bold and the release it was recreated at: " \
        "#{form['message'].inspect}")
end

# The message is HTML, so a service name is text inside markup rather than
# markup, and the title -- which Pushover never parses -- stays as written.
HOSTILE_SERVICE = %(Paperless & "Tika" <i>'x'</i>)
check_report(failures, "a service name carrying markup",
             RECREATED.merge("ntfy_deployment_report_service" => HOSTILE_SERVICE), 1) do |request|
  form = request["form"] || {}
  check(failures, form["title"] == "#{HOSTILE_SERVICE} deployed (recreated)",
        "the report title must stay plain text: #{form['title'].inspect}")
  check(failures, form["message"].to_s.start_with?(
    "<b>Paperless &amp; &#34;Tika&#34; &lt;i&gt;&#39;x&#39;&lt;/i&gt;</b>\n"
  ), "every value in the report's HTML must be escaped: #{form['message'].inspect}")
  check(failures, form["message"].to_s.scan("<").length == 2,
        "the report's only markup must be its own <b></b>: #{form['message'].inspect}")
end

# Escaping expands, and a cut after escaping can split an entity or the closing
# tag. The name is cut first, so even a name made of nothing but ampersands
# arrives whole: complete entities, a closed tag, under Pushover's cap, and never
# reaching the publish task's own cut.
check_report(failures, "a service name long enough to overrun the message",
             RECREATED.merge("ntfy_deployment_report_service" => "&" * 300), 1) do |request|
  message = (request["form"] || {})["message"].to_s
  check(failures, message.length <= 1024 && !message.include?("…"),
        "an overlong service name must be bounded before escaping, not cut after: #{message.length}")
  check(failures, message.start_with?("<b>#{'&amp;' * 128}</b>\n"),
        "an overlong service name must keep whole entities and its closing tag: #{message[0, 40].inspect}")
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
  [*TOKENS.values, USER_KEY].each do |secret|
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
    expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL },
  # Pushover's status is an integer. false == 0 and true == 1 in Jinja, and
  # "0" becomes 0 under | int, so each of these would be an invented verdict.
  { label: "a 400 whose status is false", answer: [400, JSON.generate({ "status" => false })],
    expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL },
  { label: "a 400 whose status is the string \"0\"", answer: [400, JSON.generate({ "status" => "0" })],
    expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL },
  { label: "a 200 whose status is true", answer: [200, JSON.generate({ "status" => true })],
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
  check(failures, output.include?("Check vault_pushover_containers_token against") &&
                  output.include?("vault_pushover_user_key"),
        "a refused report must name vault_pushover_containers_token and vault_pushover_user_key")
  check(failures, !output.include?("vault_pushover_deployments_token") &&
                  !output.include?("vault_pushover_alerts_token"),
        "a refused report must not send the operator to another application's token")
  check(failures, TOKENS.values.none? { |secret| output.include?(secret) },
        "a refused report disclosed a Pushover token")
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

# --- the site.yml callers under tests/ redirect the endpoint ---------------
#
# The role default is Pushover itself, and the Mac lane converges with the
# operator's real vault, so a caller that loses its override pushes a
# notification to the household's devices for every service a run recreates.
#
# PINNED, NOT DERIVED, and this covers exactly the three commands below. A scan
# for files that put site.yml into an ansible-playbook argv was tried and does
# not hold: the two lane wrappers receive the playbook through a variable, so
# they carry no site.yml literal, while the poller's tests and the docs tests
# carry one without converging anything. A new caller has to be added here by
# hand. Known callers and how each reaches one of these three commands:
#   * tests/integration.sh -> tests/integration_controller.sh -> run_play
#   * tests/mac/run.sh, tests/mac/hooks/drift/20-dozzle.sh and 40-komga.sh ->
#     mac_ansible_playbook
#   * tests/contracts/audiobookshelf-runtime.rb's inactive-administrator mode ->
#     its own audiobookshelf_playbook_command
# Every other ansible-playbook call under tests/ runs verify.yml, which cannot
# reach the report, or a fixture playbook. Read out of the function each command
# is built in, so a line moved outside it does not satisfy the check.
LANE_ENDPOINT = "http://127.0.0.1:1/1/messages.json"
DEPLOYMENT_ENDPOINT_OVERRIDES = {
  "tests/integration_controller_lib.sh" => [
    /^run_play\(\) \{\n(.*?)^\}/m,
    /-e ntfy_deployment_pushover_api_url="\$integration_deployment_pushover_api_url"/,
    /^integration_deployment_pushover_api_url='#{Regexp.escape(LANE_ENDPOINT)}'$/
  ],
  "tests/mac/lib.sh" => [
    /^mac_ansible_playbook\(\) \{\n(.*?)^\}/m,
    /-e 'ntfy_deployment_pushover_api_url=#{Regexp.escape(LANE_ENDPOINT)}'/,
    nil
  ],
  "tests/contracts/audiobookshelf-runtime.rb" => [
    /^def audiobookshelf_playbook_command\(playbook, tags\)\n(.*?)^end/m,
    /"-e", "ntfy_deployment_pushover_api_url=#{Regexp.escape(LANE_ENDPOINT)}"/,
    nil
  ]
}.freeze

DEPLOYMENT_ENDPOINT_OVERRIDES.each do |relative, (function, argument, value)|
  source = File.read(File.join(ROOT, relative))
  body = source[function, 1]
  check(failures, body,
        "#{relative} no longer defines the function this check reads its site.yml command from")
  next unless body

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
