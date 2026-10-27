# frozen_string_literal: true

# Reads the text of one string field of a JSON object while the model is still writing it. The agent answers in structured output
# and the JSON arrives in pieces of a few characters; this keeps just enough state to hand out the text of the field so far,
# decoded (\n, \", \uXXXX and surrogate pairs, also when an escape is cut between two pieces). Only the keys of the top-level object
# are looked at; any other value (a number, a list, an unknown key) is skipped. Anything that is not the JSON it expects ends the
# reading for good (#dead?): a preview is a convenience, it never guesses what the model meant.
class Captain::ReplySuggestion::DraftStream::FieldReader
  FIELD = 'response'
  MODE_FIELD = 'response_mode'
  MAX_KEY_LENGTH = 64
  MAX_TEXT_LENGTH = 20_000
  WHITESPACE = [' ', "\t", "\r", "\n"].freeze
  REPLACEMENT = '�'
  STEPS = {
    start: :expect_open, first_key: :expect_first_key, next_key: :expect_key_start, key: :read_key,
    colon: :expect_colon, value: :begin_value, string: :read_string, skip: :skip_value,
    after_value: :after_value
  }.freeze
  DISCARD = Class.new { def <<(_char) = self }.new

  # text: the decoded text of the field so far. mode: the value of response_mode once that string is complete (nil before).
  attr_reader :text, :mode

  def initialize
    reset
  end

  def reset
    @state = :start
    @key = +''
    @target = nil
    @text = +''
    @mode = nil
    @mode_buffer = +''
    @field_seen = false
    @mode_seen = false
    @closed = false
    @decoder = StringDecoder.new
    @skip_escape = false
    @skip_depth = 0
    @skip_in_string = false
    self
  end

  def feed(chunk)
    return self if dead? || done?

    chunk.to_s.each_char do |char|
      step(char)
      break if dead? || done?
    end
    self
  end

  # The string of the field is complete.
  def closed?
    @closed
  end

  def done?
    @state == :done
  end

  def dead?
    @state == :dead
  end

  private

  def step(char)
    __send__(STEPS.fetch(@state), char)
  end

  def expect_open(char)
    return if whitespace?(char)

    char == '{' ? @state = :first_key : die
  end

  def expect_first_key(char)
    return if whitespace?(char)
    return @state = :done if char == '}'

    expect_key_start(char)
  end

  def expect_key_start(char)
    return if whitespace?(char)
    return die unless char == '"'

    @key = +''
    @state = :key
  end

  def read_key(char)
    closed = false
    valid = @decoder.decode(char, @key) { closed = true }
    die unless valid
    @state = :colon if closed
    die if @key.length > MAX_KEY_LENGTH
  end

  def expect_colon(char)
    return if whitespace?(char)

    char == ':' ? @state = :value : die
  end

  def begin_value(char)
    return if whitespace?(char)
    return die if tracked_key_repeated?
    return begin_string_value if char == '"'

    @skip_depth = 0
    @skip_in_string = false
    @state = :skip
    skip_value(char)
  end

  def begin_string_value
    @target = target_for(@key)
    @field_seen = true if @target == :text
    @mode_seen = true if @target == :mode
    @state = :string
  end

  # A duplicate tracked key can replace a previously previewed value in the final JSON parser.
  # Stop previewing rather than guessing which value will win.
  def tracked_key_repeated?
    (@key == FIELD && @field_seen) || (@key == MODE_FIELD && @mode_seen)
  end

  def target_for(key)
    return :text if key == FIELD && !@field_seen
    return :mode if key == MODE_FIELD && !@mode_seen

    nil
  end

  def read_string(char)
    buffer = buffer_for(@target)
    die unless @decoder.decode(char, buffer) { finish_string }
    die if @text.length > MAX_TEXT_LENGTH
  end

  def buffer_for(target)
    case target
    when :text then @text
    when :mode then @mode_buffer
    else DISCARD
    end
  end

  def finish_string
    @closed = true if @target == :text
    @mode = @mode_buffer.dup if @target == :mode
    @target = nil
    @state = :after_value
  end

  def after_value(char)
    return if whitespace?(char)

    case char
    when ',' then @state = :next_key
    when '}' then @state = :done
    else die
    end
  end

  # A value that is not a string: a number, true/false/null, or a list. Strings inside it are walked so that a bracket in a
  # text does not count.
  def skip_value(char)
    return skip_string_char(char) if @skip_in_string

    case char
    when '"' then @skip_in_string = true
    when '[', '{' then @skip_depth += 1
    else skip_delimiter(char)
    end
  end

  def skip_delimiter(char)
    case char
    when ']' then close_skipped_group
    when '}' then close_skipped_object
    when ',' then @state = :next_key if @skip_depth.zero?
    end
  end

  def skip_string_char(char)
    if @skip_escape
      @skip_escape = false
    elsif char == '\\'
      @skip_escape = true
    elsif char == '"'
      @skip_in_string = false
    end
  end

  def close_skipped_group
    @skip_depth.zero? ? die : @skip_depth -= 1
  end

  def close_skipped_object
    return @state = :done if @skip_depth.zero?

    @skip_depth -= 1
  end

  def whitespace?(char)
    WHITESPACE.include?(char)
  end

  def die
    @state = :dead
  end
end
