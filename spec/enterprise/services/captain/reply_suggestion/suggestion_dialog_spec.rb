# frozen_string_literal: true

require 'rails_helper'

# «Предложить ответ» end to end: StartService -> GenerateJob -> ReplySuggestionService -> AgentRunnerService -> DecisionRouter, with
# only the model calls stubbed (the agent runs and the decision chain). It guards the dialog that the suggestions keep across turns:
# the sticky agent, the escalation of an unsure router, the anchor default and the approval cards of an inserted draft.
RSpec.describe 'Reply suggestion dialog' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:manager) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:tools) { { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[create_appointment handoff] } } } }
  let!(:doctors) { create(:captain_assistant, account: account, name: 'Врачи', routing_description: 'Запись к ЛОР-врачам', config: tools) }
  let!(:procedures) { create(:captain_assistant, account: account, name: 'Процедуры', routing_description: 'ЛОР-процедуры', config: tools) }
  let(:store) { Captain::ReplySuggestion::RequestStore }
  let(:sticky) { Captain::ReplySuggestion::StickyAgent }
  let(:approvals) { Captain::ReplySuggestion::ActionApprovalService }
  let(:questions_seen) { [] }
  let(:runs) { [] }
  let(:runtime_runner) { instance_double(Captain::Runtime::Runner) }

  include_context 'with a configured reply suggestion model'

  before do
    Llm::EventSubscriber.install!
    account.enable_features!('captain_integration', 'captain_tasks')
    allow(ActionCable.server).to receive(:broadcast)
    allow(Llm::ApiClient).to receive(:moderate).and_return(instance_double(RubyLLM::Moderation, flagged?: false))
    detector = instance_double(Captain::PatientLanguageDetector, call: 'ru', safe_saved_language: 'ru')
    allow(Captain::PatientLanguageDetector).to receive(:new).and_return(detector)
    allow(Captain::Runtime::Runner).to receive(:new).and_return(runtime_runner)
    allow(runtime_runner).to receive(:run) do |agent_runtime, input, **options|
      runs << { agent: agent_runtime.name, input: input }
      Captain::Runtime::Result.new(output: { 'response' => "Ответ #{agent_runtime.name}", 'response_mode' => 'reply', 'operator_note' => '' },
                                   messages: [], usage: nil, error: nil, context: options[:context])
    end
    patient_says('Хочу на промывание миндалин завтра')
  end

  after { sticky.clear!(conversation) }

  def patient_says(text)
    create(:message, conversation: conversation, account: account, message_type: :incoming, content: text)
  end

  def clinic_says(text)
    create(:message, conversation: conversation, account: account, message_type: :outgoing, content: text)
  end

  def decide(mode, yes: [], confidence: 0.92)
    allow(Llm::DecisionChain).to receive(:decide) do |question:, **|
      questions_seen << question
      yes_names = yes.map { |id| "include_agent_#{id}" }
      choices = question[:questions].keys.index_with { |name| yes_names.include?(name) ? 'yes' : 'no' }.merge('route_mode' => mode)
      answers = choices.transform_values { |choice| Llm::OpenRouterDecisionClient::Answer.new(choice: choice, confidence: confidence) }
      Llm::DecisionChain::Result.new(answers: answers, model: 'perplexity/pplx-decider-v1.2', served_model: 'perplexity/pplx-decider-v1.2',
                                     position: 1)
    end
  end

  def escalate_to(mode, yes: [])
    choices = { 'route_mode' => mode }.merge([doctors, procedures].to_h { |item| ["include_agent_#{item.id}", yes.include?(item.id) ? 'yes' : 'no'] })
    answer = Captain::Runtime::DecisionRouter::Escalation::Answer.new(choices: choices, reason: 'escalated', model: 'openai/gpt-6-luna')
    escalation = instance_double(Captain::Runtime::DecisionRouter::Escalation, choose: answer)
    allow(Captain::Runtime::DecisionRouter::Escalation).to receive(:new).and_return(escalation)
    escalation
  end

  def suggest
    body = Captain::ReplySuggestion::StartService.new(
      account: account, user: manager, conversation: conversation, conversation_display_id: conversation.display_id
    ).perform.body
    Captain::ReplySuggestion::GenerateJob.perform_now(body[:suggestion_request_id])
    store.fetch_raw(body[:suggestion_request_id])
  end

  def feedback(record, outcome)
    Captain::ReplySuggestion::FeedbackService.new(
      account: account, user: manager, conversation: conversation, outcome: outcome, copilot_action: 'reply_suggestion',
      requested_display_id: conversation.display_id, suggestion_request_id: record['id'], generated_text: record.dig('result', 'message')
    ).perform
  end

  it 'makes the agent of a draft the current agent of the next suggestion, which keeps a confident short reply with it' do
    decide('route_agent', yes: [procedures.id])
    first = suggest
    expect(first).to include('status' => 'draft', 'budget_seconds' => Captain::ReplySuggestion::ROUTER_BUDGET_SECONDS)
    expect(sticky.read(conversation)).to eq(procedures.id)
    feedback(first, 'applied')

    clinic_says('Завтра 16:30 или 17:00?')
    patient_says('Да, на 17:00')
    decide('stay_current', yes: [procedures.id])
    expect(Captain::Runtime::DecisionRouter::Escalation).not_to receive(:new)
    second = suggest

    expect(questions_seen.last[:state][:current_agent_id]).to eq(procedures.id)
    expect(second).to include('status' => 'draft')
    expect(runs.pluck(:agent)).to eq(["assistant_#{procedures.id}", "assistant_#{procedures.id}"])
  end

  it 'escalates a short reply that the router keeps with the sticky agent at a low confidence' do
    sticky.confirm!(conversation, procedures.id, request_id: 'earlier')
    clinic_says('Завтра 16:30 или 17:00?')
    patient_says('Да, на 17:00')
    decide('stay_current', yes: [procedures.id], confidence: 0.3)
    escalation = escalate_to('stay_current', yes: [procedures.id])

    expect(suggest).to include('status' => 'draft')
    expect(escalation).to have_received(:choose)
  end

  it 'withdraws the agent of a rejected draft: the agent before it leads the dialog again' do
    sticky.confirm!(conversation, doctors.id, request_id: 'earlier')
    decide('route_agent', yes: [procedures.id])
    first = suggest
    expect(sticky.read(conversation)).to eq(procedures.id)

    feedback(first, 'dismissed')

    expect(sticky.read(conversation)).to eq(doctors.id)
  end

  it 'sends a short reply mid-dialog without a sticky agent to the escalation, and makes no anchor default sticky' do
    clinic_says('Завтра 16:30 или 17:00?')
    patient_says('Да, на 17:00')
    decide('route_agent', confidence: 0.95)
    escalation = escalate_to('route_agent')

    record = suggest

    expect(escalation).to have_received(:choose)
    expect(questions_seen.last[:state][:current_agent_id]).to be_nil
    expect(record).to include('status' => 'draft')
    expect(record.dig('result', 'suggestion_meta', 'routing')).to include('decision_key' => "route_agent_#{doctors.id}", 'default_to' => 'anchor')
    expect(sticky.read(conversation)).to be_nil
    feedback(record, 'applied')
    expect(sticky.read(conversation)).to be_nil
  end

  it 'keeps the pending card of an inserted draft through the next suggestion and shows it there again' do
    decide('route_agent', yes: [procedures.id])
    first = suggest
    approvals.store_record!(
      'action_id' => 'booking-card', 'account_id' => account.id, 'conversation_id' => conversation.id, 'status' => 'pending',
      'tool_name' => 'create_appointment', 'digest' => 'digest-booking', 'user_id' => manager.id, 'suggestion_request_id' => first['id']
    )
    feedback(first, 'applied')

    clinic_says('Записала вас на завтра в 17:00.')
    patient_says('Спасибо! А что взять с собой?')
    second = suggest

    expect(approvals.fetch_record('booking-card')).to include('status' => 'pending')
    expect(second.dig('result', 'pending_actions').pluck('action_id')).to include('booking-card')
  end
end
