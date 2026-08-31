#!/usr/bin/env ruby
# Copy one protected input into the Mac proof sandbox, or validate the copy a
# manual-validation resume is reusing.
#
# usage: pin-protected-input.rb SOURCE DESTINATION LABEL KIND EXTERNAL \
#          REPOSITORY PROTECTED_ROOT REUSE
#
#   KIND      vault | password. A vault must carry the Ansible Vault header and
#             may be 16 MiB; anything else is capped at 1 MiB.
#   EXTERNAL  "true" refuses a source that resolves inside the repository.
#   REUSE     "true" validates an existing 0600 copy byte-for-byte instead of
#             writing one, which is how a resumed manual validation proves it
#             was handed the same inputs.
#
# Exits 0 on success, 1 with a one-line `protected <label> input <detail>`
# diagnostic on any refusal. Nothing it reads or writes is ever printed.
#
# This is a TOCTOU-safe pin, not a copy. The source is opened through a
# directory descriptor held for the whole operation -- `in_directory` fchdir()s
# into it, so `./basename` cannot be redirected by a component of the path being
# swapped underneath -- and every lstat/stat pair before and after the read must
# still agree. The interleaving of those checks with the syscalls between them
# is the security property: do not reorder, coalesce, or hoist them.
#
# It lived in a `<<'RUBY'` heredoc inside tests/mac/run.sh until #147. Nothing
# syntax-checked it and nothing could unit-test it; tests/mac/pin-protected-input-test.rb
# now does both. The body below is byte-identical to what that heredoc rendered.
source_path, destination_path, label, kind, external, repository, protected_root, reuse = ARGV
require "fiddle"
require "open3"
require "rbconfig"
require "timeout"

maximum_size = kind == "vault" ? 16 * 1024 * 1024 : 1024 * 1024
FCHDIR = Fiddle::Function.new(
  Fiddle::Handle::DEFAULT["fchdir"],
  [Fiddle::TYPE_INT],
  Fiddle::TYPE_INT
)

def in_directory(directory)
  previous = File.open(".", File::RDONLY)
  raise SystemCallError.new("fchdir", Fiddle.last_error) if FCHDIR.call(directory.fileno).negative?

  yield
ensure
  if previous
    restored = FCHDIR.call(previous.fileno)
    previous.close
    raise SystemCallError.new("fchdir", Fiddle.last_error) if restored.negative?
  end
end

def fail_pin(label, detail)
  warn "protected #{label} input #{detail}"
  exit 1
end

def signature(stat)
  [stat.dev, stat.ino, stat.size, stat.mode, stat.mtime.to_r, stat.ctime.to_r]
end

def identity(stat)
  [stat.dev, stat.ino, stat.mode, stat.uid]
end

def terminate_group(pid, signal)
  Process.kill(signal, -pid)
rescue Errno::ESRCH
  nil
end

def bounded_read(stream, maximum_size)
  bytes = stream.read(maximum_size + 1) || ""
  stream.close if bytes.bytesize > maximum_size
  { bytes: bytes, failed: false }
rescue IOError
  { bytes: "", failed: true }
end

def execute_provider(directory, basename, provider_bytes, maximum_size)
  result = {
    output: "", success: false, timed_out: false, oversized: false,
    capture_failed: false, unsupported: false, contains_nul: false
  }
  unless provider_bytes.lines.first == "#!/bin/sh\n"
    result[:unsupported] = true
    return result
  end
  if provider_bytes.include?("\0")
    result[:contains_nul] = true
    return result
  end
  directory_descriptor = directory.fileno
  directory.close_on_exec = false
  # Buffer the inspected bytes from an anonymous pipe before evaluating them.
  # The sentinel prevents command substitution from stripping trailing newlines.
  provider_command = <<~'PROVIDER_COMMAND'
    provider_script=$(cat && printf '\036') || exit 70
    provider_script=${provider_script%?}
    exec </dev/null || exit 70
    eval "$provider_script"
  PROVIDER_COMMAND
  launcher = <<~'PROVIDER_LAUNCHER'
    require "fiddle"
    directory_descriptor = Integer(ARGV.fetch(0), 10)
    basename = ARGV.fetch(1)
    provider_command = ARGV.fetch(2)
    directory = IO.for_fd(directory_descriptor)
    fchdir = Fiddle::Function.new(
      Fiddle::Handle::DEFAULT["fchdir"], [Fiddle::TYPE_INT], Fiddle::TYPE_INT
    )
    raise SystemCallError.new("fchdir", Fiddle.last_error) if fchdir.call(directory.fileno).negative?
    directory.close
    exec(["/bin/sh", "/bin/sh"], "-c", provider_command, "./#{basename}")
  PROVIDER_LAUNCHER
  spawn_options = { pgroup: true, directory_descriptor => directory_descriptor }
  Open3.popen3(
    [RbConfig.ruby, RbConfig.ruby], "-e", launcher,
    directory_descriptor.to_s, basename, provider_command, spawn_options
  ) do |stdin, stdout, stderr, wait_thread|
    writer = Thread.new do
      begin
        stdin.write(provider_bytes)
        { failed: false }
      rescue IOError, SystemCallError
        { failed: true }
      ensure
        stdin.close unless stdin.closed?
      end
    end
    stdout_reader = Thread.new { bounded_read(stdout, maximum_size) }
    stderr_reader = Thread.new { bounded_read(stderr, 64 * 1024) }
    stdout_reader.report_on_exception = false
    stderr_reader.report_on_exception = false
    writer.report_on_exception = false
    reader_cleanup_failed = false
    writer_cleanup_failed = false
    begin
      status = Timeout.timeout(5) { wait_thread.value }
      result[:success] = status.success?
    rescue Timeout::Error
      result[:timed_out] = true
      terminate_group(wait_thread.pid, "TERM")
      unless wait_thread.join(1)
        terminate_group(wait_thread.pid, "KILL")
        wait_thread.join
      end
    ensure
      unless writer.join(1)
        writer_cleanup_failed = true
        stdin.close unless stdin.closed?
        terminate_group(wait_thread.pid, "TERM")
        terminate_group(wait_thread.pid, "KILL") unless writer.join(1)
      end
      readers = [[stdout_reader, stdout], [stderr_reader, stderr]]
      readers.each do |reader, _stream|
        next if reader.join(1)

        reader_cleanup_failed = true
        terminate_group(wait_thread.pid, "TERM")
        readers.each { |_capture, stream| stream.close unless stream.closed? }
        terminate_group(wait_thread.pid, "KILL")
        break
      end
      readers.each do |reader, stream|
        stream.close unless stream.closed?
        reader.kill unless reader.join(1)
        reader.join
      end
      writer.kill unless writer.join(1)
      writer.join
    end
    writer_capture = writer.value || { failed: true }
    stdout_capture = stdout_reader.value || { bytes: "", failed: true }
    stderr_capture = stderr_reader.value || { bytes: "", failed: true }
    result[:output] = stdout_capture[:bytes]
    result[:capture_failed] = writer_cleanup_failed || writer_capture[:failed] ||
                              reader_cleanup_failed || stdout_capture[:failed] || stderr_capture[:failed]
    result[:oversized] = result[:output].bytesize > maximum_size ||
                         stderr_capture[:bytes].bytesize > 64 * 1024
  end
  result
rescue SystemCallError, IOError
  result
end

temporary_path = nil
parent_directory = nil
source = nil
begin
  fail_pin(label, "cannot be pinned safely") unless
    File.const_defined?(:NOFOLLOW) && File.const_defined?(:NONBLOCK)
  source_path = File.expand_path(source_path)
  repository = File.realpath(repository)
  protected_root = File.expand_path(protected_root)
  destination_parent = File.expand_path(File.dirname(destination_path))
  protected_root_before = File.lstat(protected_root)
  fail_pin(label, "destination is unsafe") unless
    destination_parent == protected_root && protected_root_before.directory? &&
      protected_root_before.uid == Process.uid && (protected_root_before.mode & 0o777) == 0o700 &&
      File.realpath(protected_root) == protected_root
  parent_path = File.dirname(source_path)
  basename = File.basename(source_path)
  fail_pin(label, "cannot be pinned safely") if [".", ".."].include?(basename)
  parent_before = File.realpath(parent_path)
  if external == "true" &&
     (parent_before == repository || parent_before.start_with?(repository + File::SEPARATOR))
    fail_pin(label, "must remain outside the repository")
  end

  flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
  parent_path_before = File.lstat(parent_path)
  canonical_parent_before = File.lstat(parent_before)
  parent_directory = File.open(parent_before, flags)
  parent_descriptor_before = parent_directory.stat
  fail_pin(label, "changed while being pinned") unless
    parent_descriptor_before.directory? &&
      identity(canonical_parent_before) == identity(parent_descriptor_before)
  path_before = File.lstat(source_path)
  held_path_before = in_directory(parent_directory) { File.lstat("./#{basename}") }
  fail_pin(label, "must be a regular non-symlink file") unless
    path_before.file? && held_path_before.file?
  fail_pin(label, "changed while being pinned") unless
    signature(path_before) == signature(held_path_before)
  bytes = nil
  executable = false
  source = in_directory(parent_directory) { File.open("./#{basename}", flags) }
  descriptor_before = source.stat
  fail_pin(label, "changed while being pinned") unless
    descriptor_before.file? && signature(path_before) == signature(descriptor_before)
  fail_pin(label, "exceeds the size limit") if descriptor_before.size > maximum_size
  executable = (descriptor_before.mode & 0o111).positive?
  bytes = source.read(maximum_size + 1)
  fail_pin(label, "exceeds the size limit") if bytes.bytesize > maximum_size
  descriptor_after = source.stat
  fail_pin(label, "changed while being pinned") unless
    signature(descriptor_before) == signature(descriptor_after)

  parent_after = File.realpath(parent_path)
  parent_path_after = File.lstat(parent_path)
  canonical_parent_after = File.lstat(parent_before)
  parent_descriptor_after = parent_directory.stat
  path_after = File.lstat(source_path)
  held_path_after = in_directory(parent_directory) { File.lstat("./#{basename}") }
  fail_pin(label, "changed while being pinned") unless
    parent_before == parent_after &&
      identity(parent_path_before) == identity(parent_path_after) &&
      identity(canonical_parent_before) == identity(canonical_parent_after) &&
      identity(parent_descriptor_before) == identity(parent_descriptor_after) &&
      signature(path_before) == signature(path_after) &&
      signature(path_before) == signature(held_path_after)
  if kind == "password" && executable
    source.close
    source = nil
    provider = execute_provider(parent_directory, basename, bytes, maximum_size)
    provider_parent_after = File.realpath(parent_path)
    provider_parent_path_after = File.lstat(parent_path)
    provider_canonical_parent_after = File.lstat(parent_before)
    provider_parent_descriptor_after = parent_directory.stat
    provider_path_after = File.lstat(source_path)
    provider_held_path_after = in_directory(parent_directory) { File.lstat("./#{basename}") }
    fail_pin(label, "changed while being pinned") unless
      parent_before == provider_parent_after &&
        identity(parent_path_before) == identity(provider_parent_path_after) &&
        identity(canonical_parent_before) == identity(provider_canonical_parent_after) &&
        identity(parent_descriptor_before) == identity(provider_parent_descriptor_after) &&
        signature(path_before) == signature(provider_path_after) &&
        signature(path_before) == signature(provider_held_path_after)
    fail_pin(label, "provider timed out") if provider[:timed_out]
    fail_pin(label, "provider output exceeds the size limit") if provider[:oversized]
    fail_pin(label, "provider must use the exact #!/bin/sh executable format") if provider[:unsupported]
    fail_pin(label, "provider contains unsupported NUL bytes") if provider[:contains_nul]
    fail_pin(label, "provider failed") unless provider[:success] && !provider[:capture_failed]
    bytes = provider[:output]
  end
  if source
    source.close
    source = nil
  end
  parent_directory.close
  parent_directory = nil
  if kind == "vault" && !bytes.start_with?("$ANSIBLE_VAULT;")
    fail_pin(label, "is not Ansible Vault encrypted")
  end

  protected_root_after = File.lstat(protected_root)
  fail_pin(label, "destination is unsafe") unless
    signature(protected_root_before) == signature(protected_root_after) &&
      File.realpath(protected_root) == protected_root
  if reuse == "true"
    fail_pin(label, "protected copy is unavailable or unsafe") unless
      File.file?(destination_path) && !File.symlink?(destination_path)
    destination_before = File.lstat(destination_path)
    fail_pin(label, "protected copy is unavailable or unsafe") unless
      destination_before.uid == Process.uid && (destination_before.mode & 0o777) == 0o600 &&
        destination_before.size <= maximum_size
    destination = File.open(destination_path, flags)
    destination_held = destination.stat
    destination_bytes = destination.read(maximum_size + 1)
    destination_after = destination.stat
    destination.close
    fail_pin(label, "protected copy changed while being validated") unless
      signature(destination_before) == signature(destination_held) &&
        signature(destination_held) == signature(destination_after)
    fail_pin(label, "differs from the manual-validation protected copy") unless
      destination_bytes == bytes
    protected_root_reused = File.lstat(protected_root)
    fail_pin(label, "destination is unsafe") unless
      signature(protected_root_before) == signature(protected_root_reused) &&
        File.realpath(protected_root) == protected_root
    exit 0
  end
  mode = 0o600
  temporary_path = "#{destination_path}.tmp.#{Process.pid}"
  output_flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
  File.open(temporary_path, output_flags, mode) do |output|
    output.write(bytes)
    output.flush
    output.fsync
  end
  File.chmod(mode, temporary_path)
  File.rename(temporary_path, destination_path)
  temporary_path = nil
  protected_root_final = File.lstat(protected_root)
  destination_final = File.lstat(destination_path)
  fail_pin(label, "destination is unsafe") unless
    [protected_root_final.dev, protected_root_final.ino, protected_root_final.mode,
     protected_root_final.uid] ==
      [protected_root_before.dev, protected_root_before.ino, protected_root_before.mode,
       protected_root_before.uid] &&
      File.realpath(protected_root) == protected_root && destination_final.file? &&
      (destination_final.mode & 0o777) == mode && destination_final.uid == Process.uid
rescue SystemCallError, IOError, ArgumentError
  fail_pin(label, "changed while being pinned")
ensure
  source.close if source && !source.closed?
  parent_directory.close if parent_directory && !parent_directory.closed?
  File.unlink(temporary_path) if temporary_path && File.file?(temporary_path) && !File.symlink?(temporary_path)
end
