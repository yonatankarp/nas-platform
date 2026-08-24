#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

SCRIPT = File.expand_path("classify_changes.rb", __dir__)
LANES = %w[
  static foundation arr downloaders bindery kapowarr pinchflat trailarr seerr
  smoke beszel dozzle audiobookshelf komga jellyfin immich paperless idempotence_check
].freeze
ACQUISITION_LANES = %w[arr downloaders bindery kapowarr pinchflat trailarr seerr].freeze
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

if File.file?(SCRIPT)
  require_relative "classify_changes"
else
  failures << "classifier script is missing"
end

def selected_lanes(paths, full: false)
  ClassifyChanges.classify(paths, full: full).select { |_lane, selected| selected }.keys
end

if defined?(ClassifyChanges)
  {
    ["docs/getting-started.md"] => [],
    [".gitignore"] => [],
    ["README.md"] => %w[static],
    ["docs/getting-started-nas.md"] => %w[static],
    ["docs/secrets.md"] => %w[static],
    ["roles/paperless_ngx/tasks/main.yml"] => %w[static smoke paperless idempotence_check],
    ["services/dozzle/compose.yml"] => %w[static smoke dozzle idempotence_check],
    ["tests/contracts/jellyfin.sh"] => %w[static smoke jellyfin idempotence_check],
    ["roles/arr/tasks/main.yml"] => %w[static arr idempotence_check],
    ["services/downloaders/compose.yml"] => %w[static downloaders idempotence_check],
    ["tests/expected/bindery.yml"] => %w[static bindery idempotence_check],
    ["tests/contracts/kapowarr-foundation.sh"] => %w[static kapowarr idempotence_check],
    ["config/media-acquisition.yml"] => %w[static arr downloaders bindery kapowarr pinchflat trailarr seerr idempotence_check],
    ["roles/host_prep/tasks/verify_media_acquisition.yml"] => %w[static arr downloaders bindery kapowarr pinchflat trailarr seerr idempotence_check],
    ["roles/deployment_bundle/tasks/main.yml"] => LANES,
    ["unexpected/new-runtime-file"] => LANES
  }.each do |paths, expected|
    check(failures, selected_lanes(paths) == expected,
          "#{paths.join(', ')} selected #{selected_lanes(paths).inspect}, expected #{expected.inspect}")
  end

  ACQUISITION_LANES.each do |project|
    [
      "roles/#{project}/tasks/main.yml",
      "services/#{project}/compose.yml",
      "tests/expected/#{project}.yml",
      "tests/contracts/#{project}-foundation.sh"
    ].each do |path|
      expected = ["static", project, "idempotence_check"]
      check(failures, selected_lanes([path]) == expected,
            "#{path} selected #{selected_lanes([path]).inspect}, expected #{expected.inspect}")
    end
  end

  %w[
    config/media-acquisition.yml
    roles/host_prep/tasks/verify_media_acquisition.yml
    tests/media_acquisition_foundation_verifier_test.rb
  ].each do |path|
    expected = ["static", *ACQUISITION_LANES, "idempotence_check"]
    check(failures, selected_lanes([path]) == expected,
          "#{path} must select every acquisition foundation lane")
  end

  {
    "beszel" => %w[beszel],
    "dozzle" => %w[dozzle],
    "audiobookshelf" => %w[audiobookshelf],
    "komga" => %w[komga],
    "jellyfin" => %w[jellyfin],
    "immich" => %w[immich],
    "paperless-ngx" => %w[paperless]
  }.each do |service, expected_service_lanes|
    role = service == "paperless-ngx" ? "paperless_ngx" : service
    contract = service == "paperless-ngx" ? "paperless" : service
    [
      "roles/#{role}/tasks/main.yml",
      "services/#{service}/compose.yml",
      "tests/contracts/#{contract}.sh"
    ].each do |path|
      expected = %w[static smoke] + expected_service_lanes + %w[idempotence_check]
      check(failures, selected_lanes([path]) == expected,
            "#{path} selected #{selected_lanes([path]).inspect}, expected #{expected.inspect}")
    end
  end

  check(failures, selected_lanes(["roles/beszel/tasks/main.yml", "services/dozzle/compose.yml"]) ==
                  %w[static smoke beszel dozzle idempotence_check],
        "multiple service changes must combine service lanes in canonical order")
  check(
    failures,
    selected_lanes([
      "roles/komga/tasks/main.yml",
      "services/jellyfin/compose.yml",
      "tests/contracts/immich.sh"
    ]) == %w[static smoke komga jellyfin immich idempotence_check],
    "multiple media service changes must remain independent and canonically ordered"
  )
  check(failures, ClassifyChanges.classify([], full: false).keys == LANES,
        "classify must return every lane in canonical order")
  check(failures, selected_lanes([], full: true) == LANES,
        "full events must select every lane")
  check(failures, selected_lanes(["AGENTS.md"]) == LANES,
        "AGENTS.md must not be treated as inert Markdown")
  check(failures, selected_lanes(["tests/fixtures/operator-guide.md"]) == LANES,
        "test fixture Markdown must not be treated as inert")

  {
    "roles/beszel/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,beszel",
    "roles/dozzle/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,dozzle",
    "roles/audiobookshelf/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,audiobookshelf",
    "roles/komga/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,komga",
    "roles/jellyfin/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,jellyfin",
    "roles/immich/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,immich",
    "roles/paperless_ngx/tasks/main.yml" => "host_prep,deployment_bundle,ntfy,paperless"
  }.each do |path, expected_tags|
    service_output = StringIO.new
    ClassifyChanges.write_github_outputs(ClassifyChanges.classify([path]), service_output)
    check(failures, service_output.string.end_with?("selected_tags=#{expected_tags}\n"),
          "#{path} emitted the wrong prerequisite tag plan: #{service_output.string.inspect}")
  end

  io = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(%w[roles/beszel/tasks/main.yml services/dozzle/compose.yml]), io
  )
  expected_output = <<~OUTPUT
    static=true
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=false
    trailarr=false
    seerr=false
    smoke=true
    beszel=true
    dozzle=true
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=false
    idempotence_check=true
    suites=["smoke","beszel","dozzle","idempotence-check"]
    run_ci=true
    selected_tags=host_prep,deployment_bundle,ntfy,beszel,dozzle
  OUTPUT
  check(failures, io.string == expected_output,
        "GitHub output or prerequisite tag ordering was incorrect: #{io.string.inspect}")

  full_output = StringIO.new
  ClassifyChanges.write_github_outputs(ClassifyChanges.classify([], full: true), full_output)
  expected_full_output = <<~OUTPUT
    static=true
    foundation=true
    arr=true
    downloaders=true
    bindery=true
    kapowarr=true
    pinchflat=true
    trailarr=true
    seerr=true
    smoke=true
    beszel=true
    dozzle=true
    audiobookshelf=true
    komga=true
    jellyfin=true
    immich=true
    paperless=true
    idempotence_check=true
    suites=["foundation","arr","downloaders","bindery","kapowarr","pinchflat","trailarr","seerr","smoke","beszel","dozzle","audiobookshelf","komga","jellyfin","immich","paperless","idempotence-check"]
    run_ci=true
    selected_tags=
  OUTPUT
  check(failures, full_output.string == expected_full_output,
        "--full output must leave selected_tags empty: #{full_output.string.inspect}")

  shared_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/deployment_bundle/tasks/main.yml"]), shared_output
  )
  check(failures, shared_output.string == expected_full_output,
        "shared-scope output must select the full untagged site: #{shared_output.string.inspect}")

  unknown_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["unexpected/new-runtime-file"]), unknown_output
  )
  check(failures, unknown_output.string == expected_full_output,
        "unknown-path output must select the full untagged site: #{unknown_output.string.inspect}")

  paperless_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["roles/paperless_ngx/tasks/main.yml"]), paperless_output
  )
  check(failures, paperless_output.string == <<~OUTPUT,
    static=true
    foundation=false
    arr=false
    downloaders=false
    bindery=false
    kapowarr=false
    pinchflat=false
    trailarr=false
    seerr=false
    smoke=true
    beszel=false
    dozzle=false
    audiobookshelf=false
    komga=false
    jellyfin=false
    immich=false
    paperless=true
    idempotence_check=true
    suites=["smoke","paperless","idempotence-check"]
    run_ci=true
    selected_tags=host_prep,deployment_bundle,ntfy,paperless
  OUTPUT
        "Paperless-only output must retain its exact tag plan: #{paperless_output.string.inspect}")

  io = StringIO.new
  ClassifyChanges.write_github_outputs(ClassifyChanges.classify(["README.md"]), io)
  check(failures, io.string.end_with?("run_ci=true\nselected_tags=\n"),
        "protected operator docs must select static CI and emit empty selected_tags")
  # The CI matrix job skips on exactly this literal, so it has to stay compact.
  check(failures, io.string.include?("suites=[]\n"),
        "protected operator docs must emit an empty suite array: #{io.string.inspect}")

  check(failures, ClassifyChanges::SUITES.keys == ClassifyChanges::LANES - ["static"],
        "every lane except static must map to exactly one integration suite")
  check(failures,
        ClassifyChanges.suites(ClassifyChanges.classify(["roles/beszel/tasks/main.yml"])) ==
          %w[smoke beszel idempotence-check],
        "a Beszel-only change must dispatch smoke, beszel and idempotence-check")
  check(failures,
        ClassifyChanges.suites(ClassifyChanges.classify(["roles/arr/tasks/main.yml"])) ==
          %w[arr idempotence-check],
        "an Arr-only change must dispatch its foundation suite without smoke")

  acquisition_output = StringIO.new
  ClassifyChanges.write_github_outputs(
    ClassifyChanges.classify(["tests/contracts/seerr-foundation.sh"]), acquisition_output
  )
  check(failures,
        acquisition_output.string.end_with?(
          "selected_tags=host_prep,deployment_bundle,media_acquisition_foundation\n"
        ),
        "acquisition foundation lanes must emit only the fixed foundation tag plan")
  check(failures, !acquisition_output.string.downcase.include?("tmm"),
        "classifier outputs must not resurrect the retired tMM project")

  Dir.mktmpdir("classify-changes-git-") do |root|
    system("git", "init", "-q", root, exception: true)
    system("git", "-C", root, "config", "user.email", "ci@example.invalid", exception: true)
    system("git", "-C", root, "config", "user.name", "CI Test", exception: true)
    source = File.join(root, "roles", "paperless_ngx", "tasks", "main.yml")
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, "paperless owned content\n" * 20)
    system("git", "-C", root, "add", ".", exception: true)
    system("git", "-C", root, "commit", "-qm", "base", exception: true)
    base, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    check(failures, status.success?, "failed to resolve temporary base commit")
    base = base.strip
    destination = File.join(root, "docs", "paperless-role.md")
    FileUtils.mkdir_p(File.dirname(destination))
    system("git", "-C", root, "mv", source, destination, exception: true)
    system("git", "-C", root, "commit", "-qam", "rename", exception: true)
    head, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    check(failures, status.success?, "failed to resolve temporary head commit")
    head = head.strip

    paths = Dir.chdir(root) { ClassifyChanges.changed_paths(base, head) }
    check(failures,
          paths == ["roles/paperless_ngx/tasks/main.yml", "docs/paperless-role.md"],
          "rename parsing must return old and new paths, got #{paths.inspect}")
    check(failures, selected_lanes(paths).include?("paperless"),
          "renaming a Paperless-owned path to docs must retain Paperless selection")
  end

  Dir.mktmpdir("classify-changes-copy-delete-") do |root|
    system("git", "init", "-q", root, exception: true)
    system("git", "-C", root, "config", "user.email", "ci@example.invalid", exception: true)
    system("git", "-C", root, "config", "user.name", "CI Test", exception: true)
    beszel_source = File.join(root, "roles", "beszel", "tasks", "main.yml")
    dozzle_source = File.join(root, "roles", "dozzle", "tasks", "main.yml")
    FileUtils.mkdir_p(File.dirname(beszel_source))
    FileUtils.mkdir_p(File.dirname(dozzle_source))
    File.write(beszel_source, "beszel owned content\n" * 20)
    File.write(dozzle_source, "dozzle owned content\n" * 20)
    system("git", "-C", root, "add", ".", exception: true)
    system("git", "-C", root, "commit", "-qm", "base", exception: true)
    base, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    check(failures, status.success?, "failed to resolve temporary copy base commit")
    base = base.strip

    copy = File.join(root, "docs", "copied.md")
    FileUtils.mkdir_p(File.dirname(copy))
    FileUtils.cp(beszel_source, copy)
    system("git", "-C", root, "add", ".", exception: true)
    system("git", "-C", root, "commit", "-qm", "copy", exception: true)
    copy_head, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    check(failures, status.success?, "failed to resolve temporary copy commit")
    copy_head = copy_head.strip

    copied_paths = Dir.chdir(root) { ClassifyChanges.changed_paths(base, copy_head) }
    check(failures,
          copied_paths == ["roles/beszel/tasks/main.yml", "docs/copied.md"],
          "copy parsing must return source and destination paths, got #{copied_paths.inspect}")
    check(failures, selected_lanes(copied_paths).include?("beszel"),
          "copying a Beszel-owned path to docs must retain Beszel selection")

    FileUtils.rm(dozzle_source)
    system("git", "-C", root, "add", "-u", exception: true)
    system("git", "-C", root, "commit", "-qm", "delete", exception: true)
    delete_head, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    check(failures, status.success?, "failed to resolve temporary deletion commit")
    delete_head = delete_head.strip

    deleted_paths = Dir.chdir(root) { ClassifyChanges.changed_paths(copy_head, delete_head) }
    check(failures, deleted_paths == ["roles/dozzle/tasks/main.yml"],
          "deletion parsing must retain the deleted path, got #{deleted_paths.inspect}")
    check(failures, selected_lanes(deleted_paths).include?("dozzle"),
          "deleting a Dozzle-owned path must retain Dozzle selection")
  end
end

# Invalid mode combinations must fail with usage status before touching output.
Dir.mktmpdir("classify-changes-cli-") do |root|
  output_path = File.join(root, "github-output")
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, SCRIPT, "--full", "--files", "README.md", "--github-output", output_path
  )
  check(failures, status.exitstatus == 2, "invalid CLI modes must exit 2")
  check(failures, stdout.empty? && !File.exist?(output_path),
        "invalid CLI modes must fail before producing output")
  check(failures, stderr.include?("usage:"), "invalid CLI modes must print usage")

  stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--files", "README.md")
  check(failures, status.success? && stderr.empty? &&
                  stdout.include?("static=true\n") && stdout.include?("run_ci=true\n"),
        "--files CLI mode did not select static CI for protected operator docs")

  stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--full")
  check(failures, status.success? && stderr.empty? && stdout == expected_full_output,
        "--full CLI mode must emit an untagged full-site selection: #{stdout.inspect}")
end

unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} changed-path classifier failure(s)"
end

puts "changed-path classifier: all checks passed"
