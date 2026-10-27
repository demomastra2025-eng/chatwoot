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
  WHITESPACE = [" ", "\t", "\r", "\n"].freeze
  HEX = /\A\h\z/
  SIMPLE_ESCAPES = { '"' => '"', '\\' => '\\', '/' => '/', 'n' => "\n", 't' => "\t", 'r' => "\r", 'b' => "\b", 'f' => "\f" }.freeze
  HIGH_SURROGATES = (0xD800..0xDBFF)
  LOW_SURROGATES = (0xDC00..0xDFFF)
  REPLACEMENT = "�"

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
    @closed = false
    @escape = false
    @unicode = nil
    @high = nil
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
    case @state
    when :start then expect_open(char)
    when :first_key then expect_first_key(char)
    when :next_key then expect_key_start(char)
    when :key then read_key(char)
    when :colon then expect_colon(char)
    when :value then begin_value(char)
    when :string then read_string(char)
    when :skip then skip_value(char)
    when :after_value then after_value(char)
    end
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
    decode(char, @key) { @state = :colon }
    die if @key.length > MAX_KEY_LENGTH
  end

  def expect_colon(char)
    return if whitespace?(char)

    char == ':' ? @state = :value : die
  end

  def begin_value(char)
    return if whitespace?(char)
    return begin_string_value if char == '"'

    @skip_depth = 0
    @skip_in_string = false
    @state = :skip
    skip_value(char)
  end

  def begin_string_value
    @target = target_for(@key)
    @field_seen = true if @target == :text
    @state = :string
  end

  # The first value of each tracked key is read; a repeated key is skipped.
  def target_for(key)
    return :text if key == FIELD && !@field_seen
    return :mode if key == MODE_FIELD && @mode.nil?

    nil
  end

  def read_string(char)
    buffer = buffer_for(@target)
    decode(char, buffer) { finish_string }
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
    when ']' then close_skipped_group
    when '}' then close_skipped_object
    when ',' then @state = :next_key if @skip_depth.zero?
    end
  end

  def skip_string_char(char)
    if @escape
      @escape = false
    elsif char == '\\'
      @escape = true
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

  # Decodes one character of a JSON string into buffer; yields when the closing quote is read.
  def decode(char, buffer)
    return read_unicode(char, buffer) if @unicode
    return read_escape(char, buffer) if @escape

    case char
    when '\\' then @escape = true
    when '"'
      flush_high(buffer)
      yield
    else
      flush_high(buffer)
      buffer << char
    end
  end

  def read_escape(char, buffer)
    @escape = false
    if char == 'u'
      @unicode = +''
    elsif SIMPLE_ESCAPES.key?(char)
      flush_high(buffer)
      buffer << SIMPLE_ESCAPES[char]
    else
      die
    end
  end

  def read_unicode(char, buffer)
    return die unless HEX.match?(char)

    @unicode << char
    return if @unicode.length < 4

    code = @unicode.to_i(16)
    @unicode = nil
    append_code(code, buffer)
  end

  # A code in the high range waits for the low half that follows it (it may arrive in the next piece).
  def append_code(code, buffer)
    if HIGH_SURROGATES.cover?(code)
      flush_high(buffer)
      @high = code
    elsif LOW_SURROGATES.cover?(code)
      buffer << (@high ? [0x10000 + ((@high - 0xD800) << 10) + (code - 0xDC00)].pack('U') : REPLACEMENT)
      @high = nil
    else
      flush_high(buffer)
      buffer << [code].pack('U')
    end
  end

  def flush_high(buffer)
    return unless @high

    buffer << REPLACEMENT
    @high = nil
  end

  def whitespace?(char)
    WHITESPACE.include?(char)
  end

  def die
    @state = :dead
  end

  # The buffer of a string that is read only to get past it.
  class Discard
    def <<(_char)
      self
    end
  end
  DISCARD = Discard.new
end
