# frozen_string_literal: true

require 'rails_helper'

ChatFactoryRouterSpecTool = Struct.new(:name, :description) do
  def parameters = {}
end

# One logic only: in a clinic with several agents the router decides who answers, so no run binds a transfer, planning or task tool
# and no prompt describes other agents.
RSpec.describe Captain::Runtime::ChatFactory do
  let(:account) { create(:account) }
  let(:tools) { { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[create_appointment handoff] } } } }
  let!(:doctors) { create(:captain_assistant, account: account, name: 'Врачи', routing_description: 'Запись к ЛОР-врачам', config: tools) }
  let!(:procedures) { create(:captain_assistant, account: account, name: 'Процедуры', routing_description: 'ЛОР-процедуры', config: tools) }
  let(:conversation) { create(:conversation, account: account) }
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:prompts) { [] }

  before do
    allow(Llm::Runtime).to receive(:build_chat).and_return(chat)
    allow(chat).to receive_messages(after_message: chat, with_tools: chat, model: 'openai/gpt-6-luna')
    allow(chat).to receive(:with_instructions) do |prompt|
      prompts << prompt
      chat
    end
    allow(Llm::CapabilityPolicy).to receive(:ensure_chat_features_supported!)
    allow(Llm::OpenRouterRequestPolicy).to receive(:require_parameters!)
  end

  it 'binds only the agent\'s own tools in a multi-agent run and tells it nothing about the other agents' do
    run_context = Captain::AgentRunContext.new(scope: Captain::ChannelScope.for_conversation(conversation), conversation: conversation)
    context = run_context.prepare({ state: { account_id: account.id, assistant_id: doctors.id }, conversation_history: [] })
    run_context.activate(procedures, context)
    agent = Captain::Runtime::Agent.new(name: "assistant_#{procedures.id}", instructions: 'Ты — ИИ-специалист кабинета процедур.',
                                        model: 'openai/gpt-6-luna',
                                        tools: [ChatFactoryRouterSpecTool.new('create_appointment', 'book'),
                                                ChatFactoryRouterSpecTool.new('handoff', 'staff')])
    wrapper = Captain::Runtime::RunContext.new(context)

    described_class.build(agent: agent, context_wrapper: wrapper, llm_context: nil, runtime_headers: {}, runtime_params: {})

    bound = wrapper.context[:captain_v2_bound_tool_ids]
    expect(bound).to eq(%w[create_appointment handoff])
    expect(bound.grep(/\Atransfer_to_|\Ahandoff_to_/)).to be_empty
    expect(bound & %w[plan_request manage_agent_tasks]).to be_empty
    expect(prompts.last).not_to include('Colleagues', 'colleague', 'transfer', doctors.name)
  end
end
