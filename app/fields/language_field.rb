require 'administrate/field/base'

# The language of an account, as text. The platform speaks Russian only for now (owner decision, ru-only freeze), so the
# forms of the super admin do not offer Қазақша or English: they say «Язык: русский» and send no language. The language an
# account already has is shown as it is, and a form that sends one is still accepted (the account is not changed by the
# page that only shows it).
class LanguageField < Administrate::Field::Base
  # «русский», «казахский», «английский»; a code the list does not know is shown as it is
  def to_s
    self.class.name_of(data)
  end

  def self.name_of(code)
    I18n.t("super_admin.locale_names.#{code}", default: code.to_s)
  end

  def self.searchable?
    false
  end
end
