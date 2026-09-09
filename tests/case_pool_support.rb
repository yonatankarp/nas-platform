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

# One case, run with its own failure list. Both widths below go through this,
# so the parallel and the serial paths cannot report different things: there is
# one per-case body, not two kept in agreement by hand.
#
# A case that raises a StandardError becomes a failure of that case -- named,
# with the exception class and message -- rather than the end of the run. A row
# whose fixture cannot be built is a broken row, and the four contract tests
# that pool by return value already record it this way.
#
# The message is *appended* to the case's list rather than replacing it, which
# is the one place this differs from those four. They can rebuild the list
# because their block returns its findings; here the block appends to the list
# it is handed, so a case that recorded two findings and then raised owes three
# entries, not one. Only StandardError is caught -- SystemExit and the rest
# still end the run, which is the next comment.
def run_pool_case(item, collected)
  yield item, collected
rescue StandardError => error
  collected << "#{item.is_a?(Hash) ? item.fetch(:name, item) : item}: case raised " \
               "#{error.class}: #{error.message}"
end

# Runs +items+ through the pool, appending each case's failures to +failures+.
#
# The block takes the case and *its own* failure list, never the shared one:
# every case collects into a private array and the arrays are concatenated in
# the original order once the pool drains, so the report a developer reads is
# the same list in the same order the serial version produced. Both widths run
# the same per-case body, `run_pool_case` above, and a single worker runs it in
# the calling thread -- which is the serial path POLICY_JOBS=1 takes.
#
# That invariant did not hold before #514, and `tests/case_pool_behavior_test.rb`
# is what holds it now, one child process per width so each meets the real
# environment variable. A case raising a StandardError used to kill its worker,
# `Thread#join` re-raised it here, and the concatenation below was never
# reached: seven cases' real findings were discarded to report the eighth's
# exception, and the two widths reported different lists -- 0 failures at
# CASE_POOL_WORKERS=4 against 2 at POLICY_JOBS=1, so the flag CLAUDE.md
# prescribes for bisecting a load-dependent failure changed the evidence rather
# than serialising it.
#
# `abort` in a case still ends the run and still reports nothing, and that is
# deliberate rather than the same bug in a smaller form. SystemExit is not a
# StandardError, so `run_pool_case` does not rescue it: the worker thread dies,
# `Thread#join` re-raises it here, and the process exits on it with whatever
# `abort` wrote on stderr and no report assembled. Anything a case needs to
# abort over -- a fixture that cannot be built, a row that names something
# absent -- is the check saying it cannot continue, and belongs before the pool.
# Recording each case's array *before* running it, so the other cases' findings
# could ride out alongside the abort, was considered and rejected: the
# concatenation below is still not reached, so those findings would land in an
# array no caller ever prints, and the mechanism would be one nothing could
# observe.
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
