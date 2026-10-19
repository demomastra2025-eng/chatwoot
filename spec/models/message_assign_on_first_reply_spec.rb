# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Message, 'assign_conversation_to_responding_agent' do
  let(:account) { create(:account, conversation_auto_assignment_enabled: false, conversation_assign_on_first_reply_enabled: true) }
  let(:inbox) { create(:inbox, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: nil) }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
    create(:inbox_member, inbox: inbox, user: other_agent)
  end

  it 'assigns an unassigned conversation to the agent who sends the first public outgoing reply' do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, sender: agent)

    expect(conversation.reload.assignee).to eq(agent)
  end

  it 'does not assign the conversation when the agent writes a private note' do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, private: true, sender: agent)

    expect(conversation.reload.assignee).to be_nil
  end

  it 'does not overwrite an existing assignee when another agent replies' do
    conversation.update!(assignee: other_agent)

    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, sender: agent)

    expect(conversation.reload.assignee).to eq(other_agent)
  end

  it 'does not assign the conversation when conversation_assign_on_first_reply_enabled is false' do
    account.update!(conversation_assign_on_first_reply_enabled: false)

    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, sender: agent)

    expect(conversation.reload.assignee).to be_nil
  end
end
