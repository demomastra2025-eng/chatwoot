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
  let(:runs) { [] }
  let(:councils) { [] }
  let(:events) { [] }
  let(:runtime_runner) { instance_double(Captain::Runtime::Runner) }
  let(:service) { described_class.new(assistant: doctors, conversation: conversation) }
  let(:session) { Captain::Conversation::AgentSession.new(entry: doctors, conversation: conversation) }

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

    response = service.generate_response(message_history: history)

    expect(runs).to be_empty
    expect(response).to include('response' => 'conversation_handoff', 'handoff_authorized' => true, 'routing_handoff' => true,
                                'agent_name' => "assistant_#{procedures.id}", 'agent_id' => procedures.id)
    expect(session.read['current_assistant_id']).to eq(procedures.id)
    expect(session.read['done'].last).to include('tool' => Captain::DoneActions::HANDOFF_TOOL)
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
    suggestion = described_class.new(assistant: doctors, conversation: conversation, source: 'reply_suggestion')

    response = suggestion.generate_response(message_history: history)

    expect(runs).to be_empty
    expect(response).to include('response' => '', 'response_mode' => 'human')
    expect(response['operator_note']).to be_present
    expect(conversation.reload.additional_attributes.to_h).not_to have_key(Captain::Conversation::AgentSession::ATTRIBUTE)
  end
end
