# frozen_string_literal: true

class OwnerFinance::CeoMetricsBuilder
  PAYABLE_KINDS = %w[medelement_commission payable_debt partner_settlement].freeze
  OUTFLOW_PAYER_MODES = %w[us rebill_client].freeze
  INFLOW_PAYER_MODES = %w[incoming_milestone rebill_client].freeze
  FIXED_EXPENSE_CATEGORIES = %w[servers_and_cloud telephony accounting_and_software payroll_and_contractors office_and_ops].freeze

  def initialize(col:, period_range:, reference_date:, month:, confirmed_scope:)
    @col = col
    @period_range = period_range
    @reference_date = reference_date
    @month = month
    @confirmed_scope = confirmed_scope
  end

  def build_kpis(pnl:, cash:, exp_breakdown:, series_12m:)
    rev = pnl[:month_revenue_kzt].to_d
    profit = pnl[:month_net_profit_kzt].to_d
    plan_metrics(rev, profit, cash[:live_contracts_mrr_kzt].to_d, series_12m)
      .merge(break_even_metrics(rev, exp_breakdown))
      .merge(balance_and_payroll_metrics(rev, cash[:total_balance_kzt].to_d, exp_breakdown))
      .merge(cashflow_metrics(cash))
  end

  def build_summary(kpis_data:, exp_breakdown:)
    rev = kpis_data[:month_revenue_kzt].to_d
    total_exp = kpis_data[:month_expenses_kzt].to_d
    {
      top_5_expenses: build_top5_expenses(exp_breakdown, total_exp, rev),
      cash_gap_radar: compute_cash_gap_radar(kpis_data[:total_balance_kzt].to_d)
    }
  end

  private

  def plan_metrics(rev, profit, mrr, series_12m)
    plan_rev = (@month.zero? ? (mrr * 12) : mrr) + milestones_in_period
    {
      revenue_plan_kzt: plan_rev.to_f,
      revenue_plan_pct: pct_of(rev, plan_rev),
      net_margin_pct: pct_of(profit, rev),
      revenue_mom_pct: compute_mom_pct(rev, series_12m)
    }
  end

  def milestones_in_period
    @col[:deadlines].select do |d|
      d.status == 'active' && @period_range.cover?(d.due_on) && INFLOW_PAYER_MODES.include?(d.payer_mode)
    end.sum(&:amount_kzt).to_d
  end

  def compute_mom_pct(rev, series_12m)
    return nil unless @month > 1

    prev_rev = series_12m.find { |m| m[:month] == @month - 1 }&.dig(:revenue_kzt).to_d
    prev_rev.positive? ? (((rev - prev_rev) / prev_rev) * 100).round(1).to_f : nil
  end

  def break_even_metrics(rev, exp_breakdown)
    break_even = [fixed_expense_sum(exp_breakdown), monthly_us_deadlines_sum].max
    {
      break_even_kzt: break_even.to_f,
      break_even_passed: rev >= break_even && break_even.positive?,
      break_even_delta_kzt: (rev - break_even).to_f
    }
  end

  def fixed_expense_sum(exp_breakdown)
    exp_breakdown.select { |i| FIXED_EXPENSE_CATEGORIES.include?(i[:category]) }.sum { |i| i[:amount_kzt].to_d }
  end

  def monthly_us_deadlines_sum
    @col[:deadlines].select { |d| d.status == 'active' && d.payer_mode == 'us' && d.recurrence == 'monthly' }.sum(&:amount_kzt).to_d
  end

  def balance_and_payroll_metrics(rev, cash_bal, exp_breakdown)
    receivables = open_obligations_sum(%w[receivable_debt])
    payables = open_obligations_sum(PAYABLE_KINDS)
    assets = cash_bal + receivables
    payroll = exp_breakdown.find { |i| i[:category] == 'payroll_and_contractors' }&.dig(:amount_kzt).to_d
    {
      accounts_receivable_kzt: receivables.to_f,
      accounts_payable_kzt: payables.to_f,
      total_assets_kzt: assets.to_f,
      net_working_capital_kzt: (assets - payables).to_f,
      payroll_kzt: payroll.to_f,
      payroll_share_pct: pct_of(payroll, rev)
    }
  end

  def open_obligations_sum(kinds, on_day: nil)
    @col[:obligations].select do |o|
      o.status == 'open' && kinds.include?(o.entry_kind) && (on_day.nil? || o.due_on == on_day)
    end.sum(&:outstanding_kzt).to_d
  end

  def active_deadlines_sum(modes, on_day)
    @col[:deadlines].select do |d|
      d.status == 'active' && d.due_on == on_day && modes.include?(d.payer_mode)
    end.sum(&:amount_kzt).to_d
  end

  def cashflow_metrics(cash)
    cash_in = @confirmed_scope.where(direction: 'income').where.not(pnl_treatment: 'transfer').sum(:amount_kzt).to_d
    cash_out = @confirmed_scope.where(direction: 'expense').where.not(pnl_treatment: 'transfer').sum(:amount_kzt).to_d
    proj = cash[:total_balance_kzt].to_d + cash[:expected_inflow_30d_kzt].to_d - cash[:committed_outflow_30d_kzt].to_d
    {
      net_cashflow_kzt: (cash_in - cash_out).to_f,
      cash_inflow_period_kzt: cash_in.to_f,
      cash_outflow_period_kzt: cash_out.to_f,
      projected_balance_30d_kzt: proj.to_f
    }
  end

  def build_top5_expenses(exp_breakdown, total_exp, rev)
    exp_breakdown.first(5).map do |item|
      amt = item[:amount_kzt].to_d
      item.merge(
        share_of_expenses_pct: pct_of(amt, total_exp),
        share_of_revenue_pct: pct_of(amt, rev)
      )
    end
  end

  def compute_cash_gap_radar(starting_balance)
    state = { running: starting_balance, min_bal: starting_balance, min_date: @reference_date, gap_date: nil, gap_amt: 0.0 }
    (0..30).each { |offset| step_cash_gap_day!(state, @reference_date + offset.days) }
    {
      has_gap: state[:gap_date].present?,
      first_gap_date: state[:gap_date],
      first_gap_kzt: state[:gap_amt],
      min_balance_30d_kzt: state[:min_bal].to_f,
      min_balance_date: state[:min_date].iso8601,
      ending_balance_30d_kzt: state[:running].to_f
    }
  end

  def step_cash_gap_day!(state, day)
    state[:running] += daily_inflow(day) - daily_outflow(day)
    if state[:running] < state[:min_bal]
      state[:min_bal] = state[:running]
      state[:min_date] = day
    end
    return unless state[:running].negative? && state[:gap_date].nil?

    state[:gap_date] = day.iso8601
    state[:gap_amt] = state[:running].to_f
  end

  def daily_outflow(day)
    active_deadlines_sum(OUTFLOW_PAYER_MODES, day) + open_obligations_sum(PAYABLE_KINDS, on_day: day)
  end

  def daily_inflow(day)
    active_deadlines_sum(INFLOW_PAYER_MODES, day) +
      open_obligations_sum(%w[receivable_debt], on_day: day) +
      contracts_billing_on(day)
  end

  def contracts_billing_on(day)
    @col[:contracts].select { |c| %w[active signed].include?(c.status) && c.billing_day.to_i == day.day }.sum(&:monthly_amount_kzt).to_d
  end

  def pct_of(part, total)
    total.positive? ? ((part / total) * 100).round(1).to_f : 0.0
  end
end
