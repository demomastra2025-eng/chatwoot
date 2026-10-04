# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::AiVoice::ToolExecutionService do
  self.use_transactional_tests = false

  after { CommittedRowsCleanup.truncate! }

  it 'commits an actual Captain conversation mutation before a result normalization failure' do
    channel = create(:channel_voice, :sipuni)
    account = channel.account
    account.enable_features!('captain_integration')
    inbox = channel.inbox
    conversation = create(:conversation, account: account, inbox: inbox, priority: 'low')
    assistant = create(
      :captain_assistant,
      account: account,
      config: {
        'tool_access' => {
          'agent' => { 'enabled' => true, 'tool_ids' => ['update_priority'] }
        }
      }
    )
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    Telephony::NumberBinding.sync_from_voice_channel!(channel)
    call_session = create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: inbox,
      number_binding: inbox.reload.telephony_number_binding,
      external_call_ref: 'captain-mutation-normalization-boundary',
      status: 'in_progress'
    )
    capability = Telephony::AiVoice::ToolCapability.issue(
      call_session: call_session,
      runtime_session_id: 'captain-mutation-normalization-runtime',
      runtime_engine: 'pipecat',
      assistant_id: assistant.id,
      tools: [{ name: 'update_priority' }]
    )
    service = described_class.new(
      tool_name: 'update_priority',
      payload: {
        account_id: account.id,
        call_session_id: call_session.id,
        call_ref: call_session.external_call_ref,
        conversation_id: conversation.id,
        inbox_id: inbox.id,
        assistant_id: assistant.id,
        runtime_session_id: 'captain-mutation-normalization-runtime',
        runtime_engine: 'pipecat',
        tool_capability: capability,
        tool_call_id: 'captain-mutation-normalization-key',
        arguments: { priority: 'high' }
      }
    )
    allow(service).to receive(:normalize_result).and_raise(ArgumentError, 'invalid result envelope')

    expect { service.perform }.to raise_error(ArgumentError, 'invalid result envelope')
    expect(conversation.reload.priority).to eq('high')
    expect(account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE))
      .to have_attributes(status: 'failed', error_message: 'TOOL_EXECUTION_OUTCOME_UNKNOWN')

    replay = described_class.new(
      tool_name: 'update_priority',
      payload: {
        account_id: account.id,
        call_session_id: call_session.id,
        call_ref: call_session.external_call_ref,
        conversation_id: conversation.id,
        inbox_id: inbox.id,
        assistant_id: assistant.id,
        runtime_session_id: 'captain-mutation-normalization-runtime',
        runtime_engine: 'pipecat',
        tool_capability: capability,
        tool_call_id: 'captain-mutation-normalization-key',
        arguments: { priority: 'high' }
      }
    )
    expect do
      replay.perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_EXECUTION_OUTCOME_UNKNOWN') }
    expect(conversation.reload.priority).to eq('high')
  end
end
