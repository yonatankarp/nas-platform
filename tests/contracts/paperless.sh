#!/bin/sh
set -eu
set +x

mode=${1:-run}
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
compose=$repo_dir/services/paperless-ngx/compose.yml
mac_compose=$repo_dir/services/paperless-ngx/compose.mac.yml
role=$repo_dir/roles/paperless_ngx/tasks/main.yml
defaults=$repo_dir/roles/paperless_ngx/defaults/main.yml
generator=$repo_dir/generate-secrets.yml
snapshot=$repo_dir/tests/mac/snapshot-paperless.sh
environment_template=$repo_dir/roles/paperless_ngx/templates/env.j2
ocr_fixture=$repo_dir/tests/fixtures/paperless-ocr.png.base64

fail_contract() {
  printf 'Paperless contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$compose" ] || fail_contract 'services/paperless-ngx/compose.yml is absent'
[ -f "$mac_compose" ] || fail_contract 'services/paperless-ngx/compose.mac.yml is absent'
[ -f "$role" ] || fail_contract 'roles/paperless_ngx/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/paperless_ngx/defaults/main.yml is absent'
[ -x "$snapshot" ] || fail_contract 'tests/mac/snapshot-paperless.sh is absent or not executable'
[ -f "$ocr_fixture" ] || fail_contract 'tests/fixtures/paperless-ocr.png.base64 is absent'

ruby -ryaml - "$compose" "$mac_compose" "$role" "$defaults" "$generator" "$environment_template" <<'RUBY'
compose_path, mac_path, role_path, defaults_path, generator_path, environment_template_path = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
mac = YAML.safe_load_file(mac_path, aliases: true)
role = YAML.safe_load_file(role_path, aliases: true)
role_text = File.read(role_path)
defaults = YAML.safe_load_file(defaults_path)
generator = File.read(generator_path)
environment_template = File.read(environment_template_path)

def refuse(message)
  abort "Paperless contract failed: #{message}"
end

services = compose.fetch("services")
expected_images = {
  "broker" => "docker.io/valkey/valkey:9.1.1-alpine@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328",
  "db" => "docker.io/library/postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15",
  "webserver" => "ghcr.io/paperless-ngx/paperless-ngx:3.0.5@sha256:65a4cabf0169ea7fbd90ab7bb28ba3f8b5909613635acda1a03ad606f34b456b",
  "gotenberg" => "docker.io/gotenberg/gotenberg:8.34@sha256:67097317623a503ba2a6a7e9ae8db6929a1f7e1bbd88077bacf2d325fbdab923",
  "tika" => "docker.io/apache/tika:3.3.1.0@sha256:90b7fa1dc018434075fce9e1d9b88b1e3d0ea6979d0cf86e116c79a8073ae973"
}
refuse("stack composition differs") unless services.keys.sort == expected_images.keys.sort
expected_images.each do |name, image|
  refuse("#{name} legacy image pin differs") unless services.fetch(name).fetch("image") == image
end
services.each do |name, service|
  refuse("#{name} restart policy differs") unless service.fetch("restart") == "unless-stopped"
  refuse("#{name} logging policy differs") unless service.fetch("logging") == {
    "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
  }
end

web = services.fetch("webserver")
refuse("NAS webserver must use host networking") unless web.fetch("network_mode") == "host"
refuse("NAS webserver must not publish ports") if web.key?("ports")
refuse("webserver must wait for healthy Tika") unless
  web.fetch("depends_on").fetch("tika").fetch("condition") == "service_healthy"
refuse("Tika healthcheck is absent") unless services.fetch("tika").key?("healthcheck")
%w[broker db gotenberg tika].each do |name|
  refuse("#{name} must bind only to loopback on the NAS") unless
    services.fetch(name).fetch("ports").all? { |port| port.start_with?("127.0.0.1:") }
end

refuse("document storage contract differs") unless web.fetch("volumes").grep(/PAPERLESS_(MEDIA|CONSUME|EXPORT)_PATH/).sort == [
  "${PAPERLESS_CONSUME_PATH:?}:/usr/src/paperless/consume",
  "${PAPERLESS_EXPORT_PATH:?}:/usr/src/paperless/export",
  "${PAPERLESS_MEDIA_PATH:?}:/usr/src/paperless/media"
]
refuse("document paths must not be read-only") if
  web.fetch("volumes").grep(/PAPERLESS_(MEDIA|CONSUME|EXPORT)_PATH/).any? { |volume| volume.end_with?(":ro") }
refuse("application-state storage contract differs") unless
  web.fetch("volumes").include?("${PAPERLESS_DATA_PATH:?}:/usr/src/paperless/data") &&
  services.fetch("broker").fetch("volumes") == ["${PAPERLESS_REDIS_PATH:?}:/data"] &&
  services.fetch("db").fetch("volumes") == ["${PAPERLESS_POSTGRES_PATH:?}:/var/lib/postgresql"]
refuse("Hebrew OCR model is not mounted read-only") unless
  web.fetch("volumes").include?("${PAPERLESS_TESSDATA_PATH:?}/heb.traineddata:/usr/share/tesseract-ocr/5/tessdata/heb.traineddata:ro")
refuse("OCR languages differ") unless web.fetch("environment").fetch("PAPERLESS_OCR_LANGUAGE") == "deu+eng+heb"
refuse("optional Ollama configuration differs from the canonical stack") unless
  web.fetch("environment").slice(
    "PAPERLESS_AI_ENABLED", "PAPERLESS_AI_LLM_BACKEND", "PAPERLESS_AI_LLM_CONTEXT_SIZE",
    "PAPERLESS_AI_LLM_ENDPOINT", "PAPERLESS_AI_LLM_MODEL", "PAPERLESS_AI_LLM_REQUEST_TIMEOUT"
  ) == {
    "PAPERLESS_AI_ENABLED" => "${PAPERLESS_AI_ENABLED:?}",
    "PAPERLESS_AI_LLM_BACKEND" => "ollama", "PAPERLESS_AI_LLM_CONTEXT_SIZE" => 4096,
    "PAPERLESS_AI_LLM_ENDPOINT" => "${PAPERLESS_AI_LLM_ENDPOINT:?}",
    "PAPERLESS_AI_LLM_MODEL" => "${PAPERLESS_AI_LLM_MODEL:?}",
    "PAPERLESS_AI_LLM_REQUEST_TIMEOUT" => 300
  }

override_services = mac.fetch("services")
refuse("Mac override must provide all services") unless override_services.keys.sort == services.keys.sort
refuse("Mac webserver must replace host networking") unless
  override_services.fetch("webserver").fetch("network_mode") == "bridge"
refuse("Mac webserver must publish only its configured port") unless
  override_services.fetch("webserver").fetch("ports") == ["${PAPERLESS_HOST_PORT:?}:8000"]
%w[broker db gotenberg tika].each do |name|
  refuse("Mac #{name} must not publish a port") unless override_services.fetch(name).fetch("ports") == []
end

required_tasks = [
  "Render the Paperless environment",
  "Deploy the Paperless data services",
  "Refuse a rotated Paperless database credential",
  "Deploy Paperless",
  "Create the absent vault Paperless administrator",
  "Authenticate the vault Paperless administrator",
  "Repair the vault Paperless administrator",
  "Refuse duplicate managed Paperless mail accounts",
  "Inspect the installed Paperless Gmail credential fingerprint",
  "Test the candidate Paperless Gmail credential before persistence",
  "Require a valid non-consuming Paperless Gmail credential before persistence",
  "Create the managed Paperless mail account",
  "Repair the managed Paperless mail account",
  "Refuse duplicate managed Paperless mail rules",
  "Create the managed Paperless mail rule",
  "Repair the managed Paperless mail rule",
  "Test the managed Paperless mail account without consuming messages",
  "Require exact Paperless administrator, mail account, and mail rule",
  "Record the verified Paperless Gmail credential fingerprint"
]
required_tasks.each { |name| refuse("missing #{name}") unless role_text.include?("- name: #{name}") }
refuse("role must never invoke the consuming mail endpoint") if role_text.match?(%r{/mail_accounts/.+/process/})

secret_tasks = role.select do |task|
  task.to_s.match?(/vault_paperless_|paperless_api_token|paperless_mail_account_payload/)
end
secret_tasks.each do |task|
  refuse("secret-bearing task #{task['name']} is not redacted") unless task["no_log"] == true
end
refuse("Gmail app password must be a visible sentinel in the new-platform generator") unless
  generator.include?("paperless_gmail_app_password: replace-with-google-app-password")
refuse("generator must not synthesize a Gmail app password") if
  generator.match?(/paperless_gmail_app_password:\s*[\"']?\{\{/)
refuse("role must accept Google's grouped app-password display") unless
  role_text.include?("vault_paperless_gmail_app_password | replace(' ', '')")
refuse("host-network endpoint selection must cover NAS and integration") unless
  environment_template.include?("platform_compose_kind in ['nas', 'integration']")
%w[
  vault_paperless_db_password vault_paperless_django_secret_key
  vault_paperless_admin_username vault_paperless_admin_password vault_paperless_admin_email
].each do |variable|
  refuse("#{variable} is not protected from Compose interpolation") unless
    environment_template.include?("#{variable} | replace('$', '$$')")
end

account = defaults.fetch("paperless_mail_account")
refuse("Gmail IMAP settings differ") unless account == {
  "imap_server" => "imap.gmail.com", "imap_port" => 993, "imap_security" => 2,
  "is_token" => false, "account_type" => 1, "character_set" => "UTF-8"
}
rule = defaults.fetch("paperless_mail_rule")
refuse("managed mail rule must be enabled and non-destructive") unless
  rule.fetch("enabled") == true && rule.fetch("folder") == "INBOX" &&
  rule.fetch("action") == 3 && rule.fetch("consumption_scope") == 1
RUBY

grep -qF 'run_paperless_contract seed' "$repo_dir/tests/integration.sh" ||
  fail_contract 'integration does not exercise Paperless document fixtures'
grep -qF 'run_paperless_snapshot drill' "$repo_dir/tests/integration.sh" ||
  fail_contract 'integration does not exercise coordinated Paperless recovery'
grep -qF 'run("docker", "stop", WEBSERVER, REDIS)' "$snapshot" ||
  fail_contract 'Paperless snapshot does not quiesce writers'
grep -qF 'wait_healthy(REDIS, WEBSERVER)' "$snapshot" ||
  fail_contract 'Paperless restore does not wait for application health'
grep -qF 'request("delete", "/api/documents/' "$snapshot" ||
  fail_contract 'Paperless rollback drill does not destructively test restoration'
grep -qF '"document_importer"' "$repo_dir/tests/contracts/paperless.sh" ||
  fail_contract 'Paperless portable export is never restored'
grep -qF 'document_exporter --passphrase "$passphrase"' "$repo_dir/tests/contracts/paperless.sh" ||
  fail_contract 'Paperless portable export does not encrypt sensitive fields'
grep -qF 'document_importer --passphrase "$passphrase"' "$repo_dir/tests/contracts/paperless.sh" ||
  fail_contract 'Paperless portable import does not decrypt sensitive fields'

[ "$mode" = static ] && { printf '%s\n' 'Paperless static contract passed'; exit 0; }

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_PAPERLESS_PORT:=8000}"
: "${PLATFORM_PAPERLESS_WEBSERVER_CONTAINER:=paperless_webserver}"
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT PLATFORM_PAPERLESS_PORT
export PLATFORM_PAPERLESS_WEBSERVER_CONTAINER PLATFORM_CONTRACT_REPO_DIR

shift || true
exec ruby - "$mode" "$@" <<'RUBY'
require "digest"
require "json"
require "net/http"
require "open3"
require "pathname"
require "timeout"
require "uri"
require "yaml"
require "zlib"

MODE = ARGV.fetch(0)
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_PAPERLESS_PORT'), 10)}")
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
REPO_ROOT = Pathname.new(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR", Dir.pwd)).expand_path
WEBSERVER = ENV.fetch("PLATFORM_PAPERLESS_WEBSERVER_CONTAINER")
STATE_PATH = REPORT_ROOT.join("paperless-persistence.json")
EXPORT_PATH = MEDIA_ROOT.join("Documents/export/task-13-contract-export")
PDF_MARKER = "paperlesscontractenglish"
IMAGE_MARKER = "paperless contract image ocr"
OFFICE_MARKER = "paperlesscontracthebrew"
OFFICE_TEXT = "Paperless contract English Deutsch Überprüfung Hebrew שלום #{OFFICE_MARKER}"

def fail_contract(message)
  warn "Paperless contract failed: #{message}"
  exit 1
end

def endpoint(path)
  URI.join(BASE.to_s, path)
end

def request(method, path, token: nil, body: nil, expected: [200], parse_json: true)
  uri = endpoint(path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Token #{token}" if token
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 60) do |http|
    http.request(request)
  end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless
    expected.include?(response.code.to_i)
  payload = if parse_json
              response.body.to_s.empty? ? nil : JSON.parse(response.body)
            else
              response.body.to_s
            end
  [response, payload]
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

def results(payload)
  payload.fetch("results")
end

def pdf_bytes(text)
  escaped = text.gsub(/[\\()]/) { |character| "\\#{character}" }
  stream = "BT /F1 18 Tf 72 720 Td (#{escaped}) Tj ET\n"
  objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream"
  ]
  body = "%PDF-1.4\n"
  offsets = [0]
  objects.each_with_index do |object, index|
    offsets << body.bytesize
    body << "#{index + 1} 0 obj\n#{object}\nendobj\n"
  end
  xref = body.bytesize
  body << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
  offsets.drop(1).each { |offset| body << format("%010d 00000 n \n", offset) }
  body << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
end

def zip_entries(entries)
  local = +"".b
  central = +"".b
  entries.each do |name, contents|
    name = name.b
    contents = contents.b
    crc = Zlib.crc32(contents)
    offset = local.bytesize
    local << [0x04034b50, 20, 0, 0, 0, 0, crc, contents.bytesize, contents.bytesize,
              name.bytesize, 0].pack("VvvvvvVVVvv") << name << contents
    central << [0x02014b50, 20, 20, 0, 0, 0, 0, crc, contents.bytesize, contents.bytesize,
                name.bytesize, 0, 0, 0, 0, 0, offset].pack("VvvvvvvVVVvvvvvVV") << name
  end
  local + central +
    [0x06054b50, 0, 0, entries.length, entries.length, central.bytesize,
     local.bytesize, 0].pack("VvvvvVVv")
end

def docx_bytes(text)
  escaped = text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  zip_entries([
    ["[Content_Types].xml", <<~XML],
      <?xml version="1.0" encoding="UTF-8"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      </Types>
    XML
    ["_rels/.rels", <<~XML],
      <?xml version="1.0" encoding="UTF-8"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
      </Relationships>
    XML
    ["word/document.xml", <<~XML]
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>#{escaped}</w:t></w:r></w:p></w:body></w:document>
    XML
  ])
end

def write_fixture(path, bytes)
  path.dirname.mkpath
  if path.exist?
    fail_contract("fixture bytes drifted: #{path.basename}") unless path.file? && path.binread == bytes
  else
    path.open(File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) }
  end
end

def run_bounded(seconds, *argv, input: nil)
  reader, writer = IO.pipe if input
  spawn_options = { pgroup: true, out: File::NULL, err: File::NULL }
  spawn_options[:in] = reader if input
  pid = Process.spawn(*argv, **spawn_options)
  reader&.close
  if input
    writer.write(input)
    writer.close
  end
  status = nil
  begin
    Timeout.timeout(seconds) { _waited, status = Process.wait2(pid) }
  rescue Timeout::Error
    begin
      Process.kill("TERM", -pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Timeout.timeout(5) { Process.wait(pid) }
    rescue Timeout::Error
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
    fail_contract("#{argv.first} timed out")
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
  fail_contract("#{argv.first} failed") unless status.success?
end

def document_for(token, marker, deadline:)
  loop do
    _response, payload = request(
      "get", "/api/documents/?query=#{URI.encode_www_form_component(marker)}&page_size=100",
      token: token
    )
    match = results(payload).find { |document| document.fetch("content", "").downcase.include?(marker.downcase) }
    return match if match
    fail_contract("document marker #{marker} was not indexed") if Time.now >= deadline
    sleep 3
  end
end

def canonical_documents(pdf_document, image_document, office_document)
  JSON.generate({
    "pdf_id" => pdf_document.fetch("id"), "image_id" => image_document.fetch("id"),
    "office_id" => office_document.fetch("id"),
    "pdf_checksum" => pdf_document.fetch("checksum"),
    "image_checksum" => image_document.fetch("checksum"),
    "office_checksum" => office_document.fetch("checksum")
  }.sort.to_h)
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
export_passphrase = Digest::SHA256.hexdigest(
  "paperless-portable-export:\0#{vault.fetch('vault_paperless_django_secret_key')}"
)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)

_token_response, token_payload = request(
  "post", "/api/token/",
  body: {
    "username" => vault.fetch("vault_paperless_admin_username"),
    "password" => vault.fetch("vault_paperless_admin_password")
  }
)
token = token_payload.fetch("token")

_users_response, users_payload = request("get", "/api/users/?page_size=1000", token: token)
admins = results(users_payload).select do |user|
  user["username"] == vault.fetch("vault_paperless_admin_username")
end
fail_contract("vault administrator identity differs") unless
  admins.length == 1 && admins.first["email"] == vault.fetch("vault_paperless_admin_email") &&
  admins.first["is_superuser"] && admins.first["is_staff"] && admins.first["is_active"]

_accounts_response, accounts_payload = request("get", "/api/mail_accounts/?page_size=1000", token: token)
accounts = results(accounts_payload).select do |account|
  account["name"] == vault.fetch("vault_paperless_mail_account_name")
end
fail_contract("managed Gmail account is absent or duplicated") unless accounts.length == 1
account = accounts.first
expected_account = {
  "name" => vault.fetch("vault_paperless_mail_account_name"),
  "imap_server" => "imap.gmail.com", "imap_port" => 993, "imap_security" => 2,
  "username" => vault.fetch("vault_paperless_gmail_account"), "character_set" => "UTF-8",
  "is_token" => false, "account_type" => 1, "owner" => admins.first.fetch("id")
}
expected_account.each do |key, value|
  fail_contract("managed Gmail account #{key} differs") unless account[key] == value
end

_rules_response, rules_payload = request("get", "/api/mail_rules/?page_size=1000", token: token)
rules = results(rules_payload).select { |rule| rule["name"] == vault.fetch("vault_paperless_mail_rule_name") }
fail_contract("managed Gmail rule is absent or duplicated") unless rules.length == 1
rule = rules.first
expected_rule = {
  "account" => account.fetch("id"), "enabled" => true, "folder" => "INBOX",
  "action" => 3, "consumption_scope" => 1, "attachment_type" => 1,
  "owner" => admins.first.fetch("id")
}

if MODE == "drift"
  request("patch", "/api/mail_rules/#{rule.fetch('id')}/", token: token,
          body: { "enabled" => false }, expected: [200])
  puts "Paperless mail-rule drift installed"
  exit
end
if MODE == "drift-verify"
  fail_contract("Paperless drift fixture was not installed") unless rule["enabled"] == false
  puts "Paperless mail-rule drift is present"
  exit
end
expected_rule.each do |key, value|
  fail_contract("managed Gmail rule #{key} differs") unless rule[key] == value
end

unless ENV["PLATFORM_KIND"] == "integration"
  _mail_before_response, mail_before = request("get", "/api/processed_mail/?page_size=1", token: token)
  _tasks_before_response, tasks_before = request("get", "/api/tasks/?page_size=1", token: token)
  test_payload = expected_account.merge("id" => account.fetch("id"), "password" => "**********")
  _test_response, test_result = request(
    "post", "/api/mail_accounts/test/", token: token, body: test_payload, expected: [200]
  )
  fail_contract("Gmail connection test did not succeed") unless test_result.fetch("success") == true
  _mail_after_response, mail_after = request("get", "/api/processed_mail/?page_size=1", token: token)
  _tasks_after_response, tasks_after = request("get", "/api/tasks/?page_size=1", token: token)
  fail_contract("Gmail connection test consumed mail") unless mail_before.fetch("count") == mail_after.fetch("count")
  fail_contract("Gmail connection test queued a task") unless tasks_before.fetch("count") == tasks_after.fetch("count")
end

if MODE == "run"
  puts "Paperless login, Gmail, and non-consuming connection contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

consume = MEDIA_ROOT.join("Documents/inbox")
if MODE == "seed"
  write_fixture(consume.join("task-13-contract.pdf"), pdf_bytes("Paperless PDF #{PDF_MARKER}"))
  write_fixture(
    consume.join("task-13-contract.png"),
    REPO_ROOT.join("tests/fixtures/paperless-ocr.png.base64").read.delete("\n").unpack1("m0")
  )
  write_fixture(consume.join("task-13-contract.docx"), docx_bytes(OFFICE_TEXT))
end

processing_deadline = Time.now + 240
pdf_document = document_for(token, PDF_MARKER, deadline: processing_deadline)
image_document = document_for(token, IMAGE_MARKER, deadline: processing_deadline)
office_document = document_for(token, OFFICE_MARKER, deadline: processing_deadline)
[pdf_document, image_document, office_document].each do |document|
  preview_response, preview_body = request(
    "get", "/api/documents/#{document.fetch('id')}/preview/", token: token, parse_json: false
  )
  fail_contract("document preview was not a PDF") unless
    preview_response["Content-Type"].to_s.split(";", 2).first == "application/pdf" &&
    preview_body.start_with?("%PDF")
end
fail_contract("image OCR did not preserve German text") unless
  image_document.fetch("content", "").downcase.include?("überprüfung")
fail_contract("image OCR did not preserve Hebrew text") unless
  image_document.fetch("content", "").include?("עברית")
fail_contract("Office conversion did not preserve German text") unless
  office_document.fetch("content", "").include?("Überprüfung")
fail_contract("Office conversion did not preserve Hebrew text") unless
  office_document.fetch("content", "").include?("שלום")

canonical = canonical_documents(pdf_document, image_document, office_document)

case MODE
when "seed"
  fail_contract("report root is unavailable or unsafe") unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace Paperless persistence artifact") if STATE_PATH.exist? || STATE_PATH.symlink?
  STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(canonical) }
  fail_contract("refusing to replace Paperless export fixture") if EXPORT_PATH.exist? || EXPORT_PATH.symlink?
  run_bounded(
    120,
    "docker", "exec", "-i", WEBSERVER, "sh", "-ec",
    'IFS= read -r passphrase; exec python manage.py document_exporter --passphrase "$passphrase" "$1"',
    "paperless-exporter", "/usr/src/paperless/export/task-13-contract-export",
    input: "#{export_passphrase}\n"
  )
  fail_contract("portable export was not created") unless EXPORT_PATH.directory? && EXPORT_PATH.children.any?
  [pdf_document, image_document, office_document].each do |document|
    request("delete", "/api/documents/#{document.fetch('id')}/", token: token, expected: [204])
  end
  deletion_deadline = Time.now + 120
  loop do
    remaining = [PDF_MARKER, IMAGE_MARKER, OFFICE_MARKER].sum do |marker|
      _response, payload = request(
        "get", "/api/documents/?query=#{URI.encode_www_form_component(marker)}&page_size=100",
        token: token
      )
      results(payload).length
    end
    break if remaining.zero?
    fail_contract("portable export mutation did not remove the documents") if Time.now >= deletion_deadline
    sleep 2
  end
  run_bounded(
    120,
    "docker", "exec", "-i", WEBSERVER, "sh", "-ec",
    'IFS= read -r passphrase; exec python manage.py document_importer --passphrase "$passphrase" "$1"',
    "paperless-importer", "/usr/src/paperless/export/task-13-contract-export",
    input: "#{export_passphrase}\n"
  )
  import_deadline = Time.now + 240
  imported_pdf = document_for(token, PDF_MARKER, deadline: import_deadline)
  imported_image = document_for(token, IMAGE_MARKER, deadline: import_deadline)
  imported_office = document_for(token, OFFICE_MARKER, deadline: import_deadline)
  fail_contract("portable export did not restore exact records") unless
    canonical_documents(imported_pdf, imported_image, imported_office) == canonical
  puts "Paperless PDF, Office, OCR, search, preview, export, and import fixtures seeded"
when "assert-persistence"
  fail_contract("Paperless persistence artifact is unavailable or unsafe") unless STATE_PATH.file? && !STATE_PATH.symlink?
  fail_contract("Paperless documents changed across recreation") unless STATE_PATH.binread == canonical
  fail_contract("Paperless portable export did not persist") unless EXPORT_PATH.directory? && EXPORT_PATH.children.any?
  puts "Paperless documents, search index, previews, and export persisted"
end
RUBY
