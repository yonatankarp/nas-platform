#!/usr/bin/env ruby
# frozen_string_literal: true

# The deployment record is what a human actually reads after a deployment, so
# what it says — and when it stays silent — is a contract. Two messages make it
# up: one per-service report, and the run-level summary behind them.

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

require_relative "policy_support"
require_relative "http_fixture_support"

include HttpFixtureSupport
include TestScaffold

DIGEST_A = "@sha256:#{'a' * 64}"
DIGEST_B = "@sha256:#{'b' * 64}"
TOKEN = "tk_fixturedeploytokenvalue"

failures = []

# The record is a fire-and-forget POST, so the probe only has to accept it and
# say nothing back: no Content-Type and no body. What the test reads afterwards
# is what arrived.
def with_http_probe(expected_count, &block)
  requests = []
  with_http_fixture(->(port) { block.call(port, requests) },
                    content_type: nil) do |method, target, headers, body|
    requests << { "method" => method, "target" => target, "headers" => headers, "body" => body }
    200
  end
  raise "deployment record probe request count differs: #{requests.length}" unless
    requests.length == expected_count
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

PREVIOUS_IMAGES = {
  "jellyfin" => { "jellyfin" => "docker.io/jellyfin/jellyfin:10.10.3#{DIGEST_A}" },
  "ntfy" => { "ntfy" => "docker.io/binwiederhier/ntfy:v2.28.0#{DIGEST_A}" }
}.freeze
CURRENT_IMAGES = {
  "jellyfin" => { "jellyfin" => "docker.io/jellyfin/jellyfin:10.11.0#{DIGEST_B}" },
  "ntfy" => { "ntfy" => "docker.io/binwiederhier/ntfy:v2.28.0#{DIGEST_A}" }
}.freeze

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
      "ntfy_port" => port,
      "vault_ntfy_deploy_token" => TOKEN
    }.merge(overrides)
  end

  with_http_probe(1) do |port, requests|
    _stdout, stderr, status = run_summary(
      base.call(port, "deployment_bundle_previous_release_id" => previous)
    )
    check(failures, status.success?,
          "deployment summary fixture failed: #{stderr.lines.last&.strip}")
    published = requests.first || {}
    document = begin
      JSON.parse(published["body"].to_s)
    rescue JSON::ParserError
      {}
    end
    message = document["message"].to_s
    check(failures, published["method"] == "POST" && published["target"] == "/",
          "the summary must POST its document to the ntfy root, not to a topic path")
    check(failures, published.dig("headers", "authorization") == "Bearer #{TOKEN}",
          "the summary must publish with the deploy publisher's write-only token")
    check(failures, document["topic"] == "nas-deployment",
          "the summary belongs on the deployment topic, not the critical one")
    check(failures, document["title"] == "NAS deployed: jellyfin",
          "the summary title must name what moved: #{document['title'].inspect}")
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
    document = begin
      JSON.parse((requests.first || {})["body"].to_s)
    rescue JSON::ParserError
      {}
    end
    check(failures, document["title"].to_s.start_with?("NAS deployed: jellyfin"),
          "a first install must report its images as new: #{document['title'].inspect}")
    check(failures, document["message"].to_s.include?("(new)"),
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
end

# The per-service report is the detail behind the summary, and only a service
# Compose actually recreated has any detail to give. The summary already says a
# deployment happened and which images it moved, so a service left running
# unchanged publishes nothing rather than one "already current" message per
# service on every release.
RELEASE = "c" * 40
PREDECESSOR = "d" * 40

def report_variables(port, overrides)
  {
    "platform_release_id" => RELEASE,
    "ntfy_port" => port,
    "vault_ntfy_deploy_token" => TOKEN,
    "ntfy_deployment_report_service" => "Komga",
    "ntfy_deployment_report_changed" => false
  }.merge(overrides)
end

def published_report(requests)
  JSON.parse((requests.first || {})["body"].to_s)
rescue JSON::ParserError
  {}
end

def check_report(failures, label, variables_overrides, expected_count, *arguments)
  with_http_probe(expected_count) do |port, requests|
    _stdout, stderr, status = run_report(
      report_variables(port, variables_overrides), *arguments
    )
    check(failures, status.success?,
          "#{label} report fixture failed: #{stderr.lines.last&.strip}")
    yield published_report(requests) if block_given?
  end
end

check_report(failures, "recreated", {
               "deployment_bundle_previous_release_id" => PREDECESSOR,
               "ntfy_deployment_report_changed" => true
             }, 1) do |document|
  check(failures, document["topic"] == "nas-deployment",
        "a service report belongs on the deployment topic")
  check(failures, document["title"] == "Komga deployed (recreated)",
        "a recreated service must say so: #{document['title'].inspect}")
  check(failures, document["message"].to_s.include?("Compose recreated Komga") &&
                  document["message"].to_s.include?(RELEASE[0, 12]),
        "a recreated service must name what happened and at which release")
  check(failures, document["priority"] == 2,
        "a service report stays below the run summary it details")
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
             }, 1) do |document|
  check(failures, document["title"] == "Komga deployed (recreated)",
        "a recreation outside a release move must still be reported")
end

# A selective converge never rebuilds the bundle, so nothing moved.
check_report(failures, "selective converge", {}, 0)

# Check mode reviews a deployment rather than performing one.
check_report(failures, "check mode", {
               "deployment_bundle_previous_release_id" => PREDECESSOR,
               "ntfy_deployment_report_changed" => true
             }, 0, "--check")

if failures.empty?
  puts "Deployment record: only a recreated service reports, " \
       "and one summary says what shipped"
else
  failures.each { |failure| puts "FAIL #{failure}" }
  puts "#{failures.length} deployment summary violation(s)"
  exit 1
end
