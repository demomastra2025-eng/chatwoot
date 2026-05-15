require 'rails_helper'

RSpec.describe 'Captain assistant account observability tools' do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe 'registry metadata' do
    it 'registers account-scoped observability tools for assistant scope only' do
      assistant_ids = Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)
      agent_ids = Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(assistant_ids).to include(
        'get_account_health',
        'get_recent_account_errors',
        'trace_ai_response',
        'trace_message_delivery',
        'get_channel_health'
      )
      expect(agent_ids).not_to include(
        'get_account_health',
        'get_recent_account_errors',
        'trace_ai_response',
        'trace_message_delivery',
        'get_channel_health'
      )
    end
  end

  describe Captain::Tools::Copilot::GetAccountHealthService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'is administrator-only' do
      expect(service.active?).to be true
      expect(described_class.new(assistant, user: agent).active?).to be false
    end

    it 'returns an account-scoped health snapshot without leaking other accounts' do
      create(:llm_event, account: account, event_name: 'llm.chat.complete', status: 'completed', total_tokens: 100)
      create(:llm_event, account: account, event_name: 'llm.tool.complete', status: 'failed', error: true, tool_failure: true)
      create(:llm_event, account: other_account, event_name: 'llm.chat.complete', status: 'completed')

      payload = JSON.parse(service.execute(since: 2.hours.ago.iso8601))

      expect(payload).to include('account_id' => account.id, 'status' => 'degraded')
      expect(payload.fetch('snapshot')).to include('total_events' => 2, 'request_count' => 1, 'error_count' => 1, 'tool_failure_count' => 1)
      expect(payload.fetch('recommendations')).to include(a_string_matching(/recent failed/i))
    end
  end

  describe Captain::Tools::Copilot::GetRecentAccountErrorsService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'returns only account errors with sanitized payload details' do
      error_event = create(
        :llm_event,
        account: account,
        event_name: 'llm.tool.complete',
        feature: 'assistant',
        tool_name: 'search_documentation',
        status: 'failed',
        error: true,
        payload: { 'message' => 'boom', 'api_token' => 'secret-token' },
        created_at: 10.minutes.ago
      )
      create(:llm_event, account: account, event_name: 'llm.chat.complete', status: 'completed')
      create(:llm_event, account: other_account, event_name: 'llm.tool.complete', status: 'failed', error: true)

      payload = JSON.parse(service.execute(limit: 10))

      expect(payload.fetch('total_count')).to eq(1)
      expect(payload.fetch('events').first).to include('id' => error_event.id, 'tool_name' => 'search_documentation')
      expect(payload.fetch('events').first.fetch('details')).to include('message' => 'boom', 'api_token' => '[REDACTED]')
    end
  end

  describe Captain::Tools::Copilot::TraceAiResponseService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'returns a sanitized account-scoped event timeline for a trace' do
      first = create(:llm_event, account: account, trace_id: 'trace-123', event_name: 'llm.chat.start',
                                 payload: { 'authorization' => 'Bearer secret' }, created_at: 2.minutes.ago)
      second = create(:llm_event, account: account, trace_id: 'trace-123', event_name: 'llm.chat.complete', created_at: 1.minute.ago)
      create(:llm_event, account: other_account, trace_id: 'trace-123', event_name: 'llm.chat.complete')

      payload = JSON.parse(service.execute(trace_id: 'trace-123'))

      expect(payload).to include('matched_count' => 2)
      expect(payload.fetch('events').map { |event| event.fetch('id') }).to eq([first.id, second.id])
      expect(payload.fetch('events').first.fetch('details')).to include('authorization' => '[REDACTED]')
    end

    it 'requires at least one trace filter' do
      expect(service.execute).to include('trace_id, request_id, session_id, conversation_id, or conversation_display_id is required')
    end
  end

  describe Captain::Tools::Copilot::TraceMessageDeliveryService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'summarizes delivery state for one permissible account conversation' do
      inbox = create(:inbox, account: account, name: 'WhatsApp')
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'outgoing', status: 'delivered', content: 'ok')
      failed = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'outgoing', status: 'failed',
                                content: 'bad', content_attributes: { external_error: 'provider timeout' })

      payload = JSON.parse(service.execute(conversation_id: conversation.display_id))

      expect(payload.fetch('conversation')).to include('id' => conversation.id, 'display_id' => conversation.display_id, 'inbox_id' => inbox.id)
      expect(payload.fetch('summary')).to include('total_messages' => 2, 'failed_outgoing_count' => 1)
      expect(payload.fetch('messages').last).to include('id' => failed.id, 'status' => 'failed', 'external_error' => 'provider timeout')
    end
  end

  describe Captain::Tools::Copilot::GetChannelHealthService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'summarizes per-inbox message and failure health without exposing secrets' do
      inbox = create(:inbox, account: account, name: 'Main WA')
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'incoming', status: 'sent')
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'outgoing', status: 'failed',
                       content_attributes: { external_error: '401 Unauthorized token=secret' })
      create(:inbox, account: other_account, name: 'Other account')

      payload = JSON.parse(service.execute(inbox_id: inbox.id, since: 2.hours.ago.iso8601))

      expect(payload.fetch('channels').size).to eq(1)
      expect(payload.fetch('channels').first).to include('inbox_id' => inbox.id, 'inbox_name' => 'Main WA', 'failed_outgoing_count' => 1,
                                                         'status' => 'degraded')
      expect(payload.fetch('channels').first.fetch('recent_failures').first.fetch('external_error')).to eq('[REDACTED]')
    end
  end
end
