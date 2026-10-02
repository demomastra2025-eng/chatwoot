class Whatsapp::MonthlyUsageService
  SERVICE_RATE_KZT = 8
  FREE_SERVICE_ALLOWANCE_PER_PHONE = 1_000
  TEMPLATE_CATEGORIES = %w[marketing utility authentication authentication-international].freeze
  OTHER_CATEGORIES = (WhatsappUsageDelivery::CATEGORY_VALUES - (TEMPLATE_CATEGORIES + ['service'])).freeze
  UsageSnapshot = Struct.new(:period_start, :period_end, :tracking_started_at, :connected_phones, :delivery_groups,
                             :phones, :unknown_timestamp_counts, :unknown_existing_counts, keyword_init: true)

  def initialize(account:, now: Time.current)
    @account = account
    @now = now
  end

  def perform
    period_start, period_end = utc_month_period
    tracking_started_at = WhatsappUsageTrackingState.current_or_create!.tracking_started_at.utc
    channels = cloud_channels
    connected_phones = connected_phone_map(channels)
    delivery_groups = deliveries_for_period(period_start, period_end)
    deliveries_by_phone = delivery_groups_by_phone(delivery_groups)
    unknown_timestamp_counts = unknown_timestamp_counts_for(period_start, period_end)
    unknown_existing_counts = unassigned_existing_delivery_counts(channels, period_start, period_end)
    phones = phone_usage_rows(connected_phones, deliveries_by_phone, unknown_timestamp_counts, unknown_existing_counts)

    usage_payload(
      UsageSnapshot.new(
        period_start:, period_end:, tracking_started_at:, connected_phones:, delivery_groups:, phones:,
        unknown_timestamp_counts:, unknown_existing_counts:
      )
    )
  end

  private

  def utc_month_period
    now_utc = @now.utc
    period_start = Time.utc(now_utc.year, now_utc.month, 1)
    [period_start, period_start.next_month]
  end

  def cloud_channels
    Channel::Whatsapp.where(account_id: @account.id, provider: 'whatsapp_cloud').order(:id).to_a
  end

  def connected_phone_map(channels)
    channels.index_by { |channel| WhatsappUsageDelivery.canonical_phone_number(channel.phone_number) }
            .reject { |phone_number, _channel| phone_number.blank? }
  end

  def deliveries_for_period(period_start, period_end)
    WhatsappUsageDelivery.where(account_id: @account.id, delivered_at: period_start...period_end)
                         .group(:phone_number, :category, :billable).count
  end

  def delivery_groups_by_phone(delivery_groups)
    delivery_groups.each_with_object({}) do |((phone_number, category, billable), count), grouped|
      (grouped[phone_number] ||= Hash.new(0))[[category, billable]] += count
    end
  end

  def unknown_timestamp_counts_for(period_start, period_end)
    WhatsappUsageDelivery.where(account_id: @account.id, delivered_at: nil,
                                received_at: period_start...period_end)
                         .group(:phone_number).count
  end

  def phone_usage_rows(connected_phones, deliveries_by_phone, unknown_timestamp_counts, unknown_existing_counts)
    phone_keys = connected_phones.keys | deliveries_by_phone.keys |
      unknown_timestamp_counts.keys | unknown_existing_counts.keys
    phones = phone_keys.map do |phone_key|
      unknown_timestamps = unknown_timestamp_counts.fetch(phone_key, 0) + unknown_existing_counts.fetch(phone_key, 0)
      build_phone_usage(phone_key, deliveries_by_phone.fetch(phone_key, {}), unknown_timestamps,
                        unknown_existing_counts.fetch(phone_key, 0), connected_phones)
    end
    phones.sort_by { |usage| usage[:phone_number] }
  end

  def usage_payload(snapshot)
    delivery_counts = delivery_counts(snapshot.delivery_groups)
    base = {
      month: snapshot.period_start.strftime('%Y-%m'),
      period_start: snapshot.period_start.iso8601(6),
      period_end: snapshot.period_end.iso8601(6),
      currency: 'KZT',
      estimated: true,
      estimated_service_rate_kzt: SERVICE_RATE_KZT,
      service_rate_source: 'user_provided_estimate',
      free_service_allowance_per_phone: FREE_SERVICE_ALLOWANCE_PER_PHONE,
      service_allowance_applied: false,
      amount_basis: 'Meta pricing.billable=true for service deliveries; allowance is reflected in Meta billing status',
      estimated_amount_scope: 'billable_service_messages_only',
      template_costs_included: false,
      official_cloud_phone_count: snapshot.connected_phones.size,
      eligible: snapshot.connected_phones.present?,
      phones: snapshot.phones
    }
    base.merge(delivery_counts)
        .merge(phone_totals(snapshot.phones))
        .merge(coverage_summary(snapshot.period_start, snapshot.tracking_started_at, delivery_counts,
                                snapshot.unknown_timestamp_counts, snapshot.unknown_existing_counts))
  end

  def delivery_counts(delivery_groups)
    category_billability_counts = Hash.new(0)
    delivery_groups.each do |(_phone_number, category, billable), count|
      category_billability_counts[[category, billable]] += count
    end
    aggregate_delivery_counts(category_billability_counts)
  end

  def aggregate_delivery_counts(category_billability_counts)
    counts = {
      delivered_count: 0,
      service_delivered_count: 0,
      non_billable_service_count: 0,
      template_delivered_count: 0,
      other_category_delivered_count: 0,
      unknown_category_delivered_count: 0,
      unknown_service_billable_count: 0
    }

    category_billability_counts.each do |(category, billable), count|
      counts[:delivered_count] += count
      counts[:service_delivered_count] += count if category == 'service'
      counts[:non_billable_service_count] += count if category == 'service' && billable == false
      counts[:template_delivered_count] += count if template_category?(category)
      counts[:other_category_delivered_count] += count if other_category?(category)
      counts[:unknown_category_delivered_count] += count if unknown_category?(category)
      counts[:unknown_service_billable_count] += count if category == 'service' && billable.nil?
    end

    counts
  end

  def phone_totals(phones)
    {
      chargeable_service_count: phones.sum { |usage| usage[:chargeable_service_count] },
      estimated_amount_kzt: phones.sum { |usage| usage[:estimated_amount_kzt] }
    }
  end

  def coverage_summary(period_start, tracking_started_at, delivery_counts, unknown_timestamp_counts, unknown_existing_counts)
    unknown_existing_count = unknown_existing_counts.values.sum
    unknown_timestamp_count = unknown_timestamp_counts.values.sum + unknown_existing_count
    coverage_started_at = [tracking_started_at, period_start].compact.max
    coverage_complete = tracking_started_at.present? && tracking_started_at <= period_start && unknown_timestamp_count.zero?
    completeness = estimate_completeness(coverage_complete, delivery_counts)

    {
      unknown_delivery_timestamp_count: unknown_timestamp_count,
      unknown_existing_delivery_count: unknown_existing_count,
      tracking_started_at: tracking_started_at&.iso8601(6),
      coverage_started_at: coverage_started_at.iso8601(6),
      coverage_complete: coverage_complete
    }.merge(completeness)
  end

  def estimate_completeness(coverage_complete, delivery_counts)
    service_complete = coverage_complete && delivery_counts[:unknown_category_delivered_count].zero? &&
      delivery_counts[:unknown_service_billable_count].zero?
    full_estimate_complete = service_complete && delivery_counts[:template_delivered_count].zero? &&
      delivery_counts[:other_category_delivered_count].zero?

    { service_estimate_complete: service_complete, estimate_complete: full_estimate_complete }
  end

  def build_phone_usage(phone_key, category_billability_counts, unknown_timestamp_count,
                        unknown_existing_delivery_count, connected_phones)
    counts = aggregate_delivery_counts(category_billability_counts)
    {
      phone_number: connected_phones[phone_key]&.phone_number || phone_key,
      connected: connected_phones.key?(phone_key),
      unknown_delivery_timestamp_count: unknown_timestamp_count,
      unknown_existing_delivery_count: unknown_existing_delivery_count
    }.merge(counts).merge(service_usage_counts(category_billability_counts))
  end

  def service_usage_counts(category_billability_counts)
    chargeable_service_count = category_billability_counts.fetch(['service', true], 0)
    {
      chargeable_service_count: chargeable_service_count,
      estimated_amount_kzt: chargeable_service_count * SERVICE_RATE_KZT
    }
  end

  def template_category?(category)
    TEMPLATE_CATEGORIES.include?(category)
  end

  def other_category?(category)
    OTHER_CATEGORIES.include?(category)
  end

  def unknown_category?(category)
    !WhatsappUsageDelivery::CATEGORY_VALUES.include?(category)
  end

  def unassigned_existing_delivery_counts(channels, period_start, period_end)
    channels.each_with_object({}) do |channel, counts|
      inbox = channel.inbox
      next if inbox.blank?

      phone_number = WhatsappUsageDelivery.canonical_phone_number(channel.phone_number)
      unassigned_messages = existing_delivered_cloud_messages(inbox, period_start, period_end)
      unassigned_messages = unassigned_messages.where(<<~SQL.squish, @account.id, phone_number)
        NOT EXISTS (
          SELECT 1
          FROM whatsapp_usage_deliveries
          WHERE whatsapp_usage_deliveries.account_id = ?
            AND whatsapp_usage_deliveries.phone_number = ?
            AND whatsapp_usage_deliveries.provider_message_id = messages.source_id
        )
      SQL
      unassigned_count = unassigned_messages.reorder(nil).distinct.count(:source_id)
      counts[phone_number] = unassigned_count if unassigned_count.positive?
    end
  end

  def existing_delivered_cloud_messages(inbox, period_start, period_end)
    Message.without_imported_history.where(
      account_id: @account.id,
      inbox_id: inbox.id,
      created_at: period_start...period_end,
      message_type: [Message.message_types[:outgoing], Message.message_types[:template]],
      status: Message.statuses.values_at('delivered', 'read'),
      private: false
    ).where.not(source_id: [nil, ''])
     .where(<<~'SQL'.squish)
       NOT CASE json_typeof(messages.content_attributes)
       WHEN 'object' THEN
         LOWER(COALESCE(messages.content_attributes ->> 'external_echo', 'false')) = 'true'
         OR LOWER(COALESCE(messages.content_attributes ->> 'whatsapp_history_import', 'false')) = 'true'
       WHEN 'string' THEN
         COALESCE(messages.content_attributes #>> '{}', '') ~*
           '"(external_echo|whatsapp_history_import)"\s*:\s*(true|"true")'
       ELSE false
       END
     SQL
  end
end
