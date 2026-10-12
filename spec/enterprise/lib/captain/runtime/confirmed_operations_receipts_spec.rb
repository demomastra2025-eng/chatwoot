require 'rails_helper'

RSpec.describe Captain::Runtime::ConfirmedOperations, 'durable operation receipts' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:entry) { create(:captain_assistant, account: account) }
  let(:specialist) { create(:captain_assistant, account: account) }
  let(:conversation) do
    create(:captain_inbox, inbox: inbox, captain_assistant: entry, reply_to_open_conversations: false)
    create(:conversation, account: account, inbox: inbox, status: :pending)
  end
  let(:tool) { double('action tool', name: 'create_appointment', metadata: { risk_level: 'high' }) }
  let(:executions) { [] }
  let(:pending_text) { 'Запрос отправлен, подтверждение придёт сообщением.' }
  let(:actors) do
    [entry, specialist].index_by(&:id).transform_values do |assistant|
      double("actor #{assistant.id}", id: assistant.id, agent_name: "assistant_#{assistant.id}", agent_tools: [tool])
    end
  end
  let(:graph) do
    double('channel graph').tap { |channel| allow(channel).to receive(:find) { |id| actors[id] } }
  end
  let(:run_context) do
    double('run context').tap do |object|
      allow(object).to receive(:activate) do |actor, run_state|
        run_state[:state][:assistant_id] = actor.id
        run_state[:agent_session].update_routing(actor_id: actor.id)
      end
    end
  end

  def stored_part(executor_id)
    { 'id' => 'synthetic-part', 'version' => 2, 'executor_agent_id' => executor_id, 'state' => 'open',
      'fragment' => 'Записать на приём',
      'proposed_operation' => { 'type' => 'create_appointment', 'params' => { 'slot_id' => 9 } } }
  end

  def session_with(parts = nil, fence: {})
    Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation, fence: fence).tap do |session|
      session.change { |data| data['parts'] = parts } if parts
    end
  end

  def execute(session, executor_id)
    run_state = { state: { assistant_id: executor_id, account_id: account.id, conversation: { id: conversation.id } },
                  agent_session: session, agent_run_context_object: run_context, agent_request_id: 'synthetic-request',
                  parts: session.read['parts'] }
    described_class.new(context: run_state, graph: graph).run([stored_part(executor_id)])
  end

  # Mirrors the tool wrapper: claim the durable receipt, call the provider, record what came back.
  def stub_provider(&provider)
    allow(Captain::Runtime::ToolWrapper).to receive(:new) do |wrapped_tool, wrapper|
      double('wrapped tool').tap do |wrapped|
        allow(wrapped).to receive(:call) do |arguments|
          guard = Captain::Runtime::OperationGuard.new(wrapper.context, wrapped_tool, arguments.deep_symbolize_keys)
          outcome = guard.reserve
          unless outcome
            executions << arguments
            outcome = provider.call(arguments)
            guard.finish(outcome)
          end
          wrapper.callback_manager.emit_tool_complete(wrapped_tool.name, outcome, wrapper)
        end
      end
    end
  end

  it 'never executes an unknown outcome again in a later run or through another executor' do
    stub_provider { |_arguments| raise 'connection dropped after the request was sent' }

    expect(execute(session_with([stored_part(entry.id)]), entry.id)).to eq(pending_text)
    expect(executions.size).to eq(1)

    later = session_with
    expect(execute(later, entry.id)).to eq(pending_text)

    later.change { |data| data['parts'].first['executor_agent_id'] = specialist.id }
    expect(execute(session_with, specialist.id)).to eq(pending_text)

    expect(executions.size).to eq(1)
    expect(session_with.read['parts'].first['state']).to eq('unknown')
  end

  it 'records the result of an executed action after staff took over and sends nothing to the customer' do
    stub_provider do |_arguments|
      conversation.update!(status: :open) # staff takes over while the provider call is running
      Captain::ToolResult.success(data: { appointment_id: 77 })
    end
    session = session_with([stored_part(entry.id)], fence: { control_generation: conversation.captain_control_generation })

    expect(execute(session, entry.id)).to eq('Действие выполнено.')

    saved = session_with.read
    expect(executions.size).to eq(1)
    expect(saved['parts'].first['state']).to eq('done')
    expect(saved['operations'].values.sole).to include('status' => 'finished')
    expect(conversation.messages.outgoing.count).to eq(0)
  end
end
