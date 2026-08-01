require 'rails_helper'

RSpec.describe Telephony::AiVoice::ToolCapability do
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
      external_call_ref: 'capability-call-1',
      status: 'in_progress'
    )
  end
  let(:runtime_session_id) { 'runtime-capability-1' }
  let(:runtime_engine) { 'pipecat' }
  let(:tools) { [{ name: 'create_note' }, { name: 'find_contact' }] }

  def issue_capability
    described_class.issue(
      call_session: call_session,
      runtime_session_id: runtime_session_id,
      runtime_engine: runtime_engine,
      assistant_id: nil,
      tools: tools
    )
  end

  def scoped_payload(overrides = {})
    {
      'account_id' => account.id,
      'call_session_id' => call_session.id,
      'call_ref' => call_session.external_call_ref,
      'conversation_id' => conversation.id,
      'inbox_id' => voice_channel.inbox.id,
      'assistant_id' => nil,
      'runtime_session_id' => runtime_session_id,
      'runtime_engine' => runtime_engine
    }.merge(overrides.stringify_keys)
  end

  it 'binds an allowed tool to the exact tenant, call and runtime generation' do
    token = issue_capability

    capability = described_class.verify!(
      token: token,
      call_session: call_session,
      assistant_id: nil,
      tool_name: 'create_note',
      payload: scoped_payload
    )

    expect(capability).to include(
      'account_id' => account.id,
      'call_session_id' => call_session.id,
      'runtime_session_id' => runtime_session_id,
      'runtime_engine' => runtime_engine
    )
    expect(capability['tool_names']).to eq(%w[create_note find_contact])
    expect(call_session.reload.metadata.dig('runtime_lease', 'generation')).to be_present
  end

  it 'rejects a different account, session, conversation, inbox or runtime identity' do
    token = issue_capability

    %w[account_id call_session_id conversation_id inbox_id assistant_id runtime_session_id runtime_engine].each do |field|
      expect do
        described_class.verify!(
          token: token,
          call_session: call_session,
          assistant_id: nil,
          tool_name: 'create_note',
          payload: scoped_payload(field => 'forged')
        )
      end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_CAPABILITY_SCOPE_MISMATCH') }
    end
  end

  it 'rejects tools outside the context catalog' do
    token = issue_capability

    expect do
      described_class.verify!(token: token, call_session: call_session, assistant_id: nil, tool_name: 'delete_account', payload: scoped_payload)
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_NOT_ALLOWED_FOR_RUNTIME') }
  end

  it 'rejects a tampered or missing token' do
    [nil, "#{issue_capability}tampered"].each do |token|
      expect do
        described_class.verify!(token: token, call_session: call_session, assistant_id: nil, tool_name: 'create_note', payload: scoped_payload)
      end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_CAPABILITY_INVALID') }
    end
  end

  it 'rejects a capability after the runtime lease generation changes' do
    token = issue_capability
    metadata = call_session.reload.metadata.deep_dup
    metadata['runtime_lease']['generation'] = 'replacement-generation'
    call_session.update_columns(metadata: metadata) # rubocop:disable Rails/SkipsModelValidations

    expect do
      described_class.verify!(token: token, call_session: call_session, assistant_id: nil, tool_name: 'create_note', payload: scoped_payload)
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('RUNTIME_LEASE_CONFLICT') }
  end

  it 'rejects capability issuance for a competing runtime' do
    issue_capability

    expect do
      described_class.issue(
        call_session: call_session,
        runtime_session_id: 'competing-runtime',
        runtime_engine: runtime_engine,
        assistant_id: nil,
        tools: tools
      )
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('RUNTIME_LEASE_CONFLICT') }
  end

  it 'rejects capability issuance for a terminal call' do
    call_session.update!(status: 'completed', ended_at: Time.current)

    expect { issue_capability }
      .to raise_error(Telephony::Error) { |error| expect(error.code).to eq('CALL_SESSION_TERMINAL') }
  end

  it 'keeps the runtime generation across heartbeat renewal' do
    token = issue_capability
    generation = call_session.reload.metadata.dig('runtime_lease', 'generation')

    Telephony::AiVoice::HeartbeatService.new(payload: scoped_payload).perform

    expect(call_session.reload.metadata.dig('runtime_lease', 'generation')).to eq(generation)
    expect do
      described_class.verify!(
        token: token,
        call_session: call_session,
        assistant_id: nil,
        tool_name: 'create_note',
        payload: scoped_payload
      )
    end.not_to raise_error
  end

  it 'rejects a capability issued for a previous assistant assignment' do
    token = described_class.issue(
      call_session: call_session,
      runtime_session_id: runtime_session_id,
      runtime_engine: runtime_engine,
      assistant_id: 42,
      tools: tools
    )

    expect do
      described_class.verify!(
        token: token,
        call_session: call_session,
        assistant_id: 43,
        tool_name: 'create_note',
        payload: scoped_payload('assistant_id' => 42)
      )
    end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TOOL_CAPABILITY_SCOPE_MISMATCH') }
  end
end
