# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::RoutingSnapshot do
  let(:candidates) do
    [Captain::Routing::Candidate.new(id: 84, name: 'Сезім — Богенбай Батыра', routing_description: 'Запись к ЛОР-врачам. Тел. +7 701 123 45 67',
                                     tool_ids: %w[create_appointment]),
     Captain::Routing::Candidate.new(id: 119, name: 'Кабинет ЛОР-процедур', routing_description: 'ЛОР-процедуры', tool_ids: %w[create_appointment]),
     Captain::Routing::Candidate.new(id: 120, name: 'Отдел хирургии', routing_description: 'ЛОР-операции', tool_ids: %w[faq_lookup])]
  end

  describe '.from_context' do
    let(:context) do
      {
        state: { source: 'reply_suggestion' },
        routing_current_agent_id: 119,
        routing_trail: [{ 'kind' => 'agent', 'from' => 84, 'to' => [119] }],
        conversation_history: [
          { role: :user, content: 'Хочу криотерапию' },
          { role: :assistant, content: { response: 'Свободно завтра 15:00. Как вас зовут?' }.to_json, agent_name: 'assistant_119' },
          { role: :assistant, content: '', tool_calls: [{ id: 'x' }], agent_name: 'assistant_119' },
          { role: :tool, content: 'tool data' },
          { role: :user, content: [{ type: 'text', text: 'Вот снимок' }, { type: 'image_url', image_url: { url: 'https://x' } }] }
        ],
        captain_v2_current_input: 'Давайте на 15:00, Ерлан',
        parts: [{ 'id' => 'p1', 'state' => 'waiting_customer', 'executor_agent_id' => 120, 'missing_fields' => ['Какой день удобен?'] },
                { 'id' => 'p2', 'state' => 'done', 'executor_agent_id' => 84 }]
      }
    end

    it 'gives the router the public dialogue, the message to route and the current agent' do
      state = described_class.from_context(context, candidates: candidates, clinic: 'SEZIM', patient_language: 'ru').to_state

      expect(state).to include(current_agent_id: 119, clinic: 'SEZIM', last_turn: { kind: 'agent', agent_ids: [119] }, visited_agent_ids: [119])
      expect(state[:agents]).to eq([{ id: 84, label: 'Сезім — Богенбай Батыра' }, { id: 119, label: 'Кабинет ЛОР-процедур' },
                                    { id: 120, label: 'Отдел хирургии' }])
      expect(state[:recent_messages]).to eq([{ role: 'patient', text: 'Хочу криотерапию' },
                                             { role: 'clinic', agent_id: 119, text: 'Свободно завтра 15:00. Как вас зовут?' }])
      expect(state[:latest_message]).to eq("Вот снимок [image]\nДавайте на 15:00, Ерлан")
    end

    it 'gives the router the open questions, the source and whether staff can take over' do
      snapshot = described_class.from_context(context, candidates: candidates, human_available: true)

      expect(snapshot.to_state[:open_questions]).to eq([{ number: 1, agent_id: 120, question: 'Какой день удобен?' }])
      expect(snapshot.source).to eq('reply_suggestion')
      expect(snapshot.human_available).to be(true)
    end

    it 'writes the competence cards into the agents, not into the state' do
      snapshot = described_class.from_context(context, candidates: candidates)

      expect(snapshot.agent(84).card).to eq('Запись к ЛОР-врачам. Тел.')
      expect(snapshot.agent(120).card).to eq("ЛОР-операции #{Captain::Routing::CompetenceCard::NO_BOOKING_NOTE}")
      expect(snapshot.to_state.to_json).not_to include('ЛОР-операции')
    end

    it 'has no current agent when the saved one is no longer a candidate' do
      snapshot = described_class.from_context(context.merge(routing_current_agent_id: 999), candidates: candidates)

      expect(snapshot.current_agent_id).to be_nil
      expect(snapshot).to be_first_message
    end
  end

  describe '#bounce_source' do
    def snapshot_with(current, trail)
      described_class.new(agents: described_class.agents_for(candidates), latest_message: 'x', current_agent_id: current, trail: trail)
    end

    it 'is the agent the previous turn routed away from to the current agent' do
      expect(snapshot_with(119, [{ 'kind' => 'agent', 'from' => 84, 'to' => [119] }]).bounce_source).to eq(84)
    end

    it 'is nothing after a stay, a council or a first route' do
      expect(snapshot_with(119, [{ 'kind' => 'agent', 'from' => 119, 'to' => [119] }]).bounce_source).to be_nil
      expect(snapshot_with(119, [{ 'kind' => 'council', 'from' => 84, 'to' => [84, 119] }]).bounce_source).to be_nil
      expect(snapshot_with(119, [{ 'kind' => 'agent', 'to' => [119] }]).bounce_source).to be_nil
      expect(snapshot_with(nil, [{ 'kind' => 'agent', 'from' => 84, 'to' => [119] }]).bounce_source).to be_nil
    end
  end

  it 'narrows the same turn to the words of one part and the agents that are left' do
    snapshot = described_class.new(agents: described_class.agents_for(candidates), latest_message: 'все сразу', current_agent_id: 84,
                                   human_available: true)

    narrowed = snapshot.narrowed(latest_message: 'про операцию', without: [119])

    expect(narrowed.agent_ids).to eq([84, 120])
    expect(narrowed.latest_message).to eq('про операцию')
    expect(narrowed.current_agent_id).to eq(84)
    expect(narrowed.human_available).to be(true)
  end

  it 'builds the same state from a benchmark scenario' do
    scenario = { 'id' => 'SZ07', 'current' => 119, 'language' => 'ru', 'message' => 'Давайте на 16:30',
                 'history' => [{ 'role' => 'patient', 'text' => 'Хочу криотерапию' },
                               { 'role' => 'agent', 'agent_id' => 119, 'text' => 'Свободно 16:30' }] }

    state = described_class.from_fixture(candidates: candidates, scenario: scenario, clinic: 'SEZIM').to_state

    expect(state).to include(current_agent_id: 119, patient_language: 'ru', latest_message: 'Давайте на 16:30', visited_agent_ids: [119])
    expect(state[:recent_messages]).to eq([{ role: 'patient', text: 'Хочу криотерапию' }, { role: 'clinic', agent_id: 119, text: 'Свободно 16:30' }])
  end
end
