require 'rails_helper'

RSpec.describe Captain::AgentGraph do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: account) }
  let(:entry) { create(:captain_assistant, account: account) }
  let(:member) { create(:captain_assistant, account: account, channel_scope: 'selected') }
  let(:other) { create(:captain_assistant, account: account, channel_scope: 'selected') }

  it 'keeps all active external agents in the channel graph while read-only peers cannot transfer' do
    Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: member)
    Captain::AgentChannel.create!(account: account, inbox: other_inbox, assistant: other)

    graph = described_class.new(entry, inbox: inbox)
    expect(graph.agents.map(&:id)).to contain_exactly(entry.id, member.id, other.id)
    expect(graph.peers?).to be(true)
    expect(graph.allows?(entry, member)).to be(false)
    expect(graph.allows?(member, entry)).to be(false)
    expect(graph.allows?(member, other)).to be(false)
    expect(graph.allows?(entry, entry)).to be(false)
    expect(graph.payload.first).not_to have_key(:target_ids)
  end

  it 'raises a dedicated error, still an ArgumentError, when the entry agent is disabled' do
    entry.update!(active: false)

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

  it 'includes an active colleague even when the legacy channel rows list another inbox' do
    other
    Captain::AgentChannel.create!(account: account, inbox: other_inbox, assistant: other)

    graph = described_class.new(entry, inbox: inbox)

    expect(graph.agents.map(&:id)).to contain_exactly(entry.id, other.id)
    expect(graph.peers?).to be(true)
    expect(graph.allows?(entry, other)).to be(false)
  end

  it 'ignores the stored allowed-targets list of an agent' do
    Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: member)
    entry.update!(handoff_agent_ids: [other.id])
    member.update!(handoff_agent_ids: [])

    graph = described_class.new(entry, inbox: inbox)

    expect(graph.agents.map(&:id)).to contain_exactly(entry.id, member.id, other.id)
    expect(graph.allows?(entry, member)).to be(false)
    expect(graph.allows?(entry, other)).to be(false)
  end

  it 'allows a colleague with a different handoff team' do
    team = create(:team, account: account)
    member.update!(config: member.config.merge('handoff_team_id' => team.id))

    expect(described_class.new(entry, inbox: inbox).allows?(entry, member)).to be(true)
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

  describe '#resolve' do
    let(:graph) do
      Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: member)
      described_class.new(entry, inbox: inbox)
    end

    it 'finds an agent by its runtime key assistant_<id> and by agent_<id>, the key in its transfer tool name' do
      expect(graph.resolve("assistant_#{member.id}")).to eq(member)
      expect(graph.resolve("agent_#{member.id}")).to eq(member)
      expect(graph.resolve("assistant_#{member.id + 1000}")).to be_nil
      expect(graph.resolve("agent_#{member.id + 1000}")).to be_nil
    end

    it 'reads a key that still carries a transfer prefix, under the new or the former name of the tool' do
      expect(graph.resolve("transfer_to_agent_#{member.id}")).to eq(member)
      expect(graph.resolve("handoff_to_assistant_#{member.id}")).to eq(member)
      expect(graph.resolve("handoff_to_agent_#{member.id}")).to eq(member)
    end

    it 'finds an agent by its normalized name and returns nothing for an unknown key' do
      member.update!(name: 'Lab consultant')

      expect(graph.resolve('lab_consultant')).to eq(member)
      expect(graph.resolve('nobody')).to be_nil
      expect(graph.resolve(nil)).to be_nil
    end
  end
end
