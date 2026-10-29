# frozen_string_literal: true

module Integrations::KaspiPay::PhoneNormalizer
  class InvalidPhoneError < StandardError; end

  module_function

  # Kaspi Pay entrance & qrpay endpoints expect a 10-digit national KZ number (e.g. "7011234567").
  def to_kaspi_10_digits!(raw_phone)
    digits = raw_phone.to_s.gsub(/\D/, '')
    digits = digits[1..] if digits.length == 11 && %w[7 8].include?(digits[0])

    unless digits.length == 10 && digits.start_with?('7')
      raise InvalidPhoneError, 'Введите корректный казахстанский номер телефона (+7 7XX XXX XX XX)'
    end

    digits
  end

  def to_kaspi_10_digits(raw_phone)
    to_kaspi_10_digits!(raw_phone)
  rescue InvalidPhoneError
    nil
  end

  def format_display(raw_phone)
    d = to_kaspi_10_digits(raw_phone)
    return raw_phone.to_s if d.blank?

    "+7 (#{d[0, 3]}) #{d[3, 3]}-#{d[6, 2]}-#{d[8, 2]}"
  end

  def mask(raw_phone)
    d = to_kaspi_10_digits(raw_phone)
    return '***' if d.blank?

    "+7 #{d[0, 3]} *** ** #{d[8, 2]}"
  end
end
