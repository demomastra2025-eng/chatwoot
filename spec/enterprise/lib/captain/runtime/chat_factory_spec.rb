# frozen_string_literal: true

require 'rails_helper'

ChatFactorySpecTool = Struct.new(:name, :description) do
  def parameters = {}
end

RSpec.describe Captain::Runtime::ChatFactory do
  describe '.configure' do
    let(:chat) { instance_double(RubyLLM::Chat) }
    let(:tool) { ChatFactorySpecTool.new('search_deals', 'Search CRM deals') }
    let(:agent) do
      Captain::Runtime::Agent.new(
        name: 'assistant_agent',
        model: 'deepseek/deepseek-v4-pro',
        tools: [tool]
      )
    end
    let(:context_wrapper) { Captain::Runtime::RunContext.new({}) }
    let(:openrouter_model) { instance_double(RubyLLM::Model::Info, id: 'deepseek/deepseek-v4-pro', provider: 'openrouter') }

    it 'requires OpenRouter providers to support tool parameters before binding runtime tools' do
      allow(chat).to receive(:model).and_return(openrouter_model)
      allow(chat).to receive(:params).and_return(provider: { allow_fallbacks: true })
      allow(chat).to receive(:with_tools).and_return(chat)
      allow(chat).to receive(:with_instructions).and_return(chat)
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
      expect(chat).to receive(:with_tools) do |*tools, replace:|
        expect(tools.first).to be_a(Captain::Runtime::ToolWrapper)
        expect(replace).to be true
        chat
      end

      described_class.send(:configure, chat, agent, context_wrapper)
    end
  end
end
