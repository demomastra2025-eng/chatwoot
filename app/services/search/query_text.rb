# Cleans the text typed into a search box before it is compared with anything in SQL.
#
# Text copied from a messenger, a web page or a spreadsheet brings invisible baggage: non-breaking, thin and narrow
# spaces, direction marks (U+200E, U+200F, U+202A-202E), zero-width characters, a decomposed "й" or "ё". Every kind of
# space becomes a plain one, letters are composed (NFC) and full-width ASCII (＋７ ７０７, Ａ) becomes plain ASCII; control and
# format characters are dropped. NFKC is NOT used: it rewrites characters that people type on purpose and that stay as
# they are in the stored text ("№" to "No", "…" to "...", "²" to "2", "™" to "TM"), so a literal search for "справка №123"
# would find nothing. A NUL byte would make PostgreSQL reject the statement (HTTP 500), so it never gets past here.
# Invalid UTF-8 is scrubbed for the same reason.
module Search::QueryText
  MAX_LENGTH = 200
  # Any letter spelled with "е" or "ё": the two are the same letter for a person who types a name or a word.
  YO_LETTERS = /[еёЕЁ]/
  REGEXP_SPECIAL = /[\\^$.|?*+()\[\]{}]/
  FULL_WIDTH_ASCII = /[\uFF01-\uFF5E]/
  FULL_WIDTH_OFFSET = 0xFEE0
  # Between two typed words a space matches any run of spaces and punctuation of the message (a comma, a line break, two
  # spaces), and the sentence punctuation that sits next to such a space ("день, хочу") does not have to be there.
  # Every other character, "№" or a bracket for instance, has to be there as typed.
  WORD_GAP_RUN = /([.,;:!?…"'«» ]+)/
  WORD_GAP_REGEXP = '[^[:alnum:]]+'.freeze

  module_function

  def clean(raw)
    text = raw.to_s.scrub('').unicode_normalize(:nfc)
    text = text.gsub(FULL_WIDTH_ASCII) { |char| (char.ord - FULL_WIDTH_OFFSET).chr(Encoding::UTF_8) }
    text = text.gsub(/[[:space:]]+/, ' ').gsub(/[\p{Cc}\p{Cf}]/, '')
    text.strip.first(MAX_LENGTH).strip
  end

  def like_pattern(text)
    "%#{ActiveRecord::Base.sanitize_sql_like(text)}%"
  end

  def yo?(text)
    text.match?(YO_LETTERS)
  end

  # A POSIX regular expression (use with the case-insensitive ~* operator) that finds the text with "е" and "ё"
  # interchangeable: "Семён" and "Семен" both find both, also in names that contain several of the letters.
  def yo_regexp(text)
    text.gsub(REGEXP_SPECIAL) { |char| "\\#{char}" }.gsub(YO_LETTERS, '[её]')
  end

  # The same, for a text of several words: the gap between two typed words accepts any run of non-letters (see WORD_GAP_RUN).
  def literal_regexp(text)
    text.split(WORD_GAP_RUN).map { |piece| piece.include?(' ') ? WORD_GAP_REGEXP : yo_regexp(piece) }.join
  end

  def gap?(text)
    text.split(WORD_GAP_RUN).any? { |piece| piece.include?(' ') }
  end
end
