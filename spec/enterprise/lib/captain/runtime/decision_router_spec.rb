# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::DecisionRouter do
  let(:account) { create(:account) }
  let(:agents) do
    [
      Captain::Runtime::RoutingSnapshot::Agent.new(id: 84, label: 'Сезім — Богенбай Батыра', card: 'Запись к ЛОР-врачам'),
      Captain::Runtime::RoutingSnapshot::Agent.new(id: 119, label: 'Кабинет ЛОР-процедур', card: 'ЛОР-процедуры'),
      Captain::Runtime::RoutingSnapshot::Agent.new(id: 120, label: 'Отдел хирургии', card: 'ЛОР-операции')
    ]
  end
  let(:trail) { [] }
  let(:current) { nil }
  let(:snapshot) do
    Captain::Runtime::RoutingSnapshot.new(agents: agents, latest_message: 'Сәлеметсіз бе, ертеңге ЛОР дәрігеріне жазылуға бола ма?',
                                          current_agent_id: current, trail: trail, human_available: true)
  end
  let(:router) { described_class.new(snapshot, account: account, observability: { routing_request_id: 'r-1' }) }
  let(:calls) { [] }

  # What a decision model answered: route_mode and the agents that are yes, each with one confidence, and the probabilities the
  # model gave per question ({ name => { key => probability } }; none by default).
  def chain_answer(mode, yes: [], confidence: 0.93, probabilities: {}, model: 'perplexity/pplx-decider-v1.2')
    choices = { 'route_mode' => mode }.merge([84, 119, 120].to_h { |id| ["include_agent_#{id}", yes.include?(id) ? 'yes' : 'no'] })
    answers = choices.to_h do |name, choice|
      [name, Llm::OpenRouterDecisionClient::Answer.new(choice: choice, confidence: confidence, probabilities: probabilities.fetch(name, {}))]
    end
    Llm::DecisionChain::Result.new(choice: 'summary', confidence: confidence, probabilities: {}, answers: answers, model: model,
                                   served_model: model, position: 1)
  end

  # The probabilities of the include questions: { agent id => probability of yes }.
  def includes(probabilities)
    probabilities.to_h { |id, yes| ["include_agent_#{id}", { 'yes' => yes, 'no' => (1 - yes).round(4) }] }
  end

  def answer_chain(*results)
    allow(Llm::DecisionChain).to receive(:decide) do |**kwargs|
      calls << kwargs
      results.shift || raise('no more answers')
    end
  end

  it 'uses the answers of the decision model as the decision' do
    answer_chain(chain_answer('route_agent', yes: [84]))

    expect(router.decide).to have_attributes(key: 'route_agent_84', kind: 'agent', agent_ids: [84], decided_by: 'perplexity/pplx-decider-v1.2',
                                             confidence: 0.93, criteria_count: 4, candidate_count: 3, first_message: true, mode: 'turn',
                                             answers: 'route_mode=route_agent include_agent_84=yes include_agent_119=no include_agent_120=no')
  end

  it 'asks the routing chain the questions of the turn in one call, with the state of the turn' do
    answer_chain(chain_answer('route_agent', yes: [84]))

    router.decide

    question = calls.sole
    expect(question).to include(feature: :agent_routing, total_timeout: described_class::Settings::CHAIN_BUDGET_SECONDS, models: nil)
    expect(question[:question][:questions].keys).to eq(%w[route_mode include_agent_84 include_agent_119 include_agent_120])
    expect(question[:question][:questions]['route_mode'][:instructions]).to eq(described_class::INSTRUCTIONS)
    expect(question[:question][:state]).to include(current_agent_id: nil, latest_message: snapshot.latest_message,
                                                   agents: agents.map { |agent| { id: agent.id, label: agent.label, handles: agent.card } })
    expect(question[:observability]).to include(routing_request_id: 'r-1', operation: 'captain.agent_routing')
  end

  # The owner's decision of 26.10: the decision models' most probable answer decides; no threshold, no second opinion.
  describe 'the most probable answer decides, with no threshold and no escalation' do
    it 'uses an answer of any confidence as it is, with one call of the chain' do
      answer_chain(chain_answer('route_agent', yes: [119], confidence: 0.31))

      expect(router.decide).to have_attributes(key: 'route_agent_119', confidence: 0.31)
      expect(Llm::DecisionChain).to have_received(:decide).once
    end

    it 'takes the route_mode key with the highest probability' do
      mode = { 'route_mode' => { 'route_agent' => 0.42, 'council' => 0.46, 'human_handoff' => 0.12 } }
      answer_chain(chain_answer('route_agent', yes: [84], probabilities: mode.merge(includes(84 => 0.81, 119 => 0.62, 120 => 0.05))))

      expect(router.decide).to have_attributes(key: 'council_84_119', kind: 'council', agent_ids: [84, 119], confidence: 0.46)
    end

    it 'gives staff only when human_handoff is the most probable route_mode, at any probability' do
      unsure = { 'route_mode' => { 'human_handoff' => 0.45, 'route_agent' => 0.55 } }.merge(includes(84 => 0.7))
      low = { 'route_mode' => { 'human_handoff' => 0.4, 'route_agent' => 0.35, 'council' => 0.25 } }
      answer_chain(chain_answer('human_handoff', probabilities: unsure), chain_answer('human_handoff', confidence: 0.4, probabilities: low))

      expect(router.decide).to have_attributes(key: 'route_agent_84', kind: 'agent')
      expect(router.decide).to have_attributes(key: 'human_handoff', kind: 'human', agent_ids: [], confidence: 0.4)
    end

    it 'routes to the agent with the highest include probability, even when every include answer is no' do
      answer_chain(chain_answer('route_agent', probabilities: includes(84 => 0.32, 119 => 0.41, 120 => 0.08)))

      expect(router.decide).to have_attributes(key: 'route_agent_119', agent_ids: [119])
    end

    it 'holds a council of the agents whose include probability is 0.5 or more, else routes to the most probable one' do
      answer_chain(chain_answer('council', yes: [84, 119, 120], probabilities: includes(84 => 0.9, 119 => 0.5, 120 => 0.49)),
                   chain_answer('council', yes: [120], probabilities: includes(84 => 0.2, 119 => 0.45, 120 => 0.7)))

      expect(router.decide).to have_attributes(key: 'council_84_119', kind: 'council', agent_ids: [84, 119])
      expect(router.decide).to have_attributes(key: 'route_agent_120', kind: 'agent', agent_ids: [120])
    end

    it 'reads no threshold or escalation setting of the platform' do
      create(:installation_config, name: 'CAPTAIN_AGENT_ROUTING_MIN_CONFIDENCE', value: '0.99')
      create(:installation_config, name: 'CAPTAIN_AGENT_ROUTING_ESCALATION_MODEL', value: 'openai/gpt-6-luna')
      answer_chain(chain_answer('route_agent', yes: [84], confidence: 0.6))

      expect(router.decide).to have_attributes(key: 'route_agent_84', decided_by: 'perplexity/pplx-decider-v1.2')
    end
  end

  context 'with a current agent' do
    let(:current) { 119 }

    it 'never routes to the current agent: route_agent takes the most probable other agent' do
      answer_chain(chain_answer('route_agent', yes: [119], probabilities: includes(84 => 0.3, 119 => 0.95, 120 => 0.35)))

      expect(router.decide).to have_attributes(key: 'route_agent_120', agent_ids: [120])
    end

    it 'keeps the current agent on stay_current whatever the include answers say' do
      answer_chain(chain_answer('stay_current', yes: [84], probabilities: includes(84 => 0.8, 119 => 0.1)))

      expect(router.decide).to have_attributes(key: 'stay_current', kind: 'stay', agent_ids: [119])
    end

    it 'takes a council of one agent that is the current one for a stay' do
      answer_chain(chain_answer('council', yes: [119], probabilities: includes(84 => 0.2, 119 => 0.9, 120 => 0.1)))

      expect(router.decide).to have_attributes(key: 'stay_current', kind: 'stay', agent_ids: [119])
    end

    context 'when the previous turn routed from 84 to it' do
      let(:trail) { [{ 'kind' => 'agent', 'from' => 84, 'to' => [119] }] }

      it 'uses a route straight back to 84 as it is (no bounce guard)' do
        answer_chain(chain_answer('route_agent', yes: [84], confidence: 0.99))

        expect(router.decide).to have_attributes(key: 'route_agent_84', agent_ids: [84])
      end
    end
  end

  it 'raises UnavailableError with the models it tried when every decision model fails' do
    allow(Llm::DecisionChain).to receive(:decide).and_raise(
      Llm::DecisionChain::ExhaustedError.new(feature: :agent_routing, attempts: [{ model: 'perplexity/pplx-decider-v1.2', error_class: 'Timeout' },
                                                                                 { model: 'inception/mercury-decide', error_class: 'Error' }])
    )

    expect { router.decide }.to raise_error(described_class::UnavailableError) do |error|
      expect(error.reason).to eq('decision_chain_unavailable')
      expect(error.models_tried).to eq(%w[perplexity/pplx-decider-v1.2 inception/mercury-decide])
    end
  end

  it 'uses the answer of the next model of the chain when the head failed (the chain falls back inside Llm::DecisionChain)' do
    answer_chain(chain_answer('route_agent', yes: [120], model: 'inception/mercury-decide').tap { |result| result.position = 2 })

    expect(router.decide).to have_attributes(key: 'route_agent_120', decided_by: 'inception/mercury-decide', chain_position: 2)
  end

  describe 'a message that needs no answer' do
    let(:snapshot) do
      Captain::Runtime::RoutingSnapshot.new(agents: agents, latest_message: 'хорошо спасибо', current_agent_id: current, human_available: true,
                                            recent_messages: [{ role: 'clinic', text: 'УЗИ — 8 000 ₸, приём — 10 000 ₸.' }])
    end

    it 'is no_reply_needed when no include answer is yes, never a council, and keeps the current agent when one leads' do
      answer_chain(chain_answer('no_reply_needed', confidence: 0.6))

      expect(router.decide).to have_attributes(key: 'no_reply_needed', kind: 'no_reply', agent_ids: [], agent_id: nil, confidence: 0.6)
      expect(calls.sole[:question][:questions]['route_mode'][:criteria]).to have_key('no_reply_needed')
    end

    # Review of df3aaff78: «Спасибо! А УЗИ почек сколько стоит?» answered no_reply_needed with include yes left no draft.
    it 'routes a no_reply_needed whose include answer is yes for an agent to that agent, never silencing the turn' do
      answer_chain(chain_answer('no_reply_needed', yes: [84, 119], probabilities: includes(84 => 0.7, 119 => 0.9)))

      expect(router.decide).to have_attributes(key: 'route_agent_119', kind: 'agent', agent_ids: [119])
    end

    context 'with a current agent' do
      let(:current) { 119 }

      it 'names the current agent, which a live turn lets write a courtesy reply' do
        answer_chain(chain_answer('no_reply_needed', yes: [119]))

        expect(router.decide).to have_attributes(kind: 'no_reply', agent_ids: [119], agent_id: 119, no_reply?: true)
      end

      it 'keeps an ok that answers an offered time with the current agent' do
        offered = Captain::Runtime::RoutingSnapshot.new(
          agents: agents, latest_message: 'Ок', current_agent_id: 119, human_available: true,
          recent_messages: [{ role: 'clinic', agent_id: 119, text: 'Свободно завтра в 16:30. Записать вас на 16:30?' }]
        )
        answer_chain(chain_answer('no_reply_needed'))

        expect(described_class.new(offered, account: account).decide).to have_attributes(key: 'stay_current', agent_ids: [119])
      end
    end
  end

  it 'asks the models the evaluation harness names instead of the platform chain' do
    answer_chain(chain_answer('council', yes: [119]))

    decision = described_class.new(snapshot, account: account, chain_models: ['typesafe/jev-1.14']).decide

    expect(decision).to have_attributes(key: 'route_agent_119', kind: 'agent')
    expect(calls.sole[:models]).to eq(['typesafe/jev-1.14'])
  end

  describe 'a reply suggestion' do
    let(:sticky) { 119 }
    let(:message) { 'Да, на 16:30' }
    let(:history) { [{ role: 'clinic', text: 'Свободно 16:30 и 17:00. Какое время удобно?' }] }
    let(:snapshot) do
      Captain::Runtime::RoutingSnapshot.new(agents: agents, latest_message: message, current_agent_id: sticky, human_available: true,
                                            recent_messages: history, suggestion: true, anchor_agent_id: 84)
    end

    it 'keeps a short reply with the sticky agent, also at a low confidence and when it names no agent' do
      answer_chain(chain_answer('stay_current', yes: [119]), chain_answer('stay_current', confidence: 0.4))

      expect(router.decide).to have_attributes(key: 'stay_current', agent_ids: [119])
      expect(router.decide).to have_attributes(key: 'stay_current', agent_ids: [119], confidence: 0.4)
    end

    context 'without a sticky agent' do
      let(:sticky) { nil }

      it 'gives route_agent naming no agent to the most probable agent, never by default to the anchor' do
        answer_chain(chain_answer('route_agent', probabilities: includes(84 => 0.2, 119 => 0.45, 120 => 0.1)))

        expect(router.decide).to have_attributes(key: 'route_agent_119', agent_ids: [119])
      end
    end
  end

  # Router benchmark 26.10 (AS06, IS06, SS05): v2 cards have no catch-all agent of general questions, so the old rule (a plain thanks
  # goes to that agent) sent a plain thanks to a council.
  it 'tells the decision models that a message that needs no answer is no_reply_needed, never a council' do
    instructions = described_class::INSTRUCTIONS.squish

    expect(instructions).to include('3. A message that needs no answer is no_reply_needed, whoever the current agent is',
                                    'no_reply_needed is never a council and never a route to an agent.',
                                    'stay_current and no_reply_needed - yes for the current agent at most;',
                                    'human_handoff - the include_agent answers do not matter.')
    expect(instructions).not_to include('route_agent to the agent whose description lists general clinic questions, as in rule 6')
    expect(described_class::Questions::INCLUDE_INSTRUCTIONS).to include(
      'a message that needs no answer (a plain thanks, ok or emoji that asks for nothing and accepts nothing that waits) is no for ' \
      'every agent.'
    )
  end

  # Review of df3aaff78: an ok to an offered time is an acceptance, and a greeting opens the dialog; neither needs no answer.
  it 'tells the decision models that an ok to an offered time or booking accepts it and that a greeting is answered' do
    instructions = described_class::INSTRUCTIONS.squish

    expect(instructions).to include('"Записать вас на завтра в 14:00?"', '"жарайды"', 'a thumbs-up - accepts the offer',
                                    'never no_reply_needed', 'A greeting ("Здравствуйте", "Сәлеметсіз бе") opens or resumes the dialog')
    expect(instructions).not_to include('greets')
  end

  describe '#redecide for a council part that was not its owner\'s' do
    it 'decides among the other agents, staff or nobody, never a council' do
      allow(Llm::DecisionChain).to receive(:decide) do |**kwargs|
        calls << kwargs
        answers = { 'route_mode' => 'route_agent', 'include_agent_84' => 'no', 'include_agent_120' => 'yes' }.transform_values do |choice|
          Llm::OpenRouterDecisionClient::Answer.new(choice: choice, confidence: 0.9)
        end
        Llm::DecisionChain::Result.new(answers: answers, model: 'perplexity/pplx-decider-v1.2', position: 1)
      end

      decision = router.redecide(fragment: 'сколько стоит септопластика', without: [119])

      expect(decision).to have_attributes(key: 'route_agent_120', agent_ids: [120], mode: 'part')
      questions = calls.sole[:question][:questions]
      expect(questions.keys).to eq(%w[route_mode include_agent_84 include_agent_120])
      expect(questions['route_mode'][:criteria].keys).to eq(%w[route_agent human_handoff nobody])
      expect(calls.sole[:question][:state][:latest_message]).to eq('сколько стоит септопластика')
    end

    it 'has nobody to choose when no agent is left' do
      expect(Llm::DecisionChain).not_to receive(:decide)

      expect(router.redecide(fragment: 'x', without: [84, 119, 120])).to be_nil
    end
  end

  it 'never writes patient text into its event payload' do
    answer_chain(chain_answer('route_agent', yes: [84]))

    payload = router.decide.to_event_payload
    expect(payload.to_json).not_to include('ЛОР дәрігеріне')
    expect(payload).to include(decision_key: 'route_agent_84', kind: 'agent', target_ids: [84], decided_by: 'perplexity/pplx-decider-v1.2',
                               first_answers: start_with('route_mode=route_agent'))
    expect(payload.keys).not_to include(:escalated, :escalation_trigger, :escalation_fallback, :default_to, :guard)
  end
end
