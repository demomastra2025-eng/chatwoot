# frozen_string_literal: true

require 'rails_helper'

# A reply suggestion reads the patient card and the upcoming appointments of the patient circle once, when the run starts, and gives
# them to the prompt of the agent that answers; a conversation reads nothing in advance (#generate_response). All data is synthetic.
RSpec.describe Captain::Assistant::AgentRunnerService, '#generate_response' do
  let(:service) do
    described_class.new(assistant: assistant, conversation: conversation, source: source, request_id: SecureRandom.uuid,
                        callbacks: { on_suggestion_preload: ->(preload) { reported << preload } })
  end
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Айгуль', last_name: 'Ахметова') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:tool_ids) { %w[get_my_contact list_my_appointments faq_lookup] }
  let(:assistant) do
    create(:captain_assistant, account: account, config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => tool_ids } } })
  end
  let(:source) { 'reply_suggestion' }
  let(:reported) { [] }
  let(:message_history) { [{ role: 'user', content: 'Когда моя запись?' }] }
  let(:mock_runner) { instance_double(Captain::Runtime::AgentRunner) }
  let(:run_contexts) { [] }
  let(:runner_output) { { 'patient_language' => 'Russian', 'response' => 'Ваша запись завтра.', 'response_mode' => 'reply' } }
  let(:runner_result) { instance_double(Captain::Runtime::Result, output: runner_output, context: { current_agent: 'assistant_agent' }, error: nil) }

  before do
    account.enable_features!('scheduling')
    allow(Llm::Config).to receive(:initialize!)
    allow(Llm::ApiClient).to receive(:moderate).and_return(instance_double(RubyLLM::Moderation, flagged?: false))
    allow(Captain::Runtime::Runner).to receive(:with_agents).and_return(mock_runner)
    allow(mock_runner).to receive(:run) do |_input, context:, **|
      run_contexts << context
      runner_result
    end
    Captain::Runtime::CallbackManager::EVENT_TYPES.each { |event_type| allow(mock_runner).to receive(:"on_#{event_type}").and_return(mock_runner) }
  end

  it 'puts the card and the upcoming appointments into the context of the run and reports what was read' do
    visit = create(:scheduling_appointment, account: account, contact: contact, starts_at: 1.day.from_now)

    service.generate_response(message_history: message_history)

    preload = run_contexts.first[:suggestion_preload]
    expect(preload[:card]).to include(first_name: 'Айгуль', last_name: 'Ахметова')
    expect(preload[:appointments].pluck(:id)).to eq([visit.id])
    expect(reported.first).to include('parts' => %w[card appointments], 'ms' => be_a(Integer))
  end

  context 'when the agent has no tool that reads the patient' do
    let(:tool_ids) { %w[faq_lookup] }

    it 'reads nothing' do
      service.generate_response(message_history: message_history)

      expect(run_contexts.first).not_to have_key(:suggestion_preload)
      expect(reported.first).to include('parts' => [])
    end
  end

  context 'when the run is a live conversation' do
    let(:source) { 'incoming_message' }

    it 'reads nothing in advance: the agent reads with its tools' do
      service.generate_response(message_history: message_history)

      expect(run_contexts.first).not_to have_key(:suggestion_preload)
      expect(reported).to be_empty
    end
  end

  describe 'the FAQ answers close to the message of the patient' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    let(:answers) { [{ question: 'Как подготовиться к УЗИ?', answer: 'Не есть за 6 часов.', score: 0.83 }] }
    let(:faq_preload) { instance_double(Captain::ReplySuggestion::FaqPreload, matches: answers) }

    before { allow(Captain::ReplySuggestion::FaqPreload).to receive(:start).and_return(faq_preload) }

    it 'are searched for the latest words of the patient, from the start, and given to the run with the agent that answers' do
      history = [{ role: 'user', content: 'Здравствуйте' }, { role: 'assistant', content: 'Добрый день' },
                 { role: 'user', content: 'Подскажите про УЗИ' }, { role: 'user', content: 'Как подготовиться?' }]

      service.generate_response(message_history: history)

      expect(Captain::ReplySuggestion::FaqPreload).to have_received(:start)
        .with(account: account, text: "Подскажите про УЗИ\nКак подготовиться?")
      expect(faq_preload).to have_received(:matches).with(assistant)
      expect(run_contexts.first[:suggestion_preload][:faq]).to eq(answers)
      expect(reported.first['parts']).to eq(%w[card appointments faq])
    end

    it 'are searched without the send times that the platform stamps on the messages of the history' do
      history = [{ role: 'user', content: 'Подскажите про УЗИ', sent_at: Time.zone.parse('2026-10-26 09:50') },
                 { role: 'user', content: 'Как подготовиться?' }]

      service.generate_response(message_history: history)

      expect(Captain::ReplySuggestion::FaqPreload).to have_received(:start).with(account: account, text: "Подскажите про УЗИ\nКак подготовиться?")
    end

    it 'are not added when there are none' do
      allow(faq_preload).to receive(:matches).and_return([])

      service.generate_response(message_history: message_history)

      expect(run_contexts.first[:suggestion_preload]).not_to have_key(:faq)
    end

    it 'are not searched for a council: its parts search with their tools' do
      allow_any_instance_of(described_class).to receive(:council_turn?).and_return(true) # rubocop:disable RSpec/AnyInstance

      service.generate_response(message_history: message_history)

      expect(faq_preload).not_to have_received(:matches)
    end

    context 'when the run is a live conversation' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:source) { 'incoming_message' }

      it 'are not searched in advance' do
        service.generate_response(message_history: message_history)

        expect(Captain::ReplySuggestion::FaqPreload).not_to have_received(:start)
      end
    end

    it 'cost nothing when the search cannot start: the run goes on and the agent has faq_lookup' do
      allow(Captain::ReplySuggestion::FaqPreload).to receive(:start).and_raise(StandardError, 'boom')

      result = service.generate_response(message_history: message_history)

      expect(result).to include('response' => 'Ваша запись завтра.')
      expect(run_contexts.first[:suggestion_preload]).not_to have_key(:faq)
    end
  end

  it 'goes on without the preload when reading it fails: the tools are still there' do
    allow(Captain::ReplySuggestion::PatientPreload).to receive(:build).and_raise(ActiveRecord::StatementInvalid, 'boom')

    result = service.generate_response(message_history: message_history)

    expect(result).to include('response' => 'Ваша запись завтра.')
    expect(run_contexts.first).not_to have_key(:suggestion_preload)
  end
end
