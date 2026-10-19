# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::SingleDialogConsolidator do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:agent) { create(:user, account: account, role: :agent) }

  it 'consolidates duplicate conversations for the same contact and inbox and deduplicates activity messages' do
    conv1 = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :resolved)
    conv2 = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open, assignee: agent)

    msg1 = create(:message, account: account, inbox: inbox, conversation: conv1, content: 'Old message')
    msg2 = create(:message, account: account, inbox: inbox, conversation: conv2, content: 'New message')

    timestamp = Time.zone.parse('2026-10-19 12:55:04')
    act1 = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conv1,
      message_type: :activity,
      content: 'Agent assigned conversation to self',
      created_at: timestamp
    )
    act2 = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conv2,
      message_type: :activity,
      content: 'Agent assigned conversation to self',
      created_at: timestamp + 1.second
    )

    stats = described_class.new(account_id: account.id).perform

    expect(stats[:groups_consolidated]).to eq(1)
    expect(stats[:conversations_removed]).to eq(1)
    expect(Conversation.where(account_id: account.id, contact_id: contact.id, inbox_id: inbox.id).pluck(:id)).to eq([conv2.id])
    expect(msg1.reload.conversation_id).to eq(conv2.id)
    expect(msg2.reload.conversation_id).to eq(conv2.id)
    expect(Message.where(id: [act1.id, act2.id]).count).to eq(1)
  end

  it 'prevents ConversationBuilder from creating a second conversation for the same contact and inbox' do
    first_conv = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :resolved)

    returned_conv = ConversationBuilder.new(params: {}, contact_inbox: contact_inbox).perform

    expect(returned_conv.id).to eq(first_conv.id)
    expect(Conversation.where(account_id: account.id, contact_id: contact.id, inbox_id: inbox.id).count).to eq(1)
  end

  it 'emits only a single activity message when assigning a conversation across multiple contact conversations' do
    assigned_agent = agent
    other_inbox = create(:inbox, account: account)
    other_contact_inbox = create(:contact_inbox, contact: contact, inbox: other_inbox)
    conv1 = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    conv2 = create(:conversation, account: account, inbox: other_inbox, contact: contact, contact_inbox: other_contact_inbox)

    perform_enqueued_jobs(only: Conversations::ActivityMessageJob) do
      Current.user = assigned_agent
      conv1.update!(assignee: assigned_agent)
    ensure
      Current.user = nil
    end

    expect(conv1.reload.assignee_id).to eq(assigned_agent.id)
    expect(conv2.reload.assignee_id).to eq(assigned_agent.id)

    activity_messages = Message.where(conversation_id: [conv1.id, conv2.id], message_type: :activity)
    expect(activity_messages.count).to eq(1)
  end

  it 'persists custom email subject on outgoing email messages and updates conversation mail_subject' do
    email_channel = create(:channel_email, account: account)
    email_inbox = email_channel.inbox
    email_contact_inbox = create(:contact_inbox, contact: contact, inbox: email_inbox)
    email_conv = create(
      :conversation,
      account: account,
      inbox: email_inbox,
      contact: contact,
      contact_inbox: email_contact_inbox,
      additional_attributes: { 'mail_subject' => 'Initial Subject' }
    )

    params = ActionController::Parameters.new(
      content: 'Follow-up body',
      mail_subject: 'Updated Topic Subject'
    )

    msg = Messages::MessageBuilder.new(agent, email_conv, params).perform

    expect(msg.content_attributes.dig('email', 'subject')).to eq('Updated Topic Subject')
    expect(email_conv.reload.additional_attributes['mail_subject']).to eq('Updated Topic Subject')
  end
end
