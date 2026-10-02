require 'rails_helper'

RSpec.describe 'WhatsApp usage API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:path) { "/api/v1/accounts/#{account.id}/whatsapp_usage" }

  it 'returns usage for administrators and includes the official Cloud phone scope' do
    channel = create(:channel_whatsapp, account: account, phone_number: '+77010000004', provider: 'whatsapp_cloud',
                                        sync_templates: false, validate_provider_config: false)
    tracking_state = WhatsappUsageTrackingState.current_or_create!
    tracking_state.update!(tracking_started_at: Time.current.utc.beginning_of_month)

    get path, headers: administrator.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['whatsapp_usage']).to include(
      'currency' => 'KZT',
      'estimated' => true,
      'eligible' => true,
      'official_cloud_phone_count' => 1,
      'phones' => include(hash_including('phone_number' => channel.phone_number, 'connected' => true))
    )
  end

  it 'rejects authenticated non-administrator account members' do
    agent = create(:user, account: account, role: :agent)

    get path, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq('error' => 'You are not authorized to do this action')
  end
end
