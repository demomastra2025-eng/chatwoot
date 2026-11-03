# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::CouncilModelChain do
  let(:split_models) { %w[deepseek/deepseek-v4.1-flash qwen/qwen3.7-flash openai/gpt-6-luna google/gemini-2.5-flash-lite] }
  let(:edit_models) { %w[google/gemini-2.5-flash-lite deepseek/deepseek-v4.1-flash qwen/qwen3.7-flash openai/gpt-6-luna] }

  def chain(feature: :council_split, **)
    described_class.new(feature: feature, model: Llm::Models.configured_default_model_for(feature), account: nil, **)
  end

  it 'keeps the owner order for each role, including its fourth choice' do
    expect(chain.models).to eq(split_models)
    expect(chain(feature: :council_edit).models).to eq(edit_models)
  end

  it 'tries the next model after an invalid domain result and stops at the first usable result' do
    visited = []
    result = chain.call do |model|
      visited << model
      model == split_models.last ? :valid : nil
    end
    expect(result).to eq(:valid)
    expect(visited).to eq(split_models)
  end

  it 'honours the existing switch that disables model fallbacks' do
    expect(chain(runtime_preferences: { openrouter_allow_model_fallbacks: false }).models).to eq(split_models.first(1))
  end

  it 'recognizes a typed SDK 503 when its provider message omits the status code' do
    visited = []
    result = chain.call do |model|
      visited << model
      raise RubyLLM::ServiceUnavailableError, 'provider unavailable' if model == split_models.first

      :valid
    end
    expect(result).to eq(:valid)
    expect(visited).to eq(split_models.first(2))
  end

  it 'does not cascade consent, permission, privacy, budget, refusal or overall deadline failures' do
    errors = [ArgumentError.new('privacy denied'), RubyLLM::ForbiddenError.new('upstream timeout'),
              RubyLLM::UnauthorizedError.new('network error'), RubyLLM::PaymentRequiredError.new('provider unavailable'),
              StandardError.new('consent required'), RubyLLM::ServiceUnavailableError.new('guardrail blocked'),
              Llm::StructuredOutputPolicy::ProviderRefusalError.new('refused'), Timeout::Error.new]
    errors.each do |error|
      visited = []
      expect do
        chain.call do |model|
          visited << model
          raise error
        end
      end.to raise_error(error.class)
      expect(visited).to eq(split_models.first(1))
    end
  end

  it 'lets a fail-closed egress exception pass through without a second attempt' do
    blocked = Class.new(Exception) # rubocop:disable Lint/InheritException -- Mirrors the fail-closed egress boundary.
    visited = []
    expect do
      chain.call do |model|
        visited << model
        raise blocked
      end
    end.to raise_error(blocked)
    expect(visited).to eq(split_models.first(1))
  end

  describe 'the actual Council SDK wire with the installed static metadata' do
    let(:account) { create(:account) }
    let(:bodies) { [] }
    let(:catalog_snapshot) { {} }
    let(:endpoint) { 'https://council-offline.example/api/v1/chat/completions' }

    before do
      # Exercise the real catalog fallback and runtime/compiler/SDK, without a fake capability table or external inference.
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(catalog_snapshot)
      allow(Llm::Config).to receive(:api_key).and_call_original
      allow(Llm::Config).to receive(:api_base).and_call_original
      allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return('offline-test-key')
      allow(Llm::Config).to receive(:api_base).with('openrouter', account: account).and_return('https://council-offline.example/api/v1')
      allow(Llm::Config).to receive(:context).and_wrap_original do |original, **options|
        original.call(**options).tap { |context| context.config.max_retries = 0 }
      end
    end

    def wire_chain(models, content)
      stub_request(:post, endpoint).to_return do |request|
        body = JSON.parse(request.body)
        bodies << body
        if body['model'] == models.last
          { status: 200, headers: { 'Content-Type' => 'application/json' }, body: {
            id: 'offline-response', model: models.last, choices: [{ index: 0, finish_reason: 'stop',
                                                                    message: { role: 'assistant', content: content.to_json } }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
          }.to_json }
        else
          { status: 503, headers: { 'Content-Type' => 'application/json' }, body: { error: { message: 'provider unavailable' } }.to_json }
        end
      end
    end

    def expect_ordered_wire(models)
      expect(bodies.pluck('model')).to eq(models)
      expect(bodies.pluck('models')).to eq(models.zip)
      bodies.each { |body| expect_transform_policy(body) }
    end

    def expect_transform_policy(body)
      expect(body).to include('response_format' => include('type' => 'json_schema'))
      expect(body).not_to include('tools', 'parallel_tool_calls')
      expect(body['reasoning']).to(satisfy { |value| value == { 'enabled' => false } || value&.[]('effort') == 'none' })
    end

    it 'splits through all four models in order and retains exactly the selected participants' do
      participants = [Captain::Runtime::RoutingSnapshot::Agent.new(id: 21, label: 'First', card: 'First service'),
                      Captain::Runtime::RoutingSnapshot::Agent.new(id: 22, label: 'Second', card: 'Second service')]
      parts = participants.map do |agent|
        { agent_id: agent.id, fragment: 'Synthetic service question', patient: 'self', relation: 'independent',
          link_part_number: nil, link_action: 'new' }
      end
      wire_chain(split_models, parts: parts)
      result = Captain::Runtime::CouncilSplitter.new(account: account, message: 'Synthetic service question', participants: participants).split

      expect(result.fallback).to be false
      expect(result.parts.pluck('executor_agent_id')).to eq([21, 22])
      expect_ordered_wire(split_models)
    end

    it 'edits through all four models in order without tools or reasoning' do
      wire_chain(edit_models, reply: 'Synthetic completed answer')
      editor = Captain::Runtime::CouncilEditor.new(context: {}, account: account,
                                                   model: Llm::Config.model_for(feature: :council_edit, account: account))
      result = editor.edit(message: 'Synthetic service question', parts: [{ text: 'Synthetic completed answer', done: false }])

      expect(result.reply).to eq('Synthetic completed answer')
      expect_ordered_wire(edit_models)
    end

    context 'with the actual shipped fallback catalog' do
      let(:catalog_snapshot) { Llm::OpenRouterModelCatalog.send(:fallback_model_configs) }

      it 'preserves explicit reasoning off in every SDK attempt when cold-catalog entries shadow static metadata' do
        expect(catalog_snapshot.fetch('google/gemini-2.5-flash-lite')['source']).to eq(Llm::OpenRouterModelCatalog::FALLBACK_SOURCE)
        wire_chain(edit_models, reply: 'Synthetic cold-catalog answer')
        editor = Captain::Runtime::CouncilEditor.new(context: {}, account: account,
                                                     model: Llm::Config.model_for(feature: :council_edit, account: account))

        expect(editor.edit(message: 'Synthetic question', parts: [{ text: 'Synthetic cold-catalog answer', done: false }]).reply)
          .to eq('Synthetic cold-catalog answer')
        expect_ordered_wire(edit_models)
      end
    end
  end
end
