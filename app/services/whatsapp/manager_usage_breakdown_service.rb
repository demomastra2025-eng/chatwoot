class Whatsapp::ManagerUsageBreakdownService
  CONSECUTIVE_WINDOW_SECONDS = 300
  KZ_VAT_MULTIPLIER = BigDecimal('1.12')

  QUERY_SQL = <<~SQL.squish.freeze
    WITH conv_msgs AS (
      SELECT
        m.id AS message_id,
        m.sender_type,
        m.sender_id,
        m.message_type,
        LAG(m.message_type) OVER (PARTITION BY m.conversation_id ORDER BY m.created_at, m.id) AS prev_message_type,
        LAG(m.sender_type) OVER (PARTITION BY m.conversation_id ORDER BY m.created_at, m.id) AS prev_sender_type,
        LAG(m.sender_id) OVER (PARTITION BY m.conversation_id ORDER BY m.created_at, m.id) AS prev_sender_id,
        EXTRACT(EPOCH FROM (
          m.created_at - LAG(m.created_at) OVER (PARTITION BY m.conversation_id ORDER BY m.created_at, m.id)
        )) AS gap_seconds
      FROM messages m
      WHERE m.account_id = :account_id
        AND m.created_at >= :window_start
        AND m.created_at < :period_end
        AND m.private = FALSE
    )
    SELECT
      cm.sender_id AS user_id,
      u.name AS user_name,
      d.category,
      d.billable,
      COALESCE(d.recipient_country, 'KZ') AS recipient_country,
      CASE
        WHEN cm.prev_message_type = 1
          AND cm.prev_sender_type = 'User'
          AND cm.prev_sender_id = cm.sender_id
          AND d.category = 'service'
          AND cm.gap_seconds <= :burst_seconds
        THEN TRUE
        ELSE FALSE
      END AS is_consecutive,
      COUNT(*) AS delivery_count
    FROM whatsapp_usage_deliveries d
    INNER JOIN conv_msgs cm ON cm.message_id = d.message_id
    INNER JOIN users u ON u.id = cm.sender_id
    WHERE d.account_id = :account_id
      AND d.delivered_at >= :period_start
      AND d.delivered_at < :period_end
      AND cm.sender_type = 'User'
      AND cm.message_type = 1
    GROUP BY 1, 2, 3, 4, 5, 6
  SQL

  def initialize(account:, period_start:, period_end:, exchange_rate:)
    @account = account
    @period_start = period_start
    @period_end = period_end
    @exchange_rate = exchange_rate
  end

  def perform
    rows = fetch_grouped_rows
    managers = build_manager_rows(rows)
    {
      managers: managers,
      consecutive_summary: build_consecutive_summary(managers)
    }
  end

  private

  def fetch_grouped_rows
    sanitized = ActiveRecord::Base.sanitize_sql_array([
      QUERY_SQL,
      {
        account_id: @account.id,
        window_start: @period_start - CONSECUTIVE_WINDOW_SECONDS.seconds,
        period_start: @period_start,
        period_end: @period_end,
        burst_seconds: CONSECUTIVE_WINDOW_SECONDS
      }
    ])
    ActiveRecord::Base.connection.exec_query(sanitized).to_a
  end

  def build_manager_rows(rows)
    grouped = {}
    rows.each do |row|
      user_id = row['user_id'].to_i
      entry = (grouped[user_id] ||= empty_manager_entry(user_id, row['user_name']))
      accumulate_manager_row(entry, row)
    end

    grouped.values.map { |entry| finalize_manager_entry(entry) }
           .sort_by { |m| [-m[:chargeable_consecutive_count], -m[:consecutive_count], -m[:delivered_count], m[:name].to_s] }
  end

  def empty_manager_entry(user_id, name)
    {
      user_id: user_id,
      name: name,
      delivered_count: 0,
      service_delivered_count: 0,
      chargeable_count: 0,
      free_count: 0,
      consecutive_count: 0,
      chargeable_consecutive_count: 0,
      paid_usd: BigDecimal(0),
      consecutive_paid_usd: BigDecimal(0)
    }
  end

  def accumulate_manager_row(entry, row)
    count = row['delivery_count'].to_i
    billable = ActiveModel::Type::Boolean.new.cast(row['billable'])
    is_consecutive = ActiveModel::Type::Boolean.new.cast(row['is_consecutive'])
    category = row['category']
    country = row['recipient_country']

    entry[:delivered_count] += count
    entry[:service_delivered_count] += count if category == 'service'
    entry[:free_count] += count if billable == false
    entry[:consecutive_count] += count if is_consecutive

    return unless billable == true

    entry[:chargeable_count] += count
    entry[:chargeable_consecutive_count] += count if is_consecutive
    rate = Whatsapp::MetaUsdRateCatalog.rate(country_code: country, category: category, at: @period_start) || BigDecimal(0)
    entry[:paid_usd] += rate * count
    entry[:consecutive_paid_usd] += rate * count if is_consecutive
  end

  def finalize_manager_entry(entry)
    base_kzt = kzt_from_usd(entry[:paid_usd], entry[:chargeable_count])
    consec_kzt = kzt_from_usd(entry[:consecutive_paid_usd], entry[:chargeable_consecutive_count])
    svc_count = entry[:service_delivered_count]
    ratio = svc_count.positive? ? (entry[:consecutive_count].to_f / svc_count * 100).round(1) : 0.0

    entry.except(:paid_usd, :consecutive_paid_usd).merge(
      consecutive_ratio_percent: ratio,
      estimated_amount_kzt: base_kzt,
      estimated_amount_with_vat_kzt: with_vat(base_kzt),
      consecutive_overpayment_kzt: consec_kzt,
      consecutive_overpayment_with_vat_kzt: with_vat(consec_kzt)
    )
  end

  def build_consecutive_summary(managers)
    total_svc = managers.sum { |m| m[:service_delivered_count] }
    consec_count = managers.sum { |m| m[:consecutive_count] }
    paid_consec_count = managers.sum { |m| m[:chargeable_consecutive_count] }
    overpayment_kzt = sum_kzt(managers, :consecutive_overpayment_kzt, paid_consec_count)

    {
      window_seconds: CONSECUTIVE_WINDOW_SECONDS,
      consecutive_service_count: consec_count,
      chargeable_consecutive_count: paid_consec_count,
      consecutive_ratio_percent: total_svc.positive? ? (consec_count.to_f / total_svc * 100).round(1) : 0.0,
      estimated_overpayment_kzt: overpayment_kzt,
      estimated_overpayment_with_vat_kzt: with_vat(overpayment_kzt)
    }
  end

  def kzt_from_usd(usd_amount, paid_count)
    return BigDecimal(0) if paid_count.zero?
    return if @exchange_rate.nil?

    (usd_amount * @exchange_rate.rate_per_usd).round(2)
  end

  def sum_kzt(managers, key, total_paid_count)
    return BigDecimal(0) if total_paid_count.zero?
    return if @exchange_rate.nil?

    managers.sum(BigDecimal(0)) { |m| m[key] || BigDecimal(0) }.round(2)
  end

  def with_vat(amount)
    return if amount.nil?

    (amount * KZ_VAT_MULTIPLIER).round(2)
  end
end
