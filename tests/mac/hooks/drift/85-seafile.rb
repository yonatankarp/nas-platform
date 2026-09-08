#!/usr/bin/env ruby
# Switch Seafile's file indexing back on by hand, which is the drift the Mac
# lane's reconcile repairs.
#
# usage: 85-seafile.rb   (no arguments; every input is an environment variable)
#
# tests/mac/hooks/drift/85-seafile.sh is the hook this belongs to. It requires
# PLATFORM_DOCKER_ROOT and PLATFORM_SEAFILE_CONTAINER, runs this program, and
# then insists the Seafile contract refuses the drifted deployment with its own
# fixed diagnostic. Only the mutation lives here; the hook's comment records why
# this key is the one worth drifting and why the refusal comes from the contract
# rather than from verify.yml.
#
# The edit is made through `docker exec` rather than against the host path
# directly, and that is not decoration. seafevents.conf is written by the server
# running as root inside a bind mount, so on Linux -- which the integration proof
# platform is -- the host copy is root-owned and a hook running as anybody else
# cannot write it. Inside the container there is no such question. The host copy
# is read here to compose the new content and read again to confirm the write
# landed, which is also what proves the two paths are the same file before the
# contract is asked to say so.
require "open3"

CONTAINER = ENV.fetch("PLATFORM_SEAFILE_CONTAINER")
CONTAINER_PATH = "/shared/seafile/conf/seafevents.conf"
HOST_PATH = File.join(
  ENV.fetch("PLATFORM_DOCKER_ROOT"), "seafile", "data", "seafile", "conf", "seafevents.conf"
)
# Section-scoped, exactly as roles/seafile/tasks/reconcile_seafevents.yml is, and
# for the same reason: `enabled` is not a unique key in this INI document --
# upstream writes one under [AUDIT] and one under [SEAHUB EMAIL] as well -- so a
# per-line rewrite would drift three settings and this hook would then be
# asserting the repair of something it did not mean to break. [^\[]*? stops the
# match at the next section header, which is the only thing in this grammar that
# opens with a bracket.
INDEX_FILES_ASSIGNMENT = /(?m)^(\[INDEX FILES\][^\[]*?^enabled\s*=\s*)([^\r\n]*)/

def refuse(message)
  warn "seafile drift: #{message}"
  exit 1
end

refuse("the deployed event configuration is not at #{HOST_PATH}") unless File.file?(HOST_PATH)
current = File.binread(HOST_PATH)
match = current.match(INDEX_FILES_ASSIGNMENT)
refuse("the deployed event configuration declares no [INDEX FILES] enabled key") if match.nil?
refuse("file indexing is already #{match[2].strip}, so this lane is not drifting anything") unless
  match[2].strip == "false"

drifted = current.sub(INDEX_FILES_ASSIGNMENT) { "#{Regexp.last_match(1)}true" }
refuse("the hand edit changed nothing") if drifted == current

# `cat >` into the existing path rather than a write-and-move: it truncates in
# place, so the inode, mode and ownership the server gave the file all survive.
# The role reads that mode back and re-applies it when it repairs the file, and a
# hook that quietly loosened it would be planting a second defect beside the one
# it means to plant.
_out, error, status = Open3.capture3(
  "docker", "exec", "-i", CONTAINER, "sh", "-c", "cat > '#{CONTAINER_PATH}'",
  stdin_data: drifted
)
refuse("the hand edit could not be written inside #{CONTAINER}: #{error.strip}") unless
  status.success?

confirmed = File.binread(HOST_PATH)
refuse("the hand edit did not reach the host copy of the event configuration") unless
  confirmed == drifted
