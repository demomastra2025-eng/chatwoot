require 'rails_helper'

RSpec.describe Captain::AgentGraph do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:scope) { Captain::ChannelScope.for_inbox(inbox) }
  let(:first) { create(:captain_assistant, account: account) }
  let(:second) { create(:captain_assistant, account: account) }
  let(:third) { create(:captain_assistant, account: account) }

  def graph_of(channel_scope = scope)
    described_class.new(channel_scope)
  end

  it 'keeps every enabled external agent of the workspace in a text channel graph, ordered by id, as peers' do
    agents = [third, first, second]
    agents.each { |agent| agent.update!(routing_description: "Card of #{agent.id}") }

    graph = graph_of
    expect(graph.agents.map(&:id)).to eq(agents.map(&:id).sort)
    expect(graph).not_to respond_to(:entry)
    expect(graph).not_to respond_to(:peers?)
    expect(graph).not_to respond_to(:allows?)
    expect(graph.payload.first).not_to have_key(:target_ids)
  end

  it 'does not depend on a channel row, a former default agent or a channel list of an agent' do
    first
    second

    expect(inbox.captain_inbox).to be_nil
    expect(graph_of.agents.map(&:id)).to eq([first.id, second.id])
  end

  it 'never raises for a disabled agent: it is simply not a member' do
    first.update!(active: false)
    second

    graph = graph_of
    expect(graph.agents).to eq([second])
    expect(described_class.constants).not_to include(:EntryDisabledError)
  end

  it 'leaves out an agent that is switched off or is not an external agent' do
    first
    second.update!(active: false)
    third.update!(usage_mode: 'internal_assistant')

    graph = graph_of

    expect(graph.agents).to eq([first])
    expect(graph.candidates).to eq([first])
    expect(graph).to be_solo
  end

  it 'includes every enabled external agent for the Playground with no channel (the workspace scope)' do
    [first, second, third].each { |agent| agent.update!(routing_description: "Card of #{agent.id}") }
    graph = graph_of(Captain::ChannelScope.for_workspace(account))

    expect(graph.agents.map(&:id)).to contain_exactly(first.id, second.id, third.id)
    expect(graph.payload.pluck(:id)).to contain_exactly(first.id, second.id, third.id)
    expect(graph).not_to be_solo
  end

  it 'gives a voice number its own agent alone, and nobody when that agent is switched off' do
    voice_inbox = create_voice_inbox(account)
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: first)
    second.update!(routing_description: 'Doctors')
    voice_scope = Captain::ChannelScope.for_inbox(voice_inbox)

    expect(graph_of(voice_scope).agents).to eq([first])
    expect(graph_of(voice_scope).candidates).to eq([first])

    first.update!(active: false)
    expect(graph_of(Captain::ChannelScope.for_inbox(voice_inbox.reload)).agents).to be_empty
  end

  describe 'who the router chooses among (the candidates)' do
    it 'is the agent alone when exactly one agent is enabled, with or without a card' do
      first
      second.update!(active: false)

      expect(graph_of.candidates).to eq([first])
      expect(graph_of).to be_solo
      expect(graph_of.unavailable_reason).to be_nil

      first.update!(routing_description: 'Doctors')
      expect(described_class.new(scope).candidates).to eq([first])
    end

    it 'is every enabled agent that has a card when two or more are enabled; an agent without a card is not chosen' do
      first.update!(routing_description: 'Doctors')
      second.update!(routing_description: 'Lab tests')
      third

      graph = graph_of

      expect(graph.candidates.map(&:id)).to eq([first.id, second.id].sort)
      expect(graph.candidate_rows.map(&:routing_description)).to eq(graph.candidates.map(&:routing_description))
      expect(graph).not_to be_solo
      expect(graph.unavailable_reason).to be_nil
    end

    it 'is one agent that has a card among several enabled agents: nothing to choose, so the router is not called' do
      first.update!(routing_description: 'Doctors')
      second
      third

      graph = graph_of

      expect(graph.candidates).to eq([first])
      expect(graph).to be_solo
    end

    it 'is nobody when two or more agents are enabled and none has a card' do
      first
      second

      graph = graph_of

      expect(graph.candidates).to be_empty
      expect(graph.unavailable_reason).to eq(described_class::NO_ROUTING_CARDS)
    end

    it 'is nobody when every agent is switched off' do
      first.update!(active: false)
      second.update!(active: false)

      graph = graph_of

      expect(graph.agents).to be_empty
      expect(graph.candidates).to be_empty
      expect(graph.unavailable_reason).to eq(described_class::NO_ACTIVE_AGENT)
    end

    it 'is nobody in a workspace with no agent at all' do
      expect(graph_of.unavailable_reason).to eq(described_class::NO_ACTIVE_AGENT)
    end
  end

  describe '#resolve' do
    let(:graph) do
      first
      second
      graph_of
    end

    it 'finds an agent by its runtime key assistant_<id> and by agent_<id>, the key in its transfer tool name' do
      expect(graph.resolve("assistant_#{second.id}")).to eq(second)
      expect(graph.resolve("agent_#{second.id}")).to eq(second)
      expect(graph.resolve("assistant_#{second.id + 1000}")).to be_nil
      expect(graph.resolve("agent_#{second.id + 1000}")).to be_nil
    end

    it 'reads a key that still carries a transfer prefix, under the new or the former name of the tool' do
      expect(graph.resolve("transfer_to_agent_#{second.id}")).to eq(second)
      expect(graph.resolve("handoff_to_assistant_#{second.id}")).to eq(second)
      expect(graph.resolve("handoff_to_agent_#{second.id}")).to eq(second)
    end

    it 'finds an agent by its normalized name and returns nothing for an unknown key' do
      second.update!(name: 'Lab consultant')

      expect(graph.resolve('lab_consultant')).to eq(second)
      expect(graph.resolve('nobody')).to be_nil
      expect(graph.resolve(nil)).to be_nil
    end
  end
end
