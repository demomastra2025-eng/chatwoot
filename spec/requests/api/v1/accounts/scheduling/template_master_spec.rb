# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Scheduling::TemplateMaster', type: :request do
  let(:account) { create(:account, name: 'MedLine Clinic') }
  let(:admin) { create(:user, account: account, role: :administrator) }

  before do
    account.enable_features!('scheduling')
  end

  describe 'POST /api/v1/accounts/:account_id/scheduling/template_master/generate' do
    it 'returns AI-generated validated template drafts for requested languages' do
      allow(Llm::Runtime).to receive(:chat).and_return(double(content: '{}'))

      post "/api/v1/accounts/#{account.id}/scheduling/template_master/generate",
           headers: admin.create_new_auth_token,
           params: { languages: %w[ru kk], bilingual: false },
           as: :json

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body['payload']
      expect(payload['model']).to eq('openai/gpt-6.1-terra')
      expect(payload['languages']).to eq(%w[ru kk])
      expect(payload['templates'].size).to eq(12)
      expect(payload['templates']).to all(satisfy { |tpl| tpl.dig('validation', 'valid') == true })
    end
  end

  describe 'POST /api/v1/accounts/:account_id/scheduling/template_master/validate' do
    it 'validates a template draft programmatically before submitting to Meta' do
      post "/api/v1/accounts/#{account.id}/scheduling/template_master/validate",
           headers: admin.create_new_auth_token,
           params: {
             body_text: 'Сәлеметсіз бе, {{1}}! Ертең сағат {{2}}-ке келіңіз.',
             buttons: [{ type: 'QUICK_REPLY', text: 'Растаймын' }],
             language: 'kk',
             category: 'UTILITY'
           },
           as: :json

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body['payload']
      expect(payload['valid']).to be(false)
      expect(payload['error_codes']).to include('hyphen_suffix_after_variable')
    end
  end
end
