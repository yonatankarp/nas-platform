# frozen_string_literal: true
#
# The scaffolding the tests/*_contract_test.rb files drive their wrappers and
# their self-tests with. Until #835 each file carried its own copy of every
# helper here, and copies drift: #352 found the judge in seven bodies, two of
# them accepting a refusal for the wrong reason. One copy cannot drift from
# itself.
#
# What stays in each test file is what genuinely differs per contract: which
# programs sit beside its wrapper, how its fixture repository is built, and which
# invocations its stdin rows probe.

require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"

module ContractTestSupport
  # Stands in for a contract program and reports what it was handed on stdin.
  STDIN_PROBE = <<~'PROBE'
    warn "probe read #{$stdin.read.inspect}"
    exit 1
  PROBE

  # Applies one mutation to a program's source and returns [planted, nil], or
  # [nil, why] when the mutation cannot be planted exactly as written. A plant
  # that matches a different number of times than it declares, or that changes
  # nothing, would test some other program than the one its label names.
  def plant_or_error(source, mutation, occurrences: mutation.fetch(:occurrences, 1))
    from = mutation.fetch(:from)
    found = source.scan(from).length
    unless found == occurrences
      return [nil, "could not plant #{mutation.fetch(:label)}: expected #{occurrences} " \
                   "match(es) of #{from.inspect}, found #{found}"]
    end

    planted = occurrences == 1 ? source.sub(from, mutation.fetch(:to)) : source.gsub(from, mutation.fetch(:to))
    return [nil, "planted nothing for #{mutation.fetch(:label)}"] if planted == source

    [planted, nil]
  end

  # plant_or_error, aborting with its reason. An abort inside a pool worker kills
  # the thread before it records a result, so call this on the main thread.
  def plant(source, mutation, occurrences: mutation.fetch(:occurrences, 1))
    planted, error = plant_or_error(source, mutation, occurrences: occurrences)
    abort "self-test #{error}" if error
    planted
  end

  # The rows a mutation names, as [rows, nil], or [nil, why] when a name matches
  # no row -- a misspelt name would otherwise select fewer rows and still pass.
  def rows_named_or_error(rows, names)
    selected = rows.select { |row| names.include?(row.fetch(:name)) }
    unless selected.length == names.length
      missing = names - selected.map { |row| row.fetch(:name) }
      return [nil, "names a row that does not exist: #{missing.inspect}"]
    end

    [selected, nil]
  end

  # rows_named_or_error, aborting with its reason; main thread only, as plant.
  def rows_named(rows, names)
    selected, error = rows_named_or_error(rows, names)
    abort "self-test #{error}" if error
    selected
  end

  # Builds a sandbox repository with the calling file's own
  # build_fixture_repository, writes the wrapper as tests/contracts/<service>.sh
  # and each program as tests/contracts/<service>-<name>.rb beside it, and yields
  # the wrapper's path and the sandbox root.
  def with_contract_sandbox(service, wrapper, programs)
    Dir.mktmpdir("nas-platform-#{service}-wrapper.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      contracts = File.join(root, "tests", "contracts")
      FileUtils.mkdir_p(contracts)
      wrapper_path = File.join(contracts, "#{service}.sh")
      File.write(wrapper_path, wrapper)
      File.chmod(0o755, wrapper_path)
      programs.each do |name, content|
        destination = File.join(contracts, "#{service}-#{name}.rb")
        File.write(destination, content)
        File.chmod(0o644, destination)
      end
      yield wrapper_path, root
    end
  end

  # Runs `<contract> <args>; printf 'left:'; cat` with a payload on stdin, where
  # the contract's program has been replaced by STDIN_PROBE, and returns what
  # went wrong: the program was handed the payload, or the contract swallowed it
  # before the shell's own `cat` could read it back. `status:` also requires the
  # probing shell to succeed; that status is `cat`'s, so it says nothing about a
  # run that ends in an exec'd probe. A block receives the combined output and
  # returns any further failures.
  def stdin_probe_failures(contract, args, env, prefix: "stdin", subject: "the program", status: true)
    command = "#{contract.shellescape} #{args.map(&:shellescape).join(' ')}; printf 'left:'; cat"
    stdout, stderr, result = Open3.capture3(env, "/bin/sh", "-c", command, stdin_data: "caller-payload\n")
    output = stdout + stderr
    failures = []
    failures << "#{prefix}: the probing shell itself failed: #{output.strip}" if status && !result.success?
    failures << "#{prefix}: #{subject} was handed the caller's input: #{output.strip.inspect}" unless
      output.include?('probe read ""')
    failures << "#{prefix}: the caller's input did not survive the contract: #{output.strip.inspect}" unless
      output.include?("left:caller-payload")
    failures.concat(Array(yield(output))) if block_given?
    failures
  end

  # For probes that keep the real program below them rather than replacing it:
  # runs `<contract> <args>` with a payload on stdin and returns
  # [stdout, stderr, status, survived], where status is the contract's own and
  # survived says whether the payload was still there for the caller afterwards.
  def run_with_caller_stdin(env, contract, args)
    command = "#{contract.shellescape} #{args.map(&:shellescape).join(' ')}; " \
              "rc=$?; printf 'left:'; cat; exit $rc"
    stdout, stderr, status = Open3.capture3(env, "/bin/sh", "-c", command, stdin_data: "caller-payload\n")
    [stdout, stderr, status, stdout.include?("left:caller-payload")]
  end
end
