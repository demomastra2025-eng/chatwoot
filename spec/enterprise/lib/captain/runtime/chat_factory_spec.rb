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

    before do
      allow(chat).to receive(:after_message).and_return(chat)
      allow(Llm::Models).to receive(:model_config).with('openai/gpt-5.4-mini', account: nil).and_return(
        'supported_parameters' => %w[temperature top_p max_tokens]
      )
    end

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

    it 'forwards a snapshot of resolved current actor preferences after preparing its context' do
      resolved = {
        'openrouter_provider_only' => ['anthropic'], 'openrouter_allow_fallbacks' => false,
        'openrouter_cache_policy' => 'read_only', 'openrouter_sort' => { 'by' => 'latency' }
      }
      context_wrapper.context[:state] = { assistant_id: 1, captain_runtime: { 'previous_actor_only' => true } }
      agent.context_preparer = lambda do |wrapper|
        wrapper.context[:state].merge!(assistant_id: 2, captain_runtime: resolved)
      end
      expect(Llm::Runtime).to receive(:build_chat) do |**attributes|
        expect(context_wrapper.context.dig(:state, :assistant_id)).to eq(2)
        expect(attributes.fetch(:runtime_preferences)).to eq(resolved)
        expect(attributes.fetch(:runtime_preferences)).not_to equal(resolved)
        chat
      end

      described_class.build(
        agent: agent, context_wrapper: context_wrapper, llm_context: :llm_context,
        runtime_headers: {}, runtime_params: {}
      )
    end

    it 'uses each actor preferences on a shared wrapper without stale settings or nested mutation leakage' do
      first_preferences = {
        'openrouter_provider_only' => ['anthropic'], 'openrouter_cache_policy' => 'read_only',
        'openrouter_sort' => { 'by' => 'latency' }, 'first_actor_only' => true
      }
      second_preferences = {
        'openrouter_provider_only' => ['azure/global'], 'openrouter_cache_policy' => 'disabled',
        'openrouter_sort' => { 'by' => 'price' }
      }
      original_first = first_preferences.deep_dup
      original_second = second_preferences.deep_dup
      second_agent = Captain::Runtime::Agent.new(name: 'specialist_agent', model: agent.model)
      context_wrapper.context[:state] = {}
      agent.context_preparer = ->(wrapper) { wrapper.context[:state][:captain_runtime] = first_preferences }
      second_agent.context_preparer = ->(wrapper) { wrapper.context[:state][:captain_runtime] = second_preferences }
      captured = []
      expect(Llm::Runtime).to receive(:build_chat).twice do |**attributes|
        captured << attributes.fetch(:runtime_preferences)
        chat
      end

      [agent, second_agent].each do |current_agent|
        described_class.build(
          agent: current_agent, context_wrapper: context_wrapper, llm_context: :llm_context,
          runtime_headers: {}, runtime_params: {}
        )
      end

      expect(captured).to eq([original_first, original_second])
      captured.each do |preferences|
        preferences['openrouter_provider_only'] << 'mutation'
        preferences['openrouter_sort']['by'] = 'mutation'
      end
      expect(first_preferences).to eq(original_first)
      expect(second_preferences).to eq(original_second)
      expect(context_wrapper.context.dig(:state, :captain_runtime)).to eq(original_second)
    end

    it 'passes empty runtime preferences when the context has no resolved settings' do
      expect(Llm::Runtime).to receive(:build_chat).with(hash_including(runtime_preferences: {})).and_return(chat)

      described_class.build(
        agent: agent, context_wrapper: context_wrapper, llm_context: :llm_context,
        runtime_headers: {}, runtime_params: {}
      )

      expect(context_wrapper.context).not_to have_key(:state)
    end

    it 'does not pass parallel tool call routing for mutating Captain tool requests' do
      mutating_tool = ChatFactorySpecTool.new('create_deal', 'Create CRM deal')
      agent_with_tool = Captain::Runtime::Agent.new(
        name: 'assistant_agent',
        model: 'openai/gpt-5.4-mini',
        tools: [mutating_tool],
        params: { top_p: 0.8 }
      )

      allow(chat).to receive(:model).and_return('openai/gpt-5.4-mini')
      allow(chat).to receive(:with_instructions).and_return(chat)
      expect(chat).to receive(:with_tools).with(
        an_instance_of(Captain::Runtime::ToolWrapper), replace: true, concurrency: false
      ).and_return(chat)

      expect(Llm::Runtime).to receive(:build_chat).with(
        hash_including(
          feature: :captain_agent,
          model: 'openai/gpt-5.4-mini',
          options: hash_including(
            params: { top_p: 0.8 }
          )
        )
      ).and_return(chat)

      described_class.build(
        agent: agent_with_tool,
        context_wrapper: context_wrapper,
        llm_context: :llm_context,
        runtime_headers: {},
        runtime_params: {}
      )
    end

    it 'does not pass parallel tool call routing for handoff-only Captain agents' do
      handoff_target = Captain::Runtime::Agent.new(name: 'scenario_agent')
      handoff_agent = Captain::Runtime::Agent.new(
        name: 'assistant_agent',
        model: 'openai/gpt-5.4-mini',
        handoff_agents: [handoff_target]
      )

      allow(chat).to receive(:model).and_return('openai/gpt-5.4-mini')
      allow(chat).to receive(:with_instructions).and_return(chat)
      expect(chat).to receive(:with_tools).with(
        an_instance_of(Captain::Runtime::ToolWrapper), replace: true, concurrency: false
      ).and_return(chat)

      expect(Llm::Runtime).to receive(:build_chat).with(
        hash_including(
          feature: :captain_agent,
          model: 'openai/gpt-5.4-mini',
          options: hash_including(params: {})
        )
      ).and_return(chat)

      described_class.build(
        agent: handoff_agent,
        context_wrapper: context_wrapper,
        llm_context: :llm_context,
        runtime_headers: {},
        runtime_params: {}
      )
    end

    # Owner rule: reasoning is for the agents that talk to customers (the runtime and the council consultations), at
    # `low` unless the agent or the workspace chose an effort.
    describe 'reasoning effort' do
      let(:account) { create(:account) }
      let(:reasoning_model) do
        {
          'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[reasoning],
          'supported_parameters' => %w[temperature reasoning],
          'reasoning' => { 'supported_efforts' => %w[low medium high], 'mandatory' => false }
        }
      end

      before do
        allow(chat).to receive(:with_instructions).and_return(chat)
        allow(chat).to receive(:with_tools).and_return(chat)
        allow(Llm::Models).to receive(:model_config).with('openai/gpt-5.4-mini', account: account).and_return(reasoning_model)
      end

      def thinking_sent(state: {}, consult_mode: false)
        sent = nil
        allow(Llm::Runtime).to receive(:build_chat) do |**attributes|
          sent = attributes.fetch(:options)[:thinking]
          chat
        end
        runtime = account.captain_runtime_preferences.to_h.stringify_keys
        wrapper = Captain::Runtime::RunContext.new({ state: { captain_runtime: runtime }.merge(state), consult_mode: consult_mode })
        described_class.build(
          agent: agent, context_wrapper: wrapper, llm_context: :llm_context, runtime_headers: {}, runtime_params: {}, account: account
        )
        sent
      end

      it 'is low when neither the agent nor the workspace chose an effort' do
        expect(thinking_sent).to eq(effort: 'low')
      end

      it 'is low for a council consultation too' do
        expect(thinking_sent(consult_mode: true)).to eq(effort: 'low')
      end

      it 'keeps the explicit effort of the agent' do
        expect(thinking_sent(state: { assistant_config: { 'thinking_effort' => 'high' } })).to eq(effort: 'high')
        expect(thinking_sent(state: { assistant_config: { 'thinking_effort' => 'high' } }, consult_mode: true)).to eq(effort: 'high')
      end

      it 'keeps the effort the workspace stored' do
        account.update!(captain_runtime: { 'assistant_thinking_effort' => 'medium' })

        expect(thinking_sent).to eq(effort: 'medium')
      end

      it 'sends no reasoning to a model that cannot reason' do
        allow(Llm::Models).to receive(:model_config).with('openai/gpt-5.4-mini', account: account)
                                                    .and_return('supported_parameters' => %w[temperature])

        expect(thinking_sent).to be_nil
      end
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
      expect(chat).to receive(:with_tools) do |*tools, replace:, concurrency:|
        expect(tools.first).to be_a(Captain::Runtime::ToolWrapper)
        expect(replace).to be true
        expect(concurrency).to be false
        chat
      end

      described_class.send(:configure, chat, agent, context_wrapper)
    end
  end

  describe 'the consultation prompt' do
    let(:agent) { Captain::Runtime::Agent.new(name: 'assistant_agent', model: 'openai/gpt-5.4-mini', instructions: 'Base prompt') }

    def prompt_for(context)
      described_class.send(:system_prompt_for, agent, Captain::Runtime::RunContext.new({ consult_mode: true }.merge(context)))
    end

    it 'lists the other agents by name and asks for the suggested agent by name, never by an id' do
      peers = [{ name: 'Лаборатория', description: 'Анализы' }, { name: 'Регистратура', description: 'Запись на приём' }]

      prompt = prompt_for(consult_peers: peers)

      expect(prompt).to include('suggested_agent (the exact agent name from the list below) when out of scope.')
      expect(prompt).to include("Other agents (name and responsibility):\nЛаборатория: Анализы\nРегистратура: Запись на приём")
      expect(prompt).not_to include('suggested_agent_id')
    end

    it 'does not ask for a suggested agent when there is no other agent to suggest' do
      prompt = prompt_for(consult_peers: [])

      expect(prompt).to include('status: ok, needs_information, out_of_scope or unavailable; contradictions.')
      expect(prompt).not_to include('suggested_agent', 'Other agents')
    end
  end
end
