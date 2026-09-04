#!/usr/bin/env ruby
# Verify every managed ntfy account against the vault that authored it.
#
# usage: 15-ntfy.rb   (the decrypted vault arrives on standard input)
#
# tests/mac/hooks/verify/15-ntfy.sh is the hook this belongs to. It decrypts the
# vault with ansible-vault and pipes the plaintext here, so **this program reads
# standard input** and must not be invoked with `</dev/null`. That redirect is
# right for every other program #315 lifted out of a heredoc and wrong for this
# one: a heredoc consumes the caller's standard input by construction, and here
# the caller's standard input is the payload.
#
# Reads PLATFORM_NTFY_BASE_URL and PLATFORM_NTFY_TOPICS, both set by the hook.
#
# It ran from a `<<'RUBY'` heredoc in that hook until #315, opened as
# `ruby -rjson -rnet/http -ruri -ryaml /dev/fd/3` -- the body carried no
# requires of its own and took all four from the command line, so the four
# below are that invocation written down. Everything after them is
# byte-identical to what the heredoc rendered.
require "json"
require "net/http"
require "uri"
require "yaml"

vault = YAML.safe_load($stdin.read, aliases: false)
abort "ntfy verification vault is not a mapping" unless vault.is_a?(Hash)

managed = vault.dig("vault_managed_users", "ntfy")
abort "ntfy managed-user vault shape is invalid" unless managed.is_a?(Array)

base_url = ENV.fetch("PLATFORM_NTFY_BASE_URL")
topics = ENV.fetch("PLATFORM_NTFY_TOPICS").split
account_uri = URI("#{base_url}/v1/account")

# A managed account must be subscribed to exactly the provisioned topics it may
# read, and to no provisioned topic it may not.
def readable_topics(user, topics)
  topics.select do |topic|
    user.fetch("access").any? do |rule|
      rule.is_a?(Hash) && rule["topic"] == topic &&
        %w[read-only read-write].include?(rule["permission"])
    end
  end
end

eligible = managed.select do |user|
  abort "ntfy managed-user shape is invalid" unless user.is_a?(Hash)
  abort "ntfy managed users must be nonadministrative" unless user["role"] == "user"
  access = user["access"]
  abort "ntfy managed-user ACL shape is invalid" unless access.is_a?(Array)
  !readable_topics(user, topics).empty?
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
  readable = readable_topics(user, topics)
  topics.each do |topic|
    matches = subscriptions.count do |subscription|
      subscription["base_url"] == base_url && subscription["topic"] == topic
    end
    expected = readable.include?(topic) ? 1 : 0
    abort "ntfy synchronized #{topic} subscription differs" unless matches == expected
  end
end
