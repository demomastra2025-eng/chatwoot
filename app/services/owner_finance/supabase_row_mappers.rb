# frozen_string_literal: true

require 'json'

class OwnerFinance::SupabaseRowMappers
  ACTIVE_DEADLINE_STATUSES = %w[active upcoming overdue due_soon].freeze
  CONTRACT_STATUS_MAP = {
    'active' => 'active', 'signed' => 'signed',
    'under_termination' => 'under_termination', 'performed' => 'performed'
  }.freeze

  class << self
    def account_attrs(row)
      bal = [BigDecimal(row['computed_balance'].to_s), BigDecimal(0)].max
      kind = row['account_type'] == 'cash' ? 'cash' : 'business_bank'
      {
        name: row['name'], account_kind: kind, scope: 'business',
        currency: normalize_cur(row['currency']), current_balance: bal,
        active: row['is_active'] != 'f', notes: row['notes']
      }
    end

    def contract_attrs(row, cp_id_map)
      meta = parse_json(row['metadata'])
      monthly_amt, one_time_amt = resolve_contract_amounts(row, meta)
      contract_identity_attrs(row, cp_id_map, meta).merge(
        tariff_code: infer_tariff_code(monthly_amt, monthly_amt.zero?),
        monthly_amount: monthly_amt, one_time_amount: one_time_amt,
        currency: normalize_cur(row['currency']), starts_on: parse_date(row['starts_at']),
        ends_on: parse_date(row['ends_at']), medelement_commission_enabled: medelement_contract?(row, meta),
        medelement_commission_rate: BigDecimal((row['commission_expected_rate'].presence || '0.30').to_s),
        notes: [row['payment_terms'], row['notes']].compact_blank.join("\n")
      )
    end

    def external_deadline_attrs(row, due_on)
      meta = parse_json(row['metadata'])
      cat, payer = classify_external_deadline(row, meta)
      {
        title: external_deadline_title(row), category: cat, payer_mode: payer,
        provider: row['provider'], related_domain: row['related_domain'],
        due_on: due_on, amount: BigDecimal((row['amount'] || 0).to_s),
        currency: normalize_cur(row['currency']), recurrence: map_recurrence(meta['billing_cycle']),
        status: map_external_deadline_status(row['status']), notes: meta['source_note']
      }
    end

    def recurring_deadline_attrs(row, cp_id_map, contract_id_map, due_on)
      inflow = row['category'].to_s.match?(/inflow|receivable|income/i)
      active = ACTIVE_DEADLINE_STATUSES.include?(row['status'].to_s)
      {
        title: row['name'].presence || "Обязательство ##{row['id']}",
        category: inflow ? 'contract' : 'hosting', payer_mode: inflow ? 'incoming_milestone' : 'us',
        client_name: row['cp_name'], counterparty_id: cp_id_map[row['counterparty_id'].to_s],
        contract_id: contract_id_map[row['contract_id'].to_s], due_on: due_on,
        amount: BigDecimal((row['amount'] || 0).to_s), currency: normalize_cur(row['currency']),
        recurrence: map_recurrence(row['frequency']), status: active ? 'active' : 'archived', notes: row['notes']
      }
    end

    def map_cp_kind(raw)
      return 'client' if raw.to_s.match?(/client|customer/i)
      return 'partner' if raw.to_s.match?(/partner/i)
      return 'tax' if raw.to_s.match?(/tax|gov/i)

      raw.to_s.match?(/vendor|supplier/i) ? 'vendor' : 'other'
    end

    def normalize_cur(val) = (val.presence || 'KZT').to_s.upcase

    def parse_date(val)
      val.present? ? Date.parse(val.to_s) : nil
    rescue Date::Error
      nil
    end

    def parse_time(val)
      val.present? ? Time.zone.parse(val.to_s) || Time.current : Time.current
    rescue ArgumentError
      Time.current
    end

    def parse_json(val)
      val.present? ? JSON.parse(val.to_s) : {}
    rescue JSON::ParserError
      {}
    end

    private

    def resolve_contract_amounts(row, meta)
      meta_monthly = extract_meta_monthly(meta)
      raw_amt = BigDecimal((row['amount'] || 0).to_s)
      return [meta_monthly, BigDecimal(0)] if meta_monthly.positive?
      return [raw_amt, BigDecimal(0)] if monthly_contract?(row, meta)

      [BigDecimal(0), raw_amt]
    end

    def extract_meta_monthly(meta)
      BigDecimal((meta['monthly_amount'] || meta['monthly_subscription_kzt'] || 0).to_s)
    end

    def monthly_contract?(row, meta)
      meta['monthly'] == true || row['payment_terms'].to_s.match?(/в месяц|ежемесяч/i)
    end

    def contract_identity_attrs(row, cp_id_map, meta)
      num = row['contract_number'].presence || meta['onec_description'].presence
      {
        counterparty_id: cp_id_map[row['counterparty_id'].to_s],
        client_name: row['client_name'].presence || row['title'].presence || "Клиент ##{row['id']}",
        contract_number: num, title: row['title'].presence || 'Договор OneLink',
        status: CONTRACT_STATUS_MAP.fetch(row['status'].to_s, 'archived')
      }
    end

    def medelement_contract?(row, meta)
      row['commission_applicability'] == 'required' || meta['medelement_commission'].to_s == 'true'
    end

    def external_deadline_title(row)
      base = row['service_name'].presence || row['related_domain'].presence || "Срок ##{row['id']}"
      row['provider'].present? && base.downcase.exclude?(row['provider'].downcase) ? "#{base} (#{row['provider']})" : base
    end

    def map_external_deadline_status(raw_status)
      return 'archived' if %w[removed archived cancelled superseded].include?(raw_status.to_s)

      ACTIVE_DEADLINE_STATUSES.include?(raw_status.to_s) ? 'active' : 'completed'
    end

    def classify_external_deadline(row, meta)
      cat = domain_or_hosting_category(row)
      [cat, resolve_payer_mode(meta['payer_type'], cat)]
    end

    def domain_or_hosting_category(row)
      is_dom = row['service_type'].to_s.include?('domain') || row['related_domain'].present?
      return 'hosting' unless is_dom

      row['related_domain'].to_s.match?(/one-link|onelink|vconsult|veritas/i) ? 'own_domain' : 'client_domain'
    end

    def resolve_payer_mode(payer_type, cat)
      return 'rebill_client' if payer_type.to_s.match?(/rebill|reimburse|client_reimburse/i)
      return 'client_direct' if payer_type.to_s.match?(/client_direct|client/i)

      cat == 'client_domain' ? 'rebill_client' : 'us'
    end

    def map_recurrence(raw)
      return 'monthly' if raw.to_s.match?(/month/i)
      return 'quarterly' if raw.to_s.match?(/quarter/i)

      raw.to_s.match?(/once|one_time/i) ? 'once' : 'yearly'
    end

    def infer_tariff_code(amt, is_one_time)
      return 'custom' if is_one_time

      case amt.to_i
      when 85_000..105_000 then 'text_voice_99k'
      when 155_000..210_000 then 'ai_agent_rop_199k'
      when 335_000..420_000 then 'voice_ai_399k'
      else 'custom'
      end
    end
  end
end
