# frozen_string_literal: true

require 'rails_helper'

OpenRouterRequestPolicySpecModel = Struct.new(:id, :provider)

class OpenRouterRequestPolicySpecChat
  attr_reader :model, :params, :headers, :with_params_calls, :with_headers_calls
  attr_accessor :tools

  def initialize(model:, params: {}, headers: {})
    @model = model
    @params = params
    @headers = headers
    @tools = {}
    @with_params_calls = []
    @with_headers_calls = []
  end

  def with_params(**params)
    @params = params
    @with_params_calls << params
    self
  end

  def with_headers(**headers)
    @headers = headers
    @with_headers_calls << headers
    self
  end

  def with_temperature(temperature)
    @temperature = temperature
    self
  end
end

RSpec.describe Llm::OpenRouterRequestPolicy do
  it 'installs the RubyLLM OpenRouter server-tool payload patch' do
    expect(RubyLLM::Providers::OpenRouter.ancestors).to include(Llm::OpenRouterServerToolsPatch)
  end

  describe '.require_parameters!' do
    describe 'parallel call hints across the real compile and binding sequence' do
      let(:model_id) { 'moonshotai/kimi-k2.6' }
      let(:account) { instance_double(Account, id: 42) }
      let(:read_tool) { Struct.new(:name, :metadata).new('search_slots', { read_only: true }) }
      let(:write_tool) { Struct.new(:name, :metadata).new('create_appointment', { risk_level: 'high' }) }

      before do
        allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoints_for).and_return(
          [{ 'supported_parameters' => %w[tools parallel_tool_calls] }]
        )
      end

      def initial_chat(hint)
        request = Llm::FeatureRequest.new(
          feature: :captain_agent, account: account, model: model_id,
          assistant: { id: 77, account_id: 42 }, session_id: 'original-conversation', parallel_tool_calls: hint
        )
        compiled = Llm::OpenRouterRequestCompiler.call(request: request, model: model_id, account: account)
        chat = OpenRouterRequestPolicySpecChat.new(
          model: OpenRouterRequestPolicySpecModel.new(model_id, 'openrouter'), params: compiled.params
        )
        described_class.tag!(chat, feature: :captain_agent, account: account, model: model_id, routing_metadata: compiled.metadata)
        chat
      end

      def serialized_provider_payload(chat)
        config = RubyLLM.config.dup
        config.openrouter_api_key = 'synthetic-test-key'
        provider = RubyLLM::Providers::OpenRouter.new(config)
        allow(provider).to receive(:sync_response) { |_connection, payload, _headers| JSON.parse(payload.to_json) }
        provider.complete(
          [], tools: {}, temperature: nil, model: RubyLLM::Model::Info.default(model_id, 'openrouter'), params: chat.params
        )
      end

      [true, false, nil].each do |hint|
        it "keeps #{hint.inspect} through tool binding, schema binding and the final wire parameters" do
          chat = initial_chat(hint)
          described_class.require_parameters!(chat, tools: [read_tool, write_tool])
          chat.tools = { read_tool.name => read_tool, write_tool.name => write_tool }
          described_class.require_structured_output!(chat)

          wire = serialized_provider_payload(chat)
          expect(wire['parallel_tool_calls']).to equal(hint != false)
          expect(wire['session_id']).to eq('llm:captain_agent:42:assistant_77')
        end
      end

      it 'removes an old enabled flag if capability is no longer advertised' do
        chat = initial_chat(true)
        described_class.require_parameters!(chat, tools: [read_tool, write_tool])
        expect(chat.params[:parallel_tool_calls]).to be(true)
        allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoints_for).and_return([{ 'supported_parameters' => %w[tools] }])
        described_class.require_parameters!(chat, tools: [read_tool, write_tool])

        expect(chat.params).not_to have_key(:parallel_tool_calls)
      end

      it 'keeps explicit off even when the initial compile omitted it for an unsupported endpoint' do
        allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoints_for).and_return([{ 'supported_parameters' => %w[tools] }])
        chat = initial_chat(false)
        expect(chat.params).not_to have_key(:parallel_tool_calls)
        allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoints_for).and_return(
          [{ 'supported_parameters' => %w[tools parallel_tool_calls] }]
        )
        described_class.require_parameters!(chat, tools: [read_tool, write_tool])
        expect(JSON.parse(chat.params.to_json)['parallel_tool_calls']).to be(false)
      end
    end

    it 'adds provider require_parameters for OpenRouter chats and preserves existing params' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('deepseek/deepseek-v4-pro', 'openrouter'),
        params: {
          'logit_bias' => { '123' => -1 },
          'provider' => { 'allow_fallbacks' => true },
          :max_tokens => 200
        },
        headers: {
          'HTTP-Referer' => 'https://spoofed.example',
          'X-OpenRouter-Title' => 'Spoofed'
        }
      )

      result = described_class.require_parameters!(chat)

      expect(result).to eq(chat)
      expect(chat.params).to include(
        'logit_bias' => { '123' => -1 },
        :max_tokens => 200,
        :provider => include(:allow_fallbacks => true, :require_parameters => true)
      )
      expect(chat.headers).to include(
        'HTTP-Referer' => Llm::OpenRouterHeaders.attribution_headers['HTTP-Referer'],
        'X-OpenRouter-Title' => 'OneLink'
      )
    end

    it 'adds provider require_parameters for registry-resolved OpenRouter model ids' do
      chat = OpenRouterRequestPolicySpecChat.new(model: 'openai/gpt-5.4')

      allow(Llm::Models).to receive(:provider_for).with('openai/gpt-5.4', account: nil).and_return('openrouter')

      described_class.require_parameters!(chat)

      expect(chat.params).to include(provider: include(require_parameters: true))
    end

    it 'keeps the models of the first compile when it compiles the chat again: a chat built for one model keeps one' do
      chat = OpenRouterRequestPolicySpecChat.new(model: OpenRouterRequestPolicySpecModel.new('openai/gpt-6-luna', 'openrouter'))
      described_class.tag!(chat, feature: :editor, model: 'openai/gpt-6-luna', routing_metadata: { models: ['openai/gpt-6-luna'] })

      described_class.require_parameters!(chat, feature: :editor, model: 'openai/gpt-6-luna', reasoning: true)

      expect(chat.params[:models]).to eq(['openai/gpt-6-luna'])
    end

    it 'never sends OpenRouter more than three models when it compiles a chat of a Luna 6 feature that has four fallbacks listed' do
      %i[editor label_suggestion].each do |feature|
        chat = OpenRouterRequestPolicySpecChat.new(model: OpenRouterRequestPolicySpecModel.new('openai/gpt-6-luna', 'openrouter'))

        described_class.require_parameters!(chat, feature: feature, model: 'openai/gpt-6-luna', reasoning: true)

        expect(chat.params[:models].size).to be <= 3
        expect(chat.params[:models].first(2)).to eq(%w[openai/gpt-6-luna openai/gpt-5.6-luna])
      end
    end

    it 'sends a customer image to the one reader the platform named, with no fallback model' do
      chat = OpenRouterRequestPolicySpecChat.new(model: OpenRouterRequestPolicySpecModel.new('openai/gpt-6-luna', 'openrouter'))

      described_class.require_parameters!(chat, feature: :image_recognition, model: 'openai/gpt-6-luna', reasoning: true)

      expect(chat.params[:models]).to eq(['openai/gpt-6-luna'])
    end

    it 'uses tagged account and feature metadata for existing chat instances' do
      account = create(:account)
      chat = OpenRouterRequestPolicySpecChat.new(model: 'custom/model')
      described_class.tag!(chat, account: account, feature: :copilot, model: 'custom/model')

      allow(Llm::Models).to receive(:provider_for).with('custom/model', account: account).and_return('openrouter')

      described_class.require_parameters!(chat)

      expect(chat.params).to include(
        provider: include(
          require_parameters: true,
          sort: { by: 'latency', partition: 'none' }
        )
      )
    end

    it 'preserves trusted compiled OpenRouter routing controls when requiring tool parameters' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('moonshotai/kimi-k2.6', 'openrouter'),
        params: {
          provider: {
            order: %w[Groq Fireworks],
            only: ['Groq'],
            ignore: ['OpenAI'],
            quantizations: ['fp8'],
            preferred_min_throughput: 80,
            preferred_max_latency: 1200,
            max_price: { prompt: 0.2, completion: 0.8 },
            sort: { by: 'latency', partition: 'none' },
            allow_fallbacks: false,
            data_collection: 'deny'
          }
        }
      )
      described_class.tag!(
        chat,
        feature: :captain_agent,
        model: 'moonshotai/kimi-k2.6',
        routing_metadata: {
          requested_model: 'moonshotai/kimi-k2.6',
          routing_profile: 'exacto',
          openrouter_provider_order: %w[Groq Fireworks]
        }
      )

      described_class.require_parameters!(chat, feature: :captain_agent, tools: true)

      expect(chat.params[:provider]).to include(
        order: %w[Groq Fireworks],
        only: ['Groq'],
        ignore: %w[openai/fast openai/priority openai/flex OpenAI],
        quantizations: ['fp8'],
        preferred_min_throughput: 80,
        preferred_max_latency: 1200,
        max_price: { prompt: 0.2, completion: 0.8 },
        sort: { by: 'latency', partition: 'none' },
        allow_fallbacks: false,
        data_collection: 'deny',
        require_parameters: true
      )
      expect(described_class.observability_metadata(chat)).to include(
        requested_model: 'moonshotai/kimi-k2.6',
        openrouter_provider_order: %w[Groq Fireworks],
        openrouter_require_parameters: true,
        openrouter_allow_fallbacks: false
      )
    end

    it 'drops untrusted advanced provider controls from raw OpenRouter chats' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('moonshotai/kimi-k2.6', 'openrouter'),
        params: {
          provider: {
            order: %w[UntrustedProvider],
            only: %w[UntrustedProvider],
            ignore: %w[OpenAI],
            allow_fallbacks: false,
            data_collection: 'allow'
          }
        }
      )

      described_class.require_parameters!(chat, feature: :captain_agent, tools: true)

      expect(chat.params[:provider]).not_to include(:order, :only)
      expect(chat.params[:provider][:ignore]).to eq(%w[openai/fast openai/priority openai/flex])
      expect(chat.params[:provider]).to include(
        data_collection: 'deny',
        allow_fallbacks: true,
        require_parameters: true
      )
    end

    it 'omits unsupported chat temperature when recompiling late strict OpenRouter params' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('openai/gpt-5.4', 'openrouter')
      ).with_temperature(1.0)
      allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoints_for)
        .with('openai/gpt-5.4')
        .and_return(
          [
            {
              'provider_name' => 'OpenAI',
              'supported_parameters' => %w[tools tool_choice response_format structured_outputs]
            }
          ]
        )

      described_class.require_parameters!(chat, feature: :captain_agent, tools: true, schema: true)

      expect(chat.params).not_to include(:temperature)
      expect(chat.params).to include(
        Llm::OpenRouterServerToolsPatch::OMIT_TEMPERATURE_PARAM => true,
        :provider => include(require_parameters: true)
      )
      expect(described_class.observability_metadata(chat)).to include(
        openrouter_omitted_params: ['temperature'],
        openrouter_require_parameters: true
      )
    end

    it 'preserves sensitive privacy cache disablement when recompiling existing chat params' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('openai/gpt-5.4-mini', 'openrouter'),
        headers: {
          'HTTP-Referer' => Llm::OpenRouterHeaders.attribution_headers['HTTP-Referer'],
          'x-openrouter-cache' => 'true',
          'X-OpenRouter-Cache-TTL' => '300'
        }
      )
      described_class.tag!(
        chat,
        feature: :editor,
        model: 'openai/gpt-5.4-mini',
        routing_metadata: {
          requested_model: 'openai/gpt-5.4-mini',
          openrouter_privacy_profile: 'sensitive',
          openrouter_cache_policy: 'read_only',
          openrouter_response_cache: 'disabled',
          openrouter_response_cache_ttl: 300,
          openrouter_response_cache_reason: 'privacy_sensitive'
        }
      )

      described_class.require_parameters!(chat, tools: true)

      expect(chat.headers).not_to include('X-OpenRouter-Cache')
      expect(chat.headers).not_to include('x-openrouter-cache')
      expect(chat.headers).not_to include('X-OpenRouter-Cache-TTL')
      expect(chat.params[:provider]).to include(require_parameters: true)
      metadata = described_class.observability_metadata(chat)
      expect(metadata).to include(
        openrouter_privacy_profile: 'sensitive',
        openrouter_cache_policy: 'read_only',
        openrouter_response_cache: 'disabled',
        openrouter_response_cache_reason: 'privacy_sensitive'
      )
      expect(metadata).not_to include(:openrouter_response_cache_ttl)
    end

    it 'preserves disabled cache policy when recompiling existing read-only chat params' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('openai/gpt-5.4-mini', 'openrouter'),
        headers: {
          'HTTP-Referer' => Llm::OpenRouterHeaders.attribution_headers['HTTP-Referer'],
          'X-OpenRouter-Cache' => 'true',
          'X-OpenRouter-Cache-TTL' => '300'
        }
      )
      described_class.tag!(
        chat,
        feature: :editor,
        model: 'openai/gpt-5.4-mini',
        routing_metadata: {
          requested_model: 'openai/gpt-5.4-mini',
          openrouter_cache_policy: 'disabled',
          openrouter_response_cache: 'disabled',
          openrouter_response_cache_reason: 'policy_disabled'
        }
      )

      described_class.require_parameters!(chat, tools: true)

      expect(chat.headers).not_to include('X-OpenRouter-Cache')
      expect(chat.headers).not_to include('X-OpenRouter-Cache-TTL')
      expect(chat.params[:provider]).to include(require_parameters: true)
      expect(described_class.observability_metadata(chat)).to include(
        openrouter_cache_policy: 'disabled',
        openrouter_response_cache: 'disabled',
        openrouter_response_cache_reason: 'policy_disabled'
      )
    end

    it 'does not mutate non-OpenRouter chats' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('gpt-4.1-mini', 'openai'),
        params: { temperature: 0.2 }
      )

      described_class.require_parameters!(chat)

      expect(chat.params).to eq(temperature: 0.2)
      expect(chat.with_params_calls).to be_empty
    end
  end

  describe '.require_structured_output!' do
    it 'adds response healing and provider require_parameters for OpenRouter structured output calls' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('deepseek/deepseek-v4-pro', 'openrouter'),
        params: {
          plugins: [{ id: 'web' }],
          provider: { sort: 'latency' }
        }
      )

      described_class.require_structured_output!(chat)

      expect(chat.params).to include(
        provider: include(sort: { by: 'latency', partition: 'model' }, require_parameters: true),
        plugins: contain_exactly({ id: 'response-healing' })
      )
    end

    it 'does not duplicate the response healing plugin' do
      chat = OpenRouterRequestPolicySpecChat.new(
        model: OpenRouterRequestPolicySpecModel.new('deepseek/deepseek-v4-pro', 'openrouter'),
        params: { plugins: [{ 'id' => 'response-healing' }] }
      )

      described_class.require_structured_output!(chat)

      expect(chat.params[:plugins].count { |plugin| plugin[:id] == 'response-healing' || plugin['id'] == 'response-healing' }).to eq(1)
    end
  end
end
