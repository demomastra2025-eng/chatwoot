# frozen_string_literal: true

require 'rails_helper'

# A response that no chosen agent produced (a router failure, a council that could not be set up, a custom input rule, a staff
# request) runs through the real AgentRunnerService and the response builder: it must name the agent that holds the conversation,
# or the response builder drops it as stale and nobody takes the conversation. The decision model is stubbed at
# Llm::DecisionChain; no agent runs.
RSpec.describe Captain::Conversation::ResponseBuilderJob, type: :job do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:tools) { { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[create_appointment handoff] } } } }
  # Three peers of one workspace (the clinic of Сезім Богенбай): none is a default agent.
  let!(:doctors) { create(:captain_assistant, account: account, name: 'Врачи', routing_description: 'Приём ЛОР-врачей', config: tools) }
  let!(:procedures) { create(:captain_assistant, account: account, name: 'Процедуры', routing_description: 'ЛОР-процедуры', config: tools) }
  let!(:surgery) { create(:captain_assistant, account: account, name: 'Хирургия', routing_description: 'ЛОР-операции', config: tools) }
  let(:session) { Captain::Conversation::AgentSession.new(conversation: conversation) }
  let(:runtime_runner) { instance_double(Captain::Runtime::Runner) }

  before do
    account.enable_features!('captain_integration', 'captain_tasks')
    create(:captain_inbox, inbox: inbox)
    create(:message, conversation: conversation, message_type: :incoming, content: 'Сәлеметсіз бе, ертеңге ЛОР дәрігеріне жазылуға бола ма?')
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_on)
    allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    allow(Llm::Config).to receive(:initialize!)
    allow(Llm::ApiClient).to receive(:moderate).and_return(instance_double(RubyLLM::Moderation, flagged?: false))
    detector = instance_double(Captain::PatientLanguageDetector, call: 'kk', safe_saved_language: 'kk')
    allow(Captain::PatientLanguageDetector).to receive(:new).and_return(detector)
    allow(Captain::Runtime::Runner).to receive(:new).and_return(runtime_runner)
    allow(runtime_runner).to receive(:run)
    allow(runtime_runner).to receive(:run_council)
  end

  def decide(mode, yes: [], confidence: 0.95)
    allow(Llm::DecisionChain).to receive(:decide) do |question:, **|
      yes_names = yes.map { |id| "include_agent_#{id}" }
      choices = question[:questions].keys.index_with { |name| yes_names.include?(name) ? 'yes' : 'no' }.merge('route_mode' => mode)
      answers = choices.transform_values { |choice| Llm::OpenRouterDecisionClient::Answer.new(choice: choice, confidence: confidence) }
      Llm::DecisionChain::Result.new(answers: answers, model: 'perplexity/pplx-decider-v1.2', served_model: 'perplexity/pplx-decider-v1.2',
                                     position: 1)
    end
  end

  def staff_notes
    conversation.messages.where(private: true).pluck(:content)
  end

  # The router gives a turn to staff only for a message that asks for a person (or complains), whatever the decision model chose.
  def patient_asks_for_a_person
    create(:message, conversation: conversation, message_type: :incoming, content: 'Соедините меня с оператором, пожалуйста')
  end

  def expect_staff_handoff(note)
    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(staff_notes.join("\n")).to include(note)
    expect(runtime_runner).not_to have_received(:run)
    expect(runtime_runner).not_to have_received(:run_council)
  end

  it 'hands a conversation held by a peer to staff when every decision model fails' do
    session.update_routing(actor_id: procedures.id)
    allow(Llm::DecisionChain).to receive(:decide).and_raise(
      Llm::DecisionChain::ExhaustedError.new(feature: :agent_routing, attempts: [{ model: 'inception/mercury-decide', error_class: 'Timeout' }])
    )

    described_class.perform_now(conversation, doctors)

    expect_staff_handoff('agent_router / decision_chain_unavailable')
    expect(session.read['current_assistant_id']).to eq(procedures.id)
  end

  it 'hands a conversation held by a peer to staff when the council cannot be set up' do
    session.update_routing(actor_id: procedures.id)
    decide('council', yes: [doctors.id, surgery.id])
    split = Captain::Runtime::CouncilSplitter::Result.new(parts: [{ 'executor_agent_id' => doctors.id, 'fragment' => 'к ЛОРу' }], fallback: false)
    allow(Captain::Runtime::CouncilSplitter).to receive(:new).and_return(instance_double(Captain::Runtime::CouncilSplitter, split: split))

    described_class.perform_now(conversation, doctors)

    expect_staff_handoff('agent_router / council_unavailable')
    expect(session.read['current_assistant_id']).to eq(procedures.id)
  end

  it 'hands the conversation to staff when the council of a first message cannot be set up after its first participant took it' do
    decide('council', yes: [procedures.id, surgery.id])
    split = Captain::Runtime::CouncilSplitter::Result.new(parts: [{ 'executor_agent_id' => procedures.id, 'fragment' => 'аудиометрия' }],
                                                          fallback: false)
    allow(Captain::Runtime::CouncilSplitter).to receive(:new).and_return(instance_double(Captain::Runtime::CouncilSplitter, split: split))

    described_class.perform_now(conversation, doctors)

    expect_staff_handoff('agent_router / council_unavailable')
    expect(session.read['current_assistant_id']).to eq(procedures.id)
  end

  it 'applies the handoff of a custom input rule on a turn the router gave to another agent' do
    Captain::AccountSettings.new(account).update!(
      'safety' => { 'custom_rules' => [{ 'id' => 'bleeding', 'name' => 'Bleeding', 'enabled' => true, 'instruction' => 'Bleeding needs staff.',
                                         'direction' => Captain::AccountSettings::RULE_DIRECTION_TO_API.fetch('input'),
                                         'action' => Captain::AccountSettings::RULE_ACTION_TO_API.fetch('handoff') }] }
    )
    session.update_routing(actor_id: procedures.id)
    decide('route_agent', yes: [surgery.id])
    matched = Captain::Safety::CustomRulesEvaluator::Result.new(status: :matched, direction: 'input', rule_id: 'bleeding', action: 'handoff',
                                                                model: 'decision-test-model', latency_ms: 1)
    allow(Captain::Safety::CustomRulesEvaluator).to receive(:evaluate).and_return(matched)

    described_class.perform_now(conversation, doctors)

    expect_staff_handoff(described_class::CUSTOM_GUARDRAIL_HANDOFF_NOTE)
    expect(Captain::Safety::CustomRulesEvaluator).to have_received(:evaluate).with(hash_including(account: account, direction: 'input')).once
    expect(session.read['current_assistant_id']).to eq(procedures.id)
  end

  it 'hands a conversation to staff for the patient through its holder when the holder is no longer a candidate of the router' do
    procedures.update!(routing_description: '')
    session.update_routing(actor_id: procedures.id)
    patient_asks_for_a_person
    decide('human_handoff')

    described_class.perform_now(conversation, doctors)

    expect(conversation.reload.status).to eq('open')
    expect(runtime_runner).not_to have_received(:run)
    expect(session.read['current_assistant_id']).to eq(procedures.id)
  end

  it 'releases a holder that was switched off, so that a staff request is applied by the AI itself, with no agent named' do
    session.update_routing(actor_id: surgery.id)
    surgery.update!(active: false)
    patient_asks_for_a_person
    decide('human_handoff')

    described_class.perform_now(conversation, doctors)

    expect(conversation.reload.status).to eq('open')
    expect(session.read).to include('current_assistant_id' => nil, 'routing_revision' => 2)
    expect(conversation.messages.where(private: true).where.not(sender_id: nil)).to be_empty
  end
end
