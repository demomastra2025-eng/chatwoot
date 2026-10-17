require 'rails_helper'

RSpec.describe 'Captain account settings', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:path) { "/api/v1/accounts/#{account.id}/captain/settings" }

  it 'returns one account-level settings object to an administrator' do
    allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
    get path, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.keys).to contain_exactly('understanding', 'handoff', 'faq', 'conversation', 'safety', 'availability', 'routing')
    expect(body.dig('handoff', 'handoff_reasons')).to all(include('id', 'label', 'enabled', 'builtin'))
    expect(body.dig('availability', 'web_access_configured')).to be(true)
  end

  it 'accepts a partial patch without changing another section or an agent config' do
    assistant = create(:captain_assistant, account: account, config: { 'feature_faq' => false })
    patch path, params: { faq: { generate_from_resolved: true }, handoff: { handoff_message: { mode: 'generated' } } },
                headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig('handoff', 'handoff_message')).to include('mode' => 'generated', 'enabled' => true)
    expect(Captain::AccountSettings.new(account.reload).section('faq')['generate_from_resolved']).to be(true)
    expect(assistant.reload.config['feature_faq']).to be(false)
  end

  describe 'the "how to write" instruction of the handoff and closing messages' do
    %w[handoff_message resolution_message].each do |key|
      it "returns an empty #{key} instruction by default" do
        get path, headers: admin.create_new_auth_token, as: :json

        expect(JSON.parse(response.body).dig('handoff', key)).to eq('enabled' => key == 'handoff_message', 'mode' => 'fixed', 'text' => '',
                                                                    'instruction' => '')
      end

      it "saves the #{key} instruction up to 500 characters and keeps the other fields" do
        headers = admin.create_new_auth_token
        patch path, params: { handoff: { key => { mode: 'generated', instruction: 'я' * 500 } } }, headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body).dig('handoff', key)).to include('mode' => 'generated', 'instruction' => 'я' * 500)
        expect(Captain::AccountSettings.new(account.reload).section('handoff')[key]).to include('mode' => 'generated', 'instruction' => 'я' * 500)

        patch path, params: { handoff: { key => { text: 'Готовый текст' } } }, headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body).dig('handoff', key)).to include('text' => 'Готовый текст', 'instruction' => 'я' * 500)
      end

      it "rejects a #{key} instruction longer than 500 characters or not a string, and saves nothing" do
        headers = admin.create_new_auth_token
        patch path, params: { handoff: { key => { instruction: 'я' * 501 } } }, headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)['errors']).to include(include('field' => "handoff.#{key}.instruction", 'code' => 'too_long'))

        patch path, params: { handoff: { key => { instruction: 42 } } }, headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)['errors']).to include(include('field' => "handoff.#{key}.instruction", 'code' => 'invalid_value'))
        expect(account.reload.captain_agent_settings).to be_nil
      end
    end
  end

  it 'rejects invalid custom rules with the exact errors envelope and leaves settings intact' do
    patch path, params: { safety: { custom_rules: [{ id: 'bad', direction: 'inbound', action: 'rewrite_once' }] } },
                headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['errors']).to include(include('field' => 'safety.custom_rules[0].action', 'code' => 'output_only'))
    expect(account.reload.captain_agent_settings).to be_nil
  end

  it 'requires administrator access for both reads and writes' do
    get path, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)

    patch path, params: { faq: { generate_from_resolved: true } }, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
