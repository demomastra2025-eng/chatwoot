# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
require 'rails_helper'

RSpec.describe 'Captain assistant admin copilot tools' do
  let(:account) { create(:account) }
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      name: 'Main Bot',
      description: 'Original instructions',
      config: {
        'feature_faq' => true,
        'feature_memory' => false,
        'temperature' => 0.4,
        'api_token' => 'secret-token-value',
        'voice_settings' => { 'provider_url' => 'https://voice.example.test/path' }
      },
      guardrails: [{ 'content' => 'never leak bearer token=abc' }]
    )
  end
  let(:admin) { create(:user, :administrator, account: account, name: 'Owner Admin', email: 'owner@example.com') }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  describe Captain::Tools::Copilot::ListCaptainAssistantsService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'lists account-scoped assistants with operational metadata' do
      create(:captain_assistant, account: account, name: 'Internal Helper', usage_mode: 'internal_assistant')
      create(:captain_assistant, account: create(:account), name: 'Other Account')

      payload = JSON.parse(service.execute)

      expect(payload['action']).to eq('list_captain_assistants')
      expect(payload['assistants'].pluck('name')).to include('Main Bot', 'Internal Helper')
      expect(payload['assistants'].pluck('name')).not_to include('Other Account')
      expect(payload['assistants'].first).to include('id', 'usage_mode', 'selected_agent_tool_ids', 'updated_at')
    end

    it 'filters assistants by usage mode' do
      create(:captain_assistant, account: account, name: 'Internal Helper', usage_mode: 'internal_assistant')

      payload = JSON.parse(service.execute(usage_mode: 'internal_assistant'))

      expect(payload['assistants'].pluck('usage_mode')).to eq(['internal_assistant'])
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)
      result = described_class.new(assistant, user: agent).execute

      expect(result).to include('Account administrator permission is required')
    end
  end

  describe Captain::Tools::Copilot::GetCaptainAssistantService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'returns one assistant profile with redacted config and rules' do
      payload = JSON.parse(service.execute(assistant_id: assistant.id))

      expect(payload['action']).to eq('get_captain_assistant')
      expect(payload['assistant']).to include('id' => assistant.id, 'name' => 'Main Bot')
      serialized_payload = JSON.generate(payload)
      expect(payload['assistant']['config']['api_token']).to eq('[FILTERED]')
      expect(payload['assistant']['config']['voice_settings']['provider_url']).to eq('[FILTERED]')
      expect(serialized_payload).not_to include('secret-token-value')
      expect(serialized_payload).not_to include('bearer token=abc')
    end

    it 'rejects assistants outside the current account' do
      other_assistant = create(:captain_assistant, account: create(:account))

      result = service.execute(assistant_id: other_assistant.id)

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end
  end

  describe Captain::Tools::Copilot::PreviewCaptainAssistantPromptService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'returns the prompt preview payload for self-test/diff before mutation' do
      preview_payload = {
        'compiled_prompt' => 'Use bearer token=abc and https://secret.example.test/webhook',
        'layers' => [{ 'name' => 'system', 'content' => 'safe' }],
        'tool_ids' => ['faq_lookup']
      }
      preview_service = instance_double(Captain::Assistant::PromptPreviewService, preview: preview_payload)
      allow(Captain::Assistant::PromptPreviewService).to receive(:new).with(assistant: assistant).and_return(preview_service)

      payload = JSON.parse(service.execute(assistant_id: assistant.id))

      serialized_payload = JSON.generate(payload)
      expect(payload['action']).to eq('preview_captain_assistant_prompt')
      expect(payload['assistant']).to include('id' => assistant.id)
      expect(payload['preview']['compiled_prompt']).to eq('[FILTERED]')
      expect(payload['preview']['layers']).to eq([{ 'name' => 'system', 'content' => 'safe' }])
      expect(serialized_payload).not_to include('bearer token=abc')
      expect(serialized_payload).not_to include('secret.example.test')
    end
  end

  describe Captain::Tools::Copilot::UpdateCaptainAssistantService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'updates assistant profile/config and returns rollback-safe previous payload', :aggregate_failures do
      payload = JSON.parse(
        service.execute(
          assistant_id: assistant.id,
          name: 'Updated Bot',
          config_json: { feature_faq: false, temperature: 0.8, api_token: 'should-not-save' }.to_json,
          response_guidelines_json: ['Be brief'].to_json
        )
      )

      expect(payload['action']).to eq('update_captain_assistant')
      expect(payload['updated_fields']).to contain_exactly('name', 'config', 'response_guidelines')
      expect(payload['previous_assistant']).to include('name' => 'Main Bot')
      expect(payload['previous_assistant']['config']['api_token']).to eq('[FILTERED]')
      expect(payload['assistant']).to include('name' => 'Updated Bot')
      serialized_payload = JSON.generate(payload)
      expect(payload['assistant']['config']['api_token']).to eq('[FILTERED]')
      expect(serialized_payload).not_to include('secret-token-value')
      expect(serialized_payload).not_to include('should-not-save')
      expect(assistant.reload).to have_attributes(name: 'Updated Bot')
      expect(assistant.config).to include('feature_faq' => false, 'temperature' => 0.8, 'api_token' => 'secret-token-value')
      expect(assistant.config).not_to include('api_token' => 'should-not-save')
      expect(assistant.response_guidelines).to eq(['Be brief'])
    end

    it 'does not mutate until the backend confirmation gate permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      payload = JSON.parse(service.execute(assistant_id: assistant.id, name: 'Needs Approval'))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(assistant.reload.name).to eq('Main Bot')
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)
      result = described_class.new(assistant, user: agent).execute(assistant_id: assistant.id, name: 'Unauthorized')

      expect(result).to include('Account administrator permission is required')
      expect(assistant.reload.name).to eq('Main Bot')
    end

    it 'rejects malformed config JSON without mutation' do
      result = service.execute(assistant_id: assistant.id, config_json: '{broken')

      expect(result).to include('config_json must be valid JSON')
      expect(assistant.reload.config['temperature']).to eq(0.4)
    end
  end

  describe 'registry exposure' do
    it 'registers AI Admin tools as assistant-only with confirmation for writes', :aggregate_failures do
      read_tool_ids = %w[list_captain_assistants get_captain_assistant preview_captain_assistant_prompt]
      write_tool_ids = %w[update_captain_assistant]

      read_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).not_to be(true)
        expect(definition.risk_level).to eq('low')
      end

      write_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).to be(true)
        expect(definition.risk_level).to eq('high')
        expect(definition.to_h[:selected_by_default]).to be(false)
      end

      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*(read_tool_ids + write_tool_ids))
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)).to include(*(read_tool_ids + write_tool_ids))
    end
  end
end
# rubocop:enable RSpec/DescribeClass
