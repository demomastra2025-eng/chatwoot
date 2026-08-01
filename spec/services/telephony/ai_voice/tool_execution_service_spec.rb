require 'rails_helper'

RSpec.describe Telephony::AiVoice::ToolExecutionService do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: voice_channel.inbox) }
  let(:number_binding) do
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    voice_channel.inbox.reload.telephony_number_binding
  end
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: voice_channel.inbox,
      number_binding: number_binding,
      external_call_ref: 'idempotent-tool-call',
      status: 'in_progress'
    )
  end
  let(:runtime_session_id) { 'runtime-tool-execution-1' }
  let(:runtime_engine) { 'pipecat' }

  def tool_capability(*tool_names, assistant_id: nil)
    Telephony::AiVoice::ToolCapability.issue(
      call_session: call_session,
      runtime_session_id: runtime_session_id,
      runtime_engine: runtime_engine,
      assistant_id: assistant_id,
      tools: tool_names.map { |name| { name: name } }
    )
  end

  def execution(arguments:, key: 'tool-call-1', capability: nil, assistant_id: nil)
    described_class.new(
      tool_name: 'create_note',
      payload: {
        account_id: account.id,
        call_session_id: call_session.id,
        call_ref: call_session.external_call_ref,
        conversation_id: conversation.id,
        inbox_id: voice_channel.inbox.id,
        assistant_id: assistant_id,
        runtime_session_id: runtime_session_id,
        runtime_engine: runtime_engine,
        tool_capability: capability || tool_capability('create_note', assistant_id: assistant_id),
        tool_call_id: key,
        arguments: arguments
      }
    )
  end

  it 'replays a processed result without repeating the mutation' do
    first_result = nil
    second_result = nil

    expect do
      first_result = execution(arguments: { content: 'One note' }).perform
      second_result = execution(arguments: { content: 'One note' }).perform
    end.to change { conversation.messages.where(private: true).count }.by(1)

    expect(second_result).to eq(first_result)
    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'processed', call_session_id: call_session.id)
    expect(event.payload).to include('phase' => 'completed', 'result_digest' => be_present, 'result_ciphertext' => be_present)
    expect(event.payload).not_to have_key('result')
    expect(event.payload.to_json).not_to include('One note')
  end

  it 'rejects reuse of the same key for different arguments' do
    execution(arguments: { content: 'Original note' }).perform

    expect do
      execution(arguments: { content: 'Different note' }).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_IDEMPOTENCY_CONFLICT') }

    expect(conversation.messages.where(private: true).count).to eq(1)
  end

  it 'suppresses a concurrent duplicate while the owner is still running' do
    service = execution(arguments: { content: 'Concurrent note' })
    account.telephony_events.create!(
      call_session: call_session,
      event_key: service.send(:event_key),
      event_type: described_class::EVENT_TYPE,
      status: 'received',
      payload: service.send(:event_payload, phase: 'executing')
    )

    expect do
      execution(arguments: { content: 'Concurrent note' }).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_EXECUTION_IN_PROGRESS') }

    expect(conversation.messages.where(private: true)).not_to exist
  end

  it 'records failures and does not automatically replay a possibly partial mutation' do
    expect do
      execution(arguments: { content: '' }).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('NOTE_CONTENT_REQUIRED') }

    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'failed', call_session_id: call_session.id)
    expect(event.error_message).to eq('NOTE_CONTENT_REQUIRED')
    expect(event.payload.to_json).not_to include('note content is required')

    expect do
      execution(arguments: { content: '' }).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_EXECUTION_PREVIOUSLY_FAILED') }
  end

  it 'marks a stale executing owner as outcome unknown without retrying the mutation' do
    service = execution(arguments: { content: 'Ambiguous note' })
    stale_payload = service.send(:event_payload, phase: 'executing').merge('lease_expires_at' => 1.minute.ago.iso8601)
    account.telephony_events.create!(
      call_session: call_session,
      event_key: service.send(:event_key),
      event_type: described_class::EVENT_TYPE,
      status: 'received',
      payload: stale_payload
    )

    expect do
      execution(arguments: { content: 'Ambiguous note' }).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_EXECUTION_OUTCOME_UNKNOWN') }

    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'failed', error_message: 'TOOL_EXECUTION_OUTCOME_UNKNOWN')
    expect(conversation.messages.where(private: true)).not_to exist
  end

  it 'reclaims a stale reservation that never entered dispatch' do
    service = execution(arguments: { content: 'Recovered reservation' })
    stale_payload = service.send(:event_payload, phase: 'reserved').merge('lease_expires_at' => 1.minute.ago.iso8601)
    account.telephony_events.create!(
      call_session: call_session,
      event_key: service.send(:event_key),
      event_type: described_class::EVENT_TYPE,
      status: 'received',
      payload: stale_payload
    )

    expect { execution(arguments: { content: 'Recovered reservation' }).perform }
      .to change { conversation.messages.where(private: true).count }.by(1)
  end

  it 'rejects a capability after the call is reassigned to another assistant' do
    previous_assistant = create(:captain_assistant, account: account)
    current_assistant = create(:captain_assistant, account: account)
    number_binding.routing_policy.update!(captain_assistant: previous_assistant)
    capability = tool_capability('create_note', assistant_id: previous_assistant.id)
    number_binding.routing_policy.update!(captain_assistant: current_assistant)

    expect do
      execution(
        arguments: { content: 'Must not be created' },
        capability: capability,
        assistant_id: previous_assistant.id
      ).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_CAPABILITY_SCOPE_MISMATCH') }

    expect(conversation.messages.where(private: true)).not_to exist
  end

  it 'rechecks assistant assignment after reservation immediately before dispatch' do
    previous_assistant = create(:captain_assistant, account: account)
    current_assistant = create(:captain_assistant, account: account)
    number_binding.routing_policy.update!(captain_assistant: previous_assistant)
    service = execution(arguments: { content: 'Must not be created' }, assistant_id: previous_assistant.id)

    allow(service).to receive(:mark_execution_started!).and_wrap_original do |original, event|
      original.call(event)
      number_binding.routing_policy.update!(captain_assistant: current_assistant)
    end

    expect { service.perform }
      .to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_CAPABILITY_SCOPE_MISMATCH') }

    expect(conversation.messages.where(private: true)).not_to exist
  end

  it 'rejects an assistant inserted after a routing-only capability was verified' do
    previous_assistant = create(:captain_assistant, account: account)
    current_assistant = create(:captain_assistant, account: account)
    number_binding.routing_policy.update!(captain_assistant: previous_assistant)
    service = execution(arguments: { content: 'Must not be created' }, assistant_id: previous_assistant.id)

    allow(service).to receive(:mark_execution_started!).and_wrap_original do |original, event|
      original.call(event)
      create(:captain_inbox, captain_assistant: current_assistant, inbox: voice_channel.inbox)
    end

    expect { service.perform }
      .to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_CAPABILITY_SCOPE_MISMATCH') }

    expect(conversation.messages.where(private: true)).not_to exist
  end

  it 'rejects a Captain inbox deleted and recreated after capability verification' do
    previous_assistant = create(:captain_assistant, account: account)
    current_assistant = create(:captain_assistant, account: account)
    captain_inbox = create(:captain_inbox, captain_assistant: previous_assistant, inbox: voice_channel.inbox)
    service = execution(arguments: { content: 'Must not be created' }, assistant_id: previous_assistant.id)

    allow(service).to receive(:mark_execution_started!).and_wrap_original do |original, event|
      original.call(event)
      captain_inbox.destroy!
      create(:captain_inbox, captain_assistant: current_assistant, inbox: voice_channel.inbox)
    end

    expect { service.perform }
      .to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_CAPABILITY_SCOPE_MISMATCH') }

    expect(conversation.messages.where(private: true)).not_to exist
  end

  it 'requires account scope, an idempotency key and a per-call capability' do
    base_payload = {
      account_id: account.id,
      call_session_id: call_session.id,
      call_ref: call_session.external_call_ref,
      conversation_id: conversation.id,
      inbox_id: voice_channel.inbox.id,
      runtime_session_id: runtime_session_id,
      runtime_engine: runtime_engine,
      tool_call_id: 'missing-capability',
      arguments: { content: 'Forbidden note' }
    }

    expect do
      described_class.new(tool_name: 'create_note', payload: base_payload).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_CAPABILITY_INVALID') }

    expect do
      described_class.new(tool_name: 'create_note', payload: base_payload.except(:account_id, :tool_call_id)).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('ACCOUNT_SCOPE_REQUIRED') }
  end
end
