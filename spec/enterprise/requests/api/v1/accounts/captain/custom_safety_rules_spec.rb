# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain custom safety rules', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:auth_headers) { admin.create_new_auth_token }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:rule) do
    { id: 'emergency_1', name: 'Urgent request', direction: 'input', instruction: 'The customer describes an emergency.',
      action: 'handoff', enabled: true, message: 'Please contact the appropriate emergency service.' }
  end

  def update_rules(rules, attributes = {})
    patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
          params: { assistant: attributes.merge(config: { safety_settings: { custom_rules: rules } }) },
          headers: auth_headers, as: :json
  end

  it 'creates and publishes the exact configured rules, including a preapproved public message' do
    post "/api/v1/accounts/#{account.id}/captain/assistants",
         params: { assistant: { name: 'Support', description: 'Help the customer.', config: { safety_settings: { custom_rules: [rule] } } } },
         headers: auth_headers, as: :json

    expect(response).to have_http_status(:success)
    saved = account.captain_assistants.find(JSON.parse(response.body)['id'])
    expect(saved.config.dig('safety_settings', 'custom_rules')).to eq([rule.stringify_keys])
    expect(JSON.parse(response.body).dig('config', 'safety_settings', 'custom_rules')).to eq([rule.stringify_keys])
  end

  it 'replaces the ordered list while retaining other safety and profile settings' do
    assistant.update!(config: { 'feature_faq' => true, 'safety_settings' => { 'moderation_enabled' => false, 'sensitive_info_action' => 'block' } })
    second = rule.merge(id: 'second', direction: 'output', action: 'rewrite', message: '')

    update_rules([second, rule.merge(enabled: false)])

    expect(response).to have_http_status(:success)
    expect(assistant.reload.config).to include('feature_faq' => true)
    expect(assistant.config['safety_settings']).to eq(
      'moderation_enabled' => false, 'sensitive_info_action' => 'block',
      'custom_rules' => [second.stringify_keys, rule.merge(enabled: false).stringify_keys]
    )
  end

  it 'retains omitted custom rules during a partial provider-safety update, then accepts an explicit clear' do
    assistant.update!(config: { 'safety_settings' => { 'moderation_enabled' => true, 'custom_rules' => [rule.stringify_keys] } })

    patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
          params: { assistant: { config: { safety_settings: { moderation_enabled: nil } } } },
          headers: auth_headers, as: :json

    expect(response).to have_http_status(:success)
    expect(assistant.reload.config['safety_settings']).to eq('moderation_enabled' => nil, 'custom_rules' => [rule.stringify_keys])

    update_rules([])

    expect(response).to have_http_status(:success)
    expect(assistant.reload.config['safety_settings']).to eq('moderation_enabled' => nil, 'custom_rules' => [])
  end

  [nil, 'rules', { unexpected: true }].each do |value|
    it "returns a concrete 422 for #{value.class} rules instead of losing the invalid value in strong parameters" do
      update_rules(value)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)).to include(
        'error' => 'invalid_custom_safety_rules',
        'fields' => [include('path' => 'safety_settings.custom_rules', 'code' => 'invalid_type')]
      )
      expect(assistant.reload.config.dig('safety_settings', 'custom_rules')).to be_nil
    end
  end

  it 'rejects extra rule fields before saving without echoing a supplied secret' do
    update_rules([rule.merge(provider_token: 'private-provider-token')])

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['fields']).to include(include('path' => 'safety_settings.custom_rules[0]', 'code' => 'unknown_fields'))
    expect(response.body).not_to include('private-provider-token')
  end

  it 'rolls back the entire profile and handoff graph when an input rewrite is invalid' do
    original_name = assistant.name
    target = create(:captain_assistant, account: account)

    update_rules([rule.merge(action: 'rewrite')], name: 'Changed', handoff_agent_ids: [target.id])

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['fields']).to include(include('path' => 'safety_settings.custom_rules[0].action', 'code' => 'output_only'))
    expect(assistant.reload.name).to eq(original_name)
    expect(assistant.handoff_agent_ids).to eq([])
    expect(assistant.config.dig('safety_settings', 'custom_rules')).to be_nil
  end

  it 'does not permit a manager from another account to change these rules' do
    foreign = create(:captain_assistant)

    patch "/api/v1/accounts/#{account.id}/captain/assistants/#{foreign.id}",
          params: { assistant: { config: { safety_settings: { custom_rules: [rule] } } } },
          headers: auth_headers, as: :json

    expect(response).to have_http_status(:not_found)
    expect(foreign.reload.config.dig('safety_settings', 'custom_rules')).to be_nil
  end
end
