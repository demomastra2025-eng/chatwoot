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
  let(:contact_tool_assistant) do
    assistant = create(
      :captain_assistant,
      account: account,
      config: { tool_access: { agent: { enabled: true, tool_ids: ['get_contact'] } } }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: voice_channel.inbox)
    assistant
  end

  def tool_capability(*tool_names, assistant_id: nil)
    Telephony::AiVoice::ToolCapability.issue(
      call_session: call_session,
      runtime_session_id: runtime_session_id,
      runtime_engine: runtime_engine,
      assistant_id: assistant_id,
      tools: tool_names.map { |name| { name: name } }
    )
  end

  def execution(arguments:, key: 'tool-call-1', capability: nil, assistant_id: nil, tool_name: 'create_note')
    described_class.new(
      tool_name: tool_name,
      payload: {
        account_id: account.id,
        call_session_id: call_session.id,
        call_ref: call_session.external_call_ref,
        conversation_id: conversation.id,
        inbox_id: voice_channel.inbox.id,
        assistant_id: assistant_id,
        runtime_session_id: runtime_session_id,
        runtime_engine: runtime_engine,
        tool_capability: capability || tool_capability(tool_name, assistant_id: assistant_id),
        tool_call_id: key,
        arguments: arguments
      }
    )
  end

  # Keep transport/idempotency tests on a real permitted tool; create_note is
  # denied for customer AI even with a valid call-scoped capability.
  def current_contact_execution(arguments: nil)
    assistant_id = contact_tool_assistant.id
    execution(tool_name: 'get_contact', assistant_id: assistant_id,
              arguments: arguments || { contact_id: conversation.contact_id })
  end

  it 'replays a processed contact result without executing the tool twice' do
    first_result = nil
    second_result = nil

    expect do
      first_result = current_contact_execution.perform
      second_result = current_contact_execution.perform
    end.not_to(change { conversation.messages.where(private: true).count })

    expect(second_result).to eq(first_result)
    expect(JSON.parse(first_result.fetch('result')).dig('contact', 'id')).to eq(conversation.contact_id)
    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'processed', call_session_id: call_session.id)
    expect(event.payload).to include('phase' => 'completed', 'result_digest' => be_present, 'result_ciphertext' => be_present)
    expect(event.payload).not_to have_key('result')
    expect(event.payload.to_json).not_to include(conversation.contact.name)
  end

  it 'rejects reuse of the same key for different arguments' do
    current_contact_execution.perform

    expect do
      current_contact_execution(arguments: { contact_id: conversation.contact_id, unexpected: true }).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_IDEMPOTENCY_CONFLICT') }

    expect(account.telephony_events.where(event_type: described_class::EVENT_TYPE).count).to eq(1)
  end

  it 'persists a pre-effect customer scope denial and replays the same 403 without dispatch' do
    first = execution(arguments: { content: 'Never write this note' })
    duplicate = execution(arguments: { content: 'Never write this note' })
    expect(first.send(:dispatch_service)).not_to receive(:perform)
    expect(duplicate.send(:dispatch_service)).not_to receive(:perform)

    [first, duplicate].each do |service|
      expect { service.perform }.to raise_error(Telephony::Error) do |error|
        expect(error).to have_attributes(
          code: 'CUSTOMER_AI_TOOL_SCOPE_DENIED',
          status: :forbidden,
          message: Captain::CustomerToolExecutionScope::DENIED_MESSAGE
        )
      end
    end

    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'failed', error_message: 'CUSTOMER_AI_TOOL_SCOPE_DENIED')
    expect(event.payload).to include('phase' => 'scope_denied', 'error_code' => 'CUSTOMER_AI_TOOL_SCOPE_DENIED')
    expect(event.payload).not_to have_key('owner_token_hash')
  end

  it 'keeps a denied key fingerprint and does not write notes or tasks' do
    expect do
      execution(arguments: { content: 'Never write this note' }).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('CUSTOMER_AI_TOOL_SCOPE_DENIED') }

    expect do
      execution(arguments: { content: 'Different note' }).perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_IDEMPOTENCY_CONFLICT') }
    expect(conversation.messages.where(private: true)).not_to exist
    expect(Crm::Task.where(account_id: account.id)).not_to exist
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

  it 'records dispatch exceptions as outcome unknown without retrying' do
    service = current_contact_execution
    allow(service.send(:dispatch_service)).to receive(:perform).and_raise(
      Telephony::Error.new(code: 'DISPATCH_TEST_ERROR', message: 'synthetic dispatch failure')
    )
    expect do
      service.perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('DISPATCH_TEST_ERROR') }

    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'failed', call_session_id: call_session.id)
    expect(event.error_message).to eq('TOOL_EXECUTION_OUTCOME_UNKNOWN')
    expect(event.payload.to_json).not_to include('synthetic dispatch failure')

    expect do
      current_contact_execution.perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_EXECUTION_OUTCOME_UNKNOWN') }
  end

  it 'returns and replays typed non-retryable Captain business failures while marking the event failed' do
    service = current_contact_execution
    dispatch_service = service.send(:dispatch_service)
    business_failure = {
      action: 'captain_tool',
      tool_name: 'get_contact',
      status: 'failed',
      error: 'captain_tool_business_failed',
      code: 'CAPTAIN_TOOL_BUSINESS_FAILED',
      retryable: false,
      message: 'Target is ambiguous'
    }
    allow(dispatch_service).to receive(:perform).and_return(business_failure)

    first_result = service.perform
    replayed_result = current_contact_execution.perform

    expect(first_result).to eq(business_failure.deep_stringify_keys)
    expect(replayed_result).to eq(first_result)
    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'failed', error_message: 'CAPTAIN_TOOL_BUSINESS_FAILED')
    expect(event.payload).to include('phase' => 'business_failed', 'result_ciphertext' => be_present)
  end

  it 'recognizes symbol-keyed typed business failures before persistence' do
    result = { status: 'failed', error: 'captain_tool_business_failed' }

    expect(execution(arguments: {}).send(:business_failure_result?, result)).to be(true)
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

  it 'marks a lost acknowledgement after dispatch as outcome unknown without repeating the mutation' do
    service = current_contact_execution
    dispatch_service = service.send(:dispatch_service)
    allow(dispatch_service).to receive(:perform).and_wrap_original do |original|
      original.call
      raise Timeout::Error, 'provider acknowledgement timed out'
    end

    expect { service.perform }.to raise_error(Timeout::Error)

    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'failed', error_message: 'TOOL_EXECUTION_OUTCOME_UNKNOWN')
    expect(event.payload).to include(
      'phase' => 'outcome_unknown',
      'error_code' => 'TOOL_EXECUTION_OUTCOME_UNKNOWN',
      'dispatch_error_class' => 'Timeout::Error'
    )

    expect do
      current_contact_execution.perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_EXECUTION_OUTCOME_UNKNOWN') }
    expect(conversation.messages.where(private: true)).not_to exist
    expect(dispatch_service).to have_received(:perform).once
  end

  it 'marks post-dispatch argument errors as outcome unknown without repeating the mutation' do
    service = current_contact_execution
    dispatch_service = service.send(:dispatch_service)
    allow(dispatch_service).to receive(:perform).and_wrap_original do |original|
      original.call
      raise ArgumentError, 'invalid acknowledgement shape'
    end

    expect { service.perform }.to raise_error(ArgumentError)

    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'failed', error_message: 'TOOL_EXECUTION_OUTCOME_UNKNOWN')
    expect(event.payload).to include(
      'phase' => 'outcome_unknown',
      'error_code' => 'TOOL_EXECUTION_OUTCOME_UNKNOWN',
      'dispatch_error_class' => 'ArgumentError'
    )

    expect do
      current_contact_execution.perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_EXECUTION_OUTCOME_UNKNOWN') }
    expect(dispatch_service).to have_received(:perform).once
  end

  it 'does not trust a post-dispatch scope denial code as proof of no effect' do
    service = current_contact_execution
    dispatch_service = service.send(:dispatch_service)
    allow(dispatch_service).to receive(:perform).and_wrap_original do |original|
      original.call
      raise Telephony::Error.new(code: 'CUSTOMER_AI_TOOL_SCOPE_DENIED', message: 'late denial', status: :forbidden)
    end

    expect { service.perform }.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('CUSTOMER_AI_TOOL_SCOPE_DENIED') }

    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'failed', error_message: 'TOOL_EXECUTION_OUTCOME_UNKNOWN')
    expect(event.payload).to include(
      'phase' => 'outcome_unknown',
      'error_code' => 'TOOL_EXECUTION_OUTCOME_UNKNOWN',
      'dispatch_error_class' => 'Telephony::Error'
    )

    expect do
      current_contact_execution.perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_EXECUTION_OUTCOME_UNKNOWN') }
    expect(dispatch_service).to have_received(:perform).once
  end

  it 'marks post-dispatch unknown-tool errors as outcome unknown without repeating the mutation' do
    service = current_contact_execution
    dispatch_service = service.send(:dispatch_service)
    allow(dispatch_service).to receive(:perform).and_wrap_original do |original|
      original.call
      raise Telephony::AiVoice::ToolDispatchService::UnknownToolError, 'invalid tool acknowledgement'
    end

    expect { service.perform }.to raise_error(Telephony::AiVoice::ToolDispatchService::UnknownToolError)

    event = account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)
    expect(event).to have_attributes(status: 'failed', error_message: 'TOOL_EXECUTION_OUTCOME_UNKNOWN')
    expect(event.payload).to include(
      'phase' => 'outcome_unknown',
      'error_code' => 'TOOL_EXECUTION_OUTCOME_UNKNOWN',
      'dispatch_error_class' => 'Telephony::AiVoice::ToolDispatchService::UnknownToolError'
    )

    expect do
      current_contact_execution.perform
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_EXECUTION_OUTCOME_UNKNOWN') }
    expect(dispatch_service).to have_received(:perform).once
  end

  it 'reclaims a stale reservation that never entered dispatch' do
    service = current_contact_execution
    stale_payload = service.send(:event_payload, phase: 'reserved').merge('lease_expires_at' => 1.minute.ago.iso8601)
    account.telephony_events.create!(
      call_session: call_session,
      event_key: service.send(:event_key),
      event_type: described_class::EVENT_TYPE,
      status: 'received',
      payload: stale_payload
    )

    expect(JSON.parse(current_contact_execution.perform.fetch('result')).dig('contact', 'id')).to eq(conversation.contact_id)
    expect(account.telephony_events.find_by!(event_type: described_class::EVENT_TYPE)).to have_attributes(status: 'processed')
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

  it 'holds the assistant assignment fence without retaining a transaction during the tool body' do
    service = current_contact_execution
    dispatch_service = service.send(:dispatch_service)
    baseline_transactions = ActiveRecord::Base.connection.open_transactions
    assignment_fenced = false

    allow(Telephony::AiVoice::AssistantAssignmentLock).to receive(:with_lock!).and_wrap_original do |original, *args, &block|
      original.call(*args) do
        assignment_fenced = true
        block.call
      ensure
        assignment_fenced = false
      end
    end

    allow(dispatch_service).to receive(:perform).and_wrap_original do |original|
      expect(assignment_fenced).to be(true)
      expect(ActiveRecord::Base.connection.open_transactions).to eq(baseline_transactions)
      original.call
    end

    expect(JSON.parse(service.perform.fetch('result')).dig('contact', 'id')).to eq(conversation.contact_id)
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
