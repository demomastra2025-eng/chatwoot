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

  # What a decision model answered: route_mode and the agents that are yes, each with one confidence (or per question).
  def chain_answer(mode, yes: [], confidence: 0.93, confidences: {})
    model = 'perplexity/pplx-decider-v1.2'
    choices = { 'route_mode' => mode }.merge([84, 119, 120].to_h { |id| ["include_agent_#{id}", yes.include?(id) ? 'yes' : 'no'] })
    answers = choices.to_h do |name, choice|
      [name, Llm::OpenRouterDecisionClient::Answer.new(choice: choice, confidence: confidences.fetch(name, confidence), probabilities: {})]
    end
    Llm::DecisionChain::Result.new(choice: 'summary', confidence: confidence, probabilities: {}, answers: answers, model: model,
                                   served_model: model, position: 1)
  end

  def answer_chain(*results)
    allow(Llm::DecisionChain).to receive(:decide) do |**kwargs|
      calls << kwargs
      results.shift || raise('no more answers')
    end
  end

  def escalate_to(choices, reason: 'agent 84 books ENT doctors')
    escalation = instance_double(described_class::Escalation, choose: described_class::Escalation::Answer.new(
      choices: choices, reason: reason, model: 'openai/gpt-6-luna'
    ))
    allow(described_class::Escalation).to receive(:new).and_return(escalation)
    escalation
  end

  def choices(mode, yes: [])
    { 'route_mode' => mode }.merge([84, 119, 120].to_h { |id| ["include_agent_#{id}", yes.include?(id) ? 'yes' : 'no'] })
  end

  it 'uses confident answers that agree as the decision' do
    answer_chain(chain_answer('route_agent', yes: [84]))

    expect(router.decide).to have_attributes(key: 'route_agent_84', kind: 'agent', agent_ids: [84], decided_by: 'perplexity/pplx-decider-v1.2',
                                             confidence: 0.93, escalated: false, criteria_count: 4, candidate_count: 3, first_message: true,
                                             first_answers: 'route_mode=route_agent include_agent_84=yes include_agent_119=no include_agent_120=no')
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

  it 'holds a council of exactly the agents that are yes' do
    answer_chain(chain_answer('council', yes: [84, 119], confidence: 0.75))
    expect(described_class::Escalation).not_to receive(:new)

    expect(router.decide).to have_attributes(key: 'council_84_119', kind: 'council', agent_ids: [84, 119], escalated: false)
  end

  it 'escalates when one answer is below 0.75 and uses the escalation answer' do
    answer_chain(chain_answer('route_agent', yes: [119], confidences: { 'include_agent_119' => 0.6 }))
    escalation = escalate_to(choices('route_agent', yes: [84]))

    decision = router.decide

    expect(decision).to have_attributes(key: 'route_agent_84', agent_ids: [84], escalated: true, escalation_trigger: 'low_confidence',
                                        decided_by: 'escalation:openai/gpt-6-luna', first_choice: 'route_agent_119',
                                        first_confidence: 0.6, escalation_reason: 'agent 84 books ENT doctors')
    expect(escalation).to have_received(:choose) do |state:, questions:, instructions:|
      expect(state).to eq(snapshot.to_state)
      expect(questions.to_h).to eq(calls.sole[:question][:questions])
      expect(instructions).to eq(described_class::INSTRUCTIONS)
    end
  end

  it 'escalates answers that contradict each other, whatever their confidence' do
    answer_chain(chain_answer('council', yes: [84], confidence: 0.99))
    escalate_to(choices('route_agent', yes: [84]))

    expect(router.decide).to have_attributes(key: 'route_agent_84', escalated: true, escalation_trigger: 'inconsistent',
                                             first_choice: 'inconsistent')
  end

  it 'needs 0.80 for staff and uses a staff decision at 0.80' do
    answer_chain(chain_answer('human_handoff', confidence: 0.79), chain_answer('human_handoff', confidence: 0.8))
    escalate_to(choices('route_agent', yes: [84]))

    expect(router.decide).to have_attributes(key: 'route_agent_84', escalated: true)
    expect(router.decide).to have_attributes(key: 'human_handoff', kind: 'human', agent_ids: [], escalated: false)
  end

  it 'counts a missing confidence as low' do
    answer_chain(chain_answer('route_agent', yes: [84], confidence: nil))
    escalate_to(choices('route_agent', yes: [84]))

    expect(router.decide).to have_attributes(escalated: true, escalation_trigger: 'low_confidence')
  end

  context 'when the previous turn routed from 84 to the current agent 119' do
    let(:current) { 119 }
    let(:trail) { [{ 'kind' => 'agent', 'from' => 84, 'to' => [119] }] }

    it 'sends a confident route straight back to 84 to the escalation model (bounce guard)' do
      answer_chain(chain_answer('route_agent', yes: [84], confidence: 0.99))
      escalate_to(choices('route_agent', yes: [84]))

      expect(router.decide).to have_attributes(key: 'route_agent_84', escalated: true, escalation_trigger: 'bounce', guard: 'bounce')
    end

    it 'does not guard a route to another agent' do
      answer_chain(chain_answer('route_agent', yes: [120], confidence: 0.99))

      expect(router.decide).to have_attributes(key: 'route_agent_120', escalated: false, guard: nil)
    end

    it 'does not guard when the platform switched the bounce check off' do
      create(:installation_config, name: 'CAPTAIN_AGENT_ROUTING_BOUNCE_ESCALATION', value: 'off')
      answer_chain(chain_answer('route_agent', yes: [84], confidence: 0.99))

      expect(router.decide).to have_attributes(key: 'route_agent_84', escalated: false)
    end
  end

  it 'reads the thresholds from the platform settings' do
    create(:installation_config, name: 'CAPTAIN_AGENT_ROUTING_MIN_CONFIDENCE', value: '0.9')
    answer_chain(chain_answer('route_agent', yes: [84], confidence: 0.85))
    escalate_to(choices('route_agent', yes: [84]))

    expect(router.decide).to have_attributes(escalated: true)
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

  it 'raises EscalationError when the escalation fails or its answers contradict each other' do
    answer_chain(chain_answer('route_agent', yes: [84], confidence: 0.4), chain_answer('route_agent', yes: [84], confidence: 0.4))
    escalation = instance_double(described_class::Escalation)
    allow(escalation).to receive(:choose).and_raise(described_class::EscalationError.new(reason: 'escalation_unavailable'))
    allow(described_class::Escalation).to receive(:new).and_return(escalation)

    expect { router.decide }.to raise_error(described_class::EscalationError) { |error| expect(error.reason).to eq('escalation_unavailable') }

    escalate_to(choices('council', yes: [84]))
    expect { router.decide }.to raise_error(described_class::EscalationError) { |error| expect(error.reason).to eq('escalation_invalid') }
  end

  it 'reports the escalation it would run without calling it, and asks one model alone, for the evaluation harness' do
    answer_chain(chain_answer('council', yes: [119]))
    expect(described_class::Escalation).not_to receive(:new)

    decision = described_class.new(snapshot, account: account, escalate: false, chain_models: ['typesafe/jev-1.14']).decide

    expect(decision).to have_attributes(key: 'inconsistent', kind: 'inconsistent', escalation_trigger: 'inconsistent')
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

    it 'keeps a confident short reply with the sticky agent without the escalation' do
      answer_chain(chain_answer('stay_current', yes: [119]))
      expect(described_class::Escalation).not_to receive(:new)

      expect(router.decide).to have_attributes(key: 'stay_current', agent_ids: [119], escalated: false, escalation_trigger: nil, default_to: nil)
    end

    it 'escalates a short reply kept with the sticky agent at a low confidence, as any other turn' do
      answer_chain(chain_answer('stay_current', yes: [119], confidences: { 'include_agent_84' => 0.3 }))
      escalate_to(choices('stay_current', yes: [119]))

      expect(router.decide).to have_attributes(key: 'stay_current', agent_ids: [119], escalated: true, escalation_trigger: 'low_confidence',
                                               first_confidence: 0.3)
    end

    it 'gives an explicit stay_current that names no agent to the sticky agent, and escalates it at a low confidence' do
      answer_chain(chain_answer('stay_current'), chain_answer('stay_current', confidence: 0.5))
      escalate_to(choices('stay_current'))

      expect(router.decide).to have_attributes(key: 'stay_current', agent_ids: [119], escalated: false, default_to: 'current')
      expect(router.decide).to have_attributes(key: 'stay_current', agent_ids: [119], escalated: true, escalation_trigger: 'low_confidence',
                                               default_to: 'current')
    end

    it 'escalates route_agent naming no agent as inconsistent, and raises UndecidedError when the escalation names none either' do
      answer_chain(chain_answer('route_agent', confidence: 0.99))
      escalation = escalate_to(choices('route_agent'))

      expect { router.decide }.to raise_error(described_class::UndecidedError) do |error|
        expect(error).to have_attributes(reason: 'escalation_undecided', detail: 'no_agent', models_tried: ['openai/gpt-6-luna'])
        expect(error).to be_a(described_class::EscalationError)
      end
      expect(escalation).to have_received(:choose)
    end

    context 'without a sticky agent' do
      let(:sticky) { nil }

      it 'escalates a short reply mid-dialog whose answers name no agent: the escalation finds the agent of the booking' do
        answer_chain(chain_answer('route_agent', confidence: 0.95))
        escalation = escalate_to(choices('route_agent', yes: [119]))

        expect(router.decide).to have_attributes(key: 'route_agent_119', agent_ids: [119], escalated: true, escalation_trigger: 'inconsistent',
                                                 default_to: nil)
        expect(escalation).to have_received(:choose)
      end

      it 'never gives the turn to the anchor when the escalation also names no agent: nobody decided' do
        answer_chain(chain_answer('route_agent', confidence: 0.95))
        escalate_to(choices('route_agent'))

        expect { router.decide }.to raise_error(described_class::UndecidedError) { |error| expect(error.reason).to eq('escalation_undecided') }
      end

      context 'with the first message of the dialog' do
        let(:history) { [] }
        let(:message) { 'Здравствуйте!' }

        it 'gives confident answers that name no agent to the anchor; an unsure one escalates and is undecided when the escalation names none' do
          answer_chain(chain_answer('route_agent'), chain_answer('route_agent', confidence: 0.6))
          escalate_to(choices('route_agent'))

          expect(router.decide).to have_attributes(key: 'route_agent_84', escalated: false, default_to: 'anchor')
          expect { router.decide }.to raise_error(described_class::UndecidedError)
        end

        it 'is undecided on the first message after an inconsistent answer when the escalation names no agent' do
          answer_chain(chain_answer('council', yes: [119], confidence: 0.99))
          escalate_to(choices('route_agent'))

          expect { router.decide }.to raise_error(described_class::UndecidedError)
        end
      end
    end

    it 'escalates answers that contradict each other and fails when every decision model fails: there is no fallback' do
      answer_chain(chain_answer('council', yes: [119], confidence: 0.99))
      escalate_to(choices('stay_current', yes: [119]))
      expect(router.decide).to have_attributes(escalated: true, escalation_trigger: 'inconsistent')

      allow(Llm::DecisionChain).to receive(:decide).and_raise(
        Llm::DecisionChain::ExhaustedError.new(feature: :agent_routing, attempts: [{ model: 'perplexity/pplx-decider-v1.2', error_class: 'Timeout' }])
      )
      expect { router.decide }.to raise_error(described_class::UnavailableError)
    end

    it 'says in its event that the answers named no agent and who got the turn' do
      answer_chain(chain_answer('stay_current'))

      expect(router.decide.to_event_payload).to include(default_to: 'current', escalated: false)
    end

    describe 'an unsure stay_current that asks for no agent, which the escalation makes a council' do
      let(:message) { 'Спасибо. А аудиометрию и промывание миндалин можно завтра?' }

      it 'uses the council of the escalation: its answer is final, the turn is not sent back to the sticky agent' do
        answer_chain(chain_answer('stay_current', confidence: 0.6))
        escalate_to(choices('council', yes: [84, 119]))

        expect(router.decide).to have_attributes(key: 'council_84_119', kind: 'council', agent_ids: [84, 119], escalated: true,
                                                 escalation_trigger: 'low_confidence', first_choice: 'stay_current', guard: nil,
                                                 default_to: nil)
      end
    end
  end

  it 'uses the council of the escalation of a live turn whose first answers asked for no agent' do
    answer_chain(chain_answer('route_agent', confidence: 0.95))
    escalate_to(choices('council', yes: [84, 119]))

    expect(router.decide).to have_attributes(key: 'council_84_119', kind: 'council', escalated: true, escalation_trigger: 'inconsistent',
                                             guard: nil)
  end

  it 'tells the decision models and the escalation that a plain thanks without a current agent goes to one agent, never a council' do
    rule = 'a message that asks for nothing new and continues no service (a plain thanks, ok, an emoji, a greeting)'

    expect(described_class::INSTRUCTIONS.squish).to include(
      "#{rule} is route_agent to the agent whose description lists general clinic questions, as in rule 6; it is never a council."
    )
    expect(described_class::Questions::INCLUDE_INSTRUCTIONS).to include(
      "#{rule} is yes only for the agent whose description lists general clinic questions."
    )
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
    expect(payload).to include(decision_key: 'route_agent_84', kind: 'agent', target_ids: [84], escalated: false)
  end
end
