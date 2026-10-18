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
        expect(Captain::Assistant::AgentRunnerService).to receive(:new).with(
          assistant: assistant,
          conversation: conversation,
          source: 'reply_suggestion'
        ).and_return(runner_double)

        expect(runner_double).to receive(:generate_response).with(
          message_history: [{ role: 'user', content: 'I need help' }]
        ).and_return(
          {
            'response' => 'Available slots for Dr. Smith tomorrow are 10:00 and 14:30.',
            'usage' => { 'prompt_tokens' => 120, 'completion_tokens' => 30, 'total_tokens' => 150 }
          }
        )

        result = service.perform

        expect(result[:message]).to eq('Available slots for Dr. Smith tomorrow are 10:00 and 14:30.')
        expect(result[:usage]).to eq({ 'prompt_tokens' => 120, 'completion_tokens' => 30, 'total_tokens' => 150 })
        expect(result.dig(:follow_up_context, :event_name)).to eq('reply_suggestion')
        expect(result.dig(:follow_up_context, :last_response)).to eq('Available slots for Dr. Smith tomorrow are 10:00 and 14:30.')
        expect(result.dig(:follow_up_context, :original_context)).to include('User: I need help')
      end

      it 'builds read-only agent tools and ephemeral session without mutating conversation additional_attributes' do
        runtime_agent = assistant.agent(read_only_tools: true)
        tool_names = runtime_agent.tools.map(&:name)

        expect(tool_names).to include('search_available_slots', 'search_scheduling_services', 'faq_lookup')
        expect(tool_names).not_to include('create_appointment', 'handoff', 'resolve_conversation')

        prompt = runtime_agent.get_system_prompt(
          OpenStruct.new(context: { state: { source: 'reply_suggestion' } })
        )
        expect(prompt).to include('You are drafting a suggested reply for the human clinic operator')
        expect(prompt).not_to include('Call handoff once')

        run_context = Captain::AgentRunContext.new(entry: assistant, conversation: conversation, ephemeral_session: true)
        session = run_context.prepare(state: {})[:agent_session]
        session.update_routing(actor_id: assistant.id, tasks: [{ 'id' => 't1', 'status' => 'active' }])

        expect(conversation.reload.additional_attributes.to_h).not_to have_key(Captain::Conversation::AgentSession::ATTRIBUTE)
      end

      it 'falls back to standard prompt suggestion if AgentRunnerService returns conversation_handoff' do
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner_double)
        allow(runner_double).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })

        result = service.perform

        expect(result[:message]).to eq('Sure, I can help!')
      end
    end
  end
end
