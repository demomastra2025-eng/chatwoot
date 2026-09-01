# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::EventBusCallbacks do
  class EventBusCallbacksSpecChat < Struct.new(:model)
    def with_schema(_schema)
      self
    end
  end

  let(:events) { [] }
  let(:subscriber) do
    ActiveSupport::Notifications.subscribe(/llm\.(run|chat|tool|agent)\./) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
  end
  let(:context_wrapper) do
    Captain::Runtime::RunContext.new(
      {
        session_id: '1_42',
        current_agent: 'assistant_agent',
        state: {
          account_id: 1,
          assistant_id: 2,
          conversation: { id: 3, display_id: 42 },
          channel_type: 'web',
          source: 'spec'
        }
      }
    )
  end
  let(:callbacks) { described_class.new }

  before do
    subscriber
  end

  after do
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it 'publishes normalized runtime events with shared metadata' do
    chat = EventBusCallbacksSpecChat.new('gpt-4.1-mini')
    Llm::StructuredOutputPolicy.bind!(chat: chat, schema: Captain::ConversationCompletionSchema)
    response = Struct.new(:content, :input_tokens, :output_tokens, :thinking_tokens, :tool_call?) do
      def initialize(...)
        super
      end
    end.new({ complete: true }, 11, 7, 2, false)
    result = Captain::Runtime::Result.new(
      output: { response: 'Done' },
      usage: Struct.new(:input_tokens, :output_tokens, :total_tokens, :thinking_tokens).new(11, 7, 18, 2)
    )

    callbacks.on_run_start('assistant_agent', 'Hello', context_wrapper)
    callbacks.on_chat_created(chat, 'assistant_agent', 'gpt-4.1-mini', context_wrapper)
    callbacks.on_llm_call_complete(
      'assistant_agent',
      'gpt-4.1-mini',
      response,
      context_wrapper,
      provider_usage_recorded: true
    )
    callbacks.on_tool_requested('lookup_contact', { contact_id: 123 }, context_wrapper)
    callbacks.on_tool_start('lookup_contact', { contact_id: 123 }, context_wrapper)
    callbacks.on_tool_progress('lookup_contact', { phase: 'querying' }, context_wrapper)
    callbacks.on_tool_complete('lookup_contact', { status: 'ok' }, context_wrapper)
    callbacks.on_agent_handoff('assistant_agent', 'scenario_agent', 'handoff', context_wrapper)
    callbacks.on_run_complete('scenario_agent', result, context_wrapper)

    expect(events.map(&:name)).to include(
      'llm.run.start',
      'llm.chat.complete',
      'llm.tool.requested',
      'llm.tool.execute',
      'llm.tool.progress',
      'llm.tool.complete',
      'llm.agent.handoff',
      'llm.run.complete'
    )

    chat_event = events.find { |event| event.name == 'llm.chat.complete' }
    expect(chat_event.payload).to include(
      'feature' => 'assistant',
      'runtime_mode' => 'captain_runtime',
      'account_id' => 1,
      'assistant_id' => 2,
      'conversation_id' => 3,
      'conversation_display_id' => 42,
      'schema_name' => 'Captain::ConversationCompletionSchema',
      'model' => 'gpt-4.1-mini',
      'thinking_tokens' => 2,
      'usage_counted' => false
    )

    run_event = events.find { |event| event.name == 'llm.run.complete' }
    expect(run_event.payload).to include('thinking_tokens' => 2)
    expect(run_event.payload['usage'].with_indifferent_access).to include(
      input_tokens: 11,
      output_tokens: 7,
      total_tokens: 18,
      thinking_tokens: 2
    )
  end

  it 'keeps a direct runtime completion billable when no provider usage event was recorded' do
    response = Struct.new(:content, :input_tokens, :output_tokens, :tool_call?).new('Done', 11, 7, false)

    callbacks.on_llm_call_complete('assistant_agent', 'gpt-4.1-mini', response, context_wrapper)

    chat_event = events.find { |event| event.name == 'llm.chat.complete' }
    expect(chat_event.payload).not_to have_key('usage_counted')
  end

  it 'publishes normalized tool result telemetry for failures' do
    callbacks.on_tool_complete(
      'lookup_contact',
      Captain::ToolResult.failure(error: 'Provider timeout', retryable: true),
      context_wrapper
    )

    tool_event = events.find { |event| event.name == 'llm.tool.complete' }

    expect(tool_event.payload).to include(
      'tool_name' => 'lookup_contact',
      'result_type' => 'hash',
      'error' => true,
      'result_success' => false,
      'result_retryable' => true,
      'result_error_type' => 'string',
      'result_error_size' => 16
    )
  end

  it 'records lightweight tool execution timing when start and complete are paired' do
    callbacks.on_tool_start('lookup_contact', { contact_id: 123 }, context_wrapper)
    callbacks.on_tool_complete('lookup_contact', { status: 'ok' }, context_wrapper)

    tool_event = events.find { |event| event.name == 'llm.tool.complete' }

    expect(tool_event.payload).to include(
      'tool_name' => 'lookup_contact',
      'duration_ms' => a_kind_of(Integer),
      'started_at' => a_string_matching(/\d{4}-\d{2}-\d{2}T.*\.\d{6}/),
      'completed_at' => a_string_matching(/\d{4}-\d{2}-\d{2}T.*\.\d{6}/)
    )
  end

  it 'includes trace identifiers when tracing metadata is available' do
    context_wrapper.context[:__captain_trace_event] = {
      trace_id: 'trace-123',
      trace_name: 'llm.captain_v2',
      root_span_id: 'root-span-1',
      span_id: 'span-2',
      parent_span_id: 'root-span-1',
      span_kind: 'tool',
      span_name: 'llm.captain_v2.tool.lookup_contact'
    }

    callbacks.on_tool_complete('lookup_contact', { status: 'ok' }, context_wrapper)

    tool_event = events.find { |event| event.name == 'llm.tool.complete' }

    expect(tool_event.payload).to include(
      'trace_id' => 'trace-123',
      'trace_name' => 'llm.captain_v2',
      'root_span_id' => 'root-span-1',
      'span_id' => 'span-2',
      'parent_span_id' => 'root-span-1',
      'span_kind' => 'tool',
      'span_name' => 'llm.captain_v2.tool.lookup_contact'
    )
  end

  it 'matches the deterministic trace fixture for the first customer-support no-tool case' do
    case_context = Captain::Runtime::RunContext.new(
      context_wrapper.context.deep_dup.tap do |context|
        context[:state] = context[:state].merge(project_case_id: 'customer_support.basic_no_tool')
      end
    )
    chat = EventBusCallbacksSpecChat.new('gpt-4.1-mini')
    Llm::StructuredOutputPolicy.bind!(chat: chat, schema: Captain::ResponseSchema)
    response = Struct.new(:content, :input_tokens, :output_tokens, :tool_call?).new(
      { response: 'Your order is on the way.' },
      12,
      9,
      false
    )
    result = Captain::Runtime::Result.new(
      output: { response: 'Your order is on the way.' },
      usage: Struct.new(:input_tokens, :output_tokens, :total_tokens).new(12, 9, 21)
    )

    callbacks.on_run_start('assistant_agent', 'Where is my order?', case_context)
    callbacks.on_chat_created(chat, 'assistant_agent', 'gpt-4.1-mini', case_context)
    callbacks.on_llm_call_complete(
      'assistant_agent',
      'gpt-4.1-mini',
      response,
      case_context,
      provider_usage_recorded: true
    )
    callbacks.on_run_complete('assistant_agent', result, case_context)

    expected = JSON.parse(Rails.root.join('config/llm_evals/fixtures/captain/event_contract/customer_support_basic_no_tool.json').read)
    actual = events.last(3).map do |event|
      {
        'name' => event.name,
        'payload' => JSON.parse(event.payload.except('request_id').to_json)
      }
    end

    expect(actual).to eq(expected)
  end
end
