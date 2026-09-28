require 'rails_helper'

RSpec.describe Captain::Conversation::DeliveryFenceService do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_widget, account: account).inbox }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:incoming) { create(:message, account: account, conversation: conversation, inbox: inbox, message_type: :incoming) }
  let(:message) do
    create(:message, account: account, conversation: conversation, inbox: inbox, sender: assistant,
                     message_type: :outgoing, additional_attributes: {
                       captain_delivery_fence: {
                         control_generation: conversation.current_captain_control_generation,
                         assistant_id: assistant.id,
                         trigger_message_id: incoming.id,
                         kind: 'reply'
                       }
                     })
  end

  before { create(:captain_inbox, captain_assistant: assistant, inbox: inbox) }

  it 'claims and dispatches a public response only once across job retries' do
    expect do
      described_class.new(message).perform { :attempted }
    end.to change { message.reload.additional_attributes['captain_delivery_state'] }.from(nil).to('submitted')
    expect { described_class.new(message.reload).perform { raise 'duplicate dispatch' } }.not_to raise_error
  end

  it 'applies a synchronous delivered acknowledgement only after the provider claim is submitted' do
    status_during_dispatch = nil
    described_class.new(message).perform do
      status_during_dispatch = Messages::StatusUpdateService.new(message, 'delivered').perform
      :delivered
    end

    expect(status_during_dispatch).to be false
    expect(message.reload.additional_attributes['captain_delivery_state']).to eq('submitted')
    expect(message.status).to eq('delivered')
  end

  it 'cancels an AI reply when an unlinked channel has a newer human response' do
    message
    sibling = create(:conversation, account: account, contact: conversation.contact)
    agent = create(:user, account: account)
    create(:message, account: account, conversation: sibling, sender: agent, message_type: :outgoing)

    expect { described_class.new(message).perform { raise 'late send' } }.not_to raise_error
    expect(message.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
  end

  it 'cancels an AI reply when a newer customer message arrives on another channel' do
    sibling = create(:conversation, account: account, contact: conversation.contact)
    message
    create(:message, account: account, conversation: sibling, message_type: :incoming)

    expect { described_class.new(message).perform { raise 'late send' } }.not_to raise_error
    expect(message.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
  end

  it 'cancels an unfenced legacy reply after a newer incoming on another channel' do
    legacy_reply = create(:message, account: account, conversation: conversation, inbox: inbox,
                                    sender: assistant, message_type: :outgoing, additional_attributes: {})
    sibling = create(:conversation, account: account, contact: conversation.contact)
    create(:message, account: account, conversation: sibling, message_type: :incoming)
    expect(conversation.current_captain_control_generation).to eq(0)

    expect { described_class.new(legacy_reply).perform { raise 'late legacy send' } }.not_to raise_error
    expect(legacy_reply.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
  end

  %w[reply handoff resolution follow_up reminder].each do |kind|
    it "fails closed on an unstamped #{kind} Captain public message without a trigger snapshot" do
      attributes = kind == 'follow_up' ? { captain_follow_up: true } : {}
      legacy = create(:message, account: account, conversation: conversation, inbox: inbox,
                                sender: assistant, message_type: :outgoing, additional_attributes: attributes)
      expect { described_class.new(legacy).perform { raise 'unstamped provider send' } }.not_to raise_error
      expect(legacy.reload.additional_attributes['captain_delivery_state']).to eq('cancelled')
    end
  end

  it 'leaves an ambiguous provider outcome fenced, rather than retrying the send' do
    described_class.new(message).perform { raise Timeout::Error, 'provider read timeout' }
    expect(message.reload.additional_attributes['captain_delivery_state']).to eq('outcome_unknown')
    expect { described_class.new(message.reload).perform { raise 'duplicate dispatch' } }.not_to raise_error
  end

  it 'keeps a provider-deferred send retryable only after its scheduled time' do
    message.update!(source_id: nil, status: :sent, content_attributes: {
                      whatsapp_cloud_send_retry_count: 1,
                      whatsapp_cloud_send_retry_next_at: 5.minutes.from_now.iso8601
                    })

    described_class.new(message).perform { :deferred }
    expect(message.reload.additional_attributes['captain_delivery_state']).to eq('deferred')
    expect { described_class.new(message.reload).perform { raise 'sent too early' } }.not_to raise_error

    travel 6.minutes do
      described_class.new(message.reload).perform { :attempted }
    end
    expect(message.reload.additional_attributes['captain_delivery_state']).to eq('submitted')
  end

  it 're-raises a pre-claim failure instead of marking delivery outcome unknown' do
    service = described_class.new(message)
    allow(service).to receive(:claim_pending_delivery!).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { service.perform { raise 'provider must not run' } }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    expect(message.reload.additional_attributes['captain_delivery_state']).to be_nil
  end
end
