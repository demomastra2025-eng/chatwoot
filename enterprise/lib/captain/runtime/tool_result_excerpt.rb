# frozen_string_literal: true

# The excerpt of a tool result that the model has already used. A step of a run sends the whole history to the model, so a large
# result (a catalog search, a list of free slots, long FAQ answers) is read again and again, long after the model chose what it
# needed from it. Once the model has answered after reading a large result, its tool message in the history of the run is replaced
# by a short summary built here, in code, with no extra model call: the ids, names, prices, statuses and dates it held, and the
# marker that tells the model to call the tool again for details. The tool message itself stays: the provider requires an answer
# for every tool call.
#
# Only the in-memory history of the chat changes. The system prompt, the tools and the earlier turns are not touched, and a result
# the model has not answered yet is never shortened.
module Captain::Runtime::ToolResultExcerpt
  # A result of at most this many bytes is cheap to read again and stays as it is.
  THRESHOLD_BYTES = 4096
  MARKER = 'Result shortened after use; call the tool again if you need details.'
  # The summary never exceeds this many bytes. The rows kept drop step by step until it fits: [rows of a list, rows of a list nested
  # inside a row (the specialists of a service, its price links)].
  BUDGET_BYTES = 2000
  ROW_LIMITS = [[12, 6], [8, 4], [6, 3], [4, 2], [3, 1], [2, 1], [1, 1]].freeze
  MAX_DEPTH = 4
  # A text up to this long (a name, a status, a date) is kept as it is; a longer one only under the keys of TEXT_KEYS, cut to LONG_TEXT.
  SHORT_TEXT = 100
  LONG_TEXT = 200
  TEXT_KEYS = %w[question answer message error reason].freeze
  NOISE_KEYS = %w[account_id created_at updated_at custom_attributes filters instruction paging_instruction].freeze
  NOISE_PREFIX = 'compensation_'
  PLAIN_TEXT_CHARS = 300

  module_function

  # Called when a message was added to the chat. A tool message means that the model has answered the earlier results and started
  # the next batch of calls: every large tool result before its last answer is shortened.
  def shorten_consumed!(chat)
    messages = chat.messages
    last_answer = messages.rindex { |message| message.role == :assistant }
    return if last_answer.nil?

    messages.first(last_answer).each do |message|
      next unless shortenable?(message)

      message.content = RubyLLM::Content.new(excerpt(message.content))
    end
  end

  def shortenable?(message)
    return false unless message.role == :tool

    text = message.content
    text.is_a?(String) && text.bytesize > THRESHOLD_BYTES && !text.start_with?(MARKER)
  end

  def excerpt(text)
    "#{MARKER}\n#{summary(text)}"
  end

  def summary(text)
    data = parse(text)
    return plain_summary(text) if data.nil?

    ROW_LIMITS.each do |limits|
      json = JSON.generate(digest(data, limits))
      return json if json.bytesize <= BUDGET_BYTES
    end
    JSON.generate(digest(data, ROW_LIMITS.last)).byteslice(0, BUDGET_BYTES).scrub
  end

  def parse(text)
    return unless text.lstrip.start_with?('{', '[')

    JSON.parse(text)
  rescue JSON::ParserError
    nil
  end

  def plain_summary(text)
    flat = text.squish
    flat.length > PLAIN_TEXT_CHARS ? "#{flat.first(PLAIN_TEXT_CHARS)}..." : flat
  end

  def digest(data, limits)
    data.is_a?(Array) ? digest_rows(data, 1, limits) : digest_hash(data, 0, limits)
  end

  def digest_hash(hash, depth, limits)
    hash.each_with_object({}) do |(key, value), result|
      next if noise_key?(key)

      entry = entry_for(key, value, depth, limits)
      result[key] = entry unless blank_entry?(entry)
    end
  end

  def entry_for(key, value, depth, limits)
    case value
    when String then text_entry(key, value)
    when Hash then digest_hash(value, depth + 1, limits) if depth < MAX_DEPTH
    when Array then digest_rows(value, depth + 1, limits) if depth < MAX_DEPTH
    else value
    end
  end

  # The rows of a list: the first ones, then how many were left out. A list directly under the answer gets the first limit.
  def digest_rows(rows, depth, limits)
    limit = depth == 1 ? limits.first : limits.last
    kept = rows.first(limit).filter_map { |row| row_entry(row, depth, limits) }
    kept << "+#{rows.size - limit} more" if rows.size > limit
    kept
  end

  def row_entry(row, depth, limits)
    case row
    when Hash then digest_hash(row, depth, limits)
    when String then text_entry(nil, row)
    when Numeric, true, false then row
    end
  end

  def text_entry(key, value)
    text = value.squish
    return text if text.length <= SHORT_TEXT
    return "#{text.first(LONG_TEXT)}..." if TEXT_KEYS.include?(key.to_s)

    nil
  end

  def noise_key?(key)
    NOISE_KEYS.include?(key) || key.to_s.start_with?(NOISE_PREFIX)
  end

  # false is an answer (active: false); nil, an empty text and an empty list or object say nothing.
  def blank_entry?(entry)
    entry.nil? || ((entry.is_a?(String) || entry.is_a?(Array) || entry.is_a?(Hash)) && entry.empty?)
  end
end
