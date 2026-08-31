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
require "tmpdir"

PROGRAM = File.join(__dir__, "pin-protected-input.rb")
VAULT_HEADER = "$ANSIBLE_VAULT;1.1;AES256\n"

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

def run_pin(program, layout, source, destination, kind, external, reuse, label)
  Open3.capture2e(
    RbConfig.ruby, program, source, destination, label, kind,
    external, layout[:repository], layout[:protected_root], reuse,
    stdin_data: ""
  )
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
  # Costs the pin's own five-second bound. It is the only case that does, and it
  # is the guard between a wedged provider and a Mac proof that never returns.
  "provider-that-hangs" => lambda do |program, failures|
    with_sandbox do |layout|
      source = write_source(layout, "provider", "#!/bin/sh\nsleep 60\n", mode: 0o700)
      output, status = run_pin(program, layout, source, pinned_destination(layout, "deployment-password"),
                               "password", "true", "false", "deployment password")
      refusal(failures, "provider-that-hangs", output, status,
              "protected deployment password input provider timed out")
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
      caught = behaviour_failures(mutant, mutation.fetch(:cases))
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
