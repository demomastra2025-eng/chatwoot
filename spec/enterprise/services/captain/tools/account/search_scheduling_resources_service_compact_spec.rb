require 'rails_helper'

# The patient agent reads a specialist as id, name and specialty: no MedElement codes, cabinets of a single-room specialist, photo,
# colour, timezone, timestamps or compensation fields. Staff and Copilot keep the admin payload. All data is synthetic.
RSpec.describe Captain::Tools::Account::SearchSchedulingResourcesService do
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

  def cabinet(code, name, number)
    { 'companyCabinetCode' => code, 'cabinetName' => name, 'cabinetNumber' => number, 'cabinetType' => 'Кабинет приема' }
  end

  def doctor(name, specialty, cabinets, **attributes)
    create(:scheduling_resource, account: account, name: name, specialty: specialty,
                                 custom_attributes: { 'medelement_specialist_code' => "SP-#{name.hash.abs}", 'medelement_cabinets' => cabinets },
                                 **attributes)
  end

  describe 'the entry of a specialist' do
    let!(:therapist) { doctor('Асланова Айгерим Тестовна', 'Терапевт', [cabinet('C-1', 'Кабинет 12', '12')]) }

    it 'is id, name and specialty on one compact line' do
      output = agent_tool.execute(query: 'Асланова')

      expect(output).not_to include("\n")
      expect(JSON.parse(output)).to eq(
        'total_count' => 1, 'search_status' => 'candidate',
        'resources' => [{ 'id' => therapist.id, 'name' => 'Асланова Айгерим Тестовна', 'specialty' => 'Терапевт' }],
        'instruction' => described_class::SINGLE_MATCH_INSTRUCTION
      )
    end

    it 'leaves out the MedElement codes, the photo, the colour, the timezone, the timestamps and the compensation fields' do
      therapist.update!(photo_url: 'https://example.test/photo.jpg', description: 'Опытный врач', color: '#ff0000')
      output = agent_tool.execute(query: 'Асланова')

      expect(output).not_to match(/medelement|custom_attributes|photo|color|timezone|created_at|updated_at|account_id|compensation|SP-|C-1/)
    end

    it 'leaves out an empty specialty' do
      doctor('Бекова Динара', nil, [])

      entry = JSON.parse(agent_tool.execute(query: 'Бекова'))['resources'].first

      expect(entry.keys).to contain_exactly('id', 'name')
    end

    it 'names the cabinets only for a specialist who sits in more than one, and never gives their codes' do
      surgeon = doctor('Сериков Олжас', 'Хирург', [cabinet('C-5', 'Перевязочная', '5'), cabinet('C-6', nil, '6')])

      entry = JSON.parse(agent_tool.execute(query: 'Сериков'))['resources'].find { |item| item['id'] == surgeon.id }

      expect(entry).to include('cabinets' => %w[Перевязочная 6])
      expect(JSON.parse(agent_tool.execute(query: 'Асланова')).dig('resources', 0)).not_to have_key('cabinets')
    end

    it 'marks the entry whose name is the request among several and keeps the id of every entry' do
      exact = doctor('Асланова', 'Хирург', [])
      payload = JSON.parse(agent_tool.execute(query: 'Асланова'))

      expect(payload['resources'].pluck('id')).to contain_exactly(exact.id, therapist.id)
      expect(payload['resources'].find { |item| item['id'] == exact.id }).to include('best_match' => true)
      expect(payload['resources'].find { |item| item['id'] == therapist.id }).not_to have_key('best_match')
    end

    it 'keeps the admin payload for staff and Copilot' do
      entry = JSON.parse(staff_tool.execute(query: 'Асланова'))['resources'].first

      expect(entry).to include('custom_attributes', 'created_at', 'account_id', 'timezone', 'compensation_type')
    end
  end

  describe 'the size of the answer' do
    it 'is a small fraction of the admin payload for a clinic of 30 specialists' do
      Array.new(30) do |index|
        doctor("Врач-специалист Фамилия#{index} Имя Отчество", 'Терапевт',
               [cabinet("CAB-#{index}", "Кабинет #{index}", index.to_s), cabinet("CAB-#{index}-B", "Кабинет #{index}Б", "#{index}Б")],
               description: 'Опытный врач высшей категории', photo_url: "https://example.test/photos/#{index}.jpg", color: '#3b82f6')
      end

      before_size = staff_tool.execute(query: 'врач').bytesize
      after_size = agent_tool.execute(query: 'врач').bytesize
      RSpec.configuration.reporter.message("search_scheduling_resources, 30 specialists: #{before_size} bytes -> #{after_size} bytes")

      expect(JSON.parse(agent_tool.execute(query: 'врач'))['resources'].size).to eq(30)
      expect(after_size).to be < before_size / 4
    end
  end
end
