# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterFeaturePolicy do
  it 'declares Captain feature policy with explicit server-tool, plugin, variant, budget, and guardrail status' do
    policy = described_class.for(feature: :assistant)

    expect(policy.feature_key).to eq('captain_agent')
    expect(policy.allowed_plugins).to include('response-healing', 'context-compression')
    expect(policy.allowed_server_tools).to eq(['openrouter:datetime'])
    expect(policy.allowed_variants).to include('exacto', 'extended', 'thinking')
    expect(policy.cache_policy).to eq('session')
    expect(policy.budget_policy).to eq('local_ledger_hard_stop')
    expect(policy.guardrails).to include(
      plugins: include(status: 'allowlist_enforced'),
      server_tools: include(status: 'allowlist_enforced'),
      prompt_injection: include(status: 'evaluation_required'),
      pii: include(status: 'evaluation_required')
    )
  end

  it 'keeps read-only background features blocked-by-default for plugins and server tools' do
    policy = described_class.for(feature: :editor)

    expect(policy.allowed_plugins).to be_empty
    expect(policy.allowed_server_tools).to be_empty
    expect(policy.cache_policy).to eq('read_only')
    expect(policy.compiled_service_tier).to eq('flex')
    expect(policy.guardrails).to include(
      plugins: include(status: 'blocked_by_default'),
      server_tools: include(status: 'blocked_by_default')
    )
  end

  it 'filters requested server tools through the feature allowlist and blocks apply_patch' do
    policy = described_class.for(feature: :captain_agent)
    tools = [
      { id: 'datetime', api_key: 'must-not-pass' },
      { id: 'openrouter:web_search' },
      { id: 'apply_patch' }
    ]

    expect(policy.filter_server_tools(tools)).to contain_exactly(id: 'openrouter:datetime')
  end

  it 'does not let runtime preferences upgrade a feature beyond its service-tier allowlist' do
    editor_policy = described_class.for(feature: :editor, runtime_preferences: { openrouter_service_tier: 'priority' })
    captain_policy = described_class.for(feature: :captain_agent, runtime_preferences: { openrouter_service_tier: 'priority' })

    expect(editor_policy.compiled_service_tier).to eq('flex')
    expect(captain_policy.compiled_service_tier).to eq('priority')
  end

  it 'intersects runtime variant preferences with the feature variant allowlist' do
    policy = described_class.for(
      feature: :captain_agent,
      runtime_preferences: { openrouter_variant_policy: %w[exacto free online] }
    )

    expect(policy.allowed_variants).to eq(['exacto'])
  end

  it 'inherits ZDR workspace policy in per-feature privacy diagnostics' do
    policy = described_class.for(feature: :captain_agent, runtime_preferences: { privacy_profile: 'zdr_required' })

    expect(policy.privacy_profile).to eq('zdr_required')
    expect(policy.guardrails[:privacy]).to include(status: 'zdr_fail_closed')
  end
end
