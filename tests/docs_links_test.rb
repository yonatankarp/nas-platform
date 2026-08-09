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
    open += 1 while open < text.length && text[open].match?(/\s/)
    if text[open] == "("
      close = matching_delimiter(text, open, "(", ")")
      links << text[(open + 1)...close] if close
      index = close ? close + 1 : open + 1
    else
      index += 1
    end
  end
  links
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
  index = 0
  while (start = result.index("<!--", index))
    finish = result.index("-->", start + 4)
    finish = finish ? finish + 3 : result.length
    result[start...finish] = result[start...finish].gsub(/[^\n]/, " ")
    index = finish
  end
  result
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
    text, unclosed_fence = mask_code(source.read)
    failures << "#{source_name}: malformed documentation (unclosed code fence)" if unclosed_fence
    text = mask_html_comments(mask_inline_code(text))
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
  unless markdown_link_bodies("[" * 50_000).empty?
    warn "docs links hostile-unmatched self-test failed"
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
      <!-- [comment](comment-missing.md) -->
      <!-- multiline
      [multiline-comment](multiline-comment-missing.md)
      -->
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
      [after unmatched](after-unmatched-missing.md)
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
    unclosed_comment.write("<!-- [unclosed-comment](unclosed-comment-missing.md)\n")
    unclosed_container = docs.join("unclosed-container.md")
    unclosed_container.write(">  ```markdown\n>  [hidden](hidden-container-missing.md)\n")
    unclosed_four = docs.join("unclosed-four.md")
    unclosed_four.write(">    ```markdown\n>    [hidden](hidden-four-missing.md)\n")
    failures = check_sources(root, [source])
    expected = ["missing.md", "ordinary-missing.md", "nested-missing.md", "<missing).md>", "indented-missing.md", "escaped-missing.md", "two-slash-missing.md", "unmatched-missing.md", "after-unmatched-missing.md", "ten-digit-missing.md", "unequal-missing.md", "../../etc/passwd", "bad%ZZ.md", "escape.md"]
    unless expected.all? { |target| failures.any? { |failure| failure.end_with?(target) } } && failures.length == expected.length + 1 && failures.none? { |failure| failure.match?(/[[:cntrl:]]/) }
      warn "docs links self-test failed: #{failures.inspect}"
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
