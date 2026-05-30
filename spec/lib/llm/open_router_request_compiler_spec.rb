# frozen_string_literal: true

require 'rails_helper'

OpenRouterRequestCompilerSpecRequest = Struct.new(:feature_key, :tools_required, :schema_required, :reasoning_required, keyword_init: true) do
  def requires_tools? = tools_required == true
  def requires_schema? = schema_required == true
  def reasoning? = reasoning_required == true
end

RSpec.describe Llm::OpenRouterRequestCompiler do
  def compile(feature:, model: 'moonshotai/kimi-k2.6', base_params: {}, stream: false, tools: false, schema: false, reasoning: false)
    request = OpenRouterRequestCompilerSpecRequest.new(
      feature_key: feature.to_s,
      tools_required: tools,
      schema_required: schema,
      reasoning_required: reasoning
    )

    described_class.call(
      request: request,
      model: model,
      base_params: base_params,
      stream: stream
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
      'order' => ['openai'],
      :require_parameters => true,
      :allow_fallbacks => true,
      :data_collection => 'deny'
    )
    expect(compiled.params[:provider]).not_to include('allow_fallbacks')
    expect(compiled.params[:provider]).not_to include('data_collection')
    expect(compiled.params[:provider]).not_to include('sort')
    expect(compiled.params[:provider]).not_to include(:sort)
    expect(compiled.params[:plugins].count { |plugin| plugin[:id] == 'response-healing' || plugin['id'] == 'response-healing' }).to eq(1)
    expect(compiled.params[:plugins]).to include({ id: 'web' })
  end

  it 'does not add response healing for streaming structured output requests' do
    compiled = compile(
      feature: :captain_agent,
      schema: true,
      stream: true,
      base_params: { plugins: [{ id: 'web' }] }
    )

    expect(compiled.params[:provider]).to include(require_parameters: true)
    expect(compiled.params[:plugins]).to contain_exactly({ id: 'web' })
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
end
