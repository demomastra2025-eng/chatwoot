# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TelegramPersonal::CallCleanupJob do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_telegram_personal, account: account) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '771122') }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:gateway_client) { instance_double(TelegramPersonal::GatewayClient) }

  before do
    Current.suppress_runtime_events = true
    Conversation.skip_callback(:create, :before, :determine_conversation_status)
    Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
    allow(TelegramPersonal::GatewayClient).to receive(:new).and_return(gateway_client)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  it 'expires stale ringing calls after timeout and notifies gateway and ActionCable' do
    stale_call = Call.create!(
      provider: :telegram_personal, account: account, inbox: inbox, conversation: conversation,
      contact: contact, provider_call_id: 'tg-stale-1', media_session_id: 'tg-stale-sess-1',
      direction: :incoming, status: 'ringing', created_at: 2.minutes.ago
    )
    msg = TelegramPersonal::CallMessageBuilder.create!(conversation: conversation, call: stale_call)
    stale_call.update!(message_id: msg.id)

    allow(ActionCable.server).to receive(:broadcast)
    expect(gateway_client).to receive(:reject_call!).with(
      call_ref: 'tg-stale-sess-1', reason: 'missed'
    ).and_return({ ok: true })

    described_class.perform_now(stale_call.id)

    stale_call.reload
    expect(stale_call.status).to eq('no_answer')
    expect(stale_call.end_reason).to eq('timeout')
    expect(msg.reload.content_attributes.dig('data', 'status')).to eq('no-answer')
    expect(ActionCable.server).to have_received(:broadcast).with(
      "account_#{account.id}",
      hash_including(event: 'telegram_personal_call.ended')
    )
  end
end
