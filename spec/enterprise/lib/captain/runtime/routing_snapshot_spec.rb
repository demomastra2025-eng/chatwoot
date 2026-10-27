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
      note = Captain::Routing::CompetenceCard::NO_BOOKING_NOTE
      expect(state[:agents]).to eq([{ id: 84, label: 'Сезім — Богенбай Батыра', handles: 'Запись к ЛОР-врачам. Тел.' },
                                    { id: 119, label: 'Кабинет ЛОР-процедур', handles: 'ЛОР-процедуры' },
                                    { id: 120, label: 'Отдел хирургии', handles: "ЛОР-операции #{note}" }])
      expect(state[:recent_messages]).to eq([{ role: 'patient', text: 'Хочу криотерапию' },
                                             { role: 'clinic', agent_id: 119, text: 'Свободно завтра 15:00. Как вас зовут?' }])
      expect(state[:latest_message]).to eq("Вот снимок [image]\nДавайте на 15:00, Ерлан")
    end

    # The history writes the send time in front of every message ("[Wed 28.10 12:53] Спасибо"). It is no word of the patient: its digits
    # would keep a bare thanks that came in two messages from being one.
    it 'gives the words of the unanswered messages of the patient, without the send time the history writes in front of them' do
      stamped = { state: { source: 'reply_suggestion' },
                  conversation_history: [{ role: :assistant, content: '[Wed 28.10 12:01] Напоминаем: завтра в 10:00 у вас приём.' },
                                         { role: :user, content: '[Wed 28.10 12:53] Спасибо' }],
                  captain_v2_current_input: 'Буду' }

      state = described_class.from_context(stamped, candidates: candidates).to_state

      expect(state[:latest_message]).to eq("Спасибо\nБуду")
      expect(state[:recent_messages]).to eq([{ role: 'clinic', text: '[Wed 28.10 12:01] Напоминаем: завтра в 10:00 у вас приём.' }])
    end

    it 'gives the router the open questions, the source and whether staff can take over' do
      snapshot = described_class.from_context(context, candidates: candidates, human_available: true)

      expect(snapshot.to_state[:open_questions]).to eq([{ number: 1, agent_id: 120, question: 'Какой день удобен?' }])
      expect(snapshot.source).to eq('reply_suggestion')
      expect(snapshot.human_available).to be(true)
    end

    it 'gives every question the competence cards of all agents, cleaned of contacts' do
      snapshot = described_class.from_context(context, candidates: candidates)

      expect(snapshot.agent(84).card).to eq('Запись к ЛОР-врачам. Тел.')
      expect(snapshot.agent(120).card).to eq("ЛОР-операции #{Captain::Routing::CompetenceCard::NO_BOOKING_NOTE}")
      expect(snapshot.to_state[:agents].pluck(:handles)).to eq(snapshot.agents.map(&:card))
      expect(snapshot.to_state.to_json).not_to include('701 123')
    end

    it 'marks the turn of a reply suggestion but not a live turn' do
      suggestion = described_class.from_context(context, candidates: candidates)
      live = described_class.from_context(context.merge(state: { source: 'incoming_message' }), candidates: candidates)

      expect(suggestion).to be_suggestion
      expect(live).not_to be_suggestion
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

  it 'is mid-dialog when the dialog has messages before the turn' do
    first = described_class.new(agents: described_class.agents_for(candidates), latest_message: 'Здравствуйте')
    later = described_class.new(agents: described_class.agents_for(candidates), latest_message: 'Да, на 14:00',
                                recent_messages: [{ role: 'clinic', text: 'Свободно 14:00 и 15:30' }])

    expect(first).not_to be_mid_dialog
    expect(later).to be_mid_dialog
  end

  it 'takes the sticky agent of a reply suggestion scenario as the current agent of the turn' do
    scenario = { 'id' => 'SS01', 'current' => nil, 'sticky' => 119, 'message' => 'Иә, 17:00 болады',
                 'history' => [{ 'role' => 'agent', 'text' => 'Ертең бос уақыт: 16:30 және 17:00.' }] }

    snapshot = described_class.from_fixture(candidates: candidates, scenario: scenario)

    expect(snapshot.current_agent_id).to eq(119)
    expect(snapshot).to be_suggestion
    expect(snapshot.to_state[:recent_messages]).to eq([{ role: 'clinic', text: 'Ертең бос уақыт: 16:30 және 17:00.' }])
    without_sticky = described_class.from_fixture(candidates: candidates, scenario: scenario.except('sticky').merge('suggestion' => true))
    expect(without_sticky).to have_attributes(current_agent_id: nil)
    expect(without_sticky).to be_suggestion
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
