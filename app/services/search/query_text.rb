# Cleans the text typed into a search box before it is compared with anything in SQL.
#
# Text copied from a messenger, a web page or a spreadsheet brings invisible baggage: non-breaking, thin and narrow
# spaces, direction marks (U+200E, U+200F, U+202A-202E), zero-width characters, a decomposed "й" or "ё". NFKC turns the
# exotic spaces into plain ones and composes letters; control and format characters are dropped. A NUL byte would make
# PostgreSQL reject the statement (HTTP 500), so it never gets past here. Invalid UTF-8 is scrubbed for the same reason.
module Search::QueryText
  MAX_LENGTH = 200
  # Any letter spelled with "е" or "ё": the two are the same letter for a person who types a name or a word.
  YO_LETTERS = /[еёЕЁ]/
  REGEXP_SPECIAL = /[\\^$.|?*+()\[\]{}]/

  module_function

  def clean(raw)
    text = raw.to_s.scrub('').unicode_normalize(:nfkc)
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
end
