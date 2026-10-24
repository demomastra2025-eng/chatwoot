require 'rails_helper'

# The patient agent re-reads every tool result on every later step of a run, so the catalog search answers it with one compact
# JSON line per service: id, name, base price, duration and the specialists as "id name". Staff and Copilot keep the admin payload.
# All data is synthetic.
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

  before { account.enable_features!('scheduling') }

  def doctor(name, **attributes)
    create(:scheduling_resource, account: account, name: name, **attributes)
  end

  def service(name, **attributes)
    create(:scheduling_service, account: account, name: name, **attributes)
  end

  def link(service, doctor, price)
    create(:scheduling_service_price, account: account, service: service, resource: doctor, price: price)
  end

  describe 'the entry of a service' do
    let!(:therapist) { doctor('Асланова Айгерим') }
    let!(:second_therapist) { doctor('Бекова Динара') }
    let!(:visit) { service('Консультация терапевта первичная', base_price: 15_000, duration_min: 40) }

    before do
      link(visit, therapist, 15_000)
      link(visit, second_therapist, 18_000)
    end

    it 'is one compact JSON line with the ids the next tool call needs' do
      output = agent_tool.execute(query: 'консультация терапевта')

      expect(output).not_to include("\n")
      expect(JSON.parse(output)).to eq(
        'total_count' => 1, 'match_status' => 'candidate',
        'services' => [{ 'id' => visit.id, 'name' => 'Консультация терапевта первичная', 'price' => 15_000, 'duration_min' => 40,
                         'doctors' => ["#{therapist.id} Асланова Айгерим", "#{second_therapist.id} Бекова Динара (18000)"] }],
        'instruction' => described_class::SINGLE_MATCH_INSTRUCTION
      )
    end

    it 'writes a specialist price only when it differs from the base price' do
      doctors = JSON.parse(agent_tool.execute(query: 'консультация терапевта')).dig('services', 0, 'doctors')

      expect(doctors.grep(/\(/)).to eq(["#{second_therapist.id} Бекова Динара (18000)"])
    end

    it 'leaves out the custom attributes, the timestamps, the account id, the compensation fields and every empty field' do
      visit.update!(custom_attributes: { 'medelement_nomenclature_code' => 'A01.001' }, description: 'Long text', category: 'Консультации')
      therapist.update!(custom_attributes: { 'medelement_specialist_code' => '55' })
      output = agent_tool.execute(query: 'консультация терапевта')

      expect(output).not_to match(/custom_attributes|created_at|updated_at|account_id|compensation|medelement|description|category|null|""/)
    end

    it 'lists a service without any active specialist link without a doctors field' do
      lonely = service('Консультация терапевта на дому')
      entry = JSON.parse(agent_tool.execute(query: 'консультация терапевта на дому'))['services'].find { |item| item['id'] == lonely.id }

      expect(entry).to eq('id' => lonely.id, 'name' => 'Консультация терапевта на дому', 'price' => 15_000, 'duration_min' => 30)
    end

    it 'does not list a specialist who is switched off' do
      link(visit, doctor('Архивная Анна', active: false), 15_000)

      doctors = JSON.parse(agent_tool.execute(query: 'консультация терапевта')).dig('services', 0, 'doctors')

      expect(doctors.size).to eq(2)
    end

    it 'keeps the admin payload with the prices and the verification labels for staff and Copilot' do
      payload = JSON.parse(staff_tool.execute(query: 'консультация терапевта'))

      expect(payload['services'].first['prices'].size).to eq(2)
      expect(payload['services'].first).to include('custom_attributes', 'created_at', 'account_id')
    end
  end

  describe 'the package of services' do
    it 'gives the services of a package with their ids and the total price' do
      first = service('Консультация терапевта', base_price: 10_000)
      second = service('ЭКГ', base_price: 5000)
      package = service('Пакет: Консультация терапевта + ЭКГ', base_price: 14_000)

      entry = JSON.parse(agent_tool.execute(query: 'пакет консультация терапевта ЭКГ'))['services'].find { |item| item['id'] == package.id }

      expect(entry['component_services']).to contain_exactly({ 'id' => first.id, 'name' => 'Консультация терапевта', 'price' => 10_000 },
                                                             { 'id' => second.id, 'name' => 'ЭКГ', 'price' => 5000 })
      expect(entry['components_total_price']).to eq(15_000)
    end
  end

  describe 'the number of services in one answer' do
    before { Array.new(23) { |index| service(format('УЗИ вариант %<number>02d', number: index)) } }

    it 'is at most 10 for the patient agent, whatever limit it asks for, and offers the next page' do
      first_page = JSON.parse(agent_tool.execute(query: 'УЗИ', limit: 50))
      second_page = JSON.parse(agent_tool.execute(query: 'УЗИ', limit: 50, offset: first_page['next_offset']))

      expect(first_page).to include('total_count' => 23, 'has_more' => true, 'next_offset' => 10)
      expect(first_page['services'].size).to eq(10)
      expect(second_page['services'].size).to eq(10)
      expect(second_page['services'].pluck('id') & first_page['services'].pluck('id')).to be_empty
    end

    it 'is not limited to 10 for staff and Copilot' do
      expect(JSON.parse(staff_tool.execute(query: 'УЗИ'))['services'].size).to eq(23)
    end

    it 'says nothing about paging on the last page' do
      payload = JSON.parse(agent_tool.execute(query: 'УЗИ', offset: 20))

      expect(payload.keys).to contain_exactly('total_count', 'match_status', 'services', 'instruction')
    end
  end

  describe 'an empty query' do
    before do
      service('УЗИ почек', category: 'Диагностика')
      service('УЗИ сердца', category: 'Диагностика')
      service('Консультация терапевта', category: 'Консультации')
      service('Прием без категории')
    end

    it 'does not list the catalog for the patient agent: it asks to refine the query and names the categories' do
      payload = JSON.parse(agent_tool.execute)

      expect(payload).to eq(
        'match_status' => 'query_required', 'total_count' => 4, 'categories' => %w[Диагностика Консультации],
        'instruction' => Captain::Tools::Agent::CatalogPayload::REFINE_QUERY_INSTRUCTION
      )
      expect(JSON.parse(agent_tool.execute(query: '  '))).to eq(payload)
    end

    it 'still lists the catalog for staff and Copilot' do
      expect(JSON.parse(staff_tool.execute)['services'].size).to eq(4)
    end
  end

  describe 'the size of the answer' do
    # A catalogue of 50 services that one word matches, four specialists per service, with the extra fields of a MedElement import.
    def seed_catalog
      doctors = Array.new(12) { |index| import_doctor(index) }
      Array.new(50) do |index|
        price = 10_000 + (index * 100)
        code = { 'medelement_nomenclature_code' => format('A%03d', index) }
        attributes = { base_price: price, category: 'Консультации', direction: 'Терапия', custom_attributes: code }
        record = service(format('Прием врача консультация вариант %<number>02d', number: index), **attributes)
        doctors.rotate(index).first(4).each { |item| link(record, item, price + 500) }
      end
    end

    def import_doctor(index)
      cabinet = { 'companyCabinetCode' => "CAB-#{index}", 'cabinetName' => "Кабинет #{index}" }
      attributes = { specialty: 'Терапевт', description: 'Опытный врач высшей категории', photo_url: "https://example.test/photos/#{index}.jpg",
                     custom_attributes: { 'medelement_specialist_code' => "SP-#{index}", 'medelement_cabinets' => [cabinet] } }
      doctor("Врач-специалист Фамилия#{index} Имя Отчество", **attributes)
    end

    # What the patient agent read before the compact answer: the answer of staff without the two verification labels it never got.
    def legacy_agent_output(staff_output)
      payload = JSON.parse(staff_output).except('eligibility_status', 'ambiguous')
      payload['services'].each { |entry| entry['prices'].each { |price| price.delete('service_eligibility_status') } }
      JSON.pretty_generate(payload)
    end

    it 'is a small fraction of the admin payload for a full page of services' do
      seed_catalog

      before_size = legacy_agent_output(staff_tool.execute(query: 'консультация', limit: 50)).bytesize
      after_size = agent_tool.execute(query: 'консультация').bytesize
      RSpec.configuration.reporter.message("search_scheduling_services, 50 matches x 4 specialists: #{before_size} bytes -> #{after_size} bytes")

      expect(before_size).to be > 50_000
      expect(after_size).to be < 8000
      expect(after_size).to be < before_size / 10
    end
  end
end
