# frozen_string_literal: true

require "securerandom"

module LegacySecureCopy
  class Unsafe < StandardError; end

  MAXIMUM_SIZE = 1024 * 1024

  def self.signature(stat)
    [stat.dev, stat.ino, stat.mode, stat.uid, stat.size, stat.mtime.to_r, stat.ctime.to_r]
  end

  def self.copy(source_path, destination_path, before_open: nil)
    initial = File.lstat(source_path)
    raise Unsafe unless initial.file? && !initial.symlink? && initial.uid == Process.uid
    raise Unsafe if initial.size > MAXIMUM_SIZE

    before_open&.call
    input_flags = File::RDONLY
    input_flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    bytes = File.open(source_path, input_flags) do |source|
      opened = source.stat
      raise Unsafe unless signature(initial) == signature(opened)
      content = source.read(MAXIMUM_SIZE + 1)
      raise Unsafe if content.bytesize > MAXIMUM_SIZE
      raise Unsafe unless signature(opened) == signature(source.stat)
      raise Unsafe unless signature(initial) == signature(File.lstat(source_path))
      content
    end

    directory = File.dirname(destination_path)
    temporary = File.join(directory, ".#{File.basename(destination_path)}.#{Process.pid}.#{SecureRandom.hex(8)}")
    begin
      output_flags = File::WRONLY | File::CREAT | File::EXCL
      output_flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(temporary, output_flags, 0o600) do |output|
        output.write(bytes)
        output.flush
        output.fsync
      end
      File.rename(temporary, destination_path)
      File.open(directory, File::RDONLY) { |parent| parent.fsync }
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary) && !File.symlink?(temporary)
    end
  rescue SystemCallError, IOError
    raise Unsafe
  end
end
