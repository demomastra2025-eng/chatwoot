# frozen_string_literal: true

require 'rails_helper'

# «Предложить ответ» end to end: StartService -> GenerateJob -> ReplySuggestionService -> AgentRunnerService -> DecisionRouter, with
# only the model calls stubbed (the agent runs and the decision chain). It guards the dialog that the suggestions keep across turns:
# the sticky agent (and what ends its lead: a rejection, a closed notice, a new suggestion over an unused one, a manual reply), the
# most probable answer of the router (no threshold, no escalation, no anchor default), the budget of one agent and the approval cards
# of an inserted draft.
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

  # The answers of the decision model: route_mode, the agents that are yes and, when given, the probability of yes per agent id.
  def decide(mode, yes: [], confidence: 0.92, yes_probabilities: {})
    allow(Llm::DecisionChain).to receive(:decide) do |question:, **|
      questions_seen << question
      yes_names = yes.map { |id| "include_agent_#{id}" }
      choices = question[:questions].keys.index_with { |name| yes_names.include?(name) ? 'yes' : 'no' }.merge('route_mode' => mode)
      answers = choices.to_h do |name, choice|
        probability = yes_probabilities[name.delete_prefix('include_agent_').to_i]
        probabilities = probability ? { 'yes' => probability, 'no' => 1 - probability } : {}
        [name, Llm::OpenRouterDecisionClient::Answer.new(choice: choice, confidence: confidence, probabilities: probabilities)]
      end
      Llm::DecisionChain::Result.new(answers: answers, model: 'perplexity/pplx-decider-v1.2', served_model: 'perplexity/pplx-decider-v1.2',
                                     position: 1)
    end
  end

  def suggest
    body = Captain::ReplySuggestion::StartService.new(
      account: account, user: manager, conversation: conversation, conversation_display_id: conversation.display_id
    ).perform.body
    Captain::ReplySuggestion::GenerateJob.perform_now(body[:suggestion_request_id])
    store.fetch_raw(body[:suggestion_request_id])
  end

  # What the reply box sends: a manual message, or the text of a used suggestion (content_attributes.copilot.assisted). The async
  # CaptainListener is called as the event dispatcher calls it.
  def manager_sends(text, assisted: false)
    attributes = assisted ? { copilot: { assisted: true, action: 'reply_suggestion' } } : {}
    message = create(:message, conversation: conversation, account: account, message_type: :outgoing, sender: manager, content: text,
                               content_attributes: attributes)
    CaptainListener.instance.message_created(Events::Base.new(:message_created, Time.zone.now, message: message))
    message
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
    expect(first).to include('status' => 'draft')
    expect(sticky.read(conversation)).to eq(procedures.id)
    feedback(first, 'applied')

    clinic_says('Завтра 16:30 или 17:00?')
    patient_says('Да, на 17:00')
    decide('stay_current', yes: [procedures.id])
    second = suggest

    expect(questions_seen.last[:state][:current_agent_id]).to eq(procedures.id)
    expect(second).to include('status' => 'draft')
    expect(runs.pluck(:agent)).to eq(["assistant_#{procedures.id}", "assistant_#{procedures.id}"])
  end

  it 'keeps a short reply with the sticky agent at a low confidence, with one call of the decision chain' do
    sticky.confirm!(conversation, procedures.id, request_id: 'earlier')
    clinic_says('Завтра 16:30 или 17:00?')
    patient_says('Да, на 17:00')
    decide('stay_current', yes: [procedures.id], confidence: 0.3)

    expect(suggest).to include('status' => 'draft')
    expect(Llm::DecisionChain).to have_received(:decide).once
    expect(runs.pluck(:agent)).to eq(["assistant_#{procedures.id}"])
  end

  it 'withdraws the agent of a rejected draft: the agent before it leads the dialog again' do
    sticky.confirm!(conversation, doctors.id, request_id: 'earlier')
    decide('route_agent', yes: [procedures.id])
    first = suggest
    expect(sticky.read(conversation)).to eq(procedures.id)

    feedback(first, 'dismissed')

    expect(sticky.read(conversation)).to eq(doctors.id)
  end

  it 'sends a short reply mid-dialog without a sticky agent to the most probable agent, also when no include answer is yes' do
    clinic_says('Завтра 16:30 или 17:00?')
    patient_says('Да, на 17:00')
    decide('route_agent', confidence: 0.95, yes_probabilities: { doctors.id => 0.2, procedures.id => 0.4 })
    allow(Captain::Runtime::RoutingEvents).to receive(:failed).and_call_original

    record = suggest

    expect(questions_seen.last[:state][:current_agent_id]).to be_nil
    expect(Captain::Runtime::RoutingEvents).not_to have_received(:failed)
    expect(record).to include('status' => 'draft')
    expect(runs.pluck(:agent)).to eq(["assistant_#{procedures.id}"])
    expect(record.dig('result', 'suggestion_meta', 'routing')).to include('decision_key' => "route_agent_#{procedures.id}")
  end

  it 'gives a first message whose answers name no agent to the most probable agent, never by default to the anchor' do
    decide('route_agent', confidence: 0.95, yes_probabilities: { doctors.id => 0.1, procedures.id => 0.35 })

    record = suggest

    expect(record).to include('status' => 'draft')
    expect(record.dig('result', 'suggestion_meta', 'routing')).to include('decision_key' => "route_agent_#{procedures.id}")
    expect(record.dig('result', 'suggestion_meta', 'routing')).not_to have_key('default_to')
  end

  it 'routes route_agent naming no agent while a sticky agent leads the dialog to the other agent, never back to the sticky one' do
    sticky.confirm!(conversation, procedures.id, request_id: 'earlier')
    clinic_says('Завтра 16:30 или 17:00?')
    patient_says('А к врачу Ивановой можно?')
    decide('route_agent', confidence: 0.99)

    record = suggest

    expect(record).to include('status' => 'draft')
    expect(runs.pluck(:agent)).to eq(["assistant_#{doctors.id}"])
  end

  it 'withdraws the provisional agent of a draft that a new suggestion replaces without feedback: the confirmed agent leads again' do
    sticky.confirm!(conversation, doctors.id, request_id: 'earlier')
    decide('route_agent', yes: [procedures.id])
    suggest
    expect(sticky.read(conversation)).to eq(procedures.id)

    decide('stay_current')
    suggest

    expect(questions_seen.last[:state][:current_agent_id]).to eq(doctors.id)
  end

  it 'leaves no current agent after a regenerated draft that nobody confirmed' do
    decide('route_agent', yes: [procedures.id])
    suggest
    expect(sticky.read(conversation)).to eq(procedures.id)

    decide('route_agent', yes: [procedures.id])
    suggest

    expect(questions_seen.last[:state][:current_agent_id]).to be_nil
  end

  it 'withdraws the provisional agent of a closed "no reply needed" notice' do
    allow(runtime_runner).to receive(:run) do |agent_runtime, _input, **options|
      runs << { agent: agent_runtime.name }
      Captain::Runtime::Result.new(output: { 'response' => '', 'response_mode' => 'suppress', 'operator_note' => 'Ответ не нужен' },
                                   messages: [], usage: nil, error: nil, context: options[:context])
    end
    decide('route_agent', yes: [procedures.id])
    notice = suggest
    expect(notice).to include('status' => 'no_reply')
    expect(sticky.read(conversation)).to eq(procedures.id)

    feedback(notice, 'notice_dismissed')

    expect(sticky.read(conversation)).to be_nil
  end

  it 'drops a confirmed sticky agent when the manager then writes by hand, but not for the sent text of the suggestion' do
    decide('route_agent', yes: [procedures.id])
    first = suggest
    feedback(first, 'applied')
    manager_sends(first.dig('result', 'message'), assisted: true)
    expect(sticky.read(conversation)).to eq(procedures.id)

    manager_sends('А ещё вам нужен приём ЛОР-врача после процедуры — записать?')
    patient_says('Да')
    decide('route_agent', yes: [doctors.id])
    suggest

    expect(questions_seen.last[:state][:current_agent_id]).to be_nil
    expect(sticky.read(conversation)).to eq(doctors.id)
  end

  it 'keeps the budget of one agent after the router chose one, and tells the manager the real deadline' do
    decide('route_agent', yes: [procedures.id])

    record = suggest

    started = Time.zone.parse(record['started_at'])
    expect(record['budget_seconds']).to be_between(Captain::ReplySuggestion::DEFAULT_BUDGET_SECONDS,
                                                   Captain::ReplySuggestion::DEFAULT_BUDGET_SECONDS + 2)
    expect(Time.zone.parse(record['deadline_at']) - started).to be < Captain::ReplySuggestion::DEFAULT_BUDGET_SECONDS + 2
    progress = []
    expect(ActionCable.server).to have_received(:broadcast).at_least(:once) do |_token, payload|
      progress << payload[:data] if payload[:event] == Captain::ReplySuggestion::Broadcaster::PROGRESS_EVENT
    end
    expect(progress.pluck(:budget_seconds)).to include(Captain::ReplySuggestion::ROUTER_BUDGET_SECONDS, record['budget_seconds'])
    expect(progress.pluck(:deadline_at).compact.last).to eq(record['deadline_at'])
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
