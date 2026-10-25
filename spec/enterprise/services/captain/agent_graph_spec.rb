require 'rails_helper'

RSpec.describe Captain::AgentGraph do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: account) }
  let(:entry) { create(:captain_assistant, account: account) }
  let(:member) { create(:captain_assistant, account: account, channel_scope: 'selected') }
  let(:other) { create(:captain_assistant, account: account, channel_scope: 'selected') }

  it 'keeps every active external agent in the channel graph, ordered by id, with no transfer permissions between them' do
    Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: member)
    Captain::AgentChannel.create!(account: account, inbox: other_inbox, assistant: other)

    graph = described_class.new(entry, inbox: inbox)
    expect(graph.agents.map(&:id)).to eq([entry.id, member.id, other.id].sort)
    expect(graph).not_to respond_to(:peers?)
    expect(graph).not_to respond_to(:allows?)
    expect(graph.payload.first).not_to have_key(:target_ids)
  end

  it 'raises a dedicated error, still an ArgumentError, when the entry agent is disabled' do
    entry.update!(active: false)

    expect { described_class.new(entry, inbox: inbox).agents }
      .to raise_error(described_class::EntryDisabledError, 'The entry agent is disabled')
    expect(described_class::EntryDisabledError.ancestors).to include(ArgumentError)
  end

  it 'includes active external agents of the workspace even when there is no channel (workspace sandbox)' do
    [entry, member, other].each { |agent| agent.update!(routing_description: "Card of #{agent.id}") }
    graph = described_class.new(entry)

    expect(graph.agents.map(&:id)).to contain_exactly(entry.id, member.id, other.id)
    expect(graph.payload.pluck(:id)).to contain_exactly(entry.id, member.id, other.id)
    expect(graph).not_to be_solo
  end

  it 'includes an active colleague even when the legacy channel rows list another inbox' do
    other.update!(routing_description: 'Lab tests')
    entry.update!(routing_description: 'Doctors')
    Captain::AgentChannel.create!(account: account, inbox: other_inbox, assistant: other)

    graph = described_class.new(entry, inbox: inbox)

    expect(graph.agents.map(&:id)).to contain_exactly(entry.id, other.id)
    expect(graph.candidates.map(&:id)).to contain_exactly(entry.id, other.id)
  end

  it 'ignores the stored allowed-targets list of an agent' do
    Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: member)
    entry.update!(handoff_agent_ids: [other.id], routing_description: 'Doctors')
    member.update!(handoff_agent_ids: [], routing_description: 'Lab tests')
    other.update!(routing_description: 'Ultrasound')

    graph = described_class.new(entry, inbox: inbox)

    expect(graph.agents.map(&:id)).to contain_exactly(entry.id, member.id, other.id)
    expect(graph.candidates.map(&:id)).to contain_exactly(entry.id, member.id, other.id)
  end

  it 'offers the router only the patient-facing agents with a card, as peers; the anchor alone when none has one' do
    member.update!(routing_description: 'Lab tests')
    other.update!(routing_description: 'Ultrasound', config: other.config.to_h.merge('patient_routing' => false))
    graph = described_class.new(entry, inbox: inbox)

    expect(graph.candidates).to eq([member])
    expect(graph).to be_solo

    entry.update!(routing_description: 'Doctors')
    graph = described_class.new(entry, inbox: inbox)
    expect(graph.candidates.map(&:id)).to eq([entry.id, member.id].sort)
    expect(graph.candidate_rows.map(&:routing_description)).to eq(graph.candidates.map(&:routing_description))
    expect(graph).not_to be_solo

    [entry, member].each { |agent| agent.update!(routing_description: '') }
    expect(described_class.new(entry, inbox: inbox).candidates).to eq([entry])
  end

  it 'leaves out an agent that is switched off or is not an external agent' do
    Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: member)
    Captain::AgentChannel.create!(account: account, inbox: inbox, assistant: other)
    member.update!(active: false)
    other.update!(usage_mode: 'internal_assistant')

    graph = described_class.new(entry, inbox: inbox)

    expect(graph.agents).to eq([entry])
    expect(graph).to be_solo
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
