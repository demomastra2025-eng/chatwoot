require 'rails_helper'

RSpec.describe Captain::Routing::WriterPicker do
  let(:account) { create(:account) }
  let(:router) { instance_double(Captain::Runtime::DecisionRouter) }

  def pick(instruction = 'Remind about the visit tomorrow', source: 'touch')
    described_class.pick(account: account, instruction: instruction, source: source)
  end

  def chosen(agent)
    Captain::Runtime::DecisionRouter::Decision.new(kind: 'agent', key: "route_agent_#{agent.id}", agent_ids: [agent.id])
  end

  before { allow(Captain::Runtime::DecisionRouter).to receive(:new).and_return(router) }

  it 'is the only enabled agent, with no decision to make and with or without a card' do
    only = create(:captain_assistant, account: account)
    create(:captain_assistant, account: account, active: false)
    expect(router).not_to receive(:redecide)

    expect(pick).to eq(only)
  end

  it 'is nobody when every agent is switched off, or the workspace has none' do
    expect(pick).to be_nil

    create(:captain_assistant, account: account, active: false)
    expect(pick).to be_nil
  end

  it 'asks the router once, from the instruction, among the enabled agents that have a card' do
    doctors = create(:captain_assistant, account: account, routing_description: 'Doctors')
    labs = create(:captain_assistant, account: account, routing_description: 'Lab tests')
    create(:captain_assistant, account: account)
    expect(router).to receive(:redecide).with(fragment: 'Remind about the lab results', without: []).once.and_return(chosen(labs))

    expect(pick('Remind about the lab results')).to eq(labs)
    expect(doctors).to be_active
  end

  it 'builds the decision from the candidates with a card only, and says where it was asked from' do
    create(:captain_assistant, account: account, routing_description: 'Doctors')
    create(:captain_assistant, account: account, routing_description: 'Lab tests')
    create(:captain_assistant, account: account)
    snapshot = nil
    allow(Captain::Runtime::DecisionRouter).to receive(:new) do |routing_snapshot, **|
      snapshot = routing_snapshot
      instance_double(Captain::Runtime::DecisionRouter, redecide: nil)
    end

    pick('Write a campaign text', source: 'campaign')

    expect(snapshot.agents.size).to eq(2)
    expect(snapshot.source).to eq('campaign')
  end

  it 'is nobody when several agents are on and none has a card: nothing stands in for the missing choice' do
    create(:captain_assistant, account: account)
    create(:captain_assistant, account: account)
    expect(router).not_to receive(:redecide)

    expect(pick).to be_nil
  end

  it 'is nobody when there is no instruction to decide from' do
    create(:captain_assistant, account: account, routing_description: 'Doctors')
    create(:captain_assistant, account: account, routing_description: 'Lab tests')
    expect(router).not_to receive(:redecide)

    expect(pick('   ')).to be_nil
  end

  it 'is nobody when the router has no answer or is unavailable' do
    create(:captain_assistant, account: account, routing_description: 'Doctors')
    create(:captain_assistant, account: account, routing_description: 'Lab tests')
    allow(router).to receive(:redecide).and_return(nil)
    expect(pick).to be_nil

    allow(router).to receive(:redecide).and_raise(Captain::Runtime::DecisionRouter::UnavailableError.new(reason: 'timeout', models_tried: []))
    expect(pick).to be_nil
  end
end
