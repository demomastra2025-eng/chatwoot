# frozen_string_literal: true

class OwnerFinance::DashboardQueryService
  CATEGORY_LABELS_RU = OwnerFinance::RecordSerializer::CATEGORY_LABELS_RU
  PAYABLE_KINDS = %w[medelement_commission payable_debt partner_settlement].freeze
  OUTFLOW_PAYER_MODES = %w[us rebill_client].freeze
  INFLOW_PAYER_MODES = %w[incoming_milestone rebill_client].freeze

  def initialize(year: nil, month: nil, reference_date: nil)
    @reference_date = reference_date || OwnerFinance.today_almaty
    @year = (year.presence || @reference_date.year).to_i.clamp(2000, 2100)
    @month = (month.present? ? month.to_i : @reference_date.month).clamp(0, 12)
  end

  def perform
    collections = load_collections
    period_range = build_period_range
    period_pnl_tx = OwnerFinance::TransactionRecord.in_pnl.where(occurred_on: period_range)

    build_payload(collections, period_range, period_pnl_tx)
  end

  private

  def load_collections
    {
      accounts: OwnerFinance::AccountRecord.active.order(:scope, :id).to_a,
      deadlines: OwnerFinance::Deadline.where.not(status: 'archived').order(:due_on, :id).to_a,
      contracts: OwnerFinance::Contract.where.not(status: 'archived').order(status: :asc, monthly_amount: :desc, id: :desc).to_a,
      obligations: OwnerFinance::Obligation.where.not(status: 'cancelled').order(:status, :due_on, :id).to_a
    }
  end

  def build_payload(col, period_range, period_pnl_tx)
    {
      period: { year: @year, month: @month, reference_date: @reference_date.iso8601 },
      kpis: compute_kpis(col, period_pnl_tx),
      accounts: col[:accounts].map { |acc| OwnerFinance::RecordSerializer.account(acc) },
      deadlines: col[:deadlines].map { |item| OwnerFinance::RecordSerializer.deadline(item, @reference_date) },
      contracts: serialized_contracts(col[:contracts]),
      needs_review_transactions: serialized_needs_review,
      transactions: serialized_confirmed(period_range),
      obligations: col[:obligations].map { |item| OwnerFinance::RecordSerializer.obligation(item) },
      expense_breakdown: build_expense_breakdown(period_pnl_tx),
      monthly_series: build_monthly_series,
      category_options: CATEGORY_LABELS_RU.map { |code, label| { code: code, label: label } },
      sync_states: serialized_sync_states
    }
  end

  def serialized_contracts(contracts)
    onelink_map = load_onelink_accounts_map(contracts)
    contracts.map { |item| OwnerFinance::RecordSerializer.contract(item, onelink_map[item.onelink_account_id]) }
  end

  def compute_kpis(col, period_pnl_tx)
    pnl = compute_period_pnl(period_pnl_tx)
    cash = compute_cash_horizon(col)
    radar = compute_radar_counts(col[:deadlines])
    pnl.merge(cash).merge(radar).merge(
      needs_review_count: OwnerFinance::TransactionRecord.needs_review.count,
      hidden_personal_count: OwnerFinance::PersonalTombstone.count
    )
  end

  def compute_period_pnl(period_pnl_tx)
    revenue = period_pnl_tx.where(direction: 'income', pnl_treatment: 'pnl').sum(:amount_kzt).to_d
    expenses = period_pnl_tx.where(direction: 'expense', pnl_treatment: 'pnl').sum(:amount_kzt).to_d
    refunds = period_pnl_tx.where(pnl_treatment: 'expense_refund').sum(:amount_kzt).to_d
    net_exp = [expenses - refunds, BigDecimal(0)].max
    {
      month_revenue_kzt: revenue.to_f,
      month_expenses_kzt: net_exp.to_f,
      month_net_profit_kzt: (revenue - net_exp).to_f
    }
  end

  def compute_cash_horizon(col)
    total_bal = col[:accounts].select { |acc| acc.scope == 'business' }.sum(&:balance_kzt).to_d
    committed = committed_outflow_30d(col[:deadlines], col[:obligations])
    mrr = col[:contracts].select { |con| %w[active signed].include?(con.status) }.sum(&:monthly_amount_kzt).to_d
    inflow = mrr + expected_extra_inflow_30d(col[:deadlines], col[:obligations])
    {
      total_balance_kzt: total_bal.to_f, committed_outflow_30d_kzt: committed.to_f,
      free_cash_kzt: (total_bal - committed).to_f, expected_inflow_30d_kzt: inflow.to_f,
      live_contracts_mrr_kzt: mrr.to_f
    }
  end

  def committed_outflow_30d(deadlines, obligations)
    horizon_end = @reference_date + 31.days
    deadline_sum_within(deadlines, horizon_end, OUTFLOW_PAYER_MODES) +
      payable_obligation_sum_within(obligations, horizon_end)
  end

  def deadline_sum_within(deadlines, horizon_end, payer_modes)
    deadlines.select do |item|
      item.status == 'active' && item.due_on <= horizon_end && payer_modes.include?(item.payer_mode)
    end.sum(&:amount_kzt).to_d
  end

  def payable_obligation_sum_within(obligations, horizon_end)
    obligations.select do |item|
      item.status == 'open' && PAYABLE_KINDS.include?(item.entry_kind) && (item.due_on.nil? || item.due_on <= horizon_end)
    end.sum(&:outstanding_kzt).to_d
  end

  def expected_extra_inflow_30d(deadlines, obligations)
    horizon_end = @reference_date + 31.days
    receivables = obligations.select { |item| item.status == 'open' && item.entry_kind == 'receivable_debt' }
    deadline_sum_within(deadlines, horizon_end, INFLOW_PAYER_MODES) + receivables.sum(&:outstanding_kzt).to_d
  end

  def compute_radar_counts(deadlines)
    urgent = deadlines.select { |item| item.status == 'active' && item.days_left(@reference_date) <= 14 }
    rebill = urgent.select { |item| item.payer_mode == 'rebill_client' }
    {
      urgent_deadlines_count: urgent.size,
      rebill_soon_count: rebill.size,
      rebill_soon_kzt: rebill.sum(&:amount_kzt).to_f
    }
  end

  def serialized_needs_review
    OwnerFinance::TransactionRecord.needs_review.order(occurred_on: :desc, id: :desc).limit(100).map do |item|
      OwnerFinance::RecordSerializer.transaction(item)
    end
  end

  def serialized_confirmed(period_range)
    OwnerFinance::TransactionRecord.confirmed.where(occurred_on: period_range).order(occurred_on: :desc, id: :desc).limit(250).map do |item|
      OwnerFinance::RecordSerializer.transaction(item)
    end
  end

  def serialized_sync_states
    OwnerFinance::SyncState.all.each_with_object({}) do |state, acc|
      acc[state.sync_key] = {
        status: state.sync_status,
        last_synced_at: state.last_synced_at&.iso8601,
        summary: state.summary
      }
    end
  end

  def build_period_range
    return Date.new(@year, 1, 1)..Date.new(@year, 12, 31) if @month.zero?

    start_date = Date.new(@year, @month, 1)
    start_date..start_date.end_of_month
  end

  def load_onelink_accounts_map(contracts)
    ids = contracts.filter_map(&:onelink_account_id).uniq
    ids.empty? ? {} : Account.where(id: ids).index_by(&:id)
  end

  def build_expense_breakdown(period_pnl_tx)
    gross = period_pnl_tx.where(direction: 'expense', pnl_treatment: 'pnl').group(:category).sum(:amount_kzt)
    refunds = period_pnl_tx.where(pnl_treatment: 'expense_refund').group(:category).sum(:amount_kzt)
    items = gross.filter_map do |cat, sum|
      net = sum.to_d - (refunds[cat] || 0).to_d
      { category: cat, label: CATEGORY_LABELS_RU.fetch(cat, cat), amount_kzt: net.to_f } if net.positive?
    end
    items.sort_by { |item| -item[:amount_kzt] }
  end

  def build_monthly_series
    year_range = Date.new(@year, 1, 1)..Date.new(@year, 12, 31)
    rows = OwnerFinance::TransactionRecord
           .in_pnl
           .where(occurred_on: year_range)
           .group('EXTRACT(MONTH FROM occurred_on)::int', :direction, :pnl_treatment)
           .sum(:amount_kzt)
    (1..12).map { |mon| build_month_point(rows, mon) }
  end

  def build_month_point(rows, mon)
    rev = (rows[[mon, 'income', 'pnl']] || 0).to_d
    gross_exp = (rows[[mon, 'expense', 'pnl']] || 0).to_d
    refunds = (rows[[mon, 'income', 'expense_refund']] || 0).to_d + (rows[[mon, 'expense', 'expense_refund']] || 0).to_d
    exp = [gross_exp - refunds, BigDecimal(0)].max
    { month: mon, revenue_kzt: rev.to_f, expenses_kzt: exp.to_f, net_profit_kzt: (rev - exp).to_f }
  end
end
