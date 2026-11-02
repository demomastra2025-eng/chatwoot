require 'rails_helper'

RSpec.describe Onelink::Mcp::CaptainToolAdapter, '#call_tool' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:assistant) do
    create(:captain_assistant, account: account, config: {
             'capabilities' => { 'version' => 1, 'scopes' => {
               'agent' => { 'enabled' => true, 'tool_ids' => [] },
               'assistant' => { 'enabled' => true, 'tool_ids' => %w[get_tool_execution_log trace_ai_response] }
             } }
           })
  end
  let(:context) do
    Captain::Runtime::RunContext.new({ state: { account_id: account.id, assistant_id: assistant.id, source: 'playground' },
                                       session_id: "diagnostic-spec-#{SecureRandom.uuid}" })
  end
  let(:auth_context) do
    instance_double(Onelink::Mcp::AuthContext, account: account, user: admin, assistant: assistant,
                                               scope_name: Captain::ToolAccess::SCOPE_ASSISTANT, administrator?: true,
                                               mcp_access_policy: Onelink::Mcp::AccessPolicy.new(account: account, user: admin, config: {}))
  end
  let(:adapter) { described_class.new(auth_context: auth_context) }

  after { Current.reset }

  def record_failure(result)
    payload = nil
    subscriber = ActiveSupport::Notifications.subscribe('llm.tool.complete') do |*args|
      payload = ActiveSupport::Notifications::Event.new(*args).payload
    end
    callbacks = Captain::Runtime::EventBusCallbacks.new
    callbacks.on_tool_start('create_appointment', { resource_id: 123, patient: 'synthetic-private-input' }, context)
    callbacks.on_tool_complete('create_appointment', result, context)
    event = Llm::Monitoring::EventRecorder.record_notification(
      event_name: 'llm.tool.complete', started_at: Time.current, finished_at: Time.current, payload: payload
    )
    [payload, event]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'retains metadata through the full MCP path while raw tool bodies are absent at the producer' do
    payload, event = record_failure(Captain::ToolResult.failure(error: 'Synthetic private failure body', data: { code: 'not_found' }))
    expect(payload).to include('result_success' => false, 'result_error_size' => 30)
    expect(payload.keys).not_to include('arguments', 'result', 'result_error_preview')
    expect(event).to be_persisted
    response = adapter.call_tool(name: 'get_tool_execution_log', arguments: { failed_only: true })
    expect(response[:isError]).to be(false)
    entry = response.fetch(:structuredContent).fetch('entries').find { |item| item['id'] == event.id }
    expect(entry).to include('tool_id' => 'create_appointment', 'result_success' => false)
    expect(response.to_json).not_to include('Synthetic private failure body', 'synthetic-private-input')
    expect(Onelink::Mcp::ResponseRedactor.call({ content: 'ordinary text', message: 'ordinary message', answer: 'ordinary answer' }))
      .to include(content: 'ordinary text', message: 'ordinary message', answer: 'ordinary answer')
  end

  it 'keeps account and administrator boundaries and redacts nested secrets without hiding ordinary diagnostic strings' do
    _, event = record_failure(Captain::ToolResult.failure(error: 'Synthetic private failure body', data: { code: 'not_found' }))
    foreign = create(:llm_event, account: create(:account), event_name: 'llm.tool.complete', error: true)
    response = adapter.call_tool(name: 'get_tool_execution_log', arguments: {})
    ids = response.fetch(:structuredContent).fetch('entries').pluck('id')
    expect(ids).to include(event.id)
    expect(ids).not_to include(foreign.id)
    ordinary = { message: 'Safe diagnostic', error: 'not_found', nested: JSON.generate(password: 'synthetic-secret', answer: 'ordinary answer') }
    safe = Onelink::Mcp::ResponseRedactor.call(ordinary)
    expect(safe).to include(message: 'Safe diagnostic', error: 'not_found')
    expect(safe.to_json).not_to include('synthetic-secret')
    expect(JSON.parse(safe[:nested])).to include('password' => '[FILTERED]', 'answer' => 'ordinary answer')
    agent = create(:user, account: account)
    allow(auth_context).to receive_messages(user: agent, administrator?: false)
    expect(adapter.call_tool(name: 'get_tool_execution_log', arguments: {})[:isError]).to be(true)
  end
end
