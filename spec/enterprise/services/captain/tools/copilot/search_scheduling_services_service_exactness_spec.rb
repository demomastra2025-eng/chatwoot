require 'rails_helper'

# A service may be reported as the confident match (match_status "candidate") only when its name, or one of its aliases,
# has exactly the words of the request. Every other text hit is offered with the instruction to confirm the exact name.
# All data is synthetic.
RSpec.describe Captain::Tools::Copilot::SearchSchedulingServicesService do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }
  let(:unconfident) { %w[ambiguous partial_candidates] }

  before { account.enable_features!('scheduling') }

  def create_service(name, **attributes)
    create(:scheduling_service, account: account, name: name, **attributes)
  end

  def search(**arguments)
    JSON.parse(tool.execute(**arguments))
  end

  def names_of(payload)
    payload['services'].pluck('name')
  end

  def expect_name_confirmation(payload)
    expect(payload['match_status']).to be_in(unconfident)
    expect(payload['ambiguous']).to be(true)
    expect(payload['instruction']).to include('differs from the request').and include('exact name').and include('never book')
  end

  describe 'a word that changes the meaning of the name' do
    [
      ['МРТ с контрастом', 'МРТ без контраста'],
      ['МРТ без контраста', 'МРТ с контрастом'],
      ['Анализ крови при беременности', 'Анализ крови после беременности'],
      ['МРТ 3 Тл', 'МРТ 1.5 Тл'],
      ['Гепатит I', 'Гепатит II'],
      ['Гепатит II', 'Гепатит I'],
      ['Витамин D', 'Витамин D3'],
      ['Витамин D3', 'Витамин D'],
      ['МРТ головного мозга сосудов шеи и позвоночника расширенная без контраста',
       'МРТ головного мозга сосудов шеи и позвоночника расширенная с контрастом']
    ].each do |query, sole_name|
      it "does not call #{sole_name.inspect} the confident match for #{query.inspect}" do
        create_service(sole_name)

        payload = search(query: query)

        expect(payload['total_count']).to eq(1)
        expect(names_of(payload)).to eq([sole_name])
        expect(payload['exact_name_matches']).to eq(0)
        expect_name_confirmation(payload)
      end
    end

    it 'does not let a word found only in the description complete the name' do
      create_service('МРТ головного мозга с контрастом', description: 'Подготовка: без седации')

      payload = search(query: 'МРТ головного мозга без контраста')

      expect(names_of(payload)).to eq(['МРТ головного мозга с контрастом'])
      expect_name_confirmation(payload)
    end

    it 'does not let a word found only in the category or the direction complete the name' do
      create_service('МРТ головного мозга', category: 'Исследования без контраста', direction: 'Нейровизуализация')

      expect_name_confirmation(search(query: 'МРТ головного мозга без контраста'))
      expect_name_confirmation(search(query: 'МРТ головного мозга нейровизуализация'))
    end

    it 'does not report a longer name as the match for a shorter request, nor a shorter name for a longer one' do
      create_service('УЗИ органов малого таза')

      expect_name_confirmation(search(query: 'УЗИ малого таза'))

      Scheduling::Service.delete_all
      create_service('УЗИ малого таза')

      expect_name_confirmation(search(query: 'УЗИ органов малого таза'))
    end

    it 'keeps the answer unverified and still lists the service so that the model can name it to the patient' do
      create_service('МРТ без контраста')

      payload = search(query: 'МРТ с контрастом')

      expect(payload).to include('eligibility_status' => 'unverified', 'returned_count' => 1)
      expect(names_of(payload)).to eq(['МРТ без контраста'])
    end
  end

  describe 'the equal name' do
    it 'is the candidate when the words are the same in another order, case or word form' do
      service = create_service('УЗИ малого таза')

      ['малого таза УЗИ', 'узи МАЛОГО ТАЗА'].each do |query|
        payload = search(query: query)

        expect(payload).to include('match_status' => 'candidate', 'exact_name_matches' => 1, 'ambiguous' => false)
        expect(payload['services'].pluck('id')).to eq([service.id])
        expect(payload).not_to have_key('instruction')
      end
    end

    it 'is the candidate when the request equals an alias and not the name' do
      service = create_service('Исследование А', custom_attributes: { 'aliases' => ['МРТ головы с контрастом', 'МРТ мозга'] })

      expect(search(query: 'МРТ головы с контрастом')).to include('match_status' => 'candidate', 'exact_name_matches' => 1)
      expect(search(query: 'мрт мозга')['services'].pluck('id')).to eq([service.id])
      expect_name_confirmation(search(query: 'МРТ головы без контраста'))
    end

    it 'is the only candidate for УЗИ малого таза and ЭКГ while longer names stay on the list' do
      create_service('УЗИ органов малого таза')
      create_service('УЗИ малого таза')
      create_service('ЭКГ с нагрузкой')
      create_service('ЭКГ')

      expect(search(query: 'УЗИ малого таза')).to include('match_status' => 'candidate', 'exact_name_matches' => 1)
      expect(names_of(search(query: 'УЗИ малого таза'))).to eq(['УЗИ малого таза', 'УЗИ органов малого таза'])
      expect(search(query: 'ЭКГ')).to include('match_status' => 'candidate', 'exact_name_matches' => 1)
      expect(names_of(search(query: 'ЭКГ'))).to eq(['ЭКГ', 'ЭКГ с нагрузкой'])
    end

    it 'is not the candidate when two services carry the same name' do
      create_service('УЗИ почек')
      create_service('УЗИ почек', category: 'Дети')

      payload = search(query: 'УЗИ почек')

      expect(payload).to include('match_status' => 'ambiguous', 'exact_name_matches' => 2)
      expect(payload['instruction']).to include('Several services')
    end

    it 'puts the equal name first even when it sorts after other names' do
      create_service('Я МРТ кисть')
      create_service('МРТ кисть левая')
      exact = create_service('Кисть МРТ')

      expect(search(query: 'МРТ кисть')['services'].first['id']).to eq(exact.id)
    end

    it 'does not take a request that is cut at the length limit for an equal name' do
      long_name = (['Слово'] * 40).join(' ')
      create_service(long_name)

      payload = search(query: long_name)

      expect(payload['match_status']).not_to eq('candidate')
    end
  end

  describe 'the audit catalogue' do
    # 128 "МРТ <part>" services; the eight "МРТ Кисть" variants sort at positions 45-52 of the broad candidate list.
    def seed_audit_catalogue
      parts = %w[Абдомена Артерий Бедра Брюшной Верхней Височной Голеностопного Головного Грудного Желчных Запястья Затылка]
      44.times { |index| create_service("МРТ #{parts[index % parts.size]} #{index}") }
      8.times { |index| create_service("МРТ Кисть вариант #{index + 1}") }
      76.times { |index| create_service("МРТ Яя#{index} Позвоночника") }
    end

    it 'surfaces all eight МРТ Кисть variants on the first page and asks to confirm the exact name' do
      seed_audit_catalogue

      payload = search(query: 'МРТ кисти')

      expect(payload).to include('total_count' => 8, 'returned_count' => 8, 'has_more' => false, 'exact_name_matches' => 0)
      expect(names_of(payload)).to all(start_with('МРТ Кисть вариант'))
      expect_name_confirmation(payload)
    end

    it 'orders a partial answer by the number of covered words and keeps every service reachable by paging' do
      seed_audit_catalogue

      first = search(query: 'МРТ кисти надколенника', limit: 50)
      second = search(query: 'МРТ кисти надколенника', limit: 50, offset: first['next_offset'])

      expect(first).to include('match_status' => 'partial_candidates', 'total_count' => 128, 'has_more' => true)
      expect(first['instruction']).to be_present
      expect(names_of(first).first(8)).to all(start_with('МРТ Кисть вариант'))
      expect((first['services'] + second['services']).pluck('id').uniq.size).to eq(100)
    end
  end
end
