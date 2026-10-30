# frozen_string_literal: true

class OwnerFinance::SupabaseLedgerRowMappers
  VALID_PNL_TREATMENTS = %w[pnl non_pnl expense_refund].freeze
  PAID_DEBT_STATUSES = %w[paid closed settled annulled].freeze
  CATEGORY_MAP = {
    'saas_subscription_income' => 'client_subscription',
    'project_income' => 'client_delivery',
    'unclassified_business_income' => 'client_delivery',
    'hosting_server' => 'servers_and_cloud',
    'hosting_servers' => 'servers_and_cloud',
    'infrastructure_hosting' => 'servers_and_cloud',
    'domain_one_link' => 'servers_and_cloud',
    'hosting_expense_refund' => 'servers_and_cloud',
    'software_ai' => 'ai_and_llm',
    'software_ai_subscriptions' => 'ai_and_llm',
    'sip_telephony' => 'telephony',
    'communications_calls' => 'telephony',
    'partner_commission' => 'partner_commissions',
    'taxes_social_contributions' => 'taxes_and_fees',
    'taxes_and_mandatory_payments' => 'taxes_and_fees',
    'bank_service_fee' => 'taxes_and_fees',
    'bank_fee' => 'taxes_and_fees',
    'employee_insurance_osrns' => 'taxes_and_fees',
    'software_subscription' => 'accounting_and_software',
    'software_crm' => 'accounting_and_software',
    'cloud_software_service' => 'accounting_and_software',
    'software_services' => 'accounting_and_software',
    'accounting_services' => 'accounting_and_software',
    'software_expense_refund' => 'accounting_and_software',
    'marketing_and_ads' => 'marketing',
    'owner_accountable_transfer' => 'accountable_transfer',
    'internal_bank_transfer' => 'accountable_transfer',
    'internal_transfer' => 'accountable_transfer',
    'partner_withdrawal' => 'accountable_transfer',
    'partner_settlement' => 'accountable_transfer',
    'employee_salary_offset' => 'payroll_and_contractors'
  }.freeze

  class << self
    def transaction_attrs(row, account_id_map, cp_id_map, contract_id_map)
      cur = OwnerFinance::SupabaseRowMappers.normalize_cur(row['currency'])
      amt = BigDecimal((row['amount'] || 0).to_s).abs
      meta = OwnerFinance::SupabaseRowMappers.parse_json(row['metadata'])
      transaction_classification_attrs(row).merge(
        amount: amt, currency: cur, amount_kzt: OwnerFinance.to_kzt(amt, cur),
        account_record_id: account_id_map[row['account_id'].to_s],
        counterparty_id: cp_id_map[row['counterparty_id'].to_s],
        contract_id: contract_id_map[row['contract_id'].to_s],
        row_fingerprint_sha256: meta['row_fingerprint_sha256'].presence
      )
    end

    def commission_obligation_attrs(row, contract_id_map)
      meta = OwnerFinance::SupabaseRowMappers.parse_json(row['metadata'])
      {
        entry_kind: 'medelement_commission',
        title: "МИС МедЭлемент 30% (#{row['period_label'].presence || 'период'})",
        counterparty_name: row['cp_name'].presence || 'МИС МедЭлемент',
        contract_id: contract_id_map[row['contract_id'].to_s], period_label: row['period_label'],
        status: row['status'] == 'paid' ? 'paid' : 'open', notes: row['notes'], metadata: meta
      }.merge(commission_amounts(row, meta))
    end

    def debt_obligation_attrs(row, contract_id_map)
      amt = BigDecimal((row['principal_amount'] || 0).to_s).abs
      paid = PAID_DEBT_STATUSES.include?(row['status'].to_s)
      {
        entry_kind: classify_debt_kind(row),
        title: (row['description'].presence || row['cp_name'].presence || "Обязательство ##{row['id']}").strip.slice(0, 160),
        counterparty_name: row['cp_name'], contract_id: contract_id_map[row['contract_id'].to_s],
        amount: amt, paid_amount: paid ? amt : 0, currency: OwnerFinance::SupabaseRowMappers.normalize_cur(row['currency']),
        due_on: OwnerFinance::SupabaseRowMappers.parse_date(row['due_at']), status: paid ? 'paid' : 'open', notes: row['description']
      }
    end

    private

    def transaction_classification_attrs(row)
      pnl = VALID_PNL_TREATMENTS.include?(row['pnl_treatment']) ? row['pnl_treatment'] : 'pnl'
      official = %w[official official_1c].include?(row['official_status']) ? 'official_1c' : 'management'
      {
        occurred_on: OwnerFinance::SupabaseRowMappers.parse_date(row['occurred_at']) || OwnerFinance.today_almaty,
        direction: map_direction(row['direction'], pnl), pnl_treatment: pnl, official_status: official,
        review_status: 'confirmed', category: CATEGORY_MAP.fetch(row['category'].to_s, 'office_and_ops'),
        merchant: extract_merchant(row), description: row['description']
      }
    end

    def map_direction(raw_dir, pnl)
      return 'income' if raw_dir == 'income' || pnl == 'expense_refund'
      return 'transfer' if raw_dir.to_s.start_with?('transfer')

      'expense'
    end

    def extract_merchant(row)
      first_line = row['description'].to_s.lines.first.to_s.strip.presence
      (row['cp_name'].presence || first_line || "Операция ##{row['id']}").strip.slice(0, 140)
    end

    def commission_amounts(row, meta)
      {
        base_amount: BigDecimal((meta['commission_base_amount'] || row['source_amount'] || 0).to_s),
        overage_excluded_amount: BigDecimal((meta['excluded_non_base_amount'] || 0).to_s),
        amount: BigDecimal((row['accrued_amount'] || 0).to_s).abs,
        paid_amount: BigDecimal((row['paid_amount'] || 0).to_s).abs,
        currency: OwnerFinance::SupabaseRowMappers.normalize_cur(row['currency']),
        due_on: OwnerFinance::SupabaseRowMappers.parse_date(row['due_at']),
        paid_on: OwnerFinance::SupabaseRowMappers.parse_date(row['paid_at'])
      }
    end

    def classify_debt_kind(row)
      return 'partner_settlement' if row['debt_type'] == 'partner_commission_payable' || row['cp_name'].to_s.match?(/ахан|жандаулет|асет/i)

      row['debt_type'].to_s.match?(/receivable|owed_to_us|loan_given/i) ? 'receivable_debt' : 'payable_debt'
    end
  end
end
