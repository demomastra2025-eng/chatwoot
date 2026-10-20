# frozen_string_literal: true

require 'support/string/character_counter'

# What a password of a user must contain, in Russian. The rules are the ones the model enforces (Devise password length and
# the devise-secure_password module: a capital and a small Latin letter, a digit and a special character, nothing else), read
# from the same places, so this class and the model cannot drift apart. The error text of the model is English; the super
# admin shows these messages instead, before anything is saved.
#
#   SuperAdmin::PasswordRules.problems('abc')   # => [:length, :uppercase, :number, :special]
#   SuperAdmin::PasswordRules.message('abc')    # => "Пароль не подходит: он должен содержать не меньше 6 знаков; ..."
class SuperAdmin::PasswordRules
  # The order the rules are listed in (a list under the field, a message after a failed save)
  RULES = %i[length uppercase lowercase number special].freeze

  class << self
    # The keys of the rules a password breaks (RULES), plus :unknown for a character that is not allowed at all; empty
    # when the password is good.
    def problems(password)
      text = password.to_s
      counts = Support::String::CharacterCounter.new.count(text)
      broken = RULES.reject { |rule| satisfied?(rule, counts) }
      broken << :unknown if counts[:unknown].any?
      broken
    end

    def valid?(password)
      problems(password).empty?
    end

    # «Пароль не подходит: он должен содержать ...» for a bad password, nil for a good one
    def message(password)
      broken = problems(password)
      return if broken.empty?

      details = broken.map { |rule| I18n.t("super_admin.onboarding.password.rules.#{rule}", **interpolation) }
      I18n.t('super_admin.onboarding.password.bad', details: details.join('; '))
    end

    # The special characters the model accepts: «! @ # ...»
    def special_characters
      Support::String::CharacterCounter.new.count_hash[:special].keys.join
    end

    def length_range
      Devise.password_length
    end

    # The values the texts of the rules need (the lengths and a few examples of special characters)
    def interpolation
      { min: length_range.min, max: length_range.max, examples: '! @ # $ %' }
    end

    private

    def satisfied?(rule, counts)
      return length_range.cover?(counts[:length][:count]) if rule == :length

      counts[rule].values.sum >= required(rule)
    end

    # How many characters of the kind the model asks for (one of each by default)
    def required(rule)
      key = { uppercase: :password_required_uppercase_count, lowercase: :password_required_lowercase_count,
              number: :password_required_number_count, special: :password_required_special_character_count }.fetch(rule)
      Devise.public_send(key)
    end
  end
end
