require 'rails_helper'
require Rails.root.join('db/migrate/20261011110000_add_captain_channel_membership')

RSpec.describe AddCaptainChannelMembership, type: :model do
  it 'preserves transitive graph reachability and can be rerun' do
    account = create(:account)
    inbox = create(:inbox, account: account)
    entry = create(:captain_assistant, account: account)
    middle = create(:captain_assistant, account: account)
    leaf = create(:captain_assistant, account: account)
    excluded = create(:captain_assistant, account: account)
    create(:captain_inbox, inbox: inbox, captain_assistant: entry)
    entry.update!(handoff_agent_ids: [middle.id])
    middle.update!(handoff_agent_ids: [leaf.id, excluded.id])
    excluded.update!(active: false)
    expected_ids = [entry.id, middle.id, leaf.id].sort

    described_class.new.backfill_membership!
    described_class.new.backfill_membership!

    expect(Captain::AgentChannel.where(inbox: inbox).pluck(:assistant_id).sort).to eq(expected_ids)
    expect(Captain::AgentChannel.where(inbox: inbox).count).to eq(expected_ids.size)
    expect(entry.handoff_agent_ids).to eq([middle.id])
  end
end
