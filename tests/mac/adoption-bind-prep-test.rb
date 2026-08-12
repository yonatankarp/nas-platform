#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "adoption_bind_prep"

EXPECTED_DIRECTORIES = %w[
  legacy/audiobookshelf/config legacy/audiobookshelf/metadata legacy/audiobookshelf/media
  legacy/audiobookshelf/backups
  legacy/beszel/hub legacy/beszel/agent legacy/beszel/volume1 legacy/beszel/volume2
  legacy/dozzle/data
  legacy/immich/data legacy/immich/thumbs legacy/immich/encoded-video legacy/immich/profile
  legacy/immich/backups legacy/immich/model-cache legacy/immich/postgres
  legacy/jellyfin/config legacy/jellyfin/cache legacy/jellyfin/media
  legacy/komga/config legacy/komga/library
  legacy/ntfy/cache legacy/ntfy/data
  legacy/paperless-ngx/redis legacy/paperless-ngx/postgres legacy/paperless-ngx/data
  legacy/paperless-ngx/cache legacy/paperless-ngx/export legacy/paperless-ngx/tessdata legacy/paperless-ngx/media
  legacy/paperless-ngx/consume
  legacy/tinymediamanager/data legacy/tinymediamanager/movies legacy/tinymediamanager/series
].freeze
NAS_OWNED = %w[
  legacy/audiobookshelf/config legacy/audiobookshelf/metadata legacy/audiobookshelf/media
  legacy/audiobookshelf/backups
  legacy/dozzle/data
  legacy/jellyfin/config legacy/jellyfin/cache legacy/jellyfin/media
  legacy/komga/config legacy/komga/library
  legacy/ntfy/cache legacy/ntfy/data
  legacy/paperless-ngx/data legacy/paperless-ngx/cache legacy/paperless-ngx/export legacy/paperless-ngx/tessdata
  legacy/paperless-ngx/media legacy/paperless-ngx/consume
  legacy/tinymediamanager/data legacy/tinymediamanager/movies legacy/tinymediamanager/series
].freeze

def fail_test(message)
  warn message
  exit 1
end

plan = AdoptionBindPrep.plan
fail_test("bind preparation does not cover the exact reviewed directory set") unless
  plan.map(&:relative).sort == EXPECTED_DIRECTORIES.sort
fail_test("bind preparation ownership differs from reviewed service identities") unless
  plan.select(&:nas_owned).map(&:relative).sort == NAS_OWNED.sort
fail_test("Immich PostgreSQL mode differs from its archive/runtime contract") unless
  plan.to_h { |record| [record.relative, record.mode] }.fetch("legacy/immich/postgres") == 0o700
fail_test("integration bind directories are not traversable") unless
  plan.reject { |record| record.relative == "legacy/immich/postgres" }.all? do |record|
    record.mode == 0o755
  end
adoption_source = File.read(File.join(__dir__, "adoption.sh"))
fail_test("legacy deployment does not select bind policy from the proof platform") unless
  adoption_source.include?('"${PLATFORM_PROOF_PLATFORM:-mac}" "$repo_dir/inventory/group_vars/all/main.yml"')

Dir.mktmpdir("nas-platform-bind-prep-parent.") do |parent|
  root = File.join(parent, "nas-platform-mac.Root42")
  Dir.mkdir(root, 0o700)
  File.chmod(0o700, root)
  project = "nas-platform-mac-root42"
  File.write(File.join(root, ".nas-platform-mac-owned"),
             "schema=1\nproject=#{project}\n", mode: "w", perm: 0o600)
  preserved = File.join(root, "legacy/ntfy/data/preserved")
  FileUtils.mkdir_p(File.dirname(preserved), mode: 0o700)
  File.write(preserved, "archive-semantics\n", mode: "w", perm: 0o640)
  File.link(preserved, "#{preserved}.link")
  preserved_time = Time.at(1_700_000_000, 123_456_789, :nsec)
  File.utime(preserved_time, preserved_time, preserved)
  preserved_before = File.stat(preserved)
  test_nas_uid = Process.uid.zero? ? 1000 : Process.uid
  test_nas_gid = Process.uid.zero? ? 100 : Process.gid
  AdoptionBindPrep.prepare(root, platform: "integration", nas_uid: test_nas_uid,
                           nas_gid: test_nas_gid, expected_project: project)
  plan.each do |record|
    path = File.join(root, record.relative)
    stat = File.lstat(path)
    fail_test("prepared bind is not a directory: #{record.relative}") unless stat.directory?
    fail_test("prepared bind mode differs: #{record.relative}") unless
      (stat.mode & 0o777) == record.mode
    next unless record.nas_owned

    fail_test("prepared bind ownership differs: #{record.relative}") unless
      stat.uid == test_nas_uid && stat.gid == test_nas_gid
  end
  model = File.join(root, "legacy/paperless-ngx/tessdata/heb.traineddata")
  model_stat = File.lstat(model)
  fail_test("Paperless model is not an exact regular bind") unless model_stat.file? && !model_stat.symlink?
  fail_test("Paperless model is unreadable by the reviewed service identity") unless
    (model_stat.mode & 0o777) == 0o644 && model_stat.uid == test_nas_uid &&
      model_stat.gid == test_nas_gid
  if Process.uid.zero?
    bind_descriptors = NAS_OWNED.to_h do |relative|
      [relative, File.open(File.join(root, relative), File::RDONLY)]
    end
    child = fork do
      Process.groups = []
      Process::GID.change_privilege(test_nas_gid)
      Process::UID.change_privilege(test_nas_uid)
      bind_descriptors.each do |relative, descriptor|
        AdoptionBindPrep.in_directory(descriptor) do
          File.write(".nas-platform-access-check", "ok\n", mode: "w", perm: 0o600)
          File.unlink(".nas-platform-access-check")
          File.read("heb.traineddata") if relative == "legacy/paperless-ngx/tessdata"
        end
      end
      exit! 0
    rescue StandardError
      exit! 1
    end
    child_status = Process.wait2(child).last
    bind_descriptors.each_value(&:close)
    fail_test("root-run bind sources are inaccessible to 1000:100") unless child_status.success?
  end
  preserved_after = File.stat(preserved)
  fail_test("bind preparation changed archived child state") unless
    File.read(preserved) == "archive-semantics\n" &&
      [preserved_after.ino, preserved_after.nlink, preserved_after.mode & 0o777,
       preserved_after.mtime.to_r] ==
      [preserved_before.ino, preserved_before.nlink, preserved_before.mode & 0o777,
       preserved_before.mtime.to_r]

  replaced = File.join(root, "legacy/beszel/volume2")
  Dir.rmdir(replaced)
  File.symlink(Dir.tmpdir, replaced)
  begin
    AdoptionBindPrep.prepare(root, platform: "integration", nas_uid: test_nas_uid,
                             nas_gid: test_nas_gid, expected_project: project)
    fail_test("symlinked bind source was accepted")
  rescue AdoptionBindPrep::UnsafePath
    # Expected.
  end
end

Dir.mktmpdir("nas-platform-bind-prep-mac-parent.") do |parent|
  root = File.join(parent, "nas-platform-mac.Mac042")
  Dir.mkdir(root, 0o700)
  File.chmod(0o700, root)
  project = "nas-platform-mac-mac042"
  File.write(File.join(root, ".nas-platform-mac-owned"),
             "schema=1\nproject=#{project}\n", mode: "w", perm: 0o600)
  AdoptionBindPrep.prepare(root, platform: "mac", nas_uid: Process.uid, nas_gid: Process.gid,
                           expected_project: project)
  fail_test("default Mac bind behavior changed") unless EXPECTED_DIRECTORIES.all? do |relative|
    (File.stat(File.join(root, relative)).mode & 0o777) == 0o700
  end
  fail_test("default Mac file-backed bind behavior changed") unless
    (File.stat(File.join(root, "legacy/paperless-ngx/tessdata/heb.traineddata")).mode & 0o777) == 0o600
  File.write(File.join(root, ".nas-platform-mac-owned"), "schema=1\nproject=nas-platform-mac-wrong0\n")
  begin
    AdoptionBindPrep.prepare(root, platform: "mac", nas_uid: Process.uid, nas_gid: Process.gid,
                             expected_project: project)
    fail_test("changed sandbox ownership marker was accepted")
  rescue AdoptionBindPrep::UnsafePath
    # Expected.
  end
end

puts "adoption bind preparation: root-run service access policy holds"
