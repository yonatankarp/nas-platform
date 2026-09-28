# frozen_string_literal: true

# The one bounded case pool the slow checks share (#637), so a fix lands once and
# CASE_POOL_WORKERS is the only knob. digest/sha2 is loaded eagerly: autoloading
# Digest::SHA256 from several threads at once raises.
require "digest/sha2"
require "etc"

# Never more workers than cores: tests/validate-policy.sh already runs `nproc` checks,
# so a per-check pool wider than the cores oversubscribes the runner (8 is the ceiling).
# POLICY_JOBS=1 pins this to one worker; CASE_POOL_WORKERS overrides both.
CASE_POOL_WORKERS = Integer(
  ENV.fetch("CASE_POOL_WORKERS") do
    ENV.fetch("POLICY_JOBS", "") == "1" ? "1" : [Etc.nprocessors, 8].min.to_s
  end
)

# One case with its own failure list; both widths run this. A StandardError is appended
# as a named failure of that case; SystemExit and the rest still end the run.
def run_pool_case(item, collected)
  yield item, collected
rescue StandardError => error
  collected << "#{item.is_a?(Hash) ? item.fetch(:name, item) : item}: case raised " \
               "#{error.class}: #{error.message}"
end

# Runs +items+ through the pool; each case gets a private list, concatenated in original
# order, so both widths report identically (tests/case_pool_behavior_test.rb, #514).
# `abort` in a case ends the run with no report, deliberately: abort before the pool.
def in_parallel_cases(failures, items, &case_body)
  items = items.to_a
  workers = [CASE_POOL_WORKERS, items.length].min
  collected = {}
  if workers <= 1
    items.each_with_index do |item, index|
      local = []
      run_pool_case(item, local, &case_body)
      collected[index] = local
    end
  else
    pending = Queue.new
    items.each_with_index { |item, index| pending << [index, item] }
    lock = Mutex.new
    Array.new(workers) do
      Thread.new do
        loop do
          index, item = begin
                          pending.pop(true)
                        rescue ThreadError
                          break
                        end
          local = []
          run_pool_case(item, local, &case_body)
          lock.synchronize { collected[index] = local }
        end
      end
    end.each(&:join)
  end
  collected.keys.sort.each { |index| failures.concat(collected.fetch(index)) }
end

# By-value shape: cases RETURN their findings. Deliberately not built on the two helpers
# above: tests/case_pool_behavior_test.rb rewrites their bodies by literal text, and the
# names here are chosen so its `\b` scan cannot match them.
def run_pool_case_returning(item, &case_body)
  Array(case_body.call(item))
rescue StandardError => error
  ["#{item.is_a?(Hash) ? item.fetch(:name, item) : item}: case raised " \
   "#{error.class}: #{error.message}"]
end

def in_parallel_case_results(items, &case_body)
  items = items.to_a
  workers = [CASE_POOL_WORKERS, items.length].min
  collected = {}
  if workers <= 1
    items.each_with_index do |item, index|
      collected[index] = run_pool_case_returning(item, &case_body)
    end
  else
    pending = Queue.new
    items.each_with_index { |item, index| pending << [index, item] }
    lock = Mutex.new
    Array.new(workers) do
      Thread.new do
        loop do
          index, item = begin
                          pending.pop(true)
                        rescue ThreadError
                          break
                        end
          local = run_pool_case_returning(item, &case_body)
          lock.synchronize { collected[index] = local }
        end
      end
    end.each(&:join)
  end
  collected.keys.sort.flat_map { |index| collected.fetch(index) }
end
