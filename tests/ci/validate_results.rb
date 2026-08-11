#!/usr/bin/env ruby

ALLOWED_RESULTS = %w[success skipped].freeze

abort "usage: #{File.basename($PROGRAM_NAME)} JOB=RESULT [JOB=RESULT ...]" if ARGV.empty?

seen_jobs = {}

ARGV.each do |argument|
  parts = argument.split("=", -1)
  abort "malformed job result: #{argument.inspect}" unless parts.length == 2

  job, result = parts
  abort "malformed job name: #{job.inspect}" unless job.match?(/\A[A-Za-z0-9_][A-Za-z0-9_-]*\z/)
  abort "duplicate job: #{job}" if seen_jobs.key?(job)
  abort "unexpected result for #{job}: #{result.inspect}" unless ALLOWED_RESULTS.include?(result)

  seen_jobs[job] = true
end

puts "accepted: #{ARGV.join(' ')}"
