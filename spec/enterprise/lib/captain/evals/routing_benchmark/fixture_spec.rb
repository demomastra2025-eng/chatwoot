# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'

RSpec.describe Captain::Evals::RoutingBenchmark::Fixture do
  let(:customer_tools) { %w[get_my_contact update_my_contact list_my_deals list_my_appointments add_private_note create_appointment] }
  let(:data) do
    {
      workspace: {
        agents: [{ name: 'Запись к врачу', routing_description: 'Запись', instructions: 'Отвечай по-русски.',
                   tool_ids: customer_tools, model: 'openai/gpt-6-luna' }]
      },
      dialogues: [{ id: 'case_1', turns: [{ customer: 'Здравствуйте', expect: { agent: 'Запись к врачу', council: false } }] }]
    }
  end

  def with_tools(*tool_ids)
    data.deep_dup.tap { |copy| copy[:workspace][:agents].first[:tool_ids] = tool_ids }
  end

  describe '.safe_tool_ids' do
    it 'includes the customer-scoped and internal-note tools of the registry' do
      expect(described_class.safe_tool_ids).to include(
        *%w[get_my_contact update_my_contact list_my_deals list_my_appointments add_private_note add_contact_note
            create_appointment update_appointment cancel_appointment search_available_slots get_appointment
            create_deal update_deal faq_lookup handoff]
      )
    end

    it 'is every agent-scope registry tool except the refused ones, never a hand-kept list' do
      agent_ids = Captain::ToolRegistry.definitions
                                       .select { |definition| definition.supports_scope?(Captain::ToolAccess::SCOPE_AGENT) }.map(&:id)
      refused = Captain::Evals::RoutingBenchmark::SafeTools.refused

      expect(described_class.safe_tool_ids).to match_array(agent_ids - refused.keys)
      expect(refused.values.uniq).to include('external_service', 'assistant_scope_only')
    end

    it 'refuses tools that reach external systems and tools of the assistant scope' do
      expect(described_class.safe_tool_ids)
        .not_to include('web_search', 'web_scrape_url', 'search_linear_issues', 'translate_message',
                        'create_contact', 'get_appointment_provider_status', 'update_workspace_profile')
    end

    it 'agrees with the playground policy about external tools' do
      refused = Captain::Evals::RoutingBenchmark::SafeTools.refused

      expect(refused.slice(*Captain::Playground::ToolSupport::EXTERNAL_TOOLS).values.uniq).to eq(['external_service'])
    end
  end

  describe '.new' do
    it 'accepts account teams and named booking resources and rejects unknown names' do
      fixture = data.deep_dup
      fixture[:workspace][:teams] = [{ name: 'Бухгалтерия' }]
      fixture[:workspace][:resources] = [{ key: 'doctor', name: 'Врач Иванова' }]
      agent = fixture[:workspace][:agents].first
      agent[:handoff_team] = 'Бухгалтерия'
      agent[:booking_scope] = { resources: ['Врач Иванова'] }

      expect { described_class.new(fixture) }.not_to raise_error
      agent[:booking_scope] = { resources: ['Неизвестный врач'] }
      expect { described_class.new(fixture) }.to raise_error(described_class::Invalid, /unknown resources/)
    end

    it 'accepts the customer-scoped tools that the real fixtures use' do
      agent = described_class.new(data).workspace.fetch('agents').first

      expect(agent['tool_ids']).to include('get_my_contact', 'update_my_contact', 'list_my_deals', 'add_private_note')
    end

    it 'names the refused tools, including custom and MCP ids' do
      expect { described_class.new(with_tools('faq_lookup', 'web_search', 'mcp__crm__lookup')) }
        .to raise_error(described_class::Invalid, /Unsupported benchmark tool: web_search, mcp__crm__lookup/)
    end

    it 'rejects a registry tool of the assistant scope' do
      expect { described_class.new(with_tools('create_contact')) }
        .to raise_error(described_class::Invalid, /Unsupported benchmark tool: create_contact/)
    end
  end

  describe 'expectations of the release gate' do
    let(:booking_data) do
      data.deep_dup.tap do |copy|
        copy[:workspace].merge!(
          contacts: [{ key: 'caller', name: 'Дана Нурланова' }],
          resources: [{ key: 'doctor_a', name: 'Врач А' }, { key: 'doctor_b', name: 'Врач Б' }],
          services: [{ key: 'consult', name: 'Консультация' }]
        )
        copy[:dialogues].first[:contact] = 'caller'
      end
    end

    def with_expect(extra)
      booking_data.deep_dup.tap { |copy| copy[:dialogues].first[:turns].first[:expect].merge!(extra) }
    end

    def with_operation(**operation)
      with_expect(operations: [{ model: 'appointment', kind: 'create', params: { status: 'scheduled', starts_at: '2026-10-15T12:00:00+05:00' } }.merge(operation)])
    end

    it 'accepts the v2 form: the start pinned among the params' do
      expect { described_class.new(with_operation) }.not_to raise_error
    end

    it 'accepts the symbolic start of the older form instead of the one among the params' do
      expect { described_class.new(with_operation(params: { status: 'scheduled' }, starts_at: '2026-10-15T12:00:00+05:00')) }.not_to raise_error
    end

    it 'rejects an appointment operation that pins no start: it could not tell a wrong time from a right one' do
      expect { described_class.new(with_operation(params: { status: 'scheduled' })) }
        .to raise_error(described_class::Invalid, /must pin params\.starts_at/)
      expect { described_class.new(with_operation(params: { status: 'scheduled' }, count: 0)) }.not_to raise_error
    end

    it 'rejects two different starts for one operation' do
      expect { described_class.new(with_operation(starts_at: '2026-10-16T12:00:00+05:00')) }.to raise_error(described_class::Invalid, /differ/)
    end

    it 'rejects a move that does not pin the appointment it starts from: the new start alone cannot tell the right appointment from the wrong one' do
      expect { described_class.new(with_operation(kind: 'update')) }
        .to raise_error(described_class::Invalid, /A move \(kind update\) must pin previous_starts_at/)
      expect { described_class.new(with_operation(kind: 'update', previous_starts_at: '2026-10-13T15:00:00+05:00')) }.not_to raise_error
      expect { described_class.new(with_operation(kind: 'update', previous_starts_at: '2026-10-13T15:00:00')) }
        .to raise_error(described_class::Invalid, /previous_starts_at must carry an offset/)
    end

    it 'asks the old start of a move only: a cancellation pins its appointment by its start, a booking and a count of 0 have none' do
      cancel = { status: 'cancelled', starts_at: '2026-10-15T12:00:00+05:00' }

      expect { described_class.new(with_operation(kind: 'update', params: cancel)) }.not_to raise_error
      expect { described_class.new(with_operation(kind: 'cancel')) }.not_to raise_error
      expect { described_class.new(with_operation(kind: 'create')) }.not_to raise_error
      expect { described_class.new(with_operation(kind: 'update', params: { status: 'scheduled' }, count: 0)) }.not_to raise_error
    end

    it 'accepts the doctor, service, patient and count of an appointment, and the kinds update and cancel' do
      expect do
        described_class.new(with_operation(resource: 'doctor_a', service: 'consult', patient: 'caller', count: 2))
        described_class.new(with_operation(kind: 'update', previous_starts_at: '2026-10-13T15:00:00+05:00', previous_resource: 'doctor_b',
                                           patient_name: 'Арсен'))
        described_class.new(with_operation(kind: 'cancel', resource: 'doctor_a'))
      end.not_to raise_error
    end

    it 'rejects a doctor, service or patient that the workspace does not have' do
      expect { described_class.new(with_operation(resource: 'doctor_z')) }.to raise_error(described_class::Invalid, /Unknown resource in an operation: doctor_z/)
      expect { described_class.new(with_operation(service: 'surgery')) }.to raise_error(described_class::Invalid, /Unknown service/)
      expect { described_class.new(with_operation(patient: 'stranger')) }.to raise_error(described_class::Invalid, /Unknown patient/)
      expect { described_class.new(with_operation(previous_resource: 'doctor_z')) }.to raise_error(described_class::Invalid, /Unknown previous_resource/)
    end

    it 'rejects a start without an offset, a bad count and an unknown kind' do
      expect { described_class.new(with_operation(params: { status: 'scheduled', starts_at: '2026-10-15 12:00' })) }
        .to raise_error(described_class::Invalid, /must carry an offset/)
      expect { described_class.new(with_operation(params: { status: 'scheduled', starts_at: '2026-10-15T12:00:00' })) }
        .to raise_error(described_class::Invalid, /must carry an offset/)
      expect { described_class.new(with_operation(count: -1)) }.to raise_error(described_class::Invalid, /count/)
      expect { described_class.new(with_operation(count: 'two')) }.to raise_error(described_class::Invalid, /count/)
      expect { described_class.new(with_operation(kind: 'delete')) }.to raise_error(described_class::Invalid, /Unknown operation kind/)
    end

    it 'allows the symbolic keys and a cancellation only on an appointment' do
      expect { described_class.new(with_operation(model: 'deal', params: {}, resource: 'doctor_a')) }
        .to raise_error(described_class::Invalid, /belong to an appointment/)
      expect { described_class.new(with_operation(model: 'deal', params: {}, kind: 'cancel')) }
        .to raise_error(described_class::Invalid, /Only an appointment can be cancelled/)
      expect { described_class.new(with_operation(model: 'deal', params: {}, kind: 'create')) }.not_to raise_error
    end

    it 'accepts the human_request flag as true or false only' do
      expect { described_class.new(with_expect(human_request: true)) }.not_to raise_error
      expect { described_class.new(with_expect(human_request: false)) }.not_to raise_error
      expect { described_class.new(with_expect(human_request: 'yes')) }.to raise_error(described_class::Invalid, /human_request/)
    end

    it 'rejects the ledger_tool of the operation: the ledger holds no tool name' do
      expect { described_class.new(with_operation(ledger_tool: 'create_appointment')) }.to raise_error(described_class::Invalid, /ledger_tool/)
    end

    describe 'the v2 keys' do
      it 'accepts transfers (the integer 0 or 1), staff_handoff (true, false, any) and reply_language (a language code: ru, kk, en ...)' do
        expect { described_class.new(with_expect(transfers: 0, staff_handoff: false, reply_language: 'ru')) }.not_to raise_error
        expect { described_class.new(with_expect(transfers: 1, staff_handoff: 'any', reply_language: 'kk')) }.not_to raise_error
        expect { described_class.new(with_expect(staff_handoff: true)) }.not_to raise_error
      end

      it 'accepts the reply in any language, written as its code: a patient is answered in the language they write in' do
        %w[en tr de uk ar fil].each do |language|
          expect { described_class.new(with_expect(reply_language: language)) }.not_to raise_error, language
        end
      end

      it 'rejects a transfers count that is not 0 or 1, and a boolean' do
        [2, -1, true, false, '1', 0.0].each do |value|
          expect { described_class.new(with_expect(transfers: value)) }.to raise_error(described_class::Invalid, /transfers/), value.inspect
        end
      end

      it 'rejects a staff_handoff and a reply_language outside the schema' do
        ['yes', nil, 1].each { |value| expect { described_class.new(with_expect(staff_handoff: value)) }.to raise_error(described_class::Invalid, /staff_handoff/) }
        ['RU', 'russian', 'r', 'ru-RU', '', nil, 1, ['ru']].each do |value|
          expect { described_class.new(with_expect(reply_language: value)) }.to raise_error(described_class::Invalid, /reply_language/), value.inspect
        end
      end

      it 'accepts a turn rubric that is a string, and rejects another' do
        with_rubric = ->(rubric) { booking_data.deep_dup.tap { |copy| copy[:dialogues].first[:turns].first[:rubric] = rubric } }

        expect { described_class.new(with_rubric.call('Один точный вопрос.')) }.not_to raise_error
        expect { described_class.new(with_rubric.call(['a'])) }.to raise_error(described_class::Invalid, /turn\.rubric/)
        expect { described_class.new(with_rubric.call('  ')) }.to raise_error(described_class::Invalid, /turn\.rubric/)
      end

      it 'accepts must_not_succeed of mutation tools only' do
        expect { described_class.new(with_expect(must_not_succeed: %w[create_appointment update_appointment])) }.not_to raise_error
        expect { described_class.new(with_expect(must_not_succeed: ['faq_lookup'])) }.to raise_error(described_class::Invalid, /must_not_succeed/)
        expect { described_class.new(with_expect(must_not_succeed: 'create_appointment')) }.to raise_error(described_class::Invalid, /must_not_succeed/)
      end

      it 'accepts the listed hard-zero counters, the new one included, and rejects another' do
        expect { described_class.new(with_expect(forbidden: %w[false_success_claim false_handoff_claim])) }.not_to raise_error
        expect { described_class.new(with_expect(forbidden: ['made_up'])) }.to raise_error(described_class::Invalid, /Unknown hard-zero counter/)
      end
    end

    describe 'acts' do
      let(:acting_data) do
        booking_data.deep_dup.tap do |copy|
          copy[:workspace][:agents] << { name: 'Диагностика', routing_description: 'УЗИ', instructions: 'Отвечай.', tool_ids: %w[faq_lookup create_appointment] }
          copy[:workspace][:agents].first[:tool_ids] = %w[faq_lookup update_appointment]
        end
      end

      def with_acts(acts)
        acting_data.deep_dup.tap { |copy| copy[:dialogues].first[:turns].first[:expect][:acts] = acts }
      end

      it 'accepts a mutation tool that the named agent has' do
        expect { described_class.new(with_acts([{ tool: 'create_appointment', agent: 'Диагностика' }])) }.not_to raise_error
      end

      it 'rejects an unknown agent, a tool the agent does not have, a tool that is no mutation and an unknown key' do
        expect { described_class.new(with_acts([{ tool: 'create_appointment', agent: 'Никто' }])) }.to raise_error(described_class::Invalid, /act agent is unknown/)
        expect { described_class.new(with_acts([{ tool: 'create_appointment', agent: 'Запись к врачу' }])) }.to raise_error(described_class::Invalid, /not a tool of/)
        expect { described_class.new(with_acts([{ tool: 'faq_lookup', agent: 'Запись к врачу' }])) }.to raise_error(described_class::Invalid, /not a mutation tool/)
        expect { described_class.new(with_acts([{ tool: 'create_appointment', agent: 'Диагностика', note: 'x' }])) }
          .to raise_error(described_class::Invalid, /Unknown key in act/)
        expect { described_class.new(with_acts('create_appointment')) }.to raise_error(described_class::Invalid, /acts must be an array/)
      end
    end

    describe 'tool names' do
      it 'rejects a name that matches no tool: a typo in must_not_call would silently disable the check of the tool it was meant for' do
        expect { described_class.new(with_expect(must_not_call: %w[create_appointment cancel_apointment])) }
          .to raise_error(described_class::Invalid, /must_not_call names the unknown tool "cancel_apointment"/)
        expect { described_class.new(with_expect(must_call: ['create_apointment'])) }
          .to raise_error(described_class::Invalid, /must_call names the unknown tool "create_apointment"/)
      end

      it 'wants a must_call tool that some agent of the workspace has, and takes any tool of the benchmark in must_not_call' do
        expect { described_class.new(with_expect(must_call: ['update_appointment'])) }
          .to raise_error(described_class::Invalid, /must_call names the unknown tool "update_appointment": no agent of the workspace has it/)
        expect { described_class.new(with_expect(must_not_call: %w[update_appointment cancel_appointment faq_lookup])) }.not_to raise_error
      end

      it 'takes the runtime tools plan_request and handoff, which are in no list of an agent' do
        expect { described_class.new(with_expect(must_not_call: %w[plan_request handoff])) }.not_to raise_error
        expect { described_class.new(with_expect(must_call: %w[create_appointment handoff plan_request])) }.not_to raise_error
      end

      it 'rejects a transfer tool in must_call and must_not_call: its name is account-specific' do
        %w[handoff_to_assistant_7 transfer_to_agent_4].each do |name|
          expect { described_class.new(with_expect(must_call: [name])) }.to raise_error(described_class::Invalid, /transfer tool/), name
          expect { described_class.new(with_expect(must_not_call: [name])) }.to raise_error(described_class::Invalid, /transfer tool/), name
        end
      end

      it 'rejects handoff in the must_call of a council turn, and accepts it outside a council' do
        expect { described_class.new(with_expect(council: true, must_call: ['handoff'])) }.to raise_error(described_class::Invalid, /council/)
        expect { described_class.new(with_expect(council: true, must_not_call: ['handoff'])) }.not_to raise_error
        expect { described_class.new(with_expect(council: false, must_call: ['handoff'])) }.not_to raise_error
      end

      it "takes council true, false or 'any' (a request with two right routes), and nothing else" do
        [true, false, 'any'].each { |value| expect { described_class.new(with_expect(council: value)) }.not_to raise_error, value.inspect }
        ['maybe', nil, 1].each do |value|
          expect { described_class.new(with_expect(council: value)) }
            .to raise_error(described_class::Invalid, /council must be true, false or 'any'/), value.inspect
        end
      end
    end

    describe 'the doctors of a service' do
    def with_services(services)
      data.deep_dup.tap do |copy|
        copy[:workspace].merge!(resources: [{ key: 'doctor_a', name: 'Терапевт Иванов' }, { key: 'doctor_b', name: 'Кардиолог Петров' }], services: services)
      end
    end

    it 'takes a list of the resources that perform the service, and none' do
      listed = { key: 'consult', name: 'Консультация', resources: %w[doctor_a] }
      open = { key: 'checkup', name: 'Чек-ап' }

      expect { described_class.new(with_services([listed, open])) }.not_to raise_error
    end

    it 'refuses an unknown resource, an empty list, a repeated resource and a list that is no array' do
      [{ resources: %w[doctor_x] }, { resources: [] }, { resources: %w[doctor_a doctor_a] }, { resources: 'doctor_a' }].each do |extra|
        service = { key: 'consult', name: 'Консультация' }.merge(extra)

        expect { described_class.new(with_services([service])) }.to raise_error(described_class::Invalid, /services\.consult\.resources/), extra.inspect
      end
    end
  end

  describe 'unknown keys' do
      it 'rejects a typo at the level of the fixture, the workspace, the agent, the dialogue, the turn, the expectation and the operation' do
        misspelled = {
          'fixture' => ->(copy) { copy[:extra] = 1 },
          'workspace' => ->(copy) { copy[:workspace][:appointmens] = [] },
          'agent' => ->(copy) { copy[:workspace][:agents].first[:tools] = [] },
          'dialogue' => ->(copy) { copy[:dialogues].first[:rubrik] = 'x' },
          'turn' => ->(copy) { copy[:dialogues].first[:turns].first[:delay] = 3 },
          'turn.expect' => ->(copy) { copy[:dialogues].first[:turns].first[:expect][:must_not_cal] = [] },
          'turn.staff' => ->(copy) { copy[:dialogues].first[:turns].first[:staff] = { status: 'pending', who: 'x' } },
          'operation' => lambda { |copy|
            copy[:dialogues].first[:turns].first[:expect][:operations] =
              [{ model: 'deal', kind: 'create', params: {}, titel: 'x' }]
          }
        }

        misspelled.each do |where, edit|
          copy = booking_data.deep_dup
          edit.call(copy)

          expect { described_class.new(copy) }.to raise_error(described_class::Invalid, /Unknown key in #{Regexp.escape(where)}/), where
        end
      end

      it 'rejects a typo in a row of the workspace as well: a channel, knowledge, contact, doctor, service, slot, appointment or deal' do
        rows = {
          'channels' => { key: 'api', entry_agent: 'Запись к врачу', entry: 'x' },
          'knowledge' => { question: 'Где?', answer: 'Здесь.', agnet: 'Запись к врачу' },
          'contacts' => { key: 'other', name: 'Арсен', phone: '+7 700 000 00 00' },
          'resources' => { key: 'doctor_c', name: 'Врач В', timezon: 'Asia/Almaty' },
          'services' => { key: 'xray', name: 'Рентген', price: 5000 },
          'slots' => { resource: 'doctor_a', weekday: 1, start_minute: 540, end_minute: 600, day: 'Пн' },
          'appointments' => { resource: 'doctor_a', contact: 'caller', starts_at: '2026-10-16T09:30:00+05:00', status: 'scheduled' },
          'deals' => { title: 'Программа', stage: 'new' }
        }

        rows.each do |section, row|
          copy = booking_data.deep_dup
          copy[:workspace][section.to_sym] = Array(copy[:workspace][section.to_sym]) + [row]

          expect { described_class.new(copy) }.to raise_error(described_class::Invalid, /Unknown key in workspace\.#{section}/), section
        end
      end

      it 'rejects a row of the workspace that is not a mapping' do
        copy = booking_data.deep_dup
        copy[:workspace][:resources] = ['doctor_a']

        expect { described_class.new(copy) }.to raise_error(described_class::Invalid, /resource must be a mapping/)
      end

      it 'rejects agent and agents together, and a list of one agent (write agent: for one)' do
        expectation = ->(extra, keep_agent: false) do
          booking_data.deep_dup.tap do |copy|
            turn_expect = copy[:dialogues].first[:turns].first[:expect]
            turn_expect.delete(:agent) unless keep_agent
            turn_expect.merge!(extra)
          end
        end

        expect { described_class.new(expectation.call({ agents: ['Запись к врачу'] })) }.to raise_error(described_class::Invalid, /at least two agents/)
        expect { described_class.new(expectation.call({ agents: ['Запись к врачу', 'Запись к врачу'] }, keep_agent: true)) }
          .to raise_error(described_class::Invalid, /either agent or agents/)
      end
    end

    describe 'the return of a staff handoff' do
      let(:two_turns) do
        booking_data.deep_dup.tap do |copy|
          turn = copy[:dialogues].first[:turns].first
          turn[:expect][:staff_handoff] = true
          copy[:dialogues].first[:turns] = [turn, { customer: 'Спасибо', expect: { agent: 'Запись к врачу', council: false } }]
        end
      end

      it 'wants staff: {status: pending} on the turn that follows a turn with staff_handoff true or any' do
        expect { described_class.new(two_turns) }.to raise_error(described_class::Invalid, /case_1 turn 2 follows a staff handoff/)

        two_turns[:dialogues].first[:turns].first[:expect][:staff_handoff] = 'any'
        expect { described_class.new(two_turns) }.to raise_error(described_class::Invalid, /turn 2 follows a staff handoff/)

        two_turns[:dialogues].first[:turns].last[:staff] = { status: 'pending' }
        expect { described_class.new(two_turns) }.not_to raise_error
      end

      it 'does not ask it after a turn without a handoff, and takes an open conversation for no return' do
        two_turns[:dialogues].first[:turns].first[:expect][:staff_handoff] = false
        expect { described_class.new(two_turns) }.not_to raise_error

        two_turns[:dialogues].first[:turns].first[:expect][:staff_handoff] = true
        two_turns[:dialogues].first[:turns].last[:staff] = { status: 'open' }
        expect { described_class.new(two_turns) }.to raise_error(described_class::Invalid, /pending/)
      end
    end
  end

  describe '.load' do
    let(:yaml) do
      <<~YAML
        workspace:
          agents:
            - name: Администратор
              routing_description: "беру: приветствие, адреса / не беру: запись"
              instructions: |-
                Ты администратор клиники «Самал».
                Язык ответа — язык просьбы (русский или казахский).
              tool_ids: [faq_lookup, handoff]
              model: openai/gpt-6-luna
            - name: Запись к врачу
              routing_description: "беру: запись взрослых / не беру: детей"
              instructions: Запись, перенос и отмена.
              tool_ids: [search_available_slots, list_my_appointments, create_appointment, update_appointment, get_my_contact, update_my_contact]
              model: openai/gpt-6-luna
          channels:
            - {key: api, entry_agent: Администратор}
          knowledge:
            - {agent: Администратор, question: "Где вы находитесь?", answer: "Центр и Сайран."}
            - {question: "Есть парковка?", answer: "Да, бесплатная."}
          contacts:
            - {key: n_dana, name: Дана Нурланова}
          resources:
            - {key: ginekolog, name: Гинеколог, timezone: Asia/Almaty}
          services:
            - {key: consult, name: Консультация, duration_min: 30, base_price: 6000}
          slots:
            - {resource: ginekolog, weekday: 5, start_minute: 540, end_minute: 1020}
          appointments:
            - {resource: ginekolog, service: consult, contact: n_dana, starts_at: '2026-10-16T09:30:00+05:00'}
          deals:
            - title: Годовая программа  # открытая
        dialogues:
          - id: family_booking_04
            channel: api
            contact: n_dana
            rubric: "Запись переносится, для мамы спрашиваются ФИО."
            turns:
              - customer: "перенесите мою запись и маму запишите"
                at: '2026-10-12T14:10:00+05:00'
                delay_seconds: 0
                rubric: "Перенос выполнен в этом же ходе."
                expect:
                  agents: [Запись к врачу, Администратор]
                  council: true
                  transfers: 0
                  must_call: [update_appointment]
                  must_not_call: [create_appointment, cancel_appointment, handoff]
                  operations:
                    - {model: appointment, kind: update, params: {status: scheduled, starts_at: '2026-10-16T10:00:00+05:00'}, resource: ginekolog, service: consult, previous_starts_at: '2026-10-16T09:30:00+05:00'}
                  acts:
                    - {tool: update_appointment, agent: Запись к врачу}
                  staff_handoff: true
                  reply_language: ru
                  forbidden: [false_success_claim, duplicate_operation, wrong_patient, internal_text_leak, wrong_language]
              - customer: "да, переносите"
                at: '2026-10-12T14:12:00+05:00'
                delay_seconds: 0
                staff: {status: pending}
                rubric: "Перенос уже выполнен."
                expect:
                  agent: Запись к врачу
                  council: false
                  must_call: []
                  must_not_call: [update_appointment]
                  operations: []
                  staff_handoff: false
                  reply_language: ru
                  forbidden: [false_success_claim]
      YAML
    end

    def load_text(text)
      Tempfile.create(['routing-fixture', '.yml']) do |file|
        file.write(text)
        file.flush
        yield described_class.load(file.path)
      end
    end

    it 'loads a file that uses every key of the v2 fixtures' do
      load_text(yaml) do |fixture|
        expect(fixture.dialogues.pluck('id')).to eq(['family_booking_04'])
        expect(fixture.workspace.keys).to match_array(%w[agents channels knowledge contacts resources services slots appointments deals])
        expect(fixture.dialogues.first.dig('turns', 0, 'expect', 'agents')).to eq(['Запись к врачу', 'Администратор'])
        expect(fixture.dialogues.first.dig('turns', 0, 'expect', 'operations', 0, 'params', 'starts_at')).to eq('2026-10-16T10:00:00+05:00')
      end
    end

    it 'reports an unquoted timestamp as invalid YAML' do
      unquoted = yaml.sub("'2026-10-12T14:10:00+05:00'", '2026-10-12T14:10:00+05:00')

      expect { load_text(unquoted) { |_fixture| nil } }.to raise_error(described_class::Invalid, /Invalid YAML/)
    end

    it 'reports an unquoted start among the params as invalid YAML too' do
      unquoted = yaml.sub("starts_at: '2026-10-16T10:00:00+05:00'", 'starts_at: 2026-10-16T10:00:00+05:00')

      expect { load_text(unquoted) { |_fixture| nil } }.to raise_error(described_class::Invalid, /Invalid YAML/)
    end

    it 'refuses the ledger_tool and a handoff_to_ name in a file' do
      expect { load_text(yaml.sub('kind: update, params', 'kind: update, ledger_tool: update_appointment, params')) { |_fixture| nil } }
        .to raise_error(described_class::Invalid, /ledger_tool/)
      expect { load_text(yaml.sub('must_call: [update_appointment]', 'must_call: [handoff_to_assistant_7]')) { |_fixture| nil } }
        .to raise_error(described_class::Invalid, /transfer tool/)
    end

    it 'loads every file matched by ROUTING_BENCHMARK_FIXTURES when the variable is set',
       skip: ENV['ROUTING_BENCHMARK_FIXTURES'].blank? && 'set ROUTING_BENCHMARK_FIXTURES to a glob of fixture files' do
      failures = Dir.glob(ENV.fetch('ROUTING_BENCHMARK_FIXTURES')).filter_map do |path|
        described_class.load(path)
        nil
      rescue described_class::Invalid => e
        "#{path}: #{e.message}"
      end

      expect(failures).to be_empty
    end

    # The 160 dialogues of the v2 set (390 turns), loaded by the strict loader: ROUTING_BENCHMARK_V2_FIXTURES='/root/work/bench/v2/*.yml'.
    it 'loads ALL the v2 fixtures strictly when ROUTING_BENCHMARK_V2_FIXTURES is set',
       skip: ENV['ROUTING_BENCHMARK_V2_FIXTURES'].blank? && 'set ROUTING_BENCHMARK_V2_FIXTURES to a glob of the 160 v2 fixture files' do
      paths = Dir.glob(ENV.fetch('ROUTING_BENCHMARK_V2_FIXTURES')).reject { |path| File.basename(path) == 'CHANGES.md' }
      failures = []
      dialogues = turns = 0
      paths.each do |path|
        fixture = described_class.load(path)
        dialogues += fixture.dialogues.size
        turns += fixture.dialogues.sum { |dialogue| dialogue['turns'].size }
      rescue described_class::Invalid => e
        failures << "#{File.basename(path)}: #{e.message}"
      end

      expect(failures).to be_empty
      expect([paths.size, dialogues, turns]).to eq([160, 160, 390])
    end

    # The pins that make gate item a real: a move names the appointment it starts from, a booking names its service and (where the plan
    # has exactly one doctor for it) its doctor, a booking for a relative names the relative.
    it 'pins the old start of every move, the service and the doctor of every booking and the patient of every relative in the v2 set',
       skip: ENV['ROUTING_BENCHMARK_V2_FIXTURES'].blank? && 'set ROUTING_BENCHMARK_V2_FIXTURES to a glob of the 160 v2 fixture files' do
      paths = Dir.glob(ENV.fetch('ROUTING_BENCHMARK_V2_FIXTURES')).reject { |path| File.basename(path) == 'CHANGES.md' }
      turns = paths.flat_map { |path| described_class.load(path).dialogues.flat_map { |dialogue| dialogue['turns'] } }
      operations = turns.flat_map { |turn| Array(turn.dig('expect', 'operations')) }.select { |operation| operation['model'] == 'appointment' }
      kind_of = ->(operation) { Captain::Evals::RoutingBenchmark::OperationCheck.kind_of(operation) }
      moves = operations.select { |operation| kind_of.call(operation) == 'update' }
      bookings = operations.select { |operation| kind_of.call(operation) == 'create' }

      expect([operations.size, moves.size, bookings.size]).to eq([105, 22, 80])
      expect(moves).to all(include('previous_starts_at' => match(/\A2026-10-\d\dT\d\d:\d\d:00\+05:00\z/)))
      expect(bookings).to all(include('service' => be_present))
      expect(bookings.count { |operation| operation['resource'].present? }).to eq(76)
      expect(bookings.count { |operation| operation['patient_name'].present? }).to eq(23)
      expect(operations.count { |operation| Captain::Evals::RoutingBenchmark::Gate.specific?(operation) }).to eq(105)
    end
  end
end
