require 'rails_helper'

# Synthetic catalogue that reproduces the symptoms of the stage-1 audit: a query with no strict text match and many broad
# candidates, word forms that differ from the query, and result lists longer than one page.
RSpec.describe Captain::Tools::Copilot::SearchSchedulingServicesService do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }

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

  # 128 "МРТ <part>" services; the eight "МРТ Кисть" variants sort at positions 45-52 of the broad candidate list.
  def seed_audit_catalogue
    parts = %w[Абдомена Артерий Бедра Брюшной Верхней Височной Голеностопного Головного Грудного Желчных Запястья Затылка]
    44.times { |index| create_service("МРТ #{parts[index % parts.size]} #{index}") }
    8.times { |index| create_service("МРТ Кисть вариант #{index + 1}") }
    76.times { |index| create_service("МРТ Яя#{index} Позвоночника") }
  end

  it 'finds all eight word-form variants where the old substring search found none and cut two off at a page of 50' do
    seed_audit_catalogue

    payload = search(query: 'МРТ кисти', limit: 50)

    expect(payload).to include('total_count' => 8, 'returned_count' => 8, 'has_more' => false, 'match_status' => 'ambiguous',
                               'eligibility_status' => 'unverified')
    expect(names_of(payload)).to all(start_with('МРТ Кисть'))
  end

  it 'labels a catalogue without any full match as partial and pages through all broad candidates' do
    seed_audit_catalogue
    query = 'МРТ коленной кисти надколенника'

    first = search(query: query, limit: 50)
    expect(first).to include('total_count' => 128, 'match_status' => 'partial_candidates', 'ambiguous' => true, 'has_more' => true,
                             'next_offset' => 50)

    collected = names_of(first)
    page = first
    while page['has_more']
      page = search(query: query, limit: 50, offset: page['next_offset'])
      collected += names_of(page)
    end

    expect(collected.size).to eq(128)
    expect(collected.uniq.size).to eq(128)
  end

  it 'returns the exact name as the single candidate even when longer names exist' do
    create_service('ЭКГ')
    create_service('ЭКГ с нагрузкой')

    payload = search(query: 'ЭКГ')

    expect(names_of(payload)).to eq(['ЭКГ', 'ЭКГ с нагрузкой'])
    expect(payload).to include('match_status' => 'candidate', 'exact_name_matches' => 1, 'ambiguous' => false)
  end

  it 'tells apart no match, one candidate, ambiguous and a plain listing' do
    create_service('УЗИ почек')
    create_service('УЗИ малого таза')
    create_service('УЗИ органов малого таза')

    expect(search(query: 'рентген черепа')).to include('match_status' => 'no_match', 'total_count' => 0, 'ambiguous' => false)
    expect(search(query: 'УЗИ почек')).to include('match_status' => 'candidate', 'total_count' => 1)
    expect(search(query: 'УЗИ малого таза')).to include('match_status' => 'candidate', 'exact_name_matches' => 1)
    expect(search(query: 'УЗИ таза')).to include('match_status' => 'ambiguous', 'total_count' => 2)
    expect(search).to include('match_status' => 'catalog_listing', 'ambiguous' => false, 'total_count' => 3)
  end

  it 'does not keep state between two calls of the same tool instance' do
    create_service('УЗИ почек')

    expect(search(query: 'УЗИ почек')).to include('match_status' => 'candidate')
    expect(search).to include('match_status' => 'catalog_listing')
    expect(search(query: 'неизвестное')).to include('match_status' => 'no_match')
  end

  it 'covers several medical directions through category and direction words' do
    create_service('Консультация первичная', category: 'Приём', direction: 'Кардиология')
    create_service('Консультация повторная', category: 'Приём', direction: 'Неврология')
    create_service('Эхокардиография', category: 'Диагностика', direction: 'Кардиология')

    expect(names_of(search(query: 'кардиология')).sort).to eq(['Консультация первичная', 'Эхокардиография'])
    expect(names_of(search(query: 'неврология'))).to eq(['Консультация повторная'])
    expect(names_of(search(query: 'диагностика кардиология'))).to eq(['Эхокардиография'])
  end

  it 'never shows a service of another account, with the same name or not' do
    create_service('МРТ кисти')
    create(:scheduling_service, account: other_account, name: 'МРТ кисти')
    create(:scheduling_service, account: other_account, name: 'МРТ Кисть правая')

    payload = search(query: 'МРТ кисти')

    expect(payload['total_count']).to eq(1)
    expect(payload['services'].pluck('account_id')).to eq([account.id])
  end

  it 'skips inactive services unless asked' do
    create_service('МРТ кисти', active: false)

    expect(search(query: 'МРТ кисти')).to include('total_count' => 0, 'match_status' => 'no_match')
    expect(search(query: 'МРТ кисти', include_inactive: true)).to include('total_count' => 1)
  end

  it 'loads the price links of a page without one query per service' do
    resource = create(:scheduling_resource, account: account)
    5.times do |index|
      service = create_service("УЗИ вариант #{index}")
      create(:scheduling_service_price, account: account, service: service, resource: resource)
    end

    price_queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      price_queries << payload[:sql] if payload[:sql].include?('FROM "scheduling_service_prices"')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { search(query: 'УЗИ') }

    expect(price_queries.size).to eq(1)
  end

  it 'survives odd text from a model without an error' do
    create_service('МРТ кисти')

    ["'", '"', 'a:b', 'a & b', '(мрт)', '%', "\u0000", '😀', 'я', 'мрт ' * 500, "мрт'; DROP TABLE scheduling_services; --"].each do |query|
      expect(tool.execute(query: query)).not_to start_with('ERROR'), "query #{query.inspect}"
    end
    expect(Scheduling::Service.where(account_id: account.id).count).to eq(1)
  end

  describe 'offset' do
    before { create_service('УЗИ почек') }

    it 'rejects negative, fractional, textual and oversized values with one clear message' do
      ['-1', -1, 1.5, 'abc', '1e3', 10**12, [1], { a: 1 }].each do |offset|
        expect(tool.execute(query: 'узи', offset: offset)).to(start_with('ERROR').and(include('offset must be')), "offset #{offset.inspect}")
      end
    end

    it 'accepts blank, zero, whole numbers and digit strings' do
      [nil, '', 0, '0', 2.0, '3'].each do |offset|
        expect(tool.execute(query: 'узи', offset: offset)).not_to start_with('ERROR'), "offset #{offset.inspect}"
      end
    end

    it 'marks a page past the end as out of range without hiding the total' do
      expect(search(query: 'узи', offset: 50)).to include('page_status' => 'offset_out_of_range', 'total_count' => 1,
                                                          'returned_count' => 0, 'has_more' => false, 'next_offset' => nil)
    end
  end
end
