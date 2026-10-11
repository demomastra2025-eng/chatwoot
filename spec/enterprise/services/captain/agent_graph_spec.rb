require 'rails_helper'

RSpec.describe Captain::AgentGraph do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: account) }
  let(:entry) { create(:captain_assistant, account: account) }
  let(:member) { create(:captain_assistant, account: account, channel_scope: 'selected') }
  let(:other) { create(:captain_assistant, account: account, channel_scope: 'selected') }

  it 'routes directly between active external members of one inbox without saved edges' do
    Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: member)
    Captain::AgentChannel.create!(account: account, inbox: other_inbox, assistant: other)

    graph = described_class.new(entry, inbox: inbox)
    expect(graph.agents.map(&:id)).to contain_exactly(entry.id, member.id)
    expect(graph.allows?(entry, member)).to be(true)
    expect(graph.allows?(member, entry)).to be(true)
    expect(graph.allows?(member, other)).to be(false)
    expect(graph.allows?(entry, entry)).to be(false)
    expect(graph.payload.first).not_to have_key(:target_ids)
  end

  it 'uses all active external agents in a Playground without an inbox' do
    member
    other
    expect(described_class.new(entry).agents.map(&:id)).to contain_exactly(entry.id, member.id, other.id)
  end
end
