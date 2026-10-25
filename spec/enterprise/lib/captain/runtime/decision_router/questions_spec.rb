# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::DecisionRouter::Questions do
  def snapshot(count, current: nil, human: true, card: 'Услуги агента')
    agents = (1..count).map { |id| Captain::Runtime::RoutingSnapshot::Agent.new(id: id * 10, label: "Agent #{id}", card: card) }
    Captain::Runtime::RoutingSnapshot.new(agents: agents, latest_message: 'Здравствуйте', current_agent_id: current, human_available: human)
  end

  def build(count, mode: :full, **)
    described_class.build(snapshot(count, **), instructions: 'ROUTER RULES', mode: mode)
  end

  def answers(mode, yes: [], all: [10, 20, 30])
    { 'route_mode' => mode }.merge(all.to_h { |id| ["include_agent_#{id}", yes.include?(id) ? 'yes' : 'no'] })
  end

  it 'asks route_mode and one yes/no question per agent in one call, with the card of the agent in its yes criterion' do
    questions = build(3, current: 20, card: 'УЗИ всех видов').to_h

    expect(questions.keys).to eq(%w[route_mode include_agent_10 include_agent_20 include_agent_30])
    expect(questions['route_mode']).to include(instructions: 'ROUTER RULES')
    expect(questions['route_mode'][:criteria].keys).to eq(%w[stay_current route_agent council human_handoff])
    expect(questions['include_agent_10'][:criteria].keys).to eq(%w[yes no])
    expect(questions['include_agent_10'][:criteria]['yes']).to include('Agent 10 (Agent 1)', 'УЗИ всех видов')
    expect(questions['include_agent_10'][:instructions]).to include('just in case', 'several services of one agent make only that agent yes')
  end

  it 'offers no stay_current on the first message and human_handoff only when staff can take the conversation' do
    expect(build(3).mode_keys).to eq(%w[route_agent council human_handoff])
    expect(build(3, current: 10, human: false).mode_keys).to eq(%w[stay_current route_agent council])
  end

  it 'offers a council part that was not its owner\'s one agent, staff or nobody, never a council or a stay' do
    expect(build(3, current: 10, mode: :singles).mode_keys).to eq(%w[route_agent human_handoff nobody])
  end

  it 'keeps every criterion within the limit of the endpoint and stays within its question limit' do
    questions = build(3, card: 'Я' * 3000).to_h

    expect(questions.values.flat_map { |question| question[:criteria].values }.map(&:length).max).to be <= described_class::MAX_DESCRIPTION
    expect(questions.keys).to all(match(Llm::OpenRouterDecisionClient::QUESTION_NAME))
    expect { build(described_class::MAX_AGENTS + 1) }.to raise_error(ArgumentError, /at most/)
  end

  describe '#outcome' do
    let(:questions) { build(3, current: 20) }

    it 'routes to the one agent that is yes' do
      expect(questions.outcome(answers('route_agent', yes: [30]))).to have_attributes(kind: 'agent', agent_ids: [30], key: 'route_agent_30')
    end

    it 'takes a route to the current agent for a stay' do
      expect(questions.outcome(answers('route_agent', yes: [20]))).to have_attributes(kind: 'stay', agent_ids: [20], key: 'stay_current')
    end

    it 'keeps the current agent when no other agent is yes' do
      expect(questions.outcome(answers('stay_current'))).to have_attributes(kind: 'stay', key: 'stay_current')
      expect(questions.outcome(answers('stay_current', yes: [20]))).to have_attributes(kind: 'stay', key: 'stay_current')
    end

    it 'holds a council of exactly the agents that are yes, two or three, ids ascending' do
      expect(questions.outcome(answers('council', yes: [30, 10])))
        .to have_attributes(kind: 'council', agent_ids: [10, 30], key: 'council_10_30')
      expect(questions.outcome(answers('council', yes: [10, 20, 30])).key).to eq('council_10_20_30')
    end

    it 'gives staff whatever the include answers say' do
      expect(questions.outcome(answers('human_handoff', yes: [10]))).to have_attributes(kind: 'human', agent_ids: [], key: 'human_handoff')
    end

    it 'has no outcome for answers that contradict each other' do
      expect(questions.outcome(answers('route_agent'))).to be_nil
      expect(questions.outcome(answers('route_agent', yes: [10, 30]))).to be_nil
      expect(questions.outcome(answers('council', yes: [30]))).to be_nil
      expect(questions.outcome(answers('stay_current', yes: [10]))).to be_nil
      expect(questions.outcome(answers('invented'))).to be_nil
    end

    it 'never takes several services of one agent for a council: one agent yes is a route, and a council of one has no outcome' do
      single = build(3)

      expect(single.outcome(answers('route_agent', yes: [20])).key).to eq('route_agent_20')
      expect(single.outcome(answers('council', yes: [20]))).to be_nil
    end

    it 'routes a council part to the agent that is yes, also the current one, or to nobody' do
      part = build(3, current: 10, mode: :singles)

      expect(part.outcome(answers('route_agent', yes: [10]))).to have_attributes(kind: 'agent', key: 'route_agent_10')
      expect(part.outcome(answers('nobody'))).to have_attributes(kind: 'none', key: 'nobody')
    end
  end

  describe '#confidence' do
    let(:questions) { build(3, current: 20) }

    def answer(choice, confidence) = Llm::OpenRouterDecisionClient::Answer.new(choice: choice, confidence: confidence)

    it 'is the lowest confidence of every answer, route_mode alone for staff, and nothing when one is missing' do
      all = { 'route_mode' => answer('route_agent', 0.95), 'include_agent_10' => answer('no', 0.9),
              'include_agent_20' => answer('no', 0.99), 'include_agent_30' => answer('yes', 0.7) }
      outcome = questions.outcome(all.transform_values(&:choice))

      expect(questions.confidence(all, outcome)).to eq(0.7)
      human = all.merge('route_mode' => answer('human_handoff', 0.85))
      expect(questions.confidence(human, questions.outcome(human.transform_values(&:choice)))).to eq(0.85)
      expect(questions.confidence(all.merge('include_agent_10' => answer('no', nil)), outcome)).to be_nil
    end
  end

  it 'summarizes the chosen keys for the logs' do
    expect(described_class.summary('route_mode' => 'council', 'include_agent_10' => 'yes')).to eq('route_mode=council include_agent_10=yes')
  end
end
