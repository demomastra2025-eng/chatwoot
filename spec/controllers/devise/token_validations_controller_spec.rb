require 'rails_helper'

RSpec.describe 'Token Validation API', type: :request do
  describe 'GET /validate_token' do
    let(:account) { create(:account) }

    context 'when it is an invalid token' do
      it 'returns unauthorized' do
        get '/auth/validate_token'
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is a valid token' do
      let(:agent) { create(:user, account: account, role: :agent) }

      it 'returns all the labels for the conversation' do
        get '/auth/validate_token',
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(response.body).to include('payload')
      end

      it 'preserves the ordinary customer credential payload' do
        allow(GlobalConfig).to receive(:get).and_call_original
        allow(GlobalConfig).to receive(:get).with('CHATWOOT_INBOX_HMAC_KEY')
                                            .and_return('CHATWOOT_INBOX_HMAC_KEY' => 'synthetic-hmac-key')
        headers = agent.create_new_auth_token

        get '/auth/validate_token', headers: headers

        data = response.parsed_body.dig('payload', 'data')
        expect(response).to have_http_status(:success)
        expect(data['access_token']).to eq(agent.access_token.token)
        expect(data['pubsub_token']).to eq(agent.pubsub_token)
        expect(data['hmac_identifier']).to eq(agent.hmac_identifier)
        expect(data['accounts'].map { |entry| entry['id'] }).to include(account.id)
      end
    end
  end
end
