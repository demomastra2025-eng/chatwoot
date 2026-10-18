# frozen_string_literal: true

# How the super admin shows a secret (an API token, a key): never the value itself, at most its last characters, so a
# person can tell two tokens apart. A value that is too short to give anything away safely is shown as dots only.
#
#   SuperAdmin::SecretMask.hint('abcdefghijklmnop')  # => "••••mnop"
#   SuperAdmin::SecretMask.hint('abc')               # => "••••"
#   SuperAdmin::SecretMask.hint(nil)                 # => nil
module SuperAdmin::SecretMask
  DOTS = '••••'
  VISIBLE = 4
  # A secret shorter than this shows no characters at all (4 of 8 would be half of it)
  MIN_LENGTH_TO_SHOW_TAIL = 12

  module_function

  def hint(value)
    text = value.to_s
    return if text.empty?

    text.length >= MIN_LENGTH_TO_SHOW_TAIL ? "#{DOTS}#{text.last(VISIBLE)}" : DOTS
  end
end
