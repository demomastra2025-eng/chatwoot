require 'rails_helper'

RSpec.describe SuperAdmin::UserRemovalNotes do
  let(:first_account) { create(:account, name: 'Первый') }
  let(:second_account) { create(:account, name: 'Второй') }

  describe '.for' do
    it 'is empty for an empty list' do
      expect(described_class.for([])).to eq({})
    end

    it 'counts the accounts of each person, and gives the empty note to a person with none' do
      busy = create(:user)
      alone = create(:user)
      create(:account_user, account: first_account, user: busy, role: :agent)
      create(:account_user, account: second_account, user: busy, role: :agent)

      notes = described_class.for([busy, alone])

      expect(notes[busy.id]).to have_attributes(accounts: 2, sole_admin_in: [])
      expect(notes[alone.id]).to have_attributes(accounts: 0, sole_admin_in: [])
    end

    it 'names the accounts where the person is the only administrator, and only those' do
      person = create(:user)
      create(:account_user, account: first_account, user: person, role: :administrator)
      create(:account_user, account: second_account, user: person, role: :administrator)
      create(:account_user, account: second_account, user: create(:user), role: :administrator)

      expect(described_class.for([person])[person.id].sole_admin_in).to eq(['Первый'])
    end

    it 'does not count an operator as an administrator' do
      person = create(:user)
      create(:account_user, account: first_account, user: person, role: :agent)

      expect(described_class.for([person])[person.id].sole_admin_in).to eq([])
    end

    it 'reads the whole list with a few queries, not one set per person' do
      people = create_list(:user, 5)
      people.each { |person| create(:account_user, account: first_account, user: person, role: :administrator) }
      queries = []
      counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('account_users') }

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { described_class.for(people) }

      expect(queries.size).to be <= 3
    end
  end

  describe '.sole_administrator?' do
    it 'is true for the only administrator of an account' do
      person = create(:user)
      membership = create(:account_user, account: first_account, user: person, role: :administrator)

      expect(described_class.sole_administrator?(membership)).to be(true)
    end

    it 'is false when the account has another administrator, and for an operator' do
      person = create(:user)
      membership = create(:account_user, account: first_account, user: person, role: :administrator)
      create(:account_user, account: first_account, user: create(:user), role: :administrator)
      agent = create(:account_user, account: first_account, user: create(:user), role: :agent)

      expect(described_class.sole_administrator?(membership)).to be(false)
      expect(described_class.sole_administrator?(agent)).to be(false)
    end
  end
end
