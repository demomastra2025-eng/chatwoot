# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::GlobalSearch do
  def search(term) = described_class.new(term).call

  def group(result, key) = result.groups.find { |entry| entry.key == key }

  describe 'what is searched for' do
    it 'asks for a term when nothing is typed' do
      result = search('   ')

      expect(result.state).to eq(:blank)
      expect(result.found?).to be(false)
      expect(result.groups.map(&:total)).to eq([0, 0, 0])
    end

    it 'does not run a search for a single character, and says so' do
      create(:account, name: 'Аккаунт А')

      expect(search('а').state).to eq(:too_short)
    end

    it 'takes a number of any length as the number of an account' do
      account = create(:account)

      result = search(account.id.to_s)

      expect(result.state).to eq(:found)
      expect(group(result, :accounts).records).to include(account)
    end

    it 'treats nothing as an empty term' do
      expect(search(nil).state).to eq(:blank)
    end

    it 'cuts a very long term' do
      expect(search('а' * 500).term.length).to eq(described_class::MAX_LENGTH)
    end
  end

  describe 'accounts' do
    let!(:alatau) { create(:account, name: 'Клиника «Алатау»') }
    let!(:other) { create(:account, name: 'Сезим') }

    it 'finds a part of the name without regard to case, Cyrillic letters included' do
      %w[алатау АЛАТАУ Алатау латау].each do |term|
        expect(group(search(term), :accounts).records).to eq([alatau]), "«#{term}» should find the account"
      end
    end

    it 'finds an account by its number, with or without the sign' do
      expect(group(search("##{other.id}"), :accounts).records).to eq([other])
      expect(group(search(other.id.to_s), :accounts).records.first).to eq(other)
    end

    it 'puts the account with the typed number before the names that merely contain it' do
      numbered = create(:account, name: "Филиал #{alatau.id}")

      records = group(search(alatau.id.to_s), :accounts).records

      expect(records).to eq([alatau, numbered])
    end

    it 'searches for the characters of a pattern as they are' do
      percent = create(:account, name: 'Скидка 100%')

      expect(group(search('100%'), :accounts).records).to eq([percent])
      expect(group(search('а_а'), :accounts).records).to be_empty
      expect(group(search('%%'), :accounts).records).to be_empty
    end

    it 'brings the organization of each account with it' do
      organization = create(:organization, name: 'Медицинская группа')
      alatau.update!(organization: organization)

      record = group(search('алатау'), :accounts).records.first

      expect(record.association(:organization)).to be_loaded
      expect(record.organization).to eq(organization)
    end
  end

  describe 'users' do
    let!(:ivan) { create(:user, email: 'Ivan.Petrov@example.test', name: 'Иван Петров') }

    before { create(:user, email: 'maria@example.test', name: 'Мария Сидорова') }

    it 'finds a user by a part of the e-mail without regard to case' do
      expect(group(search('IVAN.petrov'), :users).records).to eq([ivan])
    end

    it 'finds a user by the name, Cyrillic letters included' do
      expect(group(search('ПЕТРОВ'), :users).records).to eq([ivan])
      expect(group(search('иван пет'), :users).records).to eq([ivan])
    end

    it 'finds a super admin as well, and says how many accounts each user is in' do
      admin = create(:super_admin, email: 'petrov.admin@example.test')
      create(:account_user, user: ivan, account: create(:account))
      create(:account_user, user: ivan, account: create(:account))

      users = group(search('petrov'), :users)

      expect(users.records).to contain_exactly(ivan, admin)
      expect(users.extras[ivan.id]).to eq(2)
    end
  end

  describe 'organizations' do
    let!(:organization) { create(:organization, :with_requisites, name: 'Алатау Медикал', legal_name: 'ТОО «Алатау Медикал Групп»') }

    before { create(:organization, :with_requisites, name: 'Сезим') }

    it 'finds an organization by the name or the legal name without regard to case' do
      expect(group(search('алатау'), :organizations).records).to eq([organization])
      expect(group(search('МЕДИКАЛ ГРУПП'), :organizations).records).to eq([organization])
    end

    it 'finds an organization by the БИН, typed whole, in part or with spaces' do
      bin = organization.bin

      expect(group(search(bin), :organizations).records).to eq([organization])
      expect(group(search(bin[0, 6]), :organizations).records).to include(organization)
      expect(group(search("#{bin[0, 4]} #{bin[4, 4]} #{bin[8, 4]}"), :organizations).records).to eq([organization])
    end

    it 'says how many accounts the organization has' do
      create_list(:account, 2, organization: organization)

      expect(group(search('алатау'), :organizations).extras[organization.id]).to eq(2)
    end
  end

  describe 'the size of a group' do
    it 'holds ten records and the total of all of them' do
      create_list(:account, 13) { |account, index| account.update!(name: "Сезим #{index}") }

      accounts = group(search('сезим'), :accounts)

      expect(accounts.records.size).to eq(described_class::PER_GROUP)
      expect(accounts.total).to eq(13)
      expect(accounts.more?).to be(true)
    end

    it 'does not offer more when everything is shown' do
      create_list(:account, 3) { |account, index| account.update!(name: "Сезим #{index}") }

      expect(group(search('сезим'), :accounts).more?).to be(false)
    end
  end

  describe 'the cost' do
    let(:organization) { create(:organization, :with_requisites, name: 'Сезим холдинг') }

    def seed(count)
      count.times do
        number = SecureRandom.hex(3)
        account = create(:account, name: "Сезим филиал #{number}", organization: organization)
        create(:user, email: "sezim#{number}@example.test", name: "Сезим сотрудник #{number}", account: account)
      end
    end

    it 'is the same for one match and for many' do
      seed(1)
      few = sql_queries_during { search('сезим') }
      seed(11)
      many = sql_queries_during { search('сезим') }

      expect(many.size).to eq(few.size), "few:
#{few.join("
")}
many:
#{many.join("
")}"
      expect(many.size).to be <= 10
    end
  end
end
