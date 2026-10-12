# frozen_string_literal: true

# The language of a customer notice (ru or kk), read from the customer's latest messages. Kazakh when a fair share of the
# Cyrillic words has a Kazakh-only letter; one Kazakh name in a Russian text does not make the text Kazakh, because in
# Kazakhstan Russian-speaking customers often write Kazakh names (and names are skipped: a capitalised word inside a
# sentence). Other Cyrillic text is Russian; without Cyrillic text the caller's default (the workspace language) decides.
module Captain::CustomerNoticeLanguage
  # The language is read from the latest messages only, so that the customer's current language wins.
  MESSAGE_COUNT = 3
  KAZAKH_LETTERS = /[әғқңөұүһіӘҒҚҢӨҰҮҺІ]/
  # A Cyrillic word, or the end of a sentence.
  TOKEN_PATTERN = /\p{Cyrillic}+|[.!?\n]/
  SENTENCE_END_PATTERN = /\A[.!?\n]\z/
  NAME_LIKE_PATTERN = /\A\p{Lu}\p{Ll}+\z/
  # The text is Kazakh when at least this share (1 of 4) of its Cyrillic words has a Kazakh letter.
  KAZAKH_SHARE_DIVISOR = 4

  # messages: the customer's public messages, oldest first.
  def self.detect(messages, default:)
    words = cyrillic_words(Array(messages).last(MESSAGE_COUNT).join("\n"))
    return default if words.empty?

    kazakh = words.count { |word| word.match?(KAZAKH_LETTERS) }
    kazakh.positive? && kazakh * KAZAKH_SHARE_DIVISOR >= words.size ? 'kk' : 'ru'
  end

  # The Cyrillic words of the text without the names. Every message starts a sentence, so its first word always counts.
  def self.cyrillic_words(text)
    sentence_start = true
    text.scan(TOKEN_PATTERN).each_with_object([]) do |token, words|
      if token.match?(SENTENCE_END_PATTERN)
        sentence_start = true
      else
        words << token if sentence_start || !token.match?(NAME_LIKE_PATTERN)
        sentence_start = false
      end
    end
  end
  private_class_method :cyrillic_words
end
