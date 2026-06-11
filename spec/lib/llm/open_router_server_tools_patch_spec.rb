# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterServerToolsPatch do
  let(:provider_class) do
    Class.new do
      prepend Llm::OpenRouterServerToolsPatch

      attr_reader :payload, :headers

      def initialize
        @connection = :fake_connection
      end

      def maybe_normalize_temperature(temperature, _model)
        temperature
      end

      def render_payload(_messages, **options)
        {
          model: options[:model],
          stream: options[:stream],
          temperature: options[:temperature],
          tools: options[:tools],
          schema: options[:schema],
          thinking: options[:thinking],
          tool_prefs: options[:tool_prefs]
        }.compact
      end

      def complete(messages, tools:, temperature:, model:, params: {}, headers: {}, schema: nil, thinking: nil, tool_prefs: nil, &)
        payload = render_payload(
          messages,
          tools: tools,
          temperature: maybe_normalize_temperature(temperature, model),
          model: model,
          stream: block_given?,
          schema: schema,
          thinking: thinking,
          tool_prefs: tool_prefs
        ).merge(params)
        block_given? ? stream_response(@connection, payload, headers, &) : sync_response(@connection, payload, headers)
      end

      def sync_response(_connection, payload, headers)
        @payload = payload
        @headers = headers
        :sync_response
      end

      def stream_response(_connection, payload, headers)
        @payload = payload
        @headers = headers
        yield :chunk
        :stream_response
      end
    end
  end

  let(:server_tools) { [{ type: 'openrouter:datetime' }] }
  let(:function_tools) { [{ type: 'function', function: { name: 'lookup_deal' } }] }
  let(:params) do
    {
      described_class::SERVER_TOOLS_PARAM => server_tools,
      :max_tokens => 250
    }
  end

  it 'adds OpenRouter server tools to sync payload without leaking the sentinel param' do
    provider = provider_class.new

    result = provider.complete(
      [],
      tools: function_tools,
      temperature: 0.2,
      model: 'openai/gpt-5.4-mini',
      params: params,
      headers: { 'HTTP-Referer' => 'https://one-link.kz' }
    )

    expect(result).to eq(:sync_response)
    expect(provider.payload[:tools]).to eq(function_tools + server_tools)
    expect(provider.payload).to include(max_tokens: 250)
    expect(provider.payload).not_to include(described_class::SERVER_TOOLS_PARAM)
    expect(provider.headers).to include('HTTP-Referer' => 'https://one-link.kz')
  end

  it 'omits temperature and removes the internal sentinel without server tools' do
    provider = provider_class.new

    result = provider.complete(
      [],
      tools: function_tools,
      temperature: 1.0,
      model: 'openai/gpt-5.4',
      params: {
        described_class::OMIT_TEMPERATURE_PARAM => true,
        :max_tokens => 250
      },
      headers: {}
    )

    expect(result).to eq(:sync_response)
    expect(provider.payload).not_to include(:temperature)
    expect(provider.payload).not_to include(described_class::OMIT_TEMPERATURE_PARAM)
    expect(provider.payload).to include(max_tokens: 250)
  end

  it 'adds OpenRouter server tools to streaming payload' do
    provider = provider_class.new
    chunks = []

    result = provider.complete(
      [],
      tools: function_tools,
      temperature: 0.2,
      model: 'openai/gpt-5.4-mini',
      params: params,
      headers: {}
    ) { |chunk| chunks << chunk }

    expect(result).to eq(:stream_response)
    expect(chunks).to eq([:chunk])
    expect(provider.payload[:stream]).to be(true)
    expect(provider.payload[:tools]).to eq(function_tools + server_tools)
  end
end
