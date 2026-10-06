require 'rails_helper'

RSpec.describe Telephony::SiblingLegCloser do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:number_binding) { create(:telephony_number_binding, account: account, inbox: inbox) }
  let(:winner_user) { create(:user, account: account, role: :agent) }
  let(:second_user) { create(:user, account: account, role: :agent) }
  let(:third_user) { create(:user, account: account, role: :agent) }
  let(:group_key) { 'janus-inbound:one-physical-call' }
  let(:root_ref) { 'beeline:janus:101:call-id-a@sbc.example.test' }
  let!(:winner_leg) { create_leg(root_ref, winner_user, status: 'in_progress') }
  let!(:second_leg) { create_leg('beeline:janus:102:call-id-b@sbc.example.test', second_user) }
  let!(:third_leg) { create_leg('beeline:janus:103:call-id-c@sbc.example.test', third_user) }

  def leg_metadata(user, key, group_ref, claimed)
    route = { 'route_action' => 'operator', 'logical_call_key' => key, 'call_group_key' => key,
              'logical_call_group_ref' => group_ref, 'target_user_id' => user.id, 'operator_candidate_user_ids' => [user.id] }
    metadata = { 'metadata' => route }
    metadata['operator_claim'] = { 'user_id' => user.id, 'user_name' => user.name } if claimed
    metadata
  end

  def create_leg(ref, user, status: 'ringing', key: group_key, group_ref: root_ref)
    claimed = status == 'in_progress'
    create(
      :telephony_call_session,
      account: account, conversation: conversation, contact: conversation.contact, inbox: inbox,
      number_binding: number_binding, provider: 'beeline', direction: 'inbound', status: status,
      external_call_ref: ref, from_number: '+70000000001', to_number: '+70000000099',
      answered_at: (Time.current if status == 'in_progress'), answered_by: ("user:#{user.id}" if claimed),
      metadata: leg_metadata(user, key, group_ref, claimed)
    )
  end

  describe '#perform' do
    it 'closes every other open leg of the call as unanswered by this operator' do
      closed = described_class.new(call_session: winner_leg).perform

      expect(closed).to contain_exactly(second_leg, third_leg)
      [second_leg, third_leg].each do |leg|
        expect(leg.reload).to have_attributes(status: 'no_answer', end_reason: 'answered_by_other_operator', ended_by: 'system')
        expect(leg.ended_at).to be_present
      end
    end

    it 'never touches the answered leg' do
      winner_leg.update!(recording_ref: 'recording-1', transcript_ref: 'transcript-1', summary: 'Summary', duration_seconds: 12)

      described_class.new(call_session: winner_leg).perform

      expect(winner_leg.reload).to have_attributes(
        status: 'in_progress', end_reason: nil, ended_at: nil, answered_by: "user:#{winner_user.id}",
        recording_ref: 'recording-1', transcript_ref: 'transcript-1', summary: 'Summary', duration_seconds: 12
      )
    end

    it 'does not leave a missed call message for a closed leg' do
      described_class.new(call_session: winner_leg).perform

      leg_messages = conversation.messages.voice_calls.where(source_id: [second_leg, third_leg].map(&:voice_call_source_id))
      expect(leg_messages).to be_empty
    end

    it 'tells the operator of each closed leg that the call is gone, and nobody else' do
      allow(ActionCable.server).to receive(:broadcast)

      described_class.new(call_session: winner_leg).perform

      [[second_user, second_leg], [third_user, third_leg]].each do |user, leg|
        expect(ActionCable.server).to have_received(:broadcast).with(
          user.pubsub_token,
          hash_including(event: 'voice_call.status_changed', data: hash_including(callSid: leg.external_call_ref, status: 'no_answer'))
        )
        # The winner's card is the call he answers: a closed sibling is no news for him.
        expect(ActionCable.server).not_to have_received(:broadcast).with(
          winner_user.pubsub_token,
          hash_including(event: 'voice_call.status_changed', data: hash_including(callSid: leg.external_call_ref))
        )
        expect(ActionCable.server).to have_received(:broadcast).with(
          user.pubsub_token,
          hash_including(
            event: 'voice_call.claimed',
            data: hash_including(
              call_sid: leg.external_call_ref, claimed_by_user_id: winner_user.id, logical_call_key: group_key,
              related_call_sids: include(root_ref, second_leg.external_call_ref, third_leg.external_call_ref)
            )
          )
        )
      end
      expect(ActionCable.server).not_to have_received(:broadcast).with(winner_user.pubsub_token, hash_including(event: 'voice_call.claimed'))
    end

    it 'changes nothing when it runs again' do
      described_class.new(call_session: winner_leg).perform
      allow(ActionCable.server).to receive(:broadcast)

      expect { expect(described_class.new(call_session: winner_leg.reload).perform).to eq([]) }
        .not_to(change { [account.telephony_events.count, second_leg.reload.updated_at, third_leg.reload.updated_at] })
      expect(ActionCable.server).not_to have_received(:broadcast)
    end

    it 'leaves the siblings alone when the answered leg later completes' do
      described_class.new(call_session: winner_leg).perform
      winner_leg.update!(status: 'completed', ended_at: Time.current)

      expect(described_class.new(call_session: winner_leg).perform).to eq([])
      expect(second_leg.reload).to have_attributes(status: 'no_answer', end_reason: 'answered_by_other_operator')
    end

    it 'does nothing before an operator took the call' do
      winner_leg.update!(status: 'ringing')

      expect(described_class.new(call_session: winner_leg).perform).to eq([])
      expect([second_leg, third_leg].map { |leg| leg.reload.status }).to all(eq('ringing'))
    end

    it 'does not change the behaviour of other providers' do
      [winner_leg, second_leg, third_leg].each { |leg| leg.update!(provider: 'sipuni') }

      expect(described_class.new(call_session: winner_leg).perform).to eq([])
      expect(second_leg.reload.status).to eq('ringing')
    end

    it 'leaves a leg of another call of the same client alone' do
      other_ref = 'beeline:janus:104:call-id-d@sbc.example.test'
      other_call = create_leg(other_ref, third_user, key: 'janus-inbound:other-call', group_ref: other_ref)

      described_class.new(call_session: winner_leg).perform

      expect(other_call.reload.status).to eq('ringing')
    end

    it 'leaves a leg that was answered itself alone' do
      second_leg.update!(status: 'in_progress', answered_at: Time.current)

      closed = described_class.new(call_session: winner_leg).perform

      expect(closed).to eq([third_leg])
      expect(second_leg.reload.status).to eq('in_progress')
    end

    it 'takes the intake lock of the caller before it looks for open legs' do
      allow(Telephony::CallIntakeLock).to receive(:with_lock).and_call_original

      described_class.new(call_session: winner_leg).perform

      expect(Telephony::CallIntakeLock).to have_received(:with_lock).with(account_id: account.id, phone_number: '+70000000001')
    end

    it 'keeps going when one leg cannot be closed' do
      allow(Telephony::EventsIngestionService).to receive(:new).and_wrap_original do |original, payload:|
        raise StandardError, 'simulated failure' if payload[:call_ref] == second_leg.external_call_ref

        original.call(payload: payload)
      end

      closed = described_class.new(call_session: winner_leg).perform

      expect(closed).to eq([third_leg])
      expect(second_leg.reload.status).to eq('ringing')
    end
  end

  describe '.close_late_leg' do
    before { allow(ActionCable.server).to receive(:broadcast) }

    it 'closes a leg that was reported after another operator took the call' do
      expect(described_class.close_late_leg(second_leg)).to have_attributes(status: 'no_answer', end_reason: 'answered_by_other_operator')

      expect(winner_leg.reload).to have_attributes(status: 'in_progress', end_reason: nil)
    end

    it 'tells the operator of the late leg that the call was taken' do
      described_class.close_late_leg(second_leg)

      expect(ActionCable.server).to have_received(:broadcast).with(
        second_user.pubsub_token,
        hash_including(event: 'voice_call.claimed', data: hash_including(call_sid: second_leg.external_call_ref, claimed_by_user_id: winner_user.id))
      )
    end

    it 'closes a leg the claim moved to connecting as well' do
      winner_leg.update!(status: 'connecting', answered_at: nil)

      expect(described_class.close_late_leg(second_leg).status).to eq('no_answer')
    end

    it 'changes nothing when nobody owns the call yet' do
      winner_leg.update!(status: 'ringing')

      expect(described_class.close_late_leg(second_leg).status).to eq('ringing')
    end

    it 'changes nothing when the leg that owned the call is over' do
      winner_leg.update!(status: 'completed', ended_at: Time.current)

      expect(described_class.close_late_leg(second_leg).status).to eq('ringing')
    end

    it 'never closes the leg of the owner itself' do
      expect(described_class.close_late_leg(winner_leg).status).to eq('in_progress')
    end

    context 'when the late leg belongs to the operator who took the call' do
      let!(:claimer_leg) { create_leg('beeline:janus:104:call-id-d@sbc.example.test', winner_user) }

      it 'keeps it open next to a leg that carries his answer' do
        expect(described_class.close_late_leg(claimer_leg).status).to eq('ringing')
      end

      it 'keeps it open when the owner found is the claim fence, a leg of another operator with a copy of the claim' do
        winner_leg.update!(status: 'ringing', answered_at: nil, answered_by: nil, metadata: leg_metadata(winner_user, group_key, root_ref, false))
        second_leg.update!(status: 'connecting', answered_by: "user:#{winner_user.id}",
                           metadata: leg_metadata(second_user, group_key, root_ref, false).merge('operator_claim' => { 'user_id' => winner_user.id }))

        expect(described_class.close_late_leg(claimer_leg).status).to eq('ringing')
        expect(described_class.close_late_leg(third_leg).status).to eq('no_answer')
      end

      it 'finds the operator through the SIP profile when the report carries no user id' do
        profile = create(:telephony_sip_profile, account: account, inbox: inbox, user: winner_user)
        route = claimer_leg.metadata['metadata'].except('target_user_id').merge('telephony_sip_profile_id' => profile.id)
        claimer_leg.update!(metadata: claimer_leg.metadata.merge('metadata' => route))

        expect(described_class.close_late_leg(claimer_leg).status).to eq('ringing')
      end
    end

    it 'does not reopen or touch a leg that is over' do
      second_leg.update!(status: 'no_answer', ended_at: Time.current, end_reason: 'caller_hangup')

      expect(described_class.close_late_leg(second_leg)).to have_attributes(status: 'no_answer', end_reason: 'caller_hangup')
    end

    it 'does not change the behaviour of other providers' do
      [winner_leg, second_leg].each { |leg| leg.update!(provider: 'sipuni') }

      expect(described_class.close_late_leg(second_leg).status).to eq('ringing')
    end
  end
end
