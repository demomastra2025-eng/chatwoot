require 'rails_helper'

# Characterisation, not an endorsement. Beeline gives no identifier shared by
# the legs of one physical call (the call ids, the provider sids and every
# event payload differ in all the legs), so the caller number and the time
# window are the only correlation there is (Telephony::SiblingLegGrouping).
# Two live calls of the same caller number to the same channel within the
# window (two devices behind one caller ID) are therefore one logical call
# until one of them ends. This spec pins that known limitation down.
RSpec.describe 'Telephony webphone two live calls of the same caller number', type: :request do
  include_context 'with three Beeline operator browsers'

  def claim_service(index, leg)
    Telephony::OperatorCallClaimService.new(account: account, user: operators[index], call_ref: leg.external_call_ref)
  end

  # Call one reaches the browsers of operators 1 and 2, call two the one of operator 3.
  let(:first_call_legs) { [[0, 'first-call-0'], [1, 'first-call-1']].map { |index, id| leg_session(profiles[index], id) } }
  let(:second_call_leg) { leg_session(profiles[2], 'second-call-2') }

  before do
    report_leg(profiles[0], 'first-call-0')
    report_leg(profiles[1], 'first-call-1')
    report_leg(profiles[2], 'second-call-2')
  end

  it 'groups the legs of both calls into one logical call' do
    expect(logical_key(second_call_leg)).to eq(logical_key(first_call_legs.first))
    expect(first_call_legs.first.logical_group_sessions).to contain_exactly(*first_call_legs, second_call_leg)
  end

  it 'closes the leg of the second call when an operator takes the first one' do
    claim_service(0, first_call_legs.first).perform

    expect(second_call_leg.reload).to have_attributes(status: 'no_answer', end_reason: 'answered_by_other_operator')
  end

  it 'does not let the operator of the second call take it while the first one is held' do
    claim_service(0, first_call_legs.first).perform

    expect { claim_service(2, second_call_leg).perform }.to raise_error(Telephony::Error) { |error|
      expect(error.code).to eq('CALL_NOT_CLAIMABLE')
    }
  end

  it 'lets the second call be taken once the first one is over without being answered' do
    first_call_legs.each { |leg| leg.update!(status: 'no_answer', ended_at: Time.current, end_reason: 'caller_hangup') }

    expect(claim_service(2, second_call_leg).perform).to include(claimed: true, user_id: operators[2].id)
  end
end
