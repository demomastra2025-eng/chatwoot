class Crm::Reports::ManagerEffectivenessService
  DEFAULT_CURRENCY = 'KZT'.freeze
  DEFAULT_CALL_DURATION_THRESHOLD_SECONDS = 25

  attr_reader :account, :params, :since_time, :until_time, :currency,
              :pipeline_id, :call_duration_threshold_seconds

  def initialize(account:, params: {})
    @account = account
    @params = params.to_h.symbolize_keys
    @since_time = parse_time(@params[:since]) || 30.days.ago.beginning_of_day
    @until_time = parse_time(@params[:until]) || Time.current.end_of_day
    @currency = @params[:currency].presence || dominant_currency || DEFAULT_CURRENCY
    @pipeline_id = @params[:pipeline_id].presence
    @call_duration_threshold_seconds = positive_integer(
      @params[:call_duration_threshold_seconds],
      DEFAULT_CALL_DURATION_THRESHOLD_SECONDS
    )
  end

  def perform
    rows = manager_rows

    {
      rows: rows,
      totals: totals_for(rows)
    }
  end

  def meta
    {
      since: since_time.iso8601,
      until: until_time.iso8601,
      currency: currency,
      pipeline_id: pipeline_id,
      call_duration_threshold_seconds: call_duration_threshold_seconds,
      data_sources: data_sources
    }
  end

  private

  def parse_time(value)
    return if value.blank?

    if value.to_s.match?(/\A\d+\z/)
      Time.zone.at(value.to_i)
    else
      Time.zone.parse(value.to_s)
    end
  rescue ArgumentError, TypeError
    nil
  end

  def positive_integer(value, fallback)
    parsed = value.to_i
    parsed.positive? ? parsed : fallback
  end

  def dominant_currency
    account.crm_deals
           .where.not(currency: [nil, ''])
           .group(:currency)
           .order(Arel.sql('COUNT(*) DESC'))
           .limit(1)
           .pick(:currency)
  end

  def data_sources
    {
      leads: 'dialog-linked crm_deals.created_at',
      bad_leads: 'dialog-linked crm_stages.outcome=lost',
      calls: 'telephony_call_sessions.agent_binding_id',
      meetings: 'scheduling_appointments.owner_id + crm_tasks.activity_type=meeting fallback',
      payments: 'scheduling_payments by appointment owner',
      trade_in: 'not_configured'
    }
  end

  def manager_rows
    stats = Hash.new { |hash, owner_id| hash[owner_id] = base_stats(owner_id) }

    merge_deal_stats!(stats)
    merge_call_stats!(stats)
    merge_appointment_stats!(stats)
    merge_task_meeting_stats!(stats)
    merge_payment_stats!(stats)

    owner_names = owner_names_for(stats.keys.compact)

    stats.each_value do |row|
      row[:owner_name] = owner_names[row[:owner_id]]
      calculate_derived_metrics!(row)
    end

    stats.values.sort_by do |row|
      [-row[:leads_count].to_i, -row[:won_amount_minor].to_i, row[:owner_name].to_s]
    end
  end

  def base_stats(owner_id)
    {
      owner_id: owner_id,
      owner_name: nil,
      leads_count: 0,
      open_count: 0,
      bad_count: 0,
      won_count: 0,
      deal_amount_minor: 0,
      won_amount_minor: 0,
      call_attempts_count: 0,
      connected_calls_count: 0,
      long_calls_count: 0,
      appointments_count: 0,
      completed_appointments_count: 0,
      cancelled_appointments_count: 0,
      no_show_appointments_count: 0,
      meeting_tasks_count: 0,
      meetings_count: 0,
      payments_amount_minor: 0,
      cash_amount_minor: 0,
      non_cash_amount_minor: 0,
      trade_in_amount_minor: 0,
      other_amount_minor: 0
    }
  end

  def merge_deal_stats!(stats)
    period_deals_scope
      .group(:owner_id)
      .pluck(
        :owner_id,
        Arel.sql('COUNT(*)'),
        outcome_count_sql('open'),
        outcome_count_sql('won'),
        outcome_count_sql('lost'),
        currency_amount_sum_sql,
        outcome_currency_amount_sum_sql('won')
      ).each do |owner_id, count, open_count, won_count, lost_count, amount, won_amount|
        row = stats[owner_id]
        row[:leads_count] = count.to_i
        row[:open_count] = open_count.to_i
        row[:bad_count] = lost_count.to_i
        row[:won_count] = won_count.to_i
        row[:deal_amount_minor] = amount.to_i
        row[:won_amount_minor] = won_amount.to_i
      end
  end

  def merge_call_stats!(stats)
    call_scope
      .group('telephony_agent_bindings.user_id')
      .pluck(
        Arel.sql('telephony_agent_bindings.user_id'),
        Arel.sql('COUNT(*)'),
        connected_call_count_sql,
        long_call_count_sql
      ).each do |owner_id, attempts_count, connected_count, long_count|
        row = stats[owner_id]
        row[:call_attempts_count] = attempts_count.to_i
        row[:connected_calls_count] = connected_count.to_i
        row[:long_calls_count] = long_count.to_i
      end
  end

  def merge_appointment_stats!(stats)
    appointment_scope.group(:owner_id, :status).count.each do |(owner_id, status), count|
      row = stats[owner_id]
      row[:appointments_count] += count.to_i

      case status
      when 'completed'
        row[:completed_appointments_count] += count.to_i
      when 'cancelled'
        row[:cancelled_appointments_count] += count.to_i
      when 'no_show'
        row[:no_show_appointments_count] += count.to_i
      end
    end
  end

  def merge_task_meeting_stats!(stats)
    return unless crm_task_meeting_source_available?

    crm_task_meeting_scope.group(:assignee_id).count.each do |owner_id, count|
      stats[owner_id][:meeting_tasks_count] += count.to_i
    end
  end

  def merge_payment_stats!(stats)
    payment_scope.group(payment_owner_sql, :payment_method).sum(:amount).each do |(owner_id, payment_method), amount|
      row = stats[owner_id]
      amount_minor = amount.to_i
      row[:payments_amount_minor] += amount_minor
      row["#{payment_category(payment_method)}_amount_minor".to_sym] += amount_minor
    end
  end

  def deals_scope
    scope = account.crm_deals.kept.joins(:stage)
    scope = scope.where(pipeline_id: pipeline_id) if pipeline_id.present?
    scope
  end

  def period_deals_scope
    dialog_linked_deals_scope.where(created_at: since_time..until_time)
  end

  def dialog_linked_deals_scope
    deals_scope.where(
      'crm_deals.originating_conversation_id IS NOT NULL OR crm_deals.originating_communication_thread_id IS NOT NULL'
    )
  end

  def call_scope
    Telephony::CallSession
      .joins(:agent_binding)
      .where(account_id: account.id, direction: 'outbound')
      .where(telephony_agent_bindings: { account_id: account.id })
      .where('COALESCE(telephony_call_sessions.started_at, telephony_call_sessions.created_at) BETWEEN ? AND ?', since_time, until_time)
  end

  def appointment_scope
    Scheduling::Appointment.where(account_id: account.id, starts_at: since_time..until_time)
  end

  def crm_task_meeting_scope
    Crm::Task
      .kept
      .where(account_id: account.id, activity_type: 'meeting')
      .where('COALESCE(crm_tasks.due_at, crm_tasks.start_at, crm_tasks.created_at) BETWEEN ? AND ?', since_time, until_time)
  end

  def payment_scope
    Scheduling::Payment
      .joins(:appointment)
      .where(account_id: account.id, created_at: since_time..until_time)
      .where(scheduling_appointments: { account_id: account.id })
  end

  def payment_owner_sql
    Arel.sql('COALESCE(scheduling_appointments.owner_id, scheduling_payments.recorded_by_id)')
  end

  def crm_task_meeting_source_available?
    defined?(Crm::Task) && Crm::Task.column_names.include?('activity_type')
  end

  def outcome_count_sql(outcome)
    Arel.sql("SUM(CASE WHEN crm_stages.outcome = #{quoted(outcome)} THEN 1 ELSE 0 END)")
  end

  def currency_amount_sum_sql
    Arel.sql(currency_amount_sum_sql_string)
  end

  def currency_amount_sum_sql_string
    "COALESCE(SUM(CASE WHEN crm_deals.currency = #{quoted(currency)} " \
      'THEN COALESCE(crm_deals.amount_minor, 0) ELSE 0 END), 0)'
  end

  def outcome_currency_amount_sum_sql(outcome)
    Arel.sql(
      "COALESCE(SUM(CASE WHEN crm_stages.outcome = #{quoted(outcome)} " \
      "AND crm_deals.currency = #{quoted(currency)} " \
      'THEN COALESCE(crm_deals.amount_minor, 0) ELSE 0 END), 0)'
    )
  end

  def connected_call_count_sql
    Arel.sql(
      'SUM(CASE WHEN telephony_call_sessions.answered_at IS NOT NULL ' \
      "OR telephony_call_sessions.status IN ('in_progress', 'completed') " \
      'OR COALESCE(telephony_call_sessions.duration_seconds, 0) > 0 THEN 1 ELSE 0 END)'
    )
  end

  def long_call_count_sql
    Arel.sql(
      'SUM(CASE WHEN COALESCE(telephony_call_sessions.duration_seconds, 0) >= ' \
      "#{call_duration_threshold_seconds} THEN 1 ELSE 0 END)"
    )
  end

  def quoted(value)
    ActiveRecord::Base.connection.quote(value)
  end

  def payment_category(method)
    case method.to_s
    when 'cash'
      :cash
    when 'bank_transfer', 'card'
      :non_cash
    else
      :other
    end
  end

  def owner_names_for(owner_ids)
    return {} if owner_ids.blank?

    account.users.where(id: owner_ids).pluck(:id, :name, :email).to_h do |id, name, email|
      [id, name.presence || email]
    end
  end

  def calculate_derived_metrics!(row, preserve_meetings_count: false)
    unless preserve_meetings_count
      row[:meetings_count] = row[:appointments_count].positive? ? row[:appointments_count] : row[:meeting_tasks_count]
    end

    row[:bad_rate] = percentage(row[:bad_count], row[:leads_count])
    row[:lead_to_call_conversion] = percentage(row[:long_calls_count], row[:leads_count])
    row[:lead_to_meeting_conversion] = percentage(row[:meetings_count], row[:leads_count])
    row[:call_to_meeting_conversion] = percentage(row[:meetings_count], row[:long_calls_count])
    row[:meeting_to_deal_conversion] = percentage(row[:won_count], row[:meetings_count])
    row[:lead_to_deal_conversion] = percentage(row[:won_count], row[:leads_count])
    row[:average_check_minor] = average_amount(row[:won_amount_minor], row[:won_count])
    row
  end

  def totals_for(rows)
    total = base_stats(nil).except(:owner_id, :owner_name)
    rows.each do |row|
      total.each_key do |key|
        total[key] += row[key].to_i if row.key?(key)
      end
    end

    calculate_derived_metrics!(total, preserve_meetings_count: true)
    total
  end

  def percentage(numerator, denominator)
    return 0.0 if denominator.to_i.zero?

    ((numerator.to_f / denominator) * 100).round(1)
  end

  def average_amount(amount, count)
    return 0 if count.to_i.zero?

    (amount.to_f / count).round.to_i
  end
end
