# frozen_string_literal: true

require 'rails_helper'

# Safety checks and custom safety rules are one workspace-wide setting
# (PATCH captain/settings, section "safety"). The agent profile API no longer
# accepts them: a legacy client may still send config.safety_settings, it is
# ignored and whatever an agent stores from before is left as it is.
RSpec.describe 'Captain per-agent safety settings', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:auth_headers) { admin.create_new_auth_token }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:rule) do
    { id: 'emergency_1', name: 'Urgent request', direction: 'input', instruction: 'The customer describes an emergency.',
      action: 'handoff', enabled: true, message: 'Please contact the appropriate emergency service.' }
  end
  let(:path) { "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}" }

  def update_safety(safety_settings, attributes = {})
    patch path, params: { assistant: attributes.merge(config: { safety_settings: safety_settings }) },
                headers: auth_headers, as: :json
  end

  it 'creates an agent without any safety settings even when the client sends custom rules' do
    post "/api/v1/accounts/#{account.id}/captain/assistants",
         params: { assistant: { name: 'Support', description: 'Help the customer.', config: { safety_settings: { custom_rules: [rule] } } } },
         headers: auth_headers, as: :json

    expect(response).to have_http_status(:success)
    saved = account.captain_assistants.find(JSON.parse(response.body)['id'])
    expect(saved.config).not_to have_key('safety_settings')
    expect(JSON.parse(response.body).fetch('config', {})).not_to have_key('safety_settings')
  end

  it 'keeps the stored legacy safety settings untouched while saving the rest of the profile' do
    legacy = { 'moderation_enabled' => false, 'sensitive_info_action' => 'block', 'custom_rules' => [rule.stringify_keys] }
    assistant.update!(config: { 'feature_faq' => true, 'safety_settings' => legacy })

    update_safety({ moderation_enabled: true, prompt_injection_action: 'disabled', custom_rules: [] }, name: 'Renamed')

    expect(response).to have_http_status(:success)
    assistant.reload
    expect(assistant.name).to eq('Renamed')
    expect(assistant.config).to include('feature_faq' => true)
    expect(assistant.config['safety_settings']).to eq(legacy)
  end

  it 'saves the rest of the profile when the stored legacy safety data is malformed' do
    broken = { 'prompt_injection_action' => 'warn_only', 'custom_prompt_rule' => true, 'custom_rules' => 'rules' }
    assistant.update!(config: { 'feature_faq' => true, 'safety_settings' => broken })

    patch path, params: { assistant: { name: 'Renamed', config: { feature_faq: false } } }, headers: auth_headers, as: :json

    expect(response).to have_http_status(:success)
    assistant.reload
    expect(assistant.name).to eq('Renamed')
    expect(assistant.config).to include('feature_faq' => false)
    expect(assistant.config['safety_settings']).to eq(broken)
  end

  [nil, 'rules', { unexpected: true }].each do |value|
    it "does not reject the profile save for #{value.class} rules, it ignores them" do
      update_safety({ custom_rules: value }, name: 'Still saved')

      expect(response).to have_http_status(:success)
      expect(assistant.reload.name).to eq('Still saved')
      expect(assistant.config).not_to have_key('safety_settings')
    end
  end

  it 'does not let the workspace-wide safety checks be changed through another account agent' do
    foreign = create(:captain_assistant)

    patch "/api/v1/accounts/#{account.id}/captain/assistants/#{foreign.id}",
          params: { assistant: { config: { safety_settings: { custom_rules: [rule] } } } },
          headers: auth_headers, as: :json

    expect(response).to have_http_status(:not_found)
    expect(foreign.reload.config.dig('safety_settings', 'custom_rules')).to be_nil
  end
end
