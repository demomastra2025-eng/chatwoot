require 'rails_helper'

# Synthetic data. "Асланов Мурад Тестович" mirrors the shape of a name from the stage-1 audit; nobody real is used.
RSpec.describe Captain::Tools::Copilot::SearchSchedulingResourcesService do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }
  let!(:specialist) { create(:scheduling_resource, account: account, name: 'Асланов Мурад Тестович', specialty: 'Хирург') }
  let!(:room) do
    create(:scheduling_resource, account: account, name: 'Кабинет МРТ 1', specialty: nil,
                                 custom_attributes: { 'medelement_cabinets' => [{ 'cabinetCode' => 'room-1' }] })
  end

  before { account.enable_features!('scheduling') }

  def search(**arguments)
    JSON.parse(tool.execute(**arguments))
  end

  it 'finds a person by words in any order and reports one candidate' do
    payload = search(query: 'Мурад Асланов Тестович', search_by: 'name')

    expect(payload['resources'].pluck('id')).to eq([specialist.id])
    expect(payload).to include('search_status' => 'candidate', 'ambiguous' => false, 'link_status' => 'not_checked')
  end

  it 'reports several matches as ambiguous and no match as its own status' do
    create(:scheduling_resource, account: account, name: 'Асланов Мурад Другой')

    expect(search(query: 'Асланов Мурад')).to include('search_status' => 'ambiguous', 'ambiguous' => true, 'total_count' => 2)
    expect(search(query: 'Неизвестный')).to include('search_status' => 'no_name_or_specialty_match', 'total_count' => 0)
  end

  it 'does not claim a direction for a diagnostic room without a stored specialty' do
    expect(search(query: 'МРТ', search_by: 'specialty')).to include('total_count' => 0, 'search_status' => 'no_name_or_specialty_match')
    expect(search(query: 'МРТ', search_by: 'name')['resources'].pluck('id')).to eq([room.id])
  end

  it 'treats a price row as an unverified link and an inactive row as no link' do
    service_record = create(:scheduling_service, account: account, name: 'МРТ кисти')
    create(:scheduling_service_price, account: account, service: service_record, resource: room, active: true)
    create(:scheduling_service_price, account: account, service: service_record, resource: specialist, active: false)

    payload = search(service_id: service_record.id)

    expect(payload['resources'].pluck('id')).to eq([room.id])
    expect(payload).to include('link_status' => 'price_link_unverified', 'search_status' => 'candidates')
  end

  it 'reports a service without any link (incomplete import) separately from a missing text match' do
    service_record = create(:scheduling_service, account: account, name: 'Услуга без связей')

    expect(search(service_id: service_record.id)).to include('search_status' => 'no_recorded_link', 'link_status' => 'no_recorded_link',
                                                             'total_count' => 0)
    expect(search(service_id: service_record.id, query: 'мурад')).to include('search_status' => 'no_match_with_recorded_link_filter',
                                                                             'total_count' => 0)
  end

  it 'pages through resources and keeps the total' do
    5.times { |index| create(:scheduling_resource, account: account, name: format('Дополнительный %<number>02d', number: index)) }

    first = search(limit: 4)
    second = search(limit: 4, offset: first['next_offset'])

    expect(first).to include('total_count' => 7, 'returned_count' => 4, 'has_more' => true, 'next_offset' => 4)
    expect(second).to include('total_count' => 7, 'returned_count' => 3, 'has_more' => false, 'next_offset' => nil)
    expect((first['resources'] + second['resources']).pluck('id').uniq.size).to eq(7)
  end

  it 'never shows a resource of another account' do
    create(:scheduling_resource, account: other_account, name: 'Асланов Мурад Тестович')

    expect(search(query: 'Асланов Мурад')['total_count']).to eq(1)
  end

  it 'survives odd text and rejects a service id of another account' do
    ["'", '%', "\u0000", '😀', 'х ' * 500].each do |query|
      expect(tool.execute(query: query)).not_to start_with('ERROR')
    end
    foreign = create(:scheduling_service, account: other_account, name: 'Чужая услуга')

    expect(tool.execute(service_id: foreign.id)).to start_with('ERROR')
  end

  describe 'offset' do
    it 'rejects negative, fractional, textual and oversized values with one clear message' do
      ['-1', -1, 1.5, 'abc', '1e3', 10**12, [1], { a: 1 }].each do |offset|
        expect(tool.execute(offset: offset)).to(start_with('ERROR').and(include('offset must be')), "offset #{offset.inspect}")
      end
    end

    it 'accepts blank, zero, whole numbers and digit strings' do
      [nil, '', 0, '0', 2.0, '3'].each do |offset|
        expect(tool.execute(offset: offset)).not_to start_with('ERROR'), "offset #{offset.inspect}"
      end
    end
  end
end
