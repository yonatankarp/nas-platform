#!/usr/bin/env ruby
# The runtime half of the Immich service contract: what only a deployed Immich
# can answer -- that the stack is healthy and contained, that the managed
# settings and every managed user's preference profile are exactly what the
# vault authored, that an asset survives upload, thumbnailing and CPU machine
# learning, and that all of it persists across a container recreation.
#
# usage: immich-runtime.rb MODE [ARG...]
#
# MODE selects which of those it proves: run, seed, assert-persistence, drift,
# drift-verify, clean-restore-seed, clean-restore-assert. Everything else is
# read from the environment tests/contracts/immich.sh exports -- the four
# container names, the three roots, the port, the platform, and
# PLATFORM_CONTRACT_REPO_DIR, which this program reads as REPO_DIR. On failure it
# writes one `Immich contract failed: ...` line to stderr and exits 1.
#
# Note which root REPO_DIR is: the tree under inspection, not the checkout this
# file was loaded from. The wrapper resolves this program from its own checkout
# and passes the inspected tree through the environment, and those two are not
# interchangeable.
#
# The heredoc this replaced ran as `ruby - "$mode" "$@"` with no `-r` preloads at
# all -- it requires what it needs on the lines below -- so the invocation that
# replaced it carries none either.
#
# Until #147 these 850 lines were a `<<'RUBY'` heredoc inside
# tests/contracts/immich.sh, which `sh -n` reads as opaque text and no test could
# reach. The body below is byte-identical to what that heredoc rendered.
#
# Two things read this file's source rather than running it, and both slice it
# with a regular expression, so a method's `def` must stay at column zero:
# tests/immich_smart_search_retry_test.rb evals `request` and
# `assert_cpu_machine_learning` out of it, and immich-static.rb requires the
# supported-unowned-sentinel logic below to be live in it rather than commented
# out.
require "json"
require "digest"
require "net/http"
require "open3"
require "pathname"
require "timeout"
require "uri"
require "yaml"

MODE = ARGV.fetch(0)
PLATFORM = ENV.fetch("PLATFORM_IMMICH_PLATFORM")
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_IMMICH_PORT'), 10)}")
DOCKER_ROOT = Pathname.new(ENV.fetch("PLATFORM_DOCKER_ROOT")).expand_path
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
SERVER_CONTAINER = ENV.fetch("PLATFORM_IMMICH_SERVER_CONTAINER")
HELPER_CONTAINERS = [
  ENV.fetch("PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER"),
  ENV.fetch("PLATFORM_IMMICH_REDIS_CONTAINER"),
  ENV.fetch("PLATFORM_IMMICH_POSTGRES_CONTAINER")
].freeze
STATE_PATH = REPORT_ROOT.join("immich-persistence.json")
CLEAN_RESTORE_STATE_PATH = REPORT_ROOT.join("immich-clean-restore.json")
REPO_DIR = Pathname.new(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR")).expand_path
MANAGED_SENTINEL = "nas-platform-unowned-sentinel"
SUPPORTED_UNOWNED_PREFERENCE_SENTINELS = [
  [%w[albums defaultAssetOrder], "asc"],
  [%w[folders enabled], true],
  [%w[ratings enabled], true],
  [%w[tags sidebarWeb], true]
].freeze

DEVICE_ID = "nas-platform-immich-contract"
MANAGED_SETTINGS = {
  ["newVersionCheck", "enabled"] => false,
  ["machineLearning", "enabled"] => true,
  ["backup", "database", "enabled"] => true
}.freeze

# Both fixtures are produced by the pinned server image's own ffmpeg with
# bitexact flags, so regenerating them yields these exact bytes. They are
# deliberately tiny: the contract proves that the pipeline ran, not that the
# encoder is fast. unpack1 rather than the base64 library, which is not a
# default gem on the Ruby 3.4 the integration lane runs.
PHOTO_FIXTURE = (
  "/9j/4AAQSkZJRgABAgAAAQABAAD/2wBDAAgICAkICQsLCwsLCw0MDQ0NDQ0NDQ0NDQ0ODg4REREO" \
  "Dg4NDQ4OEBARERITEhERERETExQUFBgYFxccHB0iIin/xABNAAEBAAAAAAAAAAAAAAAAAAAABgEB" \
  "AQEAAAAAAAAAAAAAAAAAAAYHEAEAAAAAAAAAAAAAAAAAAAAAEQEAAAAAAAAAAAAAAAAAAAAA/8AA" \
  "EQgAMABAAwEiAAIRAAMRAP/aAAwDAQACEQMRAD8AiwEo38AAAAAAAAAAAAAAAAAAAAAB/9k="
).unpack1("m0").freeze
VIDEO_FIXTURE = (
  "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAANsbW9vdgAAAGxtdmhkAAAAAAAAAAAA" \
  "AAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA" \
  "AABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAArt0cmFrAAAAXHRraGQAAAADAAAA" \
  "AAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAA" \
  "AAAAAAAAAABAAAAAAEAAAAAwAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAgAAABAAAA" \
  "AAIzbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAgABVxAAAAAAALWhkbHIAAAAAAAAAAHZp" \
  "ZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAB3m1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAA" \
  "ACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAZ5zdGJsAAAAvnN0c2QAAAAAAAAA" \
  "AQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAMABIAAAASAAAAAAAAAABDExhdmMg" \
  "bGlieDI2NAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAGGdkAAqs2UR7ARAA" \
  "AAMAEAAAAwCA8SJZYAEABWjvgZcs/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAABC0" \
  "AAAAAAAAABhzdHRzAAAAAAAAAAEAAAAIAAAQAAAAABRzdHNzAAAAAAAAAAEAAAABAAAASGN0dHMA" \
  "AAAAAAAABwAAAAEAACAAAAAAAQAAUAAAAAABAAAgAAAAAAEAAAAAAAAAAQAAEAAAAAABAABAAAAA" \
  "AAIAABAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAIAAAAAQAAADRzdHN6AAAAAAAAAAAAAAAIAAAD" \
  "dwAAAEUAAAALAAAACwAAAA4AAAAyAAAAEAAAAAsAAAAUc3RjbwAAAAAAAAABAAADnAAAAD11ZHRh" \
  "AAAANW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAACGlsc3QAAAAI" \
  "ZnJlZQAABDVtZGF0AAACrAYF//+o3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NCByMzEw" \
  "OCAzMWUxOWY5IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyMyAt" \
  "IGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVm" \
  "PTEgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9MiBwc3k9MSBw" \
  "c3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxs" \
  "aXM9MCA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3Fw" \
  "X29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAg" \
  "bnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRf" \
  "aW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0x" \
  "IHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MSBrZXlpbnQ9MjUwIGtleWludF9taW49NCBz" \
  "Y2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTEwIHJjPWNyZiBtYnRyZWU9" \
  "MSBjcmY9NTEuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89" \
  "MS40MCBhcT0xOjEuMDAAgAAAAMNliIQD/3pWed2t18PhusYM6x+bWCrbRWvvGc7zWFLUNP4P/jm9" \
  "kBxLrrbb562/M9iZACUP0oV330y8jPggUuS4+0xfLbnfM43H9ekXN+BE6YOsseYMK5DDGRjIIRl0" \
  "RYcwJadqcTpL89ot/gK/b8xYfs9BotEQPtUe+4FK9T/ppjvirrhFQ+u3DKTOvoS28+cNo2vmH1SA" \
  "uSEd1nJwn7pDeuzQXJhUv4Y0PATCN97EJhPQLwB4koN9mzDlOZckO6Wa5jUAAABBQZokGP+huC9W" \
  "FveGiokDD7lglt6vcViI/j5WXk/RdrP//sPAVs+79xaVLBaCf8ne+XXtlDuP/utSmGg+7E0q5UoA" \
  "AAAHQZ5CQ/+7gQAAAAcBnmFH/7uAAAAACgGeY0f/zv28EGEAAAAuQZpnNEx/oYCQbyVK3Uwaw77h" \
  "zTDiQJGbHHdUO7detW/5kya7IbaTm/NHZ8AtQQAAAAxBnoVFES//v/3RtEEAAAAHAZ6mR/+7gQ=="
).unpack1("m0").freeze

FIXTURES = [
  { name: "nas-platform-contract-photo.jpg", type: "image/jpeg",
    bytes: PHOTO_FIXTURE, kind: "IMAGE" },
  { name: "nas-platform-contract-video.mp4", type: "video/mp4",
    bytes: VIDEO_FIXTURE, kind: "VIDEO" }
].freeze

def fail_contract(message)
  warn "Immich contract failed: #{message}"
  exit 1
end

def request(method, path, token: nil, body: nil, expected: [200], raw: false,
            headers: {}, form: nil, timeout: nil)
  uri = URI.join(BASE.to_s, path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Bearer #{token}" if token
  headers.each { |name, value| request[name] = value }
  if form
    boundary = "nasplatformimmichcontractboundary"
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request.body = multipart_body(form, boundary)
  elsif body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  open_timeout = timeout ? [5, timeout].min : 5
  read_timeout = timeout ? [180, timeout].min : 180
  send_request = lambda do
    Net::HTTP.start(
      uri.host, uri.port, open_timeout: open_timeout, read_timeout: read_timeout
    ) do |http|
      http.request(request)
    end
  end
  response = if timeout
               Timeout.timeout(timeout, Timeout::Error) { send_request.call }
             else
               send_request.call
             end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless
    expected.include?(response.code.to_i)
  return response if raw

  parsed = response.body.to_s.empty? ? nil : JSON.parse(response.body)
  [response, parsed]
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error, EOFError => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

# Hand-built because no multipart encoder is a Ruby default gem.
def multipart_body(fields, boundary)
  body = +""
  fields.each do |field|
    body << "--#{boundary}\r\n"
    if field.key?(:filename)
      body << %(Content-Disposition: form-data; name="#{field.fetch(:name)}"; ) <<
              %(filename="#{field.fetch(:filename)}"\r\n)
      body << "Content-Type: #{field.fetch(:content_type)}\r\n\r\n"
      body << field.fetch(:value).dup.force_encoding(Encoding::BINARY)
    else
      body << %(Content-Disposition: form-data; name="#{field.fetch(:name)}"\r\n\r\n)
      body << field.fetch(:value)
    end
    body << "\r\n"
  end
  body << "--#{boundary}--\r\n"
  body.force_encoding(Encoding::BINARY)
end

# /api/server/ping answers before the container health check reports healthy, so
# readiness here is the application answering for its own initialization state.
def wait_for_application
  deadline = Time.now + 300
  loop do
    uri = URI.join(BASE.to_s, "/api/server/config")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 15) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    payload = JSON.parse(response.body)
    return if response.code.to_i == 200 && payload["isInitialized"] == true
  rescue JSON::ParserError, SystemCallError, Timeout::Error, EOFError
    nil
  ensure
    fail_contract("Immich never reported an initialized server") if Time.now >= deadline
    sleep 2
  end
end

def docker_capture(*argv)
  stdout, stderr, status = Open3.capture3("docker", *argv)
  fail_contract("docker #{argv.first} failed: #{argv.join(' ')}") unless status.success?
  stderr.replace("\0" * stderr.bytesize)
  stdout
end

def safe_id(value)
  fail_contract("Immich returned an unsafe API identifier") unless
    value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/)
  value
end

def inspect_container(name)
  JSON.parse(docker_capture("inspect", name)).fetch(0)
end

# The plan's containment requirement: only the application is reachable from the
# host. A published database or cache port is a LAN-facing database.
def assert_container_capabilities
  server = inspect_container(SERVER_CONTAINER)
  bindings = server.dig("HostConfig", "PortBindings") || {}
  published = bindings.reject { |_port, hosts| hosts.nil? || hosts.empty? }
  fail_contract("the application must publish exactly its own port, got #{published.keys.inspect}") unless
    published.keys == ["2283/tcp"]

  devices = server.dig("HostConfig", "Devices") || []
  if PLATFORM == "nas"
    fail_contract("the NAS render device is not mapped") unless
      devices.any? { |device| device["PathInContainer"].to_s.start_with?("/dev/dri") }
  else
    fail_contract("#{PLATFORM} must expose no host device: #{devices.inspect}") unless devices.empty?
  end

  HELPER_CONTAINERS.each do |name|
    helper = inspect_container(name)
    helper_bindings = helper.dig("HostConfig", "PortBindings") || {}
    exposed = helper_bindings.reject { |_port, hosts| hosts.nil? || hosts.empty? }
    fail_contract("#{name} publishes host ports #{exposed.keys.inspect}") unless exposed.empty?
  end
end

def read_settings(token)
  _response, config = request("get", "/api/system-config", token: token)
  config
end

def assert_user_onboarding(token)
  _response, onboarding = request("get", "/api/users/me/onboarding", token: token)
  fail_contract("configured Immich user onboarding is incomplete") unless
    onboarding == { "isOnboarded" => true }
end

def managed_leaves(config)
  MANAGED_SETTINGS.keys.to_h { |path| [path.join("."), config.dig(*path)] }
end

def assert_managed_settings(config)
  MANAGED_SETTINGS.each do |path, value|
    fail_contract("managed setting #{path.join('.')} differs") unless config.dig(*path) == value
  end
end

def deep_merge(left, right)
  left.merge(right) do |_key, old_value, new_value|
    old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
  end
end

def managed_user_policy
  base = YAML.safe_load_file(
    REPO_DIR.join("inventory", "group_vars", "all", "main.yml"), aliases: false
  )
  fixture_path = Pathname.new(ENV.fetch("PLATFORM_MAC_FIXTURE_VARS_FILE")).expand_path
  stat = fixture_path.lstat
  fail_contract("protected Immich fixture policy is unsafe") unless
    fixture_path.absolute? && stat.file? && !stat.symlink? && stat.uid == Process.uid &&
    (stat.mode & 0o777) == 0o600
  fixture = YAML.safe_load_file(fixture_path, aliases: false)
  deep_merge(base, fixture)
rescue SystemCallError, KeyError, Psych::Exception
  fail_contract("protected Immich fixture policy is unavailable")
end

def desired_managed_user_profile(policy, email)
  normalized = email.strip.downcase
  profile_by_email = policy.fetch("immich_managed_user_preference_profile_by_email").to_h do |key, value|
    [key.strip.downcase, value]
  end
  overrides = policy.fetch("immich_managed_user_preference_overrides").to_h do |key, value|
    [key.strip.downcase, value]
  end
  profile_name = profile_by_email.fetch(
    normalized, policy.fetch("immich_managed_user_preference_profile_default")
  )
  profile = policy.fetch("immich_managed_user_preference_profiles").fetch(profile_name)
  deep_merge(profile, overrides.fetch(normalized, {}))
end

# Mirrors the role: the by-email map wins, otherwise the default. A managed user
# absent from the map is not an error -- it takes the default, which is null.
def desired_managed_user_quota(policy, email)
  normalized = email.strip.downcase
  quota_by_email = policy.fetch("immich_managed_user_quota_by_email").to_h do |key, value|
    [key.strip.downcase, value]
  end
  quota_by_email.fetch(normalized, policy.fetch("immich_managed_user_quota_default"))
end

def supported_unowned_preference_sentinel(profile)
  preferences = profile.reject { |key, _value| key == "avatar" }
  SUPPORTED_UNOWNED_PREFERENCE_SENTINELS.find do |path, _value|
    !preferences.fetch(path.fetch(0), {}).key?(path.fetch(1))
  end
end

def nested_preference_patch(path, value)
  { path.fetch(0) => { path.fetch(1) => value } }
end

def designated_partial_profile_email(policy)
  designated = policy.fetch("immich_contract_partial_profile_email").strip.downcase
  selected = policy.fetch("immich_managed_user_preference_profile_by_email").filter_map do |email, name|
    email.strip.downcase if name == "compact"
  end
  fail_contract("test-only compact profile must select exactly the designated managed account") unless
    selected == [designated]
  designated
end

def list_managed_user_records(token, managed_users)
  _response, users = request("get", "/api/admin/users?withDeleted=true", token: token)
  fail_contract("Immich returned an unsupported administrator user listing") unless users.is_a?(Array)
  managed_users.to_h do |managed|
    normalized = managed.fetch("email").strip.downcase
    matches = users.select { |user| user.fetch("email", "").strip.downcase == normalized }
    fail_contract("managed Immich identity does not resolve uniquely") unless matches.length == 1
    user = matches.first
    fail_contract("managed Immich preference target is not an active non-administrator") unless
      user["status"] == "active" && user["isAdmin"] == false
    [normalized, user]
  end
end

def seed_managed_user_state(token, managed_users, policy)
  _response, users = request("get", "/api/admin/users?withDeleted=true", token: token)
  designated = designated_partial_profile_email(policy)
  managed_users.each do |managed|
    normalized = managed.fetch("email").strip.downcase
    matches = users.select { |user| user.fetch("email", "").strip.downcase == normalized }
    fail_contract("managed Immich seed identity is ambiguous") if matches.length > 1
    if matches.empty?
      _response, created = request(
        "post", "/api/admin/users", token: token, expected: [201],
        body: managed.slice("email", "password", "name").merge(
          "shouldChangePassword" => false
        )
      )
      users << created
      target = created
    else
      target = matches.first
    end
    fail_contract("refusing to seed an administrator as a managed user") unless target["isAdmin"] == false
    id = safe_id(target.fetch("id"))
    profile = desired_managed_user_profile(policy, managed.fetch("email"))
    user_patch = {
      "name" => managed.fetch("name"),
      "quotaSizeInBytes" => desired_managed_user_quota(policy, managed.fetch("email")),
      "storageLabel" => MANAGED_SENTINEL
    }
    user_patch["avatarColor"] = profile.dig("avatar", "color") if
      profile.fetch("avatar", {}).key?("color")
    request(
      "patch", "/api/admin/users/#{id}", token: token,
      body: user_patch
    )
    request(
      "patch", "/api/admin/users/#{id}/preferences", token: token,
      body: profile.reject { |key, _value| key == "avatar" }
    )
    sentinel = supported_unowned_preference_sentinel(profile)
    if normalized == designated
      fail_contract("designated partial profile has no supported unowned preference sentinel") unless
        sentinel
      path, value = sentinel
      request(
        "patch", "/api/admin/users/#{id}/preferences", token: token,
        body: nested_preference_patch(path, value)
      )
    end
  end
end

def assert_managed_user_profiles(token, managed_users, policy, require_sentinel: false)
  records = list_managed_user_records(token, managed_users)
  designated = designated_partial_profile_email(policy)
  managed_users.map do |managed|
    normalized = managed.fetch("email").strip.downcase
    user = records.fetch(normalized)
    id = safe_id(user.fetch("id"))
    _response, authoritative_user = request("get", "/api/admin/users/#{id}", token: token)
    fail_contract("managed Immich authoritative user response is not an object") unless
      authoritative_user.is_a?(Hash)
    authoritative_id = authoritative_user["id"]
    authoritative_email = authoritative_user["email"]
    authoritative_admin = authoritative_user["isAdmin"]
    authoritative_password_state = authoritative_user["shouldChangePassword"]
    fail_contract("managed Immich authoritative user response has unsupported schema") unless
      authoritative_id.is_a?(String) && authoritative_email.is_a?(String) &&
      [true, false].include?(authoritative_admin) &&
      [true, false].include?(authoritative_password_state)
    fail_contract("managed Immich authoritative user read changed identity") unless
      authoritative_id == id && authoritative_email.strip.downcase == normalized &&
      authoritative_user["status"] == "active" && authoritative_admin.equal?(false)
    fail_contract("managed Immich authoritative user still requires a password change") unless
      authoritative_password_state.equal?(false)
    profile = desired_managed_user_profile(policy, managed.fetch("email"))
    if profile.fetch("avatar", {}).key?("color")
      fail_contract("managed Immich avatar preference differs") unless
        authoritative_user["avatarColor"] == profile.dig("avatar", "color")
    end
    fail_contract("managed Immich unowned sentinel was not preserved") if
      require_sentinel && authoritative_user["storageLabel"] != MANAGED_SENTINEL
    _response, preferences = request(
      "get", "/api/admin/users/#{id}/preferences", token: token
    )
    profile.reject { |key, _value| key == "avatar" }.each do |scope, leaves|
      leaves.each do |leaf, expected|
        fail_contract("managed preference #{scope}.#{leaf} differs for #{id}") unless
          preferences.dig(scope, leaf) == expected
      end
    end
    sentinel = supported_unowned_preference_sentinel(profile)
    if normalized == designated
      fail_contract("designated partial profile has no supported unowned preference sentinel") unless
        sentinel
    end
    if normalized == designated && require_sentinel
      path, expected = sentinel
      fail_contract("supported unowned managed preference #{path.join('.')} was not preserved") unless
        preferences.dig(*path) == expected
    end
    _response, managed_session = request(
      "post", "/api/auth/login", expected: [201],
      body: { "email" => managed.fetch("email"), "password" => managed.fetch("password") }
    )
    fail_contract("managed Immich authentication resolved a different identity or role") unless
      managed_session["userId"] == id && managed_session["userId"] == authoritative_user["id"] &&
      managed_session.fetch("userEmail").strip.downcase == normalized &&
      managed_session.fetch("userEmail").strip.downcase ==
        authoritative_user.fetch("email").strip.downcase &&
      managed_session["isAdmin"] == false
    managed_session_password_state = managed_session.fetch("shouldChangePassword") do
      fail_contract("managed Immich login omitted shouldChangePassword")
    end
    fail_contract("managed Immich login still requires a password change") unless
      managed_session_password_state.equal?(false)
    assert_user_onboarding(managed_session.fetch("accessToken"))
    {
      "id" => id, "email" => normalized, "name" => authoritative_user["name"],
      "quotaSizeInBytes" => authoritative_user["quotaSizeInBytes"],
      "isAdmin" => authoritative_user["isAdmin"], "avatarColor" => authoritative_user["avatarColor"],
      "storageLabel" => authoritative_user["storageLabel"],
      "preferences" => profile.reject { |key, _value| key == "avatar" },
      "supportedUnownedPreference" => sentinel && { "path" => sentinel.first.join("."),
                                                      "value" => sentinel.last }
    }
  end.sort_by { |record| record.fetch("email") }
end

def upload_fixture(token, fixture)
  _response, payload = request(
    "post", "/api/assets", token: token, expected: [200, 201],
    form: [
      { name: "assetData", filename: fixture.fetch(:name),
        content_type: fixture.fetch(:type), value: fixture.fetch(:bytes) },
      { name: "deviceAssetId", value: "#{DEVICE_ID}-#{fixture.fetch(:name)}" },
      { name: "deviceId", value: DEVICE_ID },
      { name: "fileCreatedAt", value: "2026-01-01T00:00:00.000Z" },
      { name: "fileModifiedAt", value: "2026-01-01T00:00:00.000Z" }
    ]
  )
  # An identical re-upload answers 200 "duplicate" with the same identifier, so
  # seeding is naturally re-runnable and both answers are correct here.
  fail_contract("unexpected upload status #{payload['status'].inspect}") unless
    %w[created duplicate].include?(payload["status"])
  safe_id(payload.fetch("id"))
end

def wait_for_thumbnail(token, id, timeout:)
  deadline = Time.now + timeout
  loop do
    _response, asset = request("get", "/api/assets/#{id}", token: token)
    thumbnail = request(
      "get", "/api/assets/#{id}/thumbnail?size=preview", token: token,
      raw: true, expected: (100..599).to_a
    )
    if asset["thumbhash"] && thumbnail.code.to_i == 200 && !thumbnail.body.to_s.empty?
      return asset
    end

    fail_contract("no thumbnail was generated for #{id} within #{timeout}s") if Time.now >= deadline
    sleep 3
  end
end

# Smart search is the only assertion that proves the machine learning container
# actually ran an inference: the query text is embedded by CLIP on the CPU and
# matched against embeddings the same stack produced for the fixtures.
def assert_cpu_machine_learning(
  token, expected_ids,
  clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
)
  deadline = clock.call + 600
  recovery_requested = false
  last_status = "none"
  found = []
  remaining_budget = lambda do
    remaining = deadline - clock.call
    if remaining <= 0
      fail_contract("smart search never returned the fixtures; " \
                    "last HTTP status was #{last_status} and machine learning produced " \
                    "#{found.length} embedded asset(s)")
    end
    remaining
  end
  loop do
    response = request(
      "post", "/api/search/smart", token: token, body: { "query" => "a photograph" },
      expected: [200, 500, 502, 503, 504], raw: true,
      timeout: remaining_budget.call
    )
    last_status = response.code
    remaining_budget.call
    found = []
    if response.code.to_i == 200
      begin
        payload = JSON.parse(response.body)
      rescue JSON::ParserError
        fail_contract("POST /api/search/smart returned malformed JSON")
      end
      items = payload.is_a?(Hash) && payload["assets"].is_a?(Hash) &&
              payload["assets"]["items"]
      fail_contract("POST /api/search/smart returned an unsupported schema") unless
        items.is_a?(Array) && items.all? do |item|
          item.is_a?(Hash) && item["id"].is_a?(String)
        end
      found = items.map { |item| item.fetch("id") }
      return if (expected_ids - found).empty?

      unless recovery_requested
        _queue_response, queues = request(
          "get", "/api/jobs", token: token, timeout: remaining_budget.call
        )
        remaining_budget.call
        smart_search = queues.is_a?(Hash) && queues["smartSearch"]
        queue_status = smart_search.is_a?(Hash) && smart_search["queueStatus"]
        job_counts = smart_search.is_a?(Hash) && smart_search["jobCounts"]
        count_names = %w[active waiting delayed paused]
        fail_contract("GET /api/jobs returned an unsupported smartSearch schema") unless
          queue_status.is_a?(Hash) && job_counts.is_a?(Hash) &&
          [true, false].include?(queue_status["isActive"]) &&
          [true, false].include?(queue_status["isPaused"]) &&
          count_names.all? do |name|
            job_counts[name].is_a?(Integer) && job_counts[name] >= 0
          end
        fail_contract("Immich smartSearch queue is paused") if queue_status["isPaused"]

        queue_idle = !queue_status["isActive"] &&
                     count_names.sum { |name| job_counts.fetch(name) }.zero?
        if queue_idle
          request(
            "put", "/api/jobs/smartSearch", token: token,
            body: { "command" => "start", "force" => false },
            timeout: remaining_budget.call
          )
          remaining_budget.call
          recovery_requested = true
        end
      end
    end
    sleep [5, remaining_budget.call].min
  end
end

def assert_originals_open(token, records)
  records.each do |record|
    fixture = FIXTURES.find { |candidate| candidate.fetch(:name) == record.fetch("name") }
    response = request(
      "get", "/api/assets/#{record.fetch('id')}/original", token: token, raw: true
    )
    fail_contract("the original for #{record.fetch('name')} returned HTTP #{response.code}") unless
      response.code.to_i == 200
    fail_contract("the original for #{record.fetch('name')} is not the uploaded bytes") unless
      response.body == fixture.fetch(:bytes)
  end
end

def clean_restore_records(token)
  FIXTURES.map do |fixture|
    id = upload_fixture(token, fixture)
    _response, asset = request("get", "/api/assets/#{id}", token: token)
    {
      "name" => fixture.fetch(:name),
      "id" => id,
      "checksum" => asset.fetch("checksum"),
      "bytes_sha256" => Digest::SHA256.hexdigest(fixture.fetch(:bytes))
    }
  end.sort_by { |record| record.fetch("name") }
end

ROUTINE_BACKUP_PATTERN =
  /\Aimmich-db-backup-\d{8}T\d{6}-v\d+(?:\.\d+)*-pg\d+(?:\.\d+)*\.sql\.gz\z/

def routine_backups(root)
  root.children.select { |path| path.basename.to_s.match?(ROUTINE_BACKUP_PATTERN) }
end

def wait_for_routine_backup(root, timeout:)
  deadline = Time.now + timeout
  previous = nil
  loop do
    candidates = routine_backups(root).select do |path|
      path.file? && !path.symlink?
    end
    if candidates.length == 1 && candidates.first.size.positive?
      current = [candidates.first.basename.to_s, candidates.first.size]
      return candidates.first if current == previous
      previous = current
    else
      previous = nil
    end
    fail_contract("routine database backup did not complete") if Time.now >= deadline
    sleep 2
  end
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
email = vault.fetch("vault_immich_admin_email")
password = vault.fetch("vault_immich_admin_password")
managed_users = vault.fetch("vault_managed_users").fetch("immich")
policy = managed_user_policy

wait_for_application
# A rejected login answers JSON here, unlike some other services in this
# platform, so the parsed body is safe to ask for.
request(
  "post", "/api/auth/login", expected: [401],
  body: { "email" => email, "password" => "contract-wrong-password" }
)
# A successful login answers 201, not 200.
_response, session = request(
  "post", "/api/auth/login", expected: [201],
  body: { "email" => email, "password" => password }
)
token = session.fetch("accessToken")
user_id = safe_id(session.fetch("userId"))
fail_contract("the vault administrator identity or role differs") unless
  session.fetch("userEmail") == email && session.fetch("isAdmin") == true
administrator_session_password_state = session.fetch("shouldChangePassword") do
  fail_contract("the vault administrator login omitted shouldChangePassword")
end
fail_contract("the vault administrator login still requires a password change") unless
  administrator_session_password_state.equal?(false)
_response, administrator_record = request(
  "get", "/api/admin/users/#{user_id}", token: token
)
fail_contract("the authoritative vault administrator response is not an object") unless
  administrator_record.is_a?(Hash)
administrator_record_id = administrator_record["id"]
administrator_record_email = administrator_record["email"]
administrator_record_admin = administrator_record["isAdmin"]
administrator_record_password_state = administrator_record["shouldChangePassword"]
fail_contract("the authoritative vault administrator response has unsupported schema") unless
  administrator_record_id.is_a?(String) && administrator_record_email.is_a?(String) &&
  [true, false].include?(administrator_record_admin) &&
  [true, false].include?(administrator_record_password_state)
fail_contract("the authoritative vault administrator identity or role differs") unless
  administrator_record_id == user_id && administrator_record_email == session["userEmail"] &&
  administrator_record_email == email && administrator_record_admin.equal?(true)
fail_contract("the authoritative vault administrator still requires a password change") unless
  administrator_record_password_state.equal?(false)
assert_user_onboarding(token)

seed_managed_user_state(token, managed_users, policy) if MODE == "seed"

# Creating a second administrator must be refused by the server itself, which is
# what makes the role's create-once behavior safe to rerun.
request(
  "post", "/api/auth/admin-sign-up", expected: [400],
  body: { "email" => "contract-intruder@example.invalid",
          "password" => "contract-wrong-password", "name" => "Contract Intruder" }
)

assert_container_capabilities
config = read_settings(token)

if MODE == "drift-verify"
  fail_contract("the Immich drift fixture was not installed") unless
    config.dig("newVersionCheck", "enabled") == true
  target = list_managed_user_records(token, managed_users).fetch(
    managed_users.first.fetch("email").strip.downcase
  )
  target_id = safe_id(target.fetch("id"))
  _response, drifted_user = request("get", "/api/admin/users/#{target_id}", token: token)
  _response, drifted_preferences = request(
    "get", "/api/admin/users/#{target_id}/preferences", token: token
  )
  desired = desired_managed_user_profile(policy, managed_users.first.fetch("email"))
  fail_contract("the Immich managed preference drift fixture was not installed") unless
    drifted_preferences.dig("folders", "enabled") != desired.dig("folders", "enabled") &&
    drifted_preferences.dig("people", "sidebarWeb") != desired.dig("people", "sidebarWeb") &&
    drifted_preferences.dig("people", "minimumFaces") != desired.dig("people", "minimumFaces") &&
    drifted_preferences.dig("albums", "defaultAssetOrder") == "asc"
  fail_contract("the Immich unowned sentinel did not survive drift installation") unless
    drifted_user["storageLabel"] == MANAGED_SENTINEL && drifted_user["isAdmin"] == false
  if STATE_PATH.file?
    seeded = JSON.parse(STATE_PATH.binread).fetch("managed_users").find do |record|
      record.fetch("email") == managed_users.first.fetch("email").strip.downcase
    end
    fail_contract("the Immich unowned avatar changed during drift installation") unless
      seeded && drifted_user["avatarColor"] == seeded["avatarColor"]
  end
  puts "Immich settings and managed-user preference drift are present"
  exit
end

assert_managed_settings(config)
managed_user_state = assert_managed_user_profiles(
  token, managed_users, policy, require_sentinel: STATE_PATH.file? || MODE == "seed"
)

if MODE == "clean-restore-seed"
  backup_root = MEDIA_ROOT.join("Immich-backups", "database")
  fail_contract("database backup root is unavailable or unsafe") unless
    backup_root.directory? && !backup_root.symlink?
  # Immich keeps its own bookkeeping entries inside every folder it mounts, so
  # the guard is that no database dump predates this run rather than that the
  # directory is bare.
  stale_backups = routine_backups(backup_root).map { |path| path.basename.to_s }
  fail_contract(
    "clean-restore backup root already holds #{stale_backups.join(', ')}"
  ) unless stale_backups.empty?
  records = clean_restore_records(token)
  assert_originals_open(token, records)
  request(
    "post", "/api/jobs", token: token, expected: [204],
    body: { "name" => "backup-database" }
  )
  backup = wait_for_routine_backup(backup_root, timeout: 180)
  state = {
    "user_id" => user_id,
    "assets" => records,
    "settings" => managed_leaves(config),
    "managed_users" => managed_user_state,
    "backup_filename" => backup.basename.to_s
  }
  fail_contract("report root is unavailable or unsafe") unless
    REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace clean-restore state") if
    CLEAN_RESTORE_STATE_PATH.exist? || CLEAN_RESTORE_STATE_PATH.symlink?
  CLEAN_RESTORE_STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(state))
  end
  puts "Immich clean-restore assets and routine backup seeded"
  exit
end

if MODE == "clean-restore-assert"
  fail_contract("clean-restore state is unavailable or unsafe") unless
    CLEAN_RESTORE_STATE_PATH.file? && !CLEAN_RESTORE_STATE_PATH.symlink?
  expected = JSON.parse(CLEAN_RESTORE_STATE_PATH.binread)
  records = expected.fetch("assets")
  actual_records = records.map do |record|
    id = safe_id(record.fetch("id"))
    _response, asset = request("get", "/api/assets/#{id}", token: token)
    original = request("get", "/api/assets/#{id}/original", token: token, raw: true)
    {
      "name" => record.fetch("name"),
      "id" => id,
      "checksum" => asset.fetch("checksum"),
      "bytes_sha256" => Digest::SHA256.hexdigest(original.body)
    }
  end.sort_by { |record| record.fetch("name") }
  actual = {
    "user_id" => user_id,
    "assets" => actual_records,
    "settings" => managed_leaves(config),
    "managed_users" => managed_user_state,
    "backup_filename" => expected.fetch("backup_filename")
  }
  fail_contract("Immich clean restore changed protected state") unless actual == expected
  marker = DOCKER_ROOT.join("immich", ".restore-failed")
  fail_contract("Immich restore failure marker remains") if marker.exist? || marker.symlink?
  puts "Immich clean restore recovered exact assets, users, and settings"
  exit
end

if MODE == "drift"
  drifted = config.merge("newVersionCheck" => config.fetch("newVersionCheck").merge("enabled" => true))
  request("put", "/api/system-config", token: token, body: drifted)
  first_managed = managed_users.first
  target = list_managed_user_records(token, [first_managed]).fetch(
    first_managed.fetch("email").strip.downcase
  )
  target_id = safe_id(target.fetch("id"))
  desired = desired_managed_user_profile(policy, first_managed.fetch("email"))
  request(
    "patch", "/api/admin/users/#{target_id}/preferences", token: token,
    body: {
      "folders" => { "enabled" => !desired.dig("folders", "enabled") },
      "people" => {
        "sidebarWeb" => !desired.dig("people", "sidebarWeb"),
        "minimumFaces" => desired.dig("people", "minimumFaces") + 1
      }
    }
  )
  puts "Immich settings and managed-user preference drift installed"
  exit
end

if MODE == "run"
  puts "Immich login, containment, and settings contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

records = FIXTURES.map do |fixture|
  id = upload_fixture(token, fixture)
  asset = wait_for_thumbnail(token, id, timeout: MODE == "seed" ? 300 : 120)
  fail_contract("#{fixture.fetch(:name)} was stored as #{asset['type'].inspect}") unless
    asset.fetch("type") == fixture.fetch(:kind)
  { "name" => fixture.fetch(:name), "id" => id, "checksum" => asset.fetch("checksum") }
end

assert_originals_open(token, records)
assert_cpu_machine_learning(token, records.map { |record| record.fetch("id") }) if MODE == "seed"

# Generated derivatives must land on the redirected Docker-root volume rather
# than beside the originals, which is the whole point of the nested bind layout.
thumbnail_root = DOCKER_ROOT.join("immich", "data", "thumbs")
thumbnail_root = Pathname.new(ENV.fetch("PLATFORM_IMMICH_THUMBNAIL_ROOT", thumbnail_root.to_s)).expand_path
fail_contract("the generated asset volume is unavailable or unsafe") unless
  thumbnail_root.directory? && !thumbnail_root.symlink?
fail_contract("no generated thumbnail reached the Docker-root volume") if
  Dir.glob(thumbnail_root.join("**", "*_thumbnail.webp").to_s).empty?
originals_root = MEDIA_ROOT.join("Immich", "upload")
originals_root = Pathname.new(ENV.fetch("PLATFORM_IMMICH_UPLOAD_ROOT", originals_root.to_s)).expand_path
fail_contract("the originals volume is unavailable or unsafe") unless
  originals_root.directory? && !originals_root.symlink?

state = JSON.generate(
  "user_id" => user_id,
  "assets" => records.sort_by { |record| record.fetch("name") },
  "settings" => managed_leaves(config),
  "managed_users" => managed_user_state
)

case MODE
when "seed"
  fail_contract("report root is unavailable or unsafe") unless
    REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace the Immich persistence artifact") if
    STATE_PATH.exist? || STATE_PATH.symlink?
  STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(state) }
  puts "Immich fixtures uploaded, thumbnailed, and matched by CPU machine learning"
when "assert-persistence"
  fail_contract("the Immich persistence artifact is unavailable or unsafe") unless
    STATE_PATH.file? && !STATE_PATH.symlink?
  fail_contract("Immich user, assets, or settings changed across recreation") unless
    STATE_PATH.binread == state
  puts "Immich user, assets, and settings persisted"
end
