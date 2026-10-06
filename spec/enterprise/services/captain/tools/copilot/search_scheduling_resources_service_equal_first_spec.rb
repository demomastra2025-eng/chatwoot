require 'rails_helper'

# A full name match leads and may be confident. An equal specialty leads other partial matches but still needs the name
# confirmed. All data is synthetic.
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

  def marked_ids(payload)
    payload['resources'].select { |row| row['exact_name_match'] }.pluck('id')
  end

  context 'when the equal specialty sorts after other names' do
    let!(:orthopedist) { create_resource('Абдуллин Тест', 'Хирург-ортопед') }
    let!(:children) { create_resource('Бектуров Тест', 'Детский хирург') }
    let!(:surgeon) { create_resource('Яковлев Тест', 'Хирург') }

    %w[all specialty].each do |search_by|
      it "puts the equal specialty first without treating it as a name (search_by #{search_by})" do
        payload = search(query: 'хирург', search_by: search_by)

        expect(payload['total_count']).to eq(3)
        expect(payload['resources'].pluck('id')).to eq([surgeon.id, orthopedist.id, children.id])
        expect(payload).to include('search_status' => 'ambiguous', 'ambiguous' => true, 'exact_name_matches' => 0)
        expect(payload['instruction']).to include('exact name')
        expect(marked_ids(payload)).to be_empty
        expect(payload['resources'].select { |row| row['best_match'] }.pluck('id')).to eq([surgeon.id])
      end
    end

    it 'marks nothing and asks for confirmation when no resource is equal to the request' do
      surgeon.update!(specialty: 'Хирург общей практики')

      payload = search(query: 'хирург', search_by: 'specialty')

      expect(payload).to include('search_status' => 'ambiguous', 'exact_name_matches' => 0)
      expect(marked_ids(payload)).to be_empty
      expect(payload['resources'].none? { |row| row['best_match'] }).to be(true)
    end

    it 'keeps the alphabetical order of the pages after the equal resource' do
      payload = search(query: 'хирург', search_by: 'specialty', limit: 2)

      expect(payload['resources'].pluck('id')).to eq([surgeon.id, orthopedist.id])
      expect(payload).to include('has_more' => true, 'next_offset' => 2)
      expect(search(query: 'хирург', search_by: 'specialty', limit: 2, offset: 2)['resources'].pluck('id')).to eq([children.id])
    end
  end

  it 'puts the equal full name first when longer names sort before it' do
    create_resource('Аа Асланов Мурад')
    equal = create_resource('Асланов Мурад')
    create_resource('Асланов Мурад Тестович')

    payload = search(query: 'Асланов Мурад', search_by: 'name')

    expect(payload['total_count']).to eq(3)
    expect(payload['resources'].first['id']).to eq(equal.id)
    expect(payload).to include('search_status' => 'candidate', 'exact_name_matches' => 1)
    expect(marked_ids(payload)).to eq([equal.id])
  end

  it 'never reports a candidate whose equal resource is not the marked first row' do
    create_resource('Иванов')
    create_resource('Иванов И.И.')
    create_resource('Иванов И.П.')

    ['Иванов И.', 'Иванов И.И.', 'Иванов'].each do |query|
      payload = search(query: query, search_by: 'name')
      next unless payload['search_status'] == 'candidate'

      expect(payload['resources'].first['exact_name_match']).to be(true)
      expect(marked_ids(payload).size).to eq(1)
    end
  end

  it 'lists two equal names first and asks which one is meant' do
    first = create_resource('Иванов Иван', 'Терапевт')
    second = create_resource('Иванов Иван', 'Хирург')
    create_resource('Иванов Иван Петрович')
    create_resource('Аа Иванов Иван Сергеевич')

    payload = search(query: 'Иванов Иван', search_by: 'name')

    expect(payload['resources'].first(2).pluck('id')).to contain_exactly(first.id, second.id)
    expect(payload).to include('search_status' => 'ambiguous', 'exact_name_matches' => 2)
    expect(payload['instruction']).to include('exactly this name')
    expect(marked_ids(payload)).to contain_exactly(first.id, second.id)
  end

  it 'does not mark a row when the request is empty' do
    create_resource('Иванов Иван')

    payload = search

    expect(payload['search_status']).to eq('candidates')
    expect(marked_ids(payload)).to be_empty
  end
end
