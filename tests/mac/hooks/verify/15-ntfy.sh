#!/bin/sh
set -eu
set +x

: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_NTFY_PORT:?PLATFORM_NTFY_PORT is required}"

ntfy_hook_base_url=http://127.0.0.1:$PLATFORM_NTFY_PORT
ansible-vault view \
  --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
  "$PLATFORM_MAC_VAULT_FILE" 2>/dev/null |
  PLATFORM_NTFY_BASE_URL=$ntfy_hook_base_url \
    ruby -rjson -rnet/http -ruri -ryaml /dev/fd/3 3<<'RUBY'
vault = YAML.safe_load($stdin.read, aliases: false)
abort "ntfy verification vault is not a mapping" unless vault.is_a?(Hash)

managed = vault.dig("vault_managed_users", "ntfy")
abort "ntfy managed-user vault shape is invalid" unless managed.is_a?(Array)

base_url = ENV.fetch("PLATFORM_NTFY_BASE_URL")
account_uri = URI("#{base_url}/v1/account")
eligible = managed.select do |user|
  abort "ntfy managed-user shape is invalid" unless user.is_a?(Hash)
  abort "ntfy managed users must be nonadministrative" unless user["role"] == "user"
  access = user["access"]
  abort "ntfy managed-user ACL shape is invalid" unless access.is_a?(Array)
  access.any? do |rule|
    rule.is_a?(Hash) && rule["topic"] == "nas-critical" &&
      %w[read-only read-write].include?(rule["permission"])
  end
end

eligible.each do |user|
  request = Net::HTTP::Get.new(account_uri)
  request.basic_auth(user.fetch("username"), user.fetch("password"))
  response = Net::HTTP.start(account_uri.hostname, account_uri.port) do |http|
    http.request(request)
  end
  abort "ntfy account verification failed" unless response.code == "200"
  account = JSON.parse(response.body)
  abort "ntfy account response shape is invalid" unless account.is_a?(Hash)
  abort "ntfy account identity differs" unless account["username"] == user.fetch("username")
  abort "ntfy managed account role differs" unless account["role"] == "user"
  subscriptions = account["subscriptions"] || []
  abort "ntfy account response shape is invalid" unless subscriptions.is_a?(Array)
  subscriptions.each do |subscription|
    abort "ntfy subscription response shape is invalid" unless
      subscription.is_a?(Hash) && subscription.keys.sort == %w[base_url display_name topic] &&
        subscription["base_url"].is_a?(String) && subscription["topic"].is_a?(String) &&
        (subscription["display_name"].nil? || subscription["display_name"].is_a?(String))
  end
  matches = subscriptions.count do |subscription|
    subscription["base_url"] == base_url &&
      subscription["topic"] == "nas-critical"
  end
  abort "ntfy synchronized nas-critical subscription differs" unless matches == 1
end
RUBY
