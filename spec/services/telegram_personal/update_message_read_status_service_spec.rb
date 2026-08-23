require 'rails_helper'

RSpec.describe TelegramPersonal::UpdateMessageReadStatusService do
  let(:channel) { create(:channel_telegram_personal) }
  let(:contact) { create(:contact, account: channel.account) }
  let(:contact_inbox) do
    create(:contact_inbox, contact: contact, inbox: channel.inbox, source_id: 'peer-1')
  end
  let(:conversation) do
    create(
      :conversation,
      account: channel.account,
      inbox: channel.inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
  end

  def create_message(source_id:, status: :sent, message_type: :outgoing, target_conversation: conversation)
    create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: target_conversation,
      source_id: source_id,
      status: status,
      message_type: message_type
    )
  end

  it 'updates only unread numeric outgoing messages up to the provider max id' do
    eligible = create_message(source_id: '101')
    already_read = create_message(source_id: '100', status: :read)
    above_max = create_message(source_id: '102')
    non_numeric = create_message(source_id: 'local-message')
    incoming = create_message(source_id: '99', message_type: :incoming)
    other_contact_inbox = create(:contact_inbox, inbox: channel.inbox, source_id: 'peer-2')
    other_conversation = create(
      :conversation,
      account: channel.account,
      inbox: channel.inbox,
      contact: other_contact_inbox.contact,
      contact_inbox: other_contact_inbox
    )
    other_contact_message = create_message(source_id: '98', target_conversation: other_conversation)
    allow(Messages::StatusUpdateService).to receive(:new).and_call_original

    described_class.new(inbox: channel.inbox, params: { chat_id: 'peer-1', max_id: 101 }).perform

    expect(Messages::StatusUpdateService).to have_received(:new).once.with(eligible, 'read')
    expect(eligible.reload).to be_read
    expect(already_read.reload).to be_read
    expect(above_max.reload).to be_sent
    expect(non_numeric.reload).to be_sent
    expect(incoming.reload).to be_sent
    expect(other_contact_message.reload).to be_sent
  end

  it 'does nothing when the provider max id is invalid' do
    message = create_message(source_id: '101')

    described_class.new(inbox: channel.inbox, params: { chat_id: 'peer-1', max_id: 0 }).perform

    expect(message.reload).to be_sent
  end
end
