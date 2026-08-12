#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
ROLE = File.join(ROOT, "roles/komga/tasks/main.yml")
DEFAULTS = YAML.safe_load_file(File.join(ROOT, "roles/komga/defaults/main.yml"), aliases: false)
START_TASK = "List Komga libraries for reconciliation"
END_TASK = "Require exact reconciled Komga library"

def task_name(task)
  task.fetch("name", "")
end

def library_tasks
  tasks = YAML.safe_load_file(ROLE, aliases: false)
  first = tasks.index { |task| task_name(task) == START_TASK }
  last = tasks.index { |task| task_name(task) == END_TASK }
  raise "Komga library task slice is unavailable" unless first && last && first <= last

  tasks[first..last].each do |task|
    task["ansible.builtin.include_tasks"] = File.join(
      ROOT, "roles/komga/tasks/managed_users.yml"
    ) if task["ansible.builtin.include_tasks"] == "managed_users.yml"
  end
end

def managed_library(id:, name: "Comics", root: "/data", settings: {})
  DEFAULTS.fetch("komga_library_settings").merge(
    "id" => id, "name" => name, "root" => root, "unavailable" => false
  ).merge(settings)
end

def with_http_service(libraries, users: [], fail_after_apply: false)
  server = TCPServer.new("127.0.0.1", 0)
  requests = []
  stopped = false
  error = nil
  failed_patch = false
  thread = Thread.new do
    until stopped
      next unless IO.select([server], nil, nil, 0.05)

      client = server.accept
      method, target, = client.gets.to_s.strip.split(" ", 3)
      headers = {}
      while (line = client.gets)
        line = line.chomp
        break if line == "\r" || line.empty?

        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end
      body = client.read(headers.fetch("content-length", "0").to_i)
      request = { "method" => method, "target" => target,
                  "json" => body.empty? ? nil : JSON.parse(body) }
      requests << request
      status = 500
      response = { "error" => "unexpected request" }
      case [method, target]
      when ["GET", "/api/v1/libraries"]
        status = 200
        response = libraries
      when ["POST", "/api/v1/libraries"]
        status = 200
        libraries << request.fetch("json").merge("id" => "created-library", "unavailable" => false)
        response = libraries.last
      when ["GET", "/api/v2/users"]
        status = 200
        response = users
      when ["POST", "/api/v2/users"]
        status = 201
        users << request.fetch("json").merge("id" => "created-user", "roles" => ["USER", *request.fetch("json").fetch("roles")])
        response = users.last
      else
        if method == "PATCH" && target.match?(%r{\A/api/v1/libraries/[A-Za-z0-9_.%:-]+\z})
          id = target.split("/").last
          library = libraries.find { |entry| entry.is_a?(Hash) && entry["id"] == id }
          if library
            library.merge!(request.fetch("json"))
            if fail_after_apply && !failed_patch
              failed_patch = true
              status = 500
              response = { "error" => "response lost after commit" }
            else
              status = 204
              response = nil
            end
          end
        end
      end
      payload = response.nil? ? "" : JSON.generate(response)
      reason = { 200 => "OK", 204 => "No Content", 500 => "Error" }.fetch(status)
      client.write("HTTP/1.1 #{status} #{reason}\r\n")
      client.write("Content-Type: application/json\r\n") unless payload.empty?
      client.write("Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  rescue StandardError => caught
    error = caught
  end
  yield server.addr.fetch(1), requests
ensure
  stopped = true
  server&.close
  thread&.join
  raise error if error
end

def run_tasks(port, arguments = [], managed_users: [])
  Dir.mktmpdir("komga-library-reconciliation-") do |directory|
    playbook = File.join(directory, "playbook.yml")
    variables = DEFAULTS.merge(
      "komga_api" => "http://127.0.0.1:#{port}",
      "vault_komga_admin_email" => "admin@example.invalid",
      "vault_komga_admin_password" => "admin-secret",
      "komga_claim_status" => { "json" => { "isClaimed" => true } },
      "vault_managed_komga_users" => managed_users
    )
    File.write(
      playbook,
      YAML.dump([{ "hosts" => "localhost", "gather_facts" => false,
                   "vars" => variables, "tasks" => library_tasks }]),
      mode: "w", perm: 0o600
    )
    Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,", "-c", "local",
      playbook, *arguments, chdir: ROOT
    )
  end
end

def mutations(requests)
  requests.select { |request| %w[POST PATCH DELETE].include?(request.fetch("method")) }
end

failures = []

main_tasks = YAML.safe_load_file(ROLE, aliases: false)
main_names = main_tasks.map { |task| task_name(task) }
preflight_index = main_names.index("Refuse ambiguous Komga library candidates")
user_index = main_names.index("Reconcile managed Komga users")
library_mutation_index = main_names.index("Create the managed Komga library")
failures << "complete library preflight does not precede all user/library mutation" unless
  preflight_index && user_index && library_mutation_index &&
    preflight_index < user_index && user_index < library_mutation_index

unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
         File.executable?(File.join(directory, "ansible-playbook"))
       end
  abort "ansible-playbook is required for Komga library behavior fixtures"
end

unrelated = managed_library(id: "unrelated", name: "Reference", root: "/reference")
libraries = [managed_library(id: "legacy-library", name: "Books", root: "/data/").merge(
  "legacySentinel" => "preserve-me"
), unrelated.dup]
with_http_service(libraries) do |port, requests|
  stdout, stderr, status = run_tasks(port)
  failures << "path adoption failed: #{(stdout + stderr).lines.last(12).join}" unless status.success?
  patch = mutations(requests).fetch(0, nil)
  failures << "path adoption did not use one in-place PATCH" unless
    mutations(requests).length == 1 && patch&.fetch("target") == "/api/v1/libraries/legacy-library"
  failures << "path adoption body is not limited to canonical name/root drift" unless
    patch&.fetch("json") == { "name" => "Comics", "root" => "/data" }
  failures << "path adoption overwrote an unowned library setting" unless
    libraries.first["legacySentinel"] == "preserve-me"
  failures << "path adoption changed the library identifier" unless libraries.first["id"] == "legacy-library"
  failures << "path adoption did not preserve the unrelated library" unless libraries.last == unrelated

  requests.clear
  _stdout, _stderr, rerun = run_tasks(port)
  failures << "path adoption rerun failed" unless rerun.success?
  failures << "path adoption is not idempotent" unless mutations(requests).empty?
end

libraries = [managed_library(id: "rename-only", name: "Books").merge(
  "legacySentinel" => "preserve-me"
)]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  patch = mutations(requests).fetch(0, nil)
  failures << "exact-root rename failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "exact-root rename PATCH was not name-only" unless patch&.fetch("json") == { "name" => "Comics" }
  failures << "exact-root rename lost the unowned sentinel" unless libraries.first["legacySentinel"] == "preserve-me"
end

libraries = [managed_library(id: "settings-only", settings: { "scanOnStartup" => true }).merge(
  "legacySentinel" => "preserve-me"
)]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  patch = mutations(requests).fetch(0, nil)
  failures << "owned-setting repair failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "owned-setting PATCH included unchanged fields" unless patch&.fetch("json") == { "scanOnStartup" => false }
  failures << "owned-setting repair lost the unowned sentinel" unless libraries.first["legacySentinel"] == "preserve-me"
end

libraries = [unrelated.dup]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  failures << "fresh creation failed: #{stderr.lines.last(8).join}" unless status.success?
  create = mutations(requests).fetch(0, nil)
  failures << "fresh creation did not POST one exact Comics library" unless
    mutations(requests).length == 1 && create&.fetch("method") == "POST" &&
      create&.fetch("target") == "/api/v1/libraries" &&
      create&.fetch("json") == DEFAULTS.fetch("komga_library_settings").merge(
        "name" => "Comics", "root" => "/data"
      )
  failures << "fresh creation did not preserve an unrelated library" unless libraries.first == unrelated
end

conflicts = {
  "duplicate root" => [managed_library(id: "one", name: "Books", root: "/data"),
                         managed_library(id: "two", name: "Manga", root: "/data/")],
  "desired name on another root" => [managed_library(id: "managed", name: "Books", root: "/data"),
                                      managed_library(id: "conflict", name: "Comics", root: "/elsewhere")],
  "duplicate desired name" => [managed_library(id: "one", name: "Comics", root: "/elsewhere"),
                                managed_library(id: "two", name: "Comics", root: "/other")],
  "root candidate missing name" => [{ "id" => "candidate", "root" => "/data" }],
  "name candidate malformed root" => [{ "id" => "candidate", "name" => "Comics", "root" => ["/data"] }]
}
conflicts.each do |label, state|
  with_http_service(state) do |port, requests|
    _stdout, _stderr, status = run_tasks(port)
    failures << "#{label} unexpectedly reconciled" if status.success?
    failures << "#{label} reached a mutation before global preflight" unless mutations(requests).empty?
  end
end

users = [{ "id" => "reader", "email" => "reader@example.invalid", "roles" => ["USER"] }]
managed_users = [
  { "email" => "reader@example.invalid", "password" => "reader-secret", "roles" => ["PAGE_STREAMING"] },
  { "email" => "missing@example.invalid", "password" => "missing-secret", "roles" => ["PAGE_STREAMING"] }
]
multi_conflicts = {
  "duplicate root" => [managed_library(id: "one", name: "Books", root: "/data"),
                        managed_library(id: "two", name: "Manga", root: "/data/")],
  "duplicate desired name" => [managed_library(id: "managed", name: "Books", root: "/data"),
                               managed_library(id: "one", name: "Comics", root: "/one"),
                               managed_library(id: "two", name: "Comics", root: "/two")],
  "malformed managed candidate" => [{ "id" => "candidate", "root" => "/data" }]
}
multi_conflicts.each do |label, state|
  with_http_service(state, users: users.map(&:dup)) do |port, requests|
    _stdout, _stderr, status = run_tasks(port, [], managed_users: managed_users)
    failures << "#{label} with drifted/missing users unexpectedly reconciled" if status.success?
    failures << "#{label} allowed a managed-user or library mutation" unless mutations(requests).empty?
  end
end

malformed_unrelated = { "id" => ["opaque"], "name" => 7, "root" => { "path" => "/other" } }
libraries = [managed_library(id: "managed"), malformed_unrelated]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  failures << "unrelated malformed library was unnecessarily rejected: #{stderr.lines.last(8).join}" unless
    status.success?
  failures << "unrelated malformed library was mutated" unless mutations(requests).empty? &&
    libraries.last == malformed_unrelated
end

libraries = [managed_library(id: "managed", name: "Books", settings: { "scanOnStartup" => true })]
with_http_service(libraries, fail_after_apply: true) do |port, requests|
  _stdout, _stderr, first = run_tasks(port)
  failures << "uncertain PATCH response unexpectedly succeeded" if first.success?
  failures << "uncertain PATCH did not apply the desired state before losing its response" unless
    libraries.first["name"] == "Comics" && libraries.first["scanOnStartup"] == false
  requests.clear
  _stdout, stderr, rerun = run_tasks(port)
  failures << "rerun after uncertain PATCH did not converge: #{stderr.lines.last(8).join}" unless rerun.success?
  failures << "rerun after applied PATCH repeated a mutation" unless mutations(requests).empty?
  failures << "rerun after uncertain PATCH changed the identifier" unless libraries.first["id"] == "managed"
end

libraries = [managed_library(id: "managed", name: "Books")]
with_http_service(libraries) do |port, requests|
  stdout, stderr, status = run_tasks(port, ["--check"])
  failures << "check-mode adoption failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "check-mode adoption omitted its repair plan" unless stdout.include?("KOMGA_PLAN_LIBRARY_REPAIR")
  failures << "check mode mutated a library" unless mutations(requests).empty?
end

if failures.empty?
  puts "Komga library reconciliation behavior passed"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Komga library reconciliation violation(s)"
end
