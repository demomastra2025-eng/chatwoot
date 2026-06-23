class Crm::Reports::FunnelsService
  DEFAULT_CURRENCY = 'KZT'.freeze
  DEFAULT_GROUP_BY = 'week'.freeze
  ALLOWED_GROUP_BY = %w[day week month year].freeze

  AGING_BUCKETS = [
    { key: '0_3', min_days: 0, max_days: 3 },
    { key: '4_7', min_days: 4, max_days: 7 },
    { key: '8_14', min_days: 8, max_days: 14 },
    { key: '15_30', min_days: 15, max_days: 30 },
    { key: '31_plus', min_days: 31, max_days: nil }
  ].freeze

  attr_reader :account, :params, :since_time, :until_time, :group_by, :currency

  def initialize(account:, params: {})
    @account = account
    @params = params.to_h.symbolize_keys
    @since_time = parse_time(@params[:since]) || 30.days.ago.beginning_of_day
    @until_time = parse_time(@params[:until]) || Time.current.end_of_day
    @group_by = ALLOWED_GROUP_BY.include?(@params[:group_by].to_s) ? @params[:group_by].to_s : DEFAULT_GROUP_BY
    @currency = @params[:currency].presence || dominant_currency || DEFAULT_CURRENCY
  end

  def perform
    {
      summary: summary_payload,
      stage_distribution: stage_distribution,
      forecast_by_period: forecast_by_period,
      won_lost_by_period: won_lost_by_period,
      source_performance: source_performance,
      owner_performance: owner_performance,
      aging_buckets: aging_buckets
    }
  end

  def meta
    {
      since: since_time.iso8601,
      until: until_time.iso8601,
      group_by: group_by,
      currency: currency,
      pipelines_count: account.crm_pipelines.active.count
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

  def dominant_currency
    account.crm_deals
           .where.not(currency: [nil, ''])
           .group(:currency)
           .order(Arel.sql('COUNT(*) DESC'))
           .limit(1)
           .pluck(:currency)
           .first
  end

  def deals_scope
    scope = account.crm_deals.joins(:pipeline, :stage)
    scope = scope.where(pipeline_id: params[:pipeline_id]) if params[:pipeline_id].present?
    scope
  end

  def period_deals_scope
    deals_scope.kept.where(created_at: since_time..until_time)
  end

  def active_deals_scope
    deals_scope.kept
  end

  def open_deals_scope
    active_deals_scope.where(crm_stages: { outcome: 'open' })
  end

  def closed_period_scope
    deals_scope.kept.where(closed_at: since_time..until_time)
  end

  def monetary_scope(scope)
    scope.where(currency: currency)
  end

  def sum_amount(scope)
    monetary_scope(scope).sum(Arel.sql('COALESCE(crm_deals.amount_minor, 0)')).to_i
  end

  def weighted_sum(scope)
    monetary_scope(scope).sum(
      Arel.sql('COALESCE(crm_deals.amount_minor, 0) * COALESCE(crm_deals.win_probability, 0) / 100.0')
    ).to_i
  end

  def percentage(numerator, denominator)
    return 0.0 if denominator.to_i.zero?

    ((numerator.to_f / denominator.to_f) * 100).round(1)
  end

  def summary_payload
    won_scope = closed_period_scope.where(crm_stages: { outcome: 'won' })
    lost_scope = closed_period_scope.where(crm_stages: { outcome: 'lost' })
    won_count = won_scope.count
    lost_count = lost_scope.count

    {
      created_deals_count: period_deals_scope.count,
      open_deals_count: open_deals_scope.count,
      pipeline_amount_minor: sum_amount(open_deals_scope),
      weighted_pipeline_amount_minor: weighted_sum(open_deals_scope),
      won_deals_count: won_count,
      won_amount_minor: sum_amount(won_scope),
      lost_deals_count: lost_count,
      lost_amount_minor: sum_amount(lost_scope),
      win_rate: percentage(won_count, won_count + lost_count),
      overdue_deals_count: open_deals_scope.where('crm_deals.expected_close_on < ?', Time.zone.today).count,
      currency: currency
    }
  end

  def stage_distribution
    counts_by_stage = active_deals_scope.group(:stage_id).count
    amounts_by_stage = monetary_scope(active_deals_scope).group(:stage_id).sum(:amount_minor)
    weighted_amounts_by_stage = weighted_amounts_by(:stage_id, active_deals_scope)

    account.crm_pipelines.active.ordered.includes(:stages).flat_map do |pipeline|
      pipeline.stages.active.ordered.map do |stage|
        {
          pipeline_id: pipeline.id,
          pipeline_name: pipeline.name,
          stage_id: stage.id,
          stage_name: stage.name,
          stage_color: stage.color,
          stage_position: stage.position,
          outcome: stage.outcome,
          deal_count: counts_by_stage[stage.id].to_i,
          amount_minor: amounts_by_stage[stage.id].to_i,
          weighted_amount_minor: weighted_amounts_by_stage[stage.id].to_i
        }
      end
    end
  end

  def weighted_amounts_by(group_column, scope)
    monetary_scope(scope)
      .group(group_column)
      .pluck(
        group_column,
        Arel.sql('COALESCE(SUM(COALESCE(crm_deals.amount_minor, 0) * COALESCE(crm_deals.win_probability, 0) / 100.0), 0)')
      ).to_h
  end

  def forecast_by_period
    scope = open_deals_scope.where(expected_close_on: since_time.to_date..until_time.to_date)
    period_expression = period_sql('crm_deals.expected_close_on::timestamp')

    monetary_scope(scope)
      .group(period_expression)
      .order(period_expression)
      .pluck(
        period_expression,
        Arel.sql('COUNT(*)'),
        Arel.sql('COALESCE(SUM(crm_deals.amount_minor), 0)'),
        Arel.sql('COALESCE(SUM(COALESCE(crm_deals.amount_minor, 0) * COALESCE(crm_deals.win_probability, 0) / 100.0), 0)')
      ).map do |period, count, amount, weighted_amount|
        {
          period: period.iso8601,
          deal_count: count.to_i,
          amount_minor: amount.to_i,
          weighted_amount_minor: weighted_amount.to_i
        }
      end
  end

  def won_lost_by_period
    scope = closed_period_scope.where(crm_stages: { outcome: %w[won lost] })
    period_expression = period_sql('crm_deals.closed_at')

    scope
      .group(period_expression, 'crm_stages.outcome')
      .order(period_expression)
      .pluck(
        period_expression,
        Arel.sql('crm_stages.outcome'),
        Arel.sql('COUNT(*)'),
        currency_amount_sum_sql
      ).map do |period, outcome, count, amount|
        {
          period: period.iso8601,
          outcome: outcome,
          deal_count: count.to_i,
          amount_minor: amount.to_i
        }
      end
  end

  def period_sql(column_sql)
    Arel.sql("DATE_TRUNC('#{group_by}', #{column_sql})::date")
  end

  def currency_amount_sum_sql
    Arel.sql(currency_amount_sum_sql_string)
  end

  def currency_amount_sum_sql_string
    "COALESCE(SUM(CASE WHEN crm_deals.currency = #{quoted_currency} " \
      'THEN COALESCE(crm_deals.amount_minor, 0) ELSE 0 END), 0)'
  end

  def quoted_currency
    ActiveRecord::Base.connection.quote(currency)
  end

  def source_performance
    source_expression = "COALESCE(NULLIF(crm_deals.custom_attributes->>'source', ''), 'manual')"
    rows = ActiveRecord::Base.connection.select_all(
      period_deals_scope
        .select(
          Arel.sql("#{source_expression} AS source"),
          Arel.sql('COUNT(*) AS deal_count'),
          Arel.sql("#{outcome_count_sql_string('open')} AS open_count"),
          Arel.sql("#{outcome_count_sql_string('won')} AS won_count"),
          Arel.sql("#{outcome_count_sql_string('lost')} AS lost_count"),
          Arel.sql("#{currency_amount_sum_sql_string} AS amount_minor"),
          Arel.sql("#{outcome_currency_amount_sum_sql_string('won')} AS won_amount_minor")
        )
        .group(Arel.sql(source_expression))
        .to_sql
    )

    rows.map do |row|
      won_count = row['won_count'].to_i
      lost_count = row['lost_count'].to_i

      {
        source: row['source'],
        deal_count: row['deal_count'].to_i,
        open_count: row['open_count'].to_i,
        won_count: won_count,
        lost_count: lost_count,
        amount_minor: row['amount_minor'].to_i,
        won_amount_minor: row['won_amount_minor'].to_i,
        win_rate: percentage(won_count, won_count + lost_count)
      }
    end.sort_by { |item| -item[:deal_count] }
  end

  def owner_performance
    rows = period_deals_scope
           .group(:owner_id)
           .pluck(
             :owner_id,
             Arel.sql('COUNT(*)'),
             outcome_count_sql('open'),
             outcome_count_sql('won'),
             outcome_count_sql('lost'),
             currency_amount_sum_sql,
             outcome_currency_amount_sum_sql('won')
           )
    owner_names = owner_names_for(rows.map(&:first).compact)

    rows.map do |owner_id, count, open_count, won_count, lost_count, amount, won_amount|
      {
        owner_id: owner_id,
        owner_name: owner_names[owner_id],
        deal_count: count.to_i,
        open_count: open_count.to_i,
        won_count: won_count.to_i,
        lost_count: lost_count.to_i,
        amount_minor: amount.to_i,
        won_amount_minor: won_amount.to_i,
        win_rate: percentage(won_count, won_count.to_i + lost_count.to_i)
      }
    end.sort_by { |item| -item[:amount_minor] }.first(8)
  end

  def outcome_count_sql(outcome)
    Arel.sql(outcome_count_sql_string(outcome))
  end

  def outcome_count_sql_string(outcome)
    "SUM(CASE WHEN crm_stages.outcome = #{ActiveRecord::Base.connection.quote(outcome)} THEN 1 ELSE 0 END)"
  end

  def outcome_currency_amount_sum_sql(outcome)
    Arel.sql(outcome_currency_amount_sum_sql_string(outcome))
  end

  def outcome_currency_amount_sum_sql_string(outcome)
    "COALESCE(SUM(CASE WHEN crm_stages.outcome = #{ActiveRecord::Base.connection.quote(outcome)} " \
      "AND crm_deals.currency = #{quoted_currency} " \
      'THEN COALESCE(crm_deals.amount_minor, 0) ELSE 0 END), 0)'
  end

  def owner_names_for(owner_ids)
    return {} if owner_ids.blank?

    account.users.where(id: owner_ids).pluck(:id, :name, :email).to_h do |id, name, email|
      [id, name.presence || email]
    end
  end

  def aging_buckets
    now = Time.current

    AGING_BUCKETS.map do |bucket|
      scope = open_deals_scope.where(created_at_range_for(bucket, now))

      {
        key: bucket[:key],
        min_days: bucket[:min_days],
        max_days: bucket[:max_days],
        deal_count: scope.count,
        amount_minor: sum_amount(scope)
      }
    end
  end

  def created_at_range_for(bucket, now)
    return ['crm_deals.created_at < ?', now - bucket[:min_days].days] if bucket[:max_days].blank?

    older_than = now - bucket[:min_days].days
    newer_than = now - (bucket[:max_days] + 1).days
    { created_at: newer_than...older_than }
  end
end
