require 'rails_helper'

# Test tool constants intentionally live with the examples that exercise them.
# rubocop:disable Lint/ConstantDefinitionInBlock
RSpec.describe Captain::Runtime::PartPlanTool do
  it 'limits executors to available colleagues and hides links when no part is open' do
    context = { state: { assistant_id: 1 }, agent_graph: [{ id: 1, name: 'Регистратор' }, { id: 2, name: 'Бухгалтерия' }], parts: [] }
    properties = described_class.new(context).params_schema.dig('properties', 'parts', 'items', 'properties')

    expect(properties.dig('executor', 'enum')).to eq([nil, 'Бухгалтерия'])
    expect(properties.keys).not_to include('link_part_id', 'link_action')
  end

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
    valid = { 'mode' => 'council', 'parts' => [{ 'fragment' => 'Цена', 'executor' => 'Администратор' }] }
    without = ->(key) { valid.deep_dup.tap { |item| item['parts'][0].delete(key) } }

    expect(JSONSchemer.schema(schema).valid?(valid)).to be(true)
    expect(JSONSchemer.schema(schema).valid?(without.call('executor'))).to be(true)
    expect(JSONSchemer.schema(schema).valid?(without.call('fragment'))).to be(false)
    expect(JSONSchemer.schema(schema).valid?(valid.deep_dup.tap { |item| item['parts'][0]['executor'] = nil })).to be(true)
    expect(JSONSchemer.schema(schema).valid?(valid.deep_dup.tap { |item| item['parts'][0]['executor_agent_id'] = 1 })).to be(false)
    expect(schema.dig('properties', 'parts', 'items', 'properties').keys).not_to include('executor_agent_id')
  end

  it 'describes the executor as an agent name to the model and never mentions an agent id' do
    schema = described_class.new.params_schema.deep_stringify_keys
    executor = schema.dig('properties', 'parts', 'items', 'properties', 'executor')

    expect(executor['description']).to eq(described_class::EXECUTOR_DESCRIPTION)
    expect(executor['description']).to include('by its name exactly as listed under Colleagues', 'Omit it for your own action')
    expect(schema.to_json).not_to include('executor_agent_id')
  end

  it 'offers only the valid modes to the model and one item per action' do
    schema = described_class.new.params_schema.deep_stringify_keys

    expect(schema.dig('properties', 'mode', 'enum')).to eq(%w[council clarify])
    expect(schema.dig('properties', 'mode', 'enum')).to eq(Captain::Runtime::PartRegistry::MODES)
    expect(schema.dig('properties', 'parts', 'description')).to include('One item per action')
  end

  it 'tells the model, in the schema, what the relation conditional means and how the link to an open part is written' do
    properties = described_class.new.params_schema.deep_stringify_keys.dig('properties', 'parts', 'items', 'properties')

    expect(properties.dig('relation', 'description')).to include('How this part follows the part before it in this plan',
                                                                'conditional ("if X then Y")', 'list the part that decides first',
                                                                'depends_on: the action is carried out only when the part before it succeeded',
                                                                'The patient\'s reaction to an open part goes into link_action.')
    expect(properties.dig('link_part_id', 'description')).to include('number from the list of open parts', 'Leave it out for a new action')
    expect(properties.dig('link_action', 'description')).to include('new: a separate new action')
  end

  it 'calls what a plan holds an action, the same word as the rules of the coordination block' do
    schema = described_class.new.params_schema.deep_stringify_keys
    texts = [described_class.new.description, schema.dig('properties', 'mode', 'description'), schema.dig('properties', 'parts', 'description'),
             *schema.dig('properties', 'parts', 'items', 'properties').values.pluck('description')]

    expect(texts.join(' ').scan(/\bactions?\b/).size).to be >= 8
    expect(texts.join(' ')).not_to match(/\brequests?\b/)
  end

  it 'tells the model that a person is reached with the handoff tool and is not an executor' do
    executor = described_class.new.params_schema.deep_stringify_keys.dig('properties', 'parts', 'items', 'properties', 'executor')

    expect(executor['description']).to include('Staff are not an agent: use the handoff tool.')
  end

  it 'describes every field of a part to the model in a few plain words, without internal jargon' do
    properties = described_class.new.params_schema.deep_stringify_keys.dig('properties', 'parts', 'items', 'properties')
    link = properties.fetch('link_part_id')

    expect(properties.keys).to match_array(%w[fragment executor patient relation object_refs link_part_id link_action])
    expect(properties.values.map { |item| item['description'] }).to all(be_present)
    expect(link['description']).to eq(described_class::LINK_PART_DESCRIPTION)
    expect(link['type']).to eq(%w[string integer null])
    expect(properties.values.map { |item| item['description'] }.join(' ')).not_to match(/executor_agent_id|UUID|exact ID/i)
  end

  it 'describes the modes and the optional fields briefly' do
    parameters = described_class.new.parameters

    expect(parameters[:mode].description).to eq(
      'council: actions for different agents, or one open part of another agent that the message answers, corrects or cancels. ' \
      'clarify: one question for the patient, when two or more open parts could be meant and the message names none.'
    )
    expect(parameters.keys).to eq(%i[mode parts clarification])
    expect(parameters[:parts].description).to eq(
      'One item per action, in the order of the patient\'s message; a council has at most three. A single item is for one open part ' \
      'of another agent that the message answers, corrects or cancels.'
    )
    expect(parameters[:clarification].description).to eq('The one precise question, for clarify only.')
  end

  it 'turns the former executor_agent_id into an agent key and a number in the executor into plain text before validation' do
    arguments = { mode: 'council', parts: [{ fragment: 'A', executor_agent_id: 1793 }, { fragment: 'B', executor: 7 },
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
    let(:new_action_note) { Captain::Runtime::PartRegistry::NEW_ACTION_NOTE }

    before { session.update_routing(actor_id: entry.id) }

    def failure_payload(rendered)
      JSON.parse(rendered.delete_prefix('ERROR: '))
    end

    # A mode outside the schema never gets past the wrapper's validation of a real call; the tool still answers it when it is
    # called without the wrapper (a plan stored by an older version, another caller).
    def plan_directly(**arguments)
      Captain::ToolResult.render(described_class.new.perform(Captain::Runtime::ToolContext.new(run_context: run_context), **arguments))
    end

    def open_peer_part(id, state: 'waiting_customer')
      { 'id' => id, 'version' => 1, 'state' => state, 'executor_agent_id' => entry.id + 1000, 'fragment' => id }
    end

    it 'refuses a mode outside the schema with the valid modes and the way to work without a plan' do
      booking = PartPlanToolSpecBookingTool.new
      book = Captain::Runtime::ToolWrapper.new(booking, run_context)

      payload = failure_payload(plan_directly(mode: 'answer_myself', parts: [{ fragment: 'Записать на приём', executor_agent_id: 1 }]))

      expect(payload).to include('retryable' => true, 'error' => Captain::Runtime::PartRegistry::INVALID_MODE)
      expect(payload['error']).to include('Valid modes: council', 'clarify')
      expect(context[:part_plan_accepted]).to be_nil
      expect(book.call(title: 'synthetic visit')).to include('booked synthetic visit')
      expect(booking.calls).to eq(1)
    end

    it 'tells a model that sends a value outside an enum of the schema the values it can send, for the mode and for a field of a part' do
      wrong_mode = failure_payload(planner.call(mode: 'answer', parts: [{ fragment: 'Записать на приём' }]))
      wrong_relation = failure_payload(planner.call(mode: 'council', parts: [{ fragment: 'Да', relation: 'answer' }]))
      wrong_link_action = failure_payload(planner.call(mode: 'council', parts: [{ fragment: 'Да', link_action: 'reply' }]))

      expect(wrong_mode['error']).to eq('Invalid tool arguments at /mode: enum (allowed: council, clarify)')
      expect(wrong_relation['error']).to eq('Invalid tool arguments at /parts/0/relation: enum (allowed: independent, conditional, depends_on)')
      expect(wrong_link_action['error']).to eq('Invalid tool arguments at /parts/0/link_action: enum (allowed: new, answer, correction, cancellation)')
      expect(context[:part_plan_accepted]).to be_nil
    end

    it 'takes an omitted executor as the current agent and ignores quotes and letter case in its own name' do
      context[:parts] = [open_peer_part('first'), open_peer_part('second')]

      rendered = planner.call(mode: 'clarify', clarification: 'Какой врач нужен?',
                              parts: [{ fragment: 'Запись' }, { fragment: 'Анализы', executor: ' «INTERMEDICAL — dev test» ' }])

      expect(JSON.parse(rendered)['parts'].pluck('executor')).to eq(['Intermedical — DEV Test'] * 2)
      expect(context[:part_plan][:parts].pluck('executor_agent_id')).to eq([entry.id] * 2)
    end

    it 'takes an unknown executor text as the current agent outside a council' do
      context[:parts] = [open_peer_part('first'), open_peer_part('second')]

      rendered = planner.call(mode: 'clarify', clarification: 'Какой запрос?', parts: [{ fragment: 'Какой адрес?', executor: 'Агент 1' }])

      expect(JSON.parse(rendered)['parts'].sole).to include('executor' => 'Intermedical — DEV Test')
      expect(context[:part_plan][:parts].sole['executor_agent_id']).to eq(entry.id)
    end

    it 'answers the former handoff mode with a retryable error and no accepted plan, in a single-agent setup' do
      rendered = plan_directly(mode: 'handoff', parts: [{ fragment: 'Анализы', executor: 'Лаборатория' }])
      payload = failure_payload(rendered)

      expect(payload).to include('retryable' => true)
      expect(payload['error']).to eq(
        'No other agent can be chosen on this channel. To reach a person call the handoff tool. ' \
        'Own work needs no plan: answer or use your tools.'
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
          failures = Array.new(3) { failure_payload(plan_directly(mode: 'handoff', parts: [part])) }

          expect(failures.pluck('retryable')).to eq([true] * 3)
          expect(failures.pluck('error').uniq.sole).to start_with('No other agent can be chosen on this channel.')
          expect(failures.first['error']).to include('To reach a person call the handoff tool.')
          expect(context).not_to include(terminal_key)
          expect(context[:part_plan_accepted]).to be_nil
        end
      end

      it 'keeps a council of one agent retryable' do
        failures = identical_failures(2, mode: 'council', parts: [{ fragment: 'Адрес' }, { fragment: 'Цена' }])

        expect(failures.pluck('retryable')).to eq([true, true])
        expect(failures.first['error']).to eq('No other agent can be chosen on this channel. Own work needs no plan: answer or use your tools.')
        expect(context).not_to include(terminal_key)
      end

      it 'keeps any other rejection of the arguments retryable' do
        failures = identical_failures(2, mode: 'council', parts: [{ fragment: 'Да', link_part_id: 'gone', link_action: 'answer' }])

        expect(failures.pluck('retryable')).to eq([true, true])
        expect(failures.first['error']).to eq("There is no part gone. No part is open. #{Captain::Runtime::PartRegistry::NEW_ACTION_NOTE}")
        expect(context).not_to include(terminal_key)
      end

      it 'stops a model that repeats the same rejected call without end, instead of letting it loop' do
        arguments = { mode: 'council', parts: [{ fragment: 'Адрес' }, { fragment: 'Цена' }] }
        3.times { planner.call(**arguments) }

        expect(planner.call(**arguments)).to be_a(RubyLLM::Tool::Halt)
        expect(context).to include(terminal_key)
      end
    end

    context 'with a second agent on the channel' do
      let(:graph) { [entry_agent, lab_agent] }
      let(:own_part) { { fragment: 'Адрес клиники' } }

      def open_lab_part(id)
        { 'id' => id, 'version' => 1, 'state' => 'waiting_customer', 'executor_agent_id' => lab_agent[:id], 'fragment' => id }
      end

      # A part of a colleague is planned only in a council (two agents); one colleague alone is the colleague's transfer tool.
      def council_with_lab(lab_part)
        planner.call(mode: 'council', parts: [own_part, lab_part])
      end

      def lab_part_of_plan
        context[:part_plan][:parts].last
      end

      it 'answers the former handoff mode with the colleagues to choose from and their transfer tools' do
        payload = failure_payload(plan_directly(mode: 'handoff', parts: [{ fragment: 'Сдать анализы', executor: 'Лаборатория' }]))

        expect(payload).to include('retryable' => true)
        expect(payload['error']).to eq(
          'plan_request has no handoff mode. To pass the conversation to one colleague, call that colleague\'s transfer tool ' \
          'without a plan. Colleagues: Лаборатория. To reach a person call the handoff tool. ' \
          'plan_request is only for a council (actions for different agents) and for the answer to an open part.'
        )
        expect(context[:part_plan_accepted]).to be_nil
        expect(context[:part_plan]).to be_nil
      end

      it 'rejects the former handoff mode before looking at its parts, and keeps rejecting it' do
        3.times do
          payload = failure_payload(plan_directly(mode: 'handoff', parts: []))

          expect(payload).to include('retryable' => true)
          expect(payload['error']).to start_with('plan_request has no handoff mode.')
        end
      end

      it 'does not list handoff among the modes a plan can have' do
        expect(Captain::Runtime::PartRegistry::MODES).to eq(%w[council clarify])
        expect(described_class.new.parameters[:mode].description).not_to include('handoff')
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

      it 'tells a plan whose actions all belong to one colleague to transfer the conversation with that colleague\'s transfer tool' do
        context[:captain_v2_bound_tool_ids] = ["transfer_to_agent_#{lab_agent[:id]}", 'plan_request']

        payload = failure_payload(planner.call(mode: 'council', parts: [{ fragment: 'Сдать анализы', executor: 'Лаборатория' }]))

        expect(payload).to include('retryable' => true)
        expect(payload['error']).to eq(
          "If all actions of the message belong to Лаборатория, transfer the conversation to Лаборатория with transfer_to_agent_#{lab_agent[:id]} " \
          'and plan nothing. A plan holds actions for two or more different agents; an action of yours is a part without executor.'
        )
        expect(context[:part_plan_accepted]).to be_nil
      end

      it 'tells a plan that does not link the open part of that colleague to link it with its number' do
        context[:parts] = [open_lab_part('lab-part')]
        context[:captain_v2_bound_tool_ids] = ["transfer_to_agent_#{lab_agent[:id]}", 'plan_request']

        payload = failure_payload(planner.call(mode: 'council', parts: [{ fragment: 'Давайте в 11', executor: 'Лаборатория' }]))

        expect(payload['error']).to start_with(
          'Лаборатория has the open part #1. If the message answers, corrects or cancels it, link it with link_part_id 1 and link_action ' \
          'answer, correction or cancellation'
        )
        expect(payload['error']).to include("transfer the conversation to Лаборатория with transfer_to_agent_#{lab_agent[:id]}")
      end

      it 'tells the actions of the writer only to be done with its own tools' do
        payload = failure_payload(planner.call(mode: 'council', parts: [{ fragment: 'Адрес клиники' }]))

        expect(payload['error']).to eq("Every part of this plan is yours. #{Captain::Runtime::PartRegistry::OWN_WORK_NOTE}")
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

      it 'refuses the former own-work mode even for a peer, and lets a council with that peer through' do
        payload = failure_payload(plan_directly(mode: 'answer_myself', parts: [{ fragment: 'Сдать анализы', executor: 'Лаборатория' }]))

        expect(payload).to include('retryable' => true, 'error' => Captain::Runtime::PartRegistry::INVALID_MODE)
        expect(JSON.parse(council_with_lab({ fragment: 'Сдать анализы', executor: 'Лаборатория' }))['mode']).to eq('council')
      end

      it 'leaves only a second plan for an already planned message non-retryable' do
        context.delete(:agent_session)
        council_with_lab({ fragment: 'Сдать анализы', executor: 'Лаборатория' })

        payload = failure_payload(planner.call(mode: 'clarify', clarification: 'Какой врач?', parts: [{ fragment: 'Запись' }]))

        expect(payload).to include('retryable' => false, 'error' => Captain::Runtime::PartRegistry::ALREADY_PLANNED)
        expect(payload['error']).to start_with('This message already has a plan: each agent of the plan does its part')
      end

      def wait_for_the_customer(part)
        Captain::Runtime::PartRegistry.new(context).record_result!(part['id'], state: 'waiting_customer')
        context.delete(:part_plan_accepted)
        context.delete(:part_plan)
        context[:agent_request_id] = "next-request-#{SecureRandom.hex(3)}"
      end

      it 'keeps a peer part with its owner when the answer to it names no executor' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        part = lab_part_of_plan
        wait_for_the_customer(part)
        reply = { fragment: 'Завтра', link_part_id: part['id'], link_action: 'answer' }

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

        refused = failure_payload(plan_directly(mode: 'handoff', parts: [answer]))
        expect(refused).to include('retryable' => true)
        expect(refused['error']).to include('mode council and ONLY that part linked by its number (link_part_id)')
        expect(refused['error']).not_to include('transfer tool')

        invalid = failure_payload(plan_directly(mode: 'answer', parts: [answer]))
        expect(invalid['error']).to include('Valid modes: council', 'mode council and ONLY that part linked')

        rendered = planner.call(mode: 'council', parts: [answer])

        expect(JSON.parse(rendered)).to include('mode' => 'council')
        expect(JSON.parse(rendered)['parts'].sole).to include('id' => part['id'], 'version' => 2, 'executor' => 'Лаборатория')
        expect(context[:part_plan][:parts].sole).to include('executor_agent_id' => lab_agent[:id], 'link_action' => 'answer')
        expect(context).not_to have_key(:active_part_id)
      end

      it 'links an open part by the number it is listed with, written as 2, "2" or "#2", and still by its exact id' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        part = lab_part_of_plan

        expect(Captain::Runtime::PartRegistry.number_of(context[:parts], part['id'])).to eq(2)
        [2, '2', '#2', part['id']].each do |reference|
          wait_for_the_customer(part)

          rendered = planner.call(mode: 'council', parts: [{ fragment: 'Да', link_part_id: reference, link_action: 'answer' }])

          expect(JSON.parse(rendered)['parts'].sole).to include('id' => part['id'], 'executor' => 'Лаборатория')
          expect(context[:part_plan][:parts].sole).to include('id' => part['id'], 'executor_agent_id' => lab_agent[:id])
        end
      end

      it 'refuses a number that is no open part, as a retryable error' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        wait_for_the_customer(lab_part_of_plan)

        unknown_numbers = ['9', '#0', 0]
        unknown_numbers.each do |reference|
          payload = failure_payload(planner.call(mode: 'council', parts: [{ fragment: 'Да', link_part_id: reference, link_action: 'answer' }]))

          expect(payload).to include('retryable' => true)
          expect(payload['error']).to eq(
            "There is no part #{reference}. Open parts: #2. If the message answers one of them, link its number. #{new_action_note}"
          )
        end
      end

      it 'tells a finished request apart from one that is with staff, and names the way on for each' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        part = lab_part_of_plan
        Captain::Runtime::PartRegistry.new(context).record_result!(part['id'], state: 'done', summary: 'Записано')
        reply = { fragment: 'Да', link_part_id: part['id'], link_action: 'answer' }

        context.delete(:part_plan_accepted)
        context.delete(:part_plan)
        context[:agent_request_id] = 'after-done'
        finished = failure_payload(planner.call(mode: 'council', parts: [reply]))

        expect(finished).to include('retryable' => true)
        expect(finished['error']).to eq(
          "Part #2 is closed (done). #{Captain::Runtime::PartRegistry::CLOSED_PART_NOTE} #{new_action_note}"
        )

        part_in_context = context[:parts].find { |item| item['id'] == part['id'] }
        part_in_context.merge!('state' => 'failed', 'handed_to_staff' => true)
        with_staff = failure_payload(planner.call(mode: 'council', parts: [reply]))

        expect(with_staff['error']).to eq(
          "Part #2 is with staff, who will answer it. #{Captain::Runtime::PartRegistry::STAFF_PART_NOTE} #{new_action_note}"
        )
        expect(new_action_note).to include("transfer the conversation with that colleague's transfer tool", 'link_action new')
      end

      it 'understands the former link action confirmation as an answer, before the schema is checked' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        part = lab_part_of_plan
        wait_for_the_customer(part)

        rendered = planner.call(mode: 'council', parts: [{ fragment: 'Да', link_part_id: part['id'], link_action: 'confirmation' }])

        expect(JSON.parse(rendered)['parts'].sole).to include('id' => part['id'], 'executor' => 'Лаборатория')
        expect(context[:part_plan][:parts].sole).to include('link_action' => 'answer')
      end

      it 'tells the model to confirm the cancellation of a part that never acted itself: no agent runs and no sentence is written for it' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        part = lab_part_of_plan
        wait_for_the_customer(part)

        rendered = planner.call(mode: 'council', parts: [{ fragment: 'Не надо', link_part_id: part['id'], link_action: 'cancellation' }])

        expect(JSON.parse(rendered)).to include('note' => described_class::CANCELLED_NOTE)
        expect(context[:part_plan][:parts].sole).to include('cancelled' => true, 'state' => 'done')
      end

      it 'gives no note for an answer to a part' do
        council_with_lab({ fragment: 'Записать на анализ', executor: 'Лаборатория' })
        part = lab_part_of_plan
        wait_for_the_customer(part)

        rendered = planner.call(mode: 'council', parts: [{ fragment: 'Да', link_part_id: part['id'], link_action: 'answer' }])

        expect(JSON.parse(rendered)).not_to have_key('note')
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
        context[:parts] = [open_lab_part('first'), open_lab_part('second')]
        outside_a_council = planner.call(mode: 'clarify', clarification: 'Какой запрос?', parts: [{ fragment: 'Анализы', executor: 'Лаборатория' }])

        expect(outside_a_council).to include('Intermedical')
      end
    end
  end

  it 'describes a coordination tool between agents in positive words: when to call it and what it does' do
    description = described_class.new.description

    expect(description).to eq(
      'Coordinate actions with other agents. Call it once when the patient\'s message holds actions for two or more different ' \
      'agents: it splits the message into parts (a council) and each agent does its part right away. Call it also to send the ' \
      'patient\'s answer, correction or cancellation of an open part to the agent that owns it. When all actions of the message ' \
      'belong to one colleague, transfer the conversation with that colleague\'s transfer tool.'
    )
    expect(description).not_to match(/\b(?:not|never|don't)\b/i)
    expect(description).not_to include('transfer the conversation to another agent', 'before using action tools', 'exact ID')
  end

  describe 'the audit log' do
    let(:entry) { create(:captain_assistant) }
    let(:session) { Captain::Conversation::AgentSession.new(entry: entry) }
    let(:lab_agent) { { id: entry.id + 1000, key: "assistant_#{entry.id + 1000}", name: 'Лаборатория', description: 'Анализы' } }
    let(:context) do
      { state: { assistant_id: entry.id, account_id: entry.account_id, captain_runtime: {}, source: 'benchmark', conversation: { id: 5 } },
        agent_graph: [{ id: entry.id, name: 'Администратор' }, lab_agent], agent_session: session, agent_request_id: 'audited',
        parts: [], agent_tasks: [], current_agent: "assistant_#{entry.id}" }
    end
    let(:planner) { Captain::Runtime::ToolWrapper.new(described_class.new, Captain::Runtime::RunContext.new(context)) }
    let(:rows) { Enterprise::AuditLog.where(associated_type: 'Account', associated_id: entry.account_id, action: 'captain_tool_execute') }
    let(:parts) { [{ fragment: 'Адрес клиники' }, { fragment: 'Цена анализа', executor: 'Лаборатория' }] }

    before do
      session.update_routing(actor_id: entry.id)
      entry.account.enable_features!('audit_logs')
    end

    it 'records a plan with its arguments, so that a report can show what was planned' do
      planner.call(mode: 'council', parts: parts)

      expect(rows.count).to eq(1)
      expect(rows.first.audited_changes).to include('tool_id' => 'plan_request', 'result_success' => true, 'source' => 'benchmark',
                                                    'current_agent' => "assistant_#{entry.id}", 'conversation_id' => 5)
      expect(rows.first.audited_changes['arguments']).to include(
        'mode' => 'council', 'parts' => [include('fragment' => 'Адрес клиники'), include('fragment' => 'Цена анализа', 'executor' => 'Лаборатория')]
      )
    end

    it 'records a refused plan too, and the link of a part under keys that the log does not hide' do
      planner.call(mode: 'clarify', clarification: 'Какой запрос?',
                   parts: [{ fragment: 'Да', link_part_id: '9', link_action: 'answer' }])

      changes = rows.first.audited_changes
      expect(changes).to include('result_success' => false)
      expect(changes['arguments']['clarification']).to eq('Какой запрос?')
      expect(changes['arguments']['parts']).to eq([{ 'fragment' => 'Да', 'open_part' => '9', 'reaction' => 'answer' }])
    end

    it 'is the arguments that the benchmark trace shows for a plan_request call' do
      planner.call(mode: 'council', parts: parts)
      event = Struct.new(:event_name, :tool_name, :payload).new('llm.tool.complete', 'plan_request', { 'result_success' => true })

      calls = Captain::Evals::RoutingBenchmark::ToolTrace.build(
        events: [event], audits: Captain::Evals::RoutingBenchmark::ToolTrace.audits_after(entry.account, 0)
      )

      expect(calls.sole).to include(tool: 'plan_request', success: true, audited: true, arguments: include('mode' => 'council'))
    end

    it 'writes nothing for an account without audit_logs' do
      entry.account.disable_features!('audit_logs')

      expect(JSON.parse(planner.call(mode: 'council', parts: parts))).to include('mode' => 'council')
      expect(rows.count).to eq(0)
    end

    it 'never fails the plan when the log cannot be written' do
      allow(Captain::ToolExecutionAuditService).to receive(:record).and_raise(StandardError, 'log down')

      expect(JSON.parse(planner.call(mode: 'council', parts: parts))).to include('mode' => 'council')
      expect(context[:part_plan_accepted]).to be(true)
    end
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock
