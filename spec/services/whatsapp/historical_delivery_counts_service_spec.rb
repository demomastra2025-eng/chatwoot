# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::HistoricalDeliveryCountsService do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, account: account, phone_number: '+77015550101', provider: 'whatsapp_cloud',
                              sync_templates: false, validate_provider_config: false)
  end
  let(:period_start) { Time.utc(2026, 11, 1) }
  let(:period_end) { Time.utc(2026, 12, 1) }
  let(:period) { period_start...period_end }
  let(:now) { Time.utc(2026, 11, 2, 8, 0, 0) }
  let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }

  def create_delivered_message(source_id:, created_at: Time.utc(2026, 11, 1, 12, 0, 0), status: :delivered, category: 'service', billable: false)
    create(
      :message,
      account: account,
      inbox: channel.inbox,
      message_type: :outgoing,
      status: status,
      private: false,
      source_id: source_id,
      created_at: created_at,
      content_attributes: {
        whatsapp_delivery: {
          status: 'delivered',
          pricing: { category: category, type: billable ? 'regular' : 'free_customer_service', billable: billable }
        }
      }
    )
  end

  it 'fast-exits with zero queries when channels list is empty or now is before period start' do
    existing_account = account
    existing_channel = channel
    existing_channel.inbox
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:name] == 'SCHEMA' || payload[:cached]

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      empty_res = described_class.new(account: existing_account, channels: [], period: period, now: now).perform
      early_res = described_class.new(account: existing_account, channels: [existing_channel], period: period, now: period_start - 1.minute).perform

      expect(empty_res.delivery_groups).to be_empty
      expect(early_res.delivery_groups).to be_empty
      expect(empty_res.unknown_existing_counts['77015550101']).to eq(0)
    end

    expect(queries).to be_empty
  end

  context 'with Rails.cache MemoryStore enabled' do
    before do
      allow(Rails).to receive(:cache).and_return(memory_cache)
    end

    it 'serves repeated polls from short-TTL cache and preserves Hash default(0) semantics' do
      create_delivered_message(source_id: 'wamid.cached-1')

      first_service = described_class.new(account: account, channels: [channel], period: period, now: now)
      first_result = first_service.perform
      expect(first_result.delivery_groups[['77015550101', 'service', false, nil]]).to eq(1)
      expect(first_result.free_quota_counts['77015550101']).to eq(1)

      second_service = described_class.new(account: account, channels: [channel], period: period, now: now + 45.seconds)
      expect(second_service).not_to receive(:compute_counts)

      second_result = second_service.perform
      expect(second_result.delivery_groups[['77015550101', 'service', false, nil]]).to eq(1)
      expect(second_result.delivery_groups[['77015550101', 'missing', false, nil]]).to eq(0)
      expect(second_result.unknown_existing_counts['nonexistent']).to eq(0)
    end

    it 'invalidates cache immediately when a new message becomes delivered or a ledger row is recorded' do
      pending_msg = create_delivered_message(source_id: 'wamid.pending-1', status: :sent, billable: true)

      initial = described_class.new(account: account, channels: [channel], period: period, now: now).perform
      expect(initial.delivery_groups.values.sum).to eq(0)

      # Transition sent -> delivered immediately changes the indexed fingerprint
      pending_msg.update!(status: :delivered)
      after_delivery = described_class.new(account: account, channels: [channel], period: period, now: now + 5.seconds).perform
      expect(after_delivery.delivery_groups[['77015550101', 'service', true, nil]]).to eq(1)

      # Recording dated WhatsappUsageDelivery immediately changes deliveries_fingerprint and excludes it from historical fallback
      WhatsappUsageDelivery.create!(
        account_id: account.id,
        phone_number: '77015550101',
        provider_message_id: 'wamid.pending-1',
        inbox_id: channel.inbox.id,
        delivered_at: now,
        received_at: now,
        category: 'service',
        billable: true,
        recipient_country: 'KZ'
      )

      after_ledger = described_class.new(account: account, channels: [channel], period: period, now: now + 10.seconds).perform
      expect(after_ledger.delivery_groups.values.sum).to eq(0)
    end

    it 'degrades gracefully to direct computation if Rails.cache raises an error' do
      create_delivered_message(source_id: 'wamid.redis-down')
      allow(memory_cache).to receive(:read).and_raise(StandardError, 'Redis connection refused')
      allow(memory_cache).to receive(:write).and_raise(StandardError, 'Redis connection refused')

      result = described_class.new(account: account, channels: [channel], period: period, now: now).perform
      expect(result.free_quota_counts['77015550101']).to eq(1)
    end
  end

  it 'defines the partial composite index for historical WhatsApp delivery lookups' do
    indexes = ActiveRecord::Base.connection.indexes(:messages)
    wa_index = indexes.find { |idx| idx.name == 'index_messages_on_acc_inbox_created_for_wa_deliveries' }

    expect(wa_index).to be_present
    expect(wa_index.columns).to eq(%w[account_id inbox_id created_at id updated_at])
    expect(wa_index.where).to include('private = false')
  end
end
