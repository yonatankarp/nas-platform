#!/usr/bin/env ruby

module ValidateResults
  # Every value `needs.<job>.result` can hold; anything else is refused for every
  # job, non-blocking ones included, or their tolerance would swallow a typo.
  KNOWN_RESULTS = %w[success skipped failure cancelled].freeze

  # What a blocking job may report without failing the gate.
  ALLOWED_RESULTS = %w[success skipped].freeze

  # Reported, not enforced: `toolchain` only publishes an image the suites can
  # build themselves, so a failed publish costs time, not coverage (#360).
  # tests/ci/workflow_test.rb derives this list from the suites condition.
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

        # Keeps a permanently broken publish visible in the one place that reads every result.
        warn "non-blocking: #{job} reported #{result.inspect}"
      end

      seen_jobs[job] = true
    end

    puts "accepted: #{argv.join(' ')}"
  end
end

ValidateResults.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
