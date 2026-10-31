require 'rails_helper'

# The booking search answers the whole chain of a booking question in one call: the services of the request, their specialists and the
# nearest free times. It has no matching, availability or rule of its own, so the specs compare its answer with the answers of the
# three tools it arranges and check the limits that keep the answer small. All data is synthetic.
RSpec.describe Captain::Tools::Account::SearchBookingOptionsService do
  include ActiveSupport::Testing::TimeHelpers

  # Tuesday, 21 April 2026, 12:00 in Almaty; the specialists receive Monday to Friday 09:00-18:00 every 30 minutes.
  let(:now) { Time.zone.parse('2026-04-21 12:00:00 +0500') }
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account, timezone: 'Asia/Almaty') }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:run_context) { Captain::Runtime::RunContext.new({ state: { conversation: { id: conversation.id, display_id: conversation.display_id } } }) }
  let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: run_context) }

  around { |example| travel_to(now) { example.run } }

  before do
    account.enable_features!('scheduling')
    stub_embedder(account, 'терапевт' => unit_vector(0), 'узи' => unit_vector(4), 'ЭКГ' => unit_vector(6), 'рентген' => unit_vector(8),
                           'нет такой' => unit_vector(20))
  end

  # The call of the patient agent: the adapter of the registry builds the tool with the patient scope of the conversation.
  def call(tool_id, **arguments)
    Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: tool_id).execute(tool_context, **arguments)
  end

  def doctor(name, **attributes)
    create(:scheduling_resource, account: account, name: name, timezone: 'Asia/Almaty', **attributes).tap do |resource|
      (1..5).each do |weekday|
        create(:scheduling_work_rule, resource: resource, account: account, weekday: weekday, start_minute: 9 * 60, end_minute: 18 * 60)
      end
    end
  end

  def service(name, axis, similarity = 0.95, **attributes)
    create(:scheduling_service, account: account, name: name, **attributes).tap { |record| index_service(record, vector_at(axis, similarity)) }
  end

  def link(service, resource, price = service.base_price)
    create(:scheduling_service_price, account: account, service: service, resource: resource, price: price)
  end

  def search(**arguments)
    JSON.parse(call('search_booking_options', **arguments))
  end

  describe 'one request' do
    let!(:aigerim) { doctor('Асланова Айгерим') }
    let!(:dinara) { doctor('Бекова Динара') }
    let!(:visit) { service('Консультация терапевта', 0, base_price: 15_000, duration_min: 30) }

    before do
      link(visit, aigerim)
      link(visit, dinara, 18_000)
    end

    it 'gives the candidates of the service search, then the free times of the specialists of the best candidate' do
      answer = search(services: ['терапевт'], from: '2026-04-22', to: '2026-04-23')
      result = answer['results'].first

      expect(result).to include('query' => 'терапевт', 'status' => 'found', 'slots_service_id' => visit.id)
      expect(result['services']).to eq(
        [{ 'id' => visit.id, 'name' => 'Консультация терапевта', 'price' => 15_000, 'duration_min' => 30,
           'doctors' => ["#{aigerim.id} Асланова Айгерим", "#{dinara.id} Бекова Динара (18000)"], 'score' => 0.95 }]
      )
      expect(result['days'].pluck('resource_id', 'name', 'date')).to contain_exactly(
        [aigerim.id, 'Асланова Айгерим', '2026-04-22'], [dinara.id, 'Бекова Динара', '2026-04-22']
      )
      expect(result['days'].first['times']).to eq(%w[09:00 11:00 13:00 15:00 17:30])
    end

    it 'is the answer of search_available_slots for the same service and range, not another availability' do
      direct = JSON.parse(call('search_available_slots', from: '2026-04-22', to: '2026-04-24', service_id: visit.id, limit: 31))
      answer = search(services: ['терапевт'], from: '2026-04-22', to: '2026-04-24')

      expect(answer['results'].first['days']).to eq(direct['days'])
      expect(answer['results'].first).to include('duration_min' => direct['duration_min'], 'total' => direct['total'])
    end

    it 'offers no time after the last booking time of the clinic' do
      account.update!(scheduling_last_booking_time: '11:00')

      times = search(services: ['терапевт'], from: '2026-04-22', to: '2026-04-23')['results'].first['days'].flat_map { |day| day['times'] }

      expect(times).not_to be_empty
      expect(times).to all(be <= '11:00')
    end

    it 'never offers a time that has passed: a range that began earlier starts now' do
      days = search(services: ['терапевт'], from: '2026-04-21', to: '2026-04-22')['results'].first['days']

      expect(days.pluck('date')).to all(eq('2026-04-21'))
      expect(days.flat_map { |day| day['times'] }).to all(be >= '12:00')
    end

    it 'searches the next 7 days from now when the call names no range, and says so' do
      answer = search(services: ['терапевт'])

      expect(answer['range']).to eq('from' => '2026-04-21T12:00:00+05:00', 'to' => '2026-04-28T12:00:00+05:00')
      expect(answer['results'].first['days'].pluck('date').uniq).to eq(%w[2026-04-21 2026-04-22])
      expect(answer['results'].first['more_days']).to eq(8)
    end

    it 'says once, for the whole answer, that the listed times are a sample, and not in every block' do
      answer = search(services: %w[терапевт], doctor: 'Асланова', from: '2026-04-22', to: '2026-04-23')

      expect(answer['times_note']).to eq(Captain::Tools::Agent::SlotsPayload::TIMES_NOTE)
      expect(answer['results'].first).not_to have_key('times_note')
      expect(answer['specialists']).not_to have_key('times_note')
    end

    it 'is one compact JSON line' do
      expect(call('search_booking_options', services: ['терапевт'])).not_to include("\n")
    end

    it 'tells the nearest free days of the following week when the range has none, as search_available_slots does' do
      answer = search(services: ['терапевт'], from: '2026-04-25', to: '2026-04-26')

      expect(answer['results'].first).to include('total' => 0, 'days' => [])
      expect(answer['results'].first['next_available'].first).to include('date' => '2026-04-27')
    end
  end

  describe 'several services' do
    let!(:aigerim) { doctor('Асланова Айгерим') }
    let!(:ultrasound_doctor) { doctor('Сеитова Алия') }
    let!(:visit) { service('Консультация терапевта', 0, base_price: 15_000) }
    let!(:ultrasound) { service('УЗИ щитовидной железы', 4, base_price: 9000, duration_min: 20) }

    before do
      link(visit, aigerim)
      link(ultrasound, ultrasound_doctor)
    end

    it 'searches the mentions in one request and gives the free times of each service with its own specialists' do
      embedder = stub_embedder(account, 'терапевт' => unit_vector(0), 'узи' => unit_vector(4))

      results = search(services: %w[терапевт узи], from: '2026-04-22', to: '2026-04-23')['results']

      expect(embedder).to have_received(:get_embeddings).once
      expect(results.pluck('slots_service_id')).to eq([visit.id, ultrasound.id])
      expect(results.map { |result| result['days'].pluck('name') }).to eq([['Асланова Айгерим'], ['Сеитова Алия']])
    end

    it 'searches the free times of a service once when two mentions found it' do
      stub_embedder(account, 'терапевт' => unit_vector(0), 'врач' => unit_vector(0))
      allow(Scheduling::CompleteSlotSearchService).to receive(:new).and_call_original

      results = search(services: %w[терапевт врач], from: '2026-04-22', to: '2026-04-23')['results']

      expect(results.pluck('slots_service_id')).to eq([visit.id, visit.id])
      expect(results.first['days']).to eq(results.last['days'])
      expect(Scheduling::CompleteSlotSearchService).to have_received(:new).once
    end

    it 'says that a mention is not in the catalog and searches no time for it' do
      results = search(services: ['терапевт', 'нет такой'])['results']

      expect(results.last).to eq('query' => 'нет такой', 'status' => 'not_in_catalog')
    end

    it 'gives free times to the first three services only; the others are listed without them' do
      stub_embedder(account, 'терапевт' => unit_vector(0), 'узи' => unit_vector(4), 'ЭКГ' => unit_vector(6), 'рентген' => unit_vector(8))
      ecg = service('ЭКГ', 6)
      xray = service('Рентген', 8)
      link(ecg, aigerim)
      link(xray, aigerim)

      results = search(services: %w[терапевт узи ЭКГ рентген], from: '2026-04-22', to: '2026-04-23')['results']

      expect(results.map { |result| result['slots_status'] }).to eq([nil, nil, nil, 'not_searched'])
      expect(results.last['services'].first['id']).to eq(xray.id)
    end
  end

  describe 'a service without a recorded specialist' do
    let!(:lonely) { service('Консультация терапевта на дому', 0, base_price: 20_000) }

    it 'keeps the price and says that the specialist has to be chosen first, as search_available_slots does' do
      result = search(services: ['терапевт'])['results'].first

      expect(result['services'].first).to include('id' => lonely.id, 'price' => 20_000)
      expect(result).to include('slots_status' => 'specialist_required')
      expect(result['slots_note']).to include('search_scheduling_resources')
      expect(result).not_to have_key('days')
    end
  end

  describe 'a named specialist' do
    let!(:aigerim) { doctor('Асланова Айгерим', specialty: 'терапевт') }
    let!(:dinara) { doctor('Бекова Динара', specialty: 'терапевт') }
    let!(:visit) { service('Консультация терапевта', 0, base_price: 15_000) }

    before do
      doctor('Сеитов Ерлан', specialty: 'хирург')
      link(visit, aigerim)
      link(visit, dinara)
    end

    it 'gives the specialist and her free times alone, found by the specialist search' do
      answer = search(doctor: 'Асланова', from: '2026-04-22', to: '2026-04-23')

      expect(answer).not_to have_key('results')
      expect(answer['specialists']).to include('search_status' => 'candidate', 'total_count' => 1)
      expect(answer['specialists']['resources'].pluck('id')).to eq([aigerim.id])
      expect(answer['specialists']['days'].pluck('resource_id')).to eq([aigerim.id])
    end

    it 'gives the free times of every specialist of a specialty' do
      answer = search(doctor: 'терапевт', from: '2026-04-22', to: '2026-04-23')

      expect(answer['specialists']['days'].pluck('resource_id')).to contain_exactly(aigerim.id, dinara.id)
    end

    it 'searches only that specialist for each service when both are given' do
      answer = search(services: ['терапевт'], doctor: 'Бекова', from: '2026-04-22', to: '2026-04-23')

      expect(answer['results'].first['days'].pluck('resource_id')).to eq([dinara.id])
      expect(answer['specialists']).not_to have_key('days')
      expect(answer['specialists']['resources'].pluck('id')).to eq([dinara.id])
    end

    it 'searches no time of another specialist when the named one is not found' do
      answer = search(services: ['терапевт'], doctor: 'Несуществующая')

      expect(answer['specialists']).to include('total_count' => 0)
      expect(answer['results'].first).to include('slots_status' => 'specialist_not_found')
      expect(answer['results'].first).not_to have_key('days')
    end

    it 'narrows specialty matches to compatible doctors and keeps catalog prices on multi-service doctor mismatches' do
      ultrasound = service('УЗИ щитовидной железы', 4, base_price: 9000, duration_min: 20)
      ultrasound_doctor = doctor('Сеитова Алия', specialty: 'терапевт')
      link(ultrasound, ultrasound_doctor)

      specialty_answer = search(services: ['узи'], doctor: 'терапевт', from: '2026-04-22', to: '2026-04-23')
      expect(specialty_answer['results'].first['days'].pluck('resource_id').uniq).to eq([ultrasound_doctor.id])

      multi_answer = search(services: %w[узи терапевт], doctor: 'Асланова', from: '2026-04-22', to: '2026-04-23')
      expect(multi_answer['results'].first).to include(
        'slots_status' => 'service_resource_mismatch',
        'eligible_resources' => [{ 'id' => ultrasound_doctor.id, 'name' => 'Сеитова Алия' }]
      )
      expect(multi_answer['results'].first['services'].first['price']).to eq(9000)
      expect(multi_answer['results'].second['days'].pluck('resource_id')).to eq([aigerim.id])
    end

    it 'still gives a named specialist\'s availability when the service is not in the catalog' do
      answer = search(services: ['нет такой'], doctor: 'Асланова', from: '2026-04-22', to: '2026-04-23')

      expect(answer['results'].first).to include('status' => 'not_in_catalog')
      expect(answer['specialists']['days'].pluck('resource_id')).to eq([aigerim.id])
    end
  end

  describe 'the size of the answer' do
    let!(:visit) { service('Консультация терапевта', 0) }
    let!(:doctors) { Array.new(6) { |index| doctor("Врач #{index + 1}") } }

    before { doctors.each { |resource| link(visit, resource) } }

    it 'lists the first four specialists with two days each and counts the rest' do
      result = search(services: ['терапевт'], from: '2026-04-22', to: '2026-04-25')['results'].first

      expect(result['days'].size).to eq(8)
      expect(result['days'].pluck('resource_id').uniq.size).to eq(4)
      expect(result['doctors_not_shown']).to eq(2)
      expect(result['more_days']).to eq(4)
    end
  end

  describe 'a call that cannot be answered' do
    it 'is a failure the agent can fix when it names neither services nor a specialist' do
      output = call('search_booking_options')

      expect(Captain::ToolResult.error?(output)).to be(true)
      expect(output).to include('QUERY_REQUIRED')
      expect(Captain::Runtime::ToolFailure.technical?(output)).to be(false)
    end

    it 'is a failure of the free-time search unchanged, for example a range that is too long' do
      create(:scheduling_service_price, account: account, service: service('Консультация терапевта', 0), resource: doctor('Врач'))

      output = call('search_booking_options', services: ['терапевт'], from: '2026-04-22', to: '2026-12-31')

      expect(Captain::ToolResult.error?(output)).to be(true)
      expect(output).to include('INVALID_DATE_RANGE')
    end

    it 'is not available to staff or Copilot: it reads for the patient agent' do
      output = described_class.new(assistant, user: create(:user, account: account)).execute(services: ['терапевт'])

      expect(Captain::ToolResult.error?(output)).to be(true)
    end
  end
end
