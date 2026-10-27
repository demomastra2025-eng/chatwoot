# frozen_string_literal: true

require 'rails_helper'

# The trace of a reply suggestion shows the parts of a council while they run; once the council answered, every part shows the
# status it ended with (Council#reset_reply_state), never "running".
RSpec.describe Enterprise::Captain::ReplySuggestionService::TraceCollector do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:collector) { described_class.new(assistant: assistant, conversation: conversation, user: user) }

  def part_context(id)
    OpenStruct.new(context: { part_run: true, active_part_id: id, state: { assistant_id: assistant.id },
                              part_info: { id: id, fragment: "Запрос #{id}" } })
  end

  describe 'the first words of the draft' do
    let(:progress_context) do
      { suggestion_request_id: 'sr-9', conversation_id: conversation.display_id, started_at: Time.current,
        deadline_at: 60.seconds.from_now, budget_seconds: 60 }
    end
    let(:collector) do
      described_class.new(assistant: assistant, conversation: conversation, user: user, progress_context: progress_context)
    end
    let(:run) { OpenStruct.new(context: { state: { assistant_id: assistant.id } }) }
    let(:answer) { '{"patient_language":"ru","response":"Здравствуйте, Анна! Приём стоит 8000 тенге.","response_mode":"reply"}' }
    let(:broadcasts) { [] }

    def previews
      broadcasts.select { |_token, message| message[:event] == Captain::ReplySuggestion::Broadcaster::PREVIEW_EVENT }
    end

    def preview_texts
      previews.map { |_token, message| message.dig(:data, :text) }
    end

    before do
      allow(ActionCable.server).to receive(:broadcast) { |token, message| broadcasts << [token, message] }
      allow(Captain::ReplySuggestion::RequestStore).to receive(:write_progress)
    end

    it 'listens to the answer of the agent only for a request that has an id' do
      plain = described_class.new(assistant: assistant, conversation: conversation, user: user)

      expect(collector.callbacks).to include(:on_answer_delta)
      expect(plain.callbacks).not_to include(:on_answer_delta)
    end

    it 'sends what the agent has written to the manager who asked, with the request and conversation it belongs to' do
      collector.callbacks[:on_agent_thinking].call(assistant.agent_name, 'Вопрос', run)
      collector.callbacks[:on_answer_delta].call(assistant.agent_name, answer, run)

      expect(previews.size).to eq(1)
      token, message = previews.first
      expect(token).to eq(user.pubsub_token)
      expect(message[:data]).to eq(
        suggestion_request_id: 'sr-9', account_id: account.id, conversation_id: conversation.display_id,
        conversation_record_id: conversation.id, seq: 1, text: 'Здравствуйте, Анна! Приём стоит 8000 тенге.'
      )
    end

    it 'sends the words that the interval held back when the call of the agent ends' do
      collector.callbacks[:on_answer_delta].call(assistant.agent_name, '{"response":"Здравствуйте, Анна', run)
      collector.callbacks[:on_answer_delta].call(assistant.agent_name, '! Приём стоит 8000 тенге."', run)
      collector.callbacks[:on_llm_call_complete].call(assistant.agent_name, 'model', OpenStruct.new(content: '{}', tool_call?: false), run)

      expect(preview_texts).to eq(['Здравствуйте, Анна', 'Здравствуйте, Анна! Приём стоит 8000 тенге.'])
    end

    it 'takes the text back when a tool is about to run' do
      collector.callbacks[:on_answer_delta].call(assistant.agent_name, '{"response":"Сейчас проверю расписание"}', run)
      collector.callbacks[:on_tool_start].call('search_available_slots', {}, run)

      expect(preview_texts).to eq(['Сейчас проверю расписание', ''])
    end

    it 'does not show the words of the part of a council' do
      part = OpenStruct.new(context: { part_run: true, active_part_id: 'p1', state: { assistant_id: assistant.id },
                                       part_info: { id: 'p1', fragment: 'Запрос' } })

      collector.callbacks[:on_answer_delta].call(assistant.agent_name, answer, part)
      collector.callbacks[:on_agent_thinking].call(assistant.agent_name, 'Запрос', part)
      collector.callbacks[:on_llm_call_complete].call(assistant.agent_name, 'model', OpenStruct.new(content: '{}', tool_call?: false), part)

      expect(previews).to be_empty
    end

    it 'keeps the words out of the progress that is kept for a manager who returns to the conversation' do
      collector.callbacks[:on_answer_delta].call(assistant.agent_name, answer, run)
      collector.callbacks[:on_agent_thinking].call(assistant.agent_name, 'Вопрос', run)
      collector.callbacks[:on_tool_start].call('faq_lookup', {}, run)

      expect(Captain::ReplySuggestion::RequestStore).to have_received(:write_progress).at_least(:once) do |_id, data|
        expect(data.to_json).not_to include('Здравствуйте')
      end
      expect(broadcasts.reject { |_token, message| message[:event] == Captain::ReplySuggestion::Broadcaster::PREVIEW_EVENT }
                       .to_json).not_to include('Здравствуйте')
    end
  end

  it 'shows a part as running while it runs and with the status it ended with once the council answered' do
    %w[p1 p2].each { |id| collector.callbacks[:on_agent_thinking].call(assistant.agent_name, "Запрос #{id}", part_context(id)) }

    expect(collector.suggestion_meta({}.with_indifferent_access)['council']['parts'].pluck('status')).to eq(%w[running running])

    payload = { 'council_parts' => [{ 'id' => 'p1', 'status' => 'needs_information' },
                                    { 'id' => 'p2', 'status' => 'unavailable', 'stop_reason' => 'max_turns' }] }.with_indifferent_access
    parts = collector.suggestion_meta(payload)['council']['parts']

    expect(parts).to match([include('id' => 'p1', 'status' => 'needs_information'),
                            include('id' => 'p2', 'status' => 'unavailable', 'stop_reason' => 'max_turns')])
  end
end
