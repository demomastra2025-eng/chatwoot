# frozen_string_literal: true

# The plural categories of Russian (CLDR): one (1, 21, 101 ...), few (2-4, 22-24 ...), many (0, 5-20, 25-30 ...), other
# (a fraction). Used by Onelink::Pluralization (config/initializers/i18n_pluralization.rb).
{
  ru: {
    i18n: {
      plural: {
        keys: %i[one few many other],
        rule: lambda do |count|
          # A count that is not a number (a text that was formatted for the page) has no category of its own
          next :other unless count.is_a?(Numeric)
          next :other if count.respond_to?(:finite?) && !count.finite?
          next :other unless count == count.to_i

          whole = count.to_i.abs
          last_digit = whole % 10
          last_two_digits = whole % 100

          if last_digit == 1 && last_two_digits != 11
            :one
          elsif (2..4).cover?(last_digit) && !(12..14).cover?(last_two_digits)
            :few
          else
            :many
          end
        end
      }
    }
  }
}
