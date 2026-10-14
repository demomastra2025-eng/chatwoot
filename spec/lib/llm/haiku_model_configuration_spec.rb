# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Claude Haiku 5.5 model configuration' do
  let(:model) { 'anthropic/claude-haiku-5.5' }
  let(:account) { create(:account) }
  let(:seed_allowlist) do
    YAML.safe_load_file(Rails.root.join('config/installation_config.yml'))
        .find { |config| config['name'] == 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST' }
        .fetch('value')
  end

  before do
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
    upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', seed_allowlist)
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return({})
    allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_metadata).and_return({})
  end

  it 'offers the exact model in both default lists while preserving the configured feature defaults' do
    expect(JSON.parse(seed_allowlist)).to eq(Llm::Models::DEFAULT_CURATED_MODELS)
    expect(Llm::Models.curated_model_names_for(:assistant, account: account)).to include(model)
    expect(Llm::Models.configured_default_model_for(:assistant)).to eq('openai/gpt-6-luna')
    expect(Llm::Models.configured_default_model_for(:outcome_classification)).to eq('inception/mercury-decide')
    expect(Llm::Models.configured_default_model_for(:custom_guardrail)).to eq('openai/gpt-6-luna-decisions')
  end

  it 'identifies the confirmed canonical model without claiming unsupported capabilities' do
    expect(Llm::Models.model_config(model)).to include(
      'id' => model, 'canonical_slug' => 'anthropic/claude-haiku-5.5-20261007',
      'provider' => 'openrouter', 'type' => 'chat', 'context_length' => 1_000_000, 'max_output_tokens' => 128_000
    )
    capabilities = Llm::Models.capabilities_for(model)
    expect(capabilities).to include('structured_output', 'tool_calling', 'tool_choice', 'reasoning')
    expect(capabilities).not_to include('streaming', 'audio_input', 'embedding', 'decision_classification')
  end

  it 'saves a newly selected agent model and resolves the same exact model after reloading' do
    assistant = create(:captain_assistant, account: account, config: { 'model' => model, 'thinking_effort' => 'high' })

    expect(assistant.reload.config).to include('model' => model, 'thinking_effort' => 'high')
    expect(assistant.resolved_agent_model).to eq(model)
  end

  it 'accepts Haiku when the administrator explicitly includes it in the allowed list' do
    result = Llm::InstallationModelConfig.normalize('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', seed_allowlist)

    expect(result).to be_valid
    expect(JSON.parse(result.value)).to include(model)
  end

  it 'preserves an administrator restriction that excludes Haiku' do
    upsert_installation_config('CAPTAIN_ASSISTANT_MODEL_ALLOWLIST', '["openai/gpt-6-luna"]')
    assistant = build(:captain_assistant, account: account, config: { 'model' => model })

    expect(Llm::Models.valid_model_for?(:assistant, model, account: account)).to be(true)
    expect(Llm::Models.curated_model_names_for(:assistant, account: account)).not_to include(model)
    expect(assistant).not_to be_valid
    expect(assistant.errors.of_kind?(:config, :assistant_model_not_allowed)).to be(true)
  end

  it 'does not let the added allowlist entry bypass missing provider credentials' do
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '')
    assistant = build(:captain_assistant, account: account, config: { 'model' => model })

    expect(Llm::Models.valid_model_for?(:assistant, model, account: account)).to be(false)
    expect(assistant).not_to be_valid
    expect(assistant.errors.of_kind?(:config, :assistant_model_not_allowed)).to be(true)
  end

  it 'rejects a refreshed model that no longer advertises agent tools instead of restoring static capabilities' do
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
      model => { 'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[text_input text_output],
                 'supported_parameters' => ['response_format'] }
    )
    assistant = build(:captain_assistant, account: account, config: { 'model' => model })

    expect(Llm::Models.capabilities_for(model)).not_to include('tool_calling', 'tool_choice')
    expect(Llm::Models.curated_model_names_for(:assistant, account: account)).not_to include(model)
    expect(assistant).not_to be_valid
    expect(assistant.errors.of_kind?(:config, :assistant_model_not_allowed)).to be(true)
  end

  it 'rejects provider endpoints without structured output even when the model lists it' do
    allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_metadata).with(model).and_return(
      'providers' => ['Limited Provider'],
      'endpoints' => [{ 'provider_name' => 'Limited Provider', 'supported_parameters' => %w[tools tool_choice reasoning] }]
    )

    result = Llm::OpenRouterCapabilityResolver.call(model_id: model, feature: :assistant, account: account)

    expect(result).not_to be_allowed
    expect(result.missing).to include('structured_output')
    expect(Llm::Models.curated_model_names_for(:assistant, account: account)).not_to include(model)
  end

  it 'requires a single provider endpoint to support all agent parameters' do
    allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_metadata).with(model).and_return(
      'endpoints' => [
        { 'provider_name' => 'Tools Provider', 'supported_parameters' => %w[tools tool_choice] },
        { 'provider_name' => 'JSON Provider', 'supported_parameters' => ['response_format'] }
      ]
    )

    expect(Llm::OpenRouterCapabilityResolver.call(model_id: model, feature: :assistant, account: account)).not_to be_allowed
  end

  it 'keeps zero data retention requirements enforced when endpoint metadata does not confirm them' do
    result = Llm::OpenRouterCapabilityResolver.call(
      model_id: model, feature: :assistant, account: account, runtime_preferences: { privacy_profile: 'zdr_required' }
    )

    expect(result).not_to be_allowed
    expect(result.reasons).to include(hash_including(code: 'zdr_required_unsupported'))
  end

  it 'exposes and compiles only the advertised effort levels while omitting sampling and parallel calls' do
    contract = Llm::ModelParameters.for(model, account: account)

    expect(Llm::Models.model_config(model).fetch('reasoning')).to include(
      'mandatory' => false, 'supported_efforts' => %w[max xhigh high medium low], 'default_effort' => 'medium'
    )
    expect(contract.metadata[:supports_temperature]).to be(false)
    expect(contract.reasoning_efforts).to include(*%w[max xhigh high medium low])
    expect(contract.compile(temperature: 0, thinking: { effort: 'high' }, params: { top_p: 0.5, parallel_tool_calls: true }))
      .to eq(thinking: { effort: 'high' }, params: { openrouter_omit_temperature: true })
    expect(contract.normalize_config('model' => model, 'temperature' => 0, 'thinking_effort' => 'high'))
      .to eq('model' => model, 'thinking_effort' => 'high')
  end

  it 'does not invent unsupported effort values from optional reasoning' do
    contract = Llm::ModelParameters.for(model, account: account)

    expect(Llm::Models.model_config(model).dig('reasoning', 'supported_efforts')).not_to include('none')
    %w[minimal unknown].each do |effort|
      expect(contract.reasoning_efforts).not_to include(effort)
      expect(contract.compile(thinking: { effort: effort })).not_to have_key(:thinking)
    end
  end

  it 'does not infer reasoning controls when refreshed metadata omits their supported values' do
    config = Llm::Models.model_config(model).except('reasoning').merge('source' => 'openrouter_api')
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(model => config)

    expect(Llm::Models.supports_thinking?(model)).to be(true)
    expect(Llm::Models.reasoning_efforts_for(model)).to eq([])
    expect(Llm::Models.supports_temperature?(model)).to be(false)
  end
end
