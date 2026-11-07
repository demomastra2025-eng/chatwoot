# frozen_string_literal: true

# Pure compiler regression: run with --options /dev/null, without rails_helper or a database.
require 'rspec/core'
require 'rspec/expectations'
require 'rspec/mocks'
require 'active_support'
require 'active_support/core_ext'
require 'active_model'

module Llm; end unless defined?(Llm)

require_relative '../../../lib/llm/open_router_workspace_policy'
require_relative '../../../lib/llm/open_router_routing_profile'
require_relative '../../../lib/llm/open_router_request_compiler'
require_relative '../../../lib/llm/feature_request'
require_relative '../../../lib/llm/runtime'
require_relative '../../../lib/llm/open_router_runtime'

# Pure boundary doubles avoid booting the Rails-backed catalog, headers and event persistence.
# rubocop:disable RSpec/VerifiedDoubles
RSpec.describe Llm::OpenRouterRequestCompiler do
  before do
    stub_const('Llm::Models', double(ensure_active_model!: nil))
    stub_const('Llm::FeatureProfile', double(decision_feature?: false, supported?: true))
    allow(Llm::FeatureProfile).to receive(:normalize_feature, &:to_s)
    stub_const('Llm::OpenRouterHeaders', double(build: double(headers: {}, metadata: {})))
    patch = Module.new
    patch.const_set(:OMIT_TEMPERATURE_PARAM, :openrouter_omit_temperature)
    stub_const('Llm::OpenRouterServerToolsPatch', patch)
  end

  def compile(feature: 'audio_transcription', privacy: 'standard', preferences: {}, base_params: {}, **flags)
    request = double(
      feature_key: feature, privacy_profile: privacy, runtime_preferences: preferences, options: {},
      requires_tools?: false, tools: [], requires_schema?: false, reasoning?: false
    )
    compiler = described_class.new(
      request: request, model: 'google/gemini-3.8-flash', base_params: base_params, stream: false,
      account: nil, feature: feature, schema: false, tools: nil, reasoning: false,
      trusted_provider_params: false, **flags
    )
    isolate_collaborators(compiler, privacy)
    compiler.call
  end

  def isolate_collaborators(compiler, privacy)
    policy = double(
      privacy_profile: privacy, workspace_policy: Llm::OpenRouterWorkspacePolicy.resolve(privacy_profile: privacy),
      compiled_service_tier: nil, guardrail_profile: 'native_transcription_only', cache_policy: 'disabled',
      plugin_policy: 'disabled', transform_policy: 'disabled', budget_policy: 'workspace_required',
      filter_plugins: [], filter_server_tools: []
    )
    # Exclude unrelated catalog, transform and parallel-tool collaborators; provider merging stays real.
    allow(compiler).to receive(:openrouter_feature_policy).and_return(policy)
    allow(compiler).to receive(:context_transform_plan).and_return(nil)
    allow(compiler).to receive(:apply_parallel_tool_call_params!)
    compiler
  end

  it 'keeps the real ASR envelope non-strict with nested minimal reasoning parameters' do
    account = double(id: 1, captain_runtime: {})
    attributes = {
      feature: :audio_transcription, account: account,
      model: 'google/gemini-3.8-flash',
      options: { temperature: 0.1, params: { reasoning: { effort: 'minimal' } } }
    }
    request = Llm::Runtime.send(:build_request, **attributes)
    expect(request.requires_tools?).to be(false)
    expect(request.reasoning_requested?).to be(false)
    expect(request.options.dig(:params, :reasoning, :effort)).to eq('minimal')

    stub_const('Llm::EventBus', double)
    allow(Llm::EventBus).to receive(:publish) { |_name, _payload, &block| block.call({}) }
    allow(described_class).to receive(:new).and_wrap_original do |constructor, **kwargs|
      expect(kwargs).to include(tools: false, reasoning: false)
      isolate_collaborators(constructor.call(**kwargs), request.privacy_profile)
    end
    compiled = Llm::OpenRouterRuntime.new.send(:compiled_chat_request, request, request.model)

    expect(compiled.params[:reasoning]).to eq(effort: 'minimal')
    expect(compiled.params[:provider]).not_to have_key(:require_parameters)
    expect(compiled.params[:provider]).to include(data_collection: 'deny', zdr: true)
  end

  %w[standard sensitive zdr_required].each do |privacy|
    it "keeps ASR's non-strict route for tools:false with #{privacy} privacy" do
      compiled = compile(privacy: privacy, tools: false)

      expect(compiled.params[:provider]).not_to have_key(:require_parameters)
      expect(compiled.params[:provider]).to include(data_collection: 'deny', zdr: true)
      expect(compiled.params[:provider][:allow_fallbacks]).to eq(privacy != 'zdr_required')
      expect(compiled.models).to eq(['google/gemini-3.8-flash'])
      expect(compiled.metadata[:openrouter_require_parameters]).to be_nil
    end
  end

  [nil, []].each do |tools|
    it "keeps no-tools ASR non-strict for #{tools.inspect}" do
      expect(compile(tools: tools).params[:provider]).not_to have_key(:require_parameters)
    end
  end

  [true, [Object.new]].each do |tools|
    it "requires parameters for #{tools == true ? 'tools:true' : 'actual tools'}" do
      expect(compile(tools: tools).params[:provider]).to include(require_parameters: true, data_collection: 'deny', zdr: true)
    end
  end

  it 'preserves an explicit caller requirement when tools are false' do
    result = compile(tools: false, base_params: { provider: { require_parameters: true } })

    expect(result.params[:provider]).to include(require_parameters: true, data_collection: 'deny', zdr: true)
  end

  it 'preserves an explicit runtime profile requirement when tools are false' do
    result = compile(tools: false, preferences: { openrouter_require_parameters: true })

    expect(result.params[:provider]).to include(require_parameters: true, data_collection: 'deny', zdr: true)
  end

  %w[captain_agent embedding].each do |feature|
    it "preserves the strict #{feature} profile with tools:false" do
      expect(compile(feature: feature, tools: false).params[:provider])
        .to include(require_parameters: true, data_collection: 'deny', zdr: true)
    end
  end

  it 'preserves an explicit schema requirement with tools:false' do
    expect(compile(tools: false, schema: true).params[:provider]).to include(require_parameters: true, data_collection: 'deny', zdr: true)
  end

  it 'preserves an explicit reasoning requirement with tools:false' do
    expect(compile(tools: false, reasoning: true).params[:provider]).to include(require_parameters: true, data_collection: 'deny', zdr: true)
  end
end
# rubocop:enable RSpec/VerifiedDoubles
