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
    expect(graph.peers?).to be(true)
    expect(graph.allows?(entry, member)).to be(true)
    expect(graph.allows?(member, entry)).to be(true)
    expect(graph.allows?(member, other)).to be(false)
    expect(graph.allows?(entry, entry)).to be(false)
    expect(graph.payload.first).not_to have_key(:target_ids)
  end

  it 'raises a dedicated error, still an ArgumentError, when the entry agent is disabled' do
    entry.update_columns(active: false)

    expect { described_class.new(entry, inbox: inbox).agents }
      .to raise_error(described_class::EntryDisabledError, 'The entry agent is disabled')
    expect(described_class::EntryDisabledError.ancestors).to include(ArgumentError)
  end

  it 'lets the entry agent work alone when there is no channel, whatever else the workspace has' do
    member
    other
    graph = described_class.new(entry)

    expect(graph.agents).to eq([entry])
    expect(graph.payload.pluck(:id)).to eq([entry.id])
    expect(graph.peers?).to be(false)
    expect(graph.allows?(entry, member)).to be(false)
  end

  it 'has no peers when the entry agent is the only agent of its channel' do
    other
    Captain::AgentChannel.create!(account: account, inbox: other_inbox, assistant: other)

    graph = described_class.new(entry, inbox: inbox)

    expect(graph.agents).to eq([entry])
    expect(graph.peers?).to be(false)
    expect(graph.allows?(entry, other)).to be(false)
  end

  it 'ignores the stored allowed-targets list of an agent' do
    Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: member)
    entry.update!(handoff_agent_ids: [other.id])
    member.update!(handoff_agent_ids: [])

    graph = described_class.new(entry, inbox: inbox)

    expect(graph.agents.map(&:id)).to contain_exactly(entry.id, member.id)
    expect(graph.allows?(entry, member)).to be(true)
    expect(graph.allows?(entry, other)).to be(false)
  end

  it 'leaves out an agent that is switched off or is not an external agent' do
    Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: member)
    Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: other)
    member.update!(active: false)
    other.update!(usage_mode: 'internal_assistant')

    graph = described_class.new(entry, inbox: inbox)

    expect(graph.agents).to eq([entry])
    expect(graph.peers?).to be(false)
  end
end
