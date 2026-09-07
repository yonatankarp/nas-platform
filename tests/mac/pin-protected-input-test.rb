#!/usr/bin/env ruby
# Behaviour and sequencing of tests/mac/pin-protected-input.rb.
#
# The pin is the Mac proof's trust boundary: it is what decides that the vault
# and the password provider a human named on the command line are still the same
# bytes by the time they reach the sandbox. Until #147 it was a 313-line Ruby
# program inside a `<<'RUBY'` heredoc in tests/mac/run.sh, so nothing
# syntax-checked it and the only thing that ever ran it was a full Mac lifecycle
# proof needing Docker and a real vault password.
#
# Two layers, because the program has two kinds of property:
#
#   Behaviour -- drive the real program over real fixtures, one case per refusal
#   it is supposed to make and one per copy it is supposed to produce. These
#   assert the exact diagnostic, not merely a nonzero exit: a guard that fails
#   for the wrong reason has stopped guarding what it names.
#
#   Sequencing -- the TOCTOU properties are *orderings*, not outputs. That the
#   held-descriptor lstat happens through `in_directory`, that the read sits
#   between two `source.stat` calls, that the path is re-lstat'd after the read:
#   none of that is observable without losing a race, and a test that has to lose
#   a race to pass does not belong in the policy gate. They are pinned as
#   offsets into the source, the same way tests/policy_mac_test.rb pins that
#   reconciliation deploys before it verifies.
#
# Run with --self-test to prove both layers detect a planted regression.

require "fileutils"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

PROGRAM = File.join(__dir__, "pin-protected-input.rb")
VAULT_HEADER = "$ANSIBLE_VAULT;1.1;AES256\n"

# A backstop, not a budget. Nothing below asserts how long the pin takes, and no
# case comes within an order of magnitude of this: it exists because one
# regression this suite now guards -- an unbounded reader join after the process
# group KILL -- parks the pin forever rather than making it return late, and a
# gate check that hangs is worse than one that fails. An environment input for
# the same reason IMMICH_PLAYBOOK_TIMEOUT and AUDIOBOOKSHELF_PLAYBOOK_TIMEOUT
# are.
PIN_TIMEOUT_SECONDS = Float(ENV.fetch("PIN_PROGRAM_TIMEOUT", "120"))

def with_sandbox
  Dir.mktmpdir("nas-platform-pin-test.") do |raw|
    # Realpath, not the mktmpdir path: the program requires the protected root to
    # be its own realpath, and macOS hands out /var/... symlinks for TMPDIR.
    root = File.realpath(raw)
    layout = {
      root: root,
      repository: File.join(root, "repo"),
      outside: File.join(root, "outside"),
      protected_root: File.join(root, "sandbox", "protected-inputs")
    }
    FileUtils.mkdir_p([layout[:repository], layout[:outside], layout[:protected_root]])
    File.chmod(0o700, layout[:protected_root])
    yield layout
  end
end

def write_source(layout, name, content, mode: 0o600, in_repository: false)
  path = File.join(in_repository ? layout[:repository] : layout[:outside], name)
  File.binwrite(path, content)
  File.chmod(mode, path)
  path
end

PinOutcome = Struct.new(:succeeded) do
  def success?
    succeeded
  end
end

# Deliberately not Open3.capture2e. The pin has to run under a deadline, and a
# pipe would put reader threads in this harness -- exactly the construct whose
# failure mode one case below exists to provoke. A file redirect has none, so the
# deadline is a plain waitpid and the output is read back afterwards. The pin
# leads its own process group so a run that overruns can be killed whole; the
# grandchild one case plants is outside it by construction and is reaped by pid.
def run_pin(program, layout, source, destination, kind, external, reuse, label)
  Dir.mktmpdir("nas-platform-pin-output.") do |directory|
    combined = File.join(directory, "output")
    pid = Process.spawn(
      RbConfig.ruby, program, source, destination, label, kind,
      external, layout[:repository], layout[:protected_root], reuse,
      in: File::NULL, out: combined, err: [:child, :out], pgroup: true
    )
    overran = false
    status = begin
      Timeout.timeout(PIN_TIMEOUT_SECONDS) { Process.waitpid2(pid).last }
    rescue Timeout::Error
      overran = true
      kill_pin_group(pid)
      nil
    end
    output = File.binread(combined)
    output += "the pin exceeded its #{PIN_TIMEOUT_SECONDS}s deadline\n" if overran
    [output, PinOutcome.new(!overran && status.success?)]
  end
end

# A run that overruns the deadline has to leave nothing behind, and killing the
# pin's own group is not enough: the pin spawns its provider with `pgroup: true`,
# so the provider leads a group of its own that the pin's group KILL cannot
# reach. Take those out first, while the pin is still alive to be identified as
# their parent.
#
# This is one of two mechanisms and both are wanted: the wedged providers below
# also bound their own lives, because this one identifies its targets from `ps`
# and a fixture that leaves a process running on someone's machine is not a
# failure a test gets to have twice. Neither is redundant with the other.
def kill_pin_group(pid)
  child_process_groups(pid).each do |group|
    Process.kill("KILL", -group)
  rescue Errno::ESRCH
    nil
  end
  Process.kill("KILL", -pid)
  Process.waitpid(pid)
rescue Errno::ESRCH, Errno::ECHILD
  nil
end

# The pin's children that lead a group of their own, which is the one kind its
# own group KILL misses.
#
# Group leadership is asked of each child rather than assumed from how the pin is
# known to spawn, and the asking is the point rather than a formality: signalling
# a process group by a pid that leads no group does not fail, it reaches whatever
# group happens to carry that id. On a developer's machine that is something
# entirely unrelated, and a test suite that KILLs it would be a far worse bug
# than the leak this function exists to prevent. Do not replace the check with
# the knowledge that the pin spawns exactly one child, with `pgroup: true`; that
# is true today and is not what makes the signal safe.
def child_process_groups(pid)
  listing, status = Open3.capture2("ps", "-e", "-o", "pid=", "-o", "ppid=")
  return [] unless status.success?

  listing.lines.filter_map do |line|
    child, parent = line.split.map { |field| Integer(field, 10) }
    next unless parent == pid

    child if group_leader?(child)
  end
rescue ArgumentError, SystemCallError
  []
end

def group_leader?(pid)
  Process.getpgid(pid) == pid
rescue SystemCallError
  false
end

# The grandchild the reader-outlives-the-kill case plants has a hard backstop of
# its own, because it is by construction outside the process group the pin
# signals and nothing the pin does can end it. The case always kills it
# explicitly, so this only decides how long a *crashed* run could leave it
# behind. Late-bound rather than a constant because the self-test shortens it for
# one mutation: with a reader join unbounded the pin waits for this grandchild,
# so a short life turns that regression into an acceptance the case names rather
# than a hang the deadline has to catch.
def grandchild_lifetime_seconds
  Float(ENV.fetch("PIN_GRANDCHILD_LIFETIME", "30"))
end

def process_gone?(pid, within:)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
  loop do
    begin
      Process.kill(0, pid)
    rescue Errno::ESRCH
      return true
    end
    return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.05
  end
end

def recorded_grandchild_pid(pidfile, within: 10)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
  loop do
    recorded = File.file?(pidfile) ? File.read(pidfile).strip : ""
    return Integer(recorded, 10) if recorded.match?(/\A[0-9]+\z/)
    return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.05
  end
end

# A fixture that leaks a process every run is not one to keep, so confirming the
# grandchild is gone is one of the case's assertions rather than best-effort
# cleanup. It is not this process's child -- its parent exited and it was
# reparented -- so it is signalled by pid and observed with kill(0), not waited
# for.
def reap_grandchild(failures, name, pidfile)
  pid = recorded_grandchild_pid(pidfile)
  if pid.nil?
    failures << "#{name}: the fixture grandchild never recorded a pid to reap"
    return
  end
  begin
    Process.kill("KILL", pid)
  rescue Errno::ESRCH
    return
  end
  return if process_gone?(pid, within: 10)

  failures << "#{name}: the fixture grandchild #{pid} survived being reaped"
end

# The destination every case that is not deliberately testing an unsafe
# destination writes into.
def pinned_destination(layout, name = "deployment-vault.yml")
  File.join(layout[:protected_root], name)
end

def refusal(failures, name, output, status, expected)
  if status.success?
    failures << "#{name}: the pin accepted what it must refuse"
    return
  end
  return if output.include?(expected)

  failures << "#{name}: expected #{expected.inspect}, got #{output.strip.inspect}"
end

def acceptance(failures, name, output, status)
  return if status.success? && output.empty?

  failures << "#{name}: the pin refused a valid input: #{output.strip.inspect}"
end

# One entry per property. Named so --self-test can run only the cases a planted
# regression is supposed to move, rather than the whole suite ten times over.
BEHAVIOUR = {
  "vault-happy-path" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "vault.yml", "#{VAULT_HEADER}encrypted-bytes\n")
      destination = pinned_destination(layout)
      output, status = run_pin(program, layout, source, destination, "vault", "false", "false",
                               "deployment vault")
      acceptance(failures, "vault-happy-path", output, status)
      next unless status.success?

      pinned = File.lstat(destination)
      failures << "vault-happy-path: protected copy is not a regular file" unless pinned.file?
      failures << "vault-happy-path: protected copy is mode #{format('%<mode>o', mode: pinned.mode & 0o777)}" unless
        (pinned.mode & 0o777) == 0o600
      failures << "vault-happy-path: protected copy is owned by #{pinned.uid}" unless pinned.uid == Process.uid
      failures << "vault-happy-path: protected copy differs from the source" unless
        File.binread(destination) == File.binread(source)
      failures << "vault-happy-path: the pin left a temporary file behind" unless
        Dir.children(layout[:protected_root]) == [File.basename(destination)]
    end
  end,
  "vault-without-header" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "vault.yml", "plaintext: not-encrypted\n")
      output, status = run_pin(program, layout, source, pinned_destination(layout), "vault",
                               "false", "false", "deployment vault")
      refusal(failures, "vault-without-header", output, status,
              "protected deployment vault input is not Ansible Vault encrypted")
      failures << "vault-without-header: a protected copy was written anyway" unless
        Dir.children(layout[:protected_root]).empty?
    end
  end,
  "symlinked-source" => lambda do |program, failures|
    with_sandbox do |layout|
      target = write_source(layout, "real-vault.yml", VAULT_HEADER)
      link = File.join(layout[:outside], "vault.yml")
      File.symlink(target, link)
      output, status = run_pin(program, layout, link, pinned_destination(layout), "vault",
                               "false", "false", "deployment vault")
      refusal(failures, "symlinked-source", output, status,
              "protected deployment vault input must be a regular non-symlink file")
    end
  end,
  "source-inside-the-repository" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "password", "secret\n", in_repository: true)
      output, status = run_pin(program, layout, source, pinned_destination(layout, "deployment-password"),
                               "password", "true", "false", "deployment password")
      refusal(failures, "source-inside-the-repository", output, status,
              "protected deployment password input must remain outside the repository")
    end
  end,
  "oversized-source" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "password", "0" * (1024 * 1024 + 1))
      output, status = run_pin(program, layout, source, pinned_destination(layout, "deployment-password"),
                               "password", "true", "false", "deployment password")
      refusal(failures, "oversized-source", output, status,
              "protected deployment password input exceeds the size limit")
    end
  end,
  "unsafe-protected-root" => lambda do |program, failures|
    with_sandbox do |layout|
      File.chmod(0o755, layout[:protected_root])
      source = write_source(layout, "vault.yml", VAULT_HEADER)
      output, status = run_pin(program, layout, source, pinned_destination(layout), "vault",
                               "false", "false", "deployment vault")
      refusal(failures, "unsafe-protected-root", output, status,
              "protected deployment vault input destination is unsafe")
    end
  end,
  "destination-outside-the-protected-root" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "vault.yml", VAULT_HEADER)
      elsewhere = File.join(layout[:root], "elsewhere")
      FileUtils.mkdir_p(elsewhere)
      output, status = run_pin(program, layout, source, File.join(elsewhere, "deployment-vault.yml"),
                               "vault", "false", "false", "deployment vault")
      refusal(failures, "destination-outside-the-protected-root", output, status,
              "protected deployment vault input destination is unsafe")
    end
  end,
  "plain-password-file" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "password", "VAULT-PASSWORD-DO-NOT-LEAK\n")
      destination = pinned_destination(layout, "deployment-password")
      output, status = run_pin(program, layout, source, destination, "password", "true", "false",
                               "deployment password")
      acceptance(failures, "plain-password-file", output, status)
      next unless status.success?

      failures << "plain-password-file: protected copy differs from the source" unless
        File.binread(destination) == "VAULT-PASSWORD-DO-NOT-LEAK\n"
    end
  end,
  # The provider runs fchdir'd into the source's own parent, with the source as
  # $0 and no inherited stdin. All three are security properties: the first is
  # what makes the pin immune to a renamed path component, the second keeps the
  # basename out of anything the shell evaluates, and the third stops a provider
  # from consuming the runner's input.
  "executable-provider-environment" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "provider", <<~PROVIDER, mode: 0o700)
        #!/bin/sh
        pwd -P
        printf '%s\\n' "$0"
        if [ -z "$(cat)" ]; then printf '(stdin-empty)\\n'; else printf '(stdin-open)\\n'; fi
      PROVIDER
      destination = pinned_destination(layout, "deployment-password")
      output, status = run_pin(program, layout, source, destination, "password", "true", "false",
                               "deployment password")
      acceptance(failures, "executable-provider-environment", output, status)
      next unless status.success?

      expected = "#{layout[:outside]}\n./provider\n(stdin-empty)\n"
      failures << "executable-provider-environment: provider saw #{File.binread(destination).inspect}" unless
        File.binread(destination) == expected
    end
  end,
  "provider-with-the-wrong-shebang" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "provider", "#!/bin/bash\nprintf 'secret\\n'\n", mode: 0o700)
      output, status = run_pin(program, layout, source, pinned_destination(layout, "deployment-password"),
                               "password", "true", "false", "deployment password")
      refusal(failures, "provider-with-the-wrong-shebang", output, status,
              "protected deployment password input provider must use the exact #!/bin/sh executable format")
    end
  end,
  "provider-containing-a-nul" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "provider", "#!/bin/sh\nprintf 'sec\0ret\\n'\n", mode: 0o700)
      output, status = run_pin(program, layout, source, pinned_destination(layout, "deployment-password"),
                               "password", "true", "false", "deployment password")
      refusal(failures, "provider-containing-a-nul", output, status,
              "protected deployment password input provider contains unsupported NUL bytes")
    end
  end,
  "provider-that-fails" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "provider", "#!/bin/sh\nexit 3\n", mode: 0o700)
      output, status = run_pin(program, layout, source, pinned_destination(layout, "deployment-password"),
                               "password", "true", "false", "deployment password")
      refusal(failures, "provider-that-fails", output, status,
              "protected deployment password input provider failed")
    end
  end,
  "provider-that-floods" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "provider", <<~PROVIDER, mode: 0o700)
        #!/bin/sh
        i=0
        while [ "$i" -lt 1100 ]; do
          printf '%01000d\\n' 0
          i=$((i + 1))
        done
      PROVIDER
      output, status = run_pin(program, layout, source, pinned_destination(layout, "deployment-password"),
                               "password", "true", "false", "deployment password")
      refusal(failures, "provider-that-floods", output, status,
              "protected deployment password input provider output exceeds the size limit")
    end
  end,
  # Costs the pin's own five-second bound, plus the one second its post-TERM wait
  # is bounded to. It is the only case that does, and it is the guard between a
  # wedged provider and a Mac proof that never returns.
  #
  # The provider ignores TERM, which is what makes that second bound load-bearing:
  # a provider that dies on the group TERM is reaped before `wait_thread.join(1)`
  # is reached, so the bound executes and returns a finished thread. Refusing to
  # die is what makes it return nil and the KILL that follows it necessary. An
  # ignored disposition survives exec, so the sleep ignores TERM too and only the
  # KILL ends either -- which is the point.
  #
  # It stays a bounded sleep rather than an unbounded loop, because a provider
  # that ignores TERM outlives everything but the KILL. kill_pin_group takes the
  # provider's group out on the deadline path, but it identifies that group from
  # `ps`, so the provider's own limit is what covers the case where that fails.
  # Sixty seconds, as this case has always used.
  "provider-that-hangs" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "provider", <<~PROVIDER, mode: 0o700)
        #!/bin/sh
        trap '' TERM
        sleep 60
      PROVIDER
      output, status = run_pin(program, layout, source, pinned_destination(layout, "deployment-password"),
                               "password", "true", "false", "deployment password")
      refusal(failures, "provider-that-hangs", output, status,
              "protected deployment password input provider timed out")
    end
  end,
  # The only case in which a reader outlives the kill, and so the only one that
  # makes the pin's reader-join bounds load-bearing. Every other blocked case
  # leaves the wedged process inside the group the pin signals, so the KILL
  # reaches it, EOF arrives on both captured pipes and each reader join returns a
  # finished thread -- the bound executes and has never had to fire.
  #
  # Here the provider backgrounds a grandchild into a process group of its own --
  # Process.setpgid(0, 0), which is portable where setsid(1) is not -- and lets it
  # inherit the provider's stdout, so terminate_group cannot reach it and no EOF
  # ever arrives. The provider itself exits 0, so nothing here goes through
  # Timeout::Error and the reader-join bound is the only thing that ends the run.
  #
  # That is why the assertions are what they are. "provider failed" from a
  # provider that ran to completion is the only diagnostic this path can produce:
  # the pin checks timed_out, oversized, unsupported and contains_nul first and
  # none of them hold, and a provider whose shell exited 0 leaves capture_failed
  # as the only remaining cause -- which is reachable only from a reader join that
  # returned nil. None of that depends on how fast the machine is. Reverting
  # either reader join to an unbounded one makes the pin wait for the grandchild
  # instead of giving up on it, which is a different outcome, not a slower one.
  "provider-whose-reader-outlives-the-kill" => lambda do |program, failures|
    name = "provider-whose-reader-outlives-the-kill"
    with_sandbox do |layout|
      # Under the sandbox root rather than the pinned source's own parent: the
      # pin re-lstats that directory after the provider runs.
      pidfile = File.join(layout[:root], "grandchild.pid")
      completed = File.join(layout[:root], "provider-completed")
      grandchild = "Process.setpgid(0, 0); " \
                   "File.write(ARGV.fetch(0), Process.pid); " \
                   "sleep Float(ARGV.fetch(1))"
      source = write_source(layout, "provider", <<~PROVIDER, mode: 0o700)
        #!/bin/sh
        '#{RbConfig.ruby}' -e '#{grandchild}' '#{pidfile}' '#{grandchild_lifetime_seconds}' &
        : > '#{completed}'
      PROVIDER
      begin
        output, status = run_pin(program, layout, source, pinned_destination(layout, "deployment-password"),
                                 "password", "true", "false", "deployment password")
        refusal(failures, name, output, status,
                "protected deployment password input provider failed")
        failures << "#{name}: the provider did not run to completion, so the refusal is not the capture path" unless
          File.file?(completed)
        failures << "#{name}: a protected copy was written anyway" unless
          Dir.children(layout[:protected_root]).empty?
        # Whatever the pin prints, it is one line and nothing else. That the line
        # is the right one is the refusal above; this is the other half, because
        # a reader that dies when its stream is closed under it must not add
        # Ruby's own thread-death header and stack trace to a gate whose failures
        # are read by substring.
        failures << "#{name}: the pin printed more than its diagnostic: #{output.inspect}" if
          output.lines.length > 1
      ensure
        reap_grandchild(failures, name, pidfile)
      end
    end
  end,
  "reuse-of-a-matching-copy" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "vault.yml", "#{VAULT_HEADER}encrypted-bytes\n")
      destination = pinned_destination(layout)
      _, status = run_pin(program, layout, source, destination, "vault", "false", "false",
                          "deployment vault")
      unless status.success?
        failures << "reuse-of-a-matching-copy: the initial pin failed"
        next
      end
      before = File.lstat(destination)
      output, status = run_pin(program, layout, source, destination, "vault", "false", "true",
                               "deployment vault")
      acceptance(failures, "reuse-of-a-matching-copy", output, status)
      failures << "reuse-of-a-matching-copy: the reused copy was rewritten" unless
        File.lstat(destination).ino == before.ino
    end
  end,
  "reuse-of-a-changed-copy" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "vault.yml", "#{VAULT_HEADER}encrypted-bytes\n")
      destination = pinned_destination(layout)
      _, status = run_pin(program, layout, source, destination, "vault", "false", "false",
                          "deployment vault")
      unless status.success?
        failures << "reuse-of-a-changed-copy: the initial pin failed"
        next
      end
      File.binwrite(source, "#{VAULT_HEADER}different-bytes\n")
      output, status = run_pin(program, layout, source, destination, "vault", "false", "true",
                               "deployment vault")
      refusal(failures, "reuse-of-a-changed-copy", output, status,
              "protected deployment vault input differs from the manual-validation protected copy")
    end
  end,
  "reuse-of-a-loosened-copy" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "vault.yml", "#{VAULT_HEADER}encrypted-bytes\n")
      destination = pinned_destination(layout)
      _, status = run_pin(program, layout, source, destination, "vault", "false", "false",
                          "deployment vault")
      unless status.success?
        failures << "reuse-of-a-loosened-copy: the initial pin failed"
        next
      end
      File.chmod(0o644, destination)
      output, status = run_pin(program, layout, source, destination, "vault", "false", "true",
                               "deployment vault")
      refusal(failures, "reuse-of-a-loosened-copy", output, status,
              "protected deployment vault input protected copy is unavailable or unsafe")
    end
  end
}.freeze

def behaviour_failures(program, names = BEHAVIOUR.keys)
  failures = []
  names.each { |name| BEHAVIOUR.fetch(name).call(program, failures) }
  failures
end

# Every ordering below is a TOCTOU property that no output can show. `before`
# must precede the syscall it guards and `after` must follow it, so each is
# asserted as a pair of offsets into the source rather than as its mere presence.
def sequence_failures(source)
  failures = []
  offset = lambda do |needle|
    index = source.index(needle)
    failures << "the pin no longer contains #{needle.inspect}" if index.nil?
    index
  end
  ordered = lambda do |description, *needles|
    offsets = needles.map(&offset)
    return if offsets.any?(&:nil?)
    return if offsets.each_cons(2).all? { |first, second| first < second }

    failures << "the pin no longer #{description}"
  end

  failures << "the pin no longer opens the source with NOFOLLOW" unless
    source.include?("flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK")
  failures << "the pin no longer creates the protected copy exclusively" unless
    source.include?("output_flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW")
  # A held directory descriptor is only a defence if every subsequent look at the
  # source goes through it. Four do, and each must stay an in_directory call.
  %w[held_path_before source held_path_after provider_held_path_after].each do |binding|
    failures << "the pin no longer reaches #{binding} through the held directory" unless
      source.match?(/^\s*#{binding} = in_directory\(parent_directory\)/)
  end
  ordered.call(
    "stats the canonical parent before it opens it",
    "canonical_parent_before = File.lstat(parent_before)",
    "parent_directory = File.open(parent_before, flags)",
    "parent_descriptor_before = parent_directory.stat"
  )
  ordered.call(
    "brackets the read between two descriptor stats",
    "descriptor_before = source.stat",
    "bytes = source.read(maximum_size + 1)",
    "descriptor_after = source.stat"
  )
  ordered.call(
    "re-checks the path and the held name after the read",
    "bytes = source.read(maximum_size + 1)",
    "path_after = File.lstat(source_path)",
    "held_path_after = in_directory(parent_directory)"
  )
  ordered.call(
    "re-checks the source after running the provider",
    "provider = execute_provider(parent_directory, basename, bytes, maximum_size)",
    "provider_held_path_after = in_directory(parent_directory)",
    "fail_pin(label, \"provider timed out\")"
  )
  ordered.call(
    "writes, syncs and only then renames the protected copy",
    "output.fsync",
    "File.chmod(mode, temporary_path)",
    "File.rename(temporary_path, destination_path)"
  )
  ordered.call(
    "re-checks the protected root after writing",
    "File.rename(temporary_path, destination_path)",
    "protected_root_final = File.lstat(protected_root)"
  )
  failures
end

def interface_failures(program)
  failures = []
  failures << "the pin is not executable" unless File.executable?(program)
  failures << "the pin has no ruby shebang" unless
    File.open(program, &:readline) == "#!/usr/bin/env ruby\n"
  _, status = Open3.capture2e(RbConfig.ruby, "-c", program)
  failures << "the pin does not parse" unless status.success?
  failures
end

# Each planted regression names the cases it should move and the exact failure
# the suite must emit when it does. A mutation that only turns the suite red
# somewhere is not proof that the case guarding it works -- and the wording
# distinguishes a guard that was removed ("accepted what it must refuse") from
# one that now fails for a different reason, which is a different regression.
MUTATIONS = [
  {
    label: "an unencrypted vault",
    from: 'if kind == "vault" && !bytes.start_with?("$ANSIBLE_VAULT;")',
    to: "if false",
    cases: %w[vault-without-header],
    expects: "vault-without-header: the pin accepted what it must refuse"
  },
  {
    label: "a symlinked source",
    from: "path_before.file? && held_path_before.file?",
    to: "true",
    cases: %w[symlinked-source],
    expects: "symlinked-source: expected \"protected deployment vault input must be a regular non-symlink file\""
  },
  {
    label: "a source inside the repository",
    from: 'if external == "true" &&',
    to: "if false &&",
    cases: %w[source-inside-the-repository],
    expects: "source-inside-the-repository: the pin accepted what it must refuse"
  },
  {
    label: "an oversized source",
    from: "maximum_size = kind == \"vault\" ? 16 * 1024 * 1024 : 1024 * 1024",
    to: "maximum_size = 64 * 1024 * 1024",
    cases: %w[oversized-source],
    expects: "oversized-source: the pin accepted what it must refuse"
  },
  {
    label: "a world-readable protected root",
    from: "(protected_root_before.mode & 0o777) == 0o700 &&",
    to: "",
    cases: %w[unsafe-protected-root],
    expects: "unsafe-protected-root: the pin accepted what it must refuse"
  },
  {
    label: "a provider with a foreign interpreter",
    from: 'unless provider_bytes.lines.first == "#!/bin/sh\n"',
    to: "unless true",
    cases: %w[provider-with-the-wrong-shebang],
    expects: "provider-with-the-wrong-shebang: the pin accepted what it must refuse"
  },
  {
    label: "a provider carrying a NUL",
    from: 'if provider_bytes.include?("\0")',
    to: "if false",
    cases: %w[provider-containing-a-nul],
    expects: "provider-containing-a-nul: the pin accepted what it must refuse"
  },
  {
    label: "a wedged provider",
    from: "result[:timed_out] = true",
    to: "result[:timed_out] = false",
    cases: %w[provider-that-hangs],
    expects: "provider-that-hangs: expected \"protected deployment password input provider timed out\""
  },
  {
    label: "a group-readable protected copy",
    from: "mode = 0o600",
    to: "mode = 0o640",
    cases: %w[vault-happy-path],
    expects: "vault-happy-path: protected copy is mode 640"
  },
  {
    label: "a resumed run handed different bytes",
    from: "destination_bytes == bytes",
    to: "true",
    cases: %w[reuse-of-a-changed-copy],
    expects: "reuse-of-a-changed-copy: the pin accepted what it must refuse"
  },
  {
    label: "an unbounded reader join after the kill",
    from: "next if reader.join(1)",
    to: "next if reader.join",
    cases: %w[provider-whose-reader-outlives-the-kill],
    # Unbounded, the join waits for the grandchild rather than giving up on it,
    # so the pin captures the provider's (empty) output, calls it a success and
    # writes the copy. Shortening the grandchild's life is what makes that
    # difference an acceptance this suite names instead of a hang the deadline
    # has to catch; it does not make the mutation any less detected, because a
    # pin that waits accepts whenever the wait ends.
    environment: { "PIN_GRANDCHILD_LIFETIME" => "3" },
    expects: "provider-whose-reader-outlives-the-kill: the pin accepted what it must refuse"
  },
  {
    label: "a reader whose IOError escapes bounded_read",
    from: "rescue IOError\n  { bytes: \"\", failed: true }",
    to: "rescue Errno::ENOTTY\n  { bytes: \"\", failed: true }",
    cases: %w[provider-whose-reader-outlives-the-kill],
    # bounded_read's rescue is what actually silences the reader that dies when
    # the pin closes its stream: closing a stream under a parked IO#read raises
    # "stream closed in another thread" there, and the rescue turns it into a
    # failed capture. Narrow the class and the exception escapes the thread
    # instead, Thread#join re-raises it into the cleanup, the whole popen3 block
    # unwinds into `rescue SystemCallError, IOError` -- and the pin returns a
    # result with an empty output and no recorded failure, so it writes an empty
    # protected copy and the Mac proof gets an empty vault password.
    #
    # This is not the report_on_exception property. Those two lines sit behind
    # this rescue, so they never see an exception while it stands; the noise they
    # suppress is reachable in the four capture3_with_timeout copies, whose
    # readers have no rescue of their own, and not here.
    expects: "provider-whose-reader-outlives-the-kill: the pin accepted what it must refuse"
  }
].freeze

# The sequencing layer's own regression: a look at the source that stops going
# through the held directory descriptor is exactly the TOCTOU window the pin
# exists to close, and it changes no output at all.
SEQUENCE_MUTATION = {
  label: "an unheld post-read lstat",
  from: 'held_path_after = in_directory(parent_directory) { File.lstat("./#{basename}") }',
  to: "held_path_after = File.lstat(source_path)"
}.freeze

def mutate(source, mutation)
  from = mutation.fetch(:from)
  abort "self-test could not plant #{mutation.fetch(:label)}: #{from.inspect} is absent" unless
    source.include?(from)

  source.sub(from, mutation.fetch(:to))
end

# One mutation needs a shorter fixture grandchild than the suite's own default,
# and the cases read it from the environment because that is how the deadline
# beside it is configured too.
def with_environment(overrides)
  previous = overrides.keys.to_h { |key| [key, ENV[key]] }
  overrides.each { |key, value| ENV[key] = value }
  yield
ensure
  previous.each { |key, value| ENV[key] = value }
end

def with_mutant(source, mutation)
  Dir.mktmpdir("nas-platform-pin-mutant.") do |directory|
    path = File.join(directory, "pin-protected-input.rb")
    File.write(path, mutate(source, mutation))
    File.chmod(0o755, path)
    yield path
  end
end

source_text = File.read(PROGRAM)

if ARGV.include?("--self-test")
  MUTATIONS.each do |mutation|
    with_mutant(source_text, mutation) do |mutant|
      caught = with_environment(mutation.fetch(:environment, {})) do
        behaviour_failures(mutant, mutation.fetch(:cases))
      end
      abort "self-test failed: #{mutation.fetch(:label)} was accepted" if caught.empty?
      next if caught.any? { |failure| failure.include?(mutation.fetch(:expects)) }

      abort "self-test failed: #{mutation.fetch(:label)} was caught by the wrong assertion: #{caught.join(' | ')}"
    end
  end
  planted = mutate(source_text, SEQUENCE_MUTATION)
  unless sequence_failures(planted).any? { |failure| failure.include?("held_path_after") }
    abort "self-test failed: #{SEQUENCE_MUTATION.fetch(:label)} was accepted"
  end
  puts "protected input pin: self-test detects #{MUTATIONS.length + 1} planted regressions"
  exit
end

failures = interface_failures(PROGRAM) + sequence_failures(source_text) + behaviour_failures(PROGRAM)
abort failures.map { |failure| "FAIL #{failure}" }.join("\n") unless failures.empty?
puts "protected input pin: #{BEHAVIOUR.length} behaviours and its TOCTOU orderings " \
     "verified against the real program"
