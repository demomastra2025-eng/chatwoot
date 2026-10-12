require 'rails_helper'

# Test tool constants intentionally live with the examples that exercise them.
# rubocop:disable Lint/ConstantDefinitionInBlock
RSpec.describe Captain::Runtime::PartPlanTool do
  class PartPlanToolSpecBookingTool < Captain::Runtime::Tool
    param :title, type: :string, required: true

    attr_reader :calls

    def initialize
      super
      @calls = 0
    end

    def name = 'create_appointment'
    def description = 'Create an appointment'
    def metadata = { risk_level: 'high', idempotent: false }

    def perform(_tool_context, **params)
      @calls += 1
      Captain::ToolResult.success(message: "booked #{params.fetch(:title)}", data: { appointment_id: calls })
    end
  end

  it 'requires a fragment, names the executor by an optional agent name and shows no numeric agent id to the model' do
    schema = described_class.new.params_schema.deep_stringify_keys
    valid = { 'mode' => 'answer_myself', 'parts' => [{ 'fragment' => 'Цена', 'executor' => 'Администратор' }] }
    without = ->(key) { valid.deep_dup.tap { |item| item['parts'][0].delete(key) } }

    expect(JSONSchemer.schema(schema).valid?(valid)).to be(true)
    expect(JSONSchemer.schema(schema).valid?(without.call('executor'))).to be(true)
    expect(JSONSchemer.schema(schema).valid?(without.call('fragment'))).to be(false)
    expect(JSONSchemer.schema(schema).valid?(valid.deep_dup.tap { |item| item['parts'][0]['executor'] = nil })).to be(true)
    expect(JSONSchemer.schema(schema).valid?(valid.deep_dup.tap { |item| item['parts'][0]['executor_agent_id'] = 1 })).to be(false)
    expect(schema.dig('properties', 'parts', 'items', 'properties').keys).not_to include('executor_agent_id')
  end

  it 'describes the executor as an agent name to the model and never mentions an agent id' do
    description = described_class.new.parameters[:parts].description

    expect(description).to include('executor (the agent name exactly as listed')
    expect(description).not_to include('executor_agent_id')
  end

  it 'tells the model that a person is reached with the handoff tool and is not an executor' do
    executor = described_class.new.params_schema.deep_stringify_keys.dig('properties', 'parts', 'items', 'properties', 'executor')

    expect(executor['description']).to include('Staff or an operator is not an agent: reach them with the handoff tool.')
  end

  it 'turns the former executor_agent_id into an agent key and a number in the executor into plain text before validation' do
    arguments = { mode: 'answer_myself', parts: [{ fragment: 'A', executor_agent_id: 1793 }, { fragment: 'B', executor: 7 },
                                                 { fragment: 'C', executor: ' ', executor_agent_id: nil },
                                                 { fragment: 'D', executor: 'Администратор', executor_agent_id: 5 }] }

    normalized = described_class.new.normalize_runtime_arguments(arguments, context: {})

    expect(normalized[:parts]).to eq([{ fragment: 'A', executor: 'assistant_1793' }, { fragment: 'B', executor: '7' }, { fragment: 'C' },
                                      { fragment: 'D', executor: 'Администратор' }])
    expect(described_class.new.normalize_runtime_arguments({ mode: 'clarify', parts: 'x' }, context: {})).to eq(mode: 'clarify', parts: 'x')
  end

  describe 'planning by agent name' do
    let(:entry) { create(:captain_assistant) }
    let(:session) { Captain::Conversation::AgentSession.new(entry: entry) }
    let(:entry_agent) { { id: entry.id, key: "assistant_#{entry.id}", name: 'Intermedical — DEV Test', description: 'Клиника' } }
    let(:lab_agent) { { id: entry.id + 1000, key: "assistant_#{entry.id + 1000}", name: 'Лаборатория', description: 'Анализы' } }
    let(:graph) { [entry_agent] }
    let(:context) do
      { state: { assistant_id: entry.id, captain_runtime: {} }, agent_graph: graph, agent_session: session,
        agent_request_id: 'synthetic-request', parts: [], agent_tasks: [] }
    end
    let(:run_context) { Captain::Runtime::RunContext.new(context) }
    let(:planner) { Captain::Runtime::ToolWrapper.new(described_class.new, run_context) }

    before { session.update_routing(actor_id: entry.id) }

    def failure_payload(rendered)
      JSON.parse(rendered.delete_prefix('ERROR: '))
    end

    it 'accepts a guessed number as the current agent in a single-agent setup and lets the booking tool run' do
      booking = PartPlanToolSpecBookingTool.new
      book = Captain::Runtime::ToolWrapper.new(booking, run_context)

      rendered = planner.call(mode: 'answer_myself', parts: [{ fragment: 'Записать на приём', executor_agent_id: 1 }])
      plan = JSON.parse(rendered)

      expect(plan['mode']).to eq('answer_myself')
      expect(plan['parts'].sole).to eq('id' => context[:part_plan][:parts].sole['id'], 'version' => 1, 'executor' => 'Intermedical — DEV Test')
      expect(context[:part_plan][:parts].sole['executor_agent_id']).to eq(entry.id)
      expect(context[:part_plan_accepted]).to be(true)
      expect(book.call(title: 'synthetic visit')).to include('booked synthetic visit')
      expect(booking.calls).to eq(1)
    end

    it 'accepts an unknown executor text as the current agent in answer_myself' do
      rendered = planner.call(mode: 'answer_myself', parts: [{ fragment: 'Какой адрес?', executor: 'Агент 1' }])

      expect(JSON.parse(rendered)['parts'].sole).to include('executor' => 'Intermedical — DEV Test')
      expect(context[:part_plan][:parts].sole['executor_agent_id']).to eq(entry.id)
    end

    it 'takes an omitted executor as the current agent and ignores quotes and letter case in its own name' do
      rendered = planner.call(mode: 'clarify', clarification: 'Какой врач нужен?',
                              parts: [{ fragment: 'Запись' }, { fragment: 'Анализы', executor: ' «INTERMEDICAL — dev test» ' }])

      expect(JSON.parse(rendered)['parts'].pluck('executor')).to eq(['Intermedical — DEV Test'] * 2)
      expect(context[:part_plan][:parts].pluck('executor_agent_id')).to eq([entry.id] * 2)
    end

    it 'answers the former handoff mode with a retryable error and no accepted plan, in a single-agent setup' do
      rendered = planner.call(mode: 'handoff', parts: [{ fragment: 'Анализы', executor: 'Лаборатория' }])
      payload = failure_payload(rendered)

      expect(payload).to include('retryable' => true)
      expect(payload['error']).to eq(
        'No other agent can be chosen on this channel. ' \
        'To pass the customer to a person call the handoff tool, not plan_request. For your own work use mode answer_myself.'
      )
      expect(payload['error']).not_to include('unavailable on this channel')
      expect(context[:part_plan_accepted]).to be_nil
    end

    describe 'a plan the model can still correct' do
      let(:terminal_key) { Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY }

      def identical_failures(times, **arguments)
        Array.new(times) { failure_payload(planner.call(**arguments)) }
      end

      it 'keeps the former handoff mode, with the executor omitted or its own name, retryable however often it is repeated' do
        [nil, 'Intermedical — DEV Test'].each do |executor|
          part = executor ? { fragment: 'Соедините с оператором', executor: executor } : { fragment: 'Соедините с оператором' }
          failures = identical_failures(3, mode: 'handoff', parts: [part])

          expect(failures.pluck('retryable')).to eq([true] * 3)
          expect(failures.pluck('error').uniq.sole).to start_with('No other agent can be chosen on this channel.')
          expect(failures.first['error']).to include('call the handoff tool, not plan_request')
          expect(context).not_to include(terminal_key)
          expect(context[:part_plan_accepted]).to be_nil
        end
      end

      it 'keeps a council of one agent retryable' do
        failures = identical_failures(2, mode: 'council', parts: [{ fragment: 'Адрес' }, { fragment: 'Цена' }])

        expect(failures.pluck('retryable')).to eq([true, true])
        expect(failures.first['error']).to eq('No other agent can be chosen on this channel; use mode answer_myself.')
        expect(context).not_to include(terminal_key)
      end

      it 'keeps any other rejection of the arguments retryable' do
        failures = identical_failures(2, mode: 'answer_myself', parts: [{ fragment: 'Да', link_part_id: 'gone', link_action: 'answer' }])

        expect(failures.pluck('retryable')).to eq([true, true])
        expect(failures.first['error']).to eq('Linked part is not open')
        expect(context).not_to include(terminal_key)
      end

      it 'stops a model that repeats the same rejected call without end, instead of letting it loop' do
        arguments = { mode: 'handoff', parts: [{ fragment: 'Соедините с оператором' }] }
        3.times { planner.call(**arguments) }

        expect(planner.call(**arguments)).to be_a(RubyLLM::Tool::Halt)
        expect(context).to include(terminal_key)
      end

      it 'leaves only a second plan for an already planned message non-retryable' do
        context.delete(:agent_session)
        planner.call(mode: 'answer_myself', parts: [{ fragment: 'Адрес клиники' }])

        payload = failure_payload(planner.call(mode: 'clarify', clarification: 'Какой врач?', parts: [{ fragment: 'Запись' }]))

        expect(payload).to include('retryable' => false, 'error' => 'This message already has a plan')
      end
    end

    context 'with a second agent on the channel' do
      let(:graph) { [entry_agent, lab_agent] }
      let(:own_part) { { fragment: 'Адрес клиники' } }

      # A part of a colleague is planned only in a council (two agents); one colleague alone is the colleague's transfer tool.
      def council_with_lab(lab_part)
        planner.call(mode: 'council', parts: [own_part, lab_part])
      end

      def lab_part_of_plan
        context[:part_plan][:parts].last
      end

      it 'answers the former handoff mode with the colleagues to choose from and their transfer tools' do
        payload = failure_payload(planner.call(mode: 'handoff', parts: [{ fragment: 'Сдать анализы', executor: 'Лаборатория' }]))

        expect(payload).to include('retryable' => true)
        expect(payload['error']).to eq(
          'plan_request has no handoff mode. To pass the conversation to one colleague, call that colleague\'s transfer tool ' \
          'without a plan. Colleagues: Лаборатория. To pass the customer to a person call the handoff tool, not plan_request. ' \
          'plan_request is only for a council (separate requests for different agents) and for the answer to an open part.'
        )
        expect(context[:part_plan_accepted]).to be_nil
        expect(context[:part_plan]).to be_nil
      end

      it 'rejects the former handoff mode before looking at its parts, and keeps rejecting it' do
        3.times do
          payload = failure_payload(planner.call(mode: 'handoff', parts: []))

          expect(payload).to include('retryable' => true)
          expect(payload['error']).to start_with('plan_request has no handoff mode.')
        end
      end

      it 'does not list handoff among the modes a plan can have' do
        expect(Captain::Runtime::PartRegistry::MODES).to eq(%w[answer_myself council clarify])
        expect(described_class.new.parameters[:mode].description).to eq('answer_myself, council, or clarify')
      end

      it 'plans a part of a peer named like in the agent list and reports the peer by name' do
        rendered = council_with_lab({ fragment: 'Сдать анализы', executor: '«лаборатория»' })

        expect(JSON.parse(rendered)['parts'].last).to include('version' => 1, 'executor' => 'Лаборатория')
        expect(JSON.parse(rendered)['parts'].last.keys).to match_array(%w[id version executor])
        expect(lab_part_of_plan['executor_agent_id']).to eq(lab_agent[:id])
      end

      it 'still plans a part of a peer when a model sends the former numeric executor_agent_id' do
        rendered = council_with_lab({ fragment: 'Сдать анализы', executor_agent_id: lab_agent[:id] })

        expect(JSON.parse(rendered)['parts'].last).to include('executor' => 'Лаборатория')
        expect(lab_part_of_plan['executor_agent_id']).to eq(lab_agent[:id])
      end

      it 'keeps the executor of a part that waits for the customer when the plan with the answer names no executor' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        part = lab_part_of_plan
        Captain::Runtime::PartRegistry.new(context).record_result!(part['id'], state: 'waiting_customer', summary: 'На какое время?')
        context.delete(:part_plan_accepted)
        context.delete(:part_plan)
        context[:agent_request_id] = 'next-request'

        rendered = planner.call(mode: 'council', parts: [{ fragment: 'Да', link_part_id: part['id'], link_action: 'answer' }])

        expect(JSON.parse(rendered)['parts'].sole).to include('id' => part['id'], 'version' => 2, 'executor' => 'Лаборатория')
        expect(context[:part_plan][:parts].sole).to include('prior_summary' => 'На какое время?')
      end

      it 'fails a council that names an unknown agent with the list of valid names' do
        payload = failure_payload(council_with_lab({ fragment: 'Сдать анализы', executor: 'Регистратура' }))

        expect(payload).to include('retryable' => true,
                                   'error' => 'Unknown agent "Регистратура". Use one of: Intermedical — DEV Test, Лаборатория')
        expect(context[:part_plan_accepted]).to be_nil
      end

      it 'does not take a guessed number for the peer in a council, and lists the names instead' do
        payload = failure_payload(council_with_lab({ fragment: 'Сдать анализы', executor: lab_agent[:id].to_s }))

        expect(payload).to include('retryable' => true)
        expect(payload['error']).to start_with(%(Unknown agent "#{lab_agent[:id]}". Use one of: Intermedical — DEV Test, Лаборатория))
        expect(context[:part_plan_accepted]).to be_nil
      end

      it 'asks an own part that names the peer for the transfer tool of that peer, and lets a council with that peer through' do
        payload = failure_payload(planner.call(mode: 'answer_myself', parts: [{ fragment: 'Сдать анализы', executor: 'Лаборатория' }]))

        expect(payload).to include(
          'retryable' => true,
          'error' => 'This part belongs to Лаборатория. Pass the conversation to that colleague with its transfer tool ' \
                     '(no plan needed), or omit the executor to keep it yourself.'
        )
        expect(JSON.parse(council_with_lab({ fragment: 'Сдать анализы', executor: 'Лаборатория' }))['mode']).to eq('council')
      end

      def wait_for_the_customer(part)
        Captain::Runtime::PartRegistry.new(context).record_result!(part['id'], state: 'waiting_customer')
        context.delete(:part_plan_accepted)
        context.delete(:part_plan)
        context[:agent_request_id] = "next-request-#{SecureRandom.hex(3)}"
      end

      it 'keeps a peer part with its owner when the answer to it names no executor, and asks for a council in answer_myself' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        part = lab_part_of_plan
        wait_for_the_customer(part)
        reply = { fragment: 'Завтра', link_part_id: part['id'], link_action: 'answer' }

        own = failure_payload(planner.call(mode: 'answer_myself', parts: [reply]))
        expect(own).to include('retryable' => true)
        expect(own['error']).to start_with('This part belongs to Лаборатория.').and include('mode council and ONLY that part linked')

        rendered = planner.call(mode: 'council', parts: [reply.merge(fragment: 'Завтра в десять'),
                                                          { fragment: 'Адрес клиники', link_action: 'new' }])
        expect(JSON.parse(rendered)['parts'].first).to include('id' => part['id'], 'version' => 2, 'executor' => 'Лаборатория')
        expect(context[:part_plan][:parts].first['executor_agent_id']).to eq(lab_agent[:id])
      end

      it 'plans the answer to a peer part as a council of that one part, and the former handoff mode for it names the council' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        part = lab_part_of_plan
        wait_for_the_customer(part)
        answer = { fragment: 'Давайте в 11', link_part_id: part['id'], link_action: 'answer' }

        refused = failure_payload(planner.call(mode: 'handoff', parts: [answer]))
        expect(refused).to include('retryable' => true)
        expect(refused['error']).to include('mode council and ONLY that part linked')
        expect(refused['error']).not_to include('transfer tool')

        rendered = planner.call(mode: 'council', parts: [answer])

        expect(JSON.parse(rendered)).to include('mode' => 'council')
        expect(JSON.parse(rendered)['parts'].sole).to include('id' => part['id'], 'version' => 2, 'executor' => 'Лаборатория')
        expect(context[:part_plan][:parts].sole).to include('executor_agent_id' => lab_agent[:id], 'link_action' => 'answer')
        expect(context).not_to have_key(:active_part_id)
      end

      it 'understands the former link action confirmation as an answer, before the schema is checked' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        part = lab_part_of_plan
        wait_for_the_customer(part)

        rendered = planner.call(mode: 'council', parts: [{ fragment: 'Да', link_part_id: part['id'], link_action: 'confirmation' }])

        expect(JSON.parse(rendered)['parts'].sole).to include('id' => part['id'], 'executor' => 'Лаборатория')
        expect(context[:part_plan][:parts].sole).to include('link_action' => 'answer')
      end

      it 'does not offer the link action confirmation to the model' do
        link_actions = described_class.new.params_schema.deep_stringify_keys.dig('properties', 'parts', 'items', 'properties', 'link_action', 'enum')

        expect(link_actions).to eq(%w[new answer correction cancellation])
      end

      it 'plans a council with the current agent left out of the part and one peer named' do
        rendered = planner.call(mode: 'council', parts: [{ fragment: 'Адрес клиники' },
                                                         { fragment: 'Цена анализа', executor: 'Лаборатория' }])

        expect(JSON.parse(rendered)['parts'].pluck('executor')).to eq(['Intermedical — DEV Test', 'Лаборатория'])
        expect(context[:part_plan][:parts].pluck('executor_agent_id')).to eq([entry.id, lab_agent[:id]])
      end

      it 'fails a council that names an unknown agent with the list of valid names, whatever the part' do
        payload = failure_payload(planner.call(mode: 'council', parts: [{ fragment: 'Адрес' }, { fragment: 'Цена', executor: 'Касса' }]))

        expect(payload).to include('retryable' => true)
        expect(payload['error']).to eq('Unknown agent "Касса". Use one of: Intermedical — DEV Test, Лаборатория')
      end

      it 'fails a council that names an ambiguous duplicate name and still answers an own part with that name' do
        graph << lab_agent.merge(id: lab_agent[:id] + 1, key: nil, name: ' лаборатория ')

        failure = failure_payload(council_with_lab({ fragment: 'Анализы', executor: 'Лаборатория' }))

        expect(failure).to include('retryable' => true)
        expect(failure['error']).to start_with('Unknown agent "Лаборатория" (several agents share this name).')
        expect(failure['error']).not_to include('Use one of: Лаборатория')
        expect(planner.call(mode: 'answer_myself', parts: [{ fragment: 'Анализы', executor: 'Лаборатория' }])).to include('Intermedical')
      end
    end
  end

  it 'describes a coordination tool between agents, not a step before the agent\'s own actions or a transfer' do
    description = described_class.new.description

    expect(description).to include('split a message into separate requests for different agents (a council)',
                                   'route the customer\'s answer, correction or cancellation of an open part of another agent to that agent',
                                   'Not needed for your own lookups, replies or actions',
                                   'that colleague\'s transfer tool does it without a plan')
    expect(description).not_to include('transfer the conversation to another agent', 'before using action tools')
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock
