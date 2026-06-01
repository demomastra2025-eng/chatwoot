# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterPluginPolicy do
  it 'keeps only default allowed plugins and de-duplicates by id' do
    plugins = [
      { id: 'web' },
      { 'id' => 'response_healing' },
      { id: 'response-healing', configuration: { retry: true } },
      { id: 'apply_patch' }
    ]

    filtered = described_class.filter(
      plugins: plugins,
      default_allowed_ids: ['response-healing']
    )

    expect(filtered).to contain_exactly(id: 'response-healing')
  end

  it 'allows policy-listed plugins while keeping denied runtime plugins blocked' do
    plugins = [
      { id: 'context-compression', mode: 'emergency' },
      { id: 'openrouter:web_search' },
      { id: 'pareto_router' }
    ]

    filtered = described_class.filter(
      plugins: plugins,
      runtime_preferences: {
        openrouter_allowed_plugins: ['context_compression', 'openrouter:web_search', 'pareto_router']
      }
    )

    expect(filtered).to contain_exactly(id: 'context-compression', mode: 'emergency')
  end

  it 'normalizes raw string plugins without silently dropping allowed ids' do
    filtered = described_class.filter(
      plugins: ['response_healing', :web_search],
      default_allowed_ids: ['response-healing'],
      runtime_preferences: { openrouter_allowed_plugins: ['web_search'] }
    )

    expect(filtered).to contain_exactly(id: 'response-healing')
  end

  it 'does not let runtime preferences expand beyond the feature allowlist' do
    filtered = described_class.filter(
      plugins: [{ id: 'context_compression' }, { id: 'response_healing' }],
      runtime_preferences: { openrouter_allowed_plugins: %w[context_compression response_healing] },
      feature_allowed_ids: ['response-healing']
    )

    expect(filtered).to contain_exactly(id: 'response-healing')
  end

  it 'keeps unapproved OpenRouter plugins deferred and blocked even when runtime preferences request them' do
    filtered = described_class.filter(
      plugins: [{ id: 'pdf_inputs' }, { id: 'image_generation' }],
      runtime_preferences: { openrouter_allowed_plugins: %w[pdf_inputs image_generation] }
    )

    expect(filtered).to be_empty
    expect(described_class.deferred_extensions).to include(
      include(
        id: 'pdf-inputs',
        status: 'deferred',
        owner: 'ai-platform',
        admin_availability: 'locked'
      ),
      include(
        id: 'image-generation',
        status: 'deferred',
        owner: 'ai-platform',
        admin_availability: 'locked'
      )
    )
  end

  it 'exposes product metadata for allowed extensions by feature' do
    extensions = described_class.feature_extensions(:captain_agent)

    expect(extensions).to include(
      include(
        id: 'response-healing',
        product_label_key: 'structured_response_recovery',
        risk_level: 'low',
        default_mode: 'auto_for_non_streaming_structured_output'
      ),
      include(
        id: 'context-compression',
        product_label_key: 'long_context_protection',
        risk_level: 'medium',
        default_mode: 'overflow_only'
      ),
      include(
        id: 'openrouter:datetime',
        kind: 'server_tool',
        product_label_key: 'system_time'
      )
    )
  end
end
