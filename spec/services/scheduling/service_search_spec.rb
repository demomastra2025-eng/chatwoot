require 'rails_helper'

# All data below is synthetic. The three strings from the production audit ("МРТ кисти" among them) are the only
# real-world phrases; everything else only mirrors the shape of a clinic catalogue.
RSpec.describe Scheduling::ServiceSearch do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }

  def create_service(name, **attributes)
    create(:scheduling_service, account: account, name: name, **attributes)
  end

  def search(query, scope: account.scheduling_services.active)
    described_class.new(scope: scope, query: query)
  end

  def names(query, **)
    search(query, **).call.pluck(:name)
  end

  describe 'Russian word forms' do
    before do
      create_service('МРТ кисть')
      create_service('МРТ кистей двух рук')
      create_service('МРТ кисти левой')
      create_service('УЗИ почек')
    end

    it 'finds every form of the same word and nothing else' do
      payload = search('МРТ кисти')

      expect(payload.call.pluck(:name)).to contain_exactly('МРТ кисть', 'МРТ кистей двух рук', 'МРТ кисти левой')
      expect(payload.match_kind).to eq('all_concepts')
    end

    it 'does not depend on the case or on the order of the query words' do
      expect(names('кисти МРТ')).to match_array(names('мрт КИСТИ'))
      expect(names('кисти МРТ').size).to eq(3)
    end

    it 'keeps matching a word prefix typed by a person' do
      create_service('Консультация терапевта')
      create_service('Dental cleaning')

      expect(names('консульт')).to eq(['Консультация терапевта'])
      expect(names('dent')).to eq(['Dental cleaning'])
    end
  end

  describe 'ranking before the page limit' do
    it 'puts a name match above category matches that sort earlier alphabetically' do
      60.times { |index| create_service("Анализ #{index}", category: 'МРТ кисти') }
      target = create_service('МРТ Кисть левая')

      payload = search('МРТ кисти').call.limit(1).to_a

      expect(payload).to eq([target])
    end

    it 'ranks the exact name first, then the phrase in the name, then all words in the name, then metadata' do
      metadata_only = create_service('Анализ А', category: 'МРТ кисти')
      words_in_name = create_service('Кисть МРТ дополнительно')
      phrase_in_name = create_service('МРТ кисть левая')
      exact = create_service('МРТ кисть')

      expect(search('мрт кисть').call.to_a).to eq([exact, phrase_in_name, words_in_name, metadata_only])
    end

    it 'keeps every variant reachable by paging even when one page cannot hold them' do
      60.times { |index| create_service(format('МРТ Кисть вариант %02d', index)) }

      relation = search('МРТ кисти').call
      pages = relation.count.times.each_slice(25).map { |ids| relation.offset(ids.first).limit(25).pluck(:id) }

      expect(pages.flatten).to match_array(account.scheduling_services.where('name LIKE ?', 'МРТ Кисть%').pluck(:id))
      expect(pages.flatten.uniq.size).to eq(60)
    end
  end

  describe 'close medical names' do
    it 'prefers УЗИ малого таза for its own phrase and still offers the longer name' do
      long_name = create_service('УЗИ органов малого таза')
      short_name = create_service('УЗИ малого таза')

      expect(search('УЗИ малого таза').call.to_a).to eq([short_name, long_name])
    end

    it 'labels a longer query that no name fully covers as partial and ranks the closest names first' do
      closest = create_service('УЗИ малого таза')
      create_service('УЗИ органов брюшной полости')
      create_service('УЗИ почек')

      payload = search('УЗИ органов малого таза')

      expect(payload.call.first).to eq(closest)
      expect(payload.match_kind).to eq('partial')
    end

    it 'returns the plain ЭКГ before ЭКГ с нагрузкой and finds the loaded one by its extra word' do
      loaded = create_service('ЭКГ с нагрузкой')
      plain = create_service('ЭКГ')

      expect(search('ЭКГ').call.to_a).to eq([plain, loaded])
      expect(search('ЭКГ с нагрузкой').call.to_a).to eq([loaded])
      expect(search('ЭКГ').exact_name_count).to eq(1)
    end

    it 'ignores prepositions so that a natural phrase finds the catalogue name' do
      create_service('УЗИ беременных')

      expect(names('УЗИ для беременных')).to eq(['УЗИ беременных'])
    end
  end

  describe 'spelling variants' do
    it 'treats ё and е as the same letter on both sides' do
      create_service('Приём терапевта')
      create_service('Осмотр Семена')

      expect(names('прием терапевта')).to eq(['Приём терапевта'])
      expect(names('ПРИЁМ терапевта')).to eq(['Приём терапевта'])
      expect(names('осмотр семён')).to eq(['Осмотр Семена'])
    end

    it 'reads a Latin look-alike letter inside a Cyrillic word as Cyrillic' do
      create_service('МРТ Кисть')

      expect(names('MРТ кисти')).to eq(['МРТ Кисть'])
    end

    it 'finds a service by its alias and by category or direction words' do
      create_service('Исследование А', custom_attributes: { 'aliases' => ['магнитно резонансная томография головы'] })
      create_service('Исследование Б', category: 'Диагностика', direction: 'Неврология')

      expect(names('МРТ головы')).to eq(['Исследование А'])
      expect(names('неврология')).to eq(['Исследование Б'])
    end
  end

  describe 'input safety' do
    let(:odd_queries) do
      ["'", '"', 'a:b', 'a & b', '(мрт)', '!мрт', 'мрт | узи', ':*', '<->', '\\', '%', '_', '%%%', "мрт'; DROP TABLE scheduling_services; --",
       '😀', "мрт\u0000кисти", "\u0000", "мрт\n\tкисти", 'мрт ' * 500, 'я', 'a' * 5000, "\xFF\xFEмрт".dup.force_encoding('UTF-8')]
    end

    before { create_service('МРТ Кисть') }

    it 'never raises, never changes data and returns a relation for any text' do
      expect do
        odd_queries.each { |query| search(query).call.to_a }
      end.not_to raise_error
      expect(account.scheduling_services.count).to eq(1)
    end

    it 'treats LIKE wildcards and quotes as plain text instead of matching everything' do
      expect(names('%')).to be_empty
      expect(names('_')).to be_empty
      expect(names("мрт'; DROP TABLE scheduling_services; --")).to eq(['МРТ Кисть'])
    end

    it 'lists the catalogue in a stable order when the text carries no searchable characters' do
      create_service('Б услуга')

      payload = search("\u0000")

      expect(payload.call.pluck(:name)).to eq(['Б услуга', 'МРТ Кисть'])
      expect(payload.match_kind).to eq('listing')
    end
  end

  describe 'scope, activity and ordering' do
    it 'only searches the scope it is given, never another account' do
      create_service('МРТ кисти')
      create(:scheduling_service, account: other_account, name: 'МРТ кисти')
      create(:scheduling_service, account: other_account, name: 'МРТ Кисть правая')

      expect(search('МРТ кисти').call.pluck(:account_id).uniq).to eq([account.id])
      expect(names('МРТ кисти', scope: other_account.scheduling_services.active).size).to eq(2)
    end

    it 'leaves inactive services out unless the caller widens the scope' do
      create_service('МРТ кисть', active: false)
      active = create_service('МРТ кисть левая')

      expect(search('мрт кисть').call.to_a).to eq([active])
      expect(search('мрт кисть', scope: account.scheduling_services).call.size).to eq(2)
    end

    it 'breaks ties by name and then by id so the order never changes between calls' do
      first = create_service('МРТ кисть')
      second = create_service('МРТ кисть')

      3.times { expect(search('мрт кисть').call.to_a).to eq([first, second]) }
    end
  end
end
