require 'rails_helper'

RSpec.describe Telephony::TerminalNativeSipHandoffService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:number_binding) { create(:telephony_number_binding, account: account, inbox: inbox) }
  let(:current_created_at) { Time.zone.parse('2026-07-20 18:06:56.700 UTC') }
  let(:runtime_identity) do
    {
      'telephony_sip_profile_id' => 70,
      'registration_instance_id' => 'registration-instance-1',
      'janus_session_id' => 'janus-session-1',
      'janus_handle_id' => 'janus-handle-1'
    }
  end

  # rubocop:disable Metrics/MethodLength
  def create_session(call_ref:, logical_key:, created_at:, **overrides)
    identity = overrides.delete(:identity) || runtime_identity
    group_ref = overrides.delete(:group_ref) || call_ref
    attributes = {
      status: 'no_answer',
      answered_at: nil,
      ended_at: created_at + 10.seconds,
      end_reason: 'remote_hangup',
      from_number: '+770****7060'
    }.merge(overrides)

    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: inbox,
      number_binding: number_binding,
      provider: 'binotel',
      direction: 'inbound',
      external_call_ref: call_ref,
      started_at: created_at,
      to_number: '+770****1744',
      created_at: created_at,
      **attributes,
      metadata: {
        'metadata' => runtime_identity.merge(identity).merge(
          'logical_call_key' => logical_key,
          'call_group_key' => logical_key,
          'logical_call_group_ref' => group_ref,
          'route_reason' => group_ref == call_ref ? 'operator_route' : 'duplicate_broadcast_branch'
        )
      }
    )
  end
  # rubocop:enable Metrics/MethodLength

  def create_voice_message(session)
    create(
      :message,
      account: account,
      conversation: conversation,
      inbox: inbox,
      content_type: 'voice_call',
      source_id: session.voice_call_source_id,
      created_at: session.created_at,
      content_attributes: {
        'data' => {
          'provider' => session.provider,
          'call_sid' => session.external_call_ref,
          'call_direction' => session.direction,
          'status' => session.status,
          'logical_call_key' => session.logical_call_key
        }
      }
    )
  end

  it 'collapses a rapid terminal provider handoff in history without reusing its live logical key' do
    previous = create_session(
      call_ref: 'binotel:janus:70:previous',
      logical_key: 'janus-inbound:previous',
      created_at: current_created_at - 18.seconds,
      ended_at: current_created_at - 0.5.seconds
    )
    current = create_session(
      call_ref: 'binotel:janus:70:current',
      logical_key: 'janus-inbound:current',
      created_at: current_created_at,
      end_reason: 'native_sip_missing_operator_no_answer'
    )
    duplicate = create_session(
      call_ref: 'binotel:janus:70:duplicate',
      logical_key: current.logical_call_key,
      group_ref: current.external_call_ref,
      created_at: current_created_at + 1.second
    )
    previous_message = create_voice_message(previous)
    current_message = create_voice_message(current)

    described_class.new(call_session: current).perform

    expect([previous.reload.logical_call_key, current.reload.logical_call_key]).to eq(
      ['janus-inbound:previous', 'janus-inbound:current']
    )
    expect(previous.logical_history_group_ref).to eq(previous.external_call_ref)
    expect(current.logical_history_group_ref).to eq(previous.external_call_ref)
    expect(duplicate.reload.logical_history_group_ref).to eq(previous.external_call_ref)
    expect(current.logical_history_key).to eq(previous.logical_history_key)
    history = Telephony::LogicalCallHistoryQuery.new(
      relation: account.telephony_call_sessions.where(id: [previous.id, current.id, duplicate.id]),
      limit: 10
    ).call
    expect(history.map(&:id)).to eq([current.id])
    expect(Message.where(id: [previous_message.id, current_message.id]).pluck(:id)).to eq([current_message.id])
  end

  it 'preserves a rapid parallel call on a different Janus runtime identity' do
    previous = create_session(
      call_ref: 'binotel:janus:70:previous-runtime',
      logical_key: 'janus-inbound:previous-runtime',
      created_at: current_created_at - 18.seconds,
      ended_at: current_created_at - 0.5.seconds
    )
    current = create_session(
      call_ref: 'binotel:janus:71:parallel-runtime',
      logical_key: 'janus-inbound:parallel-runtime',
      created_at: current_created_at,
      identity: runtime_identity.merge(
        'telephony_sip_profile_id' => 71,
        'registration_instance_id' => 'registration-instance-2',
        'janus_session_id' => 'janus-session-2',
        'janus_handle_id' => 'janus-handle-2'
      )
    )
    messages = [create_voice_message(previous), create_voice_message(current)]

    described_class.new(call_session: current).perform

    expect(previous.reload.logical_history_group_ref).to be_nil
    expect(current.reload.logical_history_group_ref).to be_nil
    expect(Message.where(id: messages.map(&:id)).count).to eq(2)
  end

  it 'preserves an immediate call from a different caller on the same Janus runtime' do
    previous = create_session(
      call_ref: 'binotel:janus:70:first-caller',
      logical_key: 'janus-inbound:first-caller',
      created_at: current_created_at - 18.seconds,
      ended_at: current_created_at - 0.5.seconds
    )
    current = create_session(
      call_ref: 'binotel:janus:70:second-caller',
      logical_key: 'janus-inbound:second-caller',
      created_at: current_created_at,
      from_number: '+770****0001'
    )
    messages = [create_voice_message(previous), create_voice_message(current)]

    described_class.new(call_session: current).perform

    expect(previous.reload.logical_history_group_ref).to be_nil
    expect(current.reload.logical_history_group_ref).to be_nil
    expect(Message.where(id: messages.map(&:id)).count).to eq(2)
  end

  it 'does not collapse history while a parallel branch remains active' do
    previous = create_session(
      call_ref: 'binotel:janus:70:previous-active-group',
      logical_key: 'janus-inbound:previous-active-group',
      created_at: current_created_at - 18.seconds,
      ended_at: current_created_at - 0.5.seconds
    )
    current = create_session(
      call_ref: 'binotel:janus:70:current-active-group',
      logical_key: 'janus-inbound:current-active-group',
      created_at: current_created_at
    )
    active_branch = create_session(
      call_ref: 'binotel:janus:70:active-branch',
      logical_key: current.logical_call_key,
      group_ref: current.external_call_ref,
      created_at: current_created_at + 1.second,
      status: 'ringing',
      ended_at: nil,
      end_reason: nil
    )
    messages = [create_voice_message(previous), create_voice_message(current)]

    described_class.new(call_session: current).perform

    expect(current.reload.logical_history_group_ref).to be_nil
    expect(active_branch.reload.status).to eq('ringing')
    expect(Message.where(id: messages.map(&:id)).count).to eq(2)
  end

  it 'preserves a same-runtime redial outside the handoff window' do
    previous = create_session(
      call_ref: 'binotel:janus:70:previous-redial',
      logical_key: 'janus-inbound:previous-redial',
      created_at: current_created_at - 18.seconds,
      ended_at: current_created_at - 3.seconds
    )
    current = create_session(
      call_ref: 'binotel:janus:70:current-redial',
      logical_key: 'janus-inbound:current-redial',
      created_at: current_created_at
    )
    messages = [create_voice_message(previous), create_voice_message(current)]

    described_class.new(call_session: current).perform

    expect(previous.reload.logical_history_group_ref).to be_nil
    expect(current.reload.logical_history_group_ref).to be_nil
    expect(Message.where(id: messages.map(&:id)).count).to eq(2)
  end

  it 'preserves metadata written after the session object was loaded' do
    session = create_session(
      call_ref: 'binotel:janus:70:stale-object',
      logical_key: 'janus-inbound:stale-object',
      created_at: current_created_at
    )
    service = described_class.new(call_session: session)
    recording = { 'storage_key' => 'voice-recordings/janus/final.wav', 'recorded_by' => 'janus' }
    fresh_session = Telephony::CallSession.find(session.id)
    fresh_session.update!(metadata: session.metadata.deep_merge('recording' => recording))

    service.send(:persist_history_group!, [session], 'history-group-ref')

    expect(session.reload.metadata).to include(
      'recording' => recording,
      'history_handoff' => include('group_ref' => 'history-group-ref')
    )
  end

  it 'does not collapse a runtime group spanning different conversations' do
    other_conversation = create(:conversation, account: account, inbox: inbox, contact: conversation.contact)
    previous = create_session(
      call_ref: 'binotel:janus:70:previous-conversation-scope',
      logical_key: 'janus-inbound:previous-conversation-scope',
      created_at: current_created_at - 18.seconds,
      ended_at: current_created_at - 0.5.seconds
    )
    current = create_session(
      call_ref: 'binotel:janus:70:current-conversation-scope',
      logical_key: 'janus-inbound:current-conversation-scope',
      created_at: current_created_at
    )
    create_session(
      call_ref: 'binotel:janus:70:cross-conversation-branch',
      logical_key: current.logical_call_key,
      group_ref: current.external_call_ref,
      conversation: other_conversation,
      contact: other_conversation.contact,
      created_at: current_created_at + 1.second
    )
    messages = [create_voice_message(previous), create_voice_message(current)]

    described_class.new(call_session: current).perform

    expect(current.reload.logical_history_group_ref).to be_nil
    expect(Message.where(id: messages.map(&:id)).count).to eq(2)
  end
end
