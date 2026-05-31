# frozen_string_literal: true

module Llm::Evals::OpenRouterContractGuardrailChecks
  EXPECTED_STANDARD_GUARDRAILS = {
    budget: 'workspace_required',
    provider: 'routing_profile_enforced',
    model: 'capability_resolver_enforced',
    prompt_injection: 'local_enforced',
    pii: 'local_enforced'
  }.freeze
  EXPECTED_SENSITIVE_TRACE_CAPTURE = { input: false, output: false, policy: false }.freeze
  EXPECTED_ZDR_PROVIDER = { data_collection: 'deny', zdr: true, allow_fallbacks: false }.freeze
  EXPECTED_ZDR_GUARDRAILS = { zdr: 'provider_required' }.freeze

  private

  def openrouter_guardrail_status_contract
    actual = guardrail_status_actual
    expected = guardrail_status_expected

    actual.merge(expected: expected, failures: guardrail_status_failures(actual, expected))
  end

  def guardrail_status_actual
    sensitive_preferences = sensitive_trace_preferences
    sensitive_policy = Llm::OpenRouterWorkspacePolicy.resolve(preferences: sensitive_preferences, workspace: 'production')
    zdr_policy = Llm::OpenRouterWorkspacePolicy.resolve(privacy_profile: 'zdr_required', workspace: 'production')

    {
      standard_guardrails: guardrail_statuses(Llm::OpenRouterWorkspacePolicy.resolve(workspace: 'production')),
      sensitive_trace_capture: sensitive_trace_capture_status(sensitive_preferences, sensitive_policy),
      zdr_provider: zdr_policy.provider_preferences,
      zdr_guardrails: guardrail_statuses(zdr_policy)
    }
  end

  def guardrail_status_expected
    {
      standard_guardrails: EXPECTED_STANDARD_GUARDRAILS,
      sensitive_trace_capture: EXPECTED_SENSITIVE_TRACE_CAPTURE,
      zdr_provider: EXPECTED_ZDR_PROVIDER,
      zdr_guardrails: EXPECTED_ZDR_GUARDRAILS
    }
  end

  def sensitive_trace_preferences
    {
      privacy_profile: 'sensitive',
      trace_input_capture: true,
      trace_output_capture: true
    }
  end

  def sensitive_trace_capture_status(preferences, policy)
    {
      input: Llm::RuntimePolicy.trace_input_capture?(preferences: preferences),
      output: Llm::RuntimePolicy.trace_output_capture?(preferences: preferences),
      policy: policy.trace_capture_allowed?
    }
  end

  def guardrail_statuses(policy)
    policy.guardrails.transform_values { |guardrail| guardrail.fetch(:status) }
  end

  def guardrail_status_failures(actual, expected)
    failure_messages(actual[:standard_guardrails], expected[:standard_guardrails], 'guardrail status') +
      failure_messages(actual[:sensitive_trace_capture], expected[:sensitive_trace_capture], 'sensitive trace capture') +
      failure_messages(actual[:zdr_provider], expected[:zdr_provider], 'ZDR provider') +
      failure_messages(actual[:zdr_guardrails], expected[:zdr_guardrails], 'ZDR guardrail status')
  end

  def failure_messages(actual, expected, label)
    expected.filter_map do |key, value|
      next if actual[key] == value

      "#{label} #{key} must be #{value}"
    end
  end
end
