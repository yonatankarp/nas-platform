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
  index = 0
  while index < text.length
    unless text[index] == "[" && !escaped?(text, index)
      index += 1
      next
    end
    label_end = matching_delimiter(text, index, "[", "]")
    unless label_end
      index += 1
      next
    end
    open = label_end + 1
    open += 1 while open < text.length && text[open].match?(/\s/)
    if text[open] == "("
      close = matching_delimiter(text, open, "(", ")")
      links << text[(open + 1)...close] if close
      index = close ? close + 1 : open + 1
    else
      index = label_end + 1
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
  value = value.sub(/\A {0,3}(?:(?:> ?)|(?:[-+*] |\d+[.)] ))*/, "")
  match = value.match(/\A(`{3,}|~{3,})(.*?)(?:\r?\n)?\z/)
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
    line_start = text.rindex("\n", index - 1).to_i + 1
    if text[line_start...index].match?(/\A {4,}\z/) && length >= 3
      index = run_end
      next
    end
    close = run_end
    close += 1 until close >= chars.length || (chars[close] == "`" && chars[close, length]&.length == length && chars[close, length].all? { |char| char == "`" } && (close.zero? || chars[close - 1] != "`"))
    break if close >= chars.length
    (index...close + length).each { |position| chars[position] = " " unless chars[position] == "\n" }
    index = close + length
  end
  chars.join
end

def sanitize(value)
  value.gsub(/[[:cntrl:]]/, "?")
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
    text, unclosed_fence = mask_code(source.read)
    failures << "#{source.relative_path_from(root)}: malformed documentation (unclosed code fence)" if unclosed_fence
    text = mask_inline_code(text)
    source_name = sanitize(source.relative_path_from(root).to_s)
    markdown_link_bodies(text).each do |body|
      raw_target = body.strip
      target = markdown_target(body)
      next if target.nil? || target.empty? || target.start_with?("#")
      next if target.match?(/\A(?:https?|mailto):/i)

      encoded_path = target.split("#", 2).first
      raise ArgumentError if encoded_path.match?(/%(?![0-9A-Fa-f]{2})/)

      path_text = unescape_destination(URI::DEFAULT_PARSER.unescape(encoded_path))
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
  Dir.mktmpdir("docs-links-test") do |directory|
    root = Pathname.new(directory)
    docs = root.join("docs")
    docs.mkpath
    docs.join("valid file.md").write("ok\n")
    docs.join("plus+file.md").write("ok\n")
    docs.join("balanced(name).md").write("ok\n")
    docs.join("a(b).md").write("ok\n")
    docs.join("subdir").mkpath
    outside = root.parent.join("docs-links-outside-#{Process.pid}")
    outside.write("outside\n")
    docs.join("escape.md").make_symlink(outside)
    source = docs.join("sample.md")
    source.write(<<~MARKDOWN)
      [file](valid%20file.md)
      [plus](plus+file.md)
      [balanced](balanced(name).md)
      [escaped destination](a\(b\).md)
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
      ```
      ~~~markdown
      [tilde](tilde-missing.md)
      ~~~
          ```markdown
          [indented](indented-missing.md)
          ```
      \\`[escaped](escaped-missing.md)\\`
      \\[one-slash](one-slash-missing.md)
      \\\\[two-slash](two-slash-missing.md)
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
    failures = check_sources(root, [source])
    expected = ["missing.md", "ordinary-missing.md", "nested-missing.md", "<missing).md>", "indented-missing.md", "two-slash-missing.md", "unequal-missing.md", "../../etc/passwd", "bad%ZZ.md", "escape.md"]
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
