# frozen_string_literal: true

require 'rails_helper'

# Safety checks and custom safety rules are one workspace-wide setting
# (PATCH captain/settings, section "safety"), the one the AI settings page
# edits for all agents at once. The agent profile API does not accept them: a
# legacy client may still send config.safety_settings, it is ignored and
# whatever an agent stores from before is left as it is.
RSpec.describe 'Captain safety settings', type: :request do
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

  describe 'workspace-wide checks and rules (PATCH captain/settings)' do
    let(:settings_path) { "/api/v1/accounts/#{account.id}/captain/settings" }
    let(:inbound_rule) do
      { id: 'emergency', name: 'Urgent request', direction: 'inbound', instruction: 'The customer describes an emergency.',
        action: 'handoff', enabled: true, message: 'Please contact the appropriate emergency service.' }
    end
    let(:outbound_rule) do
      { id: 'no_promises', name: 'No promises', direction: 'outbound', instruction: 'The reply promises a result nobody can guarantee.',
        action: 'rewrite_once', enabled: false, message: '' }
    end

    def update_settings(safety)
      patch settings_path, params: { safety: safety }, headers: auth_headers, as: :json
    end

    def saved_safety
      JSON.parse(response.body)['safety']
    end

    it 'returns the checks on with block and no rules until the workspace changes them' do
      get settings_path, headers: auth_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(saved_safety).to eq('moderation_enabled' => false, 'prompt_injection_action' => 'block',
                                 'sensitive_info_action' => 'block', 'custom_rules' => [])
    end

    it 'saves the switch, both actions and both rule lists exactly as sent, in order, disabled rules included' do
      update_settings(moderation_enabled: true, prompt_injection_action: 'flag', sensitive_info_action: 'off',
                      custom_rules: [outbound_rule, inbound_rule])

      expect(response).to have_http_status(:ok)
      expect(saved_safety).to include('moderation_enabled' => true, 'prompt_injection_action' => 'flag', 'sensitive_info_action' => 'off')
      expect(saved_safety['custom_rules']).to eq([outbound_rule, inbound_rule].map(&:stringify_keys))
      expect(Captain::AccountSettings.new(account.reload).section('safety')['custom_rules'])
        .to eq([outbound_rule, inbound_rule].map(&:stringify_keys))
    end

    it 'keeps the other safety values when one is patched, and accepts an explicit clear of the rules' do
      update_settings(prompt_injection_action: 'flag', custom_rules: [inbound_rule])
      update_settings(moderation_enabled: true)

      expect(saved_safety).to include('moderation_enabled' => true, 'prompt_injection_action' => 'flag')
      expect(saved_safety['custom_rules']).to eq([inbound_rule.stringify_keys])

      update_settings(custom_rules: [])

      expect(response).to have_http_status(:ok)
      expect(saved_safety).to include('moderation_enabled' => true, 'prompt_injection_action' => 'flag', 'custom_rules' => [])
    end

    it 'does not touch another section or the stored agent profiles' do
      assistant.update!(config: { 'feature_faq' => true, 'safety_settings' => { 'custom_rules' => [rule.stringify_keys] } })
      patch settings_path, params: { faq: { generate_from_resolved: true }, safety: { custom_rules: [inbound_rule] } },
                           headers: auth_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(assistant.reload.config).to include('feature_faq' => true)
      expect(assistant.config.dig('safety_settings', 'custom_rules')).to eq([rule.stringify_keys])
    end

    %w[allow warn disabled].each do |action|
      it "rejects the action #{action.inspect} and saves nothing" do
        update_settings(moderation_enabled: true, sensitive_info_action: action)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)['errors']).to include(include('field' => 'safety.sensitive_info_action', 'code' => 'invalid_value'))
        expect(account.reload.captain_agent_settings).to be_nil
      end
    end

    [nil, 'rules', { unexpected: true }].each do |value|
      it "returns a concrete 422 for #{value.class} rules" do
        update_settings(custom_rules: value)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)['errors']).to include(include('field' => 'safety.custom_rules', 'code' => 'invalid_type'))
        expect(account.reload.captain_agent_settings).to be_nil
      end
    end

    it 'rejects extra rule fields without echoing a supplied secret' do
      update_settings(custom_rules: [inbound_rule.merge(provider_token: 'private-provider-token')])

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['errors']).to include(include('field' => 'safety.custom_rules[0]', 'code' => 'unknown_fields'))
      expect(response.body).not_to include('private-provider-token')
    end

    it 'rejects the size limits of a rule and an inbound rewrite, and rolls back the rest of the same patch' do
      patch settings_path, params: { faq: { generate_from_resolved: true },
                                     safety: { custom_rules: [inbound_rule.merge(name: 'n' * 121),
                                                              inbound_rule.merge(id: 'rewrite', action: 'rewrite_once')] } },
                           headers: auth_headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['errors']).to include(
        include('field' => 'safety.custom_rules[0].name', 'code' => 'too_long'),
        include('field' => 'safety.custom_rules[1].action', 'code' => 'output_only')
      )
      expect(account.reload.captain_agent_settings).to be_nil
    end

    it 'applies the saved checks and rules at run time to every agent of the workspace' do
      agents = Array.new(2) { create(:captain_assistant, account: account) }
      update_settings(moderation_enabled: true, prompt_injection_action: 'flag', sensitive_info_action: 'off',
                      custom_rules: [inbound_rule, outbound_rule])
      expect(response).to have_http_status(:ok)

      agents.each do |agent|
        agent = Captain::Assistant.find(agent.id)
        engine = instance_double(Captain::Safety::CustomRulesStructuredOutputEngine, model: 'openai/gpt-6-luna', select: { rule_id: 'emergency' })
        input = Captain::Safety::CustomRulesEvaluator.new(engine: engine).evaluate(assistant: agent, direction: 'input', text: 'There is a fire!')

        expect(input).to have_attributes(status: :matched, rule_id: 'emergency', action: 'handoff', message: inbound_rule[:message])
        expect(engine).to have_received(:select).with(hash_including(direction: 'input', rules: [hash_including('id' => 'emergency')]))
        expect(Captain::AssistantSafetyPreferences.for(assistant: agent, feature: :assistant)).to include(
          'assistant_moderation' => true,
          'assistant_prompt_injection_guardrail' => 'flag',
          'assistant_sensitive_info_guardrail' => 'disabled'
        )
      end
    end

    it 'does not run a disabled rule' do
      update_settings(custom_rules: [outbound_rule])
      engine = instance_double(Captain::Safety::CustomRulesStructuredOutputEngine, model: 'openai/gpt-6-luna', select: { rule_id: 'no_promises' })

      agent = Captain::Assistant.find(assistant.id)
      output = Captain::Safety::CustomRulesEvaluator.new(engine: engine).evaluate(assistant: agent, direction: 'output', text: 'Guaranteed.')

      expect(output).to have_attributes(status: :allowed, reason: :no_enabled_rules)
      expect(engine).not_to have_received(:select)
    end
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
