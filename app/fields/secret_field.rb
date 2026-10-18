require 'administrate/field/base'

# A secret value on a list or a card. The page NEVER carries the secret: `data` is what a screen may show of it (the
# last characters, SuperAdmin::SecretMask), and there is no button that reveals or copies the full value.
class SecretField < Administrate::Field::String
  def data
    SuperAdmin::SecretMask.hint(super)
  end

  def to_s
    data.to_s
  end
end
