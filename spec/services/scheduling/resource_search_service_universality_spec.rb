require 'rails_helper'

# Synthetic catalogue. "Асланов Мурад" and "Лю-Фу Ольга" are the only names taken from the production audit.
RSpec.describe Scheduling::ResourceSearchService do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }

  def create_resource(name, **attributes)
    create(:scheduling_resource, account: account, name: name, **attributes)
  end

  def perform(**attributes)
    described_class.new(account: account, **attributes).perform
  end

  def ids(**attributes)
    perform(**attributes)[:resources].pluck(:id)
  end

  describe 'names' do
    let!(:aslanov) { create_resource('Асланов Мурад Тестович', specialty: 'Хирург') }
    let!(:liu_fu) { create_resource('Лю Фу Ольга Тестовна', specialty: 'Терапевт') }
    let!(:semen) { create_resource('Семён Образцов', specialty: 'Невролог') }

    it 'finds a person whatever the order, case and spacing of the typed words' do
      expect(ids(query: 'Асланов Мурад', search_by: 'name')).to eq([aslanov.id])
      expect(ids(query: 'Мурад Асланов', search_by: 'name')).to eq([aslanov.id])
      expect(ids(query: '  мурад    АСЛАНОВ ', search_by: 'all')).to eq([aslanov.id])
    end

    it 'splits a hyphen into separate words in both directions' do
      hyphenated = create_resource('Ким-Ли Анна', specialty: 'Терапевт')

      expect(ids(query: 'Лю-Фу Ольга')).to eq([liu_fu.id])
      expect(ids(query: 'Ольга Лю Фу')).to eq([liu_fu.id])
      expect(ids(query: 'Ким Ли Анна')).to eq([hyphenated.id])
      expect(ids(query: 'ким-ли')).to eq([hyphenated.id])
    end

    it 'treats ё and е as the same letter' do
      expect(ids(query: 'семен образцов')).to eq([semen.id])
      expect(ids(query: 'СЕМЁН')).to eq([semen.id])
    end

    it 'combines name words with the stored specialty in the all mode only' do
      expect(ids(query: 'хирург асланов', search_by: 'all')).to eq([aslanov.id])
      expect(ids(query: 'хирург асланов', search_by: 'name')).to be_empty
      expect(ids(query: 'хирург', search_by: 'specialty')).to eq([aslanov.id])
    end

    it 'returns nothing when one of the typed words is absent instead of guessing another person' do
      expect(ids(query: 'Асланов Мурад Другой')).to be_empty
    end

    it 'treats LIKE wildcards, quotes and odd text as plain text' do
      ["'", '"', 'a:b', 'a & b', '(х)', '%', '_', '%%', '\\', '😀', "\u0000", 'х' * 5000, "\xFF\xFEх".dup.force_encoding('UTF-8')].each do |query|
        expect { perform(query: query) }.not_to raise_error
      end
      expect(ids(query: '%')).to be_empty
      expect(ids(query: '_')).to be_empty
      expect(perform(query: "\u0000")[:total_count]).to eq(3)
    end

    it 'never returns another account even when the names are identical' do
      create(:scheduling_resource, account: other_account, name: 'Асланов Мурад Тестович', specialty: 'Хирург')

      expect(perform(query: 'Асланов Мурад')[:total_count]).to eq(1)
      expect(perform(query: 'Асланов Мурад')[:resources].pluck(:account_id)).to eq([account.id])
    end
  end

  describe 'diagnostic rooms, shared rooms and several directions' do
    let(:room_attributes) { { 'medelement_cabinets' => [{ 'cabinetCode' => 'room-1', 'cabinetName' => 'Кабинет МРТ' }] } }
    let!(:diagnostic_room) { create_resource('Кабинет МРТ 1', specialty: nil, custom_attributes: room_attributes) }
    let!(:first_specialist) do
      create_resource('Первый Специалист', specialty: 'Кардиолог',
                                           custom_attributes: room_attributes.merge('medelement_specialist_code' => 'spec-1'))
    end
    let!(:second_specialist) do
      create_resource('Второй Специалист', specialty: 'Невролог',
                                           custom_attributes: room_attributes.merge('medelement_specialist_code' => 'spec-2'))
    end

    it 'finds a diagnostic room without a doctor by its name but never by an inferred direction' do
      expect(ids(query: 'кабинет мрт', search_by: 'name')).to eq([diagnostic_room.id])
      expect(ids(query: 'мрт', search_by: 'specialty')).to be_empty
      expect(perform(query: 'мрт', search_by: 'specialty')[:total_count]).to eq(0)
    end

    it 'keeps two specialists that share one room as two separate results' do
      expect(ids(query: 'специалист')).to eq([second_specialist.id, first_specialist.id])
      expect(ids(query: 'кардиолог')).to eq([first_specialist.id])
      expect(ids(query: 'невролог')).to eq([second_specialist.id])
    end
  end

  describe 'service links' do
    let(:service_record) { create(:scheduling_service, account: account, name: 'МРТ кисти') }
    let!(:linked) { create_resource('Связанный Специалист') }
    let!(:inactive_link) { create_resource('Неактивная Связь') }

    before do
      create_resource('Без Связи')
      create(:scheduling_service_price, account: account, service: service_record, resource: linked, active: true)
      create(:scheduling_service_price, account: account, service: service_record, resource: inactive_link, active: false)
    end

    it 'keeps only resources with an active recorded link and ignores missing or inactive ones' do
      expect(ids(service_id: service_record.id)).to eq([linked.id])
      expect(ids(service_id: service_record.id, query: 'связь')).to be_empty
    end

    it 'never reaches a resource through a price row of another account' do
      other_service = create(:scheduling_service, account: other_account, name: 'МРТ кисти')
      other_resource = create(:scheduling_resource, account: other_account, name: 'Связанный Специалист')
      create(:scheduling_service_price, account: other_account, service: other_service, resource: other_resource, active: true)

      expect(ids(service_id: other_service.id)).to be_empty
      expect(perform(service_id: service_record.id)[:resources].pluck(:account_id)).to eq([account.id])
    end

    it 'reports an incomplete import (no links at all) as an empty result, not as an error' do
      lonely_service = create(:scheduling_service, account: account, name: 'Услуга без связей')

      expect(perform(service_id: lonely_service.id)).to include(total_count: 0, resources: [], has_more: false, next_offset: nil)
    end
  end

  describe 'pagination' do
    before { 7.times { |index| create_resource(format('Специалист %02d', index)) } }

    it 'walks every page exactly once with correct has_more and next_offset at the edges' do
      pages = [0, 3, 6].map { |offset| perform(limit: 3, offset: offset) }

      expect(pages.map { |page| page[:returned_count] }).to eq([3, 3, 1])
      expect(pages.map { |page| page[:has_more] }).to eq([true, true, false])
      expect(pages.map { |page| page[:next_offset] }).to eq([3, 6, nil])
      expect(pages.flat_map { |page| page[:resources].pluck(:id) }).to eq(account.scheduling_resources.order(:name, :id).pluck(:id))
      expect(pages.map { |page| page[:total_count] }.uniq).to eq([7])
    end

    it 'has no next page when the last page is exactly full' do
      page = perform(limit: 7)

      expect(page).to include(returned_count: 7, has_more: false, next_offset: nil)
    end

    it 'returns an empty page when the offset is at or beyond the end' do
      expect(perform(limit: 3, offset: 7)).to include(returned_count: 0, has_more: false, next_offset: nil, total_count: 7)
      expect(perform(limit: 3, offset: 700)).to include(returned_count: 0, has_more: false, total_count: 7)
    end

    it 'clamps invalid offsets and limits instead of failing' do
      expect(perform(offset: -5)[:offset]).to eq(0)
      expect(perform(offset: 'abc')[:offset]).to eq(0)
      expect(perform(offset: nil)[:offset]).to eq(0)
      expect(perform(offset: 10**30)).to include(returned_count: 0, has_more: false)
      expect(perform(limit: 100_000)[:returned_count]).to eq(7)
      expect(perform(limit: -3)[:returned_count]).to eq(7)
      expect(perform(limit: 0)[:returned_count]).to eq(7)
    end

    it 'caps the page size at the documented maximum' do
      50.times { |index| create_resource(format('Добавленный %02d', index)) }

      expect(perform(limit: 1000)).to include(returned_count: described_class::MAX_LIMIT, has_more: true, next_offset: 50)
    end

    it 'orders resources with the same name by id on every call' do
      first = create_resource('Одинаковое Имя')
      second = create_resource('Одинаковое Имя')

      3.times { expect(ids(query: 'одинаковое имя')).to eq([first.id, second.id]) }
    end
  end

  describe 'activity' do
    it 'leaves inactive and archived resources out of the default result' do
      create_resource('Неактивный Врач', active: false)
      create_resource('Архивный Врач', custom_attributes: { Scheduling::Resource::DELETED_FROM_SCHEDULING_KEY => true })
      active = create_resource('Активный Врач')

      expect(ids(query: 'врач')).to eq([active.id])
      expect(perform(query: 'врач', include_inactive: true)[:total_count]).to eq(2)
    end
  end
end
