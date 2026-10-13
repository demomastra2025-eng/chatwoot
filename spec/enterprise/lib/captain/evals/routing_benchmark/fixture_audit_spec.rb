# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::FixtureAudit do
  let(:booking) do
    { model: 'appointment', kind: 'create', params: { status: 'scheduled', starts_at: '2026-10-15T12:00:00+05:00' } }
  end
  let(:workspace) do
    {
      agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.', tool_ids: %w[faq_lookup create_appointment] }],
      contacts: [{ key: 'patient', name: 'Дана Нурланова' }],
      resources: [{ key: 'doctor_a', name: 'Терапевт Абдрахманова Сауле' }],
      services: [{ key: 'consult', name: 'Консультация терапевта' }]
    }
  end

  def fixture_with(turns)
    Captain::Evals::RoutingBenchmark::Fixture.new(
      workspace: workspace,
      dialogues: [{ id: 'd1', contact: 'patient', turns: turns.map { |turn| turn.deep_merge(expect: { agent: 'Регистратор', council: false }) } }]
    )
  end

  def audit(*turns) = described_class.new('ws_a.yml' => fixture_with(turns))

  it 'is ready for the gate when every booking pins its start time and a request for a person expects a handoff' do
    result = audit({ customer: 'Запишите меня', expect: { operations: [booking] } },
                   { customer: 'позовите оператора', expect: { staff_handoff: true } })

    expect(result).to be_ok
    expect(result.result).to include(fixtures: 1, turns: 2, operations: { expected: 1, specific: 1 }, human_requests: { flagged: 1, unmarked: 0 }, gaps: [])
    expect(result.markdown).to include('Ready for the gate: yes.', 'Nothing is missing.')
  end

  it 'still reads the human_request flag of the older fixtures, and the symbolic start' do
    old = { model: 'appointment', kind: 'create', resource: 'doctor_a', service: 'consult', starts_at: '2026-10-15T12:00:00+05:00' }
    result = audit({ customer: 'Запишите меня', expect: { operations: [old] } },
                   { customer: 'позовите оператора', expect: { human_request: true } })

    expect(result).to be_ok
  end

  it 'refuses a fixture with an operation that pins no start: the strict loader names it before the audit sees it' do
    unpinned = { model: 'appointment', kind: 'create', params: { status: 'scheduled' } }

    expect { audit({ customer: 'Запишите меня', expect: { operations: [booking, unpinned] } }) }
      .to raise_error(Captain::Evals::RoutingBenchmark::Fixture::Invalid, /must pin params\.starts_at/)
  end

  it 'counts the pinned expectations of item a, and is not ready unless all of them are' do
    result = audit({ customer: 'Запишите меня', expect: { operations: [booking, booking.merge(kind: 'update')] } },
                   { customer: 'позовите оператора', expect: { staff_handoff: true } })

    expect(result.result[:operations]).to eq(expected: 2, specific: 2)
    expect(result.markdown).to include('Item a: 2 of 2 appointment expectations pin the start time.')
  end

  it 'asks no service or patient of a cancellation, and counts nothing for count: 0 or a deal' do
    cancel = { model: 'appointment', kind: 'update', params: { status: 'cancelled', starts_at: '2026-10-15T12:00:00+05:00' } }
    result = audit({ customer: 'отмените', expect: { operations: [cancel, booking.merge(count: 0), { model: 'deal', kind: 'create' }] } },
                   { customer: 'оператор керек', expect: { staff_handoff: true } })

    expect(result.result).to include(operations: { expected: 1, specific: 1 }, gaps: [])
  end

  it 'finds a request for a person that the fixture does not expect a handoff for, or expects none for' do
    result = audit({ customer: 'Запишите меня', expect: { operations: [booking] } },
                   { customer: 'менеджер керек маған', expect: {} },
                   { customer: 'соедините с администратором', expect: { staff_handoff: false } },
                   { customer: 'хочу поговорить с человеком', expect: { staff_handoff: true } },
                   { customer: 'мне нужен администратор', staff: { status: 'pending' }, expect: { staff_handoff: 'any' } })

    expect(result).not_to be_ok
    expect(result.result[:human_requests]).to eq(flagged: 1, unmarked: 3)
    expect(result.result[:gaps].map(&:problem)).to eq(['the customer asks for a person: add staff_handoff: true',
                                                       'the customer asks for a person, but the fixture expects no handoff',
                                                       'the customer asks for a person: add staff_handoff: true'])
  end

  it 'does not count a handoff of a turn where nobody asks for a person as a request for a person' do
    result = audit({ customer: 'Запишите меня', expect: { operations: [booking] } },
                   { customer: 'какой результат анализа', expect: { staff_handoff: true } })

    expect(result.result[:human_requests]).to eq(flagged: 0, unmarked: 0)
    expect(result).not_to be_ok
  end

  it 'is not ready when the fixtures hold no booking expectation or no request for a person at all' do
    expect(audit({ customer: 'Здравствуйте', expect: { staff_handoff: true } })).not_to be_ok
    expect(audit({ customer: 'Запишите меня', expect: { operations: [booking] } })).not_to be_ok
  end

  describe 'the calendar lint' do
    # 2026-10-15 is a Thursday (4): doctor_a works 09:00-18:00, doctor_b 14:00-18:00; doctor_a is booked 11:00-11:30 for the patient.
    let(:workspace) do
      super().merge(
        resources: [{ key: 'doctor_a', name: 'Терапевт Абдрахманова Сауле' }, { key: 'doctor_b', name: 'Кардиолог Омаров Тимур' }],
        services: [{ key: 'consult', name: 'Консультация терапевта' }, { key: 'long', name: 'Чистка', duration_min: 60 }],
        slots: [{ resource: 'doctor_a', weekday: 4, start_minute: 540, end_minute: 1080 }, { resource: 'doctor_b', weekday: 4, start_minute: 840, end_minute: 1080 }],
        appointments: [{ resource: 'doctor_a', service: 'consult', contact: 'patient', starts_at: '2026-10-15T11:00:00+05:00' }]
      )
    end
    let(:person) { { customer: 'позовите оператора', expect: { staff_handoff: true } } }

    def at(time, **extra)
      { model: 'appointment', kind: 'create', params: { status: 'scheduled', starts_at: "2026-10-15T#{time}:00+05:00" } }.merge(extra)
    end

    def messages(*operations)
      audit({ customer: 'Запишите меня', expect: { operations: operations } }, person).result[:gaps].map(&:problem)
    end

    it 'accepts a time that some doctor can take' do
      expect(messages(at('12:00'))).to be_empty
      expect(messages(at('15:00'))).to be_empty
    end

    it 'finds a time outside the work window of every doctor, and one that the only working doctor has taken' do
      expect(messages(at('19:00')).first).to include('2026-10-15T19:00:00+05:00 (30 min) is free for no doctor: outside the work window of 2')
      expect(messages(at('11:00')).first).to include('outside the work window of 1, taken for 1 (doctor_a: taken by seeded appointment of patient at 15.10 11:00)')
    end

    it 'finds a doctor named in the operation who is closed or busy then, with the reason' do
      expect(messages(at('12:00', resource: 'doctor_b')).first).to include('not possible for doctor_b: outside the work window (14:00-18:00)')
      expect(messages(at('11:00', resource: 'doctor_a')).first).to include('not possible for doctor_a: taken by seeded appointment of patient at 15.10 11:00')
    end

    it 'counts the duration of the service: the interval must fit the window, not only its start' do
      expect(messages(at('17:00', resource: 'doctor_a', service: 'long'))).to be_empty
      expect(messages(at('17:30', resource: 'doctor_a', service: 'long')).first).to include('(60 min) is not possible for doctor_a: outside the work window')
      expect(messages(at('17:30', resource: 'doctor_a', service: 'consult'))).to be_empty
    end

    it 'lets a move ignore the seeded appointment of the contact that it moves, and a cancellation is not checked' do
      move = at('11:00', resource: 'doctor_a', kind: 'update')
      cancel = at('23:00', kind: 'update', params: { status: 'cancelled', starts_at: '2026-10-15T23:00:00+05:00' })

      expect(messages(move)).to be_empty
      expect(messages(cancel)).to be_empty
    end

    it 'finds a booking on a slot that an earlier turn of the dialogue took, for the only doctor who can take it' do
      result = audit({ customer: 'Запишите меня', expect: { operations: [at('15:00', resource: 'doctor_b')] } },
                     { customer: 'ещё раз', expect: { operations: [at('15:00', resource: 'doctor_b')] } }, person)

      expect(result.result[:gaps].map(&:problem))
        .to eq(['2026-10-15T15:00:00+05:00 (30 min) is not possible for doctor_b: taken by an earlier booking of the dialogue'])
      expect(result.result[:gaps].map(&:turn)).to eq([2])
    end

    it 'finds a business turn whose slot is free for every doctor who works then, and passes one that is taken' do
      business = ->(text) { { customer: text, at: '2026-10-12T10:00:00+05:00', expect: { must_not_succeed: ['create_appointment'] } } }

      free = audit(business.call('запишите на четверг 15-го в 12:30'), person)
      taken = audit(business.call('запишите на четверг 15-го в 11:00'), person)
      unreadable = audit(business.call('запишите на 12:30'), person)

      expect(free.result[:gaps].map(&:problem)).to eq(['the customer asks for 2026-10-15T12:30:00+05:00, which is free for every doctor who works then: the business refusal could never happen'])
      expect(taken.result[:gaps]).to be_empty
      expect(unreadable.result[:gaps]).to be_empty
    end

    context 'without work rules' do
      let(:workspace) { super().except(:slots) }

      it 'says nothing about the calendar: the availability search would find no slot at all' do
        expect(messages(at('03:00'))).to be_empty
      end
    end
  end

  # The 160 dialogues of the v2 set: ROUTING_BENCHMARK_V2_FIXTURES='/root/work/bench/v2/*.yml'.
  describe 'the v2 set' do
    let(:paths) { Dir.glob(ENV.fetch('ROUTING_BENCHMARK_V2_FIXTURES')) }

    it 'is ready for the gate, and the calendar lint finds nothing in any of its 395 turns',
       skip: ENV['ROUTING_BENCHMARK_V2_FIXTURES'].blank? && 'set ROUTING_BENCHMARK_V2_FIXTURES to a glob of the 160 v2 fixture files' do
      audit = described_class.load(paths)

      expect(audit.result[:gaps].map(&:to_h)).to be_empty
      expect(audit.result).to include(fixtures: 160, turns: 395, operations: { expected: 105, specific: 105 })
      expect(audit.result[:human_requests]).to include(flagged: 7, unmarked: 0)
      expect(audit).to be_ok
    end
  end
end
