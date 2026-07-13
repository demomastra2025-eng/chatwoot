require 'rails_helper'

RSpec.describe Captain::Conversation::ResponseBuilderJob, type: :job do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe '#perform' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }

    before do
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
      create(:message, conversation: conversation, content: 'Hello', message_type: :incoming)
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(agent_runner_service)
      allow(agent_runner_service).to receive(:generate_response).and_return({ 'response' => 'Hey, welcome to Captain V2' })
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_on)
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    end

    def create_sendable_document(name: 'Price list', filename: 'price-list.pdf')
      build(:captain_document, assistant: assistant, account: account, name: name, external_link: nil, status: :available).tap do |document|
        document.pdf_file.attach(
          io: StringIO.new('%PDF-1.4 file'),
          filename: filename,
          content_type: 'application/pdf'
        )
        document.save!
      end
    end

    def document_artifact_payload(document)
      document.reload

      Captain::Tools::DocumentArtifactToken.encode(
        account_id: account.id,
        assistant_id: assistant.id,
        document_id: document.id,
        blob_id: document.sendable_file_blob_id,
        status: document.status,
        document_fingerprint: document.artifact_fingerprint
      )
    end

    def list_documents_trace(*documents)
      {
        'version' => 1,
        'tool_steps' => [
          {
            'event' => 'finish',
            'tool_name' => 'list_captain_documents',
            'output' => {
              'success' => true,
              'message' => JSON.generate(
                'action' => 'list_captain_documents',
                'documents' => documents.map do |document|
                  {
                    'document_id' => document.id,
                    'name' => document.name,
                    'source_mode' => document.source_mode,
                    'status' => document.status,
                    'content_type' => document.content_type,
                    'file_size' => document.file_size,
                    'sendable' => true,
                    'filename' => document.sendable_filename,
                    'artifact_id' => document_artifact_payload(document)
                  }
                end
              )
            }
          }
        ]
      }
    end

    it 'uses Captain::Assistant::AgentRunnerService with runtime callbacks' do
      expect(Captain::Assistant::AgentRunnerService).to receive(:new).with(
        assistant: assistant,
        conversation: conversation,
        callbacks: hash_including(
          on_agent_thinking: kind_of(Proc),
          on_tool_start: kind_of(Proc),
          on_tool_complete: kind_of(Proc)
        )
      ).and_return(agent_runner_service)

      described_class.perform_now(conversation, assistant)

      expect(conversation.messages.last.content).to eq('Hey, welcome to Captain V2')
    end

    it 'turns the manager typing indicator on and off around response generation' do
      described_class.perform_now(conversation, assistant)

      expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_on).with(
        conversation: conversation,
        assistant: assistant
      ).at_least(:once)
      expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_off).with(
        conversation: conversation,
        assistant: assistant
      ).once
    end

    it 'passes message history to the agent runner service' do
      expect(agent_runner_service).to receive(:generate_response).with(
        message_history: [{ content: 'Hello', role: 'user' }]
      )

      described_class.perform_now(conversation, assistant)
    end

    it 'infers scenario agent_name from captain trace when legacy messages are missing explicit attribution' do
      conversation.messages.destroy_all
      create(
        :message,
        conversation: conversation,
        content: 'Start scenario',
        message_type: :incoming
      )
      create(
        :message,
        conversation: conversation,
        content: 'Scenario answer',
        message_type: :outgoing,
        sender: assistant,
        additional_attributes: {
          captain_trace: {
            version: 1,
            tool_steps: [
              {
                event: 'complete',
                tool_name: 'handoff_to_scenario_35_andalusiya_agent'
              }
            ]
          }
        }
      )
      create(
        :message,
        conversation: conversation,
        content: 'Continue please',
        message_type: :incoming
      )

      expect(agent_runner_service).to receive(:generate_response).with(
        message_history: [
          { content: 'Start scenario', role: 'user' },
          {
            content: 'Scenario answer',
            role: 'assistant',
            agent_name: 'scenario_35_andalusiya_agent'
          },
          { content: 'Continue please', role: 'user' }
        ]
      )

      described_class.perform_now(conversation, assistant)
    end

    it 'generates and processes a response' do
      described_class.perform_now(conversation, assistant)

      expect(conversation.messages.count).to eq(2)
      expect(conversation.messages.outgoing.count).to eq(1)
      expect(conversation.messages.last.content).to eq('Hey, welcome to Captain V2')
    end

    it 'increments usage response' do
      described_class.perform_now(conversation, assistant)

      account.reload
      expect(account.usage_limits[:captain][:responses][:consumed]).to eq(1)
    end

    it 'does not send a response when the conversation is no longer pending' do
      conversation.open!

      expect(agent_runner_service).not_to receive(:generate_response)

      expect do
        described_class.perform_now(conversation, assistant)
      end.not_to(change { conversation.messages.outgoing.count })
    end

    it 'sends a response for open conversations when enabled on the Captain inbox' do
      inbox.captain_inbox.update!(reply_to_open_conversations: true)
      conversation.open!

      expect do
        described_class.perform_now(conversation, assistant)
      end.to change { conversation.messages.outgoing.count }.by(1)

      expect(conversation.messages.outgoing.last.content).to eq('Hey, welcome to Captain V2')
    end

    it 'skips a bufferless stale job when a newer incoming message exists' do
      stale_last_message_id = conversation.messages.incoming.last.id
      create(:message, conversation: conversation, content: 'Newer incoming', message_type: :incoming)

      expect(agent_runner_service).not_to receive(:generate_response)

      expect do
        described_class.perform_now(conversation, assistant, expected_last_message_id: stale_last_message_id)
      end.not_to(change { conversation.messages.outgoing.count })
    end

    it 'does not persist a bufferless response if a newer incoming arrives during generation' do
      expected_last_message_id = conversation.messages.incoming.last.id
      expect(agent_runner_service).to receive(:generate_response) do
        create(:message, conversation: conversation, content: 'Interrupting incoming', message_type: :incoming)
        { 'response' => 'Late stale response' }
      end

      expect do
        described_class.perform_now(conversation, assistant, expected_last_message_id: expected_last_message_id)
      end.not_to(change { conversation.messages.outgoing.count })
    end

    it 'skips a buffered stale job when the latest incoming no longer matches the buffer state' do
      buffer_token = SecureRandom.uuid
      expected_last_message_id = conversation.messages.incoming.last.id
      state_key = format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id)
      Redis::Alfred.set(
        state_key,
        {
          token: buffer_token,
          assistant_id: assistant.id,
          last_message_id: expected_last_message_id
        }.to_json,
        ex: 10.minutes.to_i
      )
      create(:message, conversation: conversation, content: 'Newer incoming', message_type: :incoming)

      expect(agent_runner_service).not_to receive(:generate_response)

      expect do
        described_class.perform_now(
          conversation,
          assistant,
          buffer_token: buffer_token,
          expected_last_message_id: expected_last_message_id
        )
      end.not_to(change { conversation.messages.outgoing.count })
    ensure
      Redis::Alfred.delete(state_key) if defined?(state_key)
    end

    it 'does not persist a buffered response if a newer incoming arrives during generation' do
      buffer_token = SecureRandom.uuid
      expected_last_message_id = conversation.messages.incoming.last.id
      state_key = format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id)
      Redis::Alfred.set(
        state_key,
        {
          token: buffer_token,
          assistant_id: assistant.id,
          last_message_id: expected_last_message_id
        }.to_json,
        ex: 10.minutes.to_i
      )
      expect(agent_runner_service).to receive(:generate_response) do
        create(:message, conversation: conversation, content: 'Interrupting incoming', message_type: :incoming)
        { 'response' => 'Late stale response' }
      end

      expect do
        described_class.perform_now(
          conversation,
          assistant,
          buffer_token: buffer_token,
          expected_last_message_id: expected_last_message_id
        )
      end.not_to(change { conversation.messages.outgoing.count })
    ensure
      Redis::Alfred.delete(state_key) if defined?(state_key)
    end

    it 'silently skips outgoing messages when the assistant cancels its own response' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'response_cancelled',
          'response_cancelled' => true,
          'cancel_reason' => 'Acknowledgement does not need a reply',
          'usage' => { 'total_tokens' => 42 }
        }
      )

      expect do
        described_class.perform_now(conversation, assistant)
      end.not_to(change { conversation.messages.outgoing.count })

      expect(conversation.reload.status).to eq('pending')
      expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(0)
    end

    it 'skips generation when a manager has cancelled the pending response' do
      cancellation_key = format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: conversation.id)
      last_incoming_message_id = conversation.messages.incoming.last.id
      Redis::Alfred.set(
        cancellation_key,
        {
          assistant_id: assistant.id,
          last_message_id: last_incoming_message_id,
          cancelled_at: Time.current.iso8601
        }.to_json,
        ex: 10.minutes.to_i
      )

      expect(agent_runner_service).not_to receive(:generate_response)

      expect do
        described_class.perform_now(conversation, assistant, expected_last_message_id: last_incoming_message_id)
      end.not_to(change { conversation.messages.count })

      expect(Redis::Alfred.get(cancellation_key)).to be_nil
    ensure
      Redis::Alfred.delete(cancellation_key) if defined?(cancellation_key)
    end

    it 'does not turn typing back on when manager cancellation happens during runtime callbacks' do
      callbacks = nil
      last_incoming_message_id = conversation.messages.incoming.last.id

      allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |**kwargs|
        expect(kwargs[:assistant]).to eq(assistant)
        expect(kwargs[:conversation]).to eq(conversation)
        callbacks = kwargs[:callbacks]
        agent_runner_service
      end

      allow(agent_runner_service).to receive(:generate_response) do
        Captain::Conversation::ResponseCancellationService.new(
          conversation: conversation,
          assistant: assistant
        ).perform(reason: 'Manager stopped the response')
        callbacks[:on_tool_start].call('lookup_order')
        { 'response' => 'This late answer must be ignored' }
      end

      expect do
        described_class.perform_now(conversation, assistant, expected_last_message_id: last_incoming_message_id)
      end.not_to(change { conversation.messages.count })

      expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_on).with(
        conversation: conversation,
        assistant: assistant
      ).once
      expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_off).with(
        conversation: conversation,
        assistant: assistant
      ).at_least(:once)
    end

    it 'keeps manager cancellation silent when a late runtime error is raised' do
      last_incoming_message_id = conversation.messages.incoming.last.id

      allow(agent_runner_service).to receive(:generate_response) do
        Captain::Conversation::ResponseCancellationService.new(
          conversation: conversation,
          assistant: assistant
        ).perform(reason: 'Manager stopped the response')
        raise StandardError, 'provider failed after cancellation'
      end

      expect do
        described_class.perform_now(conversation, assistant, expected_last_message_id: last_incoming_message_id)
      end.not_to(change { conversation.messages.count })

      expect(conversation.reload.status).to eq('pending')
      expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(0)
    end

    it 'does not persist raw provider error details in the handoff private note' do
      allow(agent_runner_service).to receive(:generate_response) do
        raise StandardError, 'RubyLLM::PaymentRequiredError: OpenRouter credits exhausted for max_tokens=4096'
      end

      described_class.perform_now(conversation, assistant)

      private_note = conversation.reload.messages.outgoing.where(private: true).last
      expect(private_note.content).to eq(
        'Automatic reply could not be generated. Handoff to human agent was triggered.'
      )
      expect(private_note.content).not_to include('RubyLLM')
      expect(private_note.content).not_to include('OpenRouter')
      expect(private_note.content).not_to include('max_tokens')
      expect(conversation.status).to eq('open')
    end

    it 'stores captain trace on the outgoing message when provided by the assistant runtime' do
      trace_payload = Captain::ToolTraceBuilder.payload([
                                                          Captain::ToolTraceBuilder.step(
                                                            tool_name: 'search_documentation',
                                                            event: 'start',
                                                            sequence: 1
                                                          ),
                                                          Captain::ToolTraceBuilder.step(
                                                            tool_name: 'search_documentation',
                                                            event: 'complete',
                                                            sequence: 2
                                                          )
                                                        ])
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Hey, welcome to Captain V2',
          'captain_trace' => trace_payload
        }
      )

      described_class.perform_now(conversation, assistant)

      expect(conversation.reload.messages.outgoing.last.additional_attributes['captain_trace']).to eq(trace_payload)
    end

    it 'stores the scenario title in the existing agentName display field while preserving the runtime agent_name key' do
      scenario = create(
        :captain_scenario,
        assistant: assistant,
        account: account,
        title: 'Andalusiya Premium Reception Scenario'
      )

      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Handled by scenario',
          'agent_name' => scenario.handoff_key
        }
      )

      described_class.perform_now(conversation, assistant)

      attrs = conversation.reload.messages.outgoing.last.additional_attributes
      expect(attrs['agent_name']).to eq(scenario.handoff_key)
      expect(attrs['agentName']).to eq('Andalusiya Premium Reception Scenario')
    end

    it 'auto-attaches the only listed sendable Captain document when the final response omitted artifact_ids' do
      conversation.messages.incoming.last.update!(content: 'вышли мне документ')
      document = create_sendable_document(name: 'КП MACRO', filename: 'macro.pdf')

      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Да, отправляю документ.',
          'artifact_ids' => [],
          'captain_trace' => list_documents_trace(document)
        }
      )

      described_class.perform_now(conversation, assistant)

      public_message = conversation.reload.messages.outgoing.where(private: false).last
      expect(public_message.content).to eq('Да, отправляю документ.')
      expect(public_message.attachments.size).to eq(1)
      expect(public_message.attachments.first.file.filename.to_s).to eq('macro.pdf')
    end

    it 'does not auto-attach a listed document when document delivery was not requested' do
      conversation.messages.incoming.last.update!(content: 'что внутри документа?')
      document = create_sendable_document(name: 'КП MACRO', filename: 'macro.pdf')

      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'В документе описано коммерческое предложение.',
          'captain_trace' => list_documents_trace(document)
        }
      )

      described_class.perform_now(conversation, assistant)

      public_message = conversation.reload.messages.outgoing.where(private: false).last
      expect(public_message.content).to eq('В документе описано коммерческое предложение.')
      expect(public_message.attachments).to be_empty
    end

    it 'does not auto-attach when several sendable documents were listed and the model omitted artifact_ids' do
      conversation.messages.incoming.last.update!(content: 'вышли мне документ')
      first_document = create_sendable_document(name: 'First', filename: 'first.pdf')
      second_document = create_sendable_document(name: 'Second', filename: 'second.pdf')

      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Уточните, какой документ отправить.',
          'captain_trace' => list_documents_trace(first_document, second_document)
        }
      )

      described_class.perform_now(conversation, assistant)

      public_message = conversation.reload.messages.outgoing.where(private: false).last
      expect(public_message.content).to eq('Уточните, какой документ отправить.')
      expect(public_message.attachments).to be_empty
    end

    it 'splits several response attachments into sequential WhatsApp messages' do
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      create(:captain_inbox, captain_assistant: assistant, inbox: whatsapp_inbox)
      whatsapp_conversation = create(:conversation, inbox: whatsapp_inbox, account: account, status: :pending)
      create(:message, conversation: whatsapp_conversation, content: 'вышли файлы', message_type: :incoming)
      whatsapp_conversation.update!(status: :pending)

      first_document = create_sendable_document(name: 'First', filename: 'first.pdf')
      second_document = create_sendable_document(name: 'Second', filename: 'second.pdf')

      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Отправляю файлы.',
          'artifact_ids' => [document_artifact_payload(first_document), document_artifact_payload(second_document)]
        }
      )

      described_class.perform_now(whatsapp_conversation, assistant)

      public_messages = whatsapp_conversation.reload.messages.outgoing.where(private: false).last(2)
      expect(public_messages.map(&:content)).to eq(['Отправляю файлы.', nil])
      expect(public_messages.map { |message| message.attachments.size }).to eq([1, 1])
      expect(public_messages.map { |message| message.attachments.first.file.filename.to_s }).to eq(%w[first.pdf second.pdf])
    end

    it 'sends the text response without attachment when an artifact id expired' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => 'Here is the apartment photo.',
          'artifact_ids' => ['expired-artifact-id']
        }
      )
      expect(ChatwootExceptionTracker).not_to receive(:new)

      described_class.perform_now(conversation, assistant)

      public_message = conversation.reload.messages.outgoing.where(private: false).last
      expect(public_message.content).to eq('Here is the apartment photo.')
      expect(public_message.attachments).to be_empty
      expect(conversation.status).to eq('pending')
    end

    it 'creates a fallback text response when an artifact-only response cannot be materialized' do
      allow(agent_runner_service).to receive(:generate_response).and_return(
        {
          'response' => '',
          'artifact_ids' => ['expired-artifact-id']
        }
      )
      expect(ChatwootExceptionTracker).not_to receive(:new)

      described_class.perform_now(conversation, assistant)

      public_message = conversation.reload.messages.outgoing.where(private: false).last
      expect(public_message.content).to eq('The requested file is no longer available. Please ask me to fetch it again.')
      expect(public_message.attachments).to be_empty
      expect(conversation.status).to eq('pending')
    end

    it 'builds tool execution trace from runner callbacks' do
      job = described_class.new
      callbacks, tool_trace_steps = job.send(:build_tool_trace_callbacks)

      callbacks[:on_tool_start].call('search_documentation', { query: 'pricing', api_token: 'x' }, nil)
      callbacks[:on_tool_progress].call('search_documentation', { phase: 'searching' }, nil)
      callbacks[:on_tool_complete].call('search_documentation', Captain::ToolResult.success(message: 'Found 2 docs', data: { ids: [1, 2] }), nil)

      response = { 'response' => 'Hey, welcome to Captain V2' }
      job.instance_variable_set(:@response, response)
      job.send(:attach_tool_trace_to_response!, tool_trace_steps)

      expect(response['captain_trace']).to eq(
        Captain::ToolTraceBuilder.payload([
                                            Captain::ToolTraceBuilder.step(
                                              tool_name: 'search_documentation',
                                              event: 'start',
                                              sequence: 1,
                                              input: { query: 'pricing', api_token: 'x' }
                                            ),
                                            Captain::ToolTraceBuilder.step(
                                              tool_name: 'search_documentation',
                                              event: 'progress',
                                              sequence: 2,
                                              output: { phase: 'searching' }
                                            ),
                                            Captain::ToolTraceBuilder.step(
                                              tool_name: 'search_documentation',
                                              event: 'finish',
                                              sequence: 3,
                                              output: { success: true, message: 'Found 2 docs', data: { ids: [1, 2] } }
                                            )
                                          ])
      )
    end

    it 'stores native and structured reasoning separately in captain trace when no tools ran' do
      job = described_class.new
      response = {
        'response' => 'The deal was already up to date.',
        'reasoning' => 'Native model reasoning.',
        'native_reasoning' => { 'text' => 'Native model reasoning.', 'source' => 'openrouter' },
        'structured_reasoning' => 'Checked the current CRM context and no tool call was required.'
      }
      job.instance_variable_set(:@response, response)

      job.send(:attach_tool_trace_to_response!, [])

      expect(response['captain_trace']).to eq(
        'version' => Captain::ToolTraceBuilder::VERSION,
        'native_reasoning' => { 'text' => 'Native model reasoning.', 'source' => 'openrouter' },
        'structured_reasoning' => 'Checked the current CRM context and no tool call was required.'
      )
    end

    it 'creates the configured public handoff message when the V2 handoff tool already opened the conversation' do
      assistant.update!(config: {
                          'handoff_message_enabled' => true,
                          'handoff_message_mode' => 'static',
                          'handoff_message' => 'Connecting you to a human agent.'
                        })
      allow(agent_runner_service).to receive(:generate_response) do
        conversation.bot_handoff!
        { 'response' => '', 'handoff_tool_called' => true }
      end

      described_class.perform_now(conversation, assistant)

      conversation.reload
      expect(conversation.status).to eq('open')
      expect(conversation.messages.outgoing.last.content).to eq('Connecting you to a human agent.')
      expect(conversation.waiting_since).to be_present
    end

    # Regression (PR #13417): wrapping create_handoff_message and bot_handoff! in the
    # same transaction defers the message's after_create_commit until commit, at which
    # point it clears waiting_since (bot_response). The handoff path must stay outside
    # the transaction so the callback fires before bot_handoff! sets waiting_since.
    context 'when handoff is requested' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        allow(agent_runner_service).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })
      end

      it 'restores waiting_since after the handoff message callbacks' do
        conversation.update!(waiting_since: nil)

        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.status).to eq('open')
        expect(conversation.waiting_since).to be_present
      end

      it 'preserves waiting_since so a human reply consumes it for reply_time tracking' do
        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.waiting_since).to be_present

        create(:message, conversation: conversation, message_type: :outgoing,
                         sender: agent, account: account, inbox: inbox)
        expect(conversation.reload.waiting_since).to be_nil
      end

      it 'keeps captain trace on the configured static handoff message' do
        assistant.update!(config: {
                            'handoff_message_enabled' => true,
                            'handoff_message_mode' => 'static',
                            'handoff_message' => 'Connecting you to a human agent.'
                          })
        trace_payload = Captain::ToolTraceBuilder.payload([
                                                            Captain::ToolTraceBuilder.step(
                                                              tool_name: 'search_documentation',
                                                              event: 'start',
                                                              sequence: 1
                                                            )
                                                          ])
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'captain_trace' => trace_payload
          }
        )

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.messages.outgoing.last.additional_attributes['captain_trace']).to eq(trace_payload)
      end

      it 'does not create a public handoff message when handoff message is disabled' do
        assistant.update!(config: {
                            'handoff_message_enabled' => false,
                            'handoff_message_mode' => 'static',
                            'handoff_message' => ''
                          })

        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })

        expect(conversation.reload.status).to eq('open')
      end

      it 'does not fall back to default public text when static handoff message is blank' do
        assistant.update!(config: {
                            'handoff_message_enabled' => true,
                            'handoff_message_mode' => 'static',
                            'handoff_message' => ''
                          })

        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })

        expect(conversation.reload.status).to eq('open')
      end

      it 'uses generated handoff text when AI handoff message mode is enabled' do
        assistant.update!(config: {
                            'handoff_message_enabled' => true,
                            'handoff_message_mode' => 'ai',
                            'handoff_message' => ''
                          })
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_message' => 'I’ll connect you with a specialist who can continue from here.'
          }
        )

        described_class.perform_now(conversation, assistant)

        public_message = conversation.reload.messages.outgoing.where(private: false).last
        expect(public_message.content).to eq('I’ll connect you with a specialist who can continue from here.')
      end

      it 'creates a private note with the handoff reason when provided by the runtime' do
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_reason' => 'Customer requested billing specialist'
          }
        )

        described_class.perform_now(conversation, assistant)

        private_note = conversation.reload.messages.where(private: true).last
        expect(private_note.content).to eq('Customer requested billing specialist')
        expect(private_note.sender).to eq(assistant)
      end

      it 'records the AI open activity with the handoff reason' do
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => 'conversation_handoff',
            'handoff_reason' => 'Customer requested billing specialist'
          }
        )

        expected_content = I18n.t(
          'conversations.activity.captain.open_with_reason',
          locale: account.locale,
          user_name: assistant.name,
          reason: 'Customer requested billing specialist'
        )

        expect { described_class.perform_now(conversation, assistant) }
          .to have_enqueued_job(Conversations::ActivityMessageJob)
          .with(conversation, { account_id: conversation.account_id, inbox_id: conversation.inbox_id, message_type: :activity,
                                content: expected_content })
      end
    end

    context 'when provider error handoff is requested' do
      before do
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE,
            'reasoning' => 'Provider error occurred: Quota exceeded',
            'error_class' => 'RubyLLM::RateLimitError',
            'error_message' => 'Quota exceeded'
          }
        )
      end

      it 'opens the conversation without sending a public handoff message' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })

        expect(conversation.reload.status).to eq('open')
      end

      it 'creates a private note for agents without leaking provider error details' do
        described_class.perform_now(conversation, assistant)

        private_note = conversation.reload.messages.where(private: true).last
        expect(private_note.content).to eq(
          'Automatic reply could not be generated. Handoff to human agent was triggered.'
        )
        expect(private_note.content).not_to include('RubyLLM')
        expect(private_note.content).not_to include('Quota exceeded')
        expect(private_note.sender).to eq(assistant)
      end
    end

    context 'when agent runtime returns a blank public response' do
      before do
        allow(agent_runner_service).to receive(:generate_response).and_return(
          {
            'response' => '',
            'handoff_message' => '',
            'agent_name' => 'booking_scenario'
          }
        )
      end

      it 'opens the conversation with a private fallback note instead of creating a blank public message' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })

        expect(conversation.reload.status).to eq('open')
        private_note = conversation.messages.where(private: true).last
        expect(private_note.content).to eq(
          'Automatic reply could not be generated. Handoff to human agent was triggered.'
        )
        expect(private_note.content).not_to include('BlankResponseError')
      end
    end

    context 'when message contains an image' do
      let!(:message_with_image) do
        create(
          :message,
          conversation: conversation,
          message_type: :incoming,
          content: 'Can you help with this error?'
        )
      end
      let!(:image_attachment) do
        message_with_image.attachments.create!(
          account: account,
          file_type: :image,
          external_url: 'https://example.com/error.jpg'
        )
      end

      before do
        image_attachment
        conversation.messages.where.not(id: message_with_image.id).destroy_all
      end

      it 'includes image URL directly in the message history for vision analysis' do
        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          last_entry = message_history.last
          expect(last_entry[:content]).to be_an(Array)
          expect(last_entry[:content].any? { |part| part[:type] == 'text' && part[:text] == 'Can you help with this error?' }).to be(true)
          expect(last_entry[:content].any? do |part|
            part[:type] == 'image_url' && part[:image_url][:url] == 'https://example.com/error.jpg'
          end).to be(true)

          { 'response' => 'I can see the error in your image. It appears to be a database connection issue.' }
        end

        described_class.perform_now(conversation, assistant)
      end

      it 'marks an image sent after a receipt request as payment proof context' do
        assistant.update!(config: assistant.config.merge('history_message_limit' => 10))
        create(
          :message,
          conversation: conversation,
          account: account,
          inbox: inbox,
          message_type: :outgoing,
          sender: assistant,
          content: 'Пришлите, пожалуйста, фото чека после оплаты.',
          created_at: 2.minutes.ago
        )
        message_with_image.update!(content: nil, created_at: 1.minute.ago)

        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          last_entry = message_history.last
          expect(last_entry[:role]).to eq('user')
          expect(last_entry[:content]).to be_an(Array)
          expect(last_entry[:content].any? do |part|
            part[:type] == 'text' && part[:text].include?('Treat the image as the requested receipt/payment confirmation')
          end).to be(true)
          expect(last_entry[:content].any? do |part|
            part[:type] == 'image_url' && part[:image_url][:url] == 'https://example.com/error.jpg'
          end).to be(true)

          { 'response' => 'Спасибо, чек получил. Подтверждаю бронь.' }
        end

        described_class.perform_now(conversation, assistant)
      end

      it 'marks payment screenshots as receipt context without treating ordinary screenshots as receipts' do
        assistant.update!(config: assistant.config.merge('history_message_limit' => 10))
        create(
          :message,
          conversation: conversation,
          account: account,
          inbox: inbox,
          message_type: :outgoing,
          sender: assistant,
          content: 'Скиньте, пожалуйста, скрин оплаты.',
          created_at: 2.minutes.ago
        )
        message_with_image.update!(content: nil, created_at: 1.minute.ago)

        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          last_entry = message_history.last
          expect(last_entry[:content].any? do |part|
            part[:type] == 'text' && part[:text].include?('Treat the image as the requested receipt/payment confirmation')
          end).to be(true)

          { 'response' => 'Спасибо, оплату вижу.' }
        end

        described_class.perform_now(conversation, assistant)

        conversation.messages.where.not(id: message_with_image.id).destroy_all
        create(
          :message,
          conversation: conversation,
          account: account,
          inbox: inbox,
          message_type: :outgoing,
          sender: assistant,
          content: 'Пришлите, пожалуйста, скрин ошибки.',
          created_at: 2.minutes.ago
        )
        message_with_image.update!(content: nil, created_at: 1.minute.ago)

        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          last_entry = message_history.last
          expect(last_entry[:content].any? do |part|
            part[:type] == 'text' && part[:text].include?('Treat the image as the requested receipt/payment confirmation')
          end).to be(false)

          { 'response' => 'Посмотрел скрин ошибки.' }
        end

        described_class.perform_now(conversation, assistant)
      end
    end

    context 'when message contains an audio attachment' do
      let!(:audio_message) do
        create(
          :message,
          conversation: conversation,
          message_type: :incoming,
          content: nil
        )
      end
      let!(:audio_attachment) do
        audio_message.attachments.create!(
          account: account,
          file_type: :audio,
          meta: {}
        )
      end

      before do
        account.update!(captain_features: { 'audio_transcription' => true })
        audio_attachment
        conversation.messages.where.not(id: audio_message.id).destroy_all
        stub_const('Captain::Conversation::ResponseBuilderJob::AUDIO_TRANSCRIPTION_WAIT_TIMEOUT', 0.05)
        stub_const('Captain::Conversation::ResponseBuilderJob::AUDIO_TRANSCRIPTION_WAIT_INTERVAL', 0.01)
      end

      it 'waits for stored audio transcription before generating a response' do
        allow_any_instance_of(described_class).to receive(:sleep) do |_job, _duration|
          audio_attachment.update!(meta: { 'transcribed_text' => 'Audio transcript text' })
        end

        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          expect(message_history.last[:content]).to eq('Audio transcript text')
          { 'response' => 'I understood the voice message.' }
        end

        described_class.perform_now(conversation, assistant)
      end

      it 'continues without audio text after the transcription wait timeout' do
        expect_any_instance_of(described_class).to receive(:sleep).at_least(:once)
        expect(Messages::AudioTranscriptionService).not_to receive(:new)
        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          expect(message_history.last[:content]).to eq('Message without content')
          { 'response' => 'Please send the details again.' }
        end

        described_class.perform_now(conversation, assistant)
      end

      it 'does not wait or include transcription when captain audio transcription feature is disabled' do
        account.update!(captain_features: { 'audio_transcription' => false })
        audio_attachment.update!(meta: { 'transcribed_text' => 'Hidden transcript' })

        expect_any_instance_of(described_class).not_to receive(:sleep)
        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          expect(message_history.last[:content]).to eq('Message without content')
          { 'response' => 'I need more details.' }
        end

        described_class.perform_now(conversation, assistant)
      end
    end

    context 'when message contains a document attachment' do
      let!(:document_message) do
        create(
          :message,
          conversation: conversation,
          message_type: :incoming,
          content: nil
        )
      end
      let!(:document_attachment) do
        document_message.attachments.create!(
          account: account,
          file_type: :file,
          meta: {},
          file: {
            io: StringIO.new('fake pdf'),
            filename: 'contract.pdf',
            content_type: 'application/pdf'
          }
        )
      end

      before do
        account.enable_features('captain_integration')
        account.update!(captain_runtime: { 'web_document_parse_enabled' => true })
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
        document_attachment
        conversation.messages.where.not(id: document_message.id).destroy_all
        stub_const('Captain::Conversation::ResponseBuilderJob::DOCUMENT_PARSE_WAIT_TIMEOUT', 0.05)
        stub_const('Captain::Conversation::ResponseBuilderJob::DOCUMENT_PARSE_WAIT_INTERVAL', 0.01)
      end

      it 'waits for stored document text before generating a response' do
        allow_any_instance_of(described_class).to receive(:sleep) do |_job, _duration|
          document_attachment.update!(meta: { 'parsed_text' => 'Parsed contract text' })
        end

        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          expect(message_history.last[:content]).to eq("Document attachment: contract.pdf\nParsed contract text")
          { 'response' => 'I read the document.' }
        end

        described_class.perform_now(conversation, assistant)
      end

      it 'continues after the document parsing wait timeout' do
        expect_any_instance_of(described_class).to receive(:sleep).at_least(:once)
        expect(agent_runner_service).to receive(:generate_response) do |message_history:|
          expect(message_history.last[:content]).to eq('User has shared file attachment(s): contract.pdf')
          { 'response' => 'Please confirm the document details.' }
        end

        described_class.perform_now(conversation, assistant)
      end
    end
  end

  describe 'retry mechanisms for image processing' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }
    let(:mock_message_builder) { instance_double(Captain::OpenAiMessageBuilderService) }

    before do
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
      create(:message, conversation: conversation, content: 'Hello with image', message_type: :incoming)
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(agent_runner_service)
      allow(Captain::OpenAiMessageBuilderService).to receive(:new).with(message: anything).and_return(mock_message_builder)
      allow(mock_message_builder).to receive(:generate_content).and_return('Hello with image')
      allow(agent_runner_service).to receive(:generate_response).and_return({ 'response' => 'Test response' })
    end

    context 'when ActiveStorage::FileNotFoundError occurs' do
      it 'handles file errors and triggers handoff' do
        allow(mock_message_builder).to receive(:generate_content)
          .and_raise(ActiveStorage::FileNotFoundError, 'Image file not found')

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end

      it 'succeeds when no error occurs' do
        allow(mock_message_builder).to receive(:generate_content)
          .and_return('Image content processed successfully')

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.outgoing.count).to eq(1)
        expect(conversation.messages.outgoing.last.content).to eq('Test response')
      end
    end

    context 'when Faraday::BadRequestError occurs' do
      it 'handles API errors and triggers handoff' do
        allow(agent_runner_service).to receive(:generate_response)
          .and_raise(Faraday::BadRequestError, 'Bad request to image service')

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end

      it 'succeeds when no error occurs' do
        allow(agent_runner_service).to receive(:generate_response)
          .and_return({ 'response' => 'Response after retry' })

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.outgoing.last.content).to eq('Response after retry')
      end
    end

    context 'when image processing fails permanently' do
      before do
        allow(mock_message_builder).to receive(:generate_content)
          .and_raise(ActiveStorage::FileNotFoundError, 'Image permanently unavailable')
      end

      it 'triggers handoff after max retries' do
        allow(mock_message_builder).to receive(:generate_content)
          .and_raise(StandardError, 'Max retries exceeded')

        expect(ChatwootExceptionTracker).to receive(:new).and_call_original

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end
    end

    context 'when non-retryable error occurs' do
      let(:standard_error) { StandardError.new('Generic error') }

      before do
        allow(agent_runner_service).to receive(:generate_response).and_raise(standard_error)
      end

      it 'handles error and triggers handoff' do
        expect(ChatwootExceptionTracker).to receive(:new)
          .with(standard_error, account: account)
          .and_call_original

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end

      it 'creates a private note instead of a public handoff message' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.where(private: false).count })

        private_note = conversation.reload.messages.where(private: true).last
        expect(private_note.content).to eq(
          'Automatic reply could not be generated. Handoff to human agent was triggered.'
        )
        expect(private_note.content).not_to include('StandardError')
        expect(private_note.content).not_to include('Generic error')
      end

      it 'ensures Current.executed_by is reset' do
        expect(Current).to receive(:executed_by=).with(assistant)
        expect(Current).to receive(:executed_by=).with(nil)

        described_class.perform_now(conversation, assistant)
      end
    end
  end

  describe 'job configuration' do
    it 'has retry_on configuration for retryable errors' do
      expect(described_class).to respond_to(:retry_on)
    end

    it 'defines MAX_MESSAGE_LENGTH constant' do
      expect(described_class::MAX_MESSAGE_LENGTH).to eq(10_000)
    end
  end

  describe 'out of office message after handoff' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }

    before do
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
      create(:message, conversation: conversation, content: 'Hello', message_type: :incoming)
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(agent_runner_service)
    end

    context 'when handoff occurs outside business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed. Please leave your email.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
        allow(agent_runner_service).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })
      end

      it 'sends out of office message after handoff' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.to change { conversation.messages.template.count }.by(1)

        expect(conversation.reload.status).to eq('open')
        ooo_message = conversation.messages.template.last
        expect(ooo_message.content).to eq('We are currently closed. Please leave your email.')
      end
    end

    context 'when handoff occurs within business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          open_all_day: true,
          closed_all_day: false
        )
        allow(agent_runner_service).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })
      end

      it 'does not send out of office message after handoff' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.template.count })

        expect(conversation.reload.status).to eq('open')
      end
    end

    context 'when handoff occurs due to error outside business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
        allow(agent_runner_service).to receive(:generate_response).and_raise(StandardError, 'API error')
      end

      it 'sends out of office message after error-triggered handoff' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.to change { conversation.messages.template.count }.by(1)

        expect(conversation.reload.status).to eq('open')
        ooo_message = conversation.messages.template.last
        expect(ooo_message.content).to eq('We are currently closed.')
      end
    end

    context 'when no out of office message is configured' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: nil
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
        allow(agent_runner_service).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })
      end

      it 'does not send out of office message' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.template.count })
      end
    end
  end
end
