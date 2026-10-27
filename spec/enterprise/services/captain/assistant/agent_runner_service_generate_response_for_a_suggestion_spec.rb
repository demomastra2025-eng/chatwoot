# frozen_string_literal: true

require 'rails_helper'

# What a reply suggestion needs to be right on a Monday morning: the operator answers the patients of the weekend, so the agent must
# read a Saturday "tomorrow" from Saturday, and a loop of tool calls must still end with a draft and its approval cards.
RSpec.describe Captain::Assistant::AgentRunnerService, '#generate_response for a suggestion' do
  let(:service) do
    described_class.new(scope: Captain::ChannelScope.for_conversation(conversation), conversation: conversation, source: 'reply_suggestion',
                        request_id: SecureRandom.uuid)
  end

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, timezone: 'Asia/Almaty') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: create(:contact, account: account)) }
  let!(:assistant) { create(:captain_assistant, account: account) }
  let(:almaty) { Time.find_zone('Asia/Almaty') }
  let(:mock_runner) { instance_double(Captain::Runtime::AgentRunner) }
  let(:runs) { [] }
  let(:draft) { { 'response' => 'Ваша запись на воскресенье, 25 октября, в 10:10 уже прошла.', 'response_mode' => 'reply' } }

  before do
    allow(Llm::Config).to receive(:initialize!)
    allow(Llm::ApiClient).to receive(:moderate).and_return(instance_double(RubyLLM::Moderation, flagged?: false))
    allow(Captain::Runtime::Runner).to receive(:with_agents).and_return(mock_runner)
    Captain::Runtime::CallbackManager::EVENT_TYPES.each { |event_type| allow(mock_runner).to receive(:"on_#{event_type}").and_return(mock_runner) }
  end

  def add_message(type, content, at)
    create(:message, conversation: conversation, account: account, message_type: type, content: content, created_at: at)
  end

  def run_returns(*results)
    allow(mock_runner).to receive(:run) do |input, context:, max_turns:, runtime_options:|
      runs << { input: input, context: context, max_turns: max_turns, runtime_options: runtime_options }
      results[runs.size - 1] || results.last
    end
  end

  def agent_result(output:, context: { current_agent: assistant.agent_name }, error: nil)
    instance_double(Captain::Runtime::Result, output: output, context: context, error: error)
  end

  describe 'a message of Saturday answered on Monday' do
    before do
      add_message(:incoming, 'Можно завтра в 10:10 к терапевту?', almaty.local(2026, 10, 24, 9, 40))
      add_message(:outgoing, 'Да, записали вас на завтра в 10:10.', almaty.local(2026, 10, 24, 9, 45))
      add_message(:incoming, 'Я записан на 10:10 завтра?', almaty.local(2026, 10, 24, 9, 50))
      run_returns(agent_result(output: draft))
    end

    def suggest_on_monday
      travel_to(almaty.local(2026, 10, 26, 9, 0)) do
        history = Captain::ReplySuggestion::HistoryBuilder.new(account: account, conversation: conversation, assistant: assistant).perform
        service.generate_response(message_history: history)
      end
    end

    it 'shows the agent every earlier message after its Saturday send time and keeps the message being answered as it is' do
      suggest_on_monday

      expect(runs.first[:input]).to eq('Я записан на 10:10 завтра?')
      expect(runs.first[:context][:conversation_history]).to eq(
        [
          { role: :user, content: '[Sat 24.10 09:40] Можно завтра в 10:10 к терапевту?' },
          { role: :assistant, content: '[Sat 24.10 09:45] Да, записали вас на завтра в 10:10.' }
        ]
      )
      expect(runs.first[:context][:state][:runtime_clock]).to include(
        timezone: 'Asia/Almaty', date_local: '2026-10-26', message_sent_at: '2026-10-24T04:50:00Z'
      )
    end

    it 'tells the agent in the prompt when the patient wrote and to read "tomorrow" from that day' do
      suggest_on_monday

      prompt = travel_to(almaty.local(2026, 10, 26, 9, 0)) do
        assistant.agent_instructions(Captain::Runtime::RunContext.new(runs.first[:context]))
      end

      expect(prompt).to include(
        'Monday, 26 October 2026 (2026-10-26), 09:00, Almaty (UTC+5).',
        "Patient's last message was sent Saturday, 24 October 2026 (2026-10-24), 09:50 (2 days ago). " \
        'Read its relative days from that day, never from the clock above: ' \
        'today (сегодня, бүгін) = Saturday, 24 October 2026 (2026-10-24), ' \
        'tomorrow (завтра, ертең) = Sunday, 25 October 2026 (2026-10-25), ' \
        'the day after tomorrow (послезавтра) = Monday, 26 October 2026 (2026-10-26). ' \
        'By the clock above: 2026-10-24 has passed (2 days ago), 2026-10-25 has passed (yesterday), 2026-10-26 is today, ' \
        '2026-10-27 is tomorrow. ' \
        'In your reply name such a day by its date, and call a day today or tomorrow only when it is today or tomorrow by the clock above.',
        'Read today, tomorrow, the day after tomorrow and weekdays in every patient message from the day that message was sent, never from Now'
      )
      expect(prompt).not_to include('It is after midnight')
    end

    it 'drops a send stamp that the model copied into its reply' do
      run_returns(agent_result(output: draft.merge('response' => '[Mon 26.10 09:00] Здравствуйте! Запись была на 25 октября.')))

      expect(suggest_on_monday['response']).to eq('Здравствуйте! Запись была на 25 октября.')
    end
  end

  describe 'a run that the loop guard stops' do
    let(:card) do
      { 'action_id' => 'card-1', 'tool_name' => 'create_task', 'status' => 'pending', 'title' => 'Создать задачу',
        'description' => 'Задача: Перезвонить пациенту' }
    end
    let(:tool_history) do
      [
        { role: :user, content: 'Перезвоните мне, пожалуйста' },
        { role: :assistant, content: '', tool_calls: [{ id: 'call_1', name: 'create_task', arguments: { title: 'Перезвонить' } }] },
        { role: :tool, content: '{"success":true,"status":"pending_operator_approval"}', tool_call_id: 'call_1' }
      ]
    end
    let(:stopped_context) do
      { current_agent: assistant.agent_name, conversation_history: tool_history, captain_suggestion_pending_actions: [card] }.tap do |context|
        context[Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY] = { tool_name: 'search_available_slots', result: { success: false } }
      end
    end

    it 'writes the draft from the results so far in one call without tools and keeps the approval cards' do
      run_returns(
        agent_result(output: nil, context: stopped_context, error: Captain::Runtime::Runner::ToolLoopStopped.new('Tool request limit reached')),
        agent_result(output: { 'response' => 'Передала просьбу перезвонить, администратор свяжется с вами.' }, context: stopped_context)
      )

      result = service.generate_response(message_history: [{ role: 'user', content: 'Перезвоните мне, пожалуйста' }])

      expect(runs.size).to eq(2)
      expect(runs.second[:runtime_options]).to include(finalization_only: true, continue_from_history: true)
      expect(result).to include('response' => 'Передала просьбу перезвонить, администратор свяжется с вами.', 'finalization_only_retry' => true,
                                'pending_actions' => [card])
      expect(result).not_to include('error_class')
    end
  end
end
