require 'rails_helper'

# A resource may be reported as the confident candidate in two cases only: the words of the request are exactly the words of
# its name (in any order, ё as е, a hyphen splitting words) or of its stored specialty, or it is the one active resource found
# and its name holds every word of the request as a whole word (then the instruction says to name it exactly in the booking
# confirmation). A form of a surname or a number that holds the request only as a substring, several resources, or a longer
# specialty are listed for confirmation. All data is synthetic.
RSpec.describe Captain::Tools::Copilot::SearchSchedulingResourcesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }

  before { account.enable_features!('scheduling') }

  def create_resource(name, specialty = nil)
    create(:scheduling_resource, account: account, name: name, specialty: specialty)
  end

  def search(**arguments)
    JSON.parse(tool.execute(**arguments))
  end

  def expect_name_confirmation(payload)
    expect(payload['search_status']).to eq('ambiguous')
    expect(payload['ambiguous']).to be(true)
    expect(payload['instruction']).to include('differs from the request').and include('exact name').and include('never book')
  end

  def expect_single_match(payload)
    expect(payload).to include('search_status' => 'candidate', 'total_count' => 1, 'ambiguous' => false)
    expect(payload['instruction']).to eq(described_class::SINGLE_MATCH_INSTRUCTION)
    expect(payload['instruction']).to include('Exactly one specialist or room matches').and include('you may book it')
  end

  it 'reports the candidate for the full name in any order, with ё as е and with a hyphen' do
    hyphenated = create_resource('Иванова-Петрова Анна Сергеевна')
    fyodorov = create_resource('Фёдоров Пётр Семёнович')

    {
      'Анна Сергеевна Иванова Петрова' => hyphenated,
      'иванова-петрова анна сергеевна' => hyphenated,
      'федоров петр семенович' => fyodorov
    }.each do |query, resource|
      payload = search(query: query, search_by: 'name')

      expect(payload['resources'].pluck('id')).to eq([resource.id])
      expect(payload).to include('search_status' => 'candidate', 'ambiguous' => false, 'exact_name_matches' => 1)
      expect(payload['instruction']).to eq(described_class::SINGLE_MATCH_INSTRUCTION)
    end
  end

  it 'keeps the order of the words when the name holds a number, so that two numbered resources are not mixed up' do
    resource = create_resource('Кабинет 2 этаж 3')

    payload = search(query: 'Кабинет 2 этаж 3', search_by: 'name')

    expect(payload).to include('search_status' => 'candidate', 'exact_name_matches' => 1)

    ['Кабинет 3 этаж 2', 'этаж 3 Кабинет 2'].each do |query|
      payload = search(query: query, search_by: 'name')

      expect(payload['resources'].pluck('id')).to eq([resource.id])
      expect(payload['exact_name_matches']).to eq(0)
      expect_name_confirmation(payload)
    end
  end

  it 'offers the only person asked for by a part of the name as the confident candidate, with the full name in the answer' do
    resource = create_resource('Асланов Мурад Тестович', 'Хирург')

    ['Мурад Асланов', 'Асланов', 'асланов мурад'].each do |query|
      payload = search(query: query, search_by: 'name')

      expect(payload['resources'].pluck('id', 'name')).to eq([[resource.id, 'Асланов Мурад Тестович']])
      expect(payload['exact_name_matches']).to eq(0)
      expect_single_match(payload)
    end
  end

  it 'asks which person is meant when several people hold the part of the name' do
    create_resource('Асланов Мурад Тестович')
    create_resource('Асланов Эрик Тестович')

    payload = search(query: 'Асланов', search_by: 'name')

    expect(payload['total_count']).to eq(2)
    expect_name_confirmation(payload)
  end

  it 'asks to confirm the name when the only person found is not active' do
    create(:scheduling_resource, account: account, name: 'Асланов Мурад Тестович', active: false)

    expect_name_confirmation(search(query: 'Асланов', include_inactive: true))
  end

  it 'does not take another form of a surname for the requested person' do
    create_resource('Асланова Мария Ивановна')

    payload = search(query: 'Асланов Мария Ивановна', search_by: 'name')

    expect(payload['total_count']).to eq(1)
    expect_name_confirmation(payload)
  end

  it 'takes an extra word on the stored side for the only match, never for an equal name' do
    create_resource('Кабинет МРТ 1')
    create_resource('Кабинет МРТ 1 левое крыло')

    expect_name_confirmation(search(query: 'Кабинет МРТ'))
    expect(search(query: 'кабинет мрт 1')).to include('search_status' => 'candidate', 'exact_name_matches' => 1)
    # the name holds a number, so its words are read in order
    expect_name_confirmation(search(query: 'МРТ кабинет 1'))

    Scheduling::Resource.where(name: 'Кабинет МРТ 1').delete_all

    expect_single_match(search(query: 'Кабинет МРТ'))
    expect_name_confirmation(search(query: 'МРТ кабинет 1'))
  end

  it 'does not take a number that only sits inside another number for the only match' do
    create_resource('Кабинет 12')

    expect_name_confirmation(search(query: 'Кабинет 2'))
    expect_single_match(search(query: 'Кабинет 12'))
  end

  it 'asks to confirm the name when the request holds no word, only punctuation' do
    create_resource('Иванов И.И.')

    expect_name_confirmation(search(query: '.', search_by: 'name'))
  end

  it 'asks the model to write a surname and a specialty as a staff list does' do
    expect(described_class.parameters[:query].description).to include('staff list').and include('Асланова')
  end

  it 'asks to confirm the name when the specialty equals the request but the person is not the only fit' do
    surgeon = create_resource('Асланов Мурад Тестович', 'Хирург')
    create_resource('Бекова Алия Тестовна', 'Хирург')

    payload = search(query: 'хирург', search_by: 'specialty')

    expect_name_confirmation(payload)
    expect(payload['resources'].pluck('id')).to include(surgeon.id)
  end

  it 'offers the only person of a specialty as the confident candidate, but not a longer specialty' do
    surgeon = create_resource('Асланов Мурад Тестович', 'Хирург')

    payload = search(query: 'хирург', search_by: 'specialty')

    expect_single_match(payload)
    expect(payload['resources'].pluck('id')).to eq([surgeon.id])

    surgeon.update!(specialty: 'Нейрохирург')

    expect_name_confirmation(search(query: 'хирург', search_by: 'specialty'))

    surgeon.update!(specialty: 'Детский хирург')

    expect_single_match(search(query: 'хирург', search_by: 'specialty'))
  end

  it 'is not the candidate when two resources carry the same name' do
    create_resource('Асланов Мурад Тестович')
    create_resource('Асланов Мурад Тестович')

    payload = search(query: 'Асланов Мурад Тестович')

    expect(payload).to include('search_status' => 'ambiguous', 'exact_name_matches' => 2)
    expect(payload['instruction']).to include('Several resources')
  end

  it 'keeps the statuses of a plain listing and of no match' do
    create_resource('Асланов Мурад Тестович')

    expect(search).to include('search_status' => 'candidates')
    expect(search(query: 'Неизвестный')).to include('search_status' => 'no_name_or_specialty_match')
    expect(search(query: 'Неизвестный')).not_to have_key('instruction')
  end
end
