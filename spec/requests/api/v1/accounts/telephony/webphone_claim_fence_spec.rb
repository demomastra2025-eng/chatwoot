require 'rails_helper'

# The claim of a Beeline call is fenced on the oldest leg of its group. That leg
# is the first operator's, who may decline or drop before the others answer:
# nobody else may be locked out of a call that still rings for him.
RSpec.describe 'Telephony claim with sibling legs of one Beeline call', type: :request do
  include_context 'with three Beeline operator browsers'

  def claim_service(user, leg)
    Telephony::OperatorCallClaimService.new(account: account, user: user, call_ref: leg.external_call_ref)
  end

  def claim!(index, legs)
    claim_service(operators[index], legs[index]).perform
  end

  def report_three_legs(prefix = 'sip-call-id')
    profiles.each_with_index.map do |profile, index|
      report_leg(profile, "#{prefix}-#{index}")
      leg_session(profile, "#{prefix}-#{index}")
    end
  end

  def end_leg!(leg, status: 'cancelled', end_reason: 'caller_hangup')
    leg.update!(status: status, ended_at: Time.current, end_reason: end_reason)
  end

  it 'lets the second operator claim after the first one declined his own leg' do
    legs = report_three_legs
    Telephony::OperatorCallRejectService.new(account: account, user: operators[0], call_ref: legs[0].external_call_ref, status: 'rejected').perform
    expect(legs[0].reload).to be_terminal

    expect(claim!(1, legs)).to include(claimed: true, user_id: operators[1].id)
    expect(legs[1].reload.status).to eq('connecting')
  end

  it 'does not bring an ended fence leg back to life' do
    legs = report_three_legs
    end_leg!(legs[0])

    claim!(2, legs)

    expect(legs[0].reload).to have_attributes(status: 'cancelled', end_reason: 'caller_hangup')
  end

  it 'still serialises two operators on the oldest open leg' do
    legs = report_three_legs
    end_leg!(legs[0])
    # The legs closed for the others would end the claim of the third operator first.
    allow(Telephony::SiblingLegCloser).to receive(:new).and_return(instance_double(Telephony::SiblingLegCloser, perform: []))
    claim!(1, legs)

    expect { claim!(2, legs) }.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('CALL_ALREADY_CLAIMED') }
  end

  it 'refuses an operator whose own leg is over' do
    legs = report_three_legs
    end_leg!(legs[2])

    expect { claim!(2, legs) }.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('CALL_NOT_CLAIMABLE') }
  end

  it 'refuses the claim of a call another operator holds, even when the leg that carries his claim ended' do
    legs = report_three_legs
    legs[0].update!(
      status: 'no_answer', ended_at: Time.current, end_reason: 'answered_by_other_operator',
      metadata: legs[0].metadata.deep_merge('operator_claim' => { 'user_id' => operators[1].id, 'user_name' => operators[1].name })
    )

    expect { claim!(2, legs) }.to raise_error(Telephony::Error) { |error|
      expect(error.code).to eq('CALL_ALREADY_CLAIMED')
      expect(error.details).to include(user_id: operators[1].id)
    }
  end

  it 'picks another fence when the leg that carried it ended while the claim waited for its lock' do
    legs = report_three_legs
    end_leg!(legs[0])
    service = claim_service(operators[1], legs[1])
    # The fence as it was picked before the leg ended.
    service.instance_variable_set(:@claim_fence_session, legs[0])

    expect(service.perform).to include(claimed: true, user_id: operators[1].id)
    expect(service.send(:claim_fence_session)).to eq(legs[1])
  end

  it 'gives up when the fence keeps moving' do
    legs = report_three_legs
    service = claim_service(operators[1], legs[1])
    allow(service).to receive(:claim_fence_session).and_return(legs[0].tap { |leg| end_leg!(leg) })

    expect { service.perform }.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('CALL_NOT_CLAIMABLE') }
  end

  it 'gives a caller who hangs up and dials again a call of its own that can be claimed' do
    legs = report_three_legs
    legs.each { |leg| end_leg!(leg) }

    report_leg(profiles[1], 'sip-call-id-redial')
    redial = leg_session(profiles[1], 'sip-call-id-redial')

    expect(logical_key(redial)).not_to eq(logical_key(legs[0]))
    expect(redial.logical_group_sessions.map(&:external_call_ref)).to eq([redial.external_call_ref])
    expect(claim_service(operators[1], redial).perform).to include(claimed: true)
  end
end
