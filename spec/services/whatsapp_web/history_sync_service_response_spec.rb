require 'rails_helper'

RSpec.describe WhatsappWeb::HistorySyncService do
  let(:channel) { create(:channel_whatsapp_web, connection_state: 'open', lifecycle_state: 'connected') }
  let(:provider) { instance_double(WhatsappWeb::Providers::EvolutionService) }
  let(:record) do
    { 'key' => { 'id' => 'CONTRACT_RECORD', 'remoteJid' => '15550000001@s.whatsapp.net', 'fromMe' => false },
      'messageTimestamp' => 1.hour.ago.to_i, 'message' => { 'conversation' => 'Historical text' } }
  end

  before do
    channel.record_provider_history_snapshot!(message_count: 3, contact_count: 1)
    channel.request_history_sync!('full', expected_provider_history_synced_at: channel.provider_history_synced_at)
    allow(channel).to receive(:provider_service).and_return(provider)
    allow(provider).to receive_messages(fetch_contacts: [], fetch_chats: [], fetch_messages: page([], 1))
    clear_enqueued_jobs
  end

  def page(records, count)
    { 'messages' => { 'records' => records, 'pages' => count } }
  end

  def perform
    described_class.new(channel: channel, mode: 'full').perform
  end

  def expect_unconfirmed
    channel.reload
    expect(channel.full_history_baseline_present?).to be(false)
    expect(channel.local_history_provider_synced_at).to be_nil
    expect(channel.sync_state_payload['full_history_policy_version']).to be_nil
    expect(channel.sync_state_payload['last_history_sync_error']).to be_present
  end

  it 'rejects structurally absent, null, malformed or non-object first-page records', :aggregate_failures do
    [{}, nil, { 'messages' => nil }, page(nil, 1), page({}, 1), page([nil], 1)].each do |response|
      allow(provider).to receive(:fetch_messages).and_return(response)
      expect { perform }.to raise_error(described_class::InvalidResponse)
      expect_unconfirmed
    end
    expect(enqueued_jobs.map { |job| job[:job] }).not_to include(SendReplyJob, EventDispatcherJob, AutoAssignment::AssignmentJob)
  end

  it 'does not certify a snapshot when a later page is malformed after an earlier page was imported', :aggregate_failures do
    allow(provider).to receive(:fetch_messages).with(page: 1, offset: 100, from: nil).and_return(page([], 3))
    allow(provider).to receive(:fetch_messages).with(page: 3, offset: 100, from: nil).and_return(page([record], 3))
    allow(provider).to receive(:fetch_messages).with(page: 2, offset: 100, from: nil).and_return(page({}, 3))
    expect { perform }.to raise_error(described_class::InvalidResponse, /page 2/)
    expect(channel.inbox.messages.find_by(source_id: 'CONTRACT_RECORD')).to be_present
    expect_unconfirmed
    expect(channel.history_sync_request_pending?).to be(true)
    expect(enqueued_jobs.map { |job| job[:job] }).not_to include(SendReplyJob, EventDispatcherJob, AutoAssignment::AssignmentJob)
  end

  %i[fetch_contacts fetch_chats].each do |method|
    it "rejects a malformed raw #{method} list instead of treating it as empty" do
      allow(provider).to receive(method).and_return({})
      expect { perform }.to raise_error(described_class::InvalidResponse)
      expect_unconfirmed
    end
  end

  it 'rejects missing or malformed pagination for a nonempty records page', :aggregate_failures do
    [nil, 'bad', 0, -1, 1.5].each do |count|
      allow(provider).to receive(:fetch_messages).and_return(page([record], count))
      expect { perform }.to raise_error(described_class::InvalidResponse, /page count/)
      expect_unconfirmed
    end
    expect(channel.inbox.messages).to be_empty
  end

  it 'rejects pagination changes on later pages' do
    allow(provider).to receive(:fetch_messages).with(page: 1, offset: 100, from: nil).and_return(page([record], 2))
    allow(provider).to receive(:fetch_messages).with(page: 2, offset: 100, from: nil).and_return(page([record], 'bad'))
    expect { perform }.to raise_error(described_class::InvalidResponse, /page count/)
    expect_unconfirmed
  end

  [0, 1, nil].each do |count|
    it "accepts explicitly empty records with page count #{count.inspect}" do
      allow(provider).to receive(:fetch_messages).and_return(page([], count))
      expect(perform).to eq(messages_imported: 0, contacts_touched: 0)
      expect(channel.reload.full_history_baseline_current?).to be(true)
      expect(channel.sync_state_payload['full_history_policy_version']).to eq(1)
    end
  end

  it 'can retry the failed request and confirm it only after a valid response' do
    allow(provider).to receive(:fetch_messages).and_return({})
    expect { perform }.to raise_error(described_class::InvalidResponse)
    expect_unconfirmed
    allow(provider).to receive(:fetch_messages).and_return(page([], 1))
    perform
    expect(channel.reload.full_history_baseline_current?).to be(true)
    expect(channel.sync_state_payload['last_history_sync_error']).to be_nil
  end
end
