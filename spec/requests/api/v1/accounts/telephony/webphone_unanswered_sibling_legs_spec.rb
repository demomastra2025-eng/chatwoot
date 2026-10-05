require 'rails_helper'

# Nobody answers and the caller hangs up: every operator browser reports the
# end of its own leg. The call is one missed call in one conversation, not one
# conversation per leg.
RSpec.describe 'Telephony webphone unanswered call with sibling legs', type: :request do
  include ActiveJob::TestHelper
  include_context 'with three Beeline operator browsers'

  def report_legs_with_lifecycle
    profiles.each_with_index.map do |profile, index|
      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) { report_leg(profile, "sip-call-id-#{index}") }
      leg_session(profile, "sip-call-id-#{index}")
    end
  end

  def report_hangup(index, legs)
    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: legs[index].external_call_ref, status: 'no_answer', reason: 'remote_hangup' },
         headers: auth_headers(operators[index]), as: :json
    expect(response).to have_http_status(:ok)
  end

  it 'leaves one conversation and one missed call when every browser reports the hangup' do
    legs = report_legs_with_lifecycle

    legs.each_index { |index| report_hangup(index, legs) }

    expect(legs.map { |leg| leg.reload.status }).to all(eq('no_answer'))
    expect(account.conversations.count).to eq(1)
    expect(account.messages.voice_calls.map { |message| message.content_attributes.dig('data', 'status') }).to eq(['no_answer'])
    expect(account.conversations.first.additional_attributes['call_status']).to eq('no_answer')
  end

  it 'leaves one conversation when the browsers report in the reverse order' do
    legs = report_legs_with_lifecycle

    legs.each_index.reverse_each { |index| report_hangup(index, legs) }

    expect(account.conversations.count).to eq(1)
    expect(account.messages.voice_calls.count).to eq(1)
  end
end
