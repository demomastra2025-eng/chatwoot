require 'rails_helper'

RSpec.describe Captain::Playground::ExecutionBoundary do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }
  before { account.enable_features!('scheduling', 'crm_deals', 'crm_tasks') }
  after { Current.reset }

  def tool_context(workspace)
    runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, source: 'playground', playground_session: workspace)
    state = runner.send(:build_state)
    Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: state, playground_session: workspace }))
  end

  it 'builds synthetic runtime state without looking up native conversations, including when real read is enabled' do
    session.with_lock do |workspace|
      workspace.set_permissions!(read: true, write: false)
      expect(account).not_to receive(:conversations)
      context = tool_context(workspace)
      expect(context.state.dig(:contact, :id)).to eq(workspace.namespace.encode({ id: 101 })[:id])
      expect(context.state.dig(:conversation, :id)).to eq(workspace.namespace.encode({ id: 201 })[:id])
      expect(context.state.dig(:contact_inbox, :hmac_verified)).to be(false)
      expect(context.state.dig(:playground, :session_id)).to eq(workspace.id)
      expect(workspace.conversation).to be_nil
    end
  end

  it 'intercepts the production account adapter before native lookup, delegate or audit' do
    session.with_lock do |workspace|
      adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'search_appointments')
      expect(adapter).not_to receive(:execute)
      expect(Captain::ToolExecutionAuditService).not_to receive(:record)
      context = tool_context(workspace)
      result = JSON.parse(described_class.execute(adapter, context, { client_identifier: '150101500011' }) { adapter.execute(context) })
      expect(result.dig('appointments', 0, 'appointment_id')).to eq(workspace.namespace.encode({ id: 601 })[:id])
      expect(result.dig('appointments', 0, 'appointment_access_token')).to start_with("trial_#{workspace.id}_")
    end
  end

  it 'denies a substituted account, session or source before the native tool' do
    session.with_lock do |workspace|
      tool = Captain::Tools::UpdateContactTool.new(assistant)
      expect(tool).not_to receive(:execute)
      context = tool_context(workspace)
      context.state[:playground][:account_id] = account.id + 1
      expect(described_class.execute(tool, context, { name: 'Wrong account' }) { tool.execute(context) }).to include(success: false)
      context = tool_context(workspace)
      context.state[:source] = 'conversation'
      expect(described_class.execute(tool, context, { name: 'Wrong source' }) { tool.execute(context) }).to include(success: false)
    end
  end

  it 'refuses legacy Live construction without creating a caller contact or conversation' do
    assistant
    user
    counts = [Contact.count, Conversation.count, Message.count]
    expect { Captain::Playground::Session.new(account: account, user: user, assistant: assistant, mode: 'live') }
      .to raise_error(ArgumentError, /Legacy Live/)
    expect([Contact.count, Conversation.count, Message.count]).to eq(counts)
  end

  it 'blocks legacy captured state and forged server handles while leaving an ordinary runtime unchanged' do
    tool = Captain::Tools::UpdateContactTool.new(assistant)
    [%w[playground live], %w[conversation live]].each do |source, mode|
      context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({
        state: { source: source, playground: { mode: mode, session_id: 'legacy' } }
      }))
      expect(described_class.execute(tool, context, {}) { raise 'Native delegate reached' }).to include(success: false)
    end
    context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: { source: 'conversation' } }))
    expect(described_class.execute(tool, context, {}) { 'Ordinary delegate' }).to eq('Ordinary delegate')
  end

  it 'blocks builtin external providers even after both real-data permissions are enabled' do
    session.with_lock do |workspace|
      workspace.set_permissions!(read: true, write: true)
      Captain::Playground::ToolSupport::EXTERNAL_TOOLS.each do |id|
        definition = Captain::ToolRegistry.definition_for(id)
        tool = if definition.agent_tool_class == Captain::Tools::Agent::AccountToolAdapter
                 definition.agent_tool_class.new(assistant, tool_id: id)
               else
                 definition.agent_tool_class.new(assistant)
               end
        expect(tool).not_to receive(:execute)
        result = described_class.execute(tool, tool_context(workspace), {}) { tool.execute }
        expect(result).to include(success: false, data: include(code: 'blocked_external_service', delivered: false))
      end
    end
  end
end
