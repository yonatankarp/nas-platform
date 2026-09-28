#!/usr/bin/env ruby
# frozen_string_literal: true

# The per-service deployment report delivered to Pushover, the run-level summary handed
# to the poller as JSON, and how the delivery reads Pushover's answers.

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
# Sentinels, one per application, so a wrong application's token is visible as that token.
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

def with_http_probe(expected_count, answer: ACCEPTED, &block)
  requests = []
  with_http_fixture(->(port) { block.call(port, requests) }) do |method, target, headers, body|
    requests << { "method" => method, "target" => target, "headers" => headers,
                  "form" => URI.decode_www_form(body).to_h }
    answer
  end
  raise "deployment record probe request count differs: #{requests.length}" unless
    expected_count.nil? || requests.length == expected_count
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

# A real repository: the summary reads commit subjects from the controller checkout.
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
    # Beside an unrelated pin, so only an exact-reference search names the right commit.
    FileUtils.mkdir_p(File.join(repository, "services", "media"))
    File.write(File.join(repository, "services", "media", "compose.yml"),
               "image: #{CURRENT_IMAGES.dig('jellyfin', 'jellyfin')}\n" \
               "image: #{PREVIOUS_IMAGES.dig('pinchflat', 'pinchflat')}\n")
    run.call("add", "services")
    run.call("commit", "-qm", "fix: pin jellyfin 10.11.0")
    introducing = Open3.capture3("git", "-C", repository, "rev-parse", "HEAD").first.strip
    FileUtils.mkdir_p(File.join(repository, "docs"))
    File.write(File.join(repository, "docs", "service-dossiers.md"),
               "Jellyfin runs #{CURRENT_IMAGES.dig('jellyfin', 'jellyfin')}\n")
    run.call("add", "docs")
    run.call("commit", "-qm", "docs: record the jellyfin pin")
    documenting = Open3.capture3("git", "-C", repository, "rev-parse", "HEAD").first.strip
    File.write(File.join(repository, "README"), "third\n")
    run.call("commit", "-qam", "chore(deps): update immich to v1.122.0")
    current = Open3.capture3("git", "-C", repository, "rev-parse", "HEAD").first.strip
    yield directory, repository, previous, current, introducing, documenting
  end
end

UNANNOUNCED = "so the deployment poller will not announce this release"

SUMMARY_PATH_VARIABLE = "PLATFORM_DEPLOYMENT_SUMMARY_PATH"

# Unset unless a row sets it, so the caller's shell cannot turn these into poller rows.
def run_bundle_task(tasks_from, variables, *arguments, environment: { SUMMARY_PATH_VARIABLE => nil })
  report = [{
    "name" => "Report the deployment",
    "ansible.builtin.include_role" => { "name" => "deployment_bundle", "tasks_from" => tasks_from }
  }]
  run_playbook(report, variables, *arguments, environment: environment,
                                              prefix: "nas-platform-deployment-summary-play-")
end

def run_summary(variables, *arguments, **options)
  run_bundle_task("summary", variables, *arguments, **options)
end

def run_report(variables, *arguments, **options)
  run_bundle_task("report", variables, *arguments, **options)
end

# The delivery on its own: the report bounds its message before the delivery sees it.
def run_publish(variables, *arguments)
  run_bundle_task("pushover_publish", variables, *arguments)
end

UNREQUESTED = "no deployment poller asked for this run's summary"

# `extras` is the exact set of optional fields the caller sends, so a leak is as
# visible as a loss.
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
        "#{label} must carry no topic or tags field, which Pushover does not read: #{form.keys.inspect}")
  check(failures, form.slice("html", "ttl") == extras,
        "#{label} must send exactly #{extras.inspect} of html and ttl, got #{form.slice('html', 'ttl').inspect}")
  check(failures, !form["message"].to_s.strip.empty? && !form["title"].to_s.strip.empty?,
        "#{label} must never send an empty title or message; Pushover refuses one")
end

PREVIOUS_IMAGES = {
  "jellyfin" => { "jellyfin" => "docker.io/jellyfin/jellyfin:10.10.3#{DIGEST_A}" },
  "pinchflat" => { "pinchflat" => "ghcr.io/kieraneglin/pinchflat:v2.28.0#{DIGEST_A}" }
}.freeze
CURRENT_IMAGES = {
  "jellyfin" => { "jellyfin" => "docker.io/jellyfin/jellyfin:10.11.0#{DIGEST_B}" },
  "pinchflat" => { "pinchflat" => "ghcr.io/kieraneglin/pinchflat:v2.28.0#{DIGEST_A}" }
}.freeze

# Sized so both halves overrun Pushover's limits: a 253-character title (past 250 but
# inside Jinja truncate's default leeway, so the leeway must be off) and a body past 1024.
LONG_NAMES = (1..40).map { |index| format("service-%02d-%s", index, "x" * 66) }
LONG_HEADLINE = "NAS deployed: #{LONG_NAMES.first(3).join(', ')} +37"

with_controller_repository do |directory, repository, previous, current, introducing, documenting|
  deploy_root = File.join(directory, "deploy")
  write_release(deploy_root, previous, PREVIOUS_IMAGES)
  release_dir = write_release(deploy_root, current, CURRENT_IMAGES)

  base = lambda do |port, overrides|
    {
      "platform_deploy_root" => deploy_root,
      "platform_release_dir" => release_dir,
      "platform_release_id" => current,
      "deployment_summary_checkout" => repository,
      "deployment_pushover_api_url" => endpoint(port),
      "vault_pushover_user_key" => USER_KEY
    }.merge(TOKENS).merge(overrides)
  end

  # Unset (an operator converge), a moved release publishes nothing and writes nothing (#558).
  [["a moved release", previous], ["a first install", ""]].each do |label, predecessor|
    before = Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).sort
    with_http_probe(nil) do |port, requests|
      stdout, stderr, status = run_summary(
        base.call(port, "deployment_bundle_previous_release_id" => predecessor)
      )
      check(failures, status.success?,
            "#{label} without a poller: summary fixture failed: #{stderr.lines.last&.strip}")
      check(failures, requests.empty?,
            "#{label} without a poller: the summary published although nothing asked for it, " \
            "which is the plain summary back: #{requests.map { |r| r.dig('form', 'title') }.inspect}")
      check(failures, stdout.include?(UNREQUESTED),
            "#{label} without a poller must say no summary is written or sent")
    end
    after = Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).sort
    check(failures, after == before,
          "#{label} without a poller wrote #{(after - before).inspect}; with the variable unset the " \
          "summary must write nothing")
  end

  # --- the poller's half of the handshake (#558) -----------------------------
  # With the variable set this writes the summary and publishes nothing; the poller sends it.
  summary_path = File.join(directory, "state", "deployment-summary.json")
  FileUtils.mkdir_p(File.dirname(summary_path))
  poller_environment = { SUMMARY_PATH_VARIABLE => summary_path }
  read_summary = lambda do
    File.exist?(summary_path) ? JSON.parse(File.read(summary_path)) : nil
  end
  check_unpublished = lambda do |label, requests|
    check(failures, requests.empty?,
          "#{label}: summary.yml published although the poller asked for the summary; " \
          "the release would be announced twice: #{requests.map { |r| r.dig('form', 'title') }.inspect}")
  end

  with_http_probe(nil) do |port, requests|
    stdout, stderr, status = run_summary(
      base.call(port, "deployment_bundle_previous_release_id" => previous),
      environment: poller_environment
    )
    check(failures, status.success?,
          "poller deployment summary fixture failed: #{stderr.lines.last&.strip}")
    check_unpublished.call("a moved release", requests)
    check(failures, !stdout.include?(UNANNOUNCED),
          "a summary that was written must not be reported as unannounced")
    check(failures, File.exist?(summary_path) && (File.stat(summary_path).mode & 0o777) == 0o600,
          "the poller's summary must be written at mode 0600")
    check(failures, read_summary.call == {
      "version" => 1, "release" => current, "previous" => previous,
      "images" => [{ "name" => "jellyfin", "kind" => "updated", "from" => "10.10.3",
                     "to" => "10.11.0", "commit" => introducing }],
      "commits" => [{ "sha" => current, "subject" => "chore(deps): update immich to v1.122.0" },
                    { "sha" => documenting, "subject" => "docs: record the jellyfin pin" },
                    { "sha" => introducing, "subject" => "fix: pin jellyfin 10.11.0" }]
    }, "the poller's summary must name each moved image's introducing commit and every commit " \
       "of the release: #{read_summary.call.inspect}")
    image_commit = read_summary.call.to_h.fetch("images", [{}]).first.to_h["commit"]
    check(failures, image_commit != documenting,
          "the image's commit is the later document that quotes its pin, not the Compose change " \
          "that moved it, so its release-notes link would open the wrong pull request")
    written = File.read(summary_path)
    check(failures, TOKENS.values.none? { |secret| written.include?(secret) } && !written.include?(USER_KEY),
          "the poller's summary must carry no Pushover credential")
    # The one place both languages' copies of the shape meet: the poller must read exactly
    # what this play wrote. The poller is stdlib-only.
    reader = "import pathlib, sys; sys.path.insert(0, sys.argv[1]); import production_auto_deploy as p; " \
             "p.read_release_summary(pathlib.Path(sys.argv[2]), sys.argv[3])"
    refusal, accepted = Open3.capture2e("python3", "-B", "-c", reader, File.join(ROOT, "scripts"),
                                        summary_path, current)
    check(failures, accepted.success?,
          "scripts/production_auto_deploy.py refuses the summary summary.yml just wrote, " \
          "so the poller would announce nothing: #{refusal.lines.last&.strip}")
  end

  [["an unmoved release", { "deployment_bundle_previous_release_id" => current }, []],
   ["check mode", { "deployment_bundle_previous_release_id" => previous }, ["--check"]],
   ["a selective converge", {}, []]].each do |label, overrides, arguments|
    FileUtils.rm_f(summary_path)
    with_http_probe(nil) do |port, requests|
      _stdout, stderr, status = run_summary(base.call(port, overrides), *arguments,
                                            environment: poller_environment)
      check(failures, status.success?, "#{label} poller summary fixture failed: #{stderr.lines.last&.strip}")
      check_unpublished.call(label, requests)
    end
    check(failures, !File.exist?(summary_path), "#{label} must write no poller summary")
  end

  FileUtils.rm_f(summary_path)
  with_http_probe(nil) do |port, requests|
    _stdout, stderr, status = run_summary(
      base.call(port, "deployment_bundle_previous_release_id" => ""), environment: poller_environment
    )
    check(failures, status.success?,
          "first-install poller summary fixture failed: #{stderr.lines.last&.strip}")
    check_unpublished.call("a first install", requests)
  end
  first = read_summary.call || {}
  check(failures, first["previous"] == "" && first["commits"] == [] &&
                  first["images"].to_a.map { |image| [image["kind"], image["commit"]] } ==
                    [["added", nil], ["added", nil]],
        "a first install must write an empty previous, no commits and no image commits: #{first.inspect}")

  # A failed summary write is a lost notification, never a failed deployment: a fatal
  # write would skip verify and the poller's reinstall.
  read_only = File.join(directory, "read-only")
  occupied = File.join(directory, "occupied")
  FileUtils.mkdir_p([read_only, occupied])
  File.chmod(0o500, read_only)
  begin
    [["a missing directory", File.join(directory, "absent", "deployment-summary.json")],
     ["a read-only directory", File.join(read_only, "deployment-summary.json")],
     ["a directory in the summary's place", occupied]].each do |label, path|
      with_http_probe(nil) do |port, requests|
        stdout, stderr, status = run_summary(
          base.call(port, "deployment_bundle_previous_release_id" => previous),
          environment: { SUMMARY_PATH_VARIABLE => path }
        )
        output = stdout + stderr
        check(failures, status.success?,
              "#{label}: a summary that could not be written failed the converge, which marks the " \
              "release failed after every service converged: " \
              "#{output.lines.grep(/fatal|FAILED/).last&.strip}")
        check_unpublished.call(label, requests)
        check(failures, stdout.include?(UNANNOUNCED),
              "#{label}: an unwritten summary must say this release will not be announced")
        check(failures, TOKENS.values.none? { |secret| output.include?(secret) },
              "#{label}: reporting an unwritten summary disclosed a Pushover token")
      end
    end
  ensure
    File.chmod(0o700, read_only)
  end

  with_http_probe(1, answer: [400, JSON.generate({ "status" => 0 })]) do |port, _requests|
    stdout, stderr, status = run_publish(
      base.call(port, "deployment_pushover_token_variable" => "vault_pushover_deployments_token",
                      "deployment_pushover_title" => "a title", "deployment_pushover_message" => "a message",
                      "deployment_pushover_priority" => 0)
    )
    output = stdout + stderr
    check(failures, !status.success? && output.include?("Check vault_pushover_deployments_token against") &&
                    !output.include?("vault_pushover_containers_token"),
          "a refused delivery must fail naming vault_pushover_deployments_token and no other token")
    check(failures, TOKENS.values.none? { |secret| output.include?(secret) },
          "a refused delivery disclosed a Pushover token")
  end

  with_http_probe(0) do |port, _requests|
    _stdout, stderr, status = run_summary(
      base.call(port, "deployment_bundle_previous_release_id" => current)
    )
    check(failures, status.success?,
          "unchanged deployment summary fixture failed: #{stderr.lines.last&.strip}")
  end

  with_http_probe(0) do |port, _requests|
    _stdout, stderr, status = run_summary(base.call(port, {}))
    check(failures, status.success?,
          "selective deployment summary fixture failed: #{stderr.lines.last&.strip}")
  end

  with_http_probe(0) do |port, _requests|
    _stdout, stderr, status = run_summary(
      base.call(port, "deployment_bundle_previous_release_id" => previous), "--check"
    )
    check(failures, status.success?,
          "check-mode deployment summary fixture failed: #{stderr.lines.last&.strip}")
  end

  # Unbounded, this is a 400 with status 0 that fails the converge after every service
  # deployed, so the fixture answers exactly that to an overlong field.
  expected_lines = LONG_NAMES.map { |name| "- #{name} 1.0.0 → 2.0.0" }.join("\n")
  long_requests = []
  with_http_fixture(lambda { |port|
    stdout, stderr, status = run_publish(
      base.call(port, "deployment_pushover_token_variable" => "vault_pushover_deployments_token",
                      "deployment_pushover_title" => LONG_HEADLINE,
                      "deployment_pushover_message" => "Images\n#{expected_lines}",
                      "deployment_pushover_priority" => 0)
    )
    check(failures, status.success?,
          "an overlong notification must be cut, not refused: #{(stdout + stderr).lines.last(3).join.strip}")
  }) do |_method, _target, _headers, body|
    form = URI.decode_www_form(body).to_h
    long_requests << form
    over_limit = form["title"].to_s.length > 250 || form["message"].to_s.length > 1024
    over_limit ? [400, JSON.generate({ "status" => 0, "errors" => ["too long"] })] : ACCEPTED
  end
  long_form = long_requests.first || {}
  check(failures, long_requests.length == 1 && expected_lines.length > 1024 &&
                  LONG_HEADLINE.length.between?(251, 255),
        "the overlong row must actually overrun both limits to prove anything")
  check(failures, long_form["title"].to_s.length.between?(1, 250) &&
                  long_form["message"].to_s.length.between?(1, 1024),
        "an overlong notification must be cut to 250/1024 characters, got " \
        "#{long_form['title'].to_s.length}/#{long_form['message'].to_s.length}")
  check(failures, long_form["message"].to_s.start_with?("Images\n- service-01-") &&
                  long_form["message"].to_s.end_with?("…") &&
                  long_form["title"].to_s.end_with?("…"),
        "a cut notification must keep its beginning and end with a visible marker")
end

# Only a service Compose actually recreated reports; an unchanged one stays silent.
RELEASE = "c" * 40
PREDECESSOR = "d" * 40

def report_variables(url, overrides)
  {
    "platform_release_id" => RELEASE,
    "deployment_pushover_api_url" => url,
    "vault_pushover_user_key" => USER_KEY,
    "deployment_report_service" => "Komga",
    "deployment_report_changed" => false
  }.merge(TOKENS).merge(overrides)
end

# The When line is the controller's clock at render time, so any minute of the play is accepted.
def report_minutes(started, finished)
  (((started.to_i / 60) - 1)..((finished.to_i / 60) + 1)).map do |minute|
    Time.at(minute * 60).utc.strftime("%d %b %H:%M UTC")
  end
end

DETAILS_LINE = "<i>Details are in the Deployments message for this release.</i>"

def report_lines(service, release, started, finished, details: false)
  lead = "<b>#{service}</b> was <font color=\"#2e7d32\">recreated</font> by Compose"
  release_line = "🔖 <b>Release</b> <font color=\"#9e9e9e\">#{release[0, 12]}</font>"
  report_minutes(started, finished).map do |minute|
    "#{lead}\n\n#{release_line}\n🕒 <b>When</b> <font color=\"#9e9e9e\">#{minute}</font>" \
      "#{details ? "\n\n#{DETAILS_LINE}" : ''}"
  end
end

POLLER_ASKED = { SUMMARY_PATH_VARIABLE => "/nonexistent/deployment-summary.json" }.freeze

def check_report(failures, label, variables_overrides, expected_count, *arguments,
                 environment: { SUMMARY_PATH_VARIABLE => nil })
  with_http_probe(expected_count) do |port, requests|
    started = Time.now
    _stdout, stderr, status = run_report(
      report_variables(endpoint(port), variables_overrides), *arguments, environment: environment
    )
    finished = Time.now
    check(failures, status.success?,
          "#{label} report fixture failed: #{stderr.lines.last&.strip}")
    yield requests.first || {}, started, finished if block_given?
  end
end

RECREATED = {
  "deployment_bundle_previous_release_id" => PREDECESSOR,
  "deployment_report_changed" => true
}.freeze

REPORT_EXTRAS = { "html" => "1", "ttl" => "86400" }.freeze

check_report(failures, "recreated", RECREATED, 1) do |request, started, finished|
  form = request["form"] || {}
  check_delivery_form(failures, "a service report", request, "-1",
                      token: "vault_pushover_containers_token", extras: REPORT_EXTRAS)
  check(failures, form["title"] == "♻️ Komga recreated",
        "a recreated service must say so in the platform's style: #{form['title'].inspect}")
  check(failures, report_lines("Komga", RELEASE, started, finished).include?(form["message"]),
        "a hand-run recreation must lead with its bold name and a green verb, then label its release " \
        "and the UTC minute in grey, and end there: #{form['message'].inspect}")
  check(failures, !form["message"].to_s.include?(DETAILS_LINE),
        "a hand-run converge sends no Deployments message, so the report must not point at one: " \
        "#{form['message'].inspect}")
end

check_report(failures, "recreated under the poller", RECREATED, 1,
             environment: POLLER_ASKED) do |request, started, finished|
  form = request["form"] || {}
  check(failures, report_lines("Komga", RELEASE, started, finished, details: true).include?(form["message"]),
        "a recreation the poller will announce must end by pointing at the Deployments message: " \
        "#{form['message'].inspect}")
end

# The message is HTML, so a service name is escaped text; the title is never parsed.
HOSTILE_SERVICE = %(Paperless & "Tika" <i>'x'</i>)
check_report(failures, "a service name carrying markup",
             RECREATED.merge("deployment_report_service" => HOSTILE_SERVICE), 1) do |request, started, finished|
  form = request["form"] || {}
  check(failures, form["title"] == "♻️ #{HOSTILE_SERVICE} recreated",
        "the report title must stay plain text: #{form['title'].inspect}")
  escaped = "Paperless &amp; &#34;Tika&#34; &lt;i&gt;&#39;x&#39;&lt;/i&gt;"
  check(failures, report_lines(escaped, RELEASE, started, finished).include?(form["message"]),
        "every value in the report's HTML must be escaped: #{form['message'].inspect}")
  check(failures, form["message"].to_s.scan("<").length == 12,
        "the report's only markup must be its own: #{form['message'].inspect}")
end

# Escaping expands, so the name is cut first: a cut after escaping can split an entity.
check_report(failures, "a service name long enough to overrun the message",
             RECREATED.merge("deployment_report_service" => "&" * 300), 1) do |request, started, finished|
  message = (request["form"] || {})["message"].to_s
  check(failures, message.length <= 1024 && !message.include?("…"),
        "an overlong service name must be bounded before escaping, not cut after: #{message.length}")
  check(failures, report_lines("&amp;" * 128, RELEASE, started, finished).include?(message),
        "an overlong service name must keep whole entities and its closing tag: #{message[0, 40].inspect}")
end

check_report(failures, "already current", {
               "deployment_bundle_previous_release_id" => PREDECESSOR
             }, 0)

check_report(failures, "unmoved release", {
               "deployment_bundle_previous_release_id" => RELEASE
             }, 0)
check_report(failures, "unmoved release with a recreation", {
               "deployment_bundle_previous_release_id" => RELEASE,
               "deployment_report_changed" => true
             }, 1, environment: POLLER_ASKED) do |request, started, finished|
  form = request["form"] || {}
  check(failures, form["title"] == "♻️ Komga recreated",
        "a recreation outside a release move must still be reported")
  check(failures, report_lines("Komga", RELEASE, started, finished).include?(form["message"]),
        "a recreation outside a release move gets no Deployments message even under the poller, so " \
        "the report must not point at one: #{form['message'].inspect}")
end

check_report(failures, "selective converge", {}, 0)

check_report(failures, "check mode", RECREATED, 0, "--check")

# --- what Pushover answers, and what the converge makes of it --------------
# A delivered message is silent; the non-verdict notice appearing means an answer was misread.
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
  { label: "a 429 over the monthly quota", answer: [429, JSON.generate({ "status" => 0 })],
    expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL },
  # A captive portal or proxy, with an authoritative-looking code and no verdict.
  { label: "a 200 carrying HTML", answer: [200, "<html><body>Sign in</body></html>", "text/html"],
    expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL },
  { label: "a 403 carrying HTML", answer: [403, "<html><body>Blocked</body></html>", "text/html"],
    expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL },
  # false == 0 and true == 1 in Jinja, and "0" | int is 0, so each would invent a verdict.
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

closed_port = refusing_port
# The #521 shape: a uri that refuses before any request registers no status, which is no verdict.
{
  "a Pushover that refuses the connection" => "http://127.0.0.1:#{closed_port}#{ENDPOINT_PATH}",
  "a url the module refuses to parse" => "not-a-url-at-all"
}.each do |label, url|
  stdout, stderr, status = run_report(report_variables(url, RECREATED))
  check_answer(failures, label, stdout + stderr, status,
               expect_failure: false, expect_text: NON_VERDICT, forbid_text: REFUSAL)
end

# --- the site.yml callers under tests/ redirect the endpoint ---------------
# The role default is Pushover and the Mac lane uses the real vault, so a caller losing its
# override notifies the household. Pinned, not derived: a new caller is added here by hand.
LANE_ENDPOINT = "http://127.0.0.1:1/1/messages.json"
DEPLOYMENT_ENDPOINT_OVERRIDES = {
  "tests/integration_controller_lib.sh" => [
    /^run_play\(\) \{\n(.*?)^\}/m,
    /-e deployment_pushover_api_url="\$integration_deployment_pushover_api_url"/,
    /^integration_deployment_pushover_api_url='#{Regexp.escape(LANE_ENDPOINT)}'$/
  ],
  "tests/mac/lib.sh" => [
    /^mac_ansible_playbook\(\) \{\n(.*?)^\}/m,
    /-e 'deployment_pushover_api_url=#{Regexp.escape(LANE_ENDPOINT)}'/,
    nil
  ],
  "tests/contracts/audiobookshelf-runtime.rb" => [
    /^def audiobookshelf_playbook_command\(playbook, tags\)\n(.*?)^end/m,
    /"-e", "deployment_pushover_api_url=#{Regexp.escape(LANE_ENDPOINT)}"/,
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
        "#{relative} converges site.yml without redirecting deployment_pushover_api_url " \
        "away from Pushover; every recreated service would notify real devices")
end

if failures.empty?
  puts "Deployment record: only a recreated service reports, the summary is handed to the " \
       "poller and never published, and only an authoritative Pushover refusal fails the converge"
else
  failures.each { |failure| puts "FAIL #{failure}" }
  puts "#{failures.length} deployment summary violation(s)"
  exit 1
end
