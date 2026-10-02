require 'bigdecimal'
require 'date'
require 'json'

class Whatsapp::MetaUsdRateCatalog
  CATALOG_PATH = Rails.root.join('config/whatsapp/meta_usd_rates_20261001.json').freeze

  def self.rate(country_code:, category:, at:)
    date = normalized_date(at)
    return unless date_in_effective_window?(date)

    amount = rate_amount(country_code, category)
    BigDecimal(amount) if amount.present?
  rescue ArgumentError, KeyError, TypeError
    nil
  end

  def self.date_in_effective_window?(date)
    date && date >= Date.iso8601(catalog.fetch('effective_from')) &&
      date < Date.iso8601(catalog.fetch('effective_until_exclusive'))
  end
  private_class_method :date_in_effective_window?

  def self.rate_amount(country_code, category)
    country = normalized_country_code(country_code)
    return unless country

    market = catalog.dig('country_to_market', country)
    return unless market

    catalog.dig('markets', market, 'rates', normalized_category(category))
  end
  private_class_method :rate_amount

  def self.normalized_country_code(value)
    country = value.to_s.upcase
    country if country.match?(/\A[A-Z]{2}\z/)
  end
  private_class_method :normalized_country_code

  def self.normalized_category(value)
    category = value.to_s
    return 'authentication-international' if category == 'authentication_international'

    category
  end
  private_class_method :normalized_category

  def self.catalog
    @catalog ||= JSON.parse(File.read(CATALOG_PATH))
  end
  private_class_method :catalog

  def self.normalized_date(value)
    return value.to_time.utc.to_date if value.is_a?(Time) || value.is_a?(DateTime)
    return value.to_time.utc.to_date if value.respond_to?(:to_time) && !value.is_a?(Date)
    return value.to_date if value.is_a?(Date)

    Date.iso8601(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :normalized_date
end
