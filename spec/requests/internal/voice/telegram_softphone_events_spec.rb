require 'rails_helper'

RSpec.describe 'Internal::Voice::TelegramSoftphoneEvents', type: :request do
  before do
    allow(TelegramCalls::Config).to receive(:callback_token).and_return('cb-secret-token')
  end

  it 'rejects missing or invalid bearer token' do
    post '/internal/voice/telegram_softphone/events',
         params: { event: 'operator_leg.ringing', data: { leg_id: 'leg-1' } },
         as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'unwraps the Gateway {"event", "data"} envelope into ClaimCoordinator payload' do
    coordinator = instance_double(TelegramCalls::ClaimCoordinator, perform: { ok: true, claimed: true })
    allow(TelegramCalls::ClaimCoordinator).to receive(:new).and_return(coordinator)

    post '/internal/voice/telegram_softphone/events',
         params: {
           event: 'operator_leg.answered',
           timestamp: 1_730_450_000.12,
           data: { leg_id: 'leg-envelope-1', account_id: 60, user_id: 12 }
         },
         headers: { 'Authorization' => 'Bearer cb-secret-token' },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('ok' => true, 'claimed' => true)
    expect(TelegramCalls::ClaimCoordinator).to have_received(:new).with(
      payload: hash_including(
        'event_type' => 'operator_leg.answered',
        'leg_id' => 'leg-envelope-1',
        'account_id' => 60,
        'user_id' => 12
      )
    )
  end
end
