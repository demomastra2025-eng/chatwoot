require 'rails_helper'

# The browsers of one Beeline call report their legs one after another. An
# operator may take the call before the browser of another operator has
# reported its own leg: that leg joins the group of a call somebody already
# owns, so it is closed at once and rings nowhere. A caller who dials again
# after the first call is over is a new call and still rings.
RSpec.describe 'Telephony webphone leg reported after the call was taken', type: :request do
  include_context 'with three Beeline operator browsers'

  def claim!(index, leg)
    Telephony::OperatorCallClaimService.new(account: account, user: operators[index], call_ref: leg.external_call_ref).perform
  end

  def answer!(index, leg)
    Telephony::OperatorCallAnsweredService.new(account: account, user: operators[index], call_ref: leg.external_call_ref).perform
  end

  def end_call!(index, leg, status)
    Telephony::OperatorCallRejectService.new(
      account: account, user: operators[index], call_ref: leg.external_call_ref, status: status
    ).perform
  end

  def have_broadcast_incoming(leg, to: anything)
    have_received(:broadcast).with(to, hash_including(event: 'voice_call.incoming', data: hash_including(call_sid: leg.external_call_ref)))
  end

  def have_broadcast_claimed(leg, to:)
    have_received(:broadcast).with(to, hash_including(event: 'voice_call.claimed', data: hash_including(callSid: leg.external_call_ref)))
  end

  let(:first_leg) { leg_session(profiles[0], 'sip-call-id-0') }

  shared_examples 'a leg that joins a call somebody owns' do
    it 'closes the new leg at once as answered by another operator' do
      report_leg(profiles[1], 'sip-call-id-1')

      expect(leg_session(profiles[1], 'sip-call-id-1')).to have_attributes(status: 'no_answer', end_reason: 'answered_by_other_operator')
    end

    it 'rings nobody for the new leg and tells only its operator that the call was taken' do
      report_leg(profiles[1], 'sip-call-id-1')
      late = leg_session(profiles[1], 'sip-call-id-1')

      expect(ActionCable.server).not_to have_broadcast_incoming(late)
      expect(ActionCable.server).to have_broadcast_claimed(late, to: operators[1].pubsub_token)
      expect(ActionCable.server).not_to have_broadcast_claimed(late, to: operators[0].pubsub_token)
    end

    it 'answers the browser that reported the leg with the closed leg' do
      report_leg(profiles[1], 'sip-call-id-1')

      expect(response.parsed_body['payload']).to include(
        'call_ref' => leg_session(profiles[1], 'sip-call-id-1').external_call_ref, 'status' => 'no_answer',
        'logical_call_key' => logical_key(first_leg)
      )
    end

    it 'keeps the leg of the operator who owns the call and its group' do
      report_leg(profiles[1], 'sip-call-id-1')
      late = leg_session(profiles[1], 'sip-call-id-1')

      expect(first_leg.reload.status).to eq(owner_status)
      expect(first_leg.end_reason).to be_nil
      expect(first_leg.metadata.dig('operator_claim', 'user_id')).to eq(operators[0].id)
      expect(logical_key(late)).to eq(logical_key(first_leg))
      expect(first_leg.logical_group_sessions).to contain_exactly(first_leg, late)
    end

    it 'closes the legs of every operator who reports late' do
      report_leg(profiles[1], 'sip-call-id-1')
      report_leg(profiles[2], 'sip-call-id-2')

      expect(%w[sip-call-id-1 sip-call-id-2].map { |id| leg_session(profiles[id[-1].to_i], id).status }).to all(eq('no_answer'))
      expect(ActionCable.server).not_to have_broadcast_incoming(leg_session(profiles[2], 'sip-call-id-2'))
    end

    it 'changes nothing when the browser reports the same leg again' do
      report_leg(profiles[1], 'sip-call-id-1')
      late = leg_session(profiles[1], 'sip-call-id-1')

      expect do
        report_leg(profiles[1], 'sip-call-id-1')
      end.not_to(change { [account.telephony_call_sessions.count, late.reload.status, late.end_reason] })
      expect(response.parsed_body['payload']).to include('call_ref' => late.external_call_ref, 'status' => 'no_answer')
      expect(ActionCable.server).not_to have_broadcast_incoming(late)
      expect(ActionCable.server).to have_broadcast_claimed(late, to: operators[1].pubsub_token).once
      expect(first_leg.reload.status).to eq(owner_status)
    end

    it 'keeps the closed leg closed when the claim is replayed' do
      report_leg(profiles[1], 'sip-call-id-1')

      expect(claim!(0, first_leg)).to include(claimed: true, user_id: operators[0].id)

      expect(leg_session(profiles[1], 'sip-call-id-1').status).to eq('no_answer')
      expect(first_leg.reload.status).to eq(owner_status)
    end

    it 'does not let the operator of the closed leg take the call' do
      report_leg(profiles[1], 'sip-call-id-1')

      expect { claim!(1, leg_session(profiles[1], 'sip-call-id-1')) }.to raise_error(Telephony::Error) { |error|
        expect(error.code).to eq('CALL_NOT_CLAIMABLE')
      }
    end
  end

  context 'when the first operator claimed the call' do
    let(:owner_status) { 'connecting' }

    before do
      report_leg(profiles[0], 'sip-call-id-0')
      claim!(0, first_leg)
    end

    it_behaves_like 'a leg that joins a call somebody owns'
  end

  context 'when the first operator answered the call' do
    let(:owner_status) { 'in_progress' }

    before do
      report_leg(profiles[0], 'sip-call-id-0')
      claim!(0, first_leg)
      answer!(0, first_leg)
    end

    it_behaves_like 'a leg that joins a call somebody owns'
  end

  context 'when the operator who claimed the call holds a leg that is not the oldest one' do
    it 'closes the new leg as well' do
      report_leg(profiles[0], 'sip-call-id-0')
      report_leg(profiles[1], 'sip-call-id-1')
      claim!(1, leg_session(profiles[1], 'sip-call-id-1'))

      report_leg(profiles[2], 'sip-call-id-2')

      expect(leg_session(profiles[2], 'sip-call-id-2').status).to eq('no_answer')
      expect(leg_session(profiles[1], 'sip-call-id-1').status).to eq('connecting')
      expect(leg_session(profiles[0], 'sip-call-id-0').status).to eq('no_answer')
    end
  end

  context 'when the claim of a non-oldest leg is committed but its own closer has not run yet' do
    # The claim is copied onto the oldest leg (the fence) as well as the
    # claimer's leg. A late report that is admitted in this window must close
    # only itself, whichever of the two it finds as the owner.
    let(:claimer_leg) { leg_session(profiles[1], 'sip-call-id-1') }

    before do
      report_leg(profiles[0], 'sip-call-id-0')
      report_leg(profiles[1], 'sip-call-id-1')
      allow_any_instance_of(Telephony::OperatorCallClaimService).to receive(:close_sibling_legs!) # rubocop:disable RSpec/AnyInstance
      claim!(1, claimer_leg)
      report_leg(profiles[2], 'sip-call-id-2')
    end

    it 'closes only the late leg and keeps the claimer leg open' do
      expect(leg_session(profiles[2], 'sip-call-id-2')).to have_attributes(status: 'no_answer', end_reason: 'answered_by_other_operator')
      expect(claimer_leg.reload.status).to eq('connecting')
      expect(claimer_leg.end_reason).to be_nil
    end

    it 'leaves the claimer able to answer once its own closer has run' do
      Telephony::SiblingLegCloser.new(call_session: claimer_leg.reload).perform

      expect(leg_session(profiles[0], 'sip-call-id-0').status).to eq('no_answer')
      expect(claimer_leg.reload.status).to eq('connecting')
      expect { answer!(1, claimer_leg) }.not_to raise_error
      expect(claimer_leg.reload).to have_attributes(status: 'in_progress')
      expect(claimer_leg.answered_at).to be_present
    end
  end

  context 'when nobody claimed the call yet' do
    it 'still rings every operator who reports' do
      report_leg(profiles[0], 'sip-call-id-0')
      report_leg(profiles[1], 'sip-call-id-1')

      late = leg_session(profiles[1], 'sip-call-id-1')
      expect(late.status).to eq('ringing')
      expect(ActionCable.server).to have_broadcast_incoming(late, to: operators[1].pubsub_token)
    end
  end

  describe 'a caller who dials again after the first call is over' do
    let(:redial) { leg_session(profiles[1], 'sip-call-id-redial') }

    shared_examples 'a new call that rings' do
      before { report_leg(profiles[1], 'sip-call-id-redial') }

      it 'rings as a call of its own' do
        expect(redial.status).to eq('ringing')
        expect(logical_key(redial)).not_to eq(logical_key(first_leg))
        expect(ActionCable.server).to have_broadcast_incoming(redial, to: operators[1].pubsub_token)
      end

      it 'can be taken by an operator' do
        expect(claim!(1, redial)).to include(claimed: true, user_id: operators[1].id)
      end
    end

    context 'when the first call was answered and completed' do
      before do
        report_leg(profiles[0], 'sip-call-id-0')
        claim!(0, first_leg)
        answer!(0, first_leg)
        end_call!(0, first_leg, 'completed')
      end

      it_behaves_like 'a new call that rings'
    end

    context 'when the operator who claimed the first call gave up' do
      before do
        report_leg(profiles[0], 'sip-call-id-0')
        claim!(0, first_leg)
        end_call!(0, first_leg, 'failed')
      end

      it_behaves_like 'a new call that rings'
    end

    context 'when nobody answered the first call' do
      before do
        report_leg(profiles[0], 'sip-call-id-0')
        end_call!(0, first_leg, 'no_answer')
      end

      it_behaves_like 'a new call that rings'
    end
  end
end
