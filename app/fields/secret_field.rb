require 'administrate/field/base'

# A secret value on a list or a card. The page NEVER carries the secret: `data` is what a screen may show of it (the
# last characters, SuperAdmin::SecretMask), and there is no button that reveals or copies the full value.
class SecretField < Administrate::Field::String
  # A search over a secret answers «does the secret contain these characters?», which rebuilds it one character at a
  # time. Not searchable, so the search box of a list never looks at it.
  def self.searchable?
    false
  end

  def data
    SuperAdmin::SecretMask.hint(super)
  end

  def to_s
    data.to_s
  end
end
