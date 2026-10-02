module Whatsapp::UsageDeliveryCounts
  TEMPLATE_CATEGORIES = %w[marketing utility authentication authentication-international].freeze
  OTHER_CATEGORIES = (WhatsappUsageDelivery::CATEGORY_VALUES - (TEMPLATE_CATEGORIES + ['service'])).freeze

  module_function

  def for_account(delivery_groups)
    grouped_categories = Hash.new(0)
    delivery_groups.each do |(_phone_number, category, billable, _country), count|
      grouped_categories[[category, billable]] += count
    end

    [aggregate(grouped_categories), all_delivery_groups(delivery_groups)]
  end

  def aggregate(grouped_categories)
    counts = {
      delivered_count: 0,
      service_delivered_count: 0,
      non_billable_service_count: 0,
      template_delivered_count: 0,
      other_category_delivered_count: 0,
      unknown_category_delivered_count: 0,
      unknown_service_billable_count: 0
    }

    grouped_categories.each do |(category, billable, _country), count|
      counts[:delivered_count] += count
      add_category_delivery_count(counts, category, billable, count)
    end

    counts
  end

  def all_delivery_groups(delivery_groups)
    delivery_groups.each_with_object(Hash.new(0)) do |((_phone, category, billable, country), count), groups|
      groups[[category, billable, country]] += count
    end
  end

  def add_category_delivery_count(counts, category, billable, count)
    case category
    when 'service'
      counts[:service_delivered_count] += count
      counts[:non_billable_service_count] += count if billable == false
      counts[:unknown_service_billable_count] += count if billable.nil?
    when *TEMPLATE_CATEGORIES
      counts[:template_delivered_count] += count
    when *OTHER_CATEGORIES
      counts[:other_category_delivered_count] += count
    else
      counts[:unknown_category_delivered_count] += count
    end
  end
end

class Whatsapp::MonthlyUsageService
  FREE_SERVICE_ALLOWANCE_PER_PHONE = 1_000
  UsageSnapshot = Struct.new(
    :period_start,
    :period_end,
    :tracking_started_at,
    :connected_phones,
    :delivery_groups,
    :phones,
    :unknown_timestamp_counts,
    :unknown_existing_counts,
    :exchange_rate,
    keyword_init: true
  )

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
    exchange_rate = fetch_exchange_rate(period_start, connected_phones, delivery_groups)
    unknown_timestamp_counts = unknown_timestamp_counts_for(period_start, period_end)
    unknown_existing_counts = unassigned_existing_delivery_counts(channels, period_start, period_end)
    snapshot = UsageSnapshot.new(
      period_start: period_start,
      period_end: period_end,
      tracking_started_at: tracking_started_at,
      connected_phones: connected_phones,
      delivery_groups: delivery_groups,
      unknown_timestamp_counts: unknown_timestamp_counts, unknown_existing_counts: unknown_existing_counts, exchange_rate: exchange_rate
    )
    snapshot.phones = phone_usage_rows(snapshot, deliveries_by_phone)

    usage_payload(snapshot)
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
                         .group(:phone_number, :category, :billable, :recipient_country).count
  end

  def delivery_groups_by_phone(delivery_groups)
    delivery_groups.each_with_object({}) do |((phone_number, category, billable, country), count), grouped|
      (grouped[phone_number] ||= Hash.new(0))[[category, billable, country]] += count
    end
  end

  def fetch_exchange_rate(period_start, connected_phones, delivery_groups)
    return if connected_phones.empty? && delivery_groups.empty?

    Whatsapp::MonthlyExchangeRateService.new(month: period_start).perform
  end

  def unknown_timestamp_counts_for(period_start, period_end)
    WhatsappUsageDelivery.where(account_id: @account.id, delivered_at: nil,
                                received_at: period_start...period_end)
                         .group(:phone_number).count
  end

  def phone_usage_rows(snapshot, deliveries_by_phone)
    phone_keys = snapshot.connected_phones.keys | deliveries_by_phone.keys |
                 snapshot.unknown_timestamp_counts.keys | snapshot.unknown_existing_counts.keys
    phones = phone_keys.map do |phone_key|
      build_phone_usage(phone_key, deliveries_by_phone.fetch(phone_key, {}), snapshot)
    end
    phones.sort_by { |usage| usage[:phone_number] }
  end

  def usage_payload(snapshot)
    delivery_counts, cost_groups = Whatsapp::UsageDeliveryCounts.for_account(snapshot.delivery_groups)
    costs = estimate_costs(cost_groups, snapshot)
    usage_metadata(snapshot).merge(delivery_counts)
                            .merge(costs.except(:service_cost_complete, :cost_complete))
                            .merge(coverage_summary(snapshot, delivery_counts, costs))
  end

  def usage_metadata(snapshot)
    {
      month: snapshot.period_start.strftime('%Y-%m'),
      period_start: snapshot.period_start.iso8601(6),
      period_end: snapshot.period_end.iso8601(6),
      currency: 'KZT',
      estimated: true,
      free_service_allowance_per_phone: FREE_SERVICE_ALLOWANCE_PER_PHONE,
      service_allowance_applied: false,
      amount_basis: 'Meta pricing.billable=true deliveries at published USD base rates and monthly NBK USD/KZT',
      estimated_amount_scope: 'billable_message_base_rates',
      template_costs_included: true,
      volume_discounts_included: false,
      exchange_rate: exchange_rate_payload(snapshot.period_start, snapshot.exchange_rate),
      official_cloud_phone_count: snapshot.connected_phones.size,
      eligible: snapshot.connected_phones.present?,
      phones: snapshot.phones
    }
  end

  def estimate_costs(groups, snapshot)
    Whatsapp::UsageCostEstimator.new(
      groups: groups,
      month: snapshot.period_start,
      exchange_rate: snapshot.exchange_rate
    ).perform
  end

  def exchange_rate_payload(period_start, exchange_rate)
    {
      month: period_start.strftime('%Y-%m'),
      requested_date: period_start.to_date.iso8601,
      effective_date: exchange_rate&.effective_date&.iso8601,
      rate_per_usd: exchange_rate&.rate_per_usd,
      source_url: exchange_rate&.source_url,
      available: exchange_rate.present?
    }
  end

  def coverage_summary(snapshot, delivery_counts, costs)
    unknown_existing_count = snapshot.unknown_existing_counts.values.sum
    unknown_timestamp_count = snapshot.unknown_timestamp_counts.values.sum + unknown_existing_count
    coverage_started_at = [snapshot.tracking_started_at, snapshot.period_start].compact.max
    coverage_complete = snapshot.tracking_started_at.present? && snapshot.tracking_started_at <= snapshot.period_start &&
                        unknown_timestamp_count.zero?
    completeness = estimate_completeness(coverage_complete, delivery_counts, costs)

    {
      unknown_delivery_timestamp_count: unknown_timestamp_count,
      unknown_existing_delivery_count: unknown_existing_count,
      tracking_started_at: snapshot.tracking_started_at&.iso8601(6),
      coverage_started_at: coverage_started_at.iso8601(6),
      coverage_complete: coverage_complete
    }.merge(completeness)
  end

  def estimate_completeness(coverage_complete, delivery_counts, costs)
    service_complete = coverage_complete && costs[:service_cost_complete] && delivery_counts[:unknown_category_delivered_count].zero?
    full_estimate_complete = coverage_complete && costs[:cost_complete]

    { service_estimate_complete: service_complete, estimate_complete: full_estimate_complete }
  end

  def build_phone_usage(phone_key, category_billability_counts, snapshot)
    counts = Whatsapp::UsageDeliveryCounts.aggregate(category_billability_counts)
    unknown_existing_count = snapshot.unknown_existing_counts.fetch(phone_key, 0)
    unknown_timestamp_count = snapshot.unknown_timestamp_counts.fetch(phone_key, 0) + unknown_existing_count
    {
      phone_number: snapshot.connected_phones[phone_key]&.phone_number || phone_key,
      connected: snapshot.connected_phones.key?(phone_key),
      unknown_delivery_timestamp_count: unknown_timestamp_count,
      unknown_existing_delivery_count: unknown_existing_count
    }.merge(counts).merge(estimate_costs(category_billability_counts, snapshot)
                           .except(:service_cost_complete, :cost_complete))
  end

  def unassigned_existing_delivery_counts(channels, period_start, period_end)
    Whatsapp::UnassignedExistingDeliveryCountsService.new(
      account: @account,
      channels: channels,
      period: period_start...period_end
    ).perform
  end
end
