# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Assistant::AgentRunnerService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:scenario) { create(:captain_scenario, assistant: assistant, enabled: true) }
  let(:second_scenario) { create(:captain_scenario, assistant: assistant, enabled: true) }

  let(:mock_runner) { instance_double(Captain::Runtime::AgentRunner) }
  let(:mock_agent) { instance_double(Captain::Runtime::Agent) }
  let(:mock_scenario_agent) { instance_double(Captain::Runtime::Agent) }
  let(:mock_second_scenario_agent) { instance_double(Captain::Runtime::Agent) }
  let(:mock_result) do
    instance_double(
      Captain::Runtime::Result,
      output: { 'response' => 'Test response' },
      context: nil,
      error: nil
    )
  end

  let(:message_history) do
    [
      { role: 'user', content: 'Hello there' },
      { role: 'assistant', content: 'Hi! How can I help you?', agent_name: 'Assistant' },
      { role: 'user', content: 'I need help with my account' }
    ]
  end

  before do
    allow(Llm::Config).to receive(:initialize!)
    allow(Llm::Config).to receive(:api_key).and_call_original
    allow(Llm::Config).to receive(:api_key).with('openai').and_return('openai-key')
    allow(Llm::Config).to receive(:api_key).with('openai', account: account).and_return('openai-key')
    allow(Llm::ApiClient).to receive(:moderate).and_return(instance_double(RubyLLM::Moderation, flagged?: false))
    allow(assistant).to receive(:agent).and_return(mock_agent)
    scenarios_relation = instance_double(Captain::Scenario)
    allow(scenarios_relation).to receive(:enabled).and_return([scenario])
    allow(assistant).to receive(:scenarios).and_return(scenarios_relation)
    allow(scenario).to receive(:agent).and_return(mock_scenario_agent)
    allow(Captain::Runtime::Runner).to receive(:with_agents).and_return(mock_runner)
    allow(mock_runner).to receive(:run).and_return(mock_result)
    Captain::Runtime::CallbackManager::EVENT_TYPES.each do |event_type|
      allow(mock_runner).to receive(:"on_#{event_type}").and_return(mock_runner)
    end
    allow(mock_agent).to receive(:register_handoffs)
    allow(mock_scenario_agent).to receive(:register_handoffs)
  end

  describe '#initialize' do
    it 'sets instance variables correctly' do
      service = described_class.new(assistant: assistant, conversation: conversation)

      expect(service.instance_variable_get(:@assistant)).to eq(assistant)
      expect(service.instance_variable_get(:@conversation)).to eq(conversation)
      expect(service.instance_variable_get(:@callbacks)).to eq({})
    end

    it 'accepts callbacks parameter' do
      callbacks = { on_agent_thinking: proc { |x| x } }
      service = described_class.new(assistant: assistant, callbacks: callbacks)

      expect(service.instance_variable_get(:@callbacks)).to eq(callbacks)
    end
  end

  describe '#generate_response' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'initializes RubyLLM configuration before running the agent' do
      expect(Llm::Config).to receive(:initialize!)

      service.generate_response(message_history: message_history)
    end

    it 'builds agents and wires them together' do
      expect(assistant).to receive(:agent).and_return(mock_agent)
      scenarios_relation = instance_double(Captain::Scenario)
      allow(scenarios_relation).to receive(:enabled).and_return([scenario])
      expect(assistant).to receive(:scenarios).and_return(scenarios_relation)
      expect(scenario).to receive(:agent).and_return(mock_scenario_agent)
      expect(mock_agent).to receive(:register_handoffs).with(mock_scenario_agent)
      expect(mock_scenario_agent).to receive(:register_handoffs).with(mock_agent)

      service.generate_response(message_history: message_history)
    end

    it 'wires sibling scenarios for direct handoff' do
      scenarios_relation = instance_double(Captain::Scenario)
      allow(scenarios_relation).to receive(:enabled).and_return([scenario, second_scenario])
      allow(assistant).to receive(:scenarios).and_return(scenarios_relation)
      allow(scenario).to receive(:agent).and_return(mock_scenario_agent)
      allow(second_scenario).to receive(:agent).and_return(mock_second_scenario_agent)

      expect(mock_agent).to receive(:register_handoffs).with(mock_scenario_agent, mock_second_scenario_agent)
      expect(mock_scenario_agent).to receive(:register_handoffs).with(mock_agent, mock_second_scenario_agent)
      expect(mock_second_scenario_agent).to receive(:register_handoffs).with(mock_agent, mock_scenario_agent)
      expect(Captain::Runtime::Runner).to receive(:with_agents).with(
        mock_agent,
        mock_scenario_agent,
        mock_second_scenario_agent
      ).and_return(mock_runner)

      service.generate_response(message_history: message_history)
    end

    it 'creates runner with agents' do
      expect(Captain::Runtime::Runner).to receive(:with_agents).with(mock_agent, mock_scenario_agent)

      service.generate_response(message_history: message_history)
    end

    it 'runs agent with extracted user message and context' do
      communication_thread = conversation.reload.communication_thread

      expect(mock_runner).to receive(:run) do |input, context:, max_turns:, runtime_options:|
        expect(input).to eq('I need help with my account')
        expect(context).to include(
          session_id: "#{account.id}_#{conversation.display_id}",
          conversation_history: [
            { role: :user, content: 'Hello there' },
            { role: :assistant, content: 'Hi! How can I help you?', agent_name: 'Assistant' }
          ],
          state: hash_including(
            account_id: account.id,
            assistant_id: assistant.id,
            captain_runtime: hash_including(
              'assistant_thinking_effort' => 'none',
              'assistant_moderation' => false
            ),
            conversation: hash_including(id: conversation.id),
            contact: hash_including(id: contact.id),
            communication_thread: hash_including(
              display_id: communication_thread.display_id,
              current_conversation_id: conversation.display_id,
              current_channel_key: "conversation:#{conversation.display_id}",
              channels: include(hash_including(channel_key: "conversation:#{conversation.display_id}"))
            )
          )
        )
        expect(context[:captain_v2_trace_input]).to include('I need help with my account')
        expect(max_turns).to eq(described_class::MAX_RUNTIME_TURNS)
        expect(runtime_options[:llm_context]).to be_a(RubyLLM::Context)
        mock_result
      end

      service.generate_response(message_history: message_history)
    end

    context 'when the latest user message is multimodal' do
      let(:multimodal_message_history) do
        [
          { role: 'assistant', content: 'Please share a screenshot' },
          {
            role: 'user',
            content: [
              { type: 'text', text: 'What does this error mean?' },
              { type: 'image_url', image_url: { url: 'https://example.com/error.png' } }
            ]
          }
        ]
      end

      it 'passes image attachments to the runner input' do
        expect(mock_runner).to receive(:run) do |input, context:, max_turns:, runtime_options:|
          expect(input).to be_a(RubyLLM::Content)
          expect(input.text).to eq('What does this error mean?')
          expect(input.attachments.first.source.to_s).to eq('https://example.com/error.png')
          expect(context[:conversation_history]).to eq([{ role: :assistant, content: 'Please share a screenshot' }])
          expect(max_turns).to eq(described_class::MAX_RUNTIME_TURNS)
          expect(runtime_options[:llm_context]).to be_a(RubyLLM::Context)
          mock_result
        end

        service.generate_response(message_history: multimodal_message_history)
      end

      it 'preserves multimodal content in earlier history messages' do
        history_with_prior_image = [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'Here is my error screenshot' },
              { type: 'image_url', image_url: { url: 'https://example.com/error.png' } }
            ]
          },
          { role: 'assistant', content: 'I see the error. Try restarting.' },
          { role: 'user', content: 'It still does not work' }
        ]

        expect(mock_runner).to receive(:run) do |input, context:, max_turns:, runtime_options:|
          expect(input).to eq('It still does not work')
          # The earlier user message with the image should preserve the multimodal array
          first_history_msg = context[:conversation_history].first
          expect(first_history_msg[:content]).to be_a(Array)
          expect(first_history_msg[:content]).to include(
            { type: 'text', text: 'Here is my error screenshot' },
            { type: 'image_url', image_url: { url: 'https://example.com/error.png' } }
          )
          expect(max_turns).to eq(described_class::MAX_RUNTIME_TURNS)
          expect(runtime_options[:llm_context]).to be_a(RubyLLM::Context)
          mock_result
        end

        service.generate_response(message_history: history_with_prior_image)
      end

      it 'stores multimodal trace payloads in runner context' do
        expect(mock_runner).to receive(:run) do |_input, context:, max_turns:, runtime_options:|
          expect(context[:captain_v2_trace_input]).to include('image_url')
          expect(context[:captain_v2_trace_current_input]).to include('image_url')
          expect(max_turns).to eq(described_class::MAX_RUNTIME_TURNS)
          expect(runtime_options[:llm_context]).to be_a(RubyLLM::Context)
          mock_result
        end

        service.generate_response(message_history: multimodal_message_history)
      end
    end

    it 'passes the current runtime clock to the agent context' do
      inbox.update!(timezone: 'Asia/Almaty')

      travel_to Time.zone.parse('2026-05-03 14:00:00 UTC') do
        expect(mock_runner).to receive(:run) do |_input, context:, **_kwargs|
          expect(context[:state]).to include(
            runtime_clock: hash_including(
              now_utc: '2026-05-03T14:00:00Z',
              timezone: 'Asia/Almaty',
              now_local: '2026-05-03T19:00:00+05:00',
              date_local: '2026-05-03',
              time_local: '19:00:00'
            )
          )
          mock_result
        end

        service.generate_response(message_history: message_history)
      end
    end

    it 'processes and formats agent result' do
      result = service.generate_response(message_history: message_history)

      expect(result).to eq({ 'response' => 'Test response', 'agent_name' => nil, 'handoff_tool_called' => false })
    end

    it 'surfaces native OpenRouter reasoning from runtime history' do
      result = instance_double(
        Captain::Runtime::Result,
        output: { 'response' => 'Done', 'reasoning' => 'Structured summary' },
        context: {
          current_agent: 'assistant_agent',
          conversation_history: [
            { role: :user, content: 'Update the deal' },
            {
              role: :assistant,
              content: 'Done',
              thinking: 'Native OpenRouter reasoning',
              thinking_signature: 'sig_123',
              reasoning_details: [{ 'type' => 'reasoning.text', 'text' => 'detail' }]
            }
          ]
        },
        error: nil
      )
      allow(mock_runner).to receive(:run).and_return(result)

      response = service.generate_response(message_history: message_history)

      expect(response).to include(
        'response' => 'Done',
        'reasoning' => 'Native OpenRouter reasoning',
        'native_reasoning' => {
          'text' => 'Native OpenRouter reasoning',
          'signature' => 'sig_123',
          'details' => [{ 'type' => 'reasoning.text', 'text' => 'detail' }],
          'source' => 'openrouter'
        },
        'structured_reasoning' => 'Structured summary',
        'agent_name' => 'assistant_agent',
        'handoff_tool_called' => false
      )
    end

    it 'surfaces the V2 handoff tool flag from the runner context' do
      result_context = { captain_v2_handoff_tool_called: true }
      result = instance_double(Captain::Runtime::Result, output: { 'response' => '' }, context: result_context, error: nil)
      allow(mock_runner).to receive(:run).and_return(result)

      response = service.generate_response(message_history: message_history)

      expect(response['handoff_tool_called']).to be true
    end

    it 'retries blank structured output without tools using the original run context' do
      blank_result = instance_double(
        Captain::Runtime::Result,
        output: { 'response' => '' },
        context: nil,
        error: nil
      )
      recovered_result = instance_double(
        Captain::Runtime::Result,
        output: { 'response' => 'Recovered answer' },
        context: { current_agent: 'assistant_agent' },
        error: nil
      )
      run_contexts = []
      retry_events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.run.retry') do |*args|
        retry_events << ActiveSupport::Notifications::Event.new(*args)
      end

      allow(mock_runner).to receive(:run) do |_input, context:, **_kwargs|
        run_contexts << context
        run_contexts.one? ? blank_result : recovered_result
      end

      result = service.generate_response(message_history: message_history)

      expect(mock_runner).to have_received(:run).twice
      expect(run_contexts.second).to include(
        session_id: "#{account.id}_#{conversation.display_id}",
        conversation_history: [
          { role: :user, content: 'Hello there' },
          { role: :assistant, content: 'Hi! How can I help you?', agent_name: 'Assistant' }
        ],
        state: hash_including(account_id: account.id, assistant_id: assistant.id)
      )
      expect(result).to include('response' => 'Recovered answer', 'blank_response_retry' => true)
      expect(result).to include(
        'zero_completion_recovered' => true,
        'zero_completion_recovery_kind' => described_class::ZERO_COMPLETION_BLANK_RETRY
      )
      expect(retry_events.map(&:payload)).to contain_exactly(
        hash_including('reason' => 'blank_response', 'attempt' => 1, 'max_attempts' => 1)
      )
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'retries once from the post-handoff context when structured agent output is blank' do
      retry_history = [
        { role: :user, content: 'I need help with my account' },
        { role: :assistant, content: '', agent_name: 'assistant_agent', tool_calls: [{ name: 'handoff_to_scenario_agent' }] },
        { role: :tool, content: 'Transferred to scenario', tool_call_id: 'call_1' }
      ]
      blank_context = {
        current_agent: 'scenario_agent',
        conversation_history: retry_history,
        captain_v2_handoff_tool_called: true,
        captain_v2_completed_tool_names: ['handoff_to_scenario_agent']
      }
      blank_result = instance_double(
        Captain::Runtime::Result,
        output: { 'response' => '', 'handoff_message' => '' },
        context: blank_context,
        error: nil
      )
      recovered_result = instance_double(
        Captain::Runtime::Result,
        output: { 'response' => 'Recovered answer' },
        context: { current_agent: 'scenario_agent' },
        error: nil
      )
      run_contexts = []
      allow(mock_runner).to receive(:run) do |_input, context:, **_kwargs|
        run_contexts << context
        run_contexts.one? ? blank_result : recovered_result
      end

      result = service.generate_response(message_history: message_history)

      expect(mock_runner).to have_received(:run).twice
      expect(run_contexts.second).to include(
        current_agent: 'scenario_agent',
        conversation_history: retry_history
      )
      expect(run_contexts.second).not_to have_key(:captain_v2_handoff_tool_called)
      expect(run_contexts.second).not_to have_key(:captain_v2_completed_tool_names)
      expect(result).to eq(
        {
          'response' => 'Recovered answer',
          'agent_name' => 'scenario_agent',
          'handoff_tool_called' => false,
          'blank_response_retry' => true,
          'zero_completion_recovered' => true,
          'zero_completion_recovery_kind' => described_class::ZERO_COMPLETION_BLANK_RETRY
        }
      )
    end

    it 'uses a deterministic public fallback for blank structured output after non-handoff tools completed' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => '', 'handoff_message' => '' },
          context: { current_agent: 'scenario_agent', captain_v2_completed_tool_names: ['create_deal'] },
          error: nil
        )
      )

      result = service.generate_response(message_history: message_history)

      expect(mock_runner).to have_received(:run).once
      expect(result).to include(
        'response' => 'Request processed. Completed actions: Create Deal ×1.',
        'reasoning' => 'Final assistant response failed after completed tool actions; a deterministic tool-result fallback was used.',
        'agent_name' => 'scenario_agent',
        'handoff_tool_called' => false,
        'schema_fallback' => true,
        'zero_completion_recovered' => true,
        'zero_completion_recovery_kind' => described_class::ZERO_COMPLETION_TOOL_RESULT_FALLBACK,
        'error_class' => 'Captain::Assistant::AgentRunnerService::BlankResponseError',
        'error_message' => 'Assistant runtime returned a blank response'
      )
    end

    it 'retries final response generation without tools after successful tool results before deterministic fallback', :aggregate_failures do
      tool_history = finalization_tool_history
      failed_context = finalization_failed_context(tool_history)
      run_calls = []
      retry_events = []
      zero_completion_events = []
      subscriber = subscribe_to_finalization_retry_events(retry_events)
      zero_completion_subscriber = subscribe_to_zero_completion_events(zero_completion_events)
      allow_finalization_retry_runner(failed_context, run_calls)

      result = service.generate_response(message_history: message_history)

      expect_finalization_retry_call(run_calls, failed_context, tool_history)
      expect_finalization_retry_result(result)
      expect_finalization_retry_event(retry_events)
      expect_zero_completion_finalization_events(zero_completion_events)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      ActiveSupport::Notifications.unsubscribe(zero_completion_subscriber) if zero_completion_subscriber
    end

    it 'does not expose unknown raw tool identifiers in deterministic public fallback text' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => '', 'handoff_message' => '' },
          context: {
            current_agent: 'scenario_agent',
            captain_v2_completed_tool_results: [{ tool_name: 'mcp__internal_server__mutate_secret_thing', success: true }]
          },
          error: nil
        )
      )

      result = service.generate_response(message_history: message_history)

      expect(result['response']).to eq('Request processed. Completed actions: tool action ×1.')
    end

    it 'blocks model-invented response cancellation instead of silently suppressing the reply' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => 'response_cancelled', 'response_cancelled' => true },
          context: { current_agent: 'assistant_agent' },
          error: nil
        )
      )
      invalid_events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.schema.invalid') do |*args|
        invalid_events << ActiveSupport::Notifications::Event.new(*args)
      end

      result = service.generate_response(message_history: message_history)

      expect(mock_runner).to have_received(:run).once
      expect(result).to include(
        'response' => described_class::PROVIDER_ERROR_RESPONSE,
        'error_class' => 'Captain::Assistant::AgentRunnerService::SemanticOutputError',
        'error_message' => 'Model output attempted reserved runtime action response_cancelled'
      )
      expect(invalid_events.map(&:payload)).to contain_exactly(
        hash_including(
          'schema_name' => 'Captain::ResponseSchema',
          'semantic_error_code' => 'reserved_runtime_action',
          'reason' => 'Model output attempted reserved runtime action response_cancelled'
        )
      )
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'blocks non-text public responses instead of sending schema artifacts to the customer' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => true, 'reasoning' => 'Checked the request.' },
          context: { current_agent: 'assistant_agent' },
          error: nil
        )
      )

      result = service.generate_response(message_history: message_history)

      expect(mock_runner).to have_received(:run).once
      expect(result).to include(
        'response' => described_class::PROVIDER_ERROR_RESPONSE,
        'error_class' => 'Captain::Assistant::AgentRunnerService::SemanticOutputError',
        'error_message' => 'Model output returned invalid public response true'
      )
    end

    it 'blocks schema placeholder public responses' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => 'response', 'reasoning' => 'Need to search CRM deals.' },
          context: { current_agent: 'scenario_111_crm_agent' },
          error: nil
        )
      )

      result = service.generate_response(message_history: message_history)

      expect(mock_runner).to have_received(:run).once
      expect(result).to include(
        'response' => described_class::PROVIDER_ERROR_RESPONSE,
        'error_class' => 'Captain::Assistant::AgentRunnerService::SemanticOutputError',
        'error_message' => 'Model output returned invalid public response "response"'
      )
    end

    it 'uses deterministic public fallback for semantic output errors after successful tools' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => 'response', 'reasoning' => 'Need to search CRM deals.' },
          context: {
            current_agent: 'scenario_111_crm_agent',
            captain_v2_completed_tool_results: [{ tool_name: 'search_deals', success: true }]
          },
          error: nil
        )
      )

      result = service.generate_response(message_history: message_history)

      expect(mock_runner).to have_received(:run).once
      expect(result).to include(
        'response' => 'Request processed. Completed actions: Search Deals ×1.',
        'error_class' => 'Captain::Assistant::AgentRunnerService::SemanticOutputError',
        'schema_fallback' => true,
        'tool_result_fallback' => true
      )
    end

    it 'drops hallucinated artifact ids when no tool completed' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => 'Here is the file.', 'artifact_ids' => ['hallucinated-artifact-id'] },
          context: { current_agent: 'assistant_agent' },
          error: nil
        )
      )
      invalid_events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.schema.invalid') do |*args|
        invalid_events << ActiveSupport::Notifications::Event.new(*args)
      end

      result = service.generate_response(message_history: message_history)

      expect(mock_runner).to have_received(:run).once
      expect(result).to include(
        'response' => 'Here is the file.',
        'artifact_ids' => []
      )
      expect(invalid_events).to be_empty
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'blocks model-invented human handoff instead of treating it as a runtime handoff' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => 'conversation_handoff', 'handoff_message' => 'I will transfer you.' },
          context: { current_agent: 'assistant_agent' },
          error: nil
        )
      )
      invalid_events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.schema.invalid') do |*args|
        invalid_events << ActiveSupport::Notifications::Event.new(*args)
      end

      result = service.generate_response(message_history: message_history)

      expect(mock_runner).to have_received(:run).once
      expect(result).to include(
        'response' => described_class::PROVIDER_ERROR_RESPONSE,
        'error_class' => 'Captain::Assistant::AgentRunnerService::SemanticOutputError',
        'error_message' => 'Model output attempted human handoff without runtime handoff state'
      )
      expect(invalid_events.map(&:payload)).to contain_exactly(
        hash_including(
          'semantic_error_code' => 'invalid_handoff_output',
          'artifact_ids_count' => 0,
          'completed_tools_count' => 0
        )
      )
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'drops artifact ids that were not exposed by completed tool results' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => 'Here is the file.', 'artifact_ids' => ['hallucinated-artifact-id'] },
          context: {
            current_agent: 'assistant_agent',
            captain_v2_completed_tool_names: ['list_captain_documents'],
            captain_v2_artifact_ids: ['real-tool-artifact-id']
          },
          error: nil
        )
      )
      invalid_events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.schema.invalid') do |*args|
        invalid_events << ActiveSupport::Notifications::Event.new(*args)
      end

      result = service.generate_response(message_history: message_history)

      expect(result).to include(
        'response' => 'Here is the file.',
        'artifact_ids' => []
      )
      expect(invalid_events).to be_empty
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'drops artifact ids when completed tools exposed no artifact ids' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => 'Here is the file.', 'artifact_ids' => ['hallucinated-artifact-id'] },
          context: {
            current_agent: 'assistant_agent',
            captain_v2_completed_tool_names: ['search_deals']
          },
          error: nil
        )
      )

      result = service.generate_response(message_history: message_history)

      expect(result).to include(
        'response' => 'Here is the file.',
        'artifact_ids' => []
      )
    end

    it 'keeps exposed artifact ids and drops model-invented artifact ids' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: {
            'response' => 'Here is the file.',
            'artifact_ids' => %w[opaque-tool-artifact-id hallucinated-artifact-id]
          },
          context: {
            current_agent: 'assistant_agent',
            captain_v2_completed_tool_names: ['list_captain_documents'],
            captain_v2_artifact_ids: ['opaque-tool-artifact-id']
          },
          error: nil
        )
      )

      result = service.generate_response(message_history: message_history)

      expect(result).to include(
        'response' => 'Here is the file.',
        'artifact_ids' => ['opaque-tool-artifact-id']
      )
    end

    it 'allows artifact ids after a completed tool result exposed the same ids' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: { 'response' => 'Here is the file.', 'artifact_ids' => ['opaque-tool-artifact-id'] },
          context: {
            current_agent: 'assistant_agent',
            captain_v2_completed_tool_names: ['list_captain_documents'],
            captain_v2_artifact_ids: ['opaque-tool-artifact-id']
          },
          error: nil
        )
      )

      result = service.generate_response(message_history: message_history)

      expect(result).to include(
        'response' => 'Here is the file.',
        'artifact_ids' => ['opaque-tool-artifact-id']
      )
    end

    it 'returns a standardized handoff payload when the runtime requests a human handoff' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: 'conversation_handoff',
          context: {
            current_agent: 'assistant_agent',
            captain_v2_handoff_tool_called: true,
            pending_human_handoff: {
              reason: 'Needs manual review',
              message: 'I’m connecting you with a human support specialist.'
            }
          },
          error: nil
        )
      )

      result = service.generate_response(message_history: message_history)

      expect(result).to eq(
        {
          'response' => 'conversation_handoff',
          'reasoning' => 'Human handoff requested: Needs manual review',
          'handoff_reason' => 'Needs manual review',
          'handoff_message' => 'I’m connecting you with a human support specialist.',
          'agent_name' => 'assistant_agent',
          'handoff_tool_called' => true
        }
      )
    end

    it 'returns a silent cancellation payload when the runtime cancels the response' do
      allow(mock_runner).to receive(:run).and_return(
        instance_double(
          Captain::Runtime::Result,
          output: 'response_cancelled',
          context: {
            current_agent: 'assistant_agent',
            pending_response_cancellation: {
              reason: 'Acknowledgement does not need a reply'
            }
          },
          error: nil
        )
      )

      result = service.generate_response(message_history: message_history)

      expect(result).to eq(
        {
          'response' => 'response_cancelled',
          'response_cancelled' => true,
          'cancel_reason' => 'Acknowledgement does not need a reply',
          'agent_name' => 'assistant_agent'
        }
      )
    end

    context 'when no scenarios are enabled' do
      before do
        scenarios_relation = instance_double(Captain::Scenario)
        allow(scenarios_relation).to receive(:enabled).and_return([])
        allow(assistant).to receive(:scenarios).and_return(scenarios_relation)
      end

      it 'only uses assistant agent' do
        expect(Captain::Runtime::Runner).to receive(:with_agents).with(mock_agent)
        expect(mock_agent).not_to receive(:register_handoffs)

        service.generate_response(message_history: message_history)
      end
    end

    it 'returns a handoff response when moderation blocks the input' do
      allow(Llm::SafetyPolicy).to receive(:check!).and_raise(
        Llm::SafetyPolicy::UnsafeContentError.new(feature: :assistant, stage: :input, reason: :moderation_flagged)
      )

      result = service.generate_response(message_history: message_history)

      expect(result).to eq(
        {
          'response' => 'conversation_handoff',
          'reasoning' => 'Agent input blocked by moderation policy'
        }
      )
    end

    it 'returns a handoff response when fail-closed moderation is unavailable' do
      allow(Llm::SafetyPolicy).to receive(:check!).and_raise(
        Llm::SafetyPolicy::UnavailableError.new(feature: :assistant, stage: :input, reason: :provider_not_configured)
      )

      result = service.generate_response(message_history: message_history)

      expect(result).to eq(
        {
          'response' => 'conversation_handoff',
          'reasoning' => 'Agent input blocked because moderation policy is unavailable'
        }
      )
    end

    it 'builds a scoped RubyLLM context for the runner when an account OpenAI hook is configured' do
      hook = create(:integrations_hook, account: account, app_id: 'openai', status: 'enabled', settings: { api_key: 'account-key' })
      allow(account.hooks).to receive(:find_by).and_call_original
      allow(account.hooks).to receive(:find_by).with(app_id: 'openai', status: 'enabled').and_return(hook)

      expect(mock_runner).to receive(:run).with(
        anything,
        context: anything,
        max_turns: described_class::MAX_RUNTIME_TURNS,
        runtime_options: hash_including(
          llm_context: an_instance_of(RubyLLM::Context),
          account: account
        )
      )

      service.generate_response(message_history: message_history)
    end

    context 'when agent result is a string' do
      let(:mock_result) do
        instance_double(
          Captain::Runtime::Result,
          output: 'Simple string response',
          context: nil,
          error: nil
        )
      end

      it 'formats string response correctly' do
        result = service.generate_response(message_history: message_history)

        expect(result).to eq({
                               'response' => 'Simple string response',
                               'reasoning' => '',
                               'agent_name' => nil,
                               'handoff_tool_called' => false
                             })
      end
    end

    context 'when an error occurs' do
      let(:error) { StandardError.new('Test error') }

      before do
        allow(mock_runner).to receive(:run).and_raise(error)
        allow(ChatwootExceptionTracker).to receive(:new).and_return(
          instance_double(ChatwootExceptionTracker, capture_exception: true)
        )
      end

      it 'captures exception and returns error response' do
        expect(ChatwootExceptionTracker).to receive(:new).with(error, account: conversation.account)

        result = service.generate_response(message_history: message_history)

        expect(result).to eq({
                               'response' => described_class::PROVIDER_ERROR_RESPONSE,
                               'reasoning' => 'Error occurred: Test error',
                               'error_class' => 'StandardError',
                               'error_message' => 'Test error'
                             })
      end

      it 'uses deterministic public fallback when the runner raises after a successful tool callback' do
        tool_complete_callbacks = []
        context_wrapper = Struct.new(:context).new({ current_agent: 'crm_agent' })
        allow(mock_runner).to receive(:on_tool_complete) do |&block|
          tool_complete_callbacks << block
          mock_runner
        end
        allow(mock_runner).to receive(:run) do
          tool_complete_callbacks.each do |callback|
            callback.call('update_deal', Captain::ToolResult.success(message: 'ok'), context_wrapper)
          end
          raise error
        end

        result = service.generate_response(message_history: message_history)

        expect(result).to include(
          'response' => 'Request processed. Completed actions: Update Deal ×1.',
          'error_class' => 'StandardError',
          'error_message' => 'Test error',
          'tool_result_fallback' => true
        )
      end

      it 'logs error details' do
        expect(Rails.logger).to receive(:error).with('[Captain V2] AgentRunnerService error: Test error')
        expect(Rails.logger).to receive(:error).with(kind_of(String))

        service.generate_response(message_history: message_history)
      end

      context 'when conversation is nil' do
        subject(:service) { described_class.new(assistant: assistant, conversation: nil) }

        it 'handles missing conversation gracefully' do
          expect(ChatwootExceptionTracker).to receive(:new).with(error, account: nil)

          result = service.generate_response(message_history: message_history)

          expect(result).to eq({
                                 'response' => described_class::PROVIDER_ERROR_RESPONSE,
                                 'reasoning' => 'Error occurred: Test error',
                                 'error_class' => 'StandardError',
                                 'error_message' => 'Test error'
                               })
        end
      end
    end

    context 'when the runner result contains a provider error' do
      let(:provider_error) { RubyLLM::RateLimitError.new('Quota exceeded') }
      let(:mock_result) do
        instance_double(
          Captain::Runtime::Result,
          output: nil,
          context: nil,
          error: provider_error
        )
      end

      it 'returns a provider error handoff response instead of a blank message' do
        result = service.generate_response(message_history: message_history)

        expect(result).to eq(
          {
            'response' => described_class::PROVIDER_ERROR_RESPONSE,
            'reasoning' => 'Provider error occurred: Quota exceeded',
            'error_class' => 'RubyLLM::RateLimitError',
            'error_message' => 'Quota exceeded'
          }
        )
      end

      it 'uses a deterministic public fallback when final response generation fails after successful tools' do
        schema_error = Llm::StructuredOutputPolicy::InvalidStructuredOutputError.new(
          'Captain response reasoning must be present for schema Captain::ResponseSchema'
        )
        allow(mock_runner).to receive(:run).and_return(
          instance_double(
            Captain::Runtime::Result,
            output: nil,
            context: {
              current_agent: 'crm_agent',
              captain_v2_completed_tool_names: %w[search_deals update_deal update_deal],
              captain_v2_completed_tool_results: [
                { tool_name: 'search_deals', success: true },
                { tool_name: 'update_deal', success: true },
                { tool_name: 'update_deal', success: true }
              ]
            },
            error: schema_error
          )
        )

        result = service.generate_response(message_history: message_history)

        expect(result).to include(
          'response' => 'Request processed. Completed actions: Search Deals ×1, Update Deal ×2.',
          'reasoning' => 'Final assistant response failed after completed tool actions; a deterministic tool-result fallback was used.',
          'agent_name' => 'crm_agent',
          'handoff_tool_called' => false,
          'schema_fallback' => true,
          'error_class' => 'Llm::StructuredOutputPolicy::InvalidStructuredOutputError',
          'error_message' => 'Captain response reasoning must be present for schema Captain::ResponseSchema'
        )
      end
    end
  end

  describe '#build_context' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'builds context with conversation history and state' do
      context = service.send(:build_context, message_history)

      expect(context).to include(
        conversation_history: [
          { role: :user, content: 'Hello there' },
          { role: :assistant, content: 'Hi! How can I help you?', agent_name: 'Assistant' },
          { role: :user, content: 'I need help with my account' }
        ],
        state: hash_including(
          account_id: account.id,
          assistant_id: assistant.id
        ),
        session_id: "#{account.id}_#{conversation.display_id}"
      )
    end

    context 'with multimodal content' do
      let(:multimodal_content) do
        [
          { type: 'text', text: 'Can you help with this image?' },
          { type: 'image_url', image_url: { url: 'https://example.com/image.jpg' } }
        ]
      end

      let(:multimodal_message_history) do
        [{ role: 'user', content: multimodal_content }]
      end

      it 'preserves multimodal arrays in conversation history for image context retention' do
        context = service.send(:build_context, multimodal_message_history)

        expect(context[:conversation_history].first[:content]).to eq(multimodal_content)
      end
    end

    it 'preserves assistant tool calls and tool result metadata from prior history' do
      context = service.send(
        :build_context,
        [
          {
            'role' => 'assistant',
            'content' => '',
            'agent_name' => 'faq_agent',
            'tool_calls' => [
              { 'id' => 'call_1', 'name' => 'faq_lookup', 'arguments' => { 'query' => 'refund' } }
            ]
          },
          {
            'role' => 'tool',
            'content' => 'Refund policy found',
            'tool_call_id' => 'call_1'
          }
        ]
      )

      expect(context[:conversation_history]).to eq(
        [
          {
            role: :assistant,
            content: '',
            agent_name: 'faq_agent',
            tool_calls: [
              { 'id' => 'call_1', 'name' => 'faq_lookup', 'arguments' => { 'query' => 'refund' } }
            ]
          },
          {
            role: :tool,
            content: 'Refund policy found',
            tool_call_id: 'call_1'
          }
        ]
      )
    end
  end

  describe '#extract_last_user_message' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'extracts the last user message' do
      result = service.send(:extract_last_user_message, message_history)

      expect(result).to eq('I need help with my account')
    end

    it 'returns multimodal content with image attachments for the runner input' do
      multimodal_message_history = [
        {
          role: 'user',
          content: [
            { type: 'text', text: 'Can you check this screenshot?' },
            { type: 'image_url', image_url: { url: 'https://example.com/image.jpg' } }
          ]
        }
      ]

      result = service.send(:extract_last_user_message, multimodal_message_history)

      expect(result).to be_a(RubyLLM::Content)
      expect(result.text).to eq('Can you check this screenshot?')
      expect(result.attachments.first.source.to_s).to eq('https://example.com/image.jpg')
    end
  end

  describe '#extract_text_from_content' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'extracts text from string content' do
      result = service.send(:extract_text_from_content, 'Simple text')

      expect(result).to eq('Simple text')
    end

    it 'extracts response from hash content' do
      content = { 'response' => 'Hash response' }
      result = service.send(:extract_text_from_content, content)

      expect(result).to eq('Hash response')
    end

    it 'extracts text from multimodal array content' do
      content = [
        { type: 'text', text: 'First part' },
        { type: 'image_url', image_url: { url: 'image.jpg' } },
        { type: 'text', text: 'Second part' }
      ]

      result = service.send(:extract_text_from_content, content)

      expect(result).to eq('First part Second part')
    end
  end

  describe '#dynamic_trace_attributes' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'adds serialized trace input attributes when present in context' do
      context = {
        state: {
          account_id: account.id,
          assistant_id: assistant.id,
          conversation: { id: conversation.id, display_id: conversation.display_id }
        },
        captain_v2_trace_input: '[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.com/image.jpg"}}]}]'
      }
      context_wrapper = Struct.new(:context).new(context)

      attributes = service.send(:dynamic_trace_attributes, context_wrapper)

      expect(attributes['langfuse.trace.input']).to include('image_url')
      expect(attributes['langfuse.observation.input']).to include('image_url')
      expect(attributes['langfuse.user.id']).to eq(account.id.to_s)
    end
  end

  describe '#build_state' do
    subject(:service) { described_class.new(assistant: assistant, conversation: conversation) }

    it 'builds state with assistant and account information' do
      state = service.send(:build_state)

      expect(state).to include(
        account_id: account.id,
        assistant_id: assistant.id,
        assistant_config: assistant.config
      )
    end

    it 'uses direct runtime preferences without resolving full model preferences' do
      runtime_preferences = { 'assistant_moderation' => true }.with_indifferent_access

      allow(assistant).to receive(:account).and_return(account)
      allow(account).to receive(:captain_runtime_preferences).and_return(runtime_preferences)
      allow(account).to receive(:captain_preferences).and_raise('full captain preferences should not be resolved in runtime state')

      state = service.send(:build_state)

      expect(state[:captain_runtime]).to eq(runtime_preferences)
    end

    it 'includes conversation attributes when conversation is present' do
      state = service.send(:build_state)

      expect(state[:conversation]).to include(
        id: conversation.id,
        inbox_id: inbox.id,
        contact_id: contact.id,
        status: conversation.status
      )
      expect(state[:channel_type]).to eq(inbox.channel_type)
    end

    it 'includes contact inbox attributes when conversation is present' do
      state = service.send(:build_state)

      expect(state[:contact_inbox]).to include(
        id: conversation.contact_inbox.id,
        hmac_verified: conversation.contact_inbox.hmac_verified
      )
    end

    it 'always includes contact attributes in state for tool access' do
      state = service.send(:build_state)

      expect(state[:contact]).to include(
        id: contact.id,
        name: contact.name,
        email: contact.email
      )
    end

    it 'does not include campaign when conversation has no campaign' do
      state = service.send(:build_state)

      expect(state).not_to have_key(:campaign)
    end

    context 'when conversation has a campaign' do
      let(:campaign) { create(:campaign, account: account, title: 'Summer Sale', message: 'Check out our deals!', description: 'Seasonal promo') }
      let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, campaign: campaign) }

      it 'includes campaign attributes in state' do
        state = service.send(:build_state)

        expect(state[:campaign]).to include(
          id: campaign.id,
          title: 'Summer Sale',
          message: 'Check out our deals!',
          description: 'Seasonal promo'
        )
      end

      it 'only includes attributes defined in CAMPAIGN_STATE_ATTRIBUTES' do
        state = service.send(:build_state)

        expect(state[:campaign].keys).to match_array(described_class::CAMPAIGN_STATE_ATTRIBUTES)
      end
    end

    context 'when the conversation has linked CRM and scheduling records' do
      let!(:deal) do
        create(
          :crm_deal,
          account: account,
          originating_conversation: conversation,
          custom_attributes: { sales_region: 'EMEA' }
        )
      end
      let!(:task) do
        create(
          :crm_task,
          account: account,
          originating_conversation: conversation,
          custom_attributes: { follow_up_channel: 'phone' }
        )
      end
      let!(:appointment) do
        create(
          :scheduling_appointment,
          account: account,
          contact: contact,
          conversation: conversation,
          resource: create(:scheduling_resource, account: account),
          custom_attributes: { visit_room: 'B12' }
        )
      end

      before do
        create_field_definition(:deal, 'sales_region', 'Sales Region')
        create_field_definition(:task, 'follow_up_channel', 'Follow Up Channel')
        create_field_definition(:appointment, 'visit_room', 'Visit Room')
        account.enable_features!('crm_deals', 'crm_tasks', 'scheduling')
        assistant.update!(
          description: <<~TEXT.squish,
            Use [Deal Stage](field://deal.stage_name), [Sales Region](field://deal.custom_attributes.sales_region),
            [Task Status](field://task.status_name), [Follow Up Channel](field://task.custom_attributes.follow_up_channel),
            [Appointment Status](field://appointment.status), and [Visit Room](field://appointment.custom_attributes.visit_room).
          TEXT
          config: {
            'context_access' => {
              'deal' => {
                'enabled' => true,
                'field_ids' => ['deal.stage_name', 'deal.custom_attributes.sales_region']
              },
              'task' => {
                'enabled' => true,
                'field_ids' => ['task.status_name', 'task.custom_attributes.follow_up_channel']
              },
              'appointment' => {
                'enabled' => true,
                'field_ids' => ['appointment.status', 'appointment.custom_attributes.visit_room']
              }
            }
          }
        )
      end

      it 'includes appointment state and prompt context', :aggregate_failures do
        state = service.send(:build_state)

        expect(state[:deal]).to include(
          id: deal.id,
          originating_conversation_id: conversation.id,
          stage_name: deal.stage.name
        )
        expect(state.dig(:prompt_context, :deal)).to eq(
          'stage_name' => deal.stage.name,
          :custom_attributes => { 'sales_region' => 'EMEA' }
        )
        expect(state.dig(:prompt_context, :visible_fields, :deal)).to eq(['stage_name'])
        expect(state[:task]).to include(
          id: task.id,
          originating_conversation_id: conversation.id,
          status_name: task.status.name
        )
        expect(state.dig(:prompt_context, :task)).to eq(
          'status_name' => task.status.name,
          :custom_attributes => { 'follow_up_channel' => 'phone' }
        )
        expect(state.dig(:prompt_context, :visible_fields, :task)).to eq(['status_name'])
        expect(state[:appointment]).to include(
          id: appointment.id,
          conversation_id: conversation.id,
          status: appointment.status
        )
        expect(state.dig(:prompt_context, :appointment)).to eq(
          'status' => appointment.status,
          :custom_attributes => { 'visit_room' => 'B12' }
        )
        expect(state.dig(:prompt_context, :visible_fields, :appointment)).to eq(['status'])
      end
    end

    context 'when conversation is nil' do
      subject(:service) { described_class.new(assistant: assistant, conversation: nil) }

      it 'builds state without conversation and contact' do
        state = service.send(:build_state)

        expect(state).to include(
          account_id: account.id,
          assistant_id: assistant.id,
          assistant_config: assistant.config
        )
        expect(state).not_to have_key(:conversation)
        expect(state).not_to have_key(:contact)
        expect(state).not_to have_key(:campaign)
      end
    end
  end

  describe '#add_usage_metadata_callback' do
    it 'sets credit_used=false when handoff tool is used' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      runner = instance_double(Captain::Runtime::AgentRunner)
      tool_complete_callback = nil
      run_complete_callback = nil
      span_class = Class.new do
        def set_attribute(*); end
      end
      root_span = instance_double(span_class)
      context_wrapper = Struct.new(:context).new({ __otel_tracing: { root_span: root_span } })

      allow(ChatwootApp).to receive(:otel_enabled?).and_return(true)
      allow(runner).to receive(:on_tool_complete) do |&block|
        tool_complete_callback = block
        runner
      end
      allow(runner).to receive(:on_run_complete) do |&block|
        run_complete_callback = block
        runner
      end

      service.send(:add_usage_metadata_callback, runner)

      tool_complete_callback.call(Captain::Tools::HandoffTool.new(assistant).name, 'ok', context_wrapper)

      expect(context_wrapper.context[:captain_v2_completed_tool_names]).to eq(
        [Captain::Tools::HandoffTool.new(assistant).name]
      )
      expect(root_span).to receive(:set_attribute).with('langfuse.trace.metadata.credit_used', 'false')
      run_complete_callback.call('assistant', nil, context_wrapper)
    end

    it 'tracks artifact ids exposed by completed tool results' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      runner = instance_double(Captain::Runtime::AgentRunner)
      tool_complete_callback = nil
      context_wrapper = Struct.new(:context).new({})

      allow(ChatwootApp).to receive(:otel_enabled?).and_return(false)
      allow(runner).to receive(:on_tool_complete) do |&block|
        tool_complete_callback = block
        runner
      end

      service.send(:add_usage_metadata_callback, runner)

      tool_complete_callback.call(
        'list_captain_documents',
        Captain::ToolResult.success(
          data: {
            documents: [
              { artifact_id: 'doc-artifact-1', sendable: true },
              { 'artifact_id' => 'doc-artifact-2', 'sendable' => true }
            ],
            artifact_candidates: [{ id: 'http-artifact-1' }]
          }
        ),
        context_wrapper
      )

      expect(context_wrapper.context[:captain_v2_completed_tool_names]).to eq(['list_captain_documents'])
      expect(context_wrapper.context[:captain_v2_completed_tool_results]).to contain_exactly(
        hash_including(
          tool_name: 'list_captain_documents',
          success: true,
          data_type: 'hash'
        )
      )
      expect(context_wrapper.context[:captain_v2_artifact_ids]).to contain_exactly(
        'doc-artifact-1',
        'doc-artifact-2',
        'http-artifact-1'
      )
    end

    it 'sets credit_used=true when handoff tool is not used' do
      service = described_class.new(assistant: assistant, conversation: conversation)
      runner = instance_double(Captain::Runtime::AgentRunner)
      run_complete_callback = nil
      span_class = Class.new do
        def set_attribute(*); end
      end
      root_span = instance_double(span_class)
      context_wrapper = Struct.new(:context).new({ __otel_tracing: { root_span: root_span } })

      allow(ChatwootApp).to receive(:otel_enabled?).and_return(true)
      allow(runner).to receive(:on_tool_complete).and_return(runner)
      allow(runner).to receive(:on_run_complete) do |&block|
        run_complete_callback = block
        runner
      end

      service.send(:add_usage_metadata_callback, runner)

      expect(root_span).to receive(:set_attribute).with('langfuse.trace.metadata.credit_used', 'true')
      run_complete_callback.call('assistant', nil, context_wrapper)
    end
  end

  describe 'constants' do
    it 'defines conversation state attributes' do
      expect(Captain::ContextFields::CONVERSATION_STATE_ATTRIBUTES).to include(
        :id, :display_id, :inbox_id, :contact_id, :status, :priority
      )
    end

    it 'defines contact state attributes' do
      expect(Captain::ContextFields::CONTACT_STATE_ATTRIBUTES).to include(
        :id, :name, :email, :phone_number, :identifier, :contact_type
      )
    end

    it 'defines campaign state attributes' do
      expect(described_class::CAMPAIGN_STATE_ATTRIBUTES).to include(
        :id, :title, :message, :campaign_type, :description
      )
    end
  end

  def finalization_tool_history
    [
      { role: :user, content: 'Create a deal for this contact' },
      {
        role: :assistant,
        content: '',
        agent_name: 'scenario_agent',
        tool_calls: [{ id: 'call_1', name: 'create_deal', arguments: { title: 'New deal' } }]
      },
      { role: :tool, content: '{"deal_id":123,"title":"New deal"}', tool_call_id: 'call_1' }
    ]
  end

  def finalization_failed_context(tool_history)
    {
      current_agent: 'scenario_agent',
      conversation_history: tool_history,
      captain_v2_completed_tool_names: ['create_deal'],
      captain_v2_completed_tool_results: [{ tool_name: 'create_deal', success: true }]
    }
  end

  def subscribe_to_finalization_retry_events(retry_events)
    ActiveSupport::Notifications.subscribe('llm.schema.finalization_retry') do |*args|
      retry_events << ActiveSupport::Notifications::Event.new(*args)
    end
  end

  def subscribe_to_zero_completion_events(events)
    ActiveSupport::Notifications.subscribe(/llm\.zero_completion\./) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
  end

  def allow_finalization_retry_runner(failed_context, run_calls)
    blank_result = agent_result(output: { 'response' => '', 'handoff_message' => '' }, context: failed_context)
    recovered_result = agent_result(
      output: { 'response' => 'Deal created.', 'reasoning' => 'Used the completed create_deal tool result.' },
      context: failed_context.merge(current_agent: 'scenario_agent')
    )

    allow(mock_runner).to receive(:run) do |input, context:, max_turns:, runtime_options:|
      run_calls << { input: input, context: context, max_turns: max_turns, runtime_options: runtime_options }
      run_calls.one? ? blank_result : recovered_result
    end
  end

  def agent_result(output:, context:, error: nil)
    instance_double(Captain::Runtime::Result, output: output, context: context, error: error)
  end

  def expect_finalization_retry_call(run_calls, failed_context, tool_history)
    expect(mock_runner).to have_received(:run).twice
    expect(run_calls.second[:input]).to be_nil
    expect(run_calls.second[:max_turns]).to eq(described_class::MAX_RUNTIME_TURNS)
    expect_finalization_runtime_options(run_calls.second[:runtime_options])
    expect_finalization_retry_context(run_calls.second[:context], failed_context, tool_history)
  end

  def expect_finalization_runtime_options(runtime_options)
    expect(runtime_options).to include(
      account: account,
      finalization_only: true,
      continue_from_history: true
    )
    expect(runtime_options[:llm_context]).to be_a(RubyLLM::Context)
  end

  def expect_finalization_retry_context(context, failed_context, tool_history)
    expect(context).to include(
      current_agent: 'scenario_agent',
      conversation_history: tool_history,
      captain_v2_completed_tool_names: ['create_deal'],
      captain_v2_completed_tool_results: [{ tool_name: 'create_deal', success: true }]
    )
    expect(context).not_to equal(failed_context)
  end

  def expect_finalization_retry_result(result)
    expect(result).to include(
      'response' => 'Deal created.',
      'reasoning' => 'Used the completed create_deal tool result.',
      'agent_name' => 'scenario_agent',
      'handoff_tool_called' => false,
      'finalization_only_retry' => true,
      'zero_completion_recovered' => true,
      'zero_completion_recovery_kind' => described_class::ZERO_COMPLETION_FINALIZATION_RETRY
    )
    expect(result).not_to include('schema_fallback' => true)
  end

  def expect_finalization_retry_event(retry_events)
    expect(retry_events.map(&:payload)).to contain_exactly(
      hash_including(
        'schema_name' => 'Captain::ResponseSchema',
        'status' => 'retrying',
        'reason' => 'Assistant runtime returned a blank response',
        'completed_tools_count' => 1,
        'completed_tool_names' => ['create_deal']
      )
    )
  end

  def expect_zero_completion_finalization_events(events)
    expect(events.map(&:name)).to contain_exactly(
      'llm.zero_completion.detected',
      'llm.zero_completion.retry',
      'llm.zero_completion.recovered'
    )
    expect(events.map(&:payload)).to include(
      hash_including(
        'status' => 'retrying',
        'recovery_kind' => described_class::ZERO_COMPLETION_FINALIZATION_RETRY,
        'completed_tools_count' => 1,
        'completed_tool_names' => ['create_deal']
      ),
      hash_including(
        'status' => 'recovered',
        'recovery_kind' => described_class::ZERO_COMPLETION_FINALIZATION_RETRY,
        'completed_tools_count' => 1,
        'completed_tool_names' => ['create_deal']
      )
    )
  end

  def create_field_definition(entity_kind, key, label)
    create(
      :crm_field_definition,
      account: account,
      entity_kind: entity_kind,
      key: key,
      label: label
    )
  end
end
