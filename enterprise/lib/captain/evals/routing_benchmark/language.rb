# frozen_string_literal: true

# A conservative Russian/Kazakh guess for benchmark turns. It answers :ru or :kk only on strong evidence and
# :unknown otherwise, so a name, "ок" or a time never changes the language of a dialogue and a Russian service
# name inside a Kazakh reply does not turn it into a Russian reply. Capitalised words that carry Kazakh letters
# are ignored because they are usually names. The optional rubric judge (JUDGE=1) remains the quality check.
class Captain::Evals::RoutingBenchmark::Language
  # ә ғ қ ң ө ұ ү һ і
  KAZAKH_LETTERS = /[әғқңөұүһі]/
  # Frequent Kazakh words that contain no Kazakh-only letter.
  KAZAKH_WORDS = %w[мен емес керек болады болмайды туралы жазу жазып жазылу рахмет салем жарайды немесе онда осы мына ол екен].freeze
  # Frequent Russian function words that do not occur in Kazakh text.
  RUSSIAN_WORDS = %w[
    и в на не что это как я мы вы вас вам нас нам мне меня мой моя мою моё ваш ваша вашу ваши вашей можно нужно надо хочу
    хотела хотел пожалуйста здравствуйте спасибо есть нет или для по но если когда будет был была были чтобы уже ещё еще
    только очень какой какая какое где там тут здесь сейчас потом после перед при без из от за к с у о об
  ].freeze

  class << self
    # :cyrillic, :latin (at least two Latin words) or :neutral (digits, emoji, "ok", a single word).
    def script(text)
      text = text.to_s
      return :cyrillic if text.match?(/\p{Cyrillic}/)

      text.scan(/\p{Latin}{2,}/).size >= 2 ? :latin : :neutral
    end

    # Why a text is not in the expected language (:ru or :kk), or nil when it is. The fixtures of the v2 schema state the expected
    # language of a turn (`reply_language`), so no dialogue-wide guess is needed: a text with Latin words and no Cyrillic is in no
    # expected language, a text that reads as the other language is not, and a short neutral text (a time, an emoji, a single
    # word) or a weakly marked one passes.
    def mismatch(expected, text)
      other = expected.to_sym == :ru ? :kk : :ru
      case script(text)
      when :neutral then nil
      when :latin then 'the reply has no Cyrillic'
      else detect(text) == other ? "the reply reads as #{other}, expected #{expected}" : nil
      end
    end

    def detect(text)
      return :unknown unless script(text) == :cyrillic

      tokens = text.to_s.scan(/\p{L}+/)
      kazakh = tokens.count { |token| kazakh?(token) }
      russian = tokens.count { |token| RUSSIAN_WORDS.include?(token.downcase) }
      return :kk if kazakh >= 2 && kazakh > russian
      return :ru if russian >= 3 && russian > kazakh * 2

      :unknown
    end

    private

    def kazakh?(token)
      lower = token.downcase
      KAZAKH_WORDS.include?(lower) || (lower.match?(KAZAKH_LETTERS) && !token.match?(/\A\p{Lu}/))
    end
  end
end
