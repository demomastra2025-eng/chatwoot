require 'rails_helper'

RSpec.describe Llm::BaseAiService do
  subject(:service) { described_class.new }

  before do
    upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'test-key')
  end

  describe '#chat' do
    let(:chat) { instance_double(RubyLLM::Chat) }

    it 'delegates chat construction to Llm::ChatClient' do
      expect(Llm::ChatClient).to receive(:build).with(
        model: service.model,
        temperature: service.temperature,
        thinking: nil
      ).and_return(chat)

      expect(service.chat).to eq(chat)
    end
  end

  describe '#ask_chat' do
    let(:chat) { instance_double(RubyLLM::Chat) }

    it 'delegates asking to Llm::ChatClient' do
      expect(Llm::ChatClient).to receive(:ask).with(chat, 'hello', observability: {})

      service.send(:ask_chat, chat, 'hello')
    end
  end

  describe '#apply_chat_features' do
    let(:service_class) do
      Class.new(described_class) do
        def configure_chat(chat, tools:)
          apply_chat_features(chat, tools: tools)
        end

        def model
          nil
        end
      end
    end

    let(:service) { service_class.new }
    let(:chat) { instance_double(RubyLLM::Chat) }
    let(:tool) { instance_double(RubyLLM::Tool) }
    let(:openrouter_model) { instance_double(RubyLLM::Model::Info, id: 'deepseek/deepseek-v4-pro', provider: 'openrouter') }

    it 'requires OpenRouter providers to support tool parameters before attaching tools' do
      allow(chat).to receive(:model).and_return(openrouter_model)
      allow(chat).to receive(:params).and_return(provider: { allow_fallbacks: true })
      allow(chat).to receive(:with_tool).and_return(chat)
      allow(Llm::Models).to receive(:supports?).and_call_original
      allow(Llm::Models).to receive(:supports?)
        .with('deepseek/deepseek-v4-pro', :tool_calling, account: nil)
        .and_return(true)

      expect(chat).to receive(:with_params) do |**params|
        expect(params).to include(
          models: start_with('deepseek/deepseek-v4-pro'),
          provider: include(
            allow_fallbacks: true,
            data_collection: 'deny',
            require_parameters: true
          )
        )
        chat
      end
      expect(chat).to receive(:with_tool).with(tool).ordered

      service.configure_chat(chat, tools: [tool])
    end
  end
end
