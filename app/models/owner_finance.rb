# frozen_string_literal: true

module OwnerFinance
  DEFAULT_REMIND_DAYS = [7, 3, 2, 1, 0].freeze
  ALMATY_TIMEZONE = 'Asia/Almaty'
  SUPPORTED_CURRENCIES = %w[KZT USD EUR RUB].freeze

  FX_FALLBACK_RATES_KZT = {
    'KZT' => BigDecimal(1),
    'USD' => BigDecimal(490),
    'EUR' => BigDecimal(545),
    'RUB' => BigDecimal('5.2')
  }.freeze

  def self.table_name_prefix
    'owner_finance_'
  end

  def self.today_almaty
    Time.current.in_time_zone(ALMATY_TIMEZONE).to_date
  end

  def self.to_kzt(amount, currency)
    amt = BigDecimal((amount || 0).to_s)
    rate = FX_FALLBACK_RATES_KZT.fetch(currency.to_s.strip.upcase, BigDecimal(1))
    (amt * rate).round(2)
  end

  def self.normalize_merchant_key(value)
    cleaned = value.to_s.downcase.tr("\u00A0", ' ')
    cleaned = cleaned.gsub(/\(\s*[-+]?\s*[\d\s.,]+\s*(?:usd|eur|rub|kzt|\$|€|₽|₸)\s*\)/i, ' ')
    cleaned = cleaned.gsub(/курсовая разница\.?/i, ' ')
    cleaned = cleaned.gsub(/[^a-zа-яёәіңғүұқөһ0-9]+/i, ' ')
    cleaned.split.join(' ').slice(0, 80)
  end
end
