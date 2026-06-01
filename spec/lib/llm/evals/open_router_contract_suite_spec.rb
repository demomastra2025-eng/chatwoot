# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::OpenRouterContractSuite do
  it 'passes all deterministic OpenRouter runtime contracts without network calls' do
    result = described_class.new.call

    expect(result.to_h).to include(
      suite_id: 'openrouter.contracts',
      total_count: 20,
      passed_count: 20,
      failed_count: 0,
      error_count: 0,
      status: 'pass'
    )
    expect(result.to_h[:cases]).to include(
      include(id: 'openrouter.tool_calling_contract', status: 'pass'),
      include(id: 'openrouter.structured_output_contract', status: 'pass'),
      include(id: 'openrouter.structured_output_recovery_contract', status: 'pass'),
      include(id: 'openrouter.plugin_policy_contract', status: 'pass'),
      include(id: 'openrouter.reasoning_contract', status: 'pass'),
      include(id: 'openrouter.routing_contract', status: 'pass'),
      include(id: 'openrouter.native_endpoint_contract', status: 'pass'),
      include(id: 'openrouter.embedding_contract', status: 'pass'),
      include(id: 'openrouter.multimodal_contract', status: 'pass'),
      include(id: 'openrouter.privacy_contract', status: 'pass'),
      include(id: 'openrouter.guardrail_status_contract', status: 'pass'),
      include(id: 'openrouter.guardrail_budget_contract', status: 'pass'),
      include(id: 'openrouter.feature_policy_contract', status: 'pass'),
      include(id: 'openrouter.feature_request_contract', status: 'pass'),
      include(id: 'openrouter.prompt_cache_contract', status: 'pass'),
      include(id: 'openrouter.context_compression_contract', status: 'pass'),
      include(id: 'openrouter.tool_result_requires_final_answer_contract', status: 'pass'),
      include(id: 'openrouter.zero_completion_recovery_contract', status: 'pass'),
      include(id: 'openrouter.fallback_model_contract', status: 'pass'),
      include(id: 'openrouter.native_reasoning_trace_contract', status: 'pass')
    )
  end
end
