require 'rails_helper'

RSpec.describe 'Scheduling Resource Service Stats API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:ultrasound) { create(:scheduling_service, account: account, name: 'УЗИ малого таза', category: 'Диагностика') }
  let(:consultation) { create(:scheduling_service, account: account, name: 'Консультация') }
  let(:admin_headers) { admin.create_new_auth_token }
  let(:agent_headers) { agent.create_new_auth_token }
  let(:base_path) { "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/service_stats" }

  before { account.enable_features!('scheduling') }

  def body
    response.parsed_body
  end

  describe 'GET index' do
    it 'lists the pairs of the specialist, the most frequent first, with the service and the history numbers' do
      rare = create(:scheduling_resource_service_stat, account: account, resource: resource, service: consultation, receptions_count: 4,
                                                       median_duration_min: 20, status: 'stale')
      common = create(:scheduling_resource_service_stat, account: account, resource: resource, service: ultrasound, receptions_count: 40,
                                                         median_duration_min: 15, last_seen_at: Time.utc(2026, 10, 20, 8))
      create(:scheduling_resource_service_stat, account: account)

      get base_path, headers: agent_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(body['meta']).to eq('count' => 2)
      expect(body['payload'].pluck('id')).to eq([common.id, rare.id])
      expect(body['payload'].first).to include(
        'service_id' => ultrasound.id, 'service_name' => 'УЗИ малого таза', 'service_category' => 'Диагностика', 'receptions_count' => 40,
        'median_duration_min' => 15, 'last_seen_at' => '2026-10-20T08:00:00Z', 'source' => 'history', 'status' => 'auto', 'counts' => true
      )
      expect(body['payload'].last).to include('status' => 'stale', 'counts' => false)
    end

    it 'does not show the pairs of a specialist of another account' do
      other = create(:scheduling_resource)

      get "/api/v1/accounts/#{account.id}/scheduling/resources/#{other.id}/service_stats", headers: admin_headers, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'needs the scheduling feature' do
      account.disable_features!('scheduling')

      get base_path, headers: admin_headers, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'PATCH update' do
    let!(:stat) { create(:scheduling_resource_service_stat, account: account, resource: resource, service: ultrasound, status: 'auto') }

    it 'lets an administrator confirm and disable a pair' do
      patch "#{base_path}/#{stat.id}", params: { status: 'disabled' }, headers: admin_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(body['payload']).to include('id' => stat.id, 'status' => 'disabled', 'counts' => false)
      expect(stat.reload.status).to eq('disabled')

      patch "#{base_path}/#{stat.id}", params: { status: 'confirmed' }, headers: admin_headers, as: :json

      expect(body['payload']).to include('status' => 'confirmed', 'counts' => true)
      expect(stat.reload.status).to eq('confirmed')
    end

    it 'accepts only the statuses staff can set' do
      %w[auto stale unknown].each do |status|
        patch "#{base_path}/#{stat.id}", params: { status: status }, headers: admin_headers, as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end
      patch "#{base_path}/#{stat.id}", params: {}, headers: admin_headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(stat.reload.status).to eq('auto')
    end

    it 'refuses an agent' do
      patch "#{base_path}/#{stat.id}", params: { status: 'disabled' }, headers: agent_headers, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(stat.reload.status).to eq('auto')
    end

    it 'does not reach the pair of another specialist' do
      other_stat = create(:scheduling_resource_service_stat, account: account)

      patch "#{base_path}/#{other_stat.id}", params: { status: 'disabled' }, headers: admin_headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(other_stat.reload.status).to eq('auto')
    end
  end
end
