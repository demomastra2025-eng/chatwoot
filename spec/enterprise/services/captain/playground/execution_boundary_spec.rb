require 'rails_helper'

RSpec.describe Captain::Playground::ExecutionBoundary do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant, mode: mode) }
  let(:mode) { 'trial' }

  before { account.enable_features!('scheduling', 'crm_deals', 'crm_tasks') }
  after { Current.reset }

  def tool_context(playground)
    runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, source: 'playground', playground_session: playground)
    state = runner.send(:build_state)
    Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: state, playground_session: playground }))
  end

  it 'builds the Trial runtime state entirely from the scenario and never looks up its synthetic IDs in native conversations' do
    session.with_lock do |trial|
      expect(account).not_to receive(:conversations)
      context = tool_context(trial)
      expect(context.state.dig(:contact, :id)).to eq(101)
      expect(context.state.dig(:conversation, :id)).to eq(201)
      expect(context.state.dig(:contact_inbox, :hmac_verified)).to be(false)
      expect(context.state.dig(:playground, :session_id)).to eq(trial.id)
    end
  end

  it 'intercepts an account adapter before its native patient scope, business delegate, or audit is called' do
    session.with_lock do |trial|
      adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'search_appointments')
      expect(adapter).not_to receive(:execute)
      expect(Captain::ToolExecutionAuditService).not_to receive(:record)
      context = tool_context(trial)
      result = described_class.execute(adapter, context, { client_identifier: '150101500011' }) { adapter.execute(context) }
      expect(result[:appointments].first[:appointment_id]).to eq(601)
      expect(result[:appointments].first[:appointment_access_token]).to start_with("trial_#{trial.id}_")
    end
  end

  it 'denies a substituted account/session/source context without reaching the native tool' do
    session.with_lock do |trial|
      context = tool_context(trial)
      context.state[:playground][:account_id] = account.id + 1
      tool = Captain::Tools::UpdateContactTool.new(assistant)
      expect(tool).not_to receive(:execute)
      result = described_class.execute(tool, context, { name: 'Wrong account' }) { tool.execute(context) }
      expect(result).to include(success: false, retryable: false)
    end
  end

  context 'in Live' do
    let(:mode) { 'live' }

    it 'uses the dedicated actual caller consistently and executes the ordinary contact service with the signed run policy' do
      unrelated = create(:contact, account: account, name: 'Unrelated patient')
      session.with_lock(inbox_id: inbox.id) do |live|
        context = tool_context(live)
        expect(context.state.dig(:contact, :id)).to eq(live.conversation.contact_id)
        expect(context.state.dig(:conversation, :id)).to eq(live.conversation.id)
        expect(context.state.dig(:playground, :mode)).to eq('live')
        tool = Captain::Tools::UpdateContactTool.new(assistant)
        result = described_class.execute(tool, context, { name: 'Live test caller' }) do
          expect(Current.playground_run_policy).to eq(live.run_policy)
          tool.execute(context, name: 'Live test caller')
        end
        expect(Captain::ToolResult.error?(result)).to be(false)
        expect(live.conversation.contact.reload.name).to eq('Live test caller')
      end
      expect(unrelated.reload.name).to eq('Unrelated patient')
    end

    it 'rejects Trial access handles and default-off delivery before reaching a native delegate' do
      session.with_lock(inbox_id: inbox.id) do |live|
        context = tool_context(live)
        appointment_tool = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'get_appointment')
        expect(appointment_tool).not_to receive(:execute)
        result = described_class.execute(appointment_tool, context, { appointment_access_token: 'trial_other_session_token' }) { appointment_tool.execute(context) }
        expect(result[:success]).to be(false)
        message_tool = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'send_message_to_conversation')
        expect(message_tool).not_to receive(:execute)
        result = described_class.execute(message_tool, context, { content: 'No real send' }) { message_tool.execute(context) }
        expect(result).to include(success: false, data: include(delivered: false))
      end
    end

    it 'restores the dedicated caller policy in a later ordinary runner without changing the tool set' do
      session.with_lock(inbox_id: inbox.id) do |live|
        runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, conversation: live.conversation)
        allow(runner).to receive(:generate_response_in_runtime_cache) do
          expect(Current.playground_run_policy).to eq(live.run_policy)
          { 'response' => 'Caller reply' }
        end

        expect(runner.generate_response['response']).to eq('Caller reply')
        expect(Current.playground_run_policy).to be_nil
      end
    end

    it 'retains invalid caller policy and leaves an unrelated ordinary runner without Playground context' do
      session.with_lock(inbox_id: inbox.id) do |live|
        live.conversation.update_columns( # rubocop:disable Rails/SkipsModelValidations
          additional_attributes: live.conversation.additional_attributes.merge('captain_playground' => false)
        )
        runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, conversation: live.conversation)
        allow(runner).to receive(:generate_response_in_runtime_cache) do
          expect(Current.playground_run_policy).to be(false)
          { 'response' => 'Blocked delivery' }
        end
        runner.generate_response
      end
      ordinary = create(:conversation, account: account, inbox: inbox)
      runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, conversation: ordinary)
      allow(runner).to receive(:generate_response_in_runtime_cache) do
        expect(Current.playground_run_policy).to be_nil
        { 'response' => 'Ordinary reply' }
      end

      expect(runner.generate_response['response']).to eq('Ordinary reply')
    end

    it 'keeps a conflicting inherited run blocked in an explicit Live runner and restores the outer policy' do
      session.with_lock(inbox_id: inbox.id) do |live|
        runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant, source: 'playground', playground_session: live)
        inherited = Outbound::PlaygroundDeliveryPolicy.issue(Outbound::PlaygroundDeliveryPolicy.verified(live.run_policy).merge(run_id: SecureRandom.uuid))
        allow(runner).to receive(:generate_response_in_runtime_cache) do
          expect(Current.playground_run_policy).to eq({})
          { 'response' => 'Nested reply' }
        end
        Outbound::PlaygroundDeliveryPolicy.with(inherited) do
          expect(runner.generate_response['response']).to eq('Nested reply')
          expect(Current.playground_run_policy).to eq(inherited)
        end
      end
    end

    it 'keeps invalid inherited run context blocked while executing a Live business mutation' do
      session.with_lock(inbox_id: inbox.id) do |live|
        context = tool_context(live)
        tool = Captain::Tools::UpdateContactTool.new(assistant)
        [false, {}, { 'token' => 'invalid' }].each do |inherited|
          Outbound::PlaygroundDeliveryPolicy.with(inherited) do
            described_class.execute(tool, context, { name: 'Nested caller' }) do
              expect(Current.playground_run_policy).to eq({})
              descendant = EventDispatcherJob.new('nested mutation', Time.current, {})
              descendant.send(:capture_playground_run_policy)
              expect(descendant.serialize['captain_playground']).to eq({})
            end
            expect(Current.playground_run_policy).to eq(inherited)
          end
        end
      end
    end
  end
end
