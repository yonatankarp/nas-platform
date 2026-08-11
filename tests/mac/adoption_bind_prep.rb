#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

module AdoptionBindPrep
  class UnsafePath < StandardError; end

  Record = Struct.new(:relative, :mode, :nas_owned, keyword_init: true)

  DIRECTORIES = %w[
    legacy/audiobookshelf/config legacy/audiobookshelf/metadata legacy/audiobookshelf/media
    legacy/beszel/hub legacy/beszel/agent legacy/beszel/volume1 legacy/beszel/volume2
    legacy/dozzle/data
    legacy/immich/data legacy/immich/thumbs legacy/immich/encoded-video legacy/immich/profile
    legacy/immich/backups legacy/immich/model-cache legacy/immich/postgres
    legacy/jellyfin/config legacy/jellyfin/cache legacy/jellyfin/media
    legacy/komga/config legacy/komga/library
    legacy/ntfy/cache legacy/ntfy/data
    legacy/paperless-ngx/redis legacy/paperless-ngx/postgres legacy/paperless-ngx/data
    legacy/paperless-ngx/export legacy/paperless-ngx/tessdata legacy/paperless-ngx/media
    legacy/paperless-ngx/consume
    legacy/tinymediamanager/data legacy/tinymediamanager/movies legacy/tinymediamanager/series
  ].freeze
  NAS_OWNED = %w[
    legacy/audiobookshelf/config legacy/audiobookshelf/metadata legacy/audiobookshelf/media
    legacy/dozzle/data
    legacy/jellyfin/config legacy/jellyfin/cache legacy/jellyfin/media
    legacy/komga/config legacy/komga/library
    legacy/ntfy/cache legacy/ntfy/data
    legacy/paperless-ngx/data legacy/paperless-ngx/export legacy/paperless-ngx/tessdata
    legacy/paperless-ngx/media legacy/paperless-ngx/consume
    legacy/tinymediamanager/data legacy/tinymediamanager/movies legacy/tinymediamanager/series
  ].freeze

  module_function

  def plan
    @plan ||= DIRECTORIES.map do |relative|
      Record.new(relative: relative,
                 mode: relative == "legacy/immich/postgres" ? 0o700 : 0o755,
                 nas_owned: NAS_OWNED.include?(relative)).freeze
    end.freeze
  end

  def directory_flags
    flags = File::RDONLY
    flags |= File::DIRECTORY if File.const_defined?(:DIRECTORY)
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    flags
  end

  def open_directory_at(parent, component, create: false)
    raise UnsafePath unless component.match?(/\A[-A-Za-z0-9.]+\z/) && ![".", ".."].include?(component)

    Dir.fchdir(parent.fileno) { File.open(component, directory_flags) }
  rescue Errno::ENOENT
    raise unless create

    Dir.fchdir(parent.fileno) { Dir.mkdir(component, 0o700) }
    parent.fsync
    Dir.fchdir(parent.fileno) { File.open(component, directory_flags) }
  rescue Errno::ELOOP, Errno::ENOTDIR
    raise UnsafePath
  end

  def open_path(root, relative)
    current = root.dup
    components = relative.split("/")
    components.each_with_index do |component, index|
      child = open_directory_at(current, component, create: true)
      current.close
      current = child
      next if index == components.length - 1

      stat = current.stat
      raise UnsafePath unless stat.directory? && stat.uid == Process.uid
    end
    current
  rescue Exception # rubocop:disable Lint/RescueException
    current&.close
    raise
  end

  def identity(stat)
    [stat.dev, stat.ino, stat.uid, stat.gid, stat.mode & 0o777]
  end

  def verify_marker(root, expected_project)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    marker = Dir.fchdir(root.fileno) { File.open(".nas-platform-mac-owned", flags) }
    stat = marker.stat
    expected = "schema=1\nproject=#{expected_project}\n"
    raise UnsafePath unless stat.file? && stat.nlink == 1 && stat.uid == root.stat.uid &&
      (stat.mode & 0o777) == 0o600 && marker.read(expected.bytesize + 1) == expected
    identity(stat)
  rescue Errno::ELOOP, Errno::ENOTDIR, Errno::ENOENT
    raise UnsafePath
  ensure
    marker&.close
  end

  def prepare_model(tessdata, platform, nas_uid, nas_gid)
    flags = File::RDWR | File::CREAT
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    model = Dir.fchdir(tessdata.fileno) { File.open("heb.traineddata", flags, 0o600) }
    raise UnsafePath unless model.stat.file? && model.stat.nlink == 1

    if platform == "integration"
      model.chown(nas_uid, nas_gid)
      model.chmod(0o644)
    else
      raise UnsafePath unless model.stat.uid == Process.uid
      model.chmod(0o600)
    end
    model.fsync
    tessdata.fsync
  rescue Errno::ELOOP, Errno::ENOTDIR
    raise UnsafePath
  ensure
    model&.close
  end

  def prepare(sandbox, platform:, nas_uid:, nas_gid:, expected_project:)
    raise UnsafePath unless %w[mac integration].include?(platform)
    raise UnsafePath unless nas_uid.is_a?(Integer) && nas_gid.is_a?(Integer) &&
      nas_uid.positive? && nas_gid.positive?
    raise UnsafePath unless expected_project.match?(/\Anas-platform-mac-[a-z0-9]{6}\z/)

    parent = File.open(File.dirname(sandbox), directory_flags)
    root = open_directory_at(parent, File.basename(sandbox))
    root_stat = root.stat
    raise UnsafePath unless root_stat.directory? && root_stat.uid == Process.uid &&
      (root_stat.mode & 0o777) == 0o700
    suffix = File.basename(sandbox).delete_prefix("nas-platform-mac.").downcase
    raise UnsafePath unless File.basename(sandbox).match?(/\Anas-platform-mac\.[A-Za-z0-9]{6}\z/) &&
      expected_project == "nas-platform-mac-#{suffix}"
    marker_identity = verify_marker(root, expected_project)

    plan.each do |record|
      directory = open_path(root, record.relative)
      stat = directory.stat
      raise UnsafePath unless stat.directory?
      if platform == "integration"
        directory.chown(nas_uid, nas_gid) if record.nas_owned
        directory.chmod(record.mode)
      else
        raise UnsafePath unless stat.uid == Process.uid
        directory.chmod(0o700)
      end
      directory.fsync
      prepare_model(directory, platform, nas_uid, nas_gid) if
        record.relative == "legacy/paperless-ngx/tessdata"
    ensure
      directory&.close
    end
    root.fsync
    current_parent = File.open(File.dirname(sandbox), directory_flags)
    raise UnsafePath unless identity(current_parent.stat) == identity(parent.stat)
    current = open_directory_at(current_parent, File.basename(sandbox))
    raise UnsafePath unless identity(current.stat) == identity(root_stat)
    raise UnsafePath unless verify_marker(current, expected_project) == marker_identity
  rescue Errno::ELOOP, Errno::ENOTDIR, Errno::ENOENT
    raise UnsafePath
  ensure
    current&.close
    current_parent&.close
    root&.close
    parent&.close
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: adoption_bind_prep.rb SANDBOX PLATFORM INVENTORY PROJECT" unless ARGV.length == 4
  sandbox, platform, inventory_path, expected_project = ARGV
  inventory = YAML.safe_load_file(inventory_path, aliases: false)
  nas_uid = inventory.fetch("nas_uid")
  nas_gid = inventory.fetch("nas_gid")
  abort "integration ownership requires root" if platform == "integration" && Process.uid != 0
  abort "reviewed integration identity differs" unless nas_uid == 1000 && nas_gid == 100

  AdoptionBindPrep.prepare(sandbox, platform: platform, nas_uid: nas_uid, nas_gid: nas_gid,
                           expected_project: expected_project)
end
