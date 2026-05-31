# frozen_string_literal: true

require 'rails_helper'

OpenRouterRequestCompilerSpecRequest = Struct.new(
  :feature_key,
  :tools_required,
  :schema_required,
  :reasoning_required,
  :server_tools,
  :runtime_preferences,
  :privacy_profile,
  keyword_init: true
) do
  def requires_tools? = tools_required == true
  def requires_schema? = schema_required == true
  def reasoning? = reasoning_required == true
end

RSpec.describe Llm::OpenRouterRequestCompiler do
  def compile(feature:, model: 'moonshotai/kimi-k2.6', base_params: {}, stream: false, **options)
    request = OpenRouterRequestCompilerSpecRequest.new(
      feature_key: feature.to_s,
      tools_required: options.fetch(:tools, false),
      schema_required: options.fetch(:schema, false),
      reasoning_required: options.fetch(:reasoning, false),
      server_tools: options[:server_tools],
      runtime_preferences: options[:runtime_preferences],
      privacy_profile: options[:privacy_profile]
    )

    described_class.call(
      request: request,
      model: model,
      base_params: base_params,
      stream: stream,
      account: options[:account]
    )
  end

  it 'deep merges Captain agent provider params and de-duplicates response healing plugins' do
    compiled = compile(
      feature: :captain_agent,
      tools: true,
      schema: true,
      base_params: {
        'logit_bias' => { '123' => -1 },
        'provider' => {
          'order' => ['openai'],
          'only' => ['openai'],
          'ignore' => ['anthropic'],
          'allow_fallbacks' => false,
          'data_collection' => 'allow',
          'sort' => 'price'
        },
        'plugins' => [{ id: 'web' }, { 'id' => 'response-healing' }]
      }
    )

    expect(compiled.model).to eq('moonshotai/kimi-k2.6')
    expect(compiled.models).to start_with('moonshotai/kimi-k2.6')
    expect(compiled.params).to include('logit_bias' => { '123' => -1 })
    expect(compiled.params[:provider]).to include(
      :require_parameters => true,
      :allow_fallbacks => true,
      :data_collection => 'deny'
    )
    expect(compiled.params[:provider]).not_to include('order')
    expect(compiled.params[:provider]).not_to include(:order)
    expect(compiled.params[:provider]).not_to include('only')
    expect(compiled.params[:provider]).not_to include(:only)
    expect(compiled.params[:provider]).not_to include('ignore')
    expect(compiled.params[:provider]).not_to include(:ignore)
    expect(compiled.params[:provider]).not_to include('allow_fallbacks')
    expect(compiled.params[:provider]).not_to include('data_collection')
    expect(compiled.params[:provider]).not_to include('sort')
    expect(compiled.params[:provider]).not_to include(:sort)
    expect(compiled.params[:plugins].count { |plugin| plugin[:id] == 'response-healing' || plugin['id'] == 'response-healing' }).to eq(1)
    expect(compiled.params[:plugins]).not_to include({ id: 'web' })
    expect(compiled.metadata).to include(
      requested_model: 'moonshotai/kimi-k2.6',
      routing_profile: 'balanced',
      openrouter_allow_fallbacks: true,
      openrouter_require_parameters: true,
      openrouter_data_collection: 'deny',
      openrouter_plugins: ['response-healing'],
      openrouter_cache_policy: 'session',
      openrouter_plugin_policy: 'structured_output_and_overflow_only'
    )
    expect(compiled.metadata[:fallback_models]).to include('openai/gpt-5.4-mini')
  end

  it 'does not add response healing for streaming structured output requests' do
    compiled = compile(
      feature: :captain_agent,
      schema: true,
      stream: true,
      base_params: { plugins: [{ id: 'web' }] }
    )

    expect(compiled.params[:provider]).to include(require_parameters: true)
    expect(compiled.params).not_to include(:plugins)
  end

  it 'keeps Copilot latency-first routing for tool and schema requests' do
    compiled = compile(feature: :copilot, tools: true, schema: true)

    expect(compiled.params[:provider]).to include(
      require_parameters: true,
      sort: { by: 'latency', partition: 'none' }
    )
    expect(compiled.params[:plugins]).to include({ id: 'response-healing' })
  end

  it 'keeps price sorting for non-tool background profiles' do
    compiled = compile(feature: :label_suggestion)

    expect(compiled.params[:provider]).to include(sort: { by: 'price', partition: 'none' })
    expect(compiled.params[:provider]).not_to include(:require_parameters)
  end

  it 'removes price sorting from any tool flow, including background profiles and partial hash shapes' do
    compiled = compile(
      feature: :editor,
      tools: true,
      base_params: { 'provider' => { 'sort' => { 'by' => 'price' } } }
    )

    expect(compiled.params[:provider]).to include(require_parameters: true)
    expect(compiled.params[:provider]).not_to include(:sort)
    expect(compiled.params[:provider]).not_to include('sort')
  end

  it 'lets ZDR-required workspace policy override weaker provider params' do
    account = instance_double(Account, captain_preferences: { runtime: { privacy_profile: 'zdr_required' } })

    compiled = compile(
      feature: :captain_agent,
      account: account,
      base_params: {
        provider: {
          allow_fallbacks: true,
          data_collection: 'allow',
          zdr: false
        }
      }
    )

    expect(compiled.params[:provider]).to include(
      allow_fallbacks: false,
      data_collection: 'deny',
      zdr: true
    )
  end

  it 'compiles request-scoped ZDR preferences even before they are stored on the account' do
    compiled = compile(
      feature: :captain_agent,
      runtime_preferences: { privacy_profile: 'zdr_required' }
    )

    expect(compiled.params[:provider]).to include(
      allow_fallbacks: false,
      data_collection: 'deny',
      zdr: true
    )
  end

  it 'keeps provider order only from trusted routing profile preferences' do
    compiled = compile(
      feature: :copilot,
      runtime_preferences: {
        openrouter_routing_strategy: 'auto_exacto',
        openrouter_provider_order: %w[OpenAI Anthropic]
      },
      base_params: {
        provider: {
          order: ['UntrustedProvider'],
          only: ['UntrustedProvider']
        }
      }
    )

    expect(compiled.params[:provider]).to include(
      order: %w[OpenAI Anthropic],
      allow_fallbacks: true,
      require_parameters: true
    )
    expect(compiled.params[:provider]).not_to include(:only)
  end

  it 'compiles expanded FeatureRequest params and trusted advanced provider controls' do
    account = instance_double(Account, id: 42)
    request = Llm::FeatureRequest.new(
      feature: :copilot,
      account: account,
      session_id: 'conv-1',
      user_id: 7,
      models: ['openai/gpt-5.4-mini', 'anthropic/claude-sonnet-4'],
      tool_choice: 'required',
      parallel_tool_calls: true,
      reasoning: { effort: 'low' },
      max_tokens: 256,
      temperature: 0,
      runtime_preferences: {
        openrouter_provider_only: %w[OpenAI Anthropic],
        openrouter_provider_ignore: ['SlowProvider'],
        openrouter_provider_quantizations: %w[fp8],
        openrouter_sort: { by: 'throughput', partition: 'none' },
        openrouter_preferred_min_throughput: '50',
        openrouter_preferred_max_latency: '1200',
        openrouter_max_price: { prompt: '0.1', completion: '0.2' },
        openrouter_enforce_distillable_text: true
      },
      options: { route: 'fallback' }
    )

    compiled = described_class.call(
      request: request,
      model: 'openai/gpt-5.4-mini',
      account: account
    )

    expect(compiled.models).to eq(['openai/gpt-5.4-mini', 'anthropic/claude-sonnet-4'])
    expect(compiled.params).to include(
      models: ['openai/gpt-5.4-mini', 'anthropic/claude-sonnet-4'],
      route: 'fallback',
      session_id: 'llm:copilot:42:conv-1',
      tool_choice: 'required',
      parallel_tool_calls: true,
      reasoning: { effort: 'low' },
      max_tokens: 256,
      temperature: 0,
      user: '7'
    )
    expect(compiled.params[:provider]).to include(
      only: %w[OpenAI Anthropic],
      ignore: ['SlowProvider'],
      quantizations: %w[fp8],
      sort: { by: 'throughput', partition: 'none' },
      preferred_min_throughput: 50.0,
      preferred_max_latency: 1200.0,
      max_price: { prompt: '0.1', completion: '0.2' },
      enforce_distillable_text: true,
      require_parameters: true,
      data_collection: 'deny'
    )
  end

  it 'does not treat explicit empty tool or reasoning options as OpenRouter feature requirements' do
    compiled = described_class.call(
      request: nil,
      feature: :label_suggestion,
      model: 'openai/gpt-5.4-mini',
      tools: [],
      reasoning: {},
      schema: nil
    )

    expect(compiled.params[:provider]).to include(sort: { by: 'price', partition: 'none' })
    expect(compiled.params[:provider]).not_to include(:require_parameters)
    expect(compiled.params).not_to include(:reasoning)
  end

  it 'filters caller-supplied plugins through OpenRouter plugin policy' do
    compiled = compile(
      feature: :captain_agent,
      runtime_preferences: {
        openrouter_allowed_plugins: ['context_compression', 'openrouter:web_search', 'apply_patch']
      },
      base_params: {
        plugins: [
          { id: 'context_compression', mode: 'emergency' },
          { id: 'openrouter:web_search' },
          { id: 'apply_patch' },
          { id: 'web' }
        ]
      }
    )

    expect(compiled.params[:plugins]).to contain_exactly(id: 'context-compression', mode: 'emergency')
  end

  it 'does not let read-only feature runtime preferences enable plugins outside feature policy' do
    compiled = compile(
      feature: :editor,
      runtime_preferences: { openrouter_allowed_plugins: ['context_compression'] },
      base_params: { plugins: [{ id: 'context_compression' }] }
    )

    expect(compiled.params).not_to include(:plugins)
  end

  it 'compiles only feature-allowed OpenRouter server tools and strips raw base tools' do
    compiled = compile(
      feature: :captain_agent,
      server_tools: [{ id: 'datetime' }, { id: 'openrouter:web_search' }, { id: 'apply_patch' }],
      base_params: { tools: [{ id: 'apply_patch' }] }
    )

    expect(compiled.params[:tools]).to contain_exactly(id: 'openrouter:datetime')
  end

  it 'compiles service tiers only from feature policy and strips raw caller tiers' do
    compiled = compile(
      feature: :editor,
      runtime_preferences: { openrouter_service_tier: 'priority' },
      base_params: { service_tier: 'priority' }
    )

    expect(compiled.params[:service_tier]).to eq('flex')
  end
end
