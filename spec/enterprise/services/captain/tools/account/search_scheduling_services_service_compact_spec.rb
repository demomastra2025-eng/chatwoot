require 'rails_helper'

# The patient agent re-reads every tool result on every later step of a run, so the catalog search answers it with one compact
# JSON line: per mention the services as id, name, base price, duration, the specialists as "id name" and the score. Staff and Copilot
# keep the admin payload. All data is synthetic.
RSpec.describe Captain::Tools::Account::SearchSchedulingServicesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:staff_tool) { described_class.new(assistant, user: user) }
  let(:agent_tool) do
    described_class.new(assistant, user: user).tap do |tool|
      tool.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)
    end
  end

  before do
    account.enable_features!('scheduling')
    stub_embedder(account, 'терапевт' => unit_vector(0), 'пакет' => unit_vector(2), 'узи' => unit_vector(4))
  end

  def doctor(name, **attributes)
    create(:scheduling_resource, account: account, name: name, **attributes)
  end

  def service(name, vector: nil, **attributes)
    create(:scheduling_service, account: account, name: name, **attributes).tap { |record| index_service(record, vector) if vector }
  end

  def link(service, doctor, price)
    create(:scheduling_service_price, account: account, service: service, resource: doctor, price: price)
  end

  def first_entries(output)
    JSON.parse(output).dig('results', 0, 'services')
  end

  describe 'the entry of a service' do
    let!(:therapist) { doctor('Асланова Айгерим') }
    let!(:second_therapist) { doctor('Бекова Динара') }
    let!(:visit) { service('Консультация терапевта первичная', vector: vector_at(0, 0.9), base_price: 15_000, duration_min: 40) }

    before do
      link(visit, therapist, 15_000)
      link(visit, second_therapist, 18_000)
    end

    it 'is one compact JSON line with the ids the next tool call needs' do
      output = agent_tool.execute(queries: ['терапевт'])

      expect(output).not_to include("\n")
      expect(JSON.parse(output)).to eq(
        'results' => [{ 'query' => 'терапевт', 'status' => 'found',
                        'services' => [{ 'id' => visit.id, 'name' => 'Консультация терапевта первичная', 'price' => 15_000, 'duration_min' => 40,
                                         'doctors' => ["#{therapist.id} Асланова Айгерим", "#{second_therapist.id} Бекова Динара (18000)"],
                                         'score' => 0.9 }] }]
      )
    end

    it 'shows no duration for a MedElement service: its duration_min is the column default, the real length depends on the specialist' do
      ultrasound = service('УЗИ малого таза', vector: vector_at(4, 0.9), base_price: 9000, duration_min: 30,
                                              custom_attributes: { 'medelement_nomenclature_code' => 'U1' })

      entry = first_entries(agent_tool.execute(queries: ['узи'])).find { |item| item['id'] == ultrasound.id }

      expect(entry).to eq('id' => ultrasound.id, 'name' => 'УЗИ малого таза', 'price' => 9000, 'score' => 0.9)
    end

    it 'writes a specialist price only when it differs from the base price' do
      doctors = first_entries(agent_tool.execute(queries: ['терапевт'])).first['doctors']

      expect(doctors.grep(/\(/)).to eq(["#{second_therapist.id} Бекова Динара (18000)"])
    end

    it 'leaves out the custom attributes, the timestamps, the account id, the compensation fields and every empty field' do
      visit.update!(custom_attributes: { 'medelement_nomenclature_code' => 'A01.001' }, description: 'Long text', category: 'Консультации')
      therapist.update!(custom_attributes: { 'medelement_specialist_code' => '55' })
      output = agent_tool.execute(queries: ['терапевт'])

      expect(output).not_to match(/custom_attributes|created_at|updated_at|account_id|compensation|medelement|description|category|null|""/)
    end

    it 'lists a service without any active specialist link without a doctors field' do
      lonely = service('Консультация терапевта на дому', vector: vector_at(0, 0.85))
      entry = first_entries(agent_tool.execute(queries: ['терапевт'])).find { |item| item['id'] == lonely.id }

      expect(entry).to eq('id' => lonely.id, 'name' => 'Консультация терапевта на дому', 'price' => 15_000, 'duration_min' => 30,
                          'score' => 0.85)
    end

    it 'does not list a specialist who is switched off' do
      link(visit, doctor('Архивная Анна', active: false), 15_000)

      expect(first_entries(agent_tool.execute(queries: ['терапевт'])).first['doctors'].size).to eq(2)
    end

    it 'keeps the admin payload with the prices and the verification labels for staff and Copilot' do
      payload = JSON.parse(staff_tool.execute(queries: ['терапевт']))
      entry = payload['results'].first['services'].first

      expect(entry['prices'].size).to eq(2)
      expect(entry).to include('custom_attributes', 'created_at', 'account_id')
    end
  end

  describe 'the package of services' do
    it 'gives the services of a package with their ids and the total price' do
      first = service('Консультация терапевта', base_price: 10_000)
      second = service('ЭКГ', base_price: 5000)
      package = service('Пакет: Консультация терапевта + ЭКГ', vector: vector_at(2, 0.9), base_price: 14_000)

      entry = first_entries(agent_tool.execute(queries: ['пакет'])).find { |item| item['id'] == package.id }

      expect(entry['component_services']).to contain_exactly({ 'id' => first.id, 'name' => 'Консультация терапевта', 'price' => 10_000 },
                                                             { 'id' => second.id, 'name' => 'ЭКГ', 'price' => 5000 })
      expect(entry['components_total_price']).to eq(15_000)
    end
  end

  describe 'the number of services in one answer' do
    before do
      Array.new(23) { |index| service(format('УЗИ вариант %<number>02d', number: index), vector: vector_at(4, 0.95 - (index * 0.001))) }
    end

    it 'is 5 per mention by default and at most 10 for the patient agent, whatever limit it asks for' do
      expect(first_entries(agent_tool.execute(queries: ['узи'])).size).to eq(5)
      expect(first_entries(agent_tool.execute(queries: ['узи'], limit: 50)).size).to eq(10)
    end

    it 'is not limited to 10 for staff and Copilot' do
      expect(JSON.parse(staff_tool.execute(queries: ['узи'], limit: 50)).dig('results', 0, 'services').size).to eq(23)
    end

    it 'says nothing about paging: there is no next page of a search, the caller refines the mention instead' do
      payload = JSON.parse(agent_tool.execute(queries: ['узи']))

      expect(payload.to_s).not_to match(/offset|has_more|total_count/)
    end
  end

  describe 'an empty list of queries' do
    before do
      service('УЗИ почек', category: 'Диагностика')
      service('УЗИ сердца', category: 'Диагностика')
      service('Консультация терапевта', category: 'Консультации')
      service('Прием без категории')
    end

    it 'does not list the catalog for the patient agent: it asks for queries and names the categories' do
      payload = JSON.parse(agent_tool.execute)

      expect(payload).to eq(
        'status' => 'queries_required', 'total_count' => 4, 'categories' => %w[Диагностика Консультации],
        'instruction' => Captain::Tools::Agent::CatalogPayload::REFINE_QUERY_INSTRUCTION
      )
      expect(JSON.parse(agent_tool.execute(queries: ['  ', '']))).to eq(payload)
    end

    it 'still lists the catalog for staff and Copilot' do
      expect(JSON.parse(staff_tool.execute)['services'].size).to eq(4)
    end
  end

  describe 'the size of the answer' do
    # A catalogue of 50 services that one concept matches, four specialists per service, with the extra fields of a MedElement import.
    def seed_catalog
      doctors = Array.new(12) { |index| import_doctor(index) }
      Array.new(50) do |index|
        price = 10_000 + (index * 100)
        code = { 'medelement_nomenclature_code' => format('A%03d', index) }
        attributes = { base_price: price, category: 'Консультации', direction: 'Терапия', custom_attributes: code }
        name = format('Прием врача консультация вариант %<number>02d', number: index)
        record = service(name, vector: vector_at(0, 0.95 - (index * 0.001)), **attributes)
        doctors.rotate(index).first(4).each { |item| link(record, item, price + 500) }
      end
    end

    def import_doctor(index)
      cabinet = { 'companyCabinetCode' => "CAB-#{index}", 'cabinetName' => "Кабинет #{index}" }
      attributes = { specialty: 'Терапевт', description: 'Опытный врач высшей категории', photo_url: "https://example.test/photos/#{index}.jpg",
                     custom_attributes: { 'medelement_specialist_code' => "SP-#{index}", 'medelement_cabinets' => [cabinet] } }
      doctor("Врач-специалист Фамилия#{index} Имя Отчество", **attributes)
    end

    it 'is a small fraction of the admin payload of a full page of services' do
      seed_catalog

      admin_size = JSON.pretty_generate(JSON.parse(staff_tool.execute(queries: ['терапевт'], limit: 50))).bytesize
      agent_size = agent_tool.execute(queries: ['терапевт']).bytesize
      RSpec.configuration.reporter.message("search_scheduling_services, 50 matches x 4 specialists: #{admin_size} bytes -> #{agent_size} bytes")

      expect(admin_size).to be > 50_000
      expect(agent_size).to be < 3000
      expect(agent_size).to be < admin_size / 20
    end
  end
end
