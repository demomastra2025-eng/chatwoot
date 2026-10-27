# frozen_string_literal: true

# Decodes one JSON string a character at a time, including escapes split across provider chunks.
class Captain::ReplySuggestion::DraftStream::FieldReader::StringDecoder
  HEX = /\A\h\z/
  SIMPLE_ESCAPES = { '"' => '"', '\\' => '\\', '/' => '/', 'n' => "\n", 't' => "\t", 'r' => "\r", 'b' => "\b", 'f' => "\f" }.freeze
  HIGH_SURROGATES = (0xD800..0xDBFF)
  LOW_SURROGATES = (0xDC00..0xDFFF)
  REPLACEMENT = Captain::ReplySuggestion::DraftStream::FieldReader::REPLACEMENT

  def initialize
    @escape = false
    @unicode = nil
    @high = nil
  end

  # Returns false for an invalid escape; yields when the string closes.
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
    true
  end

  private

  def read_escape(char, buffer)
    @escape = false
    if char == 'u'
      @unicode = +''
    elsif SIMPLE_ESCAPES.key?(char)
      flush_high(buffer)
      buffer << SIMPLE_ESCAPES[char]
    else
      return false
    end
    true
  end

  def read_unicode(char, buffer)
    return false unless HEX.match?(char)

    @unicode << char
    return true if @unicode.length < 4

    code = @unicode.to_i(16)
    @unicode = nil
    append_code(code, buffer)
    true
  end

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
end
