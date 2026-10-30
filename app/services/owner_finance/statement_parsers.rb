# frozen_string_literal: true

require 'open3'
require 'tempfile'
require 'timeout'

class OwnerFinance::StatementParsers
  KASPI_GOLD_LINE_RE = /
    ^(\d{2}\.\d{2}\.\d{2,4})\s+
    ([+-])\s*([\d\s\u00A0]+,\d{2})\s*(?:₸|KZT)\s+
    (Поступление\s+со\s+своего\s+счета|Поступление\s+со\s+своего|Поступление\s+со|
     Перевод\s+на\s+свой\s+счет|Перевод\s+на\s+свой|Перевод\s+на|
     Зачисление\s+кредита|Зачисление|Возврат\s+покупки|Возврат|Отмена|Покупка|Перевод|Пополнение|Снятие|Разное|Комиссия)\s+
    (.+)$
  /ux

  FREEDOM_OR_GENERIC_LINE_RE = /
    ^(\d{2}\.\d{2}\.\d{4}|\d{4}-\d{2}-\d{2})\s+
    ([+-])?\s*([\d\s\u00A0]+[.,]\d{2})\s*(KZT|USD|EUR|RUB|₸|\$|€|₽)\s+
    (.+)$
  /ux

  KASPI_NOISE_PREFIXES = [
    'ао «kaspi bank»', 'ао "kaspi bank"', 'приложение к справке', 'выписка',
    'по kaspi gold', 'номер карты:', 'номер счета:', 'доступно на',
    'краткое содержание', 'пополнения', 'поступления со своих',
    'зачисления кредитов', 'переводы ', 'покупки ', 'снятия ', 'разное ',
    'дата сумма', 'лимит на снятие', 'остаток зарплатных', 'другие пополнения',
    'итого ', '- сумма заблокирована', 'сумма заблокирована', 'раздел «краткое',
    'счета» содержит'
  ].freeze

  class << self
    def extract_text(filename, raw_bytes)
      return extract_pdf_text(raw_bytes) if filename.downcase.end_with?('.pdf') || raw_bytes.start_with?('%PDF')

      decode_plain_bytes(raw_bytes)
    end

    def detect_and_parse(text)
      if text.include?('1CClientBankExchange') || text.include?('СекцияДокумент=')
        return OwnerFinance::TabularStatementParsers.parse_1c_exchange(text)
      end

      kaspi_rows = parse_kaspi_gold(text)
      return kaspi_rows if kaspi_rows.any?

      generic_rows = parse_freedom_or_generic_lines(text)
      generic_rows.any? ? generic_rows : OwnerFinance::TabularStatementParsers.parse_csv_rows(text)
    end

    def normalize_currency(raw)
      case raw.to_s.strip.upcase
      when '$', 'USD' then 'USD'
      when '€', 'EUR' then 'EUR'
      when '₽', 'RUB' then 'RUB'
      else 'KZT'
      end
    end

    def parse_decimal(raw)
      BigDecimal(raw.to_s.tr("\u00A0 ", '').gsub(/[^0-9,.-]/, '').tr(',', '.')).abs
    rescue ArgumentError
      BigDecimal(0)
    end

    def parse_date_safe(raw)
      str = raw.to_s.strip
      return nil if str.blank?
      return parse_dot_date(str) if str.match?(/\A\d{2}\.\d{2}\.\d{2,4}\z/)

      Date.parse(str)
    rescue Date::Error
      nil
    end

    private

    def extract_pdf_text(raw_bytes)
      Tempfile.create(['owner_fin_stmt_', '.pdf'], binmode: true) do |tmp|
        tmp.write(raw_bytes)
        tmp.flush
        stdout, stderr, status = Timeout.timeout(20) do
          Open3.capture3('pdftotext', '-layout', '-l', '200', tmp.path, '-')
        end
        raise ArgumentError, "Не удалось прочитать PDF: #{stderr.to_s.strip}" unless status.success?

        stdout.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      end
    rescue Timeout::Error
      raise ArgumentError, 'Превышено время разбора PDF (20 сек)'
    end

    def decode_plain_bytes(raw_bytes)
      %w[UTF-8 Windows-1251].each do |enc|
        decoded = raw_bytes.dup.force_encoding(enc).encode('UTF-8')
        return decoded.delete_prefix("\uFEFF") if decoded.valid_encoding?
      rescue EncodingError
        next
      end
      raw_bytes.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    end

    def parse_kaspi_gold(text)
      cleaned = text.sub(/Раздел\s+«Краткое\s+содержание\s+операций\s+по\s+карте»[\s\S]*?между\s+счетами\s+в\s+Kaspi\.?/im, '')
      lines = cleaned.lines.map { |ln| ln.tr("\u00A0", ' ').split.join(' ') }.reject(&:empty?)
      collect_kaspi_rows(lines)
    end

    def collect_kaspi_rows(lines)
      rows = []
      idx = 0
      while idx < lines.size
        match = KASPI_GOLD_LINE_RE.match(lines[idx])
        if match
          row, idx = consume_kaspi_entry(lines, idx, match.captures)
          rows << row if row
        else
          idx += 1
        end
      end
      rows
    end

    def consume_kaspi_entry(lines, idx, captures)
      raw_date, sign, raw_amt, oper, details = captures
      nxt_idx = idx + 1
      while nxt_idx < lines.size
        oper, details, should_continue = merge_kaspi_continuation(lines[nxt_idx], oper, details)
        break unless should_continue

        nxt_idx += 1
      end
      [build_kaspi_row(raw_date, sign, raw_amt, oper, details), nxt_idx]
    end

    def merge_kaspi_continuation(nxt, oper, details)
      return [oper, details, false] if KASPI_GOLD_LINE_RE.match?(nxt)
      return [oper, details, true] if kaspi_noise_line?(nxt)
      return expand_own_account_op(nxt, oper, details) if own_account_wrap?(oper, nxt)
      return [oper, "#{details} #{nxt}".strip, true] if nxt.start_with?('(') || nxt.include?('Курсовая разница')

      [oper, details, false]
    end

    def own_account_wrap?(oper, nxt)
      (oper == 'Поступление со' && nxt.downcase.start_with?('своего счета')) ||
        (oper == 'Перевод на' && nxt.downcase.start_with?('свой счет'))
    end

    def expand_own_account_op(nxt, oper, details)
      full_op = oper.start_with?('Поступление') ? 'Поступление со своего счета' : 'Перевод на свой счет'
      rest = nxt.sub(/\A(?:своего счета|свой счет)/i, '').strip
      merged = rest.present? ? "#{details} #{rest}".strip : details
      [full_op, merged, true]
    end

    def build_kaspi_row(raw_date, sign, raw_amt, oper, details)
      occurred_on = parse_date_safe(raw_date)
      amount = parse_decimal(raw_amt)
      return nil unless occurred_on && amount.positive?

      {
        source_type: 'kaspi_gold_pdf', official_status: 'management', is_personal_card: true,
        occurred_on: occurred_on, direction: sign == '+' ? 'income' : 'expense',
        amount: amount, currency: 'KZT', merchant: details.strip.slice(0, 140),
        description: "#{oper}: #{details}".strip
      }
    end

    def parse_freedom_or_generic_lines(text)
      text.lines.filter_map do |raw|
        match = FREEDOM_OR_GENERIC_LINE_RE.match(raw.tr("\u00A0", ' ').split.join(' '))
        build_generic_pdf_row(match.captures) if match
      end
    end

    def build_generic_pdf_row(captures)
      raw_date, sign, raw_amt, raw_cur, details = captures
      occurred_on = parse_date_safe(raw_date)
      amount = parse_decimal(raw_amt)
      return nil unless occurred_on && amount.positive?

      {
        source_type: 'card_pdf', official_status: 'management', is_personal_card: true,
        occurred_on: occurred_on, direction: sign == '+' ? 'income' : 'expense',
        amount: amount, currency: normalize_currency(raw_cur),
        merchant: details.strip.slice(0, 140), description: details.strip
      }
    end

    def kaspi_noise_line?(line)
      low = line.strip.downcase
      return true if low.empty? || low.match?(/^--\s*\d+\s+of\s+\d+\s*--$/) || low.match?(/^\d+\s+(?:из|of)\s+\d+$/)

      KASPI_NOISE_PREFIXES.any? { |prefix| low.start_with?(prefix) }
    end

    def parse_dot_date(str)
      day, mon, year = str.split('.')
      yr = year.length == 2 ? 2000 + year.to_i : year.to_i
      Date.new(yr, mon.to_i, day.to_i)
    end
  end
end
