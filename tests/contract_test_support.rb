# frozen_string_literal: true
#
# Shared helpers the tests/*_contract_test.rb files drive their wrappers and
# self-tests with (#835); per-file copies drifted (#352).

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

  # Returns [planted, nil], or [nil, why] when the plant does not match exactly
  # the declared number of times or changes nothing.
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

  # Aborts; call on the main thread (an abort in a pool worker loses the result).
  def plant(source, mutation, occurrences: mutation.fetch(:occurrences, 1))
    planted, error = plant_or_error(source, mutation, occurrences: occurrences)
    abort "self-test #{error}" if error
    planted
  end

  # [rows, nil], or [nil, why] when a name matches no row (a typo would still pass).
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

  # Builds the sandbox and writes the wrapper and programs into tests/contracts/.
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

  # Runs the contract with STDIN_PROBE as its program and a payload on stdin;
  # fails if the program got the payload or the contract swallowed it. `status:`
  # checks the trailing `cat`, not the contract.
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

  # Like stdin_probe_failures but keeps the real program; returns
  # [stdout, stderr, status, payload_survived].
  def run_with_caller_stdin(env, contract, args)
    command = "#{contract.shellescape} #{args.map(&:shellescape).join(' ')}; " \
              "rc=$?; printf 'left:'; cat; exit $rc"
    stdout, stderr, status = Open3.capture3(env, "/bin/sh", "-c", command, stdin_data: "caller-payload\n")
    [stdout, stderr, status, stdout.include?("left:caller-payload")]
  end
end
