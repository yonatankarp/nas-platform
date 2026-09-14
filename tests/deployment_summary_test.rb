#!/usr/bin/env ruby
# frozen_string_literal: true

# The deployment record is what a human actually reads after a deployment, so
# what it says — and when it stays silent — is a contract. Two pieces make it
# up: one per-service report, delivered to Pushover by
# roles/deployment_bundle/tasks/pushover_publish.yml, and the run-level summary
# behind them, which site.yml only ever hands to the deployment poller as JSON
# (#558 stage 4a removed the plain summary it used to publish). The second half
# of this file runs the delivery against a local fixture speaking Pushover's
# shapes: an authoritative refusal fails the converge, and nothing that is not
# an answer does.

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
  # nil leaves the count to the row, whose own check can say what an extra
  # request means rather than aborting the file before it reports.
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
    # The pin lands in a Compose file beside an unrelated one, as it does in
    # services/arr/compose.yml, so only a search for the exact reference can
    # name the commit that introduced it.
    FileUtils.mkdir_p(File.join(repository, "services", "media"))
    File.write(File.join(repository, "services", "media", "compose.yml"),
               "image: #{CURRENT_IMAGES.dig('jellyfin', 'jellyfin')}\n" \
               "image: #{PREVIOUS_IMAGES.dig('pinchflat', 'pinchflat')}\n")
    run.call("add", "services")
    run.call("commit", "-qm", "fix: pin jellyfin 10.11.0")
    introducing = Open3.capture3("git", "-C", repository, "rev-parse", "HEAD").first.strip
    # A later document quoting the same pin is the newest commit the reference
    # appears in, and must not be mistaken for the one that moved the image.
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

# What summary.yml says when it cannot hand the poller its summary.
UNANNOUNCED = "so the deployment poller will not announce this release"

SUMMARY_PATH_VARIABLE = "PLATFORM_DEPLOYMENT_SUMMARY_PATH"

# Unset unless a row sets it, so a variable in the shell running this file can
# never turn the plain-summary rows into poller rows.
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

# The shared delivery on its own. The report bounds its own message before the
# delivery sees it, so the delivery's cut and its refusal naming are exercised
# here directly rather than through a caller that can no longer reach them.
def run_publish(variables, *arguments)
  run_bundle_task("pushover_publish", variables, *arguments)
end

# What summary.yml says when no poller asked for the summary.
UNREQUESTED = "no deployment poller asked for this run's summary"

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

# A Renovate batch in miniature, sized so both halves overrun Pushover's limits
# by construction. The title is three 77-character names plus "+37", which is
# 253 characters: past 250, but inside the five characters of leeway Jinja's
# truncate grants by default, so the row also proves that leeway is off. Forty
# change lines of about 90 characters put the body past 1024.
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

  # With the variable unset -- an operator converge, a workstation run -- a moved
  # release publishes nothing and writes nothing (#558 stage 4a). Both halves are
  # asserted: a request would be the plain summary back, and a file would be a
  # summary written for a poller that is not there.
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
  #
  # The poller alone sets the variable, and with it set this file writes the
  # summary and publishes NOTHING: the poller sends the one message once verify
  # passes. Unset -- an operator converge, or a poller older than the variable --
  # the rows above send and write nothing. At most one message either way.
  summary_path = File.join(directory, "state", "deployment-summary.json")
  FileUtils.mkdir_p(File.dirname(summary_path))
  poller_environment = { SUMMARY_PATH_VARIABLE => summary_path }
  read_summary = lambda do
    File.exist?(summary_path) ? JSON.parse(File.read(summary_path)) : nil
  end
  # Every poller row counts its own requests, so a publish that leaked past the
  # variable is named here rather than aborting the file in the probe.
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
    # The contract has two halves in two languages, and each suite asserts its
    # own copy of the shape. This is the one place they meet: the poller's own
    # reader must accept exactly what this play just wrote, or a drift on either
    # side sends nothing with both suites green. The poller is stdlib-only.
    reader = "import pathlib, sys; sys.path.insert(0, sys.argv[1]); import production_auto_deploy as p; " \
             "p.read_release_summary(pathlib.Path(sys.argv[2]), sys.argv[3])"
    refusal, accepted = Open3.capture2e("python3", "-B", "-c", reader, File.join(ROOT, "scripts"),
                                        summary_path, current)
    check(failures, accepted.success?,
          "scripts/production_auto_deploy.py refuses the summary summary.yml just wrote, " \
          "so the poller would announce nothing: #{refusal.lines.last&.strip}")
  end

  # Nothing moved, a review, or a selective converge: nothing to announce, and no
  # file that could be mistaken for one.
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

  # A first install names no predecessor, has no Git range to read, and so no
  # commit for any image.
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

  # A summary that cannot be written is a notification lost, never a deployment
  # failed: every service has converged by now, and a fatal write would skip
  # verify and the poller's reinstall. Each case measured fatal before the rescue.
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

  # A refusal names the token the caller chose and no other. The summary was the
  # caller that sent with the Deployments token until stage 4a, so the delivery
  # is driven with that name directly.
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
  # Driven through the delivery directly since stage 4a: the plain summary was
  # the caller whose body was unbounded, and the report bounds its own.
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
    "deployment_pushover_api_url" => url,
    "vault_pushover_user_key" => USER_KEY,
    "deployment_report_service" => "Komga",
    "deployment_report_changed" => false
  }.merge(TOKENS).merge(overrides)
end

# The report's When line is the controller's clock at render time, so a row
# accepts any minute between just before the play started and just after it
# ended, in the exact form the report writes.
def report_minutes(started, finished)
  (((started.to_i / 60) - 1)..((finished.to_i / 60) + 1)).map do |minute|
    Time.at(minute * 60).utc.strftime("%d %b %H:%M UTC")
  end
end

# The closing pointer, present only when the poller asked for the summary and
# the release moved -- the run that will actually produce a Deployments message.
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

# Under the poller, on a moved release, the Deployments message will exist, and
# the report says where the rest of the release is.
check_report(failures, "recreated under the poller", RECREATED, 1,
             environment: POLLER_ASKED) do |request, started, finished|
  form = request["form"] || {}
  check(failures, report_lines("Komga", RELEASE, started, finished, details: true).include?(form["message"]),
        "a recreation the poller will announce must end by pointing at the Deployments message: " \
        "#{form['message'].inspect}")
end

# The message is HTML, so a service name is text inside markup rather than
# markup, and the title -- which Pushover never parses -- stays as written.
HOSTILE_SERVICE = %(Paperless & "Tika" <i>'x'</i>)
check_report(failures, "a service name carrying markup",
             RECREATED.merge("deployment_report_service" => HOSTILE_SERVICE), 1) do |request, started, finished|
  form = request["form"] || {}
  check(failures, form["title"] == "♻️ #{HOSTILE_SERVICE} recreated",
        "the report title must stay plain text: #{form['title'].inspect}")
  escaped = "Paperless &amp; &#34;Tika&#34; &lt;i&gt;&#39;x&#39;&lt;/i&gt;"
  check(failures, report_lines(escaped, RELEASE, started, finished).include?(form["message"]),
        "every value in the report's HTML must be escaped: #{form['message'].inspect}")
  # Six elements of its own -- <b> and <font> on each of three lines -- and not
  # one more from the name.
  check(failures, form["message"].to_s.scan("<").length == 12,
        "the report's only markup must be its own: #{form['message'].inspect}")
end

# Escaping expands, and a cut after escaping can split an entity or the closing
# tag. The name is cut first, so even a name made of nothing but ampersands
# arrives whole: complete entities, a closed tag, under Pushover's cap, and never
# reaching the publish task's own cut.
check_report(failures, "a service name long enough to overrun the message",
             RECREATED.merge("deployment_report_service" => "&" * 300), 1) do |request, started, finished|
  message = (request["form"] || {})["message"].to_s
  check(failures, message.length <= 1024 && !message.include?("…"),
        "an overlong service name must be bounded before escaping, not cut after: #{message.length}")
  check(failures, report_lines("&amp;" * 128, RELEASE, started, finished).include?(message),
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
               "deployment_report_changed" => true
             }, 1, environment: POLLER_ASKED) do |request, started, finished|
  form = request["form"] || {}
  check(failures, form["title"] == "♻️ Komga recreated",
        "a recreation outside a release move must still be reported")
  check(failures, report_lines("Komga", RELEASE, started, finished).include?(form["message"]),
        "a recreation outside a release move gets no Deployments message even under the poller, so " \
        "the report must not point at one: #{form['message'].inspect}")
end

# A selective converge never rebuilds the bundle, so nothing moved.
check_report(failures, "selective converge", {}, 0)

# Check mode reviews a deployment rather than performing one.
check_report(failures, "check mode", RECREATED, 0, "--check")

# --- what Pushover answers, and what the converge makes of it --------------
#
# Run through the report, the delivery's one caller since #558 stage 4a. The accepted row is asserted by what it does not say: a
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
