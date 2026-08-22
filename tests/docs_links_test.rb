#!/usr/bin/env ruby
# frozen_string_literal: true

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

def mask_block_contexts(text)
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
      masked = line.gsub(/[^\n]/, " ")
      offset += line.length
      next masked
    end

    unless comment
      _, marker, = fence_parts(line)
      if marker
        fence = [marker[0], marker.length]
        masked = line.gsub(/[^\n]/, " ")
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
  readme_retirement = markdown_section(
    mask_block_contexts(ROOT.join("README.md").read),
    "## tinyMediaManager retirement checkpoint"
  )
  nas_retirement = markdown_section(
    mask_block_contexts(ROOT.join("docs/getting-started-nas.md").read),
    "## tinyMediaManager retirement checkpoint"
  )
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

  failures << "NAS retirement checkpoint must document rollback before Radarr and Sonarr deployment" unless
    nas_retirement.match?(/Before Radarr or Sonarr is deployed.*restore.*role and Compose definitions.*reconverge/im)
  failures << "NAS retirement checkpoint must stop arr writers before post-write rollback" unless
    nas_retirement.match?(/After.*arr.*written.*Movies or Series.*first stop.*arr writers.*before.*restor.*reconverg.*tinyMediaManager.*concurrent writers/im)
  failures << "NAS retirement checkpoint must defer permanent cleanup until the NAS checkpoint" unless
    nas_retirement.match?(/Permanent cleanup.*waits.*NAS.*verif/im)
  failures << "NAS retirement checkpoint must retain Open Subtitles until Bazarr is proven" unless
    nas_retirement.match?(/Open Subtitles remains.*until Bazarr is\s+proven/im)

  manual_review = mask_block_contexts(ROOT.join("tests/mac/manual-review.md").read)
  failures << "Mac manual review must treat tinyMediaManager as retired and stopped" unless
    manual_review.match?(/tinyMediaManager.*retired.*remains? stopped/im)
  failures << "Mac manual review must not request active tinyMediaManager UI, API, scan, or metadata-write checks" if
    manual_review.match?(/tinyMediaManager.*(?:UI|API|scan|edit metadata|write metadata)/i)

  jellyfin_compose = ROOT.join("services/jellyfin/compose.yml").read
  failures << "Jellyfin media-mount comment must assign adjacent metadata to neutral media writers" unless
    jellyfin_compose.match?(/media writers own adjacent metadata.*Jellyfin remains read-only/im)
  failures << "Jellyfin media-mount comment must not assign metadata ownership to tinyMediaManager" if
    jellyfin_compose.match?(/tinyMediaManager owns metadata/i)
  if failures.empty?
    puts "docs links: all local targets exist"
  else
    warn failures.join("\n")
    exit 1
  end
end
