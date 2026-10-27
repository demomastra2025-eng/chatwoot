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
          callbacks: kind_of(Hash),
          request_id: nil
        ).and_return(runner_double)

        allow(runner_double).to receive(:generate_response).with(
          message_history: [{ role: 'user', content: 'I need help', sent_at: kind_of(ActiveSupport::TimeWithZone) }]
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
        session.update_routing(actor_id: assistant.id, trail: { 'kind' => 'agent', 'to' => [assistant.id] })

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
        # The check of a silence reads the cards of the conversation too (Captain::Runtime::AgreedVisit), without a request.
        allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:pending_for)
          .with(account_id: account.id, conversation_id: conversation.id).and_return([])
        allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:pending_for)
          .with(account_id: account.id, conversation_id: conversation.id, request_id: 'req-1')
          .and_return([stored_pending])
        own_request = described_class.new(account: account, conversation_display_id: conversation.display_id, user: agent, request_id: 'req-1',
                                          progress_context: { suggestion_request_id: 'req-1' })

        result = own_request.perform

        expect(result[:pending_actions]).to eq([pending_action, stored_pending])
        expect(result.dig(:suggestion_meta, 'pending_actions')).to eq([pending_action, stored_pending])
      end

      it 'does not add the pending cards of earlier suggestions to a new one' do
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner_double)
        allow(runner_double).to receive(:generate_response).and_return({ 'response' => 'Окно завтра в 10:00.', 'agent_id' => assistant.id })
        Captain::ReplySuggestion::ActionApprovalService.store_record!(
          'action_id' => 'earlier-card', 'account_id' => account.id, 'conversation_id' => conversation.id, 'status' => 'pending',
          'tool_name' => 'create_appointment', 'digest' => 'dig-earlier', 'suggestion_request_id' => 'earlier-request'
        )
        new_request = described_class.new(account: account, conversation_display_id: conversation.display_id, user: agent, request_id: 'req-2',
                                          progress_context: { suggestion_request_id: 'req-2' })

        result = new_request.perform

        expect(result[:pending_actions]).to eq([])
      end

      it 'shows again the kept cards of a suggestion the manager inserted, which still wait for approval' do
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner_double)
        allow(runner_double).to receive(:generate_response).and_return({ 'response' => 'Окно завтра в 10:00.', 'agent_id' => assistant.id })
        Captain::ReplySuggestion::ActionApprovalService.store_record!(
          'action_id' => 'kept-card', 'account_id' => account.id, 'conversation_id' => conversation.id, 'status' => 'pending',
          'tool_name' => 'create_appointment', 'digest' => 'dig-kept', 'suggestion_request_id' => 'applied-request',
          'kept_at' => Time.current.iso8601
        )
        new_request = described_class.new(account: account, conversation_display_id: conversation.display_id, user: agent, request_id: 'req-3',
                                          progress_context: { suggestion_request_id: 'req-3' })

        result = new_request.perform

        expect(result[:pending_actions].pluck('action_id')).to eq(['kept-card'])
      end

      it 'records the decision of the router and the agent it routed to' do
        specialist = create(:captain_assistant, account: account, name: 'ЛОР-специалист', active: true)
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        captured_callbacks = nil
        allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**kwargs|
          captured_callbacks = kwargs[:callbacks]
          runner_double
        end
        decision = { decision_key: "route_agent_#{specialist.id}", kind: 'agent', target_ids: [specialist.id], from_agent_id: assistant.id,
                     decided_by: 'inception/mercury-decide', confidence: 0.91 }
        allow(runner_double).to receive(:generate_response) do
          captured_callbacks[:on_agent_routed].call(decision, nil)
          { 'response' => 'Можем записать вас к ЛОРу.', 'agent_id' => specialist.id, 'agent_display_name' => specialist.name }
        end

        meta = service.perform[:suggestion_meta]

        expect(meta['routing']).to include('decision_key' => "route_agent_#{specialist.id}", 'decided_by' => 'inception/mercury-decide',
                                           'confidence' => 0.91)
        expect(meta['handoffs']).to eq([{ 'from' => assistant.name, 'to' => specialist.name, 'reason' => "route_agent_#{specialist.id}" }])
        expect(meta['working_agents'].find { |item| item['name'] == specialist.name }).to include('role' => 'routed')
        expect(captured_callbacks).not_to have_key(:on_agent_handoff)
      end

      it 'ends a message that needs no answer as no_reply of the router, with no agent shown at work' do
        sticky = create(:captain_assistant, account: account, name: 'ЛОР-специалист', active: true)
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        captured_callbacks = nil
        allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**kwargs|
          captured_callbacks = kwargs[:callbacks]
          runner_double
        end
        decision = { decision_key: 'no_reply_needed', kind: 'no_reply', target_ids: [sticky.id], decided_by: 'perplexity/pplx-decider-v1.2',
                     confidence: 0.97 }
        note = I18n.t('captain.reply_suggestion.reasons.router_no_reply')
        allow(runner_double).to receive(:generate_response) do
          captured_callbacks[:on_agent_routed].call(decision, nil)
          { 'response' => '', 'response_mode' => 'suppress', 'operator_note' => note, 'routing_no_reply' => true, 'agent_id' => assistant.id }
        end

        result = service.perform
        meta = service.instance_variable_get(:@trace_collector).suggestion_meta({})

        expect(result).to include(outcome: 'no_reply', reason: note, reason_source: 'router', agent: nil)
        expect(meta['routing']).to include('kind' => 'no_reply', 'confidence' => 0.97)
        expect(Array(meta['working_agents']).pluck('name')).not_to include(sticky.name)
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

      describe 'when the agent does not give a reply' do
        let(:runner_double) { instance_double(Captain::Assistant::AgentRunnerService) }

        before { allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner_double) }

        it 'ends as failed when the agent returns a handoff, and never runs the one-shot prompt' do
          allow(runner_double).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })

          result = service.perform

          expect(result).to include(outcome: 'failed', reason_code: 'invalid_output')
          expect(result[:message]).to be_nil
          expect(captured_messages).to be_empty
        end

        it 'lets a timeout out of the service for the job to settle, and never runs the one-shot prompt' do
          allow(runner_double).to receive(:generate_response).and_raise(Timeout::Error.new('execution expired'))

          expect { service.perform }.to raise_error(Timeout::Error)
          expect(captured_messages).to be_empty
        end

        it 'ends as failed with internal_error on an unexpected error, and never runs the one-shot prompt' do
          allow(runner_double).to receive(:generate_response).and_raise(ArgumentError, 'boom')

          result = service.perform

          expect(result).to include(outcome: 'failed', reason_code: 'internal_error', error_class: 'ArgumentError')
          expect(captured_messages).to be_empty
        end

        it 'does not wrap a stop of the run (cancel, deadline) into a result' do
          allow(runner_double).to receive(:generate_response).and_raise(Captain::ReplySuggestion::RunAborted.new(:cancelled, 'tool'))

          expect { service.perform }.to raise_error(Captain::ReplySuggestion::RunAborted)
          expect(captured_messages).to be_empty
        end

        it 'answers no_reply with the note of the agent' do
          allow(runner_double).to receive(:generate_response).and_return(
            { 'response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true, 'operator_note' => 'Пациент только поблагодарил.',
              'agent_id' => assistant.id, 'agent_display_name' => assistant.name }
          )

          result = service.perform

          expect(result).to include(outcome: 'no_reply', reason: 'Пациент только поблагодарил.', reason_source: 'agent', engine: 'agent')
          expect(result.dig(:agent, 'name')).to eq('Координатор')
        end

        # Suggestion eval 26.10 (Sezim): «Отмена завтра» and an emoji after it got «emoji only» as a no_reply.
        def emoji_only_no_reply
          { 'response' => '', 'response_mode' => 'suppress', 'response_suppressed' => true, 'operator_note' => 'Пациент отправил только эмодзи.',
            'agent_id' => assistant.id, 'agent_display_name' => assistant.name }
        end

        it 'turns a no_reply into human_needed when the unanswered messages ask to cancel, whichever message came last' do
          create(:message, conversation: conversation, message_type: :incoming, content: 'Отмена завтра')
          create(:message, conversation: conversation, message_type: :incoming, content: '💐🌷')
          allow(runner_double).to receive(:generate_response).and_return(emoji_only_no_reply)

          expect(service.perform).to include(outcome: 'human_needed', reason: I18n.t('captain.reply_suggestion.reasons.swallowed_request'))
        end

        it 'leaves a no_reply as it is when the request was answered before the thanks' do
          create(:message, conversation: conversation, message_type: :incoming, content: 'Отмена завтра')
          create(:message, conversation: conversation, message_type: :outgoing, content: 'Отменили, хорошего дня!')
          create(:message, conversation: conversation, message_type: :incoming, content: 'Спасибо')
          allow(runner_double).to receive(:generate_response).and_return(emoji_only_no_reply)

          expect(service.perform).to include(outcome: 'no_reply', reason: 'Пациент отправил только эмодзи.')
        end

        # Review of quality-fixes-1 (M1): staff offered a time without a question mark and the patient said yes; nothing is booked by a silence.
        it 'turns a no_reply into human_needed when the patient accepts a time that the last message of staff offered' do
          create(:message, conversation: conversation, message_type: :incoming, content: 'Хочу на УЗИ щитовидной железы')
          create(:message, conversation: conversation, message_type: :outgoing, content: 'Есть окно завтра в 14:00.')
          create(:message, conversation: conversation, message_type: :incoming, content: 'Да, подходит')
          allow(runner_double).to receive(:generate_response).and_return(emoji_only_no_reply)

          expect(service.perform).to include(outcome: 'human_needed', reason: I18n.t('captain.reply_suggestion.reasons.unsafe_silence'))
        end

        it 'turns a no_reply into human_needed when the patient confirms a visit that nobody booked' do
          create(:message, conversation: conversation, message_type: :outgoing, content: 'Ждём вас завтра.')
          create(:message, conversation: conversation, message_type: :incoming, content: 'Спасибо, буду')
          allow(runner_double).to receive(:generate_response).and_return(emoji_only_no_reply)

          expect(service.perform).to include(outcome: 'human_needed', reason: I18n.t('captain.reply_suggestion.reasons.unsafe_silence'))
        end

        it 'keeps a no_reply for the confirmation of a visit the contact has' do
          create(:message, conversation: conversation, message_type: :outgoing, content: 'Ждём вас завтра.')
          create(:message, conversation: conversation, message_type: :incoming, content: 'Спасибо, буду')
          create(:scheduling_appointment, account: account, contact: conversation.contact, resource: create(:scheduling_resource, account: account),
                                          starts_at: 1.day.from_now, ends_at: 1.day.from_now + 30.minutes)
          allow(runner_double).to receive(:generate_response).and_return(emoji_only_no_reply)

          expect(service.perform).to include(outcome: 'no_reply', reason: 'Пациент отправил только эмодзи.')
        end

        it 'answers human_needed with the note of the agent' do
          allow(runner_double).to receive(:generate_response).and_return(
            { 'response' => '', 'response_mode' => 'human', 'operator_note' => 'В базе нет ответа про оперирующего ЛОРа.' }
          )

          expect(service.perform).to include(outcome: 'human_needed', reason: 'В базе нет ответа про оперирующего ЛОРа.')
        end
      end

      describe 'the engine of the request' do
        it 'is the agent when the account has one' do
          expect(service.suggestion_engine).to eq(engine: 'agent', assistant_id: assistant.id)
        end

        it 'keeps the engine the request started with: a deleted agent fails the run, the one-shot prompt does not take over' do
          assistant_id = assistant.id
          assistant.destroy!
          fixed_engine = described_class.new(
            account: account, conversation_display_id: conversation.display_id, user: agent, engine: 'agent', assistant_id: assistant_id
          )

          result = fixed_engine.perform

          expect(result).to include(outcome: 'failed', reason_code: 'agent_unavailable')
          expect(captured_messages).to be_empty
        end

        it 'runs the one-shot prompt when the request was started without an agent, even if an agent exists now' do
          fixed_engine = described_class.new(
            account: account, conversation_display_id: conversation.display_id, user: agent, engine: 'legacy_prompt'
          )
          expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

          result = fixed_engine.perform

          expect(result).to include(outcome: 'draft', message: 'Sure, I can help!', engine: 'legacy_prompt')
        end

        it 'puts the request id on the events of the one-shot prompt' do
          legacy = described_class.new(
            account: account, conversation_display_id: conversation.display_id, user: agent, engine: 'legacy_prompt', request_id: 'req-9'
          )

          expect(legacy.send(:request_event_context, 'gpt-5.4-mini')).to include(request_id: 'req-9')
        end
      end

      describe 'the history of the agent' do
        let(:image_message) { create(:message, conversation: conversation, message_type: :incoming, content: 'Вот снимок') }
        let(:runner_double) { instance_double(Captain::Assistant::AgentRunnerService) }
        let(:received_history) { [] }

        before do
          allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner_double)
          allow(runner_double).to receive(:generate_response) do |message_history:|
            received_history.replace(message_history)
            { 'response' => 'Хорошо.', 'agent_id' => assistant.id, 'agent_display_name' => assistant.name }
          end
        end

        it 'describes every image of the history through the parallel describer, never one at a time inside the message builder' do
          attachment = image_message.attachments.create!(account_id: account.id, file_type: :image, external_url: 'https://example.com/a.jpg')
          describer = instance_double(Captain::ReplySuggestion::ImageDescriber, perform: { attachment.id => 'Снимок уха' })
          allow(Captain::ReplySuggestion::ImageDescriber).to receive(:new).and_return(describer)
          expect(Captain::ImageRecognitionService).not_to receive(:new)

          service.perform

          parts = received_history.last[:content]
          expect(parts).to include({ type: 'text', text: 'Image attachment: Снимок уха' })
        end
      end

      # A change repeated at a corrected time replaces its card in the run: the operator must not see, and approve, the first one. The
      # panel showed it live, so the progress and the result name it for the panel to drop.
      it 'leaves out a card that a corrected card of the same run replaced, and names it in the progress and the result' do
        progress = []
        allow(ActionCable.server).to receive(:broadcast) { |_stream, payload| progress << payload[:data] }
        runner_double = instance_double(Captain::Assistant::AgentRunnerService)
        captured_callbacks = nil
        allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**kwargs|
          captured_callbacks = kwargs[:callbacks]
          runner_double
        end
        first_card = { 'action_id' => 'act-10', 'tool_name' => 'update_appointment', 'title' => 'Перенести запись', 'status' => 'pending' }
        second_card = first_card.merge('action_id' => 'act-11')
        allow(runner_double).to receive(:generate_response) do
          run = OpenStruct.new(context: { captain_suggestion_pending_actions: [first_card] })
          captured_callbacks[:on_tool_complete].call('update_appointment', '{"status":"pending_operator_approval"}', run)
          run.context.merge!(captain_suggestion_pending_actions: [second_card], captain_suggestion_superseded_actions: ['act-10'])
          captured_callbacks[:on_tool_complete].call('update_appointment', '{"status":"pending_operator_approval"}', run)
          { 'response' => 'Подготовила перенос на 11:30.', 'agent_id' => assistant.id, 'pending_actions' => [first_card, second_card] }
        end
        allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:pending_for).and_return([])

        result = service.perform

        expect(result[:pending_actions].pluck('action_id')).to eq(['act-11'])
        expect(result[:superseded_action_ids]).to eq(['act-10'])
        expect(result.dig(:suggestion_meta, 'superseded_action_ids')).to eq(['act-10'])
        expect(Captain::ReplySuggestion::Outcome.public_result(result)).to include('superseded_action_ids' => ['act-10'])
        expect(progress).to include(hash_including(superseded_action_ids: ['act-10'], pending_actions: [second_card]))
      end

      describe 'the live progress' do
        it 'carries the request id, the id the client sent and the timing of the request' do
          allow(ActionCable.server).to receive(:broadcast)
          started_at = Time.zone.parse('2026-10-24 09:12:03 UTC')
          progress_service = described_class.new(
            account: account, conversation_display_id: conversation.display_id, user: agent, request_id: 'req-1',
            progress_context: {
              suggestion_request_id: 'req-1', conversation_id: 7001, started_at: started_at, deadline_at: started_at + 60, budget_seconds: 60
            }
          )
          runner_double = instance_double(Captain::Assistant::AgentRunnerService)
          allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner_double)
          allow(runner_double).to receive(:generate_response).and_return({ 'response' => 'Хорошо.', 'agent_id' => assistant.id })
          allow(Captain::ReplySuggestion::RequestStore).to receive(:write_progress)

          progress_service.perform

          expect(ActionCable.server).to have_received(:broadcast).with(
            agent.pubsub_token,
            hash_including(
              event: 'captain.reply_suggestion.progress',
              data: hash_including(
                suggestion_request_id: 'req-1', status: 'running', conversation_id: 7001, conversation_record_id: conversation.id,
                started_at: '2026-10-24T09:12:03.000Z', deadline_at: '2026-10-24T09:13:03.000Z', budget_seconds: 60
              )
            )
          ).at_least(:once)
          expect(Captain::ReplySuggestion::RequestStore).to have_received(:write_progress)
            .with('req-1', hash_including(phase: 'thinking')).at_least(:once)
        end

        it 'shows that the router chooses the agent, and no agent thinking, until it has chosen' do
          assistant.update!(routing_description: 'Общие вопросы о клинике')
          specialist = create(:captain_assistant, account: account, name: 'ЛОР-специалист', active: true, routing_description: 'Запись к ЛОРу')
          progress = []
          allow(ActionCable.server).to receive(:broadcast) { |_stream, payload| progress << payload[:data] }
          runner_double = instance_double(Captain::Assistant::AgentRunnerService)
          captured_callbacks = nil
          allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**kwargs|
            captured_callbacks = kwargs[:callbacks]
            runner_double
          end
          allow(runner_double).to receive(:generate_response) do
            captured_callbacks[:on_agent_routed].call({ decision_key: "route_agent_#{specialist.id}", kind: 'agent', target_ids: [specialist.id] },
                                                      nil)
            { 'response' => 'Можем записать вас к ЛОРу.', 'agent_id' => specialist.id }
          end

          service.perform

          expect(progress.first).to include(phase: 'routing')
          expect(progress.first).not_to have_key(:active_agent)
          expect(progress.last).to include(phase: 'thinking', active_agent: include('id' => specialist.id))
        end
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
        simulate_routing_callbacks(callbacks, entry_assistant, specialist)
        simulate_specialist_callbacks(callbacks, specialist)
      end

      # The router chose a council of exactly the anchor and the specialist.
      def simulate_routing_callbacks(callbacks, entry_assistant, specialist)
        callbacks[:on_agent_routed].call(
          { decision_key: "council_#{entry_assistant.id}_#{specialist.id}", kind: 'council', target_ids: [entry_assistant.id, specialist.id],
            decided_by: 'inception/mercury-decide' }, nil
        )
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
          questions: [], sources: ['search_available_slots'], reasoning: 'Найдено свободное время у врача Дани на 15:00.'
        }.to_json
        llm_msg = instance_double(RubyLLM::Message, tool_call?: false, content: llm_json)
        callbacks[:on_llm_call_complete].call(specialist.agent_name, 'gpt-5.4-mini', llm_msg, part_ctx)
      end
    end
  end
end
