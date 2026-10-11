require 'rails_helper'

RSpec.describe Captain::OutcomeClassificationService do
  let(:account) { create(:account, locale: 'ru') }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, status: 'resolved') }
  let(:transition) do
    # Incoming messages can reopen the conversation; model the actual closing action before its audit event.
    conversation.update!(status: 'resolved')
    ConversationStatusTransition.create!(account: account, conversation: conversation, actor: assistant,
                                         from_status: 'pending', to_status: 'resolved', source: 'captain')
  end
  let(:classification) { { 'reason_id' => 'question_resolved', 'explanation' => 'Вопрос решён.', 'needs_more_context' => false } }

  def add_message(content, **attributes)
    create(:message, { account: account, inbox: conversation.inbox, conversation: conversation,
                       content: content, message_type: :incoming, private: false }.merge(attributes))
  end

  before do
    allow(Llm::Config).to receive(:model_for).with(feature: 'outcome_classification', account: account).and_return('openai/gpt-6-luna')
    allow(Llm::Runtime).to receive(:chat).and_return(classification)
  end

  describe 'Microsoft Decision classification' do
    let(:decision_model) { 'microsoft/microsoft-decision-1' }
    let(:decision_result) do
      Llm::OpenRouterDecisionClient::Result.new(choice: 'question_resolved', confidence: 0.9,
                                               model: "#{decision_model}-20261009", provider: 'Azure', request_id: 'gen-dec-test')
    end

    before do
      allow(Llm::Config).to receive(:model_for).with(feature: 'outcome_classification', account: account).and_return(decision_model)
      allow(Llm::Runtime).to receive(:decide).and_return(decision_result)
    end

    it 'persists the native reason and model for reports after the completed action, without sending messages or repeating classification' do
      add_message('Спасибо, теперь всё понятно.')
      transition
      expect(transition.metadata.dig('outcome_classification', 'state')).to eq('pending')
      expect do
        2.times { described_class.new(ConversationStatusTransition.find(transition.id)).perform }
      end.not_to change(Message, :count)

      expect(Llm::Runtime).to have_received(:decide).once
      expect(Llm::Runtime).not_to have_received(:chat)
      expect(transition.reload.reason).to eq('Вопрос решён')
      expect(transition.metadata).to include('outcome_reason_id' => 'question_resolved', 'outcome_reason_type' => 'completion')
      expect(transition.metadata['outcome_classification']).to include(
        'state' => 'completed', 'model' => decision_model, 'served_model' => "#{decision_model}-20261009",
        'request_id' => 'gen-dec-test', 'provider' => 'Azure', 'confidence' => 0.9, 'explanation' => ''
      )
      expect(conversation.reload.status).to eq('resolved')
    end

    it 'expands at most once and excludes private, future and sibling-dialogue content from both requests' do
      23.times { |index| add_message("Public #{index}") }
      add_message('PRIVATE NOTE', private: true)
      transition
      add_message('FUTURE MESSAGE')
      sibling = create(:conversation, account: account, contact: conversation.contact)
      add_message('OTHER CONVERSATION', conversation: sibling, inbox: sibling.inbox)
      decision_result.choice = Captain::OutcomeDecisionEngine::MORE_CONTEXT
      counts = []
      allow(Llm::Runtime).to receive(:decide) do |args|
        counts << args[:input][:messages].size
        expect(args[:input].to_json).not_to include('PRIVATE NOTE', 'FUTURE MESSAGE', 'OTHER CONVERSATION')
        decision_result
      end

      described_class.new(transition).perform

      expect(counts).to eq([6, 20])
      expect(transition.reload.metadata['outcome_classification']).to include('state' => 'insufficient_context', 'reason_id' => 'other', 'expanded' => true)
      expect(conversation.reload.status).to eq('open')
    end

    it 'records provider failures explicitly without fabricating an other reason or undoing the business outcome' do
      add_message('Спасибо')
      transition
      allow(Llm::Runtime).to receive(:decide).and_raise(Llm::OpenRouterDecisionClient::Error, 'OpenRouter decision transport unavailable.')

      expect { described_class.new(transition).perform }.not_to change(Message, :count)

      expect(transition.reload.metadata['outcome_classification']).to include('state' => 'failed', 'error_code' => 'classification_unavailable')
      expect(transition.metadata).not_to have_key('outcome_reason_id')
      expect(conversation.reload.status).to eq('resolved')
      expect(Llm::Runtime).not_to have_received(:chat)
    end
  end

  it 'queues only committed AI outcomes and never an ordinary message or manual transition' do
    expect { add_message('Спасибо') }.not_to have_enqueued_job(Captain::OutcomeClassificationJob)
    expect { transition }.to have_enqueued_job(Captain::OutcomeClassificationJob)
    manual = ConversationStatusTransition.create!(account: account, conversation: conversation,
                                                 actor: create(:user), from_status: 'resolved', to_status: 'open', source: 'manual')
    expect(manual.metadata).not_to have_key('outcome_classification')
    described_class.new(manual).perform
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'does not enqueue a rolled-back outcome' do
    expect do
      ConversationStatusTransition.transaction do
        transition
        raise ActiveRecord::Rollback
      end
    end.not_to have_enqueued_job(Captain::OutcomeClassificationJob)
  end

  it 'uses at most six public messages from the exact dialogue as of the transition, without the agent prompt' do
    assistant.update!(description: 'PRIVATE SYSTEM INSTRUCTION')
    9.times { |index| add_message("Message #{index}") }
    add_message('PRIVATE NOTE', private: true)
    transition
    add_message('FUTURE CUSTOMER MESSAGE')
    sibling = create(:conversation, account: account, contact: conversation.contact)
    add_message('OTHER DIALOGUE', conversation: sibling, inbox: sibling.inbox)

    described_class.new(transition).perform

    expect(Llm::Runtime).to have_received(:chat).once do |args|
      expect(args[:feature]).to eq(:outcome_classification)
      expect(args[:model]).to eq('openai/gpt-6-luna')
      expect(args.fetch(:tools, [])).to be_empty
      payload = JSON.parse(args[:messages].last[:content])
      expect(payload['messages'].size).to eq(6)
      expect(payload['messages'].map { |row| row['content'] }).to eq((3..8).map { |index| "Message #{index}" })
      expect(args[:messages].to_json).not_to include('PRIVATE', 'FUTURE CUSTOMER MESSAGE', 'OTHER DIALOGUE')
    end
    expect(transition.reload.metadata['outcome_reason_id']).to eq('question_resolved')
    expect(transition.reason).to eq('Вопрос решён')
    expect(conversation.reload.status).to eq('open') # A later incoming message reopened it; classification must not undo that.
  end

  it 'permits one bounded expansion and falls back to other if the classifier still requests more' do
    25.times { |index| add_message("Message #{index} " + ('x' * 1500)) }
    allow(Llm::Runtime).to receive(:chat).and_return(classification.merge('needs_more_context' => true))
    sizes = []
    expansions = []
    allow(Llm::Runtime).to receive(:chat) do |args|
      payload = JSON.parse(args[:messages].last[:content])
      sizes << payload['messages'].size
      expansions << payload['expansion_available']
      expect(payload['messages'].all? { |row| row['content'].length <= 1000 }).to be true
      classification.merge('needs_more_context' => true)
    end

    described_class.new(transition).perform

    expect(sizes).to eq([6, 20])
    expect(expansions).to eq([true, false])
    expect(transition.reload.metadata['outcome_classification']).to include('state' => 'insufficient_context', 'expanded' => true, 'reason_id' => 'other')
  end

  it 'does not classify a duplicate job or change a newer conversation state or send a message' do
    add_message('Спасибо, всё понятно')
    transition
    conversation.update!(status: 'open')
    expect do
      2.times { described_class.new(ConversationStatusTransition.find(transition.id)).perform }
    end.not_to change(Message, :count)
    expect(Llm::Runtime).to have_received(:chat).once
    expect(conversation.reload.status).to eq('open')
  end

  it 'does not race an active claim and recovers an expired claim using the same event' do
    add_message('Спасибо')
    data = transition.metadata.fetch('outcome_classification').merge('state' => 'processing', 'claim_id' => 'older',
                                                                   'lease_until' => 5.minutes.from_now.to_i)
    transition.update!(metadata: { 'outcome_classification' => data })
    described_class.new(transition).perform
    expect(Llm::Runtime).not_to have_received(:chat)
    transition.update!(metadata: { 'outcome_classification' => data.merge('lease_until' => 1.minute.ago.to_i) })
    described_class.new(transition).perform
    expect(Llm::Runtime).to have_received(:chat).once
    expect(transition.reload.metadata.dig('outcome_classification', 'state')).to eq('completed')
  end

  it 'marks invalid or unavailable classification honestly without failing or changing the business action' do
    add_message('Здравствуйте')
    allow(Llm::Runtime).to receive(:chat).and_return(classification.merge('reason_id' => 'unknown_or_another_agent_reason'))
    expect { described_class.new(transition).perform }.not_to raise_error
    expect(transition.reload.metadata['outcome_classification']).to include('state' => 'failed', 'error_code' => 'classification_unavailable')
    expect(transition.metadata).not_to have_key('outcome_reason_id')
    expect(transition.reason).to eq('Причина не определена')
    expect(conversation.reload.status).to eq('resolved')
  end

  it 'does not spend a model request when the event has no public context' do
    described_class.new(transition).perform
    expect(Llm::Runtime).not_to have_received(:chat)
    expect(transition.reload.metadata['outcome_classification']).to include('state' => 'insufficient_context', 'reason_id' => 'other')
  end

  it 'finishes an orphaned pending event honestly when the actor is unavailable' do
    transition.update_columns(actor_id: nil)
    described_class.new(transition.reload).perform
    expect(Llm::Runtime).not_to have_received(:chat)
    expect(transition.reload.metadata['outcome_classification']).to include('state' => 'failed', 'error_code' => 'actor_unavailable')
    expect(transition.reason).to eq('Причина не определена')
  end

  it 'stops recovery after three crashed attempts and clears the expired claim' do
    data = transition.metadata.fetch('outcome_classification').merge('state' => 'processing', 'claim_id' => 'expired',
                                                                   'attempts' => 3, 'lease_until' => 1.minute.ago.to_i)
    transition.update!(metadata: { 'outcome_classification' => data })
    described_class.new(transition).perform
    expect(Llm::Runtime).not_to have_received(:chat)
    result = transition.reload.metadata['outcome_classification']
    expect(result).to include('state' => 'failed', 'error_code' => 'attempts_exhausted')
    expect(result).not_to have_key('claim_id')
    expect(result).not_to have_key('lease_until')
    expect(transition.reason).to eq('Причина не определена')
  end

  it 'records a verified mandatory FAQ miss without another model call' do
    assistant.update!(config: assistant.config.merge('feature_faq' => true, 'handoff_enabled' => true))
    add_message('Есть ли такая услуга?')
    audit = Captain::OutcomeReasonConfig.new(assistant).pending_transition_options(:handoff, signal: 'faq_no_answer')[:audit]
    event = ConversationStatusTransition.create!(account: account, conversation: conversation, actor: assistant,
                                                from_status: 'pending', to_status: 'open', source: 'captain', metadata: audit[:metadata])
    described_class.new(event).perform
    expect(event.reload.metadata['outcome_reason_id']).to eq('faq_no_answer')
    expect(event.metadata['outcome_classification']).to include('state' => 'completed', 'method' => 'faq_result')
    expect(Llm::Runtime).not_to have_received(:chat)
  end

  it 'uses the reason definitions captured at the event, not later administrator changes' do
    add_message('Спасибо')
    transition
    assistant.update!(config: assistant.config.deep_merge('outcome_reason_settings' => {
                                                          'completion_reasons' => [{ 'id' => 'question_resolved', 'label' => 'Renamed later', 'active' => false }]
                                                        }))
    described_class.new(transition).perform
    expect(transition.reload.reason).to eq('Вопрос решён')
  end
end
