require 'rails_helper'

RSpec.describe Conversations::LastSeenUpdater do
  let(:conversation) { create(:conversation, agent_last_seen_at: 20.minutes.ago).reload }

  it 'does not let a delayed read request move the shared cursor backwards' do
    existing_cursor = conversation.agent_last_seen_at

    described_class.new(conversation: conversation).perform(last_seen_at: existing_cursor - 1.minute)

    expect(conversation.reload.agent_last_seen_at).to eq(existing_cursor)
  end

  it 'allows a manual unread action to move the shared cursor back and broadcast the change' do
    manual_unread_cursor = conversation.agent_last_seen_at - 5.minutes
    actor = create(:user, account: conversation.account)
    expect(conversation).to receive(:dispatch_read_state_update).with(actor: actor)

    described_class.new(conversation: conversation).perform(
      last_seen_at: manual_unread_cursor,
      broadcast_read_state: true,
      allow_regression: true,
      actor: actor
    )

    expect(conversation.reload.agent_last_seen_at).to eq(manual_unread_cursor)
  end
end
