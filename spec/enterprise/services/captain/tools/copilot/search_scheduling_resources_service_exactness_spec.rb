require 'rails_helper'

# A resource may be reported as the confident candidate only when the words of the request are exactly the words of its
# name (in any order, ё as е, a hyphen splitting words) or of its stored specialty. A part of a name, a form of a surname
# that holds the request as a substring, or a longer specialty is listed for confirmation. All data is synthetic.
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
      expect(payload).not_to have_key('instruction')
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

  it 'lists a person asked for by a part of the name, and asks to confirm the full name' do
    resource = create_resource('Асланов Мурад Тестович', 'Хирург')

    ['Мурад Асланов', 'Асланов', 'асланов мурад'].each do |query|
      payload = search(query: query, search_by: 'name')

      expect(payload['resources'].pluck('id')).to eq([resource.id])
      expect(payload['exact_name_matches']).to eq(0)
      expect_name_confirmation(payload)
    end
  end

  it 'does not take another form of a surname for the requested person' do
    create_resource('Асланова Мария Ивановна')

    payload = search(query: 'Асланов Мария Ивановна', search_by: 'name')

    expect(payload['total_count']).to eq(1)
    expect_name_confirmation(payload)
  end

  it 'does not take an extra word on the stored side for an equal name' do
    create_resource('Кабинет МРТ 1')

    expect_name_confirmation(search(query: 'Кабинет МРТ'))
    expect(search(query: 'кабинет мрт 1')).to include('search_status' => 'candidate')
    # the name holds a number, so its words are read in order
    expect_name_confirmation(search(query: 'МРТ кабинет 1'))
  end

  it 'asks to confirm the name when only the specialty equals the request' do
    surgeon = create_resource('Асланов Мурад Тестович', 'Хирург')

    expect_name_confirmation(search(query: 'хирург', search_by: 'specialty'))
    expect(search(query: 'хирург', search_by: 'specialty')['resources'].pluck('id')).to eq([surgeon.id])

    surgeon.update!(specialty: 'Нейрохирург')

    expect_name_confirmation(search(query: 'хирург', search_by: 'specialty'))

    surgeon.update!(specialty: 'Детский хирург')

    expect_name_confirmation(search(query: 'хирург', search_by: 'specialty'))
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
