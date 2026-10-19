# frozen_string_literal: true

# A locale that ships a plural rule (`i18n.plural.rule`, see config/locales/pluralization.ru.rb) picks the form of a
# counted text by its category (one / few / many / other), not by the English "is it 1". Russian needs it: «1 аккаунт»,
# «2 аккаунта», «5 аккаунтов», «21 аккаунт». A locale without a rule keeps the default one / other choice.
module LocalePluralization
  include I18n::Backend::Pluralization

  protected

  # The rule is read from the stored translations of the locale itself. The default lookup goes through I18n.t, which
  # follows the fallbacks (a locale without a rule would borrow the one of the fallback locale) and raises for a
  # missing key where the app turns missing translations into errors.
  def pluralizer(locale)
    return pluralizers[locale] if pluralizers.key?(locale)

    pluralizers[locale] = lookup(locale, :'i18n.plural.rule')
  end
end

I18n::Backend::Simple.include(LocalePluralization)
