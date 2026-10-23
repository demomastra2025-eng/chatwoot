require 'rails_helper'

RSpec.describe Captain::ReplySuggestionService do
  subject(:service) { described_class.new(account: account, conversation_display_id: conversation.display_id, user: agent) }

  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, name: 'Jane Smith') }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:captured_messages) { [] }

  before do
    upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'test-key')
    create(:message, conversation: conversation, message_type: :incoming, content: 'I need help')
    allow(account).to receive(:feature_enabled?).and_call_original
    allow(account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)

    mock_response = instance_double(RubyLLM::Message, content: 'Sure, I can help!', input_tokens: 50, output_tokens: 20)
    mock_chat = instance_double(RubyLLM::Chat)
    mock_context = instance_double(RubyLLM::Context, chat: mock_chat)

    allow(Llm::Config).to receive(:initialize!)
    allow(Llm::Config).to receive(:context).and_return(mock_context)
    allow(Llm::Config).to receive(:provider_for_model).and_return('openai')
    allow(Llm::SafetyPolicy).to receive(:check!).and_return(true)
    allow(mock_chat).to receive(:model).and_return('gpt-5.4-mini')
    allow(mock_chat).to receive(:with_headers).and_return(mock_chat)
    allow(mock_chat).to receive(:with_temperature).and_return(mock_chat)
    allow(mock_chat).to receive(:with_params).and_return(mock_chat)
    allow(mock_chat).to receive(:with_schema).and_return(mock_chat)
    allow(mock_chat).to receive(:with_tool).and_return(mock_chat)
    allow(mock_chat).to receive(:on_end_message).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions) do |msg|
      captured_messages << { role: 'system', content: msg }
      mock_chat
    end
    allow(mock_chat).to receive(:add_message) { |args| captured_messages << args }
    allow(mock_chat).to receive(:ask) do |msg|
      captured_messages << { role: 'user', content: msg }
      mock_response
    end
  end

  describe '#perform' do
    it 'moderates only generated output' do
      expect(service.send(:task_moderation_stages)).to eq([:output])
    end

    it 'returns the suggested reply' do
      result = service.perform

      expect(result[:message]).to eq('Sure, I can help!')
    end

    it 'formats conversation using LlmFormatter' do
      service.perform

      user_message = captured_messages.find { |m| m[:role] == 'user' }
      expect(user_message[:content]).to include('Message History:')
      expect(user_message[:content]).to include('User: I need help')
    end

    context 'with chat channel' do
      it 'uses chat-specific instructions' do
        service.perform

        system_prompt = captured_messages.find { |m| m[:role] == 'system' }[:content]
        expect(system_prompt).to include('CHAT conversation')
        expect(system_prompt).to include('brief, conversational')
        expect(system_prompt).not_to include('EMAIL conversation')
      end
    end

    context 'with email channel' do
      let(:account) { create(:account, limits: { 'non_web_inboxes' => 10 }) }

      let(:inbox) { create(:inbox, :with_email, account: account) }

      it 'uses email-specific instructions' do
        service.perform

        system_prompt = captured_messages.find { |m| m[:role] == 'system' }[:content]
        expect(system_prompt).to include('EMAIL conversation')
        expect(system_prompt).to include('professional email')
        expect(system_prompt).not_to include('CHAT conversation')
      end

      context 'when agent has a signature' do
        let(:agent) { create(:user, account: account, name: 'Jane Smith', message_signature: "Best,\nJane Smith") }

        it 'includes the signature in the prompt' do
          service.perform

          system_prompt = captured_messages.find { |m| m[:role] == 'system' }[:content]
          expect(system_prompt).to include("Best,\nJane Smith")
        end
      end

      context 'when agent has no signature' do
        let(:agent) { create(:user, account: account, name: 'Jane Smith', message_signature: nil) }

        it 'falls back to agent name for sign-off' do
          service.perform

          system_prompt = captured_messages.find { |m| m[:role] == 'system' }[:content]
          expect(system_prompt).to include("sign-off using the agent's name: Jane Smith")
        end
      end
    end

    context 'when an entry-eligible Captain::Assistant is configured on the account' do
      before { allow(account).to receive(:feature_enabled?).with('crm_scheduling').and_return(true) }

      let!(:assistant) do
        create(
          :captain_assistant,
          account: account,
          name: 'Координатор',
          active: true,
          config: {
            'tool_access' => {
              'agent' => {
                'enabled' => true,
                'tool_ids' => %w[search_available_slots search_scheduling_services create_appointment handoff faq_lookup]
              }
            }
          }
        )
      end

      it 'delegates reply suggestion to Captain::Assistant::AgentRunnerService in read-only mode with follow_up_context' do
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).with(
          assistant: assistant,
          conversation: conversation,
          source: 'reply_suggestion',
          callbacks: kind_of(Hash)
        ).and_return(runner_double)

        allow(runner_double).to receive(:generate_response).with(
          message_history: [{ role: 'user', content: 'I need help' }]
        ).and_return(
          {
            'response' => 'Available slots for Dr. Smith tomorrow are 10:00 and 14:30.',
            'reasoning' => 'Checked schedule for Dr. Smith and found 2 open slots.',
            'agent_id' => assistant.id,
            'agent_display_name' => assistant.name,
            'usage' => { 'prompt_tokens' => 120, 'completion_tokens' => 30, 'total_tokens' => 150 }
          }
        )

        result = service.perform

        expect(result[:message]).to eq('Available slots for Dr. Smith tomorrow are 10:00 and 14:30.')
        expect(result[:usage]).to eq({ 'prompt_tokens' => 120, 'completion_tokens' => 30, 'total_tokens' => 150 })
        expect(result.dig(:captain_trace, 'reasoning')).to eq('Checked schedule for Dr. Smith and found 2 open slots.')
        expect(result.dig(:suggestion_meta, 'agent', 'name')).to eq('Координатор')
        expect(result[:follow_up_context]).to include(
          event_name: 'reply_suggestion',
          last_response: 'Available slots for Dr. Smith tomorrow are 10:00 and 14:30.'
        )
        expect(result.dig(:follow_up_context, :original_context)).to include('User: I need help')
      end

      it 'broadcasts live progress over ActionCable and records tool calls and council parts' do
        specialist = create(:captain_assistant, account: account, name: 'ЛОР-специалист', active: true)
        allow(ActionCable.server).to receive(:broadcast)
        stub_council_runner_execution(assistant, specialist)

        result = service.perform

        expect(ActionCable.server).to have_received(:broadcast).with(
          agent.pubsub_token,
          hash_including(event: 'captain.reply_suggestion.progress', data: hash_including(account_id: account.id))
        ).at_least(:once)
        expect(result.dig(:captain_trace, 'reasoning')).to include('Найдено свободное время у врача Дани на 15:00.')

        slot_call = result.dig(:captain_trace, 'tool_calls').find { |tc| tc['tool_name'] == 'search_available_slots' }
        expect(slot_call['current_agent']).to eq('ЛОР-специалист')

        part = result.dig(:suggestion_meta, 'council', 'parts').first
        expect(part).to include(
          'fragment' => 'Болит ухо, нужно к Дани',
          'status' => 'answered',
          'reasoning' => 'Найдено свободное время у врача Дани на 15:00.'
        )
        expect(result.dig(:suggestion_meta, 'working_agents').pluck('name')).to include('Координатор', 'ЛОР-специалист')
      end

      it 'builds read-only agent tools and suggestion tools with action interception, and uses ephemeral session' do
        runtime_agent = assistant.agent(read_only_tools: true)
        tool_names = runtime_agent.tools.map(&:name)

        expect(tool_names).to include('search_available_slots', 'search_scheduling_services', 'faq_lookup')
        expect(tool_names).not_to include('create_appointment', 'handoff', 'resolve_conversation')

        suggestion_agent = assistant.agent(suggestion_tools: true)
        suggestion_tool_names = suggestion_agent.tools.map(&:name)
        expect(suggestion_tool_names).to include('search_available_slots', 'search_scheduling_services', 'create_appointment', 'faq_lookup')
        expect(suggestion_tool_names).not_to include('handoff', 'resolve_conversation')

        prompt = suggestion_agent.get_system_prompt(
          OpenStruct.new(context: { state: { source: 'reply_suggestion' } })
        )
        expect(prompt).to include('You are drafting a suggested reply for the human clinic operator')
        expect(prompt).to include('pending_operator_approval')
        expect(prompt).not_to include('Call handoff once')

        run_context = Captain::AgentRunContext.new(entry: assistant, conversation: conversation, ephemeral_session: true)
        session = run_context.prepare(state: { source: 'reply_suggestion' })[:agent_session]
        session.update_routing(actor_id: assistant.id, tasks: [{ 'id' => 't1', 'status' => 'active' }])

        expect(conversation.reload.additional_attributes.to_h).not_to have_key(Captain::Conversation::AgentSession::ATTRIBUTE)
      end

      it 'includes pending_actions from AgentRunnerService in the result and suggestion_meta' do
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner_double)
        pending_action = {
          'action_id' => 'act-77',
          'tool_name' => 'create_appointment',
          'agent_name' => 'Координатор',
          'title' => 'Записать на приём',
          'status' => 'pending',
          'details' => [{ 'label' => 'Врач / Ресурс', 'value' => 'Дани' }]
        }
        allow(runner_double).to receive(:generate_response).and_return(
          {
            'response' => 'Можем записать вас к врачу Дани сегодня на 15:00.',
            'agent_id' => assistant.id,
            'agent_display_name' => assistant.name,
            'pending_actions' => [pending_action]
          }
        )

        stored_pending = {
          'action_id' => 'act-78',
          'tool_name' => 'create_task',
          'title' => 'Создать задачу',
          'status' => 'pending',
          'digest' => 'dig-78'
        }
        allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:pending_for)
          .with(account_id: account.id, conversation_id: conversation.id)
          .and_return([stored_pending])

        result = service.perform

        expect(result[:pending_actions]).to eq([pending_action, stored_pending])
        expect(result.dig(:suggestion_meta, 'pending_actions')).to eq([pending_action, stored_pending])
      end

      it 'prevents handoff ping-pong back to visited source agents and enforces 1-transfer limit in reply_suggestion' do
        specialist = create(:captain_assistant, account: account, name: 'ЛОР-специалист', active: true)
        expect(Captain::Runtime::Runner.max_transfers_for({ state: { source: 'reply_suggestion' } })).to eq(1)
        expect(Captain::Runtime::Runner.max_transfers_for({ state: { source: 'incoming_message' } })).to eq(2)

        lazy_entry = Captain::Runtime::LazyAgent.new(assistant, options: { suggestion_tools: true })
        lazy_specialist = Captain::Runtime::LazyAgent.new(specialist, options: { suggestion_tools: true })

        handoff_tool = Captain::Runtime::HandoffTool.new(lazy_entry, source_agent: lazy_specialist)
        tool_ctx = OpenStruct.new(
          run_context: OpenStruct.new(
            context: {
              state: { source: 'reply_suggestion', assistant_id: specialist.id },
              handoff_count: 0,
              visited_handoff_source_ids: [assistant.id]
            }
          )
        )

        ping_pong_result = handoff_tool.perform(tool_ctx)
        expect(ping_pong_result[:error] || ping_pong_result['error']).to eq(Captain::Runtime::HandoffTool::RETURN_TO_SOURCE)

        limit_ctx = OpenStruct.new(
          run_context: OpenStruct.new(
            context: {
              state: { source: 'reply_suggestion', assistant_id: assistant.id },
              handoff_count: 1,
              visited_handoff_source_ids: []
            }
          )
        )
        handoff_to_specialist = Captain::Runtime::HandoffTool.new(lazy_specialist, source_agent: lazy_entry)
        handoff_to_specialist.perform(limit_ctx)
        expect(limit_ctx.run_context.context[:transfer_guard_active]).to be(true)
      end

      it 'omits visited transfer tools in ExecutorResolver and hides clarify in PartPlanTool when < 2 open parts' do
        specialist = create(:captain_assistant, account: account, name: 'ЛОР-специалист', active: true)
        ctx = {
          state: { source: 'reply_suggestion', assistant_id: specialist.id },
          agent_graph: [
            { id: assistant.id, name: assistant.name },
            { id: specialist.id, name: specialist.name }
          ],
          visited_handoff_source_ids: [assistant.id],
          parts: []
        }

        resolver = Captain::Runtime::ExecutorResolver.new(ctx)
        expect do
          resolver.resolve([{ 'executor' => assistant.name, 'fragment' => 'Уточнить цену' }], mode: 'council')
        end.to raise_error(
          Captain::Runtime::ExecutorResolver::RetryableError,
          /handle the request with your own tools and instructions/
        )

        plan_tool_no_open = Captain::Runtime::PartPlanTool.new(ctx)
        expect(plan_tool_no_open.params_schema.dig('properties', 'mode', 'enum')).to eq(['council'])

        ctx_two_open = ctx.merge(
          parts: [
            { 'id' => 'p1', 'state' => 'waiting_customer', 'executor_agent_id' => assistant.id, 'fragment' => 'A' },
            { 'id' => 'p2', 'state' => 'waiting_customer', 'executor_agent_id' => assistant.id, 'fragment' => 'B' }
          ]
        )
        plan_tool_two_open = Captain::Runtime::PartPlanTool.new(ctx_two_open)
        expect(plan_tool_two_open.params_schema.dig('properties', 'mode', 'enum')).to include('council', 'clarify')
      end

      it 'preserves outer user_id in Llm::EventBus.with_context across nested contexts' do
        captured_context = nil
        Llm::EventBus.with_context(user_id: agent.id, source: 'reply_suggestion') do
          Llm::EventBus.with_context(assistant_id: assistant.id) do
            captured_context = Llm::EventBus.snapshot_context
          end
        end

        expect(captured_context['user_id']).to eq(agent.id)
        expect(captured_context['assistant_id']).to eq(assistant.id)
      end

      it 'falls back to standard prompt suggestion if AgentRunnerService returns conversation_handoff' do
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner_double)
        allow(runner_double).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })

        result = service.perform

        expect(result[:message]).to eq('Sure, I can help!')
      end

      it 'falls back to standard prompt suggestion if AgentRunnerService raises Timeout::Error' do
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner_double)
        allow(runner_double).to receive(:generate_response).and_raise(Timeout::Error.new('execution expired'))

        result = service.perform

        expect(result[:message]).to eq('Sure, I can help!')
      end

      def stub_council_runner_execution(entry_assistant, specialist)
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        captured_callbacks = nil
        allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**kwargs|
          captured_callbacks = kwargs[:callbacks]
          runner_double
        end

        allow(runner_double).to receive(:generate_response) do
          simulate_council_callbacks(captured_callbacks, entry_assistant, specialist)
          {
            'response' => 'Ближайшее окно к Дани сегодня в 15:00.',
            'agent_id' => entry_assistant.id,
            'agent_display_name' => entry_assistant.name,
            'council_contributors' => [
              { 'id' => entry_assistant.id, 'name' => entry_assistant.name },
              { 'id' => specialist.id, 'name' => specialist.name }
            ]
          }
        end
      end

      def simulate_council_callbacks(callbacks, entry_assistant, specialist)
        simulate_plan_callbacks(callbacks, entry_assistant, specialist)
        simulate_specialist_callbacks(callbacks, specialist)
      end

      def simulate_plan_callbacks(callbacks, entry_assistant, specialist)
        plan_ctx = OpenStruct.new(
          context: {
            state: { assistant_id: entry_assistant.id },
            part_plan: {
              mode: 'council',
              parts: [{ 'id' => 1, 'executor_agent_id' => specialist.id, 'fragment' => 'Болит ухо, нужно к Дани', 'patient' => 'self' }]
            }
          }
        )
        callbacks[:on_agent_thinking].call(entry_assistant.agent_name, 'I need help', plan_ctx)
        callbacks[:on_tool_start].call('plan_request', { mode: 'council' }, plan_ctx)
        callbacks[:on_tool_complete].call('plan_request', { status: 'planned' }, plan_ctx)
      end

      def simulate_specialist_callbacks(callbacks, specialist)
        part_ctx = OpenStruct.new(
          context: {
            part_run: true, active_part_id: 1, current_agent: specialist.agent_name, state: { assistant_id: specialist.id },
            part_info: { id: 1, fragment: 'Болит ухо, нужно к Дани', patient: 'self' }
          }
        )
        callbacks[:on_agent_thinking].call(specialist.agent_name, 'Болит ухо, нужно к Дани', part_ctx)
        callbacks[:on_tool_start].call('search_available_slots', { resource: 'Дани' }, part_ctx)
        callbacks[:on_tool_complete].call('search_available_slots', { slots: ['15:00'] }, part_ctx)
        llm_json = {
          status: 'answered', patient_language: 'ru', customer_text: 'Ближайшее окно к Дани сегодня в 15:00.',
          questions: [], sources: ['search_available_slots'], suggested_agent: '', reasoning: 'Найдено свободное время у врача Дани на 15:00.'
        }.to_json
        llm_msg = instance_double(RubyLLM::Message, tool_call?: false, content: llm_json)
        callbacks[:on_llm_call_complete].call(specialist.agent_name, 'gpt-5.4-mini', llm_msg, part_ctx)
      end
    end
  end
end
