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

def matching_delimiter(text, start, opening, closing)
  depth = 0
  angle = false
  index = start
  while index < text.length
    if text[index] == "\\"
      index += 2
      next
    end
    angle = true if text[index] == "<" && opening == "("
    angle = false if text[index] == ">" && opening == "("
    depth += 1 if text[index] == opening && !angle
    if text[index] == closing && !angle
      depth -= 1
      return index if depth.zero?
    end
    index += 1
  end
  nil
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

def mask_inline_code(text)
  chars = text.chars
  index = 0
  while index < chars.length
    unless chars[index] == "`"
      index += 1
      next
    end
    run_end = index
    run_end += 1 while run_end < chars.length && chars[run_end] == "`"
    length = run_end - index
    slash_count = 0
    before = index - 1
    while before >= 0 && chars[before] == "\\"
      slash_count += 1
      before -= 1
    end
    if slash_count.odd?
      index = run_end
      next
    end
    line_start = text.rindex("\n", index - 1).to_i + 1
    if text[line_start...index].match?(/\A {4,}\z/) && length >= 3
      index = run_end
      next
    end
    close = run_end
    loop do
      break if close >= chars.length
      if chars[close] == "`"
        candidate_end = close
        candidate_end += 1 while candidate_end < chars.length && chars[candidate_end] == "`"
        break if candidate_end - close == length

        close = candidate_end
      else
        close += 1
      end
    end
    if close >= chars.length
      index = run_end
      next
    end
    (index...close + length).each { |position| chars[position] = " " unless chars[position] == "\n" }
    index = close + length
  end
  chars.join
end

def sanitize(value)
  value.gsub(/[[:cntrl:]]/, "?")
end

def mask_html_comments(text)
  result = text.dup
  code_ranges = inline_partners(text).filter_map do |opening, closing|
    (opening...closing) if opening < closing
  end.sort_by(&:begin)
  range_index = 0
  index = 0
  while (start = result.index("<!--", index))
    range_index += 1 while code_ranges[range_index] && code_ranges[range_index].end <= start
    inside_code = code_ranges[range_index]&.cover?(start)
    if escaped?(result, start) || inside_code
      index = start + 4
      next
    end
    finish = result.index("-->", start + 4)
    finish = finish ? finish + 3 : result.length
    result[start...finish] = result[start...finish].gsub(/[^\n]/, " ")
    index = finish
  end
  result
end

def mask_block_contexts(text)
  protected_ranges = inline_partners(text).filter_map do |opening, closing|
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
      if escaped?(line, start) || protected_ranges[range_index]&.cover?(absolute)
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
        line_prefix = chars[0...index].join
        if run_length >= 3 && line_prefix.match?(/\A {4,}\z/)
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
  cross_line_openings = {}
  offset = 0
  text.lines.each do |line|
    runs = []
    index = 0
    while index < line.length
      unless line[index] == "`"
        index += 1
        next
      end
      finish = index + 1
      finish += 1 while finish < line.length && line[finish] == "`"
      runs << [offset + index, finish - index] unless escaped?(line, index)
      index = finish
    end

    waiting = {}
    runs.each do |position, length|
      if (opening = waiting.delete(length))
        partners[opening] = position
        partners[position] = opening
      else
        waiting[length] = position
      end
    end

    runs.reject { |position,| partners.key?(position) }.each do |position, length|
      before = line[0...(position - offset)]
      if (opening = cross_line_openings[length])
        cross_line_openings.delete(length)
        partners[opening] = position
        partners[position] = opening
      elsif before.strip.empty?
        cross_line_openings[length] = position
      end
    end
    offset += line.length
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
    expected = ["after-prose-missing.md", "title-paren-missing.md", "single-title-missing.md", "escaped-comment-missing.md", "missing.md", "ordinary-missing.md", "nested-missing.md", "<missing).md>", "indented-missing.md", "escaped-missing.md", "two-slash-missing.md", "unmatched-missing.md", "ten-digit-missing.md", "after-inline-comment-missing.md", "after-unmatched-missing.md", "post-unmatched-missing.md", "unequal-missing.md"]
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
  if failures.empty?
    puts "docs links: all local targets exist"
  else
    warn failures.join("\n")
    exit 1
  end
end
