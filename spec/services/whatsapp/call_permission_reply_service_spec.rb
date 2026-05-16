require 'rails_helper'

RSpec.describe Whatsapp::CallPermissionReplyService do
  let(:account) { create(:account) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: { 'source' => 'embedded_signup', 'calling_enabled' => true },
      validate_provider_config: false,
      sync_templates: false
    )
  end
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, :with_phone_number, account: account) }
  let!(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      additional_attributes: {
        'call_permission_requested_at' => 1.minute.ago.iso8601,
        'call_permission_request_message_id' => 'wamid.permission-1'
      }
    )
  end
  let!(:other_conversation) do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      additional_attributes: {
        'call_permission_requested_at' => 1.minute.ago.iso8601,
        'call_permission_request_message_id' => 'wamid.permission-2'
      }
    )
  end

  before do
    Current.suppress_runtime_events = true
    Conversation.skip_callback(:create, :before, :determine_conversation_status)
    Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
    account.enable_features!('whatsapp_call')
    allow(ActionCable.server).to receive(:broadcast)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  def reply_params(response:, context_id: 'wamid.permission-1')
    message = {
      from: contact.phone_number.delete('+'),
      interactive: {
        call_permission_reply: {
          response: response,
          is_permanent: true
        }
      }
    }
    message[:context] = { id: context_id } if context_id

    { entry: [{ changes: [{ value: { messages: [message] } }] }] }
  end

  it 'matches the accepted permission reply by WhatsApp context id' do
    described_class.new(
      inbox: inbox,
      params: reply_params(response: 'accept')
    ).perform

    expect(conversation.reload.additional_attributes).not_to include('call_permission_requested_at', 'call_permission_request_message_id')
    expect(other_conversation.reload.additional_attributes).to include('call_permission_request_message_id' => 'wamid.permission-2')
    expect(ActionCable.server).to have_received(:broadcast).with(
      "account_#{account.id}",
      hash_including(event: 'whatsapp_call.permission_granted', data: hash_including(conversation_id: conversation.id))
    )
  end

  it 'does nothing when the contact rejects the request' do
    described_class.new(inbox: inbox, params: reply_params(response: 'reject')).perform

    expect(conversation.reload.additional_attributes).to include('call_permission_request_message_id' => 'wamid.permission-1')
    expect(ActionCable.server).not_to have_received(:broadcast)
  end

  it 'does nothing when the reply has no context id' do
    described_class.new(inbox: inbox, params: reply_params(response: 'accept', context_id: nil)).perform

    expect(conversation.reload.additional_attributes).to include('call_permission_request_message_id' => 'wamid.permission-1')
    expect(ActionCable.server).not_to have_received(:broadcast)
  end

  it 'does nothing when WhatsApp calling is disabled on the channel' do
    channel.update!(provider_config: channel.provider_config.merge('calling_enabled' => false))

    described_class.new(inbox: inbox, params: reply_params(response: 'accept')).perform

    expect(conversation.reload.additional_attributes).to include('call_permission_request_message_id' => 'wamid.permission-1')
    expect(ActionCable.server).not_to have_received(:broadcast)
  end
end
