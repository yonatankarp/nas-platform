#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Per-service lifecycle probes and the check-mode and verify-tag contracts.
#
# Required by media_managed_users_test.rb, which owns the probe selection so the
# MEDIA_MANAGED_USERS_PROBES contract keeps naming one group rather than a file set.
# Fixtures and helpers come from media_managed_users_support.rb.

def exercise_audiobookshelf(failures)
  default_permissions = {
    "download" => true, "update" => false, "delete" => false, "upload" => false,
    "createEreader" => false, "accessAllLibraries" => true, "accessAllTags" => true,
    "accessExplicitContent" => false, "selectedTagsNotAccessible" => false
  }
  users = [
    { "id" => "abs-reader", "username" => "reader", "type" => "guest",
      "isActive" => false, "permissions" => default_permissions.dup,
      "librariesAccessible" => ["legacy-library"], "itemTagsSelected" => ["legacy-tag"] },
    { "id" => "abs-unmanaged", "username" => "friend", "type" => "user",
      "isActive" => true, "permissions" => default_permissions.dup,
      "librariesAccessible" => [], "itemTagsSelected" => [] }
  ]
  managed = [
    { "username" => "reader", "password" => "reader-secret", "type" => "user",
      "is_active" => true,
      "permissions" => { "flags" => { "accessAllLibraries" => false },
                           "librariesAccessible" => ["library-a"],
                           "itemTagsSelected" => ["tag-a"] } },
    { "username" => "new-reader", "password" => "new-secret", "type" => "guest",
      "is_active" => true,
      "permissions" => { "flags" => { "accessAllLibraries" => false },
                           "librariesAccessible" => [], "itemTagsSelected" => [] } }
  ]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/users"] then [200, { "users" => users }]
    when ["POST", "/login"]
      body = request.fetch("json")
      credentials = { "reader" => "reader-secret", "new-reader" => "new-secret" }
      credentials[body["username"]] == body["password"] ?
        [200, { "user" => { "username" => body["username"] } }] : [401, {}]
    when ["POST", "/api/users"]
      body = request.fetch("json")
      users << body.reject { |key, _| key == "password" }
                   .merge("id" => "abs-created",
                          "permissions" => default_permissions.merge(body.fetch("permissions")))
      [200, users.last]
    when ["PATCH", "/api/users/abs-reader"]
      body = request.fetch("json")
      users[0].merge!(body.reject { |key, _| key == "permissions" })
      users[0]["permissions"].merge!(body.fetch("permissions"))
      [200, users[0]]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    variables = {
      "audiobookshelf_api" => "http://127.0.0.1:#{port}",
      "vault_managed_audiobookshelf_users" => managed
    }
    stdout, stderr, status = run_playbook(includes_for("audiobookshelf", "fixture-token"), variables)
    failures << "Audiobookshelf behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    patch = requests.find { |request| request["method"] == "PATCH" }
    failures << "Audiobookshelf repair payload is not non-secret and exact" unless
      patch && patch["json"].keys.sort == %w[isActive itemTagsSelected librariesAccessible permissions type]
    failures << "Audiobookshelf repair did not split pinned array fields" unless
      patch&.dig("json", "permissions") == { "accessAllLibraries" => false } &&
        patch&.dig("json", "librariesAccessible") == ["library-a"] &&
        patch&.dig("json", "itemTagsSelected") == ["tag-a"]
    failures << "Audiobookshelf repair overwrote an undeclared expanded permission" unless
      users[0].dig("permissions", "download") == true
    failures << "Audiobookshelf absent creation omitted its initial password" unless
      requests.any? { |request| request["target"] == "/api/users" &&
        request["method"] == "POST" && request.dig("json", "password") == "new-secret" }
    failures << "Audiobookshelf newly created user did not prove its vault password" unless
      requests.any? { |request| request["target"] == "/login" &&
        request["json"] == { "username" => "new-reader", "password" => "new-secret" } }
    failures << "Audiobookshelf unmanaged user was not preserved" unless
      users.any? { |user| user["username"] == "friend" }
    failures << "Audiobookshelf final verification did not re-list users" unless
      requests.count { |request| request["target"] == "/api/users" && request["method"] == "GET" } == 3
  end
end

def exercise_jellyfin(failures)
  default_policy = {
    "AuthenticationProviderId" => "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider",
    "PasswordResetProviderId" => "Jellyfin.Server.Implementations.Users.DefaultPasswordResetProvider",
    "IsAdministrator" => false, "EnableAllFolders" => true,
    "IsHidden" => true, "EnableMediaPlayback" => true
  }
  users = [
    { "Id" => "a" * 32, "Name" => "reader",
      "Policy" => default_policy.dup },
    { "Id" => "b" * 32, "Name" => "friend", "Policy" => default_policy.dup }
  ]
  managed = [
    { "username" => "reader", "password" => "reader-secret",
      "policy" => { "IsAdministrator" => false, "EnableAllFolders" => false } },
    { "username" => "new-reader", "password" => "new-secret",
      "policy" => { "IsAdministrator" => false, "EnableAllFolders" => false } }
  ]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/Users"] then [200, users]
    when ["POST", "/Users/New"]
      body = request.fetch("json")
      created = { "Id" => "c" * 32, "Name" => body.fetch("Name"), "Policy" => default_policy.dup }
      users << created
      [200, created]
    when ["POST", "/Users/#{'c' * 32}/Policy"]
      body = request.fetch("json")
      required = %w[AuthenticationProviderId PasswordResetProviderId]
      next [400, {}] unless body.keys.sort == users[2]["Policy"].keys.sort &&
                            required.all? { |key| !body[key].to_s.empty? }
      users[2]["Policy"] = body
      [204, nil]
    when ["POST", "/Users/AuthenticateByName"]
      body = request.fetch("json")
      credentials = { "reader" => "reader-secret", "new-reader" => "new-secret" }
      authenticated = users.find { |user| user["Name"] == body["Username"] }
      credentials[body["Username"]] == body["Pw"] ?
        [200, { "User" => authenticated, "AccessToken" => "reader-token" }] : [401, {}]
    when ["POST", "/Users/#{'a' * 32}/Policy"]
      body = request.fetch("json")
      required = %w[AuthenticationProviderId PasswordResetProviderId]
      next [400, {}] unless body.keys.sort == users[0]["Policy"].keys.sort &&
                            required.all? { |key| !body[key].to_s.empty? }
      users[0]["Policy"] = body
      [204, nil]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    variables = {
      "jellyfin_api" => "http://127.0.0.1:#{port}", "jellyfin_client_header" => "MediaBrowser Fixture",
      "vault_managed_jellyfin_users" => managed
    }
    stdout, stderr, status = run_playbook(includes_for("jellyfin", "admin-token"), variables)
    failures << "Jellyfin behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    create = requests.find { |request| request["target"] == "/Users/New" }
    failures << "Jellyfin absent creation omitted its initial password" unless
      create&.dig("json") == { "Name" => "new-reader", "Password" => "new-secret" }
    failures << "Jellyfin newly created user did not prove its vault password" unless
      requests.any? { |request| request["target"] == "/Users/AuthenticateByName" &&
        request["json"] == { "Username" => "new-reader", "Pw" => "new-secret" } }
    policy_requests = requests.select { |request| request["target"].end_with?("/Policy") }
    failures << "Jellyfin policy update contains a secret field" unless policy_requests.all? do |request|
      request.fetch("json").keys.none? do |key|
        key != "PasswordResetProviderId" && key.match?(/password|secret|token/i)
      end
    end
    failures << "Jellyfin complete policy update did not preserve provider IDs" unless
      policy_requests.all? do |request|
        request.dig("json", "AuthenticationProviderId") == default_policy["AuthenticationProviderId"] &&
          request.dig("json", "PasswordResetProviderId") == default_policy["PasswordResetProviderId"]
      end
    failures << "Jellyfin complete policy update reset undeclared policy state" unless
      users[0].dig("Policy", "IsHidden") == true && users[2].dig("Policy", "EnableMediaPlayback") == true
    failures << "Jellyfin unmanaged user was not preserved" unless users.any? { |user| user["Name"] == "friend" }
    failures << "Jellyfin final verification did not re-list users" unless
      requests.count { |request| request["target"] == "/Users" } == 3
  end
end

def exercise_komga(failures)
  supported_roles = %w[ADMIN FILE_DOWNLOAD PAGE_STREAMING KOBO_SYNC KOREADER_SYNC]
  users = [
    { "id" => "komga-reader", "email" => "reader@example.invalid", "password" => "reader-secret",
      "roles" => %w[USER KOBO_SYNC] },
    { "id" => "komga-friend", "email" => "friend@example.invalid", "password" => "friend-secret",
      "roles" => %w[USER KOBO_SYNC] }
  ]
  managed = [
    { "email" => "reader@example.invalid", "password" => "reader-secret",
      "roles" => ["PAGE_STREAMING"] },
    { "email" => "new@example.invalid", "password" => "new-secret", "roles" => ["KOREADER_SYNC"] }
  ]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/v2/users"]
      [200, users.map { |user| user.reject { |key, _| key == "password" } }]
    when ["GET", "/api/v2/users/me"]
      email, password = basic_credentials(request)
      authenticated = users.find { |user| user["email"] == email && user["password"] == password }
      authenticated ? [200, authenticated.reject { |key, _| key == "password" }] : [401, {}]
    when ["POST", "/api/v2/users"]
      body = request.fetch("json")
      users << body.merge("id" => "komga-created",
                          "roles" => body.fetch("roles").intersection(supported_roles) + ["USER"])
      [201, users.last.reject { |key, _| key == "password" }]
    when ["PATCH", "/api/v2/users/komga-reader"]
      users[0]["roles"] = request.fetch("json").fetch("roles").intersection(supported_roles) + ["USER"]
      [204, nil]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    variables = {
      "komga_api" => "http://127.0.0.1:#{port}", "vault_komga_admin_email" => "admin@example.invalid",
      "vault_komga_admin_password" => "admin-secret", "vault_managed_komga_users" => managed
    }
    stdout, stderr, status = run_playbook(includes_for("komga"), variables)
    failures << "Komga behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    patch = requests.find { |request| request["method"] == "PATCH" }
    failures << "Komga repair payload is not roles-only" unless patch&.dig("json") == { "roles" => ["PAGE_STREAMING"] }
    create = requests.find { |request| request["method"] == "POST" }
    failures << "Komga absent creation omitted its initial password" unless create&.dig("json", "password") == "new-secret"
    failures << "Komga newly created user did not prove its vault password" unless
      requests.any? { |request| request["target"] == "/api/v2/users/me" &&
        basic_credentials(request) == ["new@example.invalid", "new-secret"] }
    failures << "Komga existing user did not authenticate with its own credential" unless
      requests.any? { |request| request["target"] == "/api/v2/users/me" &&
        basic_credentials(request) == ["reader@example.invalid", "reader-secret"] }
    failures << "Komga unmanaged user was not preserved" unless users.any? { |user| user["email"] == "friend@example.invalid" }
    failures << "Komga final verification did not re-list users" unless
      requests.count { |request| request["target"] == "/api/v2/users" && request["method"] == "GET" } == 3
  end
end

# The run where nothing needs creating and nothing needs repairing. exercise_komga
# above drives a service that is missing one identity and has the wrong roles on
# another, so every guard it exercises is exercised on its FAILING branch -- and
# a fail_msg that dies when it is finalized dies on the PASSING one, after every
# earlier assertion has held. A converged fixture is the only run that asks
# whether this reconciliation can report success at all, and it is also what
# proves the repair decision is a decision: exercise_komga would still pass if
# every identity were always repaired.
def exercise_komga_converged(failures)
  users = [{ "id" => "komga-reader", "email" => "reader@example.invalid",
             "password" => "reader-secret", "roles" => %w[USER PAGE_STREAMING] },
           { "id" => "komga-friend", "email" => "friend@example.invalid",
             "password" => "friend-secret", "roles" => %w[USER KOBO_SYNC] }]
  managed = [{ "email" => "reader@example.invalid", "password" => "reader-secret",
               "roles" => ["PAGE_STREAMING"] }]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/v2/users"]
      [200, users.map { |user| user.reject { |key, _| key == "password" } }]
    when ["GET", "/api/v2/users/me"]
      email, password = basic_credentials(request)
      authenticated = users.find { |user| user["email"] == email && user["password"] == password }
      authenticated ? [200, authenticated.reject { |key, _| key == "password" }] : [401, {}]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    variables = {
      "komga_api" => "http://127.0.0.1:#{port}",
      "vault_komga_admin_email" => "admin@example.invalid",
      "vault_komga_admin_password" => "admin-secret",
      "vault_managed_komga_users" => managed
    }
    stdout, stderr, status = run_playbook(includes_for("komga"), variables)
    failures << "Komga converged fixture failed: #{failure_tail(stdout + stderr)}" unless
      status.success?
    mutations = requests.select { |request| %w[POST PUT PATCH DELETE].include?(request["method"]) }
    failures << "Komga converged fixture mutated a converged service: " \
                "#{mutations.map { |request| request['target'] }}" unless mutations.empty?
    failures << "Komga converged fixture did not authenticate the existing identity" unless
      requests.any? do |request|
        request["target"] == "/api/v2/users/me" &&
          basic_credentials(request) == %w[reader@example.invalid reader-secret]
      end
    failures << "Komga converged fixture did not reach its final verification" unless
      requests.count { |request| request["target"] == "/api/v2/users" && request["method"] == "GET" } == 3
  end
end

# Both branches of the capability-register read, and both directions of each.
# The review branch exists because deployment_bundle stages and activates
# nothing under --check, so on the first converge that ships the register
# platform_current_dir still names a release that predates it. A probe that
# forgot to name a release at all would land in that branch and report green,
# which is why the first row asserts the token is ABSENT when the register is
# there.
def exercise_komga_capability_register(failures)
  managed = [{ "email" => "reader@example.invalid", "password" => "reader-secret",
               "roles" => ["PAGE_STREAMING"] }]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/v2/users"]
      [200, [{ "id" => "komga-reader", "email" => "reader@example.invalid",
               "roles" => %w[USER PAGE_STREAMING] }]]
    when ["GET", "/api/v2/users/me"]
      [200, { "id" => "komga-reader", "email" => "reader@example.invalid",
              "roles" => %w[USER PAGE_STREAMING] }]
    else [500, {}]
    end
  end
  register = YAML.safe_load_file(File.join(ROOT, "config", "managed-user-capabilities.yml"))
  Dir.mktmpdir("nas-platform-komga-register-") do |root|
    stale = File.join(root, "stale-release")
    drifted = File.join(root, "drifted-release")
    FileUtils.mkdir_p(stale)
    FileUtils.mkdir_p(File.join(drifted, "config"))
    drifted_register = Marshal.load(Marshal.dump(register))
    drifted_register.fetch("services").fetch("komga").fetch("interfaces")["list"] = "api/v1/users"
    File.write(File.join(drifted, "config", "managed-user-capabilities.yml"),
               YAML.dump(drifted_register))

    review = "MANAGED_USERS_REGISTER_UNREVIEWABLE"
    cases = [
      ["register present under review", ROOT, ["--check"], true, nil, review],
      ["register absent under review", stale, ["--check"], true, review, nil],
      ["register absent on a converge", stale, [], false,
       "is absent from the deployed release", nil],
      ["register drifted from this role", drifted, [], false,
       "does not authorise this reconciliation of komga", nil]
    ]
    cases.each do |label, release, arguments, expected, required, forbidden|
      with_http_service(responder) do |port, _requests|
        variables = {
          "komga_api" => "http://127.0.0.1:#{port}",
          "vault_komga_admin_email" => "admin@example.invalid",
          "vault_komga_admin_password" => "admin-secret",
          "vault_managed_komga_users" => managed,
          "platform_current_dir" => release
        }
        stdout, stderr, status = run_playbook([includes_for("komga").first], variables, *arguments)
        output = stdout + stderr
        if status.success? != expected
          failures << "Komga #{label} fixture #{expected ? 'failed' : 'succeeded'}: " \
                      "#{failure_tail(output)}"
        end
        failures << "Komga #{label} fixture omitted #{required.inspect}" if
          required && !output.include?(required)
        failures << "Komga #{label} fixture emitted #{forbidden.inspect}" if
          forbidden && output.include?(forbidden)
      end
    end
  end
end

# The verify phase's REFUSAL branch, which nothing else reaches: every other
# probe drives the final verification on its passing branch, and after #647 the
# three conditions travel through two indirections before `assert` sees them --
# komga_managed_users_verify_conditions, the role's
# managed_users_verify_conditions, and `that:` templating the list. A list of
# non-empty strings is truthy, so plumbing that delivered them as VALUES rather
# than as expressions would print exactly what a converged run prints. Only a
# state the conditions must reject tells the two apart.
#
# The absent-identity row is also the short-circuit proof: the second and third
# conditions read the single match, which does not exist for an identity with
# none, so a `that:` list evaluated all at once would raise instead of refusing.
def exercise_komga_verification(failures)
  managed = [{ "email" => "reader@example.invalid", "password" => "reader-secret",
               "roles" => ["PAGE_STREAMING"] }]
  drift = "A managed Komga identity is absent, duplicated, or differs from its exact " \
          "declared email and roles."
  cases = [
    ["converged", [{ "id" => "komga-reader", "email" => "reader@example.invalid",
                     "roles" => %w[USER PAGE_STREAMING] }], true],
    ["drifted roles", [{ "id" => "komga-reader", "email" => "reader@example.invalid",
                         "roles" => %w[USER KOBO_SYNC] }], false],
    ["absent identity", [{ "id" => "komga-other", "email" => "other@example.invalid",
                           "roles" => %w[USER] }], false],
    ["duplicated identity", [{ "id" => "komga-one", "email" => "reader@example.invalid",
                               "roles" => %w[USER PAGE_STREAMING] },
                             { "id" => "komga-two", "email" => "reader@example.invalid",
                               "roles" => %w[USER PAGE_STREAMING] }], false]
  ]
  cases.each do |label, listing, expected|
    with_http_service(->(_request) { [200, listing] }) do |port, requests|
      variables = {
        "komga_api" => "http://127.0.0.1:#{port}",
        "vault_komga_admin_email" => "admin@example.invalid",
        "vault_komga_admin_password" => "admin-secret",
        "vault_managed_komga_users" => managed
      }
      stdout, stderr, status = run_playbook([includes_for("komga").last], variables)
      output = stdout + stderr
      if status.success? != expected
        failures << "Komga #{label} verification #{expected ? 'failed' : 'succeeded'}: " \
                    "#{failure_tail(output)}"
      end
      # The duplicate is refused earlier, by the ambiguity guard, so only the two
      # rows the final verification itself owns assert its diagnostic.
      failures << "Komga #{label} verification did not refuse with its own diagnostic" if
        ["drifted roles", "absent identity"].include?(label) &&
        !HttpFixtureSupport.refused_with?(output, drift)
      failures << "Komga #{label} verification mutated the service" if
        requests.any? { |request| %w[POST PUT PATCH DELETE].include?(request["method"]) }
    end
  end
end

# roles/managed_users takes six parameters meta/argument_specs.yml cannot
# declare, because Ansible templates every declared option at role entry and
# each of these is a template over a per-identity `item` or over the match the
# role binds. The role asserts their PRESENCE instead, through q('varnames'),
# which is a mechanism nothing else here uses -- so it is exercised rather than
# trusted, by dropping one from a copy of the shim.
def exercise_komga_parameter_contract(failures)
  shim = YAML.safe_load_file(KOMGA_SHIM, aliases: false)
  %w[managed_users_create_body managed_users_repair_condition
     managed_users_list_json].each do |dropped|
    mutant = Marshal.load(Marshal.dump(shim))
    mutant.find { |task| task.key?("ansible.builtin.include_role") }.fetch("vars").delete(dropped)
    # The shim's parameter and Komga's default for it are the same value by two
    # names, so both have to go or the default still supplies it.
    overrides = HARNESS_MANAGED_USER_DEFAULTS.reject do |name, _value|
      name == dropped.sub("managed_users_", "komga_managed_users_")
    end
    stdout, stderr, status = HttpFixtureSupport.run_playbook(
      mutant,
      HARNESS_TIMING_DEFAULTS.merge(overrides).merge(HARNESS_RELEASE_DEFAULTS).merge(
        "komga_managed_users_phase" => "reconcile",
        "komga_api" => "http://127.0.0.1:#{HttpFixtureSupport.refusing_port}",
        "vault_komga_admin_email" => "admin@example.invalid",
        "vault_komga_admin_password" => "admin-secret",
        "vault_managed_komga_users" => []
      ),
      prefix: "nas-platform-komga-parameter-contract-"
    )
    output = stdout + stderr
    failures << "Komga run without #{dropped} succeeded" if status.success?
    failures << "Komga run without #{dropped} did not name it: #{failure_tail(output)}" unless
      HttpFixtureSupport.refused_with?(
        output, "A caller of roles/managed_users did not supply #{dropped}."
      )
  end
end

# What a --check review REPORTS. The two plan literals were unpinned before
# #647, which was neutral while they were `msg:` constants in Komga's own file;
# they are now a parameter, and the decision behind the repair one is a fact the
# role resolves from a caller-supplied template. A repair decision that silently
# resolved false, or a plan message that arrived empty, would leave a review
# printing nothing and changed=0 -- which reads exactly like a converged host.
def exercise_komga_review_plan(failures)
  managed = [{ "email" => "reader@example.invalid", "password" => "reader-secret",
               "roles" => ["PAGE_STREAMING"] },
             { "email" => "new@example.invalid", "password" => "new-secret",
               "roles" => ["KOREADER_SYNC"] }]
  listing = [{ "id" => "komga-reader", "email" => "reader@example.invalid",
               "roles" => %w[USER KOBO_SYNC] }]
  with_http_service(->(_request) { [200, listing] }) do |port, requests|
    variables = {
      "komga_api" => "http://127.0.0.1:#{port}",
      "vault_komga_admin_email" => "admin@example.invalid",
      "vault_komga_admin_password" => "admin-secret",
      "vault_managed_komga_users" => managed
    }
    stdout, stderr, status = run_playbook([includes_for("komga").first], variables, "--check")
    output = stdout + stderr
    failures << "Komga review fixture failed: #{failure_tail(output)}" unless status.success?
    %w[KOMGA_PLAN_MANAGED_USER_CREATE KOMGA_PLAN_MANAGED_USER_REPAIR].each do |literal|
      failures << "Komga review omitted #{literal}" unless output.include?(literal)
    end
    failures << "Komga review mutated the service" if
      requests.any? { |request| %w[POST PUT PATCH DELETE].include?(request["method"]) }
  end

  # The other direction: a converged host must report neither plan, or the
  # decision is not a decision.
  converged = [{ "id" => "komga-reader", "email" => "reader@example.invalid",
                 "roles" => %w[USER PAGE_STREAMING] }]
  with_http_service(->(_request) { [200, converged] }) do |port, _requests|
    variables = {
      "komga_api" => "http://127.0.0.1:#{port}",
      "vault_komga_admin_email" => "admin@example.invalid",
      "vault_komga_admin_password" => "admin-secret",
      "vault_managed_komga_users" => [managed.first]
    }
    stdout, stderr, status = run_playbook([includes_for("komga").first], variables, "--check")
    output = stdout + stderr
    failures << "Komga converged review failed: #{failure_tail(output)}" unless status.success?
    %w[KOMGA_PLAN_MANAGED_USER_CREATE KOMGA_PLAN_MANAGED_USER_REPAIR].each do |literal|
      failures << "Komga converged review reported #{literal}" if output.include?(literal)
    end
  end
end

def exercise_check_mode(failures)
  cases = [
    ["Audiobookshelf", "audiobookshelf", "fixture-token",
     { "vault_managed_audiobookshelf_users" => [
       { "username" => "reader", "password" => "secret", "type" => "user", "is_active" => true,
         "permissions" => { "flags" => {}, "librariesAccessible" => [], "itemTagsSelected" => [] } }
     ] },
     lambda do |request|
       request["target"] == "/api/users" ?
         [200, { "users" => [{ "id" => "reader", "username" => "reader", "type" => "user",
                               "isActive" => true, "permissions" => {},
                               "librariesAccessible" => [], "itemTagsSelected" => [] }] }] : [200, {}]
     end],
    ["Jellyfin", "jellyfin", "admin-token",
     { "jellyfin_client_header" => "MediaBrowser Fixture",
       "vault_managed_jellyfin_users" => [
         { "username" => "reader", "password" => "secret", "policy" => { "IsAdministrator" => false } }
       ] },
     lambda do |request|
       request["target"] == "/Users" ?
         [200, [{ "Id" => "a" * 32, "Name" => "reader",
                  "Policy" => { "AuthenticationProviderId" => "auth",
                                "PasswordResetProviderId" => "reset",
                                "IsAdministrator" => false } }]] : [200, {}]
     end],
    ["Komga", "komga", nil,
     { "vault_komga_admin_email" => "admin@example.invalid",
       "vault_komga_admin_password" => "admin-secret",
       "vault_managed_komga_users" => [
         { "email" => "reader@example.invalid", "password" => "secret", "roles" => ["PAGE_STREAMING"] }
       ] },
     lambda do |request|
       request["target"] == "/api/v2/users" ?
         [200, [{ "id" => "reader", "email" => "reader@example.invalid", "roles" => ["USER"] }]] :
         [200, { "id" => "reader", "email" => "reader@example.invalid", "roles" => ["USER"] }]
     end]
  ]
  cases.each do |label, service, token, variables, responder|
    with_http_service(responder) do |port, requests|
      variables["#{service}_api"] = "http://127.0.0.1:#{port}"
      stdout, stderr, status = run_playbook([includes_for(service, token).first], variables, "--check")
      failures << "#{label} check-mode fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
      auth_targets = %w[/login /Users/AuthenticateByName /api/v2/users/me]
      failures << "#{label} check mode performed authentication or mutation" if
        requests.any? { |request| auth_targets.include?(request["target"]) ||
          %w[POST PATCH DELETE].include?(request["method"]) }
    end
  end
end

def exercise_jellyfin_fresh_check_mode(failures)
  main = jellyfin_role_tasks
  first_application_task = main.index do |task|
    task_name(task) == "Wait for the Jellyfin startup API"
  end
  tasks = main.drop(first_application_task)
  tasks.each do |task|
    include_value = task["ansible.builtin.include_tasks"]
    if include_value == "settings.yml"
      task["ansible.builtin.include_tasks"] =
        File.join(ROOT, "roles", "jellyfin", "tasks", "settings.yml")
    elsif include_value.is_a?(Hash) && include_value["file"] == "qsv_probe.yml"
      # The QSV probe is fatal and verify-only (#535), so its `never` tag keeps
      # it out of this untagged check-mode run and the rewrite below resolves
      # nothing today. It stays anyway: it is what makes a dropped gate show up
      # as the assertion further down naming the probe, instead of as an
      # unresolvable include path that says nothing about why.
      include_value["file"] = File.join(ROOT, "roles", "jellyfin", "tasks", "qsv_probe.yml")
    end
  end
  defaults = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "defaults", "main.yml"), aliases: false
  )
  responder = lambda do |request|
    case request["target"]
    when "/Startup/Configuration" then [200, {}]
    when "/System/Info/Public" then [200, { "StartupWizardCompleted" => false }]
    else [500, {}]
    end
  end
  Dir.mktmpdir("jellyfin-fresh-check-") do |directory|
    with_http_service(responder) do |port, requests|
      variables = defaults.merge(
        "jellyfin_api" => "http://127.0.0.1:#{port}",
        "jellyfin_client_header" => "MediaBrowser Fixture",
        "vault_jellyfin_admin_username" => "Yonatan",
        "vault_jellyfin_admin_password" => "secret",
        "vault_jellyfin_opensubtitles_username" => "subtitle-user",
        "vault_jellyfin_opensubtitles_password" => "subtitle-secret",
        "vault_managed_jellyfin_users" => [],
        "platform_kind" => "nas",
        # Only the QSV probe reads the render device path, and it is withheld
        # from this path. The variable stays defined so that a run which does
        # reach the probe fails on the probe rather than on an undefined
        # variable, which is a different message about a different defect.
        "platform_render_device_path" => "/dev/dri/renderD128",
        "platform_current_dir" => ROOT,
        "platform_runtime_dir" => directory,
        "jellyfin_compose_project_name" => "fresh-check-fixture",
        "platform_service_compose_files" => { "jellyfin" => ["compose.yml"] },
        "jellyfin_primary_recovery_marker" => File.join(directory, "recovery.json"),
        "jellyfin_admin_avatar_source" =>
          File.join(ROOT, "roles", "jellyfin", "files", "yonatan-avatar.jpeg"),
        "jellyfin_admin_avatar_probe" => File.join(directory, "avatar-probe.jpeg"),
        "jellyfin_admin_avatar_remote" => File.join(directory, "avatar.jpeg")
      )
      stdout, stderr, status = run_playbook(tasks, variables, "--check")
      output = stdout + stderr
      failures << "Jellyfin fresh full-role check mode failed: #{failure_tail(output)}" unless
        status.success?
      expected_plans = [
        "JELLYFIN_PLAN_WIZARD",
        "JELLYFIN_PLAN_ADMIN_IMAGE",
        "JELLYFIN_PLAN_LIBRARY_CREATE Movies",
        "JELLYFIN_PLAN_LIBRARY_CREATE Shows",
        "JELLYFIN_PLAN_ENCODING",
        "JELLYFIN_PLAN_PLUGIN_REPOSITORIES",
        "JELLYFIN_PLAN_PLUGIN_INSTALL Intro Skipper",
        "JELLYFIN_PLAN_PLUGIN_INSTALL Open Subtitles",
        "JELLYFIN_PLAN_OPENSUBTITLES_CONFIGURATION"
      ]
      expected_plans.each do |plan|
        failures << "Jellyfin fresh check mode omits #{plan}" unless output.include?(plan)
      end
      # JELLYFIN_PLAN_QSV_PROBE used to be in that list, and the probe reported
      # a plan here because it ran for real under --check. #535 made the probe
      # fatal and moved it behind the verification tags, which is a stronger
      # property than the marker was: the check-mode review the platform
      # requires before applying cannot fail on a hardware fault, because it no
      # longer reaches the hardware. A skipped-by-`when` task still prints its
      # own banner, so naming the task inside the probe file is what separates
      # "was not included" from "was included and did nothing".
      failures << "Jellyfin fresh check mode reached the fatal QSV hardware probe" if
        output.include?("Probe the Jellyfin QSV hardware device")
      failures << "Jellyfin fresh check mode performed a mutation" if requests.any? do |request|
        %w[POST PUT PATCH DELETE].include?(request["method"])
      end
    end
  end
end

def exercise_verify_tag_selection(failures)
  services = %w[audiobookshelf jellyfin komga]
  tags = services.map { |service| "platform_verify_#{service}" }.join(",")
  stdout, stderr, status = Open3.capture3(
    { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,", "-c", "local",
    File.join(ROOT, "verify.yml"), "--tags", tags, "--list-tasks", chdir: ROOT
  )
  output = stdout + stderr
  failures << "media verify tag listing failed: #{failure_tail(output)}" unless status.success?
  services.each do |service|
    failures << "#{service} verify tag omits managed-user verification" unless
      output.include?("Verify managed #{service.capitalize} users")
    failures << "#{service} verify tag selected managed-user reconciliation" if
      output.include?("Reconcile managed #{service.capitalize} users")
  end
end
