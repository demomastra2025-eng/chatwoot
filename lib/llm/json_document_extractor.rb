# frozen_string_literal: true

require 'strscan'

class Llm::JsonDocumentExtractor
  OPEN_TO_CLOSE = { '{' => '}', '[' => ']' }.freeze
  CLOSE_TO_OPEN = OPEN_TO_CLOSE.invert.freeze
  JSON_STRING_PATTERN = /"(?:\\.|[^"\\])*"/m

  class << self
    def call(content)
      new(content).call
    end
  end

  def initialize(content)
    @content = content.to_s
  end

  def call
    normalized = strip_reasoning_tags(@content)
    return normalized if json_document_like?(normalized)

    fenced_json_document(normalized) || balanced_json_document(normalized)
  end

  private

  def strip_reasoning_tags(content)
    content.gsub(%r{<think>.*?</think>}mi, '').strip
  end

  def fenced_json_document(content)
    match = content.match(/```(?:json)?\s*(.*?)\s*```/mi)
    return unless match

    candidate = match[1].to_s.strip
    candidate if json_document_like?(candidate)
  end

  def json_document_like?(content)
    stripped = content.to_s.strip
    (stripped.start_with?('{') && stripped.end_with?('}')) ||
      (stripped.start_with?('[') && stripped.end_with?(']'))
  end

  def balanced_json_document(content)
    start_index = content =~ /[\{\[]/
    return if start_index.nil?

    scanner = StringScanner.new(content[start_index..])
    stack = []
    scan_json_document(scanner, stack, content, start_index)
  end

  def scan_json_document(scanner, stack, content, start_index)
    until scanner.eos?
      next if scanner.scan(JSON_STRING_PATTERN)

      char = scanner.getch
      stack << char if OPEN_TO_CLOSE.key?(char)
      return if closing_mismatch?(stack, char)
      return content[start_index, scanner.pos] if closes_document?(stack, char)
    end
  end

  def closing_mismatch?(stack, char)
    expected_open = CLOSE_TO_OPEN[char]
    return false unless expected_open

    stack.pop != expected_open
  end

  def closes_document?(stack, char)
    CLOSE_TO_OPEN.key?(char) && stack.empty?
  end
end
