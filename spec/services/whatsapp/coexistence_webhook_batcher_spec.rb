require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceWebhookBatcher do
  it 'bounds history messages and keeps progress metadata only on the final slice' do
    messages = Array.new(61) { |index| { id: "wamid.#{index}" } }
    value = {
      metadata: { phone_number_id: 'phone-1' },
      history: [{
        metadata: { progress: 100, chunk_order: 7 },
        threads: [{ id: 'contact-1', messages: messages }]
      }]
    }

    batches = described_class.new('history', value).perform

    expect(batches.size).to eq(3)
    expect(batches.flat_map { |batch| batch.dig(:history, 0, :threads, 0, :messages) }.pluck(:id)).to eq(messages.pluck(:id))
    expect(batches.map { |batch| batch.dig(:history, 0, :threads, 0, :messages).size }).to eq([25, 25, 11])
    expect(batches.first(2)).to all(satisfy { |batch| batch.dig(:history, 0, :metadata).blank? })
    expect(batches.last.dig(:history, 0, :metadata)).to include(progress: 100, chunk_order: 7)
  end

  it 'processes top-level history media one item per WABA lock slice' do
    value = { metadata: { phone_number_id: 'phone-1' }, messages: [{ id: 'media-1' }, { id: 'media-2' }] }

    batches = described_class.new('history', value).perform

    expect(batches.map { |batch| batch[:messages].pluck(:id) }).to eq([['media-1'], ['media-2']])
  end

  it 'keeps progress metadata only on the final slice across multiple threads' do
    value = {
      history: [{
        metadata: { progress: 100, chunk_order: 7 },
        threads: [
          { id: 'contact-1', messages: Array.new(26) { |index| { id: "first-#{index}" } } },
          { id: 'contact-2', messages: Array.new(26) { |index| { id: "second-#{index}" } } }
        ]
      }]
    }

    batches = described_class.new('history', value).perform

    expect(batches.size).to eq(4)
    expect(batches.first(3)).to all(satisfy { |batch| batch.dig(:history, 0, :metadata).blank? })
    expect(batches.last.dig(:history, 0, :metadata)).to include(progress: 100, chunk_order: 7)
  end

  it 'preserves each message echo exactly once instead of duplicating it across history slices' do
    history_messages = Array.new(26) { |index| { id: "history-#{index}" } }
    value = {
      history: [{ threads: [{ messages: history_messages }] }],
      message_echoes: [{ id: 'echo-1' }, { id: 'echo-2' }]
    }

    batches = described_class.new('history', value).perform

    expect(batches.flat_map { |batch| Array(batch.dig(:history, 0, :threads, 0, :messages)) }.pluck(:id)).to eq(
      history_messages.pluck(:id)
    )
    expect(batches.flat_map { |batch| Array(batch[:message_echoes]) }.pluck(:id)).to contain_exactly('echo-1', 'echo-2')
    expect(batches).to all(satisfy { |batch| Array(batch[:message_echoes]).size <= described_class::MEDIA_MESSAGES_PER_BATCH })
  end

  it 'bounds contact state sync events' do
    entries = Array.new(101) { |index| { contact: { phone_number: index.to_s } } }

    batches = described_class.new('smb_app_state_sync', { state_sync: entries }).perform

    expect(batches.map { |batch| batch[:state_sync].size }).to eq([50, 50, 1])
    expect(batches.flat_map { |batch| batch[:state_sync] }).to eq(entries.map(&:with_indifferent_access))
  end
end
