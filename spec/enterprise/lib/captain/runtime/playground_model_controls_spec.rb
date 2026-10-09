# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain playground model controls' do
  let(:account) { create(:account, captain_runtime: { 'assistant_thinking_effort' => 'high' }) }
  let(:model) { 'vendor/playground-model' }
  let(:assistant) { create(:captain_assistant, account: account, config: { 'temperature' => 0.7 }) }
  let(:model_config) do
    {
      'provider' => 'openrouter',
      'type' => 'chat',
      'capabilities' => %w[reasoning structured_output tool_calling tool_choice streaming],
      'supported_parameters' => %w[temperature reasoning tools tool_choice response_format],
      'reasoning' => { 'supported_efforts' => %w[none low medium high], 'mandatory' => false }
    }
  end
  let(:llm_context) do
    RubyLLM.context do |config|
      config.openrouter_api_key = 'test-only-key'
      config.openrouter_api_base = 'https://openrouter.example/api/v1'
    end
  end

  before do
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(model => model_config)
    allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
    allow(Llm::Models).to receive(:model_config).and_call_original
    allow(Llm::Models).to receive(:model_config).with(model, account: account).and_return(model_config)
    allow(assistant).to receive(:agent_tools).and_return([])
    allow(assistant).to receive(:agent_instructions).and_return('Return a response for this isolated test.')
  end

  %w[high none].each do |effort|
    it "serializes zero temperature and explicit #{effort} reasoning through the native provider request" do
      original_config = assistant.config.deep_dup
      original_runtime = account.captain_runtime.deep_dup
      captured_body = nil
      request = stub_request(:post, 'https://openrouter.example/api/v1/chat/completions')
                .with do |http_request|
        captured_body = JSON.parse(http_request.body)
        true
      end.to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: {
          id: 'test-generation', model: model,
          choices: [{ index: 0, message: { role: 'assistant', content: { response: 'OK', reasoning: 'Test response' }.to_json }, finish_reason: 'stop' }],
          usage: { prompt_tokens: 1, completion_tokens: 1 }
        }.to_json
      )
      service = Captain::Assistant::AgentRunnerService.new(
        assistant: assistant, source: 'playground',
        test_overrides: { model: model, temperature: 0, thinking_effort: effort }
      )
      runtime_agent = service.send(:build_and_wire_agents).first
      state = service.send(:build_state)
      context_wrapper = Captain::Runtime::RunContext.new(state: state)
      chat = Captain::Runtime::ChatFactory.build(
        agent: runtime_agent, context_wrapper: context_wrapper,
        llm_context: llm_context, runtime_headers: {}, runtime_params: {}, account: account
      )

      chat.ask('Test message')

      expect(request).to have_been_requested.once
      expect(captured_body).to include('model' => model, 'temperature' => 0.0, 'reasoning' => { 'effort' => effort })
      expect(captured_body.fetch('provider')).to include('require_parameters' => true)
      expect(assistant.reload.config).to eq(original_config)
      expect(account.reload.captain_runtime).to eq(original_runtime)
    end
  end
end
