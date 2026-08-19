#!/bin/sh
set -eu

ruby tests/policy_test.rb
ruby tests/secrets_docs_test.rb
ruby tests/docs_links_test.rb
