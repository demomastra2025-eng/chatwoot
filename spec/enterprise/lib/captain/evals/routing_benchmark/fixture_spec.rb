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
      with_expect(operations: [{ model: 'appointment', kind: 'create', params: { status: 'scheduled' } }.merge(operation)])
    end

    it 'keeps an old operation expectation valid' do
      expect { described_class.new(with_operation) }.not_to raise_error
    end

    it 'accepts the doctor, service, start, patient and count of an appointment, and the kinds update and cancel' do
      expect do
        described_class.new(with_operation(resource: 'doctor_a', service: 'consult', starts_at: '2026-10-15T12:00:00+05:00', patient: 'caller', count: 2))
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
      expect { described_class.new(with_operation(starts_at: '2026-10-15 12:00')) }.to raise_error(described_class::Invalid, /Invalid fixture value/)
      expect { described_class.new(with_operation(count: -1)) }.to raise_error(described_class::Invalid, /count/)
      expect { described_class.new(with_operation(count: 'two')) }.to raise_error(described_class::Invalid, /count/)
      expect { described_class.new(with_operation(kind: 'delete')) }.to raise_error(described_class::Invalid, /Unknown operation kind/)
    end

    it 'allows the symbolic keys and a cancellation only on an appointment' do
      expect { described_class.new(with_operation(model: 'deal', params: {}, resource: 'doctor_a')) }
        .to raise_error(described_class::Invalid, /belong to an appointment/)
      expect { described_class.new(with_operation(model: 'deal', params: {}, kind: 'cancel')) }
        .to raise_error(described_class::Invalid, /Only an appointment can be cancelled/)
    end

    it 'accepts the human_request flag as true or false only' do
      expect { described_class.new(with_expect(human_request: true)) }.not_to raise_error
      expect { described_class.new(with_expect(human_request: false)) }.not_to raise_error
      expect { described_class.new(with_expect(human_request: 'yes')) }.to raise_error(described_class::Invalid, /human_request/)
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
                staff: {status: pending}
                expect:
                  agents: [Запись к врачу, Администратор]
                  council: true
                  must_call: []
                  must_not_call: [create_appointment, cancel_appointment, update_my_contact]
                  operations:
                    - {model: appointment, kind: update, ledger_tool: update_appointment, params: {status: scheduled}}
                  forbidden: [false_success_claim, duplicate_operation, wrong_patient, internal_text_leak, wrong_language]
      YAML
    end

    def load_text(text)
      Tempfile.create(['routing-fixture', '.yml']) do |file|
        file.write(text)
        file.flush
        yield described_class.load(file.path)
      end
    end

    it 'loads a file that uses every key of the isolated fixtures' do
      load_text(yaml) do |fixture|
        expect(fixture.dialogues.pluck('id')).to eq(['family_booking_04'])
        expect(fixture.workspace.keys).to match_array(%w[agents channels knowledge contacts resources services slots appointments deals])
        expect(fixture.dialogues.first.dig('turns', 0, 'expect', 'agents')).to eq(['Запись к врачу', 'Администратор'])
      end
    end

    it 'reports an unquoted timestamp as invalid YAML' do
      unquoted = yaml.sub("'2026-10-12T14:10:00+05:00'", '2026-10-12T14:10:00+05:00')

      expect { load_text(unquoted) { |_fixture| nil } }.to raise_error(described_class::Invalid, /Invalid YAML/)
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
  end
end
