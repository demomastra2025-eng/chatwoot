require 'rails_helper'

RSpec.describe Captain::ReplyNotificationContext do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }

  def context_for(message)
    described_class.for(account: account, conversation: conversation, incoming_message_id: message.id, assistant: assistant)
  end

  it 'identifies a reminder and its current-contact appointment through an explicit reply link' do
    appointment = create(:scheduling_appointment, account: account, contact: contact, conversation: conversation)
    reminder = create(:reminder, account: account, touch_conversation: conversation, remindable: appointment)
    delivery = create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                                message_type: 'outgoing', additional_attributes: { 'touch_id' => reminder.id })
    reply = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, sender: contact,
                             content_attributes: { 'in_reply_to' => delivery.id })

    expect(context_for(reply)).to include(kind: 'reminder', reminder_id: reminder.id,
                                          appointment_id: appointment.id, appointment: include(id: appointment.id),
                                          delivery_message_id: delivery.id)
  end

  it 'uses the stored confirmation resolution link when no message reply metadata exists' do
    delivery = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: 'outgoing')
    reply = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, sender: contact)
    confirmation = create(:confirmation_request, account: account, conversation: conversation, contact: contact,
                                                 inbox: conversation.inbox, delivery_message: delivery, resolved_message: reply)

    expect(context_for(reply)).to include(kind: 'notification', confirmation_request_id: confirmation.id)
  end

  it 'omits unlinked or foreign-contact replies rather than guessing the last reminder' do
    reminder = create(:reminder, account: account, touch_conversation: conversation)
    delivery = create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                                message_type: 'outgoing', additional_attributes: { 'touch_id' => reminder.id })
    unrelated = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, sender: contact)
    other_sender = create(:contact, account: account)
    foreign = create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                               sender: other_sender, content_attributes: { 'in_reply_to' => delivery.id })

    expect(context_for(unrelated)).to be_nil
    expect(context_for(foreign)).to be_nil
  end
end
