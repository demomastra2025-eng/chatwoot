# frozen_string_literal: true

module Billing
  ALMATY_TIMEZONE = 'Asia/Almaty'
  MINOR_PER_KZT = 100
  DEFAULT_CURRENCY = 'KZT'
  TAX_ID_FORMAT = /\A\d{12}\z/
  INVOICE_CODE_REGEX = /\b(OL-\d{6}-\d{4,}-\d{2,})\b/i
  SENSITIVE_PAYLOAD_KEYS = %w[
    card_token bcc_card_token pan card_number cvv cvc token access_token
  ].freeze

  def self.table_name_prefix
    'billing_'
  end

  def self.today_almaty
    Time.use_zone(ALMATY_TIMEZONE) { Date.current }
  end

  def self.now_almaty
    Time.current.in_time_zone(ALMATY_TIMEZONE)
  end

  def self.kzt_to_minor(amount_kzt)
    (BigDecimal(amount_kzt.to_s) * MINOR_PER_KZT).round(0).to_i
  end

  def self.minor_to_kzt(amount_minor)
    (BigDecimal(amount_minor.to_i.to_s) / MINOR_PER_KZT).round(2)
  end

  def self.normalize_tax_id(raw)
    cleaned = raw.to_s.gsub(/[[:space:]]+/, '')
    cleaned.presence
  end

  def self.sanitize_sensitive_payload(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested), acc|
        key_str = key.to_s
        next if SENSITIVE_PAYLOAD_KEYS.include?(key_str.downcase)

        acc[key_str] = sanitize_sensitive_payload(nested)
      end
    when Array
      value.map { |item| sanitize_sensitive_payload(item) }
    else
      value
    end
  end
end
