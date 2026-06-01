# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterAdminOperations do
  it 'declares implemented and intentionally deferred OpenRouter admin operations' do
    result = described_class.call

    expect(result[:implemented]).to include(
      'key_health',
      'model_catalog_refresh',
      'endpoint_catalog_refresh'
    )
    expect(result[:deferred]).to include(
      'workspace_management',
      'remote_guardrail_sync',
      'remote_plugin_defaults',
      'provider_endpoint_manual_pinning'
    )
    expect(result[:operations]).to include(
      hash_including(
        id: 'remote_guardrail_sync',
        status: 'deferred',
        scope: 'superadmin',
        capabilities: include('guardrails', 'prompt_injection')
      )
    )
  end
end
