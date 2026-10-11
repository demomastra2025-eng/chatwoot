# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ChatResponseObserver do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:model) { 'openai/gpt-6-luna' }
  let(:endpoint) { 'https://openrouter.example/api/v1/chat/completions' }
  let(:context) do
    RubyLLM.context do |config|
      config.openrouter_api_key = 'synthetic-observer-key'
      config.openrouter_api_base = 'https://openrouter.example/api/v1'
    end
  end
  let(:chat) { context.chat(model: model, provider: :openrouter, assume_model_exists: true) }
  let(:observability) do
    { provider: 'openrouter', feature: 'captain_agent', account_id: account.id, assistant_id: assistant.id,
      conversation_record_id: conversation.id, conversation_display_id: conversation.display_id }
  end
  let(:tool_class) do
    Class.new(RubyLLM::Tool) do
      description 'Return a deterministic local read-only value.'
      param :step, type: :integer, required: true
      attr_accessor :executions, :halt

      def name
        'usage_probe'
      end

      def execute(step:)
        executions << step
        halt ? RubyLLM::Tool::Halt.new('Synthetic terminal result') : { step: step, read_only: true }
      end
    end
  end
  let(:tool) { tool_class.new.tap { |instance| instance.executions = [] } }

  before do
    allow(Llm::Models).to receive(:credit_multiplier_for).and_return(1)
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
      model => { 'provider' => 'openrouter', 'type' => 'chat',
                 'capabilities' => %w[tool_calling structured_output], 'supported_parameters' => %w[tools tool_choice response_format] }
    )
    allow(Llm::Monitoring::OtelEventExporter).to receive(:export_notification)
    expect(Llm::OpenRouterGenerationClient).not_to receive(:fetch)
    Llm::EventSubscriber.install!
  end

  after do
    Llm::EventSubscriber.uninstall!
  end

  def canned_response(index, tool_call: false, cost: nil)
    message = if tool_call
                { role: 'assistant', content: nil,
                  tool_calls: [{ id: "call-#{index}", type: 'function',
                                 function: { name: 'usage_probe', arguments: { step: index }.to_json } }] }
              else
                { role: 'assistant', content: 'Synthetic final answer', reasoning: 'SYNTHETIC_PRIVATE_REASONING' }
              end
    {
      status: 200, headers: { 'Content-Type' => 'application/json' },
      body: { id: "gen-observer-#{index}", model: model, provider: 'Azure',
              choices: [{ index: 0, message: message, finish_reason: tool_call ? 'tool_calls' : 'stop' }],
              usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120,
                       cost: cost || format('%.4f', index / 10_000.0),
                       prompt_tokens_details: { cached_tokens: 30 },
                       completion_tokens_details: { reasoning_tokens: 7 } } }.to_json
    }
  end

  def usage_rows
    LlmUsageEvent.where(account_id: account.id, event_name: 'llm.chat.complete').order(:id)
  end

  def observed_complete(metadata = observability)
    Llm::ChatClient.complete(chat, model: model, observability: metadata)
  end

  def publish_runtime_summary(response)
    wrapper = Captain::Runtime::RunContext.new(
      { current_agent: 'assistant_agent', state: { account_id: account.id, assistant_id: assistant.id,
                                                 conversation: { id: conversation.id, display_id: conversation.display_id } } }
    )
    wrapper.context[Captain::Runtime::TracingCallbacks::TRACE_EVENT_CONTEXT_KEY] = {
      prompt_tokens: 999, completion_tokens: 999, thinking_tokens: 999, estimated_cost: 99, cost: 99,
      openrouter_generation_id: 'gen-synthetic-runtime-summary', generation_id: 'gen-synthetic-runtime-summary',
      usage: { total_tokens: 999 }
    }
    Captain::Runtime::EventBusCallbacks.new.on_llm_call_complete('assistant_agent', model, response, wrapper)
  end

  it 'accounts for all nine native SDK HTTP responses once, including the eight tool-loop generations' do
    responses = (1..9).map { |index| canned_response(index, tool_call: index < 9) }
    request = stub_request(:post, endpoint).to_return(*responses)
    chat.with_tool(tool, concurrency: false)
    chat.add_message(role: :user, content: 'Synthetic local read-only round trip')

    result = observed_complete
    expect(Internal::FetchOpenRouterGenerationMetadataJob).not_to receive(:perform_later)
    publish_runtime_summary(result)

    expect(result.content).to eq('Synthetic final answer')
    expect(result).to equal(chat.messages.last)
    expect(request).to have_been_requested.times(9)
    expect(tool.executions).to eq((1..8).to_a)
    expect(usage_rows.pluck(:generation_id)).to eq((1..9).map { |index| "gen-observer-#{index}" })
    expect(usage_rows.count).to eq(9)
    expect(usage_rows.pluck(:request_id).uniq.size).to eq(9)
    expect(usage_rows.sum(:estimated_cost)).to eq(BigDecimal('0.0045'))
    expect(usage_rows.sum(:prompt_tokens)).to eq(900)
    expect(usage_rows.sum(:completion_tokens)).to eq(180)
    expect(usage_rows.sum(:total_tokens)).to eq(1080)
    expect(usage_rows.sum(:reasoning_tokens)).to eq(63)
    expect(usage_rows.sum(:cached_tokens)).to eq(270)
    expect(usage_rows.pluck(:actual_provider).uniq).to eq(['Azure'])
    expect(usage_rows.map { |row| row.metadata['assistant_id'] }.uniq).to eq([assistant.id])
    expect(usage_rows.map { |row| row.metadata['conversation_id'] }.uniq).to eq([conversation.id])

    events = LlmEvent.where(account_id: account.id)
    outer = events.find_by!(event_name: 'llm.chat.request')
    expect(outer).to have_attributes(prompt_tokens: nil, completion_tokens: nil, total_tokens: nil, estimated_cost: nil)
    expect(outer.payload).to include('provider_response_count' => 9, 'usage_scope' => 'outer_request')
    expect(outer.payload).not_to have_key('openrouter_generation_id')
    runtime = events.find_by!(event_name: 'llm.chat.runtime_complete')
    expect(runtime).to have_attributes(request_id: outer.request_id, assistant_id: assistant.id, conversation_id: conversation.id,
                                      prompt_tokens: nil, completion_tokens: nil, total_tokens: nil, thinking_tokens: nil, estimated_cost: nil)
    expect(runtime.payload).to include('usage_scope' => 'runtime_summary', 'provider_response_count' => 9)
    expect(runtime.payload).not_to have_key('openrouter_generation_id')
    expect(runtime.payload).not_to have_key('usage')
    expect(runtime.payload).not_to have_key('cost')
    expect(runtime.payload).not_to have_key('generation_id')
    snapshot = Llm::Monitoring::MetricsSnapshot.new(scope: events).call
    expect(snapshot).to include(request_count: 9, total_tokens: 1080, all_total_tokens: 1080)
    expect(snapshot[:total_estimated_cost].to_d).to eq(BigDecimal('0.0045'))
    expect(events.map(&:payload).to_json).not_to include('Synthetic final answer', 'SYNTHETIC_PRIVATE_REASONING', 'synthetic-observer-key')
  end

  it 'installs one callback on reused chats and attributes the next completion to the new actor' do
    second_assistant = create(:captain_assistant, account: account)
    request = stub_request(:post, endpoint).to_return(canned_response(1), canned_response(2))

    Llm::ChatClient.ask(chat, 'Synthetic first input', model: model, observability: observability)
    chat.add_message(role: :user, content: 'Synthetic second input')
    observed_complete(observability.merge(assistant_id: second_assistant.id))

    expect(request).to have_been_requested.twice
    expect(usage_rows.count).to eq(2)
    expect(usage_rows.map { |row| row.metadata['assistant_id'] }).to eq([assistant.id, second_assistant.id])
    expect(usage_rows.pluck(:generation_id)).to eq(%w[gen-observer-1 gen-observer-2])
    expect(chat.messages.count { |message| message.role == :user }).to eq(2)
    expect(ActiveSupport::IsolatedExecutionState[described_class::SCOPE_STATE_KEY]).to be_nil
  end

  it 'keeps the existing end-message callback and terminal tool Halt without billing the local tool message' do
    request = stub_request(:post, endpoint).to_return(canned_response(1, tool_call: true, cost: '0'))
    roles = []
    chat.on_end_message { |message| roles << message.role }
    tool.halt = true
    chat.with_tool(tool, concurrency: false)
    chat.add_message(role: :user, content: 'Synthetic terminal local read')

    result = observed_complete
    expect(Internal::FetchOpenRouterGenerationMetadataJob).not_to receive(:perform_later)
    publish_runtime_summary(result)

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect(result.content).to eq('Synthetic terminal result')
    expect(request).to have_been_requested.once
    expect(tool.executions).to eq([1])
    expect(roles).to eq(%i[assistant tool])
    expect(usage_rows.count).to eq(1)
    expect(usage_rows.first).to have_attributes(generation_id: 'gen-observer-1', estimated_cost: BigDecimal(0))
    outer = LlmEvent.where(account_id: account.id, event_name: 'llm.chat.request').sole
    runtime = LlmEvent.where(account_id: account.id, event_name: 'llm.chat.runtime_complete').sole
    expect(runtime).to have_attributes(request_id: outer.request_id, total_tokens: nil, thinking_tokens: nil, estimated_cost: nil)
    expect(runtime.payload).to include('usage_scope' => 'runtime_summary', 'provider_response_count' => 1)
  end

  it 'propagates tool exceptions, retains the preceding generation and clears the active observation scope' do
    request = stub_request(:post, endpoint).to_return(canned_response(1, tool_call: true), canned_response(2))
    allow(tool).to receive(:call).and_raise(RuntimeError, 'Synthetic tool failure')
    chat.with_tool(tool, concurrency: false)
    chat.add_message(role: :user, content: 'Synthetic failing local tool')

    expect { observed_complete }.to raise_error(RuntimeError, 'Synthetic tool failure')

    expect(usage_rows.pluck(:generation_id)).to eq(['gen-observer-1'])
    outer = LlmEvent.where(account_id: account.id, event_name: 'llm.chat.request').last
    expect(outer).to have_attributes(error: true, status: 'error', estimated_cost: nil)
    expect(outer.payload).to include('provider_response_count' => 1)
    expect(ActiveSupport::IsolatedExecutionState[described_class::SCOPE_STATE_KEY]).to be_nil

    chat.with_tools(replace: true)
    chat.complete
    expect(request).to have_been_requested.twice
    expect(usage_rows.count).to eq(1)
  end

  it 'preserves a provider exception as an outer error with unknown usage instead of inventing a charged generation' do
    stub_request(:post, endpoint).to_return(status: 400, headers: { 'Content-Type' => 'application/json' },
                                            body: { error: { message: 'Synthetic invalid request' } }.to_json)
    chat.add_message(role: :user, content: 'Synthetic rejected request')

    expect { observed_complete }.to raise_error(RubyLLM::Error)

    expect(usage_rows).to be_empty
    outer = LlmEvent.where(account_id: account.id, event_name: 'llm.chat.request').last
    expect(outer).to have_attributes(error: true, status: 'error', prompt_tokens: nil, estimated_cost: nil)
    expect(outer.payload).to include('provider_response_count' => 0)
    expect(ActiveSupport::IsolatedExecutionState[described_class::SCOPE_STATE_KEY]).to be_nil
  end

  it 'keeps real local tool execution and the response when usage observation fails without logging its sensitive message' do
    request = stub_request(:post, endpoint).to_return(canned_response(1, tool_call: true), canned_response(2))
    allow(Llm::ObservabilityPayload).to receive(:attach_provider_chat_response!).and_raise(StandardError, 'PRIVATE_OBSERVER_SECRET')
    warnings = []
    allow(Rails.logger).to receive(:warn) { |message| warnings << message }
    chat.with_tool(tool, concurrency: false)
    chat.add_message(role: :user, content: 'Synthetic local read')

    result = observed_complete

    expect(request).to have_been_requested.twice
    expect(tool.executions).to eq([1])
    expect(result.content).to eq('Synthetic final answer')
    outer = LlmEvent.where(account_id: account.id, event_name: 'llm.chat.request').last
    expect(outer.payload).to include('provider_response_count' => 2, 'provider_observability_error_count' => 2)
    expect(warnings.join).to include('class=StandardError')
    expect(warnings.join).not_to include('PRIVATE_OBSERVER_SECRET')
    expect(LlmEvent.where(account_id: account.id).map(&:payload).to_json).not_to include('PRIVATE_OBSERVER_SECRET')
  end

  it 'observes the native ChatRequestRunner path without a duplicate outer usage charge' do
    request = stub_request(:post, endpoint).to_return(canned_response(1), canned_response(2))
    Llm::ChatRequestRunner.new(chat: chat, model: model,
                               messages: [{ role: 'user', content: 'Synthetic first request' }],
                               observability: observability).call
    observed_complete

    expect(request).to have_been_requested.twice
    expect(usage_rows.pluck(:generation_id)).to eq(%w[gen-observer-1 gen-observer-2])
    expect(usage_rows.count).to eq(2)
    expect(usage_rows.sum(:estimated_cost)).to eq(BigDecimal('0.0003'))
    expect(usage_rows.pluck(:account_id).uniq).to eq([account.id])
    expect(usage_rows.map { |row| row.metadata['assistant_id'] }.uniq).to eq([assistant.id])
    expect(usage_rows.map { |row| row.metadata['conversation_id'] }.uniq).to eq([conversation.id])
    outer = LlmEvent.where(account_id: account.id, event_name: 'llm.chat.request').order(:id)
    expect(outer.count).to eq(2)
    expect(outer.pluck(:assistant_id, :conversation_id).uniq).to eq([[assistant.id, conversation.id]])
    expect(outer.map { |event| event.payload['provider_response_count'] }).to eq([1, 1])
  end

  it 'records one outer error for the nested native ChatRequestRunner and ChatClient path' do
    stub_request(:post, endpoint).to_return(status: 400, headers: { 'Content-Type' => 'application/json' },
                                            body: { error: { message: 'Synthetic invalid request' } }.to_json)
    runner = Llm::ChatRequestRunner.new(chat: chat, model: model,
                                       messages: [{ role: 'user', content: 'Synthetic rejected request' }],
                                       observability: observability)

    expect { runner.call }.to raise_error(RubyLLM::Error)

    expect(usage_rows).to be_empty
    events = LlmEvent.where(account_id: account.id)
    outer = events.where(event_name: 'llm.chat.request')
    expect(outer.count).to eq(1)
    expect(outer.first).to have_attributes(error: true, assistant_id: assistant.id, conversation_id: conversation.id)
    expect(outer.first.payload).to include('provider_response_count' => 0)
    expect(Llm::Monitoring::MetricsSnapshot.new(scope: events).call[:error_count]).to eq(1)
    expect(ActiveSupport::IsolatedExecutionState[described_class::SCOPE_STATE_KEY]).to be_nil
  end
end
