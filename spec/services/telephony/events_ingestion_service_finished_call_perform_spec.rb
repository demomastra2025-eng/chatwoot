require 'rails_helper'

# An operator resolves a voice conversation right after the call; the call
# recording, the second recording event and a repeated session_completed of the
# SAME call arrive afterwards. They update the call data and nothing else: the
# conversation (and its communication thread) stay resolved. Only a NEW call
# (or a new incoming message) reopens it.
RSpec.describe Telephony::EventsIngestionService, '#perform' do
  let(:account) { create(:account) }
  let(:provider_name) { 'sipuni' }
  let(:voice_channel) do
    create(
      :channel_voice, :sipuni,
      account: account, phone_number: '+15551230000', provider: provider_name,
      provider_config: { number_ref: SecureRandom.uuid, provider_kind: provider_name, routing_mode: 'operator' }
    )
  end
  let(:voice_inbox) { voice_channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+15550001111') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: contact.phone_number) }
  let(:direction) { 'outbound' }
  let(:call_ref) { "#{voice_channel.provider}:local:late-events-call" }
  let(:started_at) { Time.zone.parse(10.minutes.ago.iso8601) }
  let(:answered_at) { started_at + 10.seconds }
  let(:ended_at) { answered_at + 110.seconds }
  let(:recording_ref) { 'voice-recordings/sipuni/1/late-events-call.mp3' }

  def ingest(event, status: nil, occurred_at: Time.current, ref: call_ref, **extra)
    described_class.new(
      payload: {
        event_key: "late-events-#{event}-#{SecureRandom.hex(4)}",
        account_id: account.id,
        provider: voice_channel.provider,
        call_ref: ref,
        event: event,
        status: status,
        direction: direction,
        inbox_id: voice_inbox.id,
        from_number: direction == 'inbound' ? contact.phone_number : voice_channel.phone_number,
        to_number: direction == 'inbound' ? voice_channel.phone_number : contact.phone_number,
        occurred_at: occurred_at.iso8601
      }.merge(extra).compact
    ).perform
  end

  def run_call_to_the_end
    ingest('session_started', status: 'ringing', occurred_at: started_at)
    ingest('call_status', status: 'answered', occurred_at: answered_at, answered_at: answered_at.iso8601, answered_by: 'provider')
    ingest('session_completed', status: 'completed', occurred_at: ended_at, ended_at: ended_at.iso8601,
                                ended_by: 'operator', end_reason: 'operator_hangup')
  end

  def call_conversation
    Telephony::CallSession.find_by!(external_call_ref: call_ref).conversation
  end

  def resolve_as_operator
    Conversations::StatusTransitionService.new(
      conversation: call_conversation,
      params: { status: 'resolved' },
      actor: create(:user, account: account, role: :agent),
      source: 'manual'
    ).perform
    expect(call_conversation).to be_resolved
  end

  def late_events_of_the_call
    ingest('recording_ready', recording_ref: recording_ref, storage_key: recording_ref, duration_seconds: 110,
                              content_type: 'audio/mpeg', occurred_at: ended_at + 30.seconds)
    ingest('recording_ready', recording_ref: recording_ref, storage_key: recording_ref, duration_seconds: 110,
                              content_type: 'audio/mpeg', occurred_at: ended_at + 54.seconds)
    ingest('session_completed', status: 'completed', occurred_at: ended_at, ended_at: ended_at.iso8601,
                                ended_by: 'operator', end_reason: 'operator_hangup')
  end

  def record_conversation_status_changes
    changes = []
    callback = ->(record) { changes << [record.id, record.status] if record.saved_change_to_status? }
    Conversation.after_save(&callback)
    yield
    changes
  ensure
    Conversation.skip_callback(:save, :after, &callback)
  end

  shared_examples 'a resolved conversation that stays resolved' do
    it 'keeps the conversation resolved while the recording and repeated terminal events arrive' do
      run_call_to_the_end
      resolve_as_operator

      late_events_of_the_call

      expect(call_conversation).to be_resolved
      expect(call_conversation.additional_attributes).to include('call_status' => 'completed')
      expect(call_conversation.additional_attributes['recording_ref']).to eq(recording_ref)
      expect(Telephony::CallSession.find_by!(external_call_ref: call_ref)).to have_attributes(status: 'completed', recording_ref: recording_ref)
    end

    it 'does not write a status change of the conversation' do
      run_call_to_the_end
      resolve_as_operator

      changes = record_conversation_status_changes { late_events_of_the_call }

      expect(changes).to be_empty
    end
  end

  # The state OutboundCallBuilder leaves behind for a call the operator started
  # from the chat: the call session is attached to the conversation, the
  # conversation carries the call reference and is open.
  shared_context 'with an outbound call started from the chat' do
    let(:conversation) do
      create(
        :conversation,
        account: account, inbox: voice_inbox, contact: contact, contact_inbox: contact_inbox, status: :open,
        additional_attributes: {
          'call_direction' => 'outbound', 'call_status' => 'ringing',
          'telephony_provider' => voice_channel.provider, 'telephony_call_ref' => call_ref
        }
      )
    end

    before do
      create(
        :telephony_call_session,
        account: account, conversation: conversation, inbox: voice_inbox, number_binding: voice_inbox.telephony_number_binding,
        provider: voice_channel.provider, external_call_ref: call_ref,
        direction: 'outbound', status: 'created', started_at: started_at, last_event_at: started_at,
        to_number: contact.phone_number
      )
    end
  end

  context 'with a classic conversation' do
    include_context 'with an outbound call started from the chat'

    it_behaves_like 'a resolved conversation that stays resolved'
  end

  context 'with communication threads' do
    include_context 'with an outbound call started from the chat'

    before { account.enable_features!('communication_threads') }

    it_behaves_like 'a resolved conversation that stays resolved'

    it 'keeps the communication thread resolved' do
      run_call_to_the_end
      resolve_as_operator
      thread = call_conversation.communication_thread
      expect(thread).to be_resolved

      late_events_of_the_call

      expect(call_conversation).to be_resolved
      expect(thread.reload).to be_resolved
    end
  end

  %w[beeline binotel asterisk_analog wazo].each do |native_provider|
    context "with a #{native_provider} call" do
      include_context 'with an outbound call started from the chat'

      let(:provider_name) { native_provider }

      it_behaves_like 'a resolved conversation that stays resolved'
    end
  end

  context 'with an incoming call whose conversation the provider events create' do
    let(:direction) { 'inbound' }

    it_behaves_like 'a resolved conversation that stays resolved'
  end

  context 'with a call answered by the AI voice agent' do
    let(:direction) { 'inbound' }

    it 'does not put the conversation back to pending after an operator took it over' do
      ingest('session_started', status: 'ringing', occurred_at: started_at, metadata: { route_action: 'ai' })
      expect(call_conversation).to be_pending
      call_conversation.update!(status: :open)

      ingest('call_status', status: 'answered', occurred_at: answered_at, answered_at: answered_at.iso8601, answered_by: 'provider',
                            metadata: { route_action: 'ai' })
      ingest('recording_ready', recording_ref: recording_ref, storage_key: recording_ref, occurred_at: ended_at,
                                metadata: { route_action: 'ai' })

      expect(call_conversation).to be_open
    end
  end

  context 'when a new call comes to the resolved conversation' do
    include_context 'with an outbound call started from the chat'

    it 'reopens it on the first event of the new call and not on its later events' do
      run_call_to_the_end
      resolve_as_operator

      # A call the routing attached to the existing conversation: the
      # conversation still carries the reference of the previous call.
      second_ref = "#{voice_channel.provider}:local:late-events-second-call"
      create(
        :telephony_call_session,
        account: account, conversation: call_conversation, inbox: voice_inbox, number_binding: voice_inbox.telephony_number_binding,
        provider: voice_channel.provider, external_call_ref: second_ref,
        direction: 'outbound', status: 'created', started_at: Time.current, to_number: contact.phone_number
      )

      ingest('session_started', status: 'ringing', ref: second_ref)
      expect(call_conversation).to be_open
      expect(call_conversation.additional_attributes).to include('telephony_call_ref' => second_ref, 'call_status' => 'ringing')

      resolve_as_operator
      ingest('call_status', status: 'answered', ref: second_ref, answered_at: Time.current.iso8601, answered_by: 'provider')
      expect(call_conversation).to be_resolved
    end
  end
end
