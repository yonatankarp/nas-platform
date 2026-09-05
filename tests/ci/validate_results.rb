#!/usr/bin/env ruby

module ValidateResults
  # Every value GitHub can report in `needs.<job>.result`. Anything else is a
  # typo or a schema change, never a verdict, so it is refused for every job --
  # including the non-blocking ones, whose tolerance would otherwise swallow it
  # and turn the aggregate check into a rubber stamp.
  KNOWN_RESULTS = %w[success skipped failure cancelled].freeze

  # What a blocking job may report without failing the gate.
  ALLOWED_RESULTS = %w[success skipped].freeze

  # Jobs whose result is reported rather than enforced, because the workflow
  # declares them non-blocking and means it.
  #
  # `toolchain` publishes the controller image to ghcr.io as an optimization:
  # tests/integration.sh builds the image locally when it cannot pull one and
  # installs the toolchain inside the run when it cannot build one, which is
  # exactly what every suite leg did before the job existed. The suites matrix
  # therefore depends on it *without* the implicit success gate `needs` carries,
  # so a failed publish costs time rather than coverage. Failing the gate on it
  # here made the optimization a precondition after all -- a registry hiccup
  # reddened a run whose coverage was complete -- which is the contradiction
  # issue #360 filed. tests/ci/workflow_test.rb derives this list back out of the
  # suites condition, so the two cannot drift apart again.
  NON_BLOCKING_JOBS = %w[toolchain].freeze

  JOB_NAME = /\A[A-Za-z0-9_][A-Za-z0-9_-]*\z/

  def self.run_cli(argv)
    abort "usage: #{File.basename($PROGRAM_NAME)} JOB=RESULT [JOB=RESULT ...]" if argv.empty?

    seen_jobs = {}

    argv.each do |argument|
      parts = argument.split("=", -1)
      abort "malformed job result: #{argument.inspect}" unless parts.length == 2

      job, result = parts
      abort "malformed job name: #{job.inspect}" unless job.match?(JOB_NAME)
      abort "duplicate job: #{job}" if seen_jobs.key?(job)
      abort "unexpected result for #{job}: #{result.inspect}" unless KNOWN_RESULTS.include?(result)

      unless ALLOWED_RESULTS.include?(result)
        unless NON_BLOCKING_JOBS.include?(job)
          abort "unexpected result for #{job}: #{result.inspect}"
        end

        # Reported, not enforced. The job is red in the run's own check list
        # already; this is what keeps a permanently broken publish visible in the
        # one place that reads every result, instead of only in the leg nobody
        # opens once it stops blocking anything.
        warn "non-blocking: #{job} reported #{result.inspect}"
      end

      seen_jobs[job] = true
    end

    puts "accepted: #{argv.join(' ')}"
  end
end

ValidateResults.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
