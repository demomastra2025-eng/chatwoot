# frozen_string_literal: true

require 'rails_helper'

ChatFactorySpecTool = Struct.new(:name, :description) do
  def parameters = {}
end

RSpec.describe Captain::Runtime::ChatFactory do
  describe '.build' do
    let(:chat) { instance_double(RubyLLM::Chat) }
    let(:agent) do
      Captain::Runtime::Agent.new(
        name: 'assistant_agent',
        model: 'openai/gpt-5.4-mini',
        temperature: 0.3,
        params: { top_p: 0.8 },
        headers: { 'X-Test' => 'agent' }
      )
    end
    let(:context_wrapper) { Captain::Runtime::RunContext.new({}) }

    it 'constructs Captain chats through the LLM runtime facade' do
      allow(chat).to receive(:model).and_return('openai/gpt-5.4-mini')
      allow(chat).to receive(:with_instructions).and_return(chat)
      allow(chat).to receive(:with_tools).and_return(chat)

      expect(Llm::Runtime).to receive(:build_chat).with(
        hash_including(
          feature: :captain_agent,
          account: nil,
          model: 'openai/gpt-5.4-mini',
          options: hash_including(
            context: :llm_context,
            params: { top_p: 0.8, max_tokens: 500 },
            headers: { :'X-Test' => 'runtime' },
            temperature: 0.3
          )
        )
      ).and_return(chat)

      described_class.build(
        agent: agent,
        context_wrapper: context_wrapper,
        llm_context: :llm_context,
        runtime_headers: { 'X-Test' => 'runtime' },
        runtime_params: { max_tokens: 500 }
      )
    end
  end

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
