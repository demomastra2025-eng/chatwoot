require 'rails_helper'

RSpec.describe AutomationRules::ContactOptionsService do
  let(:account) { create(:account) }

  def service(**params)
    described_class.new(account: account, **params).perform
  end

  def names(result)
    result[:payload].pluck(:name)
  end

  describe 'search' do
    it 'finds contacts of the account by a part of the name, in any letter case' do
      create(:contact, account: account, name: 'Айгерим Нурлан')
      create(:contact, account: account, name: 'Берик Сатыбалды')
      create(:contact, account: create(:account), name: 'Айгуль Чужая')

      expect(names(service(query: 'айгер'))).to eq(['Айгерим Нурлан'])
      expect(names(service(query: 'АЙ'))).to eq(['Айгерим Нурлан'])
    end

    it 'finds a contact by its phone number typed in any format' do
      create(:contact, account: account, name: 'Phone Owner', phone_number: '+77011234567')
      create(:contact, account: account, name: 'Somebody', phone_number: '+77025550000')

      expect(names(service(query: '+7 (701) 123-45-67'))).to eq(['Phone Owner'])
      expect(names(service(query: '77011234567'))).to eq(['Phone Owner'])
      expect(names(service(query: '1234567'))).to eq(['Phone Owner'])
    end

    it 'describes every option with its name, phone number and e-mail' do
      contact = create(:contact, account: account, name: 'With Phone', phone_number: '+77011234567', email: 'with@example.com')
      bare = create(:contact, account: account, name: 'Bare', phone_number: nil, email: nil)

      payload = service[:payload]

      expect(payload).to include(
        { id: contact.id, name: 'With Phone', phone_number: '+77011234567', email: 'with@example.com' },
        { id: bare.id, name: 'Bare', phone_number: nil, email: nil }
      )
    end

    it 'lists the most recently active contacts first when nothing is typed' do
      old = create(:contact, account: account, name: 'Old', last_activity_at: 3.days.ago)
      recent = create(:contact, account: account, name: 'Recent', last_activity_at: 1.minute.ago)
      never = create(:contact, account: account, name: 'Never', last_activity_at: nil)

      expect(service[:payload].pluck(:id)).to eq([recent.id, old.id, never.id])
      expect(service(query: '   ')[:payload].pluck(:id)).to eq([recent.id, old.id, never.id])
    end

    it 'pages through the contacts and tells when there are more' do
      total = described_class::PER_PAGE + 5
      total.times { |index| create(:contact, account: account, name: format('Paged %03d', index), last_activity_at: index.minutes.ago) }

      first = service(query: 'Paged')
      second = service(query: 'Paged', page: 2)

      expect(first[:payload].size).to eq(described_class::PER_PAGE)
      expect(first[:meta]).to eq(has_more: true, current_page: 1)
      expect(second[:payload].size).to eq(5)
      expect(second[:meta]).to eq(has_more: false, current_page: 2)
      expect((first[:payload] + second[:payload]).pluck(:id).uniq.size).to eq(total)
    end

    it 'treats a bad page number as the first page' do
      create(:contact, account: account, name: 'Only One')

      expect(names(service(query: 'Only', page: 'x'))).to eq(['Only One'])
      expect(names(service(query: 'Only', page: -4))).to eq(['Only One'])
    end
  end

  describe 'lookup by ids' do
    it 'returns the named contacts of the account and nothing for deleted or foreign ids' do
      first = create(:contact, account: account, name: 'First')
      second = create(:contact, account: account, name: 'Second')
      gone = create(:contact, account: account, name: 'Gone')
      gone_id = gone.id
      gone.destroy!
      foreign = create(:contact, account: create(:account), name: 'Foreign')

      result = service(ids: [first.id, second.id.to_s, gone_id, foreign.id, 'junk'])

      expect(result[:payload].pluck(:id)).to eq([first.id, second.id])
      expect(result[:meta][:has_more]).to be(false)
    end

    it 'prefers the ids over the search text' do
      listed = create(:contact, account: account, name: 'Listed')
      create(:contact, account: account, name: 'Matches text')

      expect(names(service(ids: [listed.id], query: 'Matches'))).to eq(['Listed'])
    end

    it 'answers at most LOOKUP_LIMIT ids at a time' do
      contacts = Array.new(described_class::LOOKUP_LIMIT + 3) { |index| create(:contact, account: account, name: "Lookup #{index}") }

      result = service(ids: contacts.map(&:id))

      expect(result[:payload].size).to eq(described_class::LOOKUP_LIMIT)
    end
  end
end
