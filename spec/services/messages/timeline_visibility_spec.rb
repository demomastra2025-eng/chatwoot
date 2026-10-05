# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messages::TimelineVisibility do
  let(:conversation) { create(:conversation) }
  let(:account) { conversation.account }
  let(:visible_messages) { described_class.apply(conversation.messages) }
  let(:tool_event_attributes) do
    {
      account: account,
      conversation: conversation,
      event_name: 'llm.tool.complete',
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      tool_name: 'search_scheduling_services',
      error: false,
      tool_failure: false,
      payload: { 'result_success' => true }
    }
  end

  def project_tool_event(request_id:, **overrides)
    event = create(:llm_event, **tool_event_attributes, request_id: request_id, **overrides)
    Llm::Monitoring::ConversationTimelineProjector.new(event).call
  end

  def create_activity(**attributes)
    create(:message, message_type: :activity, account: account, inbox: conversation.inbox, conversation: conversation, **attributes)
  end

  describe '.apply' do
    context 'with lines written by the Captain projector' do
      let!(:completed_line) { project_tool_event(request_id: 'request-completed') }
      let!(:failed_line) do
        project_tool_event(request_id: 'request-failed', error: true, tool_failure: true, payload: { 'result_success' => false })
      end

      it 'hides completed and failed tool lines in the account language' do
        account.update!(locale: :ru)
        russian_line = project_tool_event(request_id: 'request-russian')

        expect(russian_line.content).to eq('ИИ Агент выполнил инструмент «search_scheduling_services»')
        expect(completed_line.content_attributes.dig('data', 'event')).to eq('completed')
        expect(failed_line.content_attributes.dig('data', 'event')).to eq('failed')
        expect(visible_messages).not_to include(completed_line, failed_line, russian_line)
      end

      it 'keeps the stored rows and the data that feeds the trace' do
        visible_messages.load

        stored = conversation.messages.activity.where(id: [completed_line.id, failed_line.id])
        expect(stored.count).to eq(2)
        expect(stored.map { |line| line.content_attributes.dig('data', 'llm_event_id') }).to all(be_present)
      end
    end

    context 'with rows stored before the marker was shared' do
      it 'hides a row recognised only by the projector source namespace' do
        legacy_line = create_activity(source_id: 'captain-tool:0123abcd', content: 'AI Agent completed tool search_deals')

        expect(visible_messages).not_to include(legacy_line)
      end

      it 'hides a row recognised only by the projector data type' do
        legacy_line = create_activity(
          content: 'ИИ Агент выполнил инструмент «search_deals»',
          content_attributes: { data: { type: 'captain_tool_event', event: 'completed' } }
        )

        expect(visible_messages).not_to include(legacy_line)
      end

      it 'hides a row whose attributes were stored as a plain JSON object' do
        legacy_line = create_activity(content: 'ИИ Агент выполнил инструмент «search_deals»')
        plain_object = '{"data":{"type":"captain_tool_event"}}'
        Message.connection.execute("UPDATE messages SET content_attributes = '#{plain_object}'::json WHERE id = #{legacy_line.id.to_i}")

        expect(visible_messages).not_to include(legacy_line)
      end

      it 'keeps an activity row whose attributes carry another data type' do
        other_line = create_activity(content_attributes: { data: { type: 'call_summary' } })

        expect(visible_messages).to include(other_line)
      end
    end

    context 'with other timeline messages' do
      it 'keeps every other kind of activity, including the handoff to a human' do
        assignment = create_activity(content: 'Conversation was assigned to Alex')
        status = create_activity(content: 'Conversation was marked resolved by Alex')
        handoff_open = create_activity(content: I18n.t('conversations.activity.captain.open', user_name: 'AI Agent'))
        handoff_reason = create_activity(
          content: I18n.t('conversations.activity.captain.open_with_reason', user_name: 'AI Agent', reason: 'customer asked for a human')
        )
        call_event = create_activity(source_id: 'ai_voice_event:call:ai_answered:1', content: 'AI Agent answered the call')
        customer_visible_handoff = create(
          :message,
          message_type: :outgoing,
          account: account,
          inbox: conversation.inbox,
          conversation: conversation,
          content: I18n.t('conversations.captain.handoff')
        )

        expect(visible_messages).to include(assignment, status, handoff_open, handoff_reason, call_event, customer_visible_handoff)
      end

      it 'still hides the noisy telemetry' do
        telemetry = create_activity(source_id: 'ai_voice_event:call:ai_speaking:1')

        expect(visible_messages).not_to include(telemetry)
      end
    end

    context 'with messages that only look like a tool line' do
      let(:tool_line_text) { 'ИИ Агент выполнил инструмент «search_deals»' }

      it 'never decides by the text' do
        typed_incoming = create(:message, message_type: :incoming, account: account, inbox: conversation.inbox,
                                          conversation: conversation, content: tool_line_text)
        typed_note = create(:message, message_type: :outgoing, private: true, account: account, inbox: conversation.inbox,
                                      conversation: conversation, content: tool_line_text)
        unmarked_activity = create_activity(content: tool_line_text)

        expect(visible_messages).to include(typed_incoming, typed_note, unmarked_activity)
      end

      it 'only hides activity rows, whatever a regular message carries in its attributes' do
        regular = create(
          :message,
          message_type: :incoming,
          account: account,
          inbox: conversation.inbox,
          conversation: conversation,
          content_attributes: { data: { type: 'captain_tool_event' } }
        )

        expect(visible_messages).to include(regular)
      end
    end
  end

  describe '.without_captain_tool_activity' do
    it 'removes only the tool lines from any message scope' do
      tool_line = project_tool_event(request_id: 'request-scope')
      regular = create(:message, account: account, inbox: conversation.inbox, conversation: conversation)
      noisy = create_activity(source_id: 'ai_voice_event:call:ai_speaking:2')

      result = described_class.without_captain_tool_activity(Message.where(conversation_id: conversation.id))

      expect(result).to include(regular, noisy)
      expect(result).not_to include(tool_line)
    end
  end
end
