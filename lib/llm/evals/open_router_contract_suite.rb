# frozen_string_literal: true

class Llm::Evals::OpenRouterContractSuite
  include Llm::Evals::OpenRouterContractRuntimeChecks
  include Llm::Evals::OpenRouterContractPolicyChecks
  include Llm::Evals::OpenRouterContractCapabilityChecks
  include Llm::Evals::OpenRouterContractGuardrailChecks

  SUITE_ID = 'openrouter.contracts'
  CASES = [
    {
      id: 'openrouter.tool_calling_contract',
      description: 'Tool flows require provider parameters and never use price sorting.',
      tags: %w[openrouter tools routing]
    },
    {
      id: 'openrouter.structured_output_contract',
      description: 'Structured output uses require_parameters and response healing when streaming is off.',
      tags: %w[openrouter structured_output response_healing]
    },
    {
      id: 'openrouter.plugin_policy_contract',
      description: 'Caller-supplied plugins are filtered through product policy and unsafe OpenRouter tools stay denied.',
      tags: %w[openrouter plugins guardrails]
    },
    {
      id: 'openrouter.reasoning_contract',
      description: 'Reasoning requests preserve reasoning params and require provider parameter support.',
      tags: %w[openrouter reasoning]
    },
    {
      id: 'openrouter.routing_contract',
      description: 'Exacto and Auto Exacto provider order map to strict and fallback routing.',
      tags: %w[openrouter routing exacto]
    },
    {
      id: 'openrouter.native_endpoint_contract',
      description: 'Embedding, audio transcription, and rerank features use OpenRouter native endpoints.',
      tags: %w[openrouter embeddings audio rerank]
    },
    {
      id: 'openrouter.embedding_contract',
      description: 'Embedding vectors must match the OneLink vector index dimensions and reject mismatched responses.',
      tags: %w[openrouter embeddings dimensions]
    },
    {
      id: 'openrouter.multimodal_contract',
      description: 'Image and audio features require the correct OpenRouter model capabilities before runtime use.',
      tags: %w[openrouter multimodal image audio]
    },
    {
      id: 'openrouter.privacy_contract',
      description: 'ZDR privacy profile denies data collection and disables fallbacks.',
      tags: %w[openrouter privacy zdr]
    },
    {
      id: 'openrouter.guardrail_status_contract',
      description: 'Workspace guardrail diagnostics stay explicit and sensitive/ZDR traces stay suppressed.',
      tags: %w[openrouter guardrails privacy diagnostics]
    },
    {
      id: 'openrouter.guardrail_budget_contract',
      description: 'Workspace budget guardrail stays explicit and guarded profiles compile provider safety preferences.',
      tags: %w[openrouter guardrails budget]
    },
    {
      id: 'openrouter.feature_request_contract',
      description: 'FeatureRequest preserves multimodal detection and mutating-tool safety guards.',
      tags: %w[openrouter feature_request multimodal tools]
    },
    {
      id: 'openrouter.prompt_cache_contract',
      description: 'FeatureRequest and compiler emit stable session IDs for OpenRouter prompt caching and routing.',
      tags: %w[openrouter prompt_cache routing]
    }
  ].freeze

  def call
    Llm::Evals::Result.new(
      suite_id: SUITE_ID,
      prompt_id: nil,
      prompt_sha: nil,
      model: nil,
      cases: CASES.map { |contract_case| evaluate_case(contract_case) }
    )
  end

  private

  def evaluate_case(contract_case)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    actual = send(contract_case[:id].tr('.', '_'))
    failures = Array(actual.delete(:failures))

    {
      id: contract_case[:id],
      description: contract_case[:description],
      tags: contract_case[:tags],
      status: failures.empty? ? 'pass' : 'fail',
      expected: actual.delete(:expected),
      actual: actual,
      failures: failures,
      duration_ms: elapsed_ms(started_at)
    }.compact
  rescue StandardError => e
    error_case_result(contract_case, e, started_at)
  end

  def error_case_result(contract_case, error, started_at)
    {
      id: contract_case[:id],
      description: contract_case[:description],
      tags: contract_case[:tags],
      status: 'error',
      actual: { error: "#{error.class.name}: #{error.message}" },
      failures: ['runtime_error'],
      duration_ms: elapsed_ms(started_at)
    }
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
