require 'rails_helper'

# A service may be reported as the confident match (match_status "candidate") in two cases only: its name, or one of its
# aliases, has exactly the words of the request, or it is the one active service found and its name holds every word of the
# request as written, qualifiers and numbers in the same order (then the instruction says to name the exact service in the
# booking confirmation). Every other text hit is offered with the instruction to confirm the exact name.
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
    expect(payload['instruction']).to include('differs from the request').and include('Choose the best match').and include('exact name')
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
      ['Анализ натощак', 'Анализ не натощак'],
      ['Анализ не натощак', 'Анализ натощак'],
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

    it 'does not report a shorter name as the match for a longer request' do
      create_service('УЗИ малого таза')

      expect_name_confirmation(search(query: 'УЗИ органов малого таза'))
    end

    it 'does not take another word form for the word of the request' do
      create_service('МРТ кисты')

      expect_name_confirmation(search(query: 'МРТ кисти'))
    end

    it 'keeps asking when a qualifier or a number of the request is missing in the only service found' do
      create_service('Приём врача до 14 лет')

      expect_name_confirmation(search(query: 'Приём врача после 14 лет'))
      expect_name_confirmation(search(query: 'Приём врача для 14 лет'))
      expect_name_confirmation(search(query: 'Приём врача до 18 лет'))
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
        expect(payload['instruction']).to eq(described_class::SINGLE_MATCH_INSTRUCTION)
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

  describe 'the only service found' do
    def expect_single_match(payload, service)
      expect(payload).to include('match_status' => 'candidate', 'total_count' => 1, 'ambiguous' => false)
      expect(payload['instruction']).to eq(described_class::SINGLE_MATCH_INSTRUCTION)
      expect(payload['instruction']).to include('Exactly one service matches').and include('you may book it').and include('exact service')
      expect(payload['services'].pluck('id')).to eq([service.id])
    end

    it 'is the confident candidate when its longer name holds every word of the request, and the name stays in the answer' do
      service = create_service('УЗИ органов малого таза')

      payload = search(query: 'УЗИ малого таза')

      expect_single_match(payload, service)
      expect(payload['exact_name_matches']).to eq(0)
      expect(names_of(payload)).to eq(['УЗИ органов малого таза'])
    end

    it 'is the confident candidate for words that stand in an alias of the service' do
      service = create_service('Исследование А', custom_attributes: { 'aliases' => ['Ультразвук почек и надпочечников'] })

      expect_single_match(search(query: 'ультразвук почек'), service)
    end

    it 'is the confident candidate when the other services that fit the request are not active' do
      service = create_service('УЗИ почек и надпочечников')
      create_service('УЗИ почек и мочевого пузыря', active: false)

      expect_single_match(search(query: 'УЗИ почек'), service)
    end

    it 'asks to confirm the name when several services fit the request' do
      create_service('УЗИ почек и надпочечников')
      create_service('УЗИ почек и мочевого пузыря')

      payload = search(query: 'УЗИ почек')

      expect(payload['total_count']).to eq(2)
      expect_name_confirmation(payload)
    end

    it 'asks to confirm the name when the only service found is not active' do
      create_service('УЗИ почек и надпочечников', active: false)

      expect_name_confirmation(search(query: 'УЗИ почек', include_inactive: true))
    end

    it 'asks to confirm the name when only some words of the request match' do
      create_service('УЗИ почек')

      payload = search(query: 'УЗИ почек и печени')

      expect(payload['match_status']).to eq('partial_candidates')
      expect_name_confirmation(payload)
    end

    it 'asks to confirm the name when the request has more words than the search reads' do
      create_service('альфа бета гамма дельта эпсилон дзета эта тета йота каппа')

      expect_name_confirmation(search(query: 'альфа бета гамма дельта эпсилон дзета эта тета йота'))
    end

    it 'asks to confirm the name when the request holds no word, only punctuation' do
      create_service('МРТ - голова')

      expect_name_confirmation(search(query: '-'))
    end

    it 'is still the confident candidate when the longer name adds a negated word that the request does not mention' do
      service = create_service('МРТ без контраста')

      expect_single_match(search(query: 'МРТ'), service)
    end

    it 'asks the model to write the words of the query as a catalog title does' do
      expect(described_class.parameters[:query].description).to include('catalog title').and include('консультация терапевта')
    end

    it 'adds no instruction to a plain listing of one service' do
      create_service('УЗИ почек')

      payload = search

      expect(payload).to include('match_status' => 'catalog_listing', 'total_count' => 1)
      expect(payload).not_to have_key('instruction')
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
