require 'rails_helper'

RSpec.describe 'Widget availability', type: :request do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_widget, account: account) }

  it 'projects the company policy without a contact or authentication token' do
    account.update!(workspace_working_hours: AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.deep_dup,
                    workspace_days_off: [{ date: '2026-09-07', title: 'Private event' }])

    travel_to(Time.iso8601('2026-09-07T07:00:00Z')) do
      expect do
        get '/api/v1/widget/availability', params: { website_token: channel.website_token }
      end.not_to change(Contact, :count)
    end

    expect(response).to have_http_status(:ok)
    data = response.parsed_body
    expect(data.keys).to contain_exactly('timezone', 'valid_from', 'valid_until', 'intervals')
    expect(data.to_json).not_to include('Private event')
    expect(response.headers['Cache-Control']).to include('public', 'max-age=60')
  end

  it 'uses the widget account regardless of supplied account IDs' do
    other = create(:account, workspace_timezone: 'America/New_York')

    get '/api/v1/widget/availability', params: { website_token: channel.website_token, account_id: other.id }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['timezone']).to eq('Asia/Almaty')
  end

  it 'rejects an invalid widget token' do
    get '/api/v1/widget/availability', params: { website_token: 'not-a-widget' }

    expect(response).to have_http_status(:not_found)
  end

  it 'does not serve availability for a suspended account' do
    account.update!(status: :suspended)

    get '/api/v1/widget/availability', params: { website_token: channel.website_token }

    expect(response).to have_http_status(:unauthorized)
  end
end
