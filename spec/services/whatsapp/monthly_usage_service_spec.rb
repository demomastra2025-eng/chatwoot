require 'rails_helper'

RSpec.describe Whatsapp::MonthlyUsageService do
  let(:account) { create(:account) }
  let(:exchange_rate) do
    instance_double(WhatsappUsageExchangeRate, rate_per_usd: BigDecimal(500), effective_date: Date.new(2026, 10, 1),
                                               source_url: 'https://nationalbank.kz/rss/get_rates.cfm?fdate=01.10.2026')
  end
  let(:exchange_rate_service) { instance_double(Whatsapp::MonthlyExchangeRateService, perform: exchange_rate) }
  let!(:first_channel) do
    create(:channel_whatsapp, account: account, phone_number: '+77010000001', provider: 'whatsapp_cloud',
                              sync_templates: false, validate_provider_config: false)
  end
  let!(:second_channel) do
    create(:channel_whatsapp, account: account, phone_number: '+77010000002', provider: 'whatsapp_cloud',
                              sync_templates: false, validate_provider_config: false)
  end
  let!(:same_phone_channel) do
    create(:channel_whatsapp, account: account, phone_number: '77010000001', provider: 'whatsapp_cloud',
                              sync_templates: false, validate_provider_config: false)
  end

  before do
    allow(Whatsapp::MonthlyExchangeRateService).to receive(:new).and_return(exchange_rate_service)
    tracking_state = WhatsappUsageTrackingState.current_or_create!
    tracking_state.update!(tracking_started_at: Time.utc(2026, 9, 1))
  end

  def record_delivery(channel:, provider_message_id:, delivered_at:, category:, **attributes)
    WhatsappUsageDelivery.create!(
      account_id: account.id,
      phone_number: WhatsappUsageDelivery.canonical_phone_number(channel.phone_number),
      provider_message_id: provider_message_id,
      inbox_id: channel.inbox.id,
      delivered_at: delivered_at,
      received_at: attributes.fetch(:received_at, delivered_at || Time.utc(2026, 10, 4)),
      category: category,
      pricing_type: attributes[:pricing_type],
      billable: attributes.fetch(:billable),
      recipient_country: attributes.fetch(:recipient_country, 'KZ')
    )
  end

  def create_legacy_delivered_message(source_id:, created_at:, **attributes)
    content_attributes = attributes.delete(:content_attributes)
    serialized = attributes.delete(:serialized) || false
    channel = attributes.delete(:channel) || first_channel
    message = create(
      :message,
      {
        account: account,
        inbox: channel.inbox,
        message_type: :outgoing,
        status: :delivered,
        private: false,
        source_id: source_id,
        content_attributes: content_attributes || {},
        created_at: created_at
      }.merge(attributes)
    )
    return message if content_attributes.nil?

    json_value = JSON.generate(content_attributes)
    json_value = JSON.generate(json_value) if serialized
    write_content_attributes_json(message, json_value)
    message
  end

  def write_content_attributes_json(message, json_value)
    sql = Message.sanitize_sql_array(
      ['UPDATE messages SET content_attributes = ?::json WHERE id = ?', json_value, message.id]
    )
    Message.connection.execute(sql)
  end

  def content_attributes_json_type(message)
    sql = Message.sanitize_sql_array(
      ['SELECT json_typeof(content_attributes) FROM messages WHERE id = ?', message.id]
    )
    Message.connection.select_value(sql)
  end

  def legacy_exclusion_messages(created_at)
    records = {}
    representations = [false, true]
    [[:echo, :external_echo], [:history, :whatsapp_history_import], [:import, :imported_history]].each do |kind, flag|
      representations.each do |serialized|
        representation = serialized ? 'serialized' : 'object'
        key = "#{representation}_#{kind}".to_sym
        records[key] = create_legacy_delivered_message(
          source_id: "wamid.legacy-#{representation}-#{kind}",
          created_at: created_at,
          content_attributes: { flag => true },
          serialized: serialized
        )
      end
    end
    records
  end

  def verify_legacy_exclusions(created_at)
    records = legacy_exclusion_messages(created_at)
    expect(records.transform_values { |message| content_attributes_json_type(message) }).to eq(
      object_echo: 'object', serialized_echo: 'string',
      object_history: 'object', serialized_history: 'string',
      object_import: 'object', serialized_import: 'string'
    )
    expect(records.fetch(:serialized_echo).reload.content_attributes['external_echo']).to be(true)
  end

  def whatsapp_delivery_attributes(category:, type:, billable:)
    {
      whatsapp_delivery: {
        status: 'delivered',
        pricing: { category: category, type: type, billable: billable }
      }
    }
  end

  it 'uses UTC month bounds and trusts Meta billable status instead of applying the allowance again' do
    november_start = Time.utc(2026, 11, 1)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.october',
                    delivered_at: november_start - 1.second, category: 'service', billable: true)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.service-billable',
                    delivered_at: november_start, category: 'service', billable: true)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.service-billable-2',
                    delivered_at: november_start + 1.second, category: 'service', billable: true)
    record_delivery(channel: second_channel, provider_message_id: 'wamid.service-free',
                    delivered_at: november_start + 2.seconds, category: 'service', billable: false)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.utility',
                    delivered_at: november_start + 3.seconds, category: 'utility', billable: true)

    usage = described_class.new(account: account, now: november_start + 30.minutes).perform

    expect(usage).to include(
      month: '2026-11',
      period_start: '2026-11-01T00:00:00.000000Z',
      period_end: '2026-12-01T00:00:00.000000Z',
      official_cloud_phone_count: 2,
      eligible: true,
      delivered_count: 4,
      service_delivered_count: 3,
      non_billable_service_count: 1,
      template_delivered_count: 1,
      chargeable_service_count: 2,
      chargeable_template_count: 1,
      estimated_amount_kzt: BigDecimal(27),
      estimated_service_amount_kzt: BigDecimal(18),
      estimated_template_amount_kzt: BigDecimal(9),
      free_service_allowance_per_phone: 1_000,
      service_allowance_applied: false,
      coverage_complete: true,
      service_estimate_complete: true,
      estimate_complete: true,
      template_costs_included: true,
      estimated_amount_scope: 'billable_message_base_rates',
      volume_discounts_included: false
    )
    expect(usage[:phones]).to contain_exactly(
      include(phone_number: '+77010000001', delivered_count: 3, chargeable_service_count: 2, estimated_amount_kzt: BigDecimal(27)),
      include(phone_number: '+77010000002', delivered_count: 1, non_billable_service_count: 1, chargeable_service_count: 0, estimated_amount_kzt: 0)
    )
  end

  it 'marks the estimate incomplete when a service delivery has no billable status' do
    at = Time.utc(2026, 10, 5)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.unknown-billable',
                    delivered_at: at, category: 'service', billable: nil)

    usage = described_class.new(account: account, now: at).perform

    expect(usage).to include(
      service_delivered_count: 1,
      unknown_service_billable_count: 1,
      chargeable_service_count: 0,
      estimated_amount_kzt: nil,
      estimate_complete: false
    )
  end

  it 'returns ordered category counts split by Meta billability' do
    at = Time.utc(2026, 10, 5)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.breakdown-service',
                    delivered_at: at, category: 'service', billable: true)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.breakdown-utility',
                    delivered_at: at, category: 'utility', billable: false)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.breakdown-marketing',
                    delivered_at: at, category: 'marketing', billable: nil)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.breakdown-authentication',
                    delivered_at: at, category: 'authentication', billable: false)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.breakdown-authentication-international',
                    delivered_at: at, category: 'authentication-international', billable: true)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.breakdown-referral',
                    delivered_at: at, category: 'referral_conversion', billable: true)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.breakdown-future-category',
                    delivered_at: at, category: 'future_category', billable: true)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.breakdown-missing-category',
                    delivered_at: at, category: nil, billable: false)

    usage = described_class.new(account: account, now: at).perform

    expect(usage[:category_breakdown]).to eq([
      { category: 'service', delivered_count: 1, chargeable_count: 1, free_count: 0, unknown_billable_count: 0 },
      { category: 'utility', delivered_count: 1, chargeable_count: 0, free_count: 1, unknown_billable_count: 0 },
      { category: 'marketing', delivered_count: 1, chargeable_count: 0, free_count: 0, unknown_billable_count: 1 },
      { category: 'authentication', delivered_count: 1, chargeable_count: 0, free_count: 1, unknown_billable_count: 0 },
      { category: 'authentication-international', delivered_count: 1, chargeable_count: 1, free_count: 0,
        unknown_billable_count: 0 },
      { category: 'referral_conversion', delivered_count: 1, chargeable_count: 1, free_count: 0,
        unknown_billable_count: 0 },
      { category: 'unknown', delivered_count: 2, chargeable_count: 1, free_count: 1, unknown_billable_count: 0 }
    ])
    expect(usage[:category_breakdown].sum { |row| row[:delivered_count] }).to eq(usage[:delivered_count])
  end

  it 'reports referral conversion separately from template deliveries and the service estimate' do
    at = Time.utc(2026, 10, 6)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.referral-conversion',
                    delivered_at: at, category: 'referral_conversion', billable: true)

    usage = described_class.new(account: account, now: at).perform

    expect(usage).to include(
      delivered_count: 1,
      service_delivered_count: 0,
      template_delivered_count: 0,
      other_category_delivered_count: 1,
      unknown_category_delivered_count: 0,
      estimated_amount_kzt: nil,
      service_estimate_complete: true,
      estimate_complete: false
    )
  end

  it 'treats an unrecognized pricing category as unknown rather than a template or other known category' do
    at = Time.utc(2026, 10, 7)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.unrecognized-category',
                    delivered_at: at, category: 'future_category', billable: true)

    usage = described_class.new(account: account, now: at).perform

    expect(usage).to include(
      delivered_count: 1,
      template_delivered_count: 0,
      other_category_delivered_count: 0,
      unknown_category_delivered_count: 1,
      estimated_amount_kzt: nil,
      estimate_complete: false
    )
  end

  it 'reports a partial month when tracking began after the UTC period started' do
    state = WhatsappUsageTrackingState.current_or_create!
    state.update!(tracking_started_at: Time.utc(2026, 10, 2, 12))

    usage = described_class.new(account: account, now: Time.utc(2026, 10, 8)).perform

    expect(usage).to include(
      month: '2026-10',
      period_start: '2026-10-01T00:00:00.000000Z',
      coverage_complete: false,
      estimate_complete: false
    )
  end

  it 'keeps a delivered message unpriced when its recipient country is unavailable' do
    at = Time.utc(2026, 10, 5)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.no-country',
                    delivered_at: at, category: 'marketing', billable: true, recipient_country: nil)

    usage = described_class.new(account: account, now: at).perform

    expect(usage).to include(chargeable_template_count: 1, unpriced_billable_count: 1,
                             estimated_amount_kzt: nil, estimate_complete: false)
  end

  it 'reports no amount when the monthly exchange rate cannot be obtained' do
    allow(exchange_rate_service).to receive(:perform).and_return(nil)
    at = Time.utc(2026, 10, 5)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.no-fx',
                    delivered_at: at, category: 'utility', billable: true)

    usage = described_class.new(account: account, now: at).perform

    expect(usage).to include(estimated_amount_kzt: nil, estimate_complete: false,
                             exchange_rate: include(available: false, requested_date: '2026-10-01', rate_per_usd: nil))
  end

  it 'rounds the workspace total once rather than summing rounded phone subtotals' do
    allow(exchange_rate).to receive(:rate_per_usd).and_return(BigDecimal(1))
    at = Time.utc(2026, 10, 5)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.round-first',
                    delivered_at: at, category: 'service', billable: true)
    record_delivery(channel: second_channel, provider_message_id: 'wamid.round-second',
                    delivered_at: at, category: 'service', billable: true)
    record_delivery(channel: second_channel, provider_message_id: 'wamid.round-third',
                    delivered_at: at, category: 'service', billable: true)

    usage = described_class.new(account: account, now: at).perform

    expect(usage[:estimated_amount_kzt]).to eq(BigDecimal('0.05'))
    expect(usage[:phones].sum { |phone| phone[:estimated_amount_kzt] }).to eq(BigDecimal('0.06'))
  end

  it 'counts delivered Cloud history alongside ledger deliveries without inventing timestamps' do
    created_at = Time.utc(2026, 10, 3, 10)
    create_legacy_delivered_message(source_id: 'wamid.legacy-delivered', created_at: created_at)
    verify_legacy_exclusions(created_at)
    create_legacy_delivered_message(source_id: 'wamid.legacy-recorded', created_at: created_at)
    record_delivery(channel: first_channel, provider_message_id: 'wamid.legacy-recorded',
                    delivered_at: created_at, category: 'service', billable: true)

    usage = described_class.new(account: account, now: Time.utc(2026, 10, 5)).perform

    expect(usage).to include(
      delivered_count: 2,
      unknown_delivery_timestamp_count: 1,
      unknown_existing_delivery_count: 1,
      coverage_complete: false,
      estimate_complete: false
    )
    expect(usage[:phones]).to include(
      include(phone_number: first_channel.phone_number, unknown_existing_delivery_count: 1)
    )
  end

  it 'keeps scalar legacy delivery metadata unknown without failing the report' do
    at = Time.utc(2026, 10, 5)
    create_legacy_delivered_message(
      source_id: 'wamid.scalar-metadata', created_at: at,
      content_attributes: [], serialized: true
    )

    usage = described_class.new(account: account, now: at).perform

    expect(usage).to include(
      delivered_count: 1,
      free_service_quota_count: 0,
      free_service_quota_unknown_count: 1,
      free_service_quota_complete: false,
      estimate_complete: false
    )
  end

  it 'deduplicates historical deliveries and merges nil-timestamp journal metadata' do
    at = Time.utc(2026, 10, 5)
    free_metadata = whatsapp_delivery_attributes(category: 'service', type: 'free_customer_service', billable: false)
    create_legacy_delivered_message(
      source_id: 'wamid.history-free', created_at: Time.utc(2026, 10, 1),
      content_attributes: free_metadata, serialized: true
    )
    create_legacy_delivered_message(
      source_id: 'wamid.history-free', created_at: Time.utc(2026, 10, 1),
      content_attributes: free_metadata, channel: same_phone_channel
    )
    create_legacy_delivered_message(
      source_id: 'wamid.nil-timestamp', created_at: Time.utc(2026, 10, 2),
      status: :read
    )
    record_delivery(
      channel: first_channel, provider_message_id: 'wamid.nil-timestamp', delivered_at: nil,
      category: 'service', billable: false, pricing_type: 'free_customer_service'
    )
    create_legacy_delivered_message(
      source_id: 'wamid.already-counted', created_at: at,
      content_attributes: free_metadata, status: :read
    )
    record_delivery(
      channel: first_channel, provider_message_id: 'wamid.already-counted', delivered_at: at,
      category: 'service', billable: false, pricing_type: 'free_customer_service'
    )

    usage = described_class.new(account: account, now: at).perform

    expect(usage).to include(
      official_cloud_phone_count: 2,
      delivered_count: 3,
      free_service_quota_count: 3,
      free_service_quota_unknown_count: 0,
      free_service_quota_limit: 2_000,
      free_service_quota_limit_per_phone: 1_000,
      free_service_quota_complete: false,
      unknown_existing_delivery_count: 1,
      estimate_complete: false
    )
    expect(usage[:phones]).to include(
      include(phone_number: first_channel.phone_number, delivered_count: 3, free_service_quota_count: 3)
    )
    expect(usage[:category_breakdown]).to include(
      { category: 'service', delivered_count: 3, chargeable_count: 0, free_count: 3, unknown_billable_count: 0 }
    )
  end

  it 'excludes dated deliveries outside the month and free entry point from free quota' do
    at = Time.utc(2026, 10, 5)
    free_metadata = whatsapp_delivery_attributes(category: 'service', type: 'free_customer_service', billable: false)
    create_legacy_delivered_message(
      source_id: 'wamid.delivered-in-september', created_at: at, content_attributes: free_metadata
    )
    record_delivery(
      channel: first_channel, provider_message_id: 'wamid.delivered-in-september',
      delivered_at: Time.utc(2026, 9, 30, 23, 59), category: 'service', billable: false,
      pricing_type: 'free_customer_service'
    )
    create_legacy_delivered_message(
      source_id: 'wamid.free-entry-point', created_at: at,
      content_attributes: whatsapp_delivery_attributes(category: 'service', type: 'free_entry_point', billable: false),
      channel: second_channel
    )
    create_legacy_delivered_message(source_id: 'wamid.unknown-pricing', created_at: at, channel: second_channel)
    create_legacy_delivered_message(
      source_id: 'wamid.future-created', created_at: at + 1.minute, content_attributes: free_metadata
    )

    usage = described_class.new(account: account, now: at).perform

    expect(usage).to include(
      official_cloud_phone_count: 2,
      delivered_count: 2,
      free_service_quota_count: 0,
      free_service_quota_unknown_count: 1,
      free_service_quota_limit: 2_000,
      free_service_quota_limit_per_phone: 1_000,
      free_service_quota_complete: false,
      unknown_delivery_timestamp_count: 2,
      unknown_existing_delivery_count: 2,
      estimate_complete: false
    )
    expect(usage[:phones]).to contain_exactly(
      include(phone_number: first_channel.phone_number, delivered_count: 0, free_service_quota_count: 0,
              free_service_quota_limit: 1_000, free_service_quota_complete: true),
      include(phone_number: second_channel.phone_number, delivered_count: 2, free_service_quota_count: 0,
              free_service_quota_unknown_count: 1, free_service_quota_limit: 1_000,
              free_service_quota_complete: false)
    )
  end
end
