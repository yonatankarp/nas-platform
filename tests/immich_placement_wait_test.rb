#!/usr/bin/env ruby
# frozen_string_literal: true

# Slices wait_for_placed_originals out of the Immich runtime contract and runs it
# against a scripted server whose queues and asset paths move one step per poll.
# The clean-restore seed must not dump the database until the storage template
# has placed every seeded original (#907): a dump taken earlier holds rows naming
# upload/ paths the template then moved away from, which is what the immich lane
# of #921 restored and refused.

require "json"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "immich-runtime.rb")
SOURCE = File.read(CONTRACT)
IDS = %w[11111111-1111-4111-8111-111111111111 22222222-2222-4222-8222-222222222222].freeze
UPLOAD = IDS.map { |id| "/data/upload/owner/ab/cd/#{id}.jpg" }.freeze
PLACED = %w[/data/library/owner/2026/2026-09-28/photo.jpg
            /data/library/owner/2026/2026-09-28/video.mp4].freeze

class ContractFailure < StandardError; end

def fail_contract(message)
  raise ContractFailure, message
end

def slice(name, next_name)
  SOURCE[/^def #{name}\b.*?(?=^def #{next_name}\b)/m] or abort("could not slice #{name} out of #{CONTRACT}")
end

eval(slice("safe_id", "inspect_container"))
eval(slice("wait_for_placed_originals", "clean_restore_records"))

# One snapshot per poll; sleep advances to the next and the last one holds.
$script = []
$step = 0

def sleep(_seconds)
  $step = [$step + 1, $script.length - 1].min
end

def request(_method, path, token:)
  raise "unexpected token" unless token == "token"

  snapshot = $script.fetch($step)
  case path
  when %r{\A/api/queues/(\w+)\z}
    [nil, snapshot.fetch(:queues).fetch(Regexp.last_match(1))]
  when %r{\A/api/assets/([0-9a-f-]+)\z}
    [nil, { "id" => Regexp.last_match(1), "originalPath" => snapshot.fetch(:paths)[IDS.index(Regexp.last_match(1))] }]
  else raise "unscripted #{path}"
  end
end

def queue(paused: false, **counts)
  { "name" => "fixture", "isPaused" => paused,
    "statistics" => { "active" => 0, "completed" => 0, "failed" => 0, "delayed" => 0,
                      "waiting" => 0, "paused" => 0 }.merge(counts.transform_keys(&:to_s)) }
end

def snapshot(paths, metadata: queue, migration: queue)
  { paths: paths, queues: { "metadataExtraction" => metadata, "storageTemplateMigration" => migration } }
end

# The lane's seed with the dump modelled as reading every row's path at the
# moment it is requested; the restore then succeeds only if those paths are
# where the files finally are.
def seed(script, wait:)
  $script = script
  $step = 0
  wait_for_placed_originals("token", IDS, stale_polls: 3) if wait
  dumped = IDS.map { |id| request("get", "/api/assets/#{id}", token: "token").last.fetch("originalPath") }
  $step = $script.length - 1
  dumped == $script.last.fetch(:paths)
end

def outcome
  yield
  :returned
rescue ContractFailure => error
  error.message
end

failures = []
check = ->(condition, message) { failures << message unless condition }

moving = [
  snapshot(UPLOAD, metadata: queue(active: 2)),
  snapshot(UPLOAD, metadata: queue(completed: 2), migration: queue(waiting: 2)),
  snapshot(PLACED, metadata: queue(completed: 2), migration: queue(completed: 2))
]
check.call(!seed(moving, wait: false), "a dump taken without the wait restored cleanly, so the model proves nothing")
check.call(seed(moving, wait: true), "a dump taken after the wait still names pre-move paths")
check.call($step == moving.length - 1, "the wait returned before the template placed the originals")

never_placed = [snapshot(UPLOAD)]
result = outcome { seed(never_placed, wait: true) }
check.call(result.is_a?(String) && result.include?("never reached their storage template paths") &&
           result.include?("0 of 2 placed"),
           "drained queues with unplaced originals did not fail loudly: #{result.inspect}")

stuck = [snapshot(UPLOAD, migration: queue(active: 1))]
result = outcome { seed(stuck, wait: true) }
check.call(result.is_a?(String) && result.include?("unchanged for 3 polls"),
           "a queue that never drains did not fail on the progress bound: #{result.inspect}")

# Ten polls of steady progress against a bound of three: the wait is bounded on
# lack of progress, never on how long the work takes.
slow = (0...10).map { |done| snapshot(UPLOAD, metadata: queue(waiting: 10 - done, completed: done)) } +
       [snapshot(PLACED)]
check.call(outcome { seed(slow, wait: true) } == :returned, "steady progress past the stale bound was refused")

result = outcome { seed([snapshot(UPLOAD, migration: queue(paused: true))], wait: true) }
check.call(result == "Immich storageTemplateMigration queue is paused", "a paused queue was not refused: #{result.inspect}")

malformed = snapshot(UPLOAD)
malformed[:queues]["metadataExtraction"] = { "isPaused" => false, "jobCounts" => {} }
result = outcome { seed([malformed], wait: true) }
check.call(result == "GET /api/queues/metadataExtraction returned an unsupported schema",
           "the legacy /api/jobs shape was accepted from /api/queues: #{result.inspect}")

# The seed itself: the wait sits between the uploads and the dump request.
block = SOURCE[/^if MODE == "clean-restore-seed"\n.*?^end\n/m].to_s
order = ["records = clean_restore_records(token)", "wait_for_placed_originals(token,", '"backup-database"']
positions = order.map { |needle| block.index(needle) }
check.call(positions.none?(&:nil?) && positions == positions.sort,
           "the clean-restore seed no longer waits for placement before requesting the dump: #{positions.inspect}")

if failures.empty?
  puts "Immich placement wait: the seed dumps only after the template placed every original"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Immich placement wait failures"
end
