#!/usr/bin/env ruby
# The runtime half of the Paperless service contract: everything that needs a
# served Paperless, a vault and a Docker host.
#
# usage: ruby paperless-runtime.rb MODE [ARGUMENT...]
#
# No -r preloads, because the heredoc this came from had none: the requires
# below are the program's own. Its whole input beyond MODE is the PLATFORM_*
# environment the wrapper exports, and PLATFORM_CONTRACT_REPO_DIR is the tree
# being inspected rather than the checkout this file lives in.
#
# The wrapper reads this file's text for three constants it cannot observe by
# running the static half -- DOCUMENT_INDEX_TIMEOUT_SECONDS,
# MAIL_PROBE_READ_TIMEOUT and its use at the mail-account probe -- so moving
# or renaming any of them is a contract change, not a refactor.
require "digest"
require "json"
require "net/http"
require "open3"
require "pathname"
require "tempfile"
require "timeout"
require "uri"
require "yaml"
require "zlib"

MODE = ARGV.fetch(0)
DOCUMENT_INDEX_TIMEOUT_SECONDS = 600
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_PAPERLESS_PORT'), 10)}")
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
REPO_ROOT = Pathname.new(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR", Dir.pwd)).expand_path
WEBSERVER = ENV.fetch("PLATFORM_PAPERLESS_WEBSERVER_CONTAINER")
STATE_PATH = REPORT_ROOT.join("paperless-persistence.json")
EXPORT_ROOT = Pathname.new(
  ENV.fetch("PLATFORM_PAPERLESS_EXPORT_ROOT", MEDIA_ROOT.join("Documents", "export").to_s)
).expand_path
CONSUME_ROOT = Pathname.new(
  ENV.fetch("PLATFORM_PAPERLESS_CONSUME_ROOT", MEDIA_ROOT.join("Documents", "inbox").to_s)
).expand_path
EXPORT_PATH = EXPORT_ROOT.join("task-13-contract-export")
PDF_MARKER = "paperlesscontractenglish"
IMAGE_MARKER = "paperless contract image ocr"
OFFICE_MARKER = "paperlesscontracthebrew"
OFFICE_TEXT = "Paperless contract English Deutsch Überprüfung Hebrew שלום #{OFFICE_MARKER}"
MAIL_PROBE_READ_TIMEOUT = 180

def fail_contract(message)
  warn "Paperless contract failed: #{message}"
  exit 1
end

def endpoint(path)
  URI.join(BASE.to_s, path)
end

def request(method, path, token: nil, body: nil, expected: [200], parse_json: true, read_timeout: 60)
  uri = endpoint(path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Token #{token}" if token
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: read_timeout) do |http|
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

def seed_document_fixtures
  write_fixture(
    CONSUME_ROOT.join("task-13-contract.pdf"),
    pdf_bytes("Paperless PDF #{PDF_MARKER}")
  )
  write_fixture(
    CONSUME_ROOT.join("task-13-contract.png"),
    REPO_ROOT.join("tests/fixtures/paperless-ocr.png.base64").read.delete("\n").unpack1("m0")
  )
  write_fixture(CONSUME_ROOT.join("task-13-contract.docx"), docx_bytes(OFFICE_TEXT))
end

def run_bounded(seconds, *argv, input: nil, label:)
  reader, writer = IO.pipe if input
  Tempfile.create("paperless-contract-command") do |stderr|
    spawn_options = { pgroup: true, out: File::NULL, err: stderr }
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
      fail_contract("#{label} timed out")
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end
    unless status.success?
      stderr.flush
      stderr.rewind
      diagnostic_bytes = stderr.read
      diagnostic = if diagnostic_bytes.bytesize > 4096
                     diagnostic_bytes.byteslice(diagnostic_bytes.bytesize - 4096, 4096)
                   else
                     diagnostic_bytes
                   end
      diagnostic = diagnostic.encode("UTF-8", invalid: :replace, undef: :replace)
      secret = input.to_s.strip
      diagnostic.gsub!(secret, "[REDACTED]") unless secret.empty?
      warn "Paperless #{label} diagnostic: #{diagnostic.strip}" unless diagnostic.strip.empty?
      fail_contract("#{label} failed")
    end
  end
end

def wait_healthy(container, deadline:)
  loop do
    stdout, _stderr, status = Open3.capture3(
      "docker", "inspect", "--format", "{{.State.Health.Status}}", container
    )
    return if status.success? && stdout.strip == "healthy"
    fail_contract("#{container} did not become healthy") if Time.now >= deadline
    sleep 2
  end
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
    "pdf_checksum" => document_checksum(pdf_document),
    "image_checksum" => document_checksum(image_document),
    "office_checksum" => document_checksum(office_document)
  }.sort.to_h)
end

def document_checksum(document)
  root_version = document.fetch("versions").find { |version| version.fetch("is_root") }
  checksum = root_version&.fetch("checksum")
  fail_contract("document root-version checksum is absent") if checksum.to_s.empty?
  checksum
end

if MODE == "seed-fixture-only"
  seed_document_fixtures
  puts "Paperless document fixtures prepared before deployment"
  exit 0
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
  managed_mail_before = {
    "accounts" => accounts.sort_by { |entry| entry.fetch("id") },
    "rules" => rules.sort_by { |entry| entry.fetch("id") }
  }
  test_payload = expected_account.merge("id" => account.fetch("id"), "password" => "**********")
  _test_response, test_result = request(
    "post", "/api/mail_accounts/test/", token: token, body: test_payload, expected: [200],
    read_timeout: MAIL_PROBE_READ_TIMEOUT
  )
  fail_contract("Gmail connection test did not return exact success") unless test_result == { "success" => true }
  _accounts_after_response, accounts_after_payload = request(
    "get", "/api/mail_accounts/?page_size=1000", token: token
  )
  _rules_after_response, rules_after_payload = request(
    "get", "/api/mail_rules/?page_size=1000", token: token
  )
  managed_mail_after = {
    "accounts" => results(accounts_after_payload).select do |entry|
      entry["name"] == vault.fetch("vault_paperless_mail_account_name")
    end.sort_by { |entry| entry.fetch("id") },
    "rules" => results(rules_after_payload).select do |entry|
      entry["name"] == vault.fetch("vault_paperless_mail_rule_name")
    end.sort_by { |entry| entry.fetch("id") }
  }
  fail_contract("Gmail connection test altered managed mail state") unless
    managed_mail_before == managed_mail_after
end

unrelated_account_name = "paperless-contract-unrelated-account"
unrelated_rule_name = "paperless-contract-unrelated-rule"
if MODE == "seed"
  unrelated_accounts = results(accounts_payload).select { |entry| entry["name"] == unrelated_account_name }
  fail_contract("unrelated mail-account fixture is duplicated") if unrelated_accounts.length > 1
  if unrelated_accounts.empty?
    _response, unrelated_account = request(
      "post", "/api/mail_accounts/", token: token, expected: [201],
      body: expected_account.merge(
        "name" => unrelated_account_name, "username" => "unrelated@example.invalid",
        "password" => "not-a-live-credential"
      ).reject { |key, _value| key == "id" }
    )
  else
    unrelated_account = unrelated_accounts.fetch(0)
  end
  unrelated_rules = results(rules_payload).select { |entry| entry["name"] == unrelated_rule_name }
  fail_contract("unrelated mail-rule fixture is duplicated") if unrelated_rules.length > 1
  if unrelated_rules.empty?
    request(
      "post", "/api/mail_rules/", token: token, expected: [201],
      body: {
        "name" => unrelated_rule_name, "account" => unrelated_account.fetch("id"),
        "enabled" => false, "folder" => "Contract-Unrelated", "maximum_age" => 1,
        "action" => 1, "assign_title_from" => 1, "assign_tags" => [],
        "assign_correspondent_from" => 1, "assign_owner_from_rule" => true,
        "order" => 99, "attachment_type" => 1, "consumption_scope" => 1,
        "pdf_layout" => 0, "stop_processing" => true, "owner" => admins.first.fetch("id")
      }
    )
  end
elsif STATE_PATH.exist?
  unrelated_accounts = results(accounts_payload).select { |entry| entry["name"] == unrelated_account_name }
  unrelated_rules = results(rules_payload).select { |entry| entry["name"] == unrelated_rule_name }
  fail_contract("reconciliation did not preserve the unrelated mail account and rule") unless
    unrelated_accounts.length == 1 && unrelated_rules.length == 1 &&
      unrelated_rules.first["account"] == unrelated_accounts.first.fetch("id") &&
      unrelated_rules.first["enabled"] == false
end

if MODE == "run"
  puts "Paperless login, Gmail, and non-consuming connection contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

if MODE == "seed" && ENV.fetch("PLATFORM_PAPERLESS_FIXTURE_PRESEEDED") != "true"
  seed_document_fixtures
end

processing_deadline = Time.now + DOCUMENT_INDEX_TIMEOUT_SECONDS
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
  EXPORT_PATH.mkdir(0o700)
  run_bounded(
    120,
    "docker", "exec", "-i", WEBSERVER, "sh", "-ec",
    'IFS= read -r passphrase; exec python manage.py document_exporter --passphrase "$passphrase" --no-progress-bar "$1"',
    "paperless-exporter", "/usr/src/paperless/export/task-13-contract-export",
    input: "#{export_passphrase}\n", label: "document exporter"
  )
  puts "Paperless encrypted portable export created"
  fail_contract("portable export was not created") unless EXPORT_PATH.directory? && EXPORT_PATH.children.any?
  document_ids = [pdf_document, image_document, office_document].map { |document| document.fetch("id") }
  document_ids.each do |document_id|
    request("delete", "/api/documents/#{document_id}/", token: token, expected: [204])
  end
  request(
    "post", "/api/trash/", token: token,
    body: { "action" => "empty", "documents" => document_ids }, expected: [200]
  )
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
    'IFS= read -r passphrase; exec python manage.py document_importer --passphrase "$passphrase" --no-progress-bar "$1"',
    "paperless-importer", "/usr/src/paperless/export/task-13-contract-export",
    input: "#{export_passphrase}\n", label: "document importer"
  )
  run_bounded(120, "docker", "restart", WEBSERVER, label: "webserver restart")
  wait_healthy(WEBSERVER, deadline: Time.now + 120)
  puts "Paperless encrypted portable export imported"
  import_deadline = Time.now + DOCUMENT_INDEX_TIMEOUT_SECONDS
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
