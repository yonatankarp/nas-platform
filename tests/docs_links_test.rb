#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "pathname"
require "tmpdir"
require "uri"

ROOT = Pathname.new(File.expand_path("..", __dir__))
SOURCES = [ROOT.join("README.md"), *ROOT.join("docs").glob("**/*.md")].freeze

def markdown_target(body)
  value = body.strip
  return if value.empty?

  if value.start_with?("<")
    closing = value.index(">")
    return unless closing

    value[1...closing]
  else
    value.split(/\s+/, 2).first
  end
end

def markdown_link_bodies(text)
  links = []
  brackets = []
  parentheses = matching_parentheses(text)
  index = 0
  while index < text.length
    if text[index] == "\\"
      index += 2
      next
    end
    if text[index] == "["
      brackets << index
      index += 1
      next
    end
    unless text[index] == "]"
      index += 1
      next
    end
    label_end = brackets.pop
    unless label_end
      index += 1
      next
    end
    open = index + 1
    if text[open] == "("
      close = parentheses[open]
      if text[open + 1] == "<"
        close = angle_destination_close(text, open)
      end
      links << text[(open + 1)...close] if close
      index = close ? close + 1 : open + 1
    else
      index += 1
    end
  end
  links
end

def angle_destination_close(text, open)
  start = open + 1
  start += 1 while start < text.length && text[start].match?(/\s/)
  return unless text[start] == "<"

  closing_angle = text.index(">", start + 1)
  return unless closing_angle

  text.index(")", closing_angle + 1)
end

def matching_parentheses(text)
  stack = []
  matches = {}
  candidates = {}
  cursor = 0
  while (position = text.index("](", cursor))
    candidates[position + 1] = true unless escaped?(text, position)
    cursor = position + 2
  end
  index = 0
  while index < text.length
    if text[index] == "\\"
      index += 2
      next
    end
    if text[index] == "(" && (stack.any? || candidates[index]) && !(stack.any? && stack[-1][1])
      stack << [index, nil]
    elsif text[index].match?(/[\"']/) && !stack.empty? && stack[-1][1].nil? && index.positive? && text[index - 1].match?(/\s/)
      stack[-1][1] = text[index]
    elsif text[index].match?(/[\"']/) && !stack.empty? && stack[-1][1] == text[index]
      stack[-1][1] = nil
    elsif text[index] == ")" && !stack.empty? && !stack[-1][1] && (open = stack.pop[0])
      matches[open] = index
    end
    index += 1
  end
  matches
end

def escaped?(text, index)
  slashes = 0
  index -= 1
  while index >= 0 && text[index] == "\\"
    slashes += 1
    index -= 1
  end
  slashes.odd?
end

def mask_code(text)
  lines = text.lines
  fence = nil
  lines.each_with_index do |line, index|
    prefix, marker, suffix = fence_parts(line)
    if marker
      if fence && marker[0] == fence[0] && marker.length >= fence[1] && suffix.match?(/\A[ \t]*(?:\r?\n)?\z/)
        fence = nil
      elsif fence.nil?
        fence = [marker[0], marker.length]
      end
      lines[index] = line.gsub(/[^\n]/, " ")
    elsif fence
      lines[index] = line.gsub(/[^\n]/, " ")
    end
  end
  [lines.join, fence]
end

def fence_parts(line)
  value = line
  value = value.sub(/\A {0,3}(?:(?:> ? {0,3})|(?:[-+*] {1,4}|\d{1,9}[.)] {1,4}))*/, "")
  match = value.match(/\A(`{3,}|~{3,})(.*?)(?:\r?\n)?\z/)
  return [nil, nil, nil] if match && match[1].start_with?("`") && match[2].include?("`")

  match ? [value, match[1], match[2]] : [nil, nil, nil]
end

def markdown_container(line)
  rest = line.dup
  indented_first_marker = rest.match?(/\A {1,3}(?:>|[-+*](?: |$)|\d{1,9}[.)](?: |$))/)
  signature = []
  list_item = false
  ordered_number = nil
  loop do
    if rest.sub!(/\A {0,3}> ?/, "")
      signature << :quote
    elsif rest.sub!(/\A {0,3}[-+*] {1,4}/, "")
      signature << :list
      list_item = true
    elsif (match = rest.match(/\A {0,3}(\d{1,9})[.)] {1,4}/))
      rest = rest[match[0].length..]
      signature << :list
      list_item = true
      ordered_number = match[1].to_i
    else
      break
    end
  end
  empty_list_item = list_item && rest.strip.empty?
  [signature, line.length - rest.length, list_item, ordered_number, empty_list_item, indented_first_marker]
end

def standalone_block_line?(line, content_start)
  content = line[content_start..].to_s.sub(/\r?\n\z/, "")
  content.match?(/\A {0,3}\#{1,6}(?:[ \t]+|$)/) ||
    content.match?(/\A {0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,}|(?:=+|-+)[ \t]*)\z/)
end

def sanitize(value)
  value.gsub(/[[:cntrl:]]/, "?")
end

def markdown_section(document, heading)
  heading = "## #{heading}" unless heading.start_with?("#")
  lines = document.lines
  heading_index = lines.index { |line| line.rstrip == heading }
  return "" unless heading_index

  heading_level = heading[/\A#+/].length
  lines.drop(heading_index + 1).take_while do |line|
    next_heading = line.rstrip.match(/\A(#+)(?:\s|\z)/)
    !next_heading || next_heading[1].length > heading_level
  end.join
end

def normalized_checklist_items(markdown)
  items = []
  current = nil
  mask_block_contexts(markdown).each_line do |line|
    if (match = line.match(/\A\s*-\s+\[[ xX]\]\s+(.*)/))
      items << current if current
      current = match[1].strip
    elsif current && line.match?(/\A\s{2,}\S/)
      current = "#{current} #{line.strip}"
    elsif !line.strip.empty?
      items << current if current
      current = nil
    end
  end
  items << current if current
  items.map { |item| item.gsub(/\s+/, " ") }
end

def normalize_block_text(text)
  CGI.unescapeHTML(text).gsub(/\s+/, " ").strip
end

def markdown_semantic_blocks(markdown)
  blocks = []
  current = nil
  standalone_fence = nil
  heading_path = []
  flush = lambda do
    if current && !current[:parts].empty?
      blocks << current.merge(text: normalize_block_text(current.delete(:parts).join(" ")))
    end
    current = nil
  end

  context_lines = mask_block_contexts(markdown, preserve_fences: true).lines
  masked_lines = mask_block_contexts(markdown).lines
  context_lines.zip(masked_lines).each do |context_line, masked_line|
    if standalone_fence
      _, closing_marker, closing_suffix = fence_parts(context_line)
      if closing_marker && closing_marker[0] == standalone_fence[:marker][0] &&
         closing_marker.length >= standalone_fence[:marker].length &&
         closing_suffix.match?(/\A[ \t]*(?:\r?\n)?\z/)
        blocks << standalone_fence.except(:marker, :parts).merge(
          text: normalize_block_text(standalone_fence[:parts].join(" "))
        )
        standalone_fence = nil
      else
        standalone_fence[:parts] << context_line.strip
      end
      next
    end

    _, opening_marker, opening_suffix = fence_parts(context_line)
    if opening_marker && current&.dig(:kind) != :list_item
      flush.call
      standalone_fence = {
        heading_path: heading_path.compact.dup,
        kind: :fenced_code,
        number: nil,
        checklist: false,
        indent: 0,
        language: opening_suffix.strip,
        marker: opening_marker,
        parts: []
      }
      next
    end

    stripped = masked_line.to_s.strip
    if (heading = stripped.match(/\A(#+)\s+(.+?)\s*\z/))
      flush.call
      level = heading[1].length
      heading_path = heading_path.take(level - 1)
      heading_path[level - 1] = "#{heading[1]} #{heading[2]}"
    elsif (item = masked_line.to_s.match(/\A(\s*)([-+*]|(\d+)[.)])\s+(\[[ xX]\]\s+)?(.*)/))
      flush.call
      current = {
        heading_path: heading_path.compact.dup,
        kind: :list_item,
        number: item[3]&.to_i,
        checklist: !item[4].nil?,
        indent: item[1].length,
        parts: [item[5]]
      }
    elsif stripped.empty?
      # Blank lines and fenced-code lines do not end a list item. This keeps
      # wrapped/nested numbered procedures as one semantic step. Preserve the
      # fenced command text in that step so rollback mutations also fail closed.
      if current&.dig(:kind) == :list_item && !context_line.to_s.strip.empty?
        current[:parts] << context_line.strip
      elsif current&.dig(:kind) == :paragraph
        flush.call
      end
    elsif current&.dig(:kind) == :list_item &&
          masked_line.match?(/\A\s{#{current[:indent] + 1},}\S/)
      current[:parts] << stripped
    else
      flush.call if current&.dig(:kind) == :list_item
      current ||= {
        heading_path: heading_path.compact.dup,
        kind: :paragraph,
        number: nil,
        checklist: false,
        indent: 0,
        parts: []
      }
      current[:parts] << stripped
    end
  end
  if standalone_fence
    blocks << standalone_fence.except(:marker, :parts).merge(
      text: normalize_block_text(standalone_fence[:parts].join(" "))
    )
  end
  flush.call
  blocks
end

def normalized_document_blocks(markdown)
  markdown_semantic_blocks(markdown).map { |block| block[:text] }
end

def markdown_heading_paths(markdown)
  path = []
  mask_block_contexts(markdown).each_line.filter_map do |line|
    heading = line.strip.match(/\A(#+)\s+(.+?)\s*\z/)
    next unless heading

    level = heading[1].length
    path = path.take(level - 1)
    path[level - 1] = "#{heading[1]} #{heading[2]}"
    path.compact.dup
  end
end

def normalized_prose(markdown)
  normalized_document_blocks(markdown).join(" ")
end

def visible_tinymediamanager_mention?(text)
  visible_text = CGI.unescapeHTML(text).gsub(/\[([^\]]+)\]\([^)]*\)/, '\\1')
  visible_text.match?(/tinymediamanager/i)
end

def retirement_block(path:, kind:, text:, number: nil, checklist: false, language: nil)
  {
    heading_path: path,
    kind: kind,
    number: number,
    checklist: checklist,
    language: language,
    text: normalize_block_text(text)
  }
end

def retirement_block_contracts
  # These exact blocks are a fail-closed operator-safety contract. Editorial
  # changes involving tinyMediaManager require a deliberate review and matching
  # update here; free-form prose is intentionally not interpreted as English.
  @retirement_block_contracts ||= {
    "README" => [
      retirement_block(
        path: ["# NAS platform", "## New to Ansible?"], kind: :paragraph,
        text: <<~TEXT
          The service stacks in [`services/manifest.yml`](services/manifest.yml) are implemented. tinyMediaManager is now a transitional retirement role rather than an active service. Prove the complete platform on the Mac before preparing a fresh production NAS installation.
        TEXT
      ),
      retirement_block(
        path: ["# NAS platform", "## tinyMediaManager retirement checkpoint"], kind: :paragraph,
        text: <<~TEXT
          tinyMediaManager is retired and must remain stopped. Its bind-mounted state is preserved through this transitional release. The Movies and Series libraries are neither deleted nor moved by retirement. The `vault_tinymediamanager_password` key remains until the cleanup release so the preserved deployment can support a deliberate rollback.
        TEXT
      ),
      retirement_block(
        path: ["# NAS platform", "## tinyMediaManager retirement checkpoint"], kind: :paragraph,
        text: <<~TEXT
          Permanent removal of the role, Compose definitions, vault key, ports, CI coverage, and preserved storage declaration waits for the NAS verification checkpoint and a separate cleanup release. That cleanup release removes repository declarations only; it must not delete `{{ nas_docker_root }}/tinymediamanager/data` or its contents. Any later data deletion requires a separate, backed-up, explicit operator decision and is not part of this retirement.
        TEXT
      ),
      retirement_block(
        path: ["# NAS platform", "## Testing"], kind: :paragraph,
        text: <<~TEXT
          The current Mac proof covers ntfy, Beszel, Dozzle, Audiobookshelf, Komga, Jellyfin, Immich, Paperless-ngx, and the tinyMediaManager retirement state. NAS-only GPU, host-networking, native-mount and production-scale behavior remain outside the Mac proof.
        TEXT
      )
    ],
    "beginner guide" => [
      retirement_block(
        path: ["# Getting started with NAS platform", "## Before running anything"], kind: :paragraph,
        text: <<~TEXT
          The migration is still in progress. The eight active services are ntfy, Beszel, Dozzle, Audiobookshelf, Komga, Jellyfin, Immich, and Paperless-ngx. tinyMediaManager remains implemented only as a transitional retirement role: it is retired, must remain stopped, and its bind-mounted state remains preserved. The authoritative status is [`services/manifest.yml`](../services/manifest.yml).
        TEXT
      )
    ],
    "NAS guide" => [
      retirement_block(
        path: ["# Physical NAS walkthrough"], kind: :paragraph,
        text: <<~TEXT
          This path targets a fresh production installation. Complete the [disposable Mac proof](getting-started-mac.md), protect any media already on the NAS, and confirm every required service is `implemented` or `accepted` in [`services/manifest.yml`](../services/manifest.yml) before installation. The active services are Audiobookshelf, Beszel, Dozzle, Immich, Jellyfin, Komga, ntfy, and Paperless-ngx. tinyMediaManager remains in the manifest only for its transitional retirement lifecycle.
        TEXT
      ),
      retirement_block(
        path: ["# Physical NAS walkthrough", "## tinyMediaManager retirement checkpoint"], kind: :paragraph,
        text: <<~TEXT
          tinyMediaManager is retired and must remain stopped. Its bind-mounted state is preserved through this transitional release. The Movies and Series libraries are neither deleted nor moved by retirement. The `vault_tinymediamanager_password` key remains until the cleanup release so a deliberate rollback can reuse the preserved configuration.
        TEXT
      ),
      retirement_block(
        path: ["# Physical NAS walkthrough", "## tinyMediaManager retirement checkpoint"], kind: :paragraph,
        text: <<~TEXT
          Permanent cleanup of the role, Compose definitions, vault key, published ports, CI coverage, and preserved storage declaration waits for the NAS verification checkpoint and a separate cleanup release. The cleanup release removes repository declarations only; it must not delete `{{ nas_docker_root }}/tinymediamanager/data` or its contents. Any later data deletion requires a separate, backed-up, explicit operator decision and is not part of this retirement. This release does not deploy Radarr, Sonarr, or Bazarr. Open Subtitles remains configured in Jellyfin until Bazarr is proven.
        TEXT
      ),
      retirement_block(
        path: ["# Physical NAS walkthrough", "## tinyMediaManager retirement checkpoint", "### What the retirement verification proves"], kind: :paragraph,
        text: <<~TEXT
          `platform_verify_tinymediamanager` proves container absence and that the state root exists, is a directory, and is not a symlink. It does not inspect or verify the state contents. Before declaring the application state preserved, make a read-only comparison against a prior inventory or snapshot and confirm a small set of representative expected files or backup records. Do not recursively hash the state, print configuration contents, or expose credentials in evidence.
        TEXT
      ),
      retirement_block(
        path: ["# Physical NAS walkthrough", "## 7. Verify and prove idempotence"], kind: :paragraph,
        text: <<~TEXT
          Record the Git commit, encrypted vault checksum, recap, application checks, and operator decision without recording secrets. Existing NAS credentials must work unchanged for all eight active services. Keep the retired tinyMediaManager credential unchanged, but do not authenticate to or start the retired service. Repeat the service-specific credential checks from the [Mac manual review](getting-started-mac.md#4-perform-the-manual-review) against the production deployment without exercising external integrations; for ntfy, use only an agreed disposable topic when verifying alerts from Beszel and Dozzle.
        TEXT
      ),
      retirement_block(
        path: ["# Physical NAS walkthrough", "## Automatic deployment from the NAS"], kind: :paragraph,
        text: <<~TEXT
          The `platform_verify_tinymediamanager` tag applies the bounded checks described in [What the retirement verification proves](#what-the-retirement-verification-proves); it does not verify configuration contents or a live UI or API.
        TEXT
      ),
      retirement_block(
        path: ["# Physical NAS walkthrough", "## Automatic deployment from the NAS"],
        kind: :fenced_code, language: "sh",
        text: %q{ansible-playbook -i inventory/local.yml validate-vault.yml \ --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" ansible-playbook -i inventory/local.yml site.yml \ --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" ansible-playbook -i inventory/local.yml verify.yml \ --tags platform_verify_ntfy,platform_verify_beszel,platform_verify_dozzle,platform_verify_audiobookshelf,platform_verify_komga,platform_verify_tinymediamanager,platform_verify_jellyfin,platform_verify_immich,platform_verify_paperless \ --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"}
      ),
      retirement_block(
        path: ["# Physical NAS walkthrough", "## Recover after loss of `/volume1`", "### Converge in recovery stages"], kind: :paragraph,
        text: <<~TEXT
          Do not interpret a clean play recap as proof that old application records were restored. Verify representative photos, users, albums, documents, metadata, and search results in each active application. Keep tinyMediaManager stopped and follow the [retirement checkpoint](#tinymediamanager-retirement-checkpoint) rather than attempting an application check.
        TEXT
      )
    ],
    "Mac guide" => [
      retirement_block(
        path: ["# Disposable Mac proof"], kind: :paragraph,
        text: <<~TEXT
          This proof covers the eight active services in [`services/manifest.yml`](../services/manifest.yml)—Audiobookshelf, Beszel, Dozzle, Immich, Jellyfin, Komga, ntfy, and Paperless-ngx—plus the tinyMediaManager retirement proof. tinyMediaManager is retired and must remain stopped; its bind-mounted state is preserved for the transitional checkpoint. The harness creates a disposable legacy fixture, converges its retirement, and requires both container absence and a preserved safe bind-state checkpoint. It sends test alerts to the sandbox's own ntfy instance. Mobile delivery is outside scope.
        TEXT
      ),
      retirement_block(
        path: ["# Disposable Mac proof", "## 4. Perform the manual review"], kind: :paragraph,
        text: <<~TEXT
          Proceed only when the block prints `All automated phases passed`. Use [`tests/mac/manual-review.md`](../tests/mac/manual-review.md) while the eight active services are running and the retired tinyMediaManager container is absent. The retirement contract also checks that its representative non-secret fixture remains unchanged in the safe bind-mounted state. Record the reviewer, manifest commit, decision, and non-secret notes. Credential continuity requires a private check for every active service:
        TEXT
      ),
      retirement_block(
        path: ["# Disposable Mac proof", "## 4. Perform the manual review"], kind: :paragraph,
        text: <<~TEXT
          For tinyMediaManager, perform only the retirement checkpoint: confirm the container remains absent and the bind-mounted state remains preserved. Do not open its UI or API, authenticate, scan a library, or write metadata.
        TEXT
      )
    ],
    "secrets guide" => [
      retirement_block(
        path: ["# Secrets and encrypted vault", "## Existing deployment recovery", "### Vault contract inventory"], kind: :list_item,
        text: <<~TEXT
          tinyMediaManager: `vault_tinymediamanager_password` remains until the cleanup release. tinyMediaManager is retired and must remain stopped, but this transitional key is preserved with its bind-mounted state for a deliberate rollback. Recover the deployed API password from the password manager or preserved configuration if it is not already in the vault; do not start the service merely to confirm it and do not rotate it.
        TEXT
      ),
      retirement_block(
        path: ["# Secrets and encrypted vault", "## Existing deployment recovery", "### Vault contract inventory"], kind: :list_item,
        text: <<~TEXT
          Managed application users: `vault_managed_users`. This mapping has exactly the eight service lists documented below. Identity comparisons trim surrounding whitespace and ignore case. Every list entry needs a non-empty preserved password, must be unique within its service, and must not duplicate that service's primary administrator. Beszel entries also differ from the primary Beszel application user; ntfy entries differ from the Dozzle and Beszel publishers. Do not add retired tinyMediaManager here; its preserved rollback contract retains the single shared login.
        TEXT
      )
    ],
    "Mac manual review" => [
      retirement_block(
        path: ["# Mac platform proof manual review", "## Application checks"], kind: :list_item, checklist: true,
        text: <<~TEXT
          tinyMediaManager: confirm it is retired, its container is absent, it must remain stopped, and its bind-mounted state remains preserved.
        TEXT
      )
    ]
  }
end

def nas_rollback_contract
  path = [
    "# Physical NAS walkthrough",
    "## tinyMediaManager retirement checkpoint",
    "### Temporary rollback procedure"
  ]
  [
    retirement_block(path: path, kind: :paragraph, text: <<~TEXT),
      The reviewed pre-retirement revision `ca15db3` is the source of the active tinyMediaManager definitions. It is not a platform rollback target. Do not roll the entire platform back to that revision or blindly restore its complete inventory. Use this mutual-exclusion procedure:
    TEXT
    retirement_block(path: path, kind: :list_item, number: 1, text: <<~TEXT),
      Record the intended current platform revision. Pause or disable the five-minute production auto-deployer using the procedure under [Automatic deployment from the NAS](#automatic-deployment-from-the-nas): save `crontab -l`, remove only the `NAS platform production auto-deploy` entry with `crontab -e`, and verify that entry is absent. Leave automation disabled throughout the temporary rollback.
    TEXT
    retirement_block(path: path, kind: :list_item, number: 2, text: <<~TEXT),
      From the intended current revision, create a temporary rollback branch. Restore only the tinyMediaManager role and Compose trees from `ca15db3`, then review the matching tinyMediaManager storage declaration so the active role can manage that already-preserved directory. Do not replace the complete inventory file. Review the diff and place this narrow change in a temporary rollback commit: ```sh git switch -c ops/tinymediamanager-temporary-rollback git restore --source=ca15db3 -- \\ roles/tinymediamanager services/tinymediamanager git diff -- roles/tinymediamanager services/tinymediamanager \\ inventory/group_vars/all/main.yml ``` Edit only the matching tinyMediaManager storage declaration. The reviewed storage edit removes `preserve_only` only from the existing `{{ nas_docker_root }}/tinymediamanager/data` declaration; it does not add, move, recreate, or delete that directory.
    TEXT
    retirement_block(path: path, kind: :list_item, number: 3, text: <<~TEXT),
      Before Radarr or Sonarr is deployed, the simpler rollback may now check and converge this reviewed temporary commit; there is no arr writer to stop. If Radarr or Sonarr has written Movies or Series, first stop both Radarr and Sonarr using their reviewed orchestration and verify both containers are absent. Keep Radarr and Sonarr stopped for the entire period tinyMediaManager can run. Do not proceed merely because an application UI looks idle.
    TEXT
    retirement_block(path: path, kind: :list_item, number: 4, text: <<~TEXT),
      Check the temporary commit with `--check --diff`, review every change, and then converge it. Confirm that Movies and Series still point to their existing paths. The invariant is one media writer at a time.
    TEXT
    retirement_block(path: path, kind: :list_item, number: 5, text: <<~TEXT),
      Before restarting any arr writer, restore or check out the intended current platform revision and converge it. Its tinyMediaManager retirement role is the mechanism that stops and removes the container without volumes; do not substitute an unbounded manual Compose command. Verify the tinyMediaManager container is absent and the retirement checks pass. Only then restart Radarr and Sonarr and re-enable the auto-deployer.
    TEXT
    retirement_block(path: path, kind: :paragraph, text: <<~TEXT)
      The temporary branch and commit are rollback evidence, not a new deployment baseline. If any container-absence or path check is ambiguous, stop the procedure instead of allowing concurrent writers.
    TEXT
  ]
end

OPERATOR_RETIREMENT_CONTRACT_LABELS = {
  "README.md" => "README",
  "docs/getting-started.md" => "beginner guide",
  "docs/getting-started-mac.md" => "Mac guide",
  "docs/getting-started-nas.md" => "NAS guide",
  "docs/secrets.md" => "secrets guide",
  "tests/mac/manual-review.md" => "Mac manual review"
}.freeze

def operator_retirement_documents(root)
  candidates = [
    root.join("README.md"),
    *root.join("docs").glob("getting-started*.md"),
    root.join("docs/secrets.md"),
    root.join("tests/mac/manual-review.md")
  ]
  candidates.select(&:file?).uniq.sort.to_h do |path|
    [path.relative_path_from(root).to_s, path.read]
  end
end

def document_has_visible_tinymediamanager_mention?(markdown)
  markdown_heading_paths(markdown).any? do |path|
    visible_tinymediamanager_mention?(path.last)
  end || markdown_semantic_blocks(markdown).any? do |block|
    visible_tinymediamanager_mention?(block[:text])
  end
end

def operator_retirement_contract_violations(root)
  operator_retirement_documents(root).flat_map do |relative_path, document|
    label = OPERATOR_RETIREMENT_CONTRACT_LABELS[relative_path]
    if label
      retirement_contract_violations(label, document).map do |violation|
        "#{relative_path}: #{violation}"
      end
    elsif document_has_visible_tinymediamanager_mention?(document)
      ["#{relative_path}: visible tinyMediaManager mention has no explicit structural contract"]
    else
      []
    end
  end
end

def contract_signature(block)
  %i[heading_path kind number checklist language text].to_h do |key|
    [key, block[key]]
  end
end

def retirement_section_contracts
  @retirement_section_contracts ||= begin
    readme_path = ["# NAS platform", "## tinyMediaManager retirement checkpoint"]
    nas_path = ["# Physical NAS walkthrough", "## tinyMediaManager retirement checkpoint"]
    readme_blocks = retirement_block_contracts.fetch("README").select do |block|
      block[:heading_path] == readme_path
    end
    readme_blocks << retirement_block(
      path: readme_path, kind: :paragraph,
      text: <<~TEXT
        Radarr, Sonarr, and Bazarr are not deployed by this release. Open Subtitles remains configured in Jellyfin until Bazarr is proven. See the [NAS retirement and rollback procedure](docs/getting-started-nas.md#tinymediamanager-retirement-checkpoint) before changing any media writer.
      TEXT
    )

    nas_blocks = retirement_block_contracts.fetch("NAS guide").select do |block|
      block[:heading_path].take(nas_path.length) == nas_path
    end
    {
      "README" => [{ path: readme_path, blocks: readme_blocks }],
      "NAS guide" => [{ path: nas_path, blocks: nas_blocks + nas_rollback_contract }]
    }
  end
end

def retirement_contract_violations(label, markdown)
  contracts = retirement_block_contracts.fetch(label)
  blocks = markdown_semantic_blocks(markdown)
  rollback_path = nas_rollback_contract.first[:heading_path]
  mentioned_blocks = blocks.select { |block| visible_tinymediamanager_mention?(block[:text]) }
  mentioned_blocks.reject! { |block| block[:heading_path] == rollback_path } if label == "NAS guide"

  remaining = contracts.map(&:dup)
  failures = []
  mentioned_blocks.each do |block|
    match_index = remaining.index { |contract| contract_signature(contract) == contract_signature(block) }
    if match_index
      remaining.delete_at(match_index)
    else
      failures << "unexpected tinyMediaManager block under #{block[:heading_path].last.inspect}: #{block[:text]}"
    end
  end
  remaining.each do |contract|
    failures << "missing approved tinyMediaManager block under #{contract[:heading_path].last.inspect}"
  end

  allowed_tinymediamanager_heading_paths = contracts.map { |contract| contract.fetch(:heading_path) }.select do |path|
    visible_tinymediamanager_mention?(path.last)
  end
  if label == "NAS guide"
    allowed_tinymediamanager_heading_paths << rollback_path.take(2)
  end
  allowed_tinymediamanager_heading_paths.uniq!
  actual_tinymediamanager_heading_paths = markdown_heading_paths(markdown).select do |path|
    visible_tinymediamanager_mention?(path.last)
  end
  unless actual_tinymediamanager_heading_paths == allowed_tinymediamanager_heading_paths
    failures << "tinyMediaManager headings differ from their approved structural locations"
  end

  retirement_section_contracts.fetch(label, []).each do |section|
    section_blocks = blocks.select do |block|
      block[:heading_path].take(section[:path].length) == section[:path]
    end
    unless section_blocks.map { |block| contract_signature(block) } ==
           section[:blocks].map { |block| contract_signature(block) }
      failures << "retirement section differs from its approved complete block sequence"
    end
  end

  if label == "NAS guide"
    rollback_blocks = blocks.select { |block| block[:heading_path] == rollback_path }
    unless rollback_blocks.map { |block| contract_signature(block) } ==
           nas_rollback_contract.map { |block| contract_signature(block) }
      failures << "temporary rollback procedure differs from its approved ordered block contract"
    end
  end
  failures
end

def mask_block_contexts(text, preserve_fences: false)
  fence_masked, = mask_code(text)
  protected_ranges = inline_partners(fence_masked).filter_map do |opening, closing|
    (opening...closing) if opening < closing
  end.sort_by(&:begin)
  range_index = 0
  comment = false
  fence = nil
  offset = 0
  text.lines.map do |line|
    if fence
      _, marker, suffix = fence_parts(line)
      fence = nil if marker && marker[0] == fence[0] && marker.length >= fence[1] && suffix.match?(/\A[ \t]*(?:\r?\n)?\z/)
      masked = preserve_fences ? line : line.gsub(/[^\n]/, " ")
      offset += line.length
      next masked
    end

    unless comment
      _, marker, = fence_parts(line)
      if marker
        fence = [marker[0], marker.length]
        masked = preserve_fences ? line : line.gsub(/[^\n]/, " ")
        offset += line.length
        next masked
      end
    end

    chars = line.chars
    index = 0
    while index < chars.length
      if comment
        close_at = line.index("-->", index)
        finish = close_at ? close_at + 3 : line.length
        chars[index...finish] = chars[index...finish].map { |char| char == "\n" ? char : " " }
        index = finish
        comment = false if close_at
        next
      end

      start = line.index("<!--", index)
      break unless start

      absolute = offset + start
      range_index += 1 while protected_ranges[range_index] && protected_ranges[range_index].end <= absolute
      _, content_start, = markdown_container(line)
      comment_prefix = line[content_start...start]
      block_comment = comment_prefix.length <= 3 && comment_prefix.strip.empty?
      protected = !block_comment && protected_ranges[range_index]&.cover?(absolute)
      if escaped?(line, start) || protected
        index = start + 4
      else
        comment = true
        index = start
      end
    end
    offset += line.length
    chars.join
  end.join
end

def mask_contexts(text)
  lines = text.lines
  partner_text = mask_block_contexts(text)
  partners = inline_partners(partner_text)
  output = []
  comment = false
  fence = nil
    inline = nil
    inline_start = nil
    offset = 0
  lines.each do |line|
    if fence
      _, marker, suffix = fence_parts(line)
      if marker && marker[0] == fence[0] && marker.length >= fence[1] && suffix.match?(/\A[ \t]*(?:\r?\n)?\z/)
        fence = nil
      end
      output << line.gsub(/[^\n]/, " ")
      offset += line.length
      next
    end
    if !comment && inline.nil?
      _, marker, = fence_parts(line)
      if marker
        fence = [marker[0], marker.length]
        output << line.gsub(/[^\n]/, " ")
        offset += line.length
        next
      end
    end
    chars = line.chars
    first_non_space = line.index(/[^ ]/) || line.length
    index = 0
    while index < chars.length
      if comment
        close_at = line.index("-->", index)
        finish = close_at ? close_at + 3 : line.length
        chars[index...finish] = chars[index...finish].map { |char| char == "\n" ? char : " " }
        index = finish
        comment = false if close_at
        next
      end
      if inline
        absolute = offset + index
        if absolute == partners[inline_start]
          run_length = inline
          chars[index, run_length] = chars[index, run_length].map { " " }
          inline = nil
          inline_start = nil
          index += run_length
        else
          chars[index] = " " unless chars[index] == "\n"
          index += 1
        end
        next
      end
      if chars[index, 4].join == "<!--" && !escaped?(line, index)
        comment = true
        next
      end
      if chars[index] == "`"
        finish = index
        finish += 1 while finish < chars.length && chars[finish] == "`"
        run_length = finish - index
        slash_count = 0
        before = index - 1
        while before >= 0 && chars[before] == "\\"
          slash_count += 1
          before -= 1
        end
        if slash_count.odd?
          index = finish
          next
        end
        if run_length >= 3 && index == first_non_space && index >= 4
          index = finish
          inline = nil
          next
        end
        absolute = offset + index
        closing = partners[absolute]
        unless closing && closing > absolute
          index = finish
          next
        end
        inline = run_length
        inline_start = absolute
        chars[index...finish] = chars[index...finish].map { " " }
        index = finish
        next
      end
      index += 1
    end
    output << chars.join
    offset += line.length
  end
  [output.join, fence]
end

def inline_partners(text)
  partners = {}
  tokens = []
  offset = 0
  paragraph = 0
  previous_container = []
  paragraph_active = false
  text.lines.each do |line|
    container, content_start, list_item, ordered_number, empty_list_item, indented_first_marker = markdown_container(line)
    standalone_block = standalone_block_line?(line, content_start)
    blank = line.strip.empty?
    if !blank && container.empty? && !previous_container.empty? && !standalone_block
      container = previous_container
    elsif paragraph_active && (empty_list_item || (ordered_number && ordered_number != 1)) &&
          (container[0...-1] == previous_container || (indented_first_marker && container == previous_container))
      container = previous_container
      list_item = false
    end
    paragraph += 1 if container != previous_container || list_item || standalone_block
    index = 0
    leading_space = true
    leading_space_count = 0
    slash_count = 0
    while index < line.length
      char = line[index]
      if char == "\\"
        slash_count += 1
        index += 1
        next
      end
      unless char == "`"
        leading_space_count += 1 if leading_space && char == " "
        leading_space = false unless char == " "
        slash_count = 0
        index += 1
        next
      end
      finish = index + 1
      finish += 1 while finish < line.length && line[finish] == "`"
      length = finish - index
      position = offset + index
      indented_block = leading_space && leading_space_count >= 4 && length >= 3
      tokens << [position, length, paragraph] unless slash_count.odd? || indented_block
      leading_space = false
      slash_count = 0
      index = finish
    end
    offset += line.length
    paragraph += 1 if blank || standalone_block
    previous_container = blank || standalone_block ? [] : container
    paragraph_active = !blank && !standalone_block
  end

  next_matching = {}
  previous_by_length = {}
  tokens.each_index do |token_index|
    length = tokens[token_index][1]
    key = [tokens[token_index][2], length]
    next_matching[previous_by_length[key]] = token_index if previous_by_length.key?(key)
    previous_by_length[key] = token_index
  end
  token_index = 0
  while token_index < tokens.length
    closing_index = next_matching[token_index]
    unless closing_index
      token_index += 1
      next
    end
    opening = tokens[token_index][0]
    closing = tokens[closing_index][0]
    partners[opening] = closing
    partners[closing] = opening
    token_index = closing_index + 1
  end
  partners
end

def unescape_destination(value)
  punctuation = %q{!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~}
  value.gsub(/\\(.)/) { |match| punctuation.include?(match[1]) ? match[1] : match }
end

def check_sources(root, sources)
  root = root.realpath
  failures = []
  sources.each do |source|
    source = source.realpath
    source_name = sanitize(source.relative_path_from(root).to_s)
    text, unclosed_fence = mask_contexts(source.read)
    failures << "#{source_name}: malformed documentation (unclosed code fence)" if unclosed_fence
    markdown_link_bodies(text).each do |body|
      raw_target = body.strip
      target = markdown_target(body)
      next if target.nil? || target.empty? || target.start_with?("#")
      next if target.match?(/\A(?:https?|mailto):/i)

      encoded_path = target.split("#", 2).first
      raise ArgumentError if encoded_path.match?(/%(?![0-9A-Fa-f]{2})/)

      path_text = URI::DEFAULT_PARSER.unescape(unescape_destination(encoded_path))
      resolved = source.dirname.join(path_text).cleanpath
      lexical_inside = resolved.to_s.start_with?("#{root}/")
      valid = lexical_inside && resolved != root && (resolved.file? || resolved.directory?)
      if valid
        begin
          valid = resolved.realpath.to_s.start_with?("#{root}/")
        rescue Errno::ENOENT, Errno::ELOOP
          valid = false
        end
      end
      unless valid
        shown = sanitize(raw_target)
        failures << "#{source_name}: broken local link #{shown}"
      end
    rescue ArgumentError
      shown = sanitize(raw_target)
      failures << "#{source_name}: malformed local link #{shown}"
    end
  end
  failures
end

def self_test
  unless markdown_link_bodies("[" * 50_000).empty? && markdown_link_bodies("[](" * 50_000).empty?
    warn "docs links hostile-unmatched self-test failed"
    exit 1
  end
  escaped_probe = inline_partners("\\` ordinary ")
  paired_probe = inline_partners("` hidden `")
  unless !escaped_probe.key?(0) && paired_probe[0] == 9
    warn "docs links inline partner self-test failed"
    exit 1
  end
  wrapped_checklist = <<~MARKDOWN
    - [ ] tinyMediaManager: confirm the container is absent and the bind-mounted
          state remains preserved.
  MARKDOWN
  unless normalized_checklist_items(wrapped_checklist) == [
    "tinyMediaManager: confirm the container is absent and the bind-mounted state remains preserved."
  ]
    warn "docs links wrapped-checklist self-test failed"
    exit 1
  end
  nested_steps = <<~MARKDOWN
    # Procedure

    1. First wrapped
       step.
       - Nested wrapped
         check.
    2. Second step.
  MARKDOWN
  nested_blocks = markdown_semantic_blocks(nested_steps)
  unless nested_blocks.map { |block| [block[:kind], block[:number], block[:text]] } == [
    [:list_item, 1, "First wrapped step."],
    [:list_item, nil, "Nested wrapped check."],
    [:list_item, 2, "Second step."]
  ]
    warn "docs links nested semantic-block self-test failed"
    exit 1
  end
  operator_documents = operator_retirement_documents(ROOT)
  retirement_documents = operator_documents.filter_map do |relative_path, document|
    label = OPERATOR_RETIREMENT_CONTRACT_LABELS[relative_path]
    [label, document] if label
  end.to_h
  canonical_failures = operator_retirement_contract_violations(ROOT)
  unless canonical_failures.empty?
    warn "docs links canonical retirement contract self-test failed: #{canonical_failures.inspect}"
    exit 1
  end

  structural_gap_failures = []
  beginner_guide = ROOT.join("docs/getting-started.md").read
  unless beginner_guide.match?(/eight active services.*tinyMediaManager.*retirement role/im)
    structural_gap_failures << "stale beginner guide service count"
  end

  readme = retirement_documents.fetch("README")
  standalone_fence_mutations = [
    "docker start tinymediamanager",
    "docker start tinyMediaManager&apos;s retired service"
  ].map do |command|
    "#{readme}\n```sh\n#{command}\n```\n"
  end
  accepted_standalone_fence = standalone_fence_mutations.any? do |mutation|
    retirement_contract_violations("README", mutation).empty?
  end
  if accepted_standalone_fence
    structural_gap_failures << "standalone fenced tinyMediaManager command accepted"
  end
  hidden_fence = <<~MARKDOWN
    #{readme}
    <!--
    ```sh
    docker start tinymediamanager
    ```
    -->
  MARKDOWN
  unless retirement_contract_violations("README", hidden_fence).empty?
    structural_gap_failures << "HTML-commented fenced command treated as visible"
  end

  separate_block_mutations = ["Start it now.", "Start the retired service now."].map do |instruction|
    readme.sub("\n## Testing", "\n#{instruction}\n\n## Testing")
  end
  accepted_separate_block = separate_block_mutations.any? do |mutation|
    retirement_contract_violations("README", mutation).empty?
  end
  if accepted_separate_block
    structural_gap_failures << "separate retirement instruction block accepted"
  end

  numeric_entity_mutation = "#{readme}\nRun tinyMedia&#77;anager now.\n"
  if retirement_contract_violations("README", numeric_entity_mutation).empty?
    structural_gap_failures << "numeric HTML entity tinyMediaManager mention accepted"
  end
  mac_entity_variant = retirement_documents.fetch("Mac guide").sub("sandbox's", "sandbox&apos;s")
  unless retirement_contract_violations("Mac guide", mac_entity_variant).empty?
    structural_gap_failures << "equivalent named HTML entity rejected"
  end

  Dir.mktmpdir("retirement-operator-docs") do |directory|
    operator_root = Pathname.new(directory)
    operator_root.join("docs").mkpath
    future_guide = operator_root.join("docs/getting-started-future.md")
    future_guide.write("# Future guide\n\nRun tinyMedia&#77;anager now.\n")
    discovered = operator_retirement_documents(operator_root)
    structural_gap_failures << "future getting-started guide omitted" unless
      discovered.key?("docs/getting-started-future.md")
    structural_gap_failures << "future guide lacks explicit-contract failure" if
      operator_retirement_contract_violations(operator_root).empty?
  end

  unless structural_gap_failures.empty?
    warn "docs links retirement structural gaps: #{structural_gap_failures.inspect}"
    exit 1
  end

  # Every historical false-negative is rejected by placement and exact block
  # shape, not by trying to infer its grammar. Test both a new block and prose
  # appended to an otherwise approved block.
  unsafe_instructions = [
    "Run tinyMediaManager now.",
    "Deploy tinyMediaManager.",
    "Enable tinyMediaManager.",
    "Bring up tinyMediaManager.",
    "Confirm tinyMediaManager is running.",
    "Authenticate to tinyMediaManager.",
    "Access tinyMediaManager.",
    "Do not delete media; start tinyMediaManager.",
    "Do not delete media and then start tinyMediaManager.",
    "For tinyMediaManager, enable the service.",
    "tinyMediaManager should be deployed temporarily.",
    "Start tinyMediaManager.",
    "tinyMediaManager can run now.",
    "For tinyMediaManager, open its UI.",
    "For tinyMediaManager, authenticate to it.",
    "For tinyMediaManager, scan its library.",
    "tinyMediaManager should start now.",
    "tinyMediaManager should run now.",
    "Deploying tinyMediaManager is recommended.",
    "Start tinyMediaManager before opening Jellyfin.",
    "Open tinyMediaManager before Jellyfin.",
    "Do not delete media, start tinyMediaManager.",
    "Do not delete media and start tinyMediaManager."
  ]
  missed_new_blocks = unsafe_instructions.select do |instruction|
    retirement_contract_violations("README", "#{readme}\n#{instruction}\n").empty?
  end
  approved_block_ending = "fresh production NAS installation."
  missed_appended_prose = unsafe_instructions.select do |instruction|
    mutation = readme.sub(approved_block_ending, "#{approved_block_ending} #{instruction}")
    retirement_contract_violations("README", mutation).empty?
  end
  unless missed_new_blocks.empty? && missed_appended_prose.empty?
    warn "docs links structural retirement mutation self-test failed"
    warn "new blocks accepted: #{missed_new_blocks.inspect}" unless missed_new_blocks.empty?
    warn "appended prose accepted: #{missed_appended_prose.inspect}" unless missed_appended_prose.empty?
    exit 1
  end
  heading_mutation = "#{readme}\n## Run tinyMediaManager now\n"
  if retirement_contract_violations("README", heading_mutation).empty?
    warn "docs links retirement heading-placement self-test failed"
    exit 1
  end

  mac_guide = retirement_documents.fetch("Mac guide")
  safe_current_phrases = [
    "retired tinyMediaManager container is absent",
    "Audiobookshelf, Jellyfin, and Komga: sign in",
    "Do not open its UI or API"
  ]
  mac_guide_prose = normalized_prose(mac_guide)
  unless safe_current_phrases.all? { |phrase| mac_guide_prose.include?(phrase) }
    warn "docs links canonical negative-state/Jellyfin-action self-test failed"
    exit 1
  end

  nas_guide = retirement_documents.fetch("NAS guide")
  rollback_mutations = [
    nas_guide.sub(
      "Use this mutual-exclusion procedure:",
      "Use this mutual-exclusion procedure: Run tinyMediaManager without the writer checks."
    ),
    nas_guide.sub(
      "\nThe temporary branch and commit are rollback evidence",
      "\nRun tinyMediaManager without review.\n\nThe temporary branch and commit are rollback evidence"
    )
  ]
  if rollback_mutations.any? { |mutation| retirement_contract_violations("NAS guide", mutation).empty? }
    warn "docs links rollback block contract mutation self-test failed"
    exit 1
  end
  Dir.mktmpdir("docs-links-test") do |directory|
    root = Pathname.new(directory)
    docs = root.join("docs")
    docs.mkpath
    docs.join("valid file.md").write("ok\n")
    docs.join("plus+file.md").write("ok\n")
    docs.join("balanced(name).md").write("ok\n")
    docs.join("a(b).md").write("ok\n")
    docs.join("a\\(b\\).md").write("ok\n")
    docs.join("subdir").mkpath
    outside = root.parent.join("docs-links-outside-#{Process.pid}")
    outside.write("outside\n")
    docs.join("escape.md").make_symlink(outside)
    source = docs.join("sample.md")
    source.write(<<~MARKDOWN)
      [file](valid%20file.md)
      prose < unmatched [after-prose](after-prose-missing.md)
      [title-paren](title-paren-missing.md "title (")
      [single-title](single-title-missing.md 'author"s (title')
      [not-a-link] (not-a-link-missing.md)
      <!-- [comment](comment-missing.md) -->
      <!-- ` [comment-inline](comment-inline-missing.md) `
      ```
      [comment-fence](comment-fence-missing.md)
      ``` -->
      <!-- multiline
      [multiline-comment](multiline-comment-missing.md)
      -->
      \\<!-- [escaped-comment](escaped-comment-missing.md) -->
      [plus](plus+file.md)
      [balanced](balanced(name).md)
      [escaped destination](a\(b\).md)
      [percent backslash](a%5C(b%5C).md)
      [titled](<valid%20file.md> "title")
      [directory](subdir/)
      [fragment](valid%20file.md#section)
      [external](https://example.test/missing)
      [missing](missing.md)
      [ordinary](ordinary-missing.md)
      [nested [label]](nested-missing.md)
      [angle-broken](<missing).md>)
      ` [inline](inline-missing.md) `
      ```markdown
      [backtick](backtick-missing.md)
      ```not-a-close
      [inside](inside-missing.md)
      ```
      ~~~markdown
      [tilde](tilde-missing.md)
      ~~~
          ```markdown
          [indented](indented-missing.md)
          ```
      \\`[escaped](escaped-missing.md)\\`
      \`[ordinary escaped](ordinary-escaped-missing.md)\`
      \\[one-slash](one-slash-missing.md)
      \\\\[two-slash](two-slash-missing.md)
      ```bad`info
      [invalid-info](invalid-info-missing.md)
      ```not-a-close
      > ```markdown
      > [blockquote](blockquote-missing.md)
      > ```
      >  ```markdown
      >  [blockquote-indented](blockquote-indented-missing.md)
      >  ```
      >    ```markdown
      >    [blockquote-four](blockquote-four-missing.md)
      >    ```
      -  ```markdown
         [list-fence](list-fence-missing.md)
         ```
      prefix ``` [unmatched](unmatched-missing.md)
      1234567890. ```ruby
      [ten-digit](ten-digit-missing.md)
      ` [later masked](later-masked-missing.md) `
      ` <!-- [inline-comment](inline-comment-missing.md) `
      [after-inline-comment](after-inline-comment-missing.md)
      [after unmatched](after-unmatched-missing.md)
      [post-unmatched](post-unmatched-missing.md)
      [post-malformed](post%ZZ.md)
      ``
      [multiline](multiline-missing.md)
      ``
      `` [unequal](unequal-missing.md) `
      [traversal](../../etc/passwd)
      [malformed](bad%ZZ.md)
      [symlink](escape.md)
    MARKDOWN
    source.open("a") { |file| file.write("[control](bad\e[31m\x01.md)\n") }
    unclosed = docs.join("unclosed.md")
    unclosed.write("```markdown\n[hidden](hidden-missing.md)\n")
    bad_source = docs.join("bad\e-source.md")
    bad_source.write("[source-control](missing-source.md)\n")
    bad_unclosed = docs.join("bad\e-unclosed.md")
    bad_unclosed.write("```markdown\n[hidden](hidden-missing.md)\n")
    unclosed_comment = docs.join("unclosed-comment.md")
    unclosed_comment.write("<!-- `\n[unclosed-comment](unclosed-comment-missing.md)\n```\n")
    unclosed_container = docs.join("unclosed-container.md")
    unclosed_container.write(">  ```markdown\n>  [hidden](hidden-container-missing.md)\n")
    unclosed_four = docs.join("unclosed-four.md")
    unclosed_four.write(">    ```markdown\n>    [hidden](hidden-four-missing.md)\n")
    failures = check_sources(root, [source])
    expected = ["after-prose-missing.md", "title-paren-missing.md", "single-title-missing.md", "escaped-comment-missing.md", "missing.md", "ordinary-missing.md", "nested-missing.md", "<missing).md>", "indented-missing.md", "escaped-missing.md", "two-slash-missing.md", "invalid-info-missing.md", "ten-digit-missing.md", "after-inline-comment-missing.md", "after-unmatched-missing.md", "post-unmatched-missing.md", "unequal-missing.md"]
    categories = [
      "malformed local link post%ZZ.md",
      "broken local link ../../etc/passwd",
      "malformed local link bad%ZZ.md",
      "broken local link escape.md",
      "broken local link bad?[31m?.md"
    ]
    unless expected.all? { |target| failures.any? { |failure| failure.include?("link #{target}") } } && categories.all? { |message| failures.any? { |failure| failure.include?(message) } } && failures.length == expected.length + categories.length && failures.none? { |failure| failure.match?(/[[:cntrl:]]/) }
      warn "docs links self-test failed: #{failures.inspect}"
      exit 1
    end
    boundary = docs.join("boundary.md")
    boundary.write("prefix `\n```markdown\n`[inside-fence](inside-fence-missing.md) `\n```\n[after-fence](after-fence-boundary-missing.md)\n")
    boundary_failures = check_sources(root, [boundary])
    unless boundary_failures == ["docs/boundary.md: broken local link after-fence-boundary-missing.md"]
      warn "docs links fence-boundary self-test failed: #{boundary_failures.inspect}"
      exit 1
    end
    comment_boundary = docs.join("comment-boundary.md")
    comment_boundary.write("prefix `\n<!-- ` [inside-comment](inside-comment-missing.md) ` -->\n[after-comment](after-comment-boundary-missing.md)\n")
    comment_boundary_failures = check_sources(root, [comment_boundary])
    unless comment_boundary_failures == ["docs/comment-boundary.md: broken local link after-comment-boundary-missing.md"]
      warn "docs links comment-boundary self-test failed: #{comment_boundary_failures.inspect}"
      exit 1
    end
    multiline_inline = docs.join("multiline-inline.md")
    multiline_inline.write("`code\n[hidden](multiline-inline-hidden.md)\n`\n[after](multiline-inline-after.md)\n")
    multiline_inline_failures = check_sources(root, [multiline_inline])
    unless multiline_inline_failures == ["docs/multiline-inline.md: broken local link multiline-inline-after.md"]
      warn "docs links multiline-inline self-test failed: #{multiline_inline_failures.inspect}"
      exit 1
    end
    multiline_suffix = docs.join("multiline-suffix.md")
    multiline_suffix.write("`\n[hidden](multiline-suffix-hidden.md)\ncode`\n[after](multiline-suffix-after.md)\n")
    multiline_suffix_failures = check_sources(root, [multiline_suffix])
    unless multiline_suffix_failures == ["docs/multiline-suffix.md: broken local link multiline-suffix-after.md"]
      warn "docs links multiline-suffix self-test failed: #{multiline_suffix_failures.inspect}"
      exit 1
    end
    prefixed_multiline = docs.join("prefixed-multiline.md")
    prefixed_multiline.write("prefix `code\n[hidden](prefixed-multiline-hidden.md)\nend`\n[after](prefixed-multiline-after.md)\n")
    prefixed_multiline_failures = check_sources(root, [prefixed_multiline])
    unless prefixed_multiline_failures == ["docs/prefixed-multiline.md: broken local link prefixed-multiline-after.md"]
      warn "docs links prefixed-multiline self-test failed: #{prefixed_multiline_failures.inspect}"
      exit 1
    end
    cross_line_close = docs.join("cross-line-close.md")
    cross_line_close.write("`open\n` [must-check](cross-line-must-check.md) `\n")
    cross_line_close_failures = check_sources(root, [cross_line_close])
    unless cross_line_close_failures == ["docs/cross-line-close.md: broken local link cross-line-must-check.md"]
      warn "docs links cross-line-close self-test failed: #{cross_line_close_failures.inspect}"
      exit 1
    end
    paragraph_boundary = docs.join("paragraph-boundary.md")
    paragraph_boundary.write("prefix `unclosed\n\n[ordinary](paragraph-boundary-missing.md) `\n")
    paragraph_boundary_failures = check_sources(root, [paragraph_boundary])
    unless paragraph_boundary_failures == ["docs/paragraph-boundary.md: broken local link paragraph-boundary-missing.md"]
      warn "docs links paragraph-boundary self-test failed: #{paragraph_boundary_failures.inspect}"
      exit 1
    end
    {
      "heading-boundary.md" => "prefix `unclosed\n# [ordinary](heading-boundary-missing.md) `\n",
      "setext-boundary.md" => "prefix `unclosed\n===\n[ordinary](setext-boundary-missing.md) `\n",
      "setext-single-boundary.md" => "prefix `unclosed\n=\n[ordinary](setext-single-boundary-missing.md) `\n",
      "setext-space-boundary.md" => "prefix `unclosed\n=   \n[ordinary](setext-space-boundary-missing.md) `\n",
      "setext-dash-boundary.md" => "prefix `unclosed\n-\n[ordinary](setext-dash-boundary-missing.md) `\n",
      "thematic-boundary.md" => "prefix `unclosed\n---\n[ordinary](thematic-boundary-missing.md) `\n",
      "quote-boundary.md" => "prefix `unclosed\n> [ordinary](quote-boundary-missing.md) `\n",
      "list-boundary.md" => "prefix `unclosed\n- [ordinary](list-boundary-missing.md) `\n"
    }.each do |name, body|
      boundary_source = docs.join(name)
      boundary_source.write(body)
      expected_target = name.sub(".md", "-missing.md")
      boundary_result = check_sources(root, [boundary_source])
      expected_failure = "docs/#{name}: broken local link #{expected_target}"
      unless boundary_result == [expected_failure]
        warn "docs links block-boundary self-test failed: #{name}: #{boundary_result.inspect}"
        exit 1
      end
    end
    quoted_comment = docs.join("quoted-comment.md")
    quoted_comment.write("> prefix `unclosed\n> <!--\n> [hidden](quoted-comment-hidden.md)\n> -->\n> [ordinary](quoted-comment-after.md) `\n")
    quoted_comment_failures = check_sources(root, [quoted_comment])
    unless quoted_comment_failures == ["docs/quoted-comment.md: broken local link quoted-comment-after.md"]
      warn "docs links quoted-comment self-test failed: #{quoted_comment_failures.inspect}"
      exit 1
    end
    nested_quote = docs.join("nested-quote.md")
    nested_quote.write("> prefix `unclosed\n>  > [ordinary](nested-quote-missing.md) `\n")
    nested_quote_failures = check_sources(root, [nested_quote])
    unless nested_quote_failures == ["docs/nested-quote.md: broken local link nested-quote-missing.md"]
      warn "docs links nested-quote self-test failed: #{nested_quote_failures.inspect}"
      exit 1
    end
    nested_quote_comment = docs.join("nested-quote-comment.md")
    nested_quote_comment.write("> > prefix `unclosed\n>  > <!--\n>  > [hidden](nested-quote-comment-hidden.md)\n>  > -->\n>  > [ordinary](nested-quote-comment-after.md) `\n")
    nested_quote_comment_failures = check_sources(root, [nested_quote_comment])
    unless nested_quote_comment_failures == ["docs/nested-quote-comment.md: broken local link nested-quote-comment-after.md"]
      warn "docs links nested-quote-comment self-test failed: #{nested_quote_comment_failures.inspect}"
      exit 1
    end
    mixed_setext = docs.join("mixed-setext.md")
    mixed_setext.write("prefix `code\n=-\n[hidden](mixed-setext-hidden.md) `\n[after](mixed-setext-after.md)\n")
    mixed_setext_failures = check_sources(root, [mixed_setext])
    unless mixed_setext_failures == ["docs/mixed-setext.md: broken local link mixed-setext-after.md"]
      warn "docs links mixed-setext self-test failed: #{mixed_setext_failures.inspect}"
      exit 1
    end
    indented_quote = docs.join("indented-quote.md")
    indented_quote.write("prefix `code\n    > [hidden](indented-quote-hidden.md) `\n[after](indented-quote-after.md)\n")
    indented_quote_failures = check_sources(root, [indented_quote])
    unless indented_quote_failures == ["docs/indented-quote.md: broken local link indented-quote-after.md"]
      warn "docs links indented-quote self-test failed: #{indented_quote_failures.inspect}"
      exit 1
    end
    indented_comment = docs.join("indented-comment.md")
    indented_comment.write("prefix `code\n    <!-- [hidden](indented-comment-hidden.md)\nend`\n[after](indented-comment-after.md)\n")
    indented_comment_failures = check_sources(root, [indented_comment])
    unless indented_comment_failures == ["docs/indented-comment.md: broken local link indented-comment-after.md"]
      warn "docs links indented-comment self-test failed: #{indented_comment_failures.inspect}"
      exit 1
    end
    list_continuation = docs.join("list-continuation.md")
    list_continuation.write("- prefix `code\n  [hidden](list-continuation-hidden.md)\n  end`\n[after](list-continuation-after.md)\n")
    list_continuation_failures = check_sources(root, [list_continuation])
    unless list_continuation_failures == ["docs/list-continuation.md: broken local link list-continuation-after.md"]
      warn "docs links list-continuation self-test failed: #{list_continuation_failures.inspect}"
      exit 1
    end
    lazy_quote = docs.join("lazy-quote.md")
    lazy_quote.write("> prefix `code\n[hidden](lazy-quote-hidden.md)\nend`\n[after](lazy-quote-after.md)\n")
    lazy_quote_failures = check_sources(root, [lazy_quote])
    unless lazy_quote_failures == ["docs/lazy-quote.md: broken local link lazy-quote-after.md"]
      warn "docs links lazy-quote self-test failed: #{lazy_quote_failures.inspect}"
      exit 1
    end
    ordered_noninterrupt = docs.join("ordered-noninterrupt.md")
    ordered_noninterrupt.write("prefix `code\n2. [hidden](ordered-noninterrupt-hidden.md) `\n[after](ordered-noninterrupt-after.md)\n")
    ordered_noninterrupt_failures = check_sources(root, [ordered_noninterrupt])
    unless ordered_noninterrupt_failures == ["docs/ordered-noninterrupt.md: broken local link ordered-noninterrupt-after.md"]
      warn "docs links ordered-noninterrupt self-test failed: #{ordered_noninterrupt_failures.inspect}"
      exit 1
    end
    quoted_ordered_noninterrupt = docs.join("quoted-ordered-noninterrupt.md")
    quoted_ordered_noninterrupt.write("> prefix `code\n> 2. [hidden](quoted-ordered-hidden.md) `\n[after](quoted-ordered-after.md)\n")
    quoted_ordered_failures = check_sources(root, [quoted_ordered_noninterrupt])
    unless quoted_ordered_failures == ["docs/quoted-ordered-noninterrupt.md: broken local link quoted-ordered-after.md"]
      warn "docs links quoted-ordered self-test failed: #{quoted_ordered_failures.inspect}"
      exit 1
    end
    {
      "ordered" => "  2. [hidden](list-nested-ordered-hidden.md) `\n",
      "empty-star" => "  * \n  [hidden](list-nested-empty-star-hidden.md) `\n"
    }.each do |label, continuation|
      list_nested_marker = docs.join("list-nested-#{label}.md")
      list_nested_marker.write("- prefix `code\n#{continuation}[after](list-nested-#{label}-after.md)\n")
      list_nested_failures = check_sources(root, [list_nested_marker])
      expected_nested_failure = "docs/list-nested-#{label}.md: broken local link list-nested-#{label}-after.md"
      unless list_nested_failures == [expected_nested_failure]
        warn "docs links list-nested-marker self-test failed: #{label}: #{list_nested_failures.inspect}"
        exit 1
      end
    end
    {"star" => "* ", "plus" => "+ ", "ordered" => "1. "}.each do |label, marker|
      empty_item = docs.join("empty-#{label}-item.md")
      empty_item.write("prefix `code\n#{marker}\n[hidden](empty-#{label}-hidden.md) `\n[after](empty-#{label}-after.md)\n")
      empty_item_failures = check_sources(root, [empty_item])
      expected_empty_failure = "docs/empty-#{label}-item.md: broken local link empty-#{label}-after.md"
      unless empty_item_failures == [expected_empty_failure]
        warn "docs links empty-list-item self-test failed: #{label}: #{empty_item_failures.inspect}"
        exit 1
      end
    end
    multiline_comment_code = docs.join("multiline-comment-code.md")
    multiline_comment_code.write("`start\ninside <!-- [hidden](multiline-comment-code-hidden.md)\nend`\n[after](multiline-comment-code-after.md)\n")
    multiline_comment_code_failures = check_sources(root, [multiline_comment_code])
    unless multiline_comment_code_failures == ["docs/multiline-comment-code.md: broken local link multiline-comment-code-after.md"]
      warn "docs links multiline-comment-code self-test failed: #{multiline_comment_code_failures.inspect}"
      exit 1
    end
    nested_delimiters = docs.join("nested-delimiters.md")
    nested_delimiters.write("` x `` y ` `` [ordinary](nested-delimiters-missing.md)\n")
    nested_delimiter_failures = check_sources(root, [nested_delimiters])
    unless nested_delimiter_failures == ["docs/nested-delimiters.md: broken local link nested-delimiters-missing.md"]
      warn "docs links nested-delimiters self-test failed: #{nested_delimiter_failures.inspect}"
      exit 1
    end
    fence_comment = docs.join("fence-comment.md")
    fence_comment.write("```markdown\n<!--\n[fenced](fence-comment-hidden.md)\n```\n` [inline](post-fence-inline-hidden.md) `\n[after](post-fence-comment.md)\n")
    fence_comment_failures = check_sources(root, [fence_comment])
    unless fence_comment_failures == ["docs/fence-comment.md: broken local link post-fence-comment.md"]
      warn "docs links fence-comment self-test failed: #{fence_comment_failures.inspect}"
      exit 1
    end
    unclosed_failures = check_sources(root, [unclosed])
    unless unclosed_failures == ["docs/unclosed.md: malformed documentation (unclosed code fence)"]
      warn "docs links unclosed-fence self-test failed: #{unclosed_failures.inspect}"
      exit 1
    end
    source_failures = check_sources(root, [bad_source])
    unless source_failures.length == 1 && source_failures.none? { |failure| failure.match?(/[[:cntrl:]]/) }
      warn "docs links source-name self-test failed: #{source_failures.inspect}"
      exit 1
    end
    bad_unclosed_failures = check_sources(root, [bad_unclosed])
    unless bad_unclosed_failures == ["docs/bad?-unclosed.md: malformed documentation (unclosed code fence)"]
      warn "docs links sanitized-unclosed self-test failed: #{bad_unclosed_failures.inspect}"
      exit 1
    end
    comment_failures = check_sources(root, [unclosed_comment])
    unless comment_failures.empty?
      warn "docs links unclosed-comment self-test failed: #{comment_failures.inspect}"
      exit 1
    end
    container_failures = check_sources(root, [unclosed_container])
    unless container_failures == ["docs/unclosed-container.md: malformed documentation (unclosed code fence)"]
      warn "docs links container-fence self-test failed: #{container_failures.inspect}"
      exit 1
    end
    four_failures = check_sources(root, [unclosed_four])
    unless four_failures == ["docs/unclosed-four.md: malformed documentation (unclosed code fence)"]
      warn "docs links four-space blockquote self-test failed: #{four_failures.inspect}"
      exit 1
    end
  ensure
    outside&.delete if outside&.exist?
  end
  puts "docs links: self-test passed"
end

if ARGV == ["--self-test"]
  self_test
else
  failures = check_sources(ROOT, SOURCES)
  readme_retirement = normalized_prose(markdown_section(
    ROOT.join("README.md").read,
    "## tinyMediaManager retirement checkpoint"
  ))
  nas_retirement = normalized_prose(markdown_section(
    ROOT.join("docs/getting-started-nas.md").read,
    "## tinyMediaManager retirement checkpoint"
  ))
  {
    "README retirement checkpoint" => readme_retirement,
    "NAS retirement checkpoint" => nas_retirement
  }.each do |label, section|
    failures << "#{label} must say tinyMediaManager is retired and must remain stopped" unless
      section.match?(/tinyMediaManager.*retired.*must remain stopped/im)
    failures << "#{label} must preserve tinyMediaManager bind-mounted state through the transitional release" unless
      section.match?(/bind-mounted state.*preserved.*transitional release/im)
    failures << "#{label} must say Movies and Series are neither deleted nor moved by retirement" unless
      section.match?(/Movies.*Series.*neither deleted nor moved.*retirement/im)
    failures << "#{label} must retain the tinyMediaManager vault key until the cleanup release" unless
      section.match?(/vault_tinymediamanager_password.*remains.*cleanup release/im)
  end

  operator_documents = operator_retirement_documents(ROOT)
  retirement_documents = operator_documents.filter_map do |relative_path, document|
    label = OPERATOR_RETIREMENT_CONTRACT_LABELS[relative_path]
    [label, document] if label
  end.to_h
  failures.concat(operator_retirement_contract_violations(ROOT))
  retirement_documents.each do |label, document|
    prose = normalized_prose(document)
    failures << "#{label} must identify tinyMediaManager as retired and stopped" unless
      prose.match?(/tinyMediaManager.*retired.*(?:must remain|remains) stopped/im)
    failures << "#{label} must identify tinyMediaManager bind-mounted state as preserved" unless
      prose.match?(/tinyMediaManager.*bind-mounted state.*preserv/im)
  end

  mac_guide = normalized_prose(ROOT.join("docs/getting-started-mac.md").read)
  failures << "Mac guide must describe eight active services plus the tinyMediaManager retirement proof" unless
    mac_guide.match?(/eight active services.*tinyMediaManager retirement proof/im)
  failures << "Mac guide must not claim all nine services run during manual review" if
    mac_guide.match?(/all nine.*services.*running/im)

  manual_items = normalized_checklist_items(ROOT.join("tests/mac/manual-review.md").read)
  retirement_item = manual_items.find { |item| item.match?(/tinyMediaManager/i) }
  failures << "Mac manual review must structurally require the retired container to be absent" unless
    retirement_item&.match?(/retired.*container.*absent/i)
  failures << "Mac manual review must structurally require preserved bind-mounted state" unless
    retirement_item&.match?(/bind-mounted state.*preserv/i)

  failures << "NAS retirement checkpoint must document rollback before Radarr and Sonarr deployment" unless
    nas_retirement.match?(/Before Radarr or Sonarr is deployed.*simpler rollback.*converge/im)
  failures << "NAS retirement checkpoint must stop arr writers before post-write rollback" unless
    nas_retirement.match?(/(?:Radarr|Sonarr).*written.*Movies or Series.*stop both Radarr and Sonarr.*one media writer at a time/im)
  failures << "NAS retirement checkpoint must defer permanent cleanup until the NAS checkpoint" unless
    nas_retirement.match?(/Permanent cleanup.*waits.*NAS.*verif/im)
  failures << "NAS retirement checkpoint must retain Open Subtitles until Bazarr is proven" unless
    nas_retirement.match?(/Open Subtitles remains.*until Bazarr is\s+proven/im)

  required_rollback_guidance = {
    /ca15db3/ => "name the reviewed pre-retirement source revision",
    /restore only.*tinyMediaManager role and Compose/im =>
      "restore only the required tinyMediaManager role and Compose files",
    /edit only.*tinyMediaManager.*storage declaration/im =>
      "limit the storage change to the tinyMediaManager declaration",
    /temporary.*(?:branch|commit)/i => "use a reviewed temporary rollback branch or commit",
    /(?:do not|must not).*entire platform.*(?:rollback|revision)/im =>
      "forbid blindly rolling back the entire platform",
    /(?:pause|disable).*five-minute.*auto-deploy/im =>
      "pause the five-minute production auto-deployer",
    /stop.*Radarr.*Sonarr.*verify.*containers.*absent/im =>
      "stop Radarr and Sonarr and verify both containers absent",
    /keep.*Radarr.*Sonarr.*stopped.*entire.*tinyMediaManager.*run/im =>
      "keep arr writers stopped for the entire tinyMediaManager run",
    /restore.*intended current.*revision.*converge.*re-enable.*auto-deploy/im =>
      "restore the intended current platform before re-enabling deployment automation",
    /restore.*intended current platform revision.*converge.*retirement role.*stop.*remove.*without volumes/im =>
      "use the intended current retirement role for bounded container removal",
    /verify.*tinyMediaManager.*container.*absent.*only then.*restart.*Radarr.*Sonarr.*re-enable.*auto-deploy/im =>
      "verify retirement before restarting arr writers and deployment automation"
  }
  required_rollback_guidance.each do |pattern, requirement|
    failures << "NAS retirement checkpoint must #{requirement}" unless nas_retirement.match?(pattern)
  end

  failures << "NAS guide must scope platform_verify_tinymediamanager to container and state-root safety" unless
    nas_retirement.match?(/platform_verify_tinymediamanager.*container absence.*state root.*exists.*directory.*not a symlink/im)
  failures << "NAS guide must say retirement verification does not inspect state contents" unless
    nas_retirement.match?(/does not.*(?:inspect|verify).*state.*contents/im)
  failures << "NAS guide must require a read-only prior inventory or snapshot comparison" unless
    nas_retirement.match?(/read-only.*(?:prior inventory|snapshot).*representative.*(?:expected files|backup)/im)
  failures << "NAS guide must prohibit recursive hashing of preserved state" unless
    nas_retirement.match?(/do not recursively hash.*state/im)

  {
    "README retirement checkpoint" => readme_retirement,
    "NAS retirement checkpoint" => nas_retirement
  }.each do |label, section|
    failures << "#{label} must limit cleanup to repository declarations" unless
      section.match?(/cleanup release.*repository declarations only/im)
    failures << "#{label} must prohibit deleting the tinyMediaManager data root or contents" unless
      section.match?(%r{must not delete.*\{\{ nas_docker_root \}\}/tinymediamanager/data.*contents}im)
    failures << "#{label} must require a separate backed-up operator decision for later data deletion" unless
      section.match?(/later data deletion.*separate.*backed-up.*operator decision.*not part of.*retirement/im)
  end

  jellyfin_compose = ROOT.join("services/jellyfin/compose.yml").read
  failures << "Jellyfin media-mount comment must assign adjacent metadata to neutral media writers" unless
    jellyfin_compose.match?(/media writers own adjacent metadata.*Jellyfin remains read-only/im)
  failures << "Jellyfin media-mount comment must not assign metadata ownership to tinyMediaManager" if
    jellyfin_compose.match?(/tinyMediaManager owns metadata/i)
  jellyfin_defaults = ROOT.join("roles/jellyfin/defaults/main.yml").read
  failures << "Jellyfin defaults comments must use a neutral external-writer metadata rationale" unless
    jellyfin_defaults.match?(/preserved adjacent metadata.*external media writers/im)
  failures << "Jellyfin defaults comments must not assign metadata ownership to tinyMediaManager" if
    jellyfin_defaults.match?(/tinyMediaManager.*(?:own|fetch|write).*metadata/i)
  if failures.empty?
    puts "docs links: all local targets exist"
  else
    warn failures.join("\n")
    exit 1
  end
end
