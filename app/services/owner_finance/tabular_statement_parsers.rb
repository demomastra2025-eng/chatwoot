# frozen_string_literal: true

require 'csv'

class OwnerFinance::TabularStatementParsers
  DATE_KEYS = ['date', 'дата', 'occurred_on', 'дата операции'].freeze
  AMOUNT_KEYS = ['amount', 'сумма', 'сумма операции'].freeze
  MERCHANT_KEYS = %w[merchant контрагент описание назначение details].freeze
  DESCRIPTION_KEYS = %w[description назначение merchant контрагент описание details].freeze
  CURRENCY_KEYS = %w[currency валюта].freeze

  class << self
    def parse_1c_exchange(text)
      rows = []
      current = nil
      text.each_line { |raw_line| current = process_1c_line(raw_line.strip, current, rows) }
      rows
    end

    def parse_csv_rows(text)
      sep = text.lines.first.to_s.include?(';') ? ';' : ','
      rows = []
      CSV.parse(text, headers: true, col_sep: sep, liberal_parsing: true) do |csv_row|
        built = build_csv_row(csv_row.to_h.transform_keys { |key| key.to_s.strip.downcase })
        rows << built if built
      end
      rows
    rescue CSV::MalformedCSVError
      []
    end

    private

    def process_1c_line(line, current, rows)
      return {} if line.start_with?('СекцияДокумент=')
      return finalize_1c_doc(current, rows) if line == 'КонецДокумента' && current

      assign_1c_pair(current, line) if current && line.include?('=')
      current
    end

    def finalize_1c_doc(current, rows)
      built = build_1c_row(current)
      rows << built if built
      nil
    end

    def assign_1c_pair(current, line)
      key, val = line.split('=', 2)
      current[key.strip] = val.to_s.strip
    end

    def build_1c_row(doc)
      amount = OwnerFinance::StatementParsers.parse_decimal(doc['Сумма'])
      occurred_on = OwnerFinance::StatementParsers.parse_date_safe(extract_1c_date(doc))
      return nil unless amount.positive? && occurred_on

      outgoing = doc['ДатаСписания'].present? && doc['ДатаПоступило'].blank?
      {
        source_type: '1c_bank', official_status: 'official_1c', is_personal_card: false,
        occurred_on: occurred_on, direction: outgoing ? 'expense' : 'income', amount: amount,
        currency: 'KZT', merchant: extract_1c_counterparty(doc, outgoing),
        description: doc['НазначениеПлатежа'].to_s.strip
      }
    end

    def extract_1c_date(doc)
      doc['ДатаСписания'].presence || doc['ДатаПоступило'].presence || doc['Дата']
    end

    def extract_1c_counterparty(doc, outgoing)
      keys = outgoing ? %w[Получатель1 Получатель] : %w[Плательщик1 Плательщик]
      found = keys.lazy.filter_map { |key| doc[key].presence }.first
      (found || 'Банковская операция 1С').slice(0, 140)
    end

    def build_csv_row(hash)
      occurred_on = OwnerFinance::StatementParsers.parse_date_safe(first_value(hash, DATE_KEYS))
      raw_amt = first_value(hash, AMOUNT_KEYS)
      return nil unless occurred_on && raw_amt

      val = BigDecimal(raw_amt.tr("\u00A0 ", '').tr(',', '.'))
      val.zero? ? nil : csv_row_payload(hash, occurred_on, val)
    rescue ArgumentError
      nil
    end

    def csv_row_payload(hash, occurred_on, val)
      merchant = first_value(hash, MERCHANT_KEYS) || 'Операция CSV'
      cur = OwnerFinance::StatementParsers.normalize_currency(first_value(hash, CURRENCY_KEYS) || 'KZT')
      {
        source_type: 'csv', official_status: 'management', is_personal_card: true,
        occurred_on: occurred_on, direction: val.negative? ? 'expense' : 'income',
        amount: val.abs, currency: cur, merchant: merchant.slice(0, 140),
        description: (first_value(hash, DESCRIPTION_KEYS) || merchant)
      }
    end

    def first_value(hash, keys)
      keys.lazy.filter_map { |key| hash[key].to_s.strip.presence }.first
    end
  end
end
