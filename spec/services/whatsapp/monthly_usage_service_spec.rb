require 'rails_helper'

RSpec.describe Whatsapp::MonthlyUsageService do
  let(:account) { create(:account) }
  let!(:first_channel) do
    create(:channel_whatsapp, account: account, phone_number: '+77010000001', provider: 'whatsapp_cloud',
                              sync_templates: false, validate_provider_config: false)
  end
  let!(:second_channel) do
    create(:channel_whatsapp, account: account, phone_number: '+77010000002', provider: 'whatsapp_cloud',
                              sync_templates: false, validate_provider_config: false)
  end

  before do
    tracking_state = WhatsappUsageTrackingState.current_or_create!
    tracking_state.update!(tracking_started_at: Time.utc(2026, 9, 1))
  end

  def record_delivery(channel:, provider_message_id:, delivered_at:, category:, billable:)
    WhatsappUsageDelivery.create!(
      account_id: account.id,
      phone_number: WhatsappUsageDelivery.canonical_phone_number(channel.phone_number),
      provider_message_id: provider_message_id,
      inbox_id: channel.inbox.id,
      delivered_at: delivered_at,
      received_at: delivered_at,
      category: category,
      billable: billable
    )
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
      estimated_amount_kzt: 16,
      free_service_allowance_per_phone: 1_000,
      service_allowance_applied: false,
      coverage_complete: true,
      service_estimate_complete: true,
      estimate_complete: false,
      template_costs_included: false
    )
    expect(usage[:phones]).to contain_exactly(
      include(phone_number: '+77010000001', delivered_count: 3, chargeable_service_count: 2, estimated_amount_kzt: 16),
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
      estimated_amount_kzt: 0,
      estimate_complete: false
    )
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
      estimated_amount_kzt: 0,
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
      estimated_amount_kzt: 0,
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

  it 'counts existing delivered Cloud messages without a provider timestamp as unassigned history' do
    created_at = Time.utc(2026, 10, 3, 10)
    create(
      :message,
      account: account,
      inbox: first_channel.inbox,
      message_type: :outgoing,
      status: :delivered,
      source_id: 'wamid.legacy-delivered',
      created_at: created_at
    )
    echo = create(
      :message,
      account: account,
      inbox: first_channel.inbox,
      message_type: :outgoing,
      status: :delivered,
      source_id: 'wamid.legacy-echo',
      content_attributes: { external_echo: true },
      created_at: created_at
    )
    write_content_attributes_json(echo, JSON.generate(external_echo: true))
    serialized_echo = create(
      :message,
      account: account,
      inbox: first_channel.inbox,
      message_type: :outgoing,
      status: :delivered,
      source_id: 'wamid.legacy-echo-string',
      content_attributes: { external_echo: true },
      created_at: created_at
    )
    serialized_echo_json = JSON.generate(JSON.generate(external_echo: true))
    write_content_attributes_json(serialized_echo, serialized_echo_json)
    object_history = create(
      :message,
      account: account,
      inbox: first_channel.inbox,
      message_type: :outgoing,
      status: :delivered,
      source_id: 'wamid.legacy-history-object',
      content_attributes: { whatsapp_history_import: true },
      created_at: created_at
    )
    write_content_attributes_json(object_history, JSON.generate(whatsapp_history_import: true))
    serialized_history = create(
      :message,
      account: account,
      inbox: first_channel.inbox,
      message_type: :outgoing,
      status: :delivered,
      source_id: 'wamid.legacy-history-string',
      content_attributes: { whatsapp_history_import: true },
      created_at: created_at
    )
    serialized_history_json = JSON.generate(JSON.generate(whatsapp_history_import: true))
    write_content_attributes_json(serialized_history, serialized_history_json)
    object_import = create(
      :message,
      account: account,
      inbox: first_channel.inbox,
      message_type: :outgoing,
      status: :delivered,
      source_id: 'wamid.legacy-import-object',
      content_attributes: { imported_history: true },
      created_at: created_at
    )
    write_content_attributes_json(object_import, JSON.generate(imported_history: true))
    serialized_import = create(
      :message,
      account: account,
      inbox: first_channel.inbox,
      message_type: :outgoing,
      status: :delivered,
      source_id: 'wamid.legacy-import-string',
      content_attributes: { imported_history: true },
      created_at: created_at
    )
    serialized_import_json = JSON.generate(JSON.generate(imported_history: true))
    write_content_attributes_json(serialized_import, serialized_import_json)

    expect({
      object_echo: content_attributes_json_type(echo),
      serialized_echo: content_attributes_json_type(serialized_echo),
      object_history: content_attributes_json_type(object_history),
      serialized_history: content_attributes_json_type(serialized_history),
      object_import: content_attributes_json_type(object_import),
      serialized_import: content_attributes_json_type(serialized_import)
    }).to eq(
      object_echo: 'object',
      serialized_echo: 'string',
      object_history: 'object',
      serialized_history: 'string',
      object_import: 'object',
      serialized_import: 'string'
    )
    expect(serialized_echo.reload.content_attributes['external_echo']).to be(true)
    create(
      :message,
      account: account,
      inbox: first_channel.inbox,
      message_type: :outgoing,
      status: :delivered,
      source_id: 'wamid.legacy-recorded',
      created_at: created_at
    )
    record_delivery(channel: first_channel, provider_message_id: 'wamid.legacy-recorded',
                    delivered_at: created_at, category: 'service', billable: true)

    usage = described_class.new(account: account, now: Time.utc(2026, 10, 5)).perform

    expect(usage).to include(
      delivered_count: 1,
      unknown_delivery_timestamp_count: 1,
      unknown_existing_delivery_count: 1,
      coverage_complete: false,
      estimate_complete: false
    )
    expect(usage[:phones]).to include(
      include(phone_number: first_channel.phone_number, unknown_existing_delivery_count: 1)
    )
  end
end
