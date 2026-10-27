# frozen_string_literal: true

require 'rails_helper'

# The router decides who answers every patient turn of a clinic with two or more agents (Captain::Runtime::DecisionRouter); the
# decision model is stubbed here at Llm::DecisionChain, and the agent runs at Captain::Runtime::Runner.
RSpec.describe Captain::Assistant::AgentRunnerService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: create(:contact, account: account)) }
  let(:tools) { { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[create_appointment handoff] } } } }
  let!(:doctors) { create(:captain_assistant, account: account, name: 'Врачи', routing_description: 'Запись к ЛОР-врачам', config: tools) }
  let!(:procedures) { create(:captain_assistant, account: account, name: 'Процедуры', routing_description: 'ЛОР-процедуры', config: tools) }
  let(:history) { [{ role: 'user', content: 'Сәлеметсіз бе, ертеңге ЛОР дәрігеріне жазылуға бола ма?' }] }
  let(:staff_history) { [{ role: 'user', content: 'Соедините меня с оператором, пожалуйста' }] }
  let(:runs) { [] }
  let(:councils) { [] }
  let(:events) { [] }
  let(:runtime_runner) { instance_double(Captain::Runtime::Runner) }
  let(:service) { described_class.new(scope: Captain::ChannelScope.for_conversation(conversation), conversation: conversation) }
  let(:session) { Captain::Conversation::AgentSession.new(conversation: conversation) }

  around do |example|
    subscriber = ActiveSupport::Notifications.subscribe(/\Acaptain\.agent\./) { |name, *, payload| events << [name, payload] }
    example.run
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  before do
    allow(Llm::Config).to receive(:initialize!)
    allow(Llm::ApiClient).to receive(:moderate).and_return(instance_double(RubyLLM::Moderation, flagged?: false))
    detector = instance_double(Captain::PatientLanguageDetector, call: 'kk', safe_saved_language: 'kk')
    allow(Captain::PatientLanguageDetector).to receive(:new).and_return(detector)
    allow(Captain::Runtime::Runner).to receive(:new).and_return(runtime_runner)
    allow(runtime_runner).to receive(:run) do |agent, input, **options|
      runs << { agent: agent.name, input: input }
      Captain::Runtime::Result.new(output: { 'response' => "Ответ #{agent.name}" }, messages: [], usage: nil, error: nil,
                                   context: options[:context])
    end
    allow(runtime_runner).to receive(:run_council) do |agent, _input, parts:, **options|
      councils << { acting: agent.name, executors: parts.pluck('executor_agent_id') }
      Captain::Runtime::Result.new(output: { response: 'Ответ консилиума' }, messages: [], usage: nil, error: nil, context: options[:context])
    end
  end

  # The answers of the decision model for the turn: route_mode and the agents that are yes.
  def decide(mode, yes: [], confidence: 0.92)
    allow(Llm::DecisionChain).to receive(:decide) do |question:, **|
      yes_names = yes.map { |id| "include_agent_#{id}" }
      choices = question[:questions].keys.index_with { |name| yes_names.include?(name) ? 'yes' : 'no' }.merge('route_mode' => mode)
      answers = choices.transform_values { |choice| Llm::OpenRouterDecisionClient::Answer.new(choice: choice, confidence: confidence) }
      Llm::DecisionChain::Result.new(answers: answers, model: 'perplexity/pplx-decider-v1.2', served_model: 'perplexity/pplx-decider-v1.2',
                                     position: 1)
    end
  end

  def routed_event = events.find { |name, _| name == 'captain.agent.routed' }&.last

  it 'routes the first message among all agents as peers and runs only the chosen agent' do
    decide('route_agent', yes: [doctors.id])

    response = service.generate_response(message_history: history)

    expect(runs).to eq([{ agent: "assistant_#{doctors.id}", input: history.last[:content] }])
    expect(response).to include('response' => "Ответ assistant_#{doctors.id}", 'agent_id' => doctors.id)
    expect(session.read).to include('current_assistant_id' => doctors.id)
    expect(routed_event).to include('decision_key' => "route_agent_#{doctors.id}", 'kind' => 'agent', 'first_message' => true,
                                    'decided_by' => 'perplexity/pplx-decider-v1.2')
    expect(routed_event.to_json).not_to include('ЛОР дәрігеріне')
    expect(Llm::DecisionChain).to have_received(:decide).with(hash_including(feature: :agent_routing)).once
  end

  it 'routes to another agent and the response is that agent\'s' do
    session.update_routing(actor_id: doctors.id)
    decide('route_agent', yes: [procedures.id])

    response = service.generate_response(message_history: history)

    expect(runs.pluck(:agent)).to eq(["assistant_#{procedures.id}"])
    expect(response['agent_id']).to eq(procedures.id)
    expect(session.read).to include('current_assistant_id' => procedures.id, 'routing_revision' => 2)
    expect(events.map(&:first)).to include('captain.agent.transfer')
  end

  it 'hands the conversation to staff without running an agent when the patient asks for a person' do
    session.update_routing(actor_id: procedures.id)
    decide('human_handoff', confidence: 0.95)

    response = service.generate_response(message_history: staff_history)

    expect(runs).to be_empty
    expect(response).to include('response' => 'conversation_handoff', 'handoff_authorized' => true, 'routing_handoff' => true,
                                'agent_name' => "assistant_#{procedures.id}", 'agent_id' => procedures.id)
    expect(session.read['current_assistant_id']).to eq(procedures.id)
    expect(session.read['done'].last).to include('tool' => Captain::DoneActions::HANDOFF_TOOL)
  end

  # Suggestion eval 26.10: the decision model answered human_handoff for a question about free times, the first message of a dialog.
  it 'runs the most probable agent when the decision model chooses staff for a message that asks for no person' do
    decide('human_handoff', yes: [doctors.id], confidence: 0.71)

    response = service.generate_response(message_history: history)

    expect(runs).to eq([{ agent: "assistant_#{doctors.id}", input: history.last[:content] }])
    expect(response).to include('response' => "Ответ assistant_#{doctors.id}", 'agent_id' => doctors.id)
    expect(response).not_to include('routing_handoff' => true)
    expect(routed_event).to include('decision_key' => "route_agent_#{doctors.id}", 'kind' => 'agent', 'first_message' => true)
  end

  it 'ends the turn through the technical-failure path when every decision model fails' do
    allow(Llm::DecisionChain).to receive(:decide).and_raise(
      Llm::DecisionChain::ExhaustedError.new(feature: :agent_routing, attempts: [{ model: 'inception/mercury-decide', error_class: 'Timeout' }])
    )

    response = service.generate_response(message_history: history)

    expect(runs).to be_empty
    expect(response).to include('response' => described_class::PROVIDER_ERROR_RESPONSE, described_class::PROVIDER_ERROR_AUTHORIZED_KEY => true)
    expect(response['technical_failure']).to include('tool' => 'agent_router', 'reason' => 'decision_chain_unavailable')
    failed = events.find { |name, _| name == 'captain.agent.routing_failed' }&.last
    expect(failed).to include('reason' => 'decision_chain_unavailable', 'models_tried' => ['inception/mercury-decide'])
  end

  it 'names the agent that holds the conversation on the technical failure of a routed turn' do
    session.update_routing(actor_id: procedures.id)
    allow(Llm::DecisionChain).to receive(:decide).and_raise(
      Llm::DecisionChain::ExhaustedError.new(feature: :agent_routing, attempts: [{ model: 'inception/mercury-decide', error_class: 'Timeout' }])
    )

    expect(service.generate_response(message_history: history)['agent_id']).to eq(procedures.id)
  end

  it 'names the routed agent when its run fails after the router gave it the conversation' do
    decide('route_agent', yes: [procedures.id])
    allow(runtime_runner).to receive(:run).and_raise(StandardError, 'provider down')

    response = service.generate_response(message_history: history)

    expect(response['agent_id']).to eq(procedures.id)
    expect(session.read['current_assistant_id']).to eq(procedures.id)
  end

  it 'runs a council of exactly the participants the router chose' do
    decide('council', yes: [doctors.id, procedures.id])
    split = Captain::Runtime::CouncilSplitter::Result.new(parts: [
                                                            { 'executor_agent_id' => doctors.id, 'fragment' => 'к ЛОРу' },
                                                            { 'executor_agent_id' => procedures.id, 'fragment' => 'аудиометрия' }
                                                          ], fallback: false)
    allow(Captain::Runtime::CouncilSplitter).to receive(:new).and_return(instance_double(Captain::Runtime::CouncilSplitter, split: split))

    response = service.generate_response(message_history: history)

    expect(runs).to be_empty
    expect(councils).to eq([{ acting: "assistant_#{doctors.id}", executors: [doctors.id, procedures.id] }])
    expect(response['response']).to eq('Ответ консилиума')
  end

  it 'tells the outcome of a suggestion that a council answered: what it left to the manager, and the agent that asked the patient' do
    decide('council', yes: [doctors.id, procedures.id])
    split = Captain::Runtime::CouncilSplitter::Result.new(parts: [
                                                            { 'executor_agent_id' => doctors.id, 'fragment' => 'к ЛОРу' },
                                                            { 'executor_agent_id' => procedures.id, 'fragment' => 'аудиометрия' }
                                                          ], fallback: false)
    allow(Captain::Runtime::CouncilSplitter).to receive(:new).and_return(instance_double(Captain::Runtime::CouncilSplitter, split: split))
    allow(runtime_runner).to receive(:run_council) do |_agent, _input, **options|
      context = options[:context].deep_dup.merge(council_handoff: { reason: 'council_unresolved', parts: ['аудиометрия'] })
      asked = context[:part_plan][:parts].find { |part| part['executor_agent_id'] == procedures.id }['id']
      context[:parts] = context[:parts].map { |part| part['id'] == asked ? part.merge('state' => 'waiting_customer') : part }
      Captain::Runtime::Result.new(output: { response: 'Записала к ЛОРу на 10:00.' }, messages: [], usage: nil, error: nil, context: context)
    end
    suggestion = described_class.new(scope: Captain::ChannelScope.for_conversation(conversation), conversation: conversation,
                                        source: 'reply_suggestion')

    response = suggestion.generate_response(message_history: history)

    expect(response).to include('council_turn' => true, 'lead_agent_id' => procedures.id,
                                'council_handoff' => { 'reason' => 'council_unresolved', 'parts' => ['аудиометрия'] })
  end

  it 'makes no decision for a clinic with one agent' do
    procedures.update!(active: false)
    expect(Captain::Runtime::DecisionRouter).not_to receive(:new)

    service.generate_response(message_history: history)

    expect(runs.pluck(:agent)).to eq(["assistant_#{doctors.id}"])
  end

  it 'discards the decision of a turn whose input the safety check blocked' do
    decide('route_agent', yes: [procedures.id])
    unsafe = Llm::SafetyPolicy::UnsafeContentError.new(feature: :assistant, stage: :input, reason: 'unsafe')
    allow(Llm::SafetyPolicy).to receive(:check!).and_raise(unsafe)

    response = service.generate_response(message_history: history)

    expect(runs).to be_empty
    expect(response).to include('response' => 'conversation_handoff', described_class::MODERATION_BLOCKED_KEY => true)
    expect(session.read['current_assistant_id']).to be_nil
  end

  it 'routes a reply suggestion without writing anything to the conversation and tells the operator about a staff request' do
    decide('human_handoff', confidence: 0.95)
    suggestion = described_class.new(scope: Captain::ChannelScope.for_conversation(conversation), conversation: conversation,
                                        source: 'reply_suggestion')

    response = suggestion.generate_response(message_history: staff_history)

    expect(runs).to be_empty
    expect(response).to include('response' => '', 'response_mode' => 'human', 'routing_human' => true)
    expect(response['operator_note']).to be_present
    expect(conversation.reload.additional_attributes.to_h).not_to have_key(Captain::Conversation::AgentSession::ATTRIBUTE)
  end

  # Suggestion eval 26.10: a closing «Спасибо» was routed to an agent that then booked a visit; the router benchmark sent a plain
  # thanks with no sticky agent to a council.
  describe 'a message that needs no answer (no_reply_needed)' do
    let(:history) { [{ role: 'assistant', content: 'Вы записаны на завтра в 10:00.' }, { role: 'user', content: 'Спасибо' }] }

    it 'runs no agent in a reply suggestion and tells the manager why there is no draft' do
      decide('no_reply_needed', confidence: 0.97)
      suggestion = described_class.new(scope: Captain::ChannelScope.for_conversation(conversation), conversation: conversation,
                                          source: 'reply_suggestion')

      response = suggestion.generate_response(message_history: history)

      expect(runs).to be_empty
      expect(councils).to be_empty
      expect(response).to include('response' => '', 'response_mode' => 'suppress', 'routing_no_reply' => true,
                                  'operator_note' => I18n.t('captain.reply_suggestion.reasons.router_no_reply'))
      expect(routed_event).to include('decision_key' => 'no_reply_needed', 'kind' => 'no_reply')
    end

    it 'lets the agent that holds a live conversation write a courtesy reply, with its action tools refused for the turn' do
      session.update_routing(actor_id: procedures.id)
      contexts = []
      allow(runtime_runner).to receive(:run) do |agent, input, **options|
        runs << { agent: agent.name, input: input }
        contexts << options[:context]
        Captain::Runtime::Result.new(output: { 'response' => 'Пожалуйста!' }, messages: [], usage: nil, error: nil, context: options[:context])
      end
      decide('no_reply_needed', confidence: 0.97)

      response = service.generate_response(message_history: history)

      expect(runs.pluck(:agent)).to eq(["assistant_#{procedures.id}"])
      expect(response).to include('response' => 'Пожалуйста!', 'agent_id' => procedures.id)
      expect(contexts.sole).to include(Captain::Runtime::ToolWrapper::ACKNOWLEDGEMENT_TURN_KEY => true)
      expect(session.read).to include('current_assistant_id' => procedures.id)
      expect(events.map(&:first)).not_to include('captain.agent.transfer')
    end
  end

  # The owner's decision of 26.10: the decision models' most probable answer decides, with no threshold and no escalation (in the
  # suggestion eval of 26.10 the escalation was all of the latency the router added, and two escalations left no draft).
  it 'runs the agent the decision models named at a low confidence, with no other model call' do
    decide('route_agent', yes: [procedures.id], confidence: 0.5)
    allow(Llm::Runtime).to receive(:build_chat).and_call_original
    suggestion = described_class.new(scope: Captain::ChannelScope.for_conversation(conversation), conversation: conversation,
                                        source: 'reply_suggestion')

    response = suggestion.generate_response(message_history: history)

    expect(runs.pluck(:agent)).to eq(["assistant_#{procedures.id}"])
    expect(response['response']).to eq("Ответ assistant_#{procedures.id}")
    expect(routed_event).to include('decided_by' => 'perplexity/pplx-decider-v1.2', 'confidence' => 0.5)
    expect(routed_event.keys).not_to include('escalated', 'escalation_fallback')
    expect(Llm::DecisionChain).to have_received(:decide).once
    expect(Llm::Runtime).not_to have_received(:build_chat).with(hash_including(feature: :agent_routing_escalation))
    expect(events.map(&:first)).not_to include('captain.agent.routing_failed')
  end

  it 'does not wait for the router when the safety check blocked the input' do
    # The decision takes 5 s: a turn that waited for it would take at least that long.
    allow(Llm::DecisionChain).to receive(:decide) do
      sleep 5
      raise Llm::DecisionChain::ExhaustedError.new(feature: :agent_routing, attempts: [])
    end
    unsafe = Llm::SafetyPolicy::UnsafeContentError.new(feature: :assistant, stage: :input, reason: 'unsafe')
    allow(Llm::SafetyPolicy).to receive(:check!).and_raise(unsafe)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = service.generate_response(message_history: history)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3.0
    expect(response).to include(described_class::MODERATION_BLOCKED_KEY => true)
  end

  describe 'a reply suggestion with a sticky agent' do
    let(:suggestion) do
      described_class.new(scope: Captain::ChannelScope.for_conversation(conversation), conversation: conversation, source: 'reply_suggestion')
    end
    let(:history) do
      [{ role: 'user', content: 'Хочу на промывание миндалин завтра' },
       { role: 'assistant', content: 'Завтра свободно 16:30 и 17:00. Какое время удобно?' },
       { role: 'user', content: 'Да, на 17:00' }]
    end

    before { Captain::ReplySuggestion::StickyAgent.confirm!(conversation, procedures.id, request_id: 'earlier') }
    after { Captain::ReplySuggestion::StickyAgent.clear!(conversation) }

    it 'gives the router the sticky agent as the current agent and keeps a confident short reply with it' do
      decide('stay_current', yes: [procedures.id], confidence: 0.92)

      response = suggestion.generate_response(message_history: history)

      expect(Llm::DecisionChain).to have_received(:decide) do |question:, **|
        expect(question[:state]).to include(current_agent_id: procedures.id)
        expect(question[:questions]['route_mode'][:criteria].keys).to include('stay_current')
      end
      expect(runs.pluck(:agent)).to eq(["assistant_#{procedures.id}"])
      expect(response).to include('agent_id' => procedures.id)
      expect(routed_event).to include('decision_key' => 'stay_current', 'run_source' => 'reply_suggestion')
    end

    it 'leaves the run the budget of one agent once the router chose one agent' do
      decide('stay_current', yes: [procedures.id], confidence: 0.92)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Captain::ReplySuggestion::ROUTER_BUDGET_SECONDS

      Captain::ReplySuggestion::RunControl.with(request_id: SecureRandom.uuid, deadline: deadline) do |control|
        suggestion.generate_response(message_history: history)

        expect(control.seconds_left).to be <= Captain::ReplySuggestion.budget_seconds
      end
    end

    it 'routes to another agent when the patient asks for its service, with no transfer in the live report' do
      decide('route_agent', yes: [doctors.id])

      response = suggestion.generate_response(message_history: history)

      expect(response['agent_id']).to eq(doctors.id)
      transfer = events.find { |name, _| name == 'captain.agent.transfer' }&.last
      expect(transfer).to include('run_source' => 'reply_suggestion', 'from_agent_id' => procedures.id, 'to_agent_id' => doctors.id)
    end
  end
end
