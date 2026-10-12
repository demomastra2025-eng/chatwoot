require 'rails_helper'

RSpec.describe Captain::Runtime::ConfirmedOperations do
  let(:tool) { double('action tool', name: 'create_deal', metadata: { risk_level: 'high' }) }
  let(:first_actor) { double('first actor', id: 1, agent_name: 'assistant_1', agent_tools: [tool]) }
  let(:second_actor) { double('second actor', id: 2, agent_name: 'assistant_2', agent_tools: [tool]) }
  let(:graph) { double('channel graph') }
  let(:parts) do
    [first_actor, second_actor].each_with_index.map do |actor, index|
      { 'id' => "synthetic-part-#{index}", 'version' => 2, 'executor_agent_id' => actor.id,
        'state' => 'open', 'proposed_operation' => { 'type' => 'create_deal', 'params' => { 'amount' => index + 1 } } }
    end
  end
  let(:context) do
    { state: { assistant_id: 1 }, parts: parts.deep_dup,
      agent_run_context_object: double('run context', activate: nil) }
  end

  it 'executes confirmed proposals sequentially with their exact parameters' do
    allow(graph).to receive(:find).with(1).and_return(first_actor)
    allow(graph).to receive(:find).with(2).and_return(second_actor)
    received = []
    allow(Captain::Runtime::ToolWrapper).to receive(:new) do |_tool, wrapper|
      double('wrapped tool').tap do |wrapped|
        allow(wrapped).to receive(:call) do |params|
          received << params
          wrapper.callback_manager.emit_tool_complete('create_deal', Captain::ToolResult.success(data: { id: received.size }), wrapper)
        end
      end
    end

    response = described_class.new(context: context, graph: graph).run(parts)

    expect(received).to eq([{ 'amount' => 1 }, { 'amount' => 2 }])
    expect(context[:parts].pluck('state')).to eq(%w[done done])
    expect(response.scan('Действие выполнено.').size).to eq(2)
  end

  describe 'dependent parts' do
    let(:slot_taken) { { success: false, error: 'Slot is taken', audit: { mutation_executed: false } } }
    let(:chain) do
      [
        { 'id' => 'first-part', 'version' => 2, 'executor_agent_id' => 1, 'state' => 'open', 'relation' => 'independent',
          'fragment' => 'Отменить визит', 'proposed_operation' => { 'type' => 'create_deal', 'params' => { 'step' => 1 } } },
        { 'id' => 'second-part', 'version' => 2, 'executor_agent_id' => 2, 'state' => 'open', 'relation' => 'depends_on',
          'depends_on_part_id' => 'first-part', 'fragment' => 'Записать на новое время',
          'proposed_operation' => { 'type' => 'create_deal', 'params' => { 'step' => 2 } } }
      ]
    end
    let(:chain_context) { context.merge(parts: chain.deep_dup) }

    before do
      allow(graph).to receive(:find).with(1).and_return(first_actor)
      allow(graph).to receive(:find).with(2).and_return(second_actor)
    end

    # Replaces the tool boundary: every call is recorded and answered with the next outcome.
    def stub_tool_calls(*outcomes)
      received = []
      allow(Captain::Runtime::ToolWrapper).to receive(:new) do |_tool, wrapper|
        double('wrapped tool').tap do |wrapped|
          allow(wrapped).to receive(:call) do |params|
            received << params
            outcome = outcomes.shift || Captain::ToolResult.success(data: { id: received.size })
            raise outcome if outcome.is_a?(Exception)

            wrapper.callback_manager.emit_tool_complete('create_deal', outcome, wrapper)
          end
        end
      end
      received
    end

    def run_chain(batch = chain)
      described_class.new(context: chain_context, graph: graph).run(batch)
    end

    it 'runs a dependent part after its prerequisite and reports every part' do
      received = stub_tool_calls

      response = run_chain

      expect(received).to eq([{ 'step' => 1 }, { 'step' => 2 }])
      expect(chain_context[:parts].pluck('state')).to eq(%w[done done])
      expect(response).to eq("«Отменить визит»: Действие выполнено.\n\n«Записать на новое время»: Действие выполнено.")
    end

    it 'executes the prerequisite first even when it is listed after its dependent part' do
      received = stub_tool_calls

      run_chain(chain.reverse)

      expect(received).to eq([{ 'step' => 1 }, { 'step' => 2 }])
    end

    it 'stops the chain at a definite failure and states what was not started' do
      received = stub_tool_calls(slot_taken)

      response = run_chain

      expect(received).to eq([{ 'step' => 1 }])
      expect(chain_context[:parts].pluck('state')).to eq(%w[failed open])
      expect(response).to eq("«Отменить визит»: Действие не выполнено.\n\n" \
                             '«Записать на новое время»: Не начато: предыдущий шаг не завершён.')
    end

    it 'stops the chain at an unknown outcome and never claims success' do
      received = stub_tool_calls(StandardError.new('connection reset'))

      response = run_chain

      expect(received.size).to eq(1)
      expect(chain_context[:parts].pluck('state')).to eq(%w[unknown open])
      expect(response).to eq("«Отменить визит»: Запрос отправлен, подтверждение придёт сообщением.\n\n" \
                             '«Записать на новое время»: Не начато: предыдущий шаг не завершён.')
      expect(response).not_to include('Действие выполнено')
    end

    it 'stops the chain while the provider confirmation is pending' do
      awaiting = Captain::ToolResult.success(data: { provider_confirmation_required: true, provider_confirmed: false })
      received = stub_tool_calls(awaiting)

      response = run_chain

      expect(received.size).to eq(1)
      expect(response).to include('Запрос отправлен, подтверждение придёт сообщением.', 'Не начато')
      expect(response).not_to include('Действие выполнено')
    end

    it 'does not start a dependent part whose prerequisite is answered only, cancelled or absent' do
      received = stub_tool_calls
      [{ 'state' => 'answered' }, { 'state' => 'done', 'cancelled' => true }, nil].each do |override|
        registry = chain.deep_dup
        override ? registry.first.merge!(override) : registry.shift

        response = described_class.new(context: context.merge(parts: registry), graph: graph).run([registry.last])

        expect(response).to eq('Не начато: предыдущий шаг не завершён.')
      end
      expect(received).to be_empty
    end

    it 'keeps running an independent part after another independent part failed' do
      independent = chain.map { |part| part.merge('relation' => 'independent').except('depends_on_part_id') }
      received = stub_tool_calls(slot_taken)

      response = described_class.new(context: context.merge(parts: independent.deep_dup), graph: graph).run(independent)

      expect(received).to eq([{ 'step' => 1 }, { 'step' => 2 }])
      expect(response).to include('Действие не выполнено.', 'Действие выполнено.')
    end

    it 'leaves conditional and unlinked dependent parts for review without executing them' do
      received = stub_tool_calls
      conditional = chain.first.merge('relation' => 'conditional')
      unlinked = chain.last.except('depends_on_part_id')

      [conditional, unlinked].each do |part|
        response = described_class.new(context: context.merge(parts: [part.deep_dup]), graph: graph).run([part])

        expect(response).to eq('Часть запроса требует дополнительной проверки.')
      end
      expect(received).to be_empty
    end

    it 'publishes operation events with identifiers and the outcome state only' do
      stub_tool_calls({ success: false, error: 'PRIVATE_ERROR', audit: { mutation_executed: false } })
      events = []
      subscriber = ActiveSupport::Notifications.subscribe(/\Acaptain\.operation\./) do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
      private_chain = chain.deep_dup
      private_chain.first['proposed_operation']['params']['note'] = 'PRIVATE_PARAM'

      described_class.new(context: context.merge(parts: private_chain.deep_dup), graph: graph).run(private_chain)

      expect(events.map(&:name)).to eq(%w[captain.operation.started captain.operation.finished captain.operation.finished])
      expect(events.first.payload).to include('part_id' => 'first-part', 'part_version' => 2, 'executor_agent_id' => 1,
                                              'tool_name' => 'create_deal')
      expect(events.second.payload).to include('part_id' => 'first-part', 'state' => 'failed')
      expect(events.third.payload).to include('part_id' => 'second-part', 'executor_agent_id' => 2, 'state' => 'not_started')
      expect(events.map { |event| event.payload.to_json }.join).not_to include('PRIVATE_PARAM', 'PRIVATE_ERROR', 'Отменить визит')
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
