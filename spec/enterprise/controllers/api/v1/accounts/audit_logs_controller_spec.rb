require 'rails_helper'

RSpec.describe 'Enterprise Audit API', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account) }

  describe 'GET /api/v1/accounts/{account.id}/audit_logs' do
    context 'when it is an un-authenticated user' do
      it 'does not fetch audit logs associated with the account' do
        get "/api/v1/accounts/#{account.id}/audit_logs",
            as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated normal user' do
      let(:user) { create(:user, account: account) }

      it 'fetches audit logs associated with the account' do
        get "/api/v1/accounts/#{account.id}/audit_logs",
            headers: user.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    # check for response in parse
    context 'when it is an authenticated admin user' do
      it 'returns empty array if feature is not enabled' do
        get "/api/v1/accounts/#{account.id}/audit_logs",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response['audit_logs']).to eql([])
      end

      it 'fetches audit logs associated with the account' do
        account.enable_features(:audit_logs)
        account.save!

        get "/api/v1/accounts/#{account.id}/audit_logs",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        inbox_log = json_response['audit_logs'].find do |audit_log|
          audit_log['auditable_type'] == 'Inbox' && audit_log['action'] == 'create' &&
            audit_log.dig('auditable', 'id') == inbox.id
        end
        expect(inbox_log).to be_present
        expect(inbox_log['auditable']['channel_type']).to eql(inbox.display_channel_type)
        expect(inbox_log['audited_changes']['name']).to eql(inbox.name)
        expect(inbox_log['associated_id']).to eql(account.id)
        # contains audit log for account user as well
        # contains audit logs for account update(enable audit logs)
        expect(json_response.slice('current_page', 'per_page', 'total_entries')).to eql(
          'current_page' => 1,
          'per_page' => 25,
          'total_entries' => 4
        )
      end

      # The Agent Bots were removed, their audit history stays: the entry is listed, without an object payload.
      it 'lists the history of an object whose class no longer exists' do
        account.enable_features(:audit_logs)
        account.save!
        Audited::Audit.insert_all!(
          [{ auditable_type: 'AgentBot', auditable_id: 41, associated_type: 'Account', associated_id: account.id,
             action: 'destroy', audited_changes: { 'name' => 'Old bot' }, created_at: Time.current }]
        )

        get "/api/v1/accounts/#{account.id}/audit_logs",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        bot_log = response.parsed_body['audit_logs'].find { |audit_log| audit_log['auditable_type'] == 'AgentBot' }
        expect(bot_log).to include('auditable_id' => 41, 'action' => 'destroy', 'auditable' => nil)
        expect(bot_log['audited_changes']).to eq('name' => 'Old bot')
      end
    end
  end
end
