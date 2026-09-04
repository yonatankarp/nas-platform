# frozen_string_literal: true

# The bounded case pool the slow policy checks drive their independent cases
# through.
#
# The pattern is tests/media_acquisition_reconciliation_support.rb's
# `in_parallel_cases`, which the fourteen contract tests each carry their own
# copy of. This file exists so the checks converted for issue #319 share one
# copy instead of adding eight more: every one of them spends its wall time
# waiting on a subprocess -- ansible-playbook, a contract program, a policy
# script -- and a case that waits alone is a case the gate has to place in its
# own slot.
#
# `require "digest"` only installs an autoload for Digest::SHA256. Workers touch
# it for the first time concurrently, and autoloading it from several threads at
# once raises "Digest::Base cannot be directly inherited" on the Ruby the runners
# carry, so anything that hashes inside a case loads it here rather than there.
require "digest/sha2"
require "etc"

# Never more workers than cores. tests/validate-policy.sh already runs its checks
# in a pool of `nproc` workers, so a check that forks its own pool of `nproc`
# oversubscribes the machine by the core count; capping at the core count keeps
# the product bounded by what the runner can actually run. The 8 ceiling is the
# one the fourteen existing copies carry, so a developer machine with 16 cores
# does not spawn 16 Ansible runs per check.
#
# Sizing *down* to leave room for the rest of the gate is not the fix and has
# been measured: CLAUDE.md records the static job going from 32 minutes to over
# 45 when the acquisition pool was halved, because the throughput lost exceeded
# the contention saved.
#
# POLICY_JOBS=1 is how the gate is serialised for bisecting a failure that only
# appears under load. That has to reach in here too -- an outer pool of one
# driving inner pools of eight is still a concurrent run -- so it pins the case
# workers to one and restores the original case order along with it.
# CASE_POOL_WORKERS overrides both, for measuring a single check at a chosen
# width.
CASE_POOL_WORKERS = Integer(
  ENV.fetch("CASE_POOL_WORKERS") do
    ENV.fetch("POLICY_JOBS", "") == "1" ? "1" : [Etc.nprocessors, 8].min.to_s
  end
)

# Runs +items+ through the pool, appending each case's failures to +failures+.
#
# The block takes the case and *its own* failure list, never the shared one:
# every case collects into a private array and the arrays are concatenated in
# the original order once the pool drains, so the report a developer reads is
# the same list in the same order the serial version produced. A single worker
# yields the shared list directly, which is the serial path POLICY_JOBS=1 takes.
#
# Anything a case needs to `abort` over -- a fixture that cannot be built, a row
# that names something absent -- belongs before the pool. `abort` inside a worker
# raises SystemExit there: the thread dies without recording its result and the
# pool reports a KeyError in place of the sentence that explains what happened.
def in_parallel_cases(failures, items)
  items = items.to_a
  workers = [CASE_POOL_WORKERS, items.length].min
  return items.each { |item| yield item, failures } if workers <= 1

  pending = Queue.new
  items.each_with_index { |item, index| pending << [index, item] }
  collected = {}
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
        yield item, local
        lock.synchronize { collected[index] = local }
      end
    end
  end.each(&:join)
  collected.keys.sort.each { |index| failures.concat(collected.fetch(index)) }
end
