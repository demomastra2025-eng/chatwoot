# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::FixtureAudit do
  let(:booking) do
    { model: 'appointment', kind: 'create', resource: 'doctor_a', service: 'consult', starts_at: '2026-10-15T12:00:00+05:00', patient: 'patient' }
  end

  def fixture_with(turns)
    Captain::Evals::RoutingBenchmark::Fixture.new(
      workspace: {
        agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.', tool_ids: %w[faq_lookup create_appointment] }],
        contacts: [{ key: 'patient', name: 'Дана Нурланова' }],
        resources: [{ key: 'doctor_a', name: 'Терапевт Абдрахманова Сауле' }],
        services: [{ key: 'consult', name: 'Консультация терапевта' }]
      },
      dialogues: [{ id: 'd1', contact: 'patient', turns: turns.map { |turn| turn.deep_merge(expect: { agent: 'Регистратор', council: false }) } }]
    )
  end

  def audit(*turns) = described_class.new('ws_a.yml' => fixture_with(turns))

  it 'is ready for the gate when every booking names its doctor, time and service or patient and a request for a person is marked' do
    result = audit({ customer: 'Запишите меня', expect: { operations: [booking] } },
                   { customer: 'позовите оператора', expect: { human_request: true } })

    expect(result).to be_ok
    expect(result.result).to include(fixtures: 1, turns: 2, operations: { expected: 1, specific: 1 }, human_requests: { flagged: 1, unmarked: 0 }, gaps: [])
    expect(result.markdown).to include('Ready for the gate: yes.', 'Nothing is missing.')
  end

  it 'names the expectations that lack a doctor, a time or a service or patient' do
    result = audit({ customer: 'Запишите меня', expect: { operations: [booking.except(:resource), booking.except(:starts_at, :service, :patient),
                                                                        { model: 'appointment', kind: 'create', params: { status: 'scheduled' } }] } },
                   { customer: 'позовите оператора', expect: { human_request: true } })

    expect(result).not_to be_ok
    expect(result.result[:operations]).to eq(expected: 3, specific: 0)
    expect(result.result[:gaps].map(&:problem)).to eq(['create expectation lacks resource', 'create expectation lacks starts_at, service or patient',
                                                       'create expectation lacks resource, starts_at, service or patient'])
    expect(result.markdown).to include('- ws_a.yml d1 turn 1: create expectation lacks resource', 'Ready for the gate: no.')
  end

  it 'asks no service or patient of a cancellation, in the old form too, and counts nothing for count: 0 or a deal' do
    old_form = { model: 'appointment', kind: 'update', resource: 'doctor_a', starts_at: '2026-10-15T12:00:00+05:00', params: { status: 'cancelled' } }
    result = audit({ customer: 'отмените', expect: { operations: [old_form, booking.merge(count: 0), { model: 'deal', kind: 'create' }] } },
                   { customer: 'оператор керек', expect: { human_request: true } })

    expect(result.result).to include(operations: { expected: 1, specific: 1 }, gaps: [])
  end

  it 'finds a request for a person that the fixture does not mark, or marks false' do
    result = audit({ customer: 'Запишите меня', expect: { operations: [booking] } },
                   { customer: 'менеджер керек маған', expect: {} },
                   { customer: 'соедините с администратором', expect: { human_request: false } },
                   { customer: 'хочу поговорить с человеком', expect: { human_request: true } })

    expect(result).not_to be_ok
    expect(result.result[:human_requests]).to eq(flagged: 1, unmarked: 2)
    expect(result.result[:gaps].map(&:problem)).to eq(['the customer asks for a person: add human_request: true',
                                                       'human_request: false, but the customer asks for a person'])
  end

  it 'is not ready when the fixtures hold no booking expectation or no request for a person at all' do
    expect(audit({ customer: 'Здравствуйте', expect: { human_request: true } })).not_to be_ok
    expect(audit({ customer: 'Запишите меня', expect: { operations: [booking] } })).not_to be_ok
  end
end
