# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::OrganizationAccountsPage do
  let(:organization) { create(:organization) }

  def block(page: nil, search: nil)
    described_class.new(organization, page: page, search: search)
  end

  # Accounts named «Филиал 01», «Филиал 02», ... so that the order by name is the order of creation
  def linked_accounts(count)
    Array.new(count) { |index| create(:account, name: format('Филиал %<number>02d', number: index + 1), organization: organization) }
  end

  def queries(&)
    statements = []
    subscriber = ->(*, payload) { statements << payload unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    statements
  end

  describe 'the linked accounts' do
    it 'come 25 to a page, by name' do
      accounts = linked_accounts(30)

      expect(block.accounts.map(&:id)).to eq(accounts.first(25).map(&:id))
      expect(block(page: '2').accounts.map(&:id)).to eq(accounts.last(5).map(&:id))
      expect(block.paginated?).to be(true)
      expect(block.accounts.total_pages).to eq(2)
    end

    it 'do not need a pager for one page' do
      linked_accounts(25)

      expect(block.paginated?).to be(false)
      expect(block.rows.size).to eq(25)
    end

    it 'show the last page for a page past the end and the first one for nonsense' do
      accounts = linked_accounts(30)

      expect(block(page: '99').accounts.map(&:id)).to eq(accounts.last(5).map(&:id))
      ['0', '-3', 'abc', '', nil, %w[1 2], { 'a' => 'b' }, '99999999999999999999'].each do |wrong|
        expect(block(page: wrong).accounts.current_page).to be_between(1, 2)
      end
      expect(block(page: 'abc').accounts.map(&:id)).to eq(accounts.first(25).map(&:id))
    end

    it 'are empty, on the first page, for an organization without accounts' do
      expect(block(page: '5').rows).to be_empty
      expect(block.paginated?).to be(false)
    end

    it 'carry the numbers of their rows' do
      account = create(:account, name: 'Филиал', organization: organization)
      create_list(:user, 2, account: account, role: :administrator)
      create(:inbox, account: account)

      (listed, row), = block.rows

      expect(listed).to eq(account)
      expect(row).to have_attributes(operators_used: 2, channels: 1)
    end
  end

  describe 'the totals' do
    after { GlobalConfig.clear_cache }

    it 'add up ALL the linked accounts, whatever page is shown' do
      accounts = linked_accounts(30)
      accounts.each do |account|
        account.update!(limits: { 'agents' => 2 })
        create(:user, account: account, role: :administrator)
      end
      accounts.first(10).each { |account| create(:inbox, account: account) }
      create(:account, name: 'Чужой', organization: create(:organization), limits: { 'agents' => 100 })

      [block, block(page: '2')].each do |page|
        expect(page.totals).to have_attributes(accounts: 30, operators_used: 30, operators_limit: 60, channels: 10)
      end
    end

    it 'have no limit when an account has none' do
      linked_accounts(2).first.update!(limits: { 'agents' => 2 })
      GlobalConfig.clear_cache

      expect(block.totals.operators_limit).to be_nil
    end
  end

  describe 'the accounts to link' do
    def free_account(name)
      create(:account, name: name)
    end

    it 'are the accounts without an organization only, by name' do
      later = free_account('Яблоко')
      first = free_account('Абрикос')
      create(:account, name: 'Занят', organization: create(:organization))
      create(:account, name: 'Мой', organization: organization)

      expect(block.candidates).to eq([["Абрикос · ##{first.id}", first.id], ["Яблоко · ##{later.id}", later.id]])
      expect(block.more_candidates?).to be(false)
      expect(block.free_accounts?).to be(true)
    end

    it 'are at most 20, and say when there are more' do
      Array.new(23) { |index| free_account(format('Свободный %<number>02d', number: index + 1)) }

      expect(block.candidates.size).to eq(20)
      expect(block.candidates.first.first).to start_with('Свободный 01')
      expect(block.candidates.last.first).to start_with('Свободный 20')
      expect(block.more_candidates?).to be(true)
    end

    it 'do not say there are more at exactly 20' do
      Array.new(20) { |index| free_account("Свободный #{index}") }

      expect(block.candidates.size).to eq(20)
      expect(block.more_candidates?).to be(false)
    end

    it 'are found by a part of the name, in any case' do
      match = free_account('Clinic Alatau')
      free_account('Clinic Nur')

      expect(block(search: 'alatau').candidates).to eq([["Clinic Alatau · ##{match.id}", match.id]])
      expect(block(search: '  ALATAU  ').candidates.map(&:last)).to eq([match.id])
      expect(block(search: '  ALATAU  ').search).to eq('ALATAU')
    end

    it 'are found by a part of a Russian name' do
      match = free_account('Клиника Алатау')
      free_account('Клиника Нур')

      expect(block(search: 'Алатау').candidates.map(&:last)).to eq([match.id])
    end

    it 'are found by the number, with or without the #' do
      target = free_account('Один')
      free_account('Два')

      expect(block(search: "##{target.id}").candidates.map(&:last)).to eq([target.id])
      expect(block(search: target.id.to_s).candidates.map(&:last)).to include(target.id)
    end

    it 'take the characters of a LIKE pattern for plain text' do
      plain = free_account('Филиал 50% скидка')
      free_account('Филиал 500')

      expect(block(search: '50%').candidates.map(&:last)).to eq([plain.id])
      expect(block(search: '_').candidates).to be_empty
    end

    it 'cut the search to 100 characters and ignore anything that is not text' do
      free_account('Один')

      expect(block(search: 'а' * 300).search.length).to eq(100)
      expect(block(search: %w[a b]).search).to eq('')
      expect(block(search: nil).candidates.size).to eq(1)
    end

    it 'are empty when nothing matches, while free accounts exist' do
      free_account('Один')

      expect(block(search: 'нет такого').candidates).to be_empty
      expect(block(search: 'нет такого').free_accounts?).to be(true)
    end

    it 'say there is nothing to link when every account has an organization' do
      create(:account, organization: organization)

      expect(block.free_accounts?).to be(false)
      expect(block.candidates).to be_empty
    end
  end

  describe 'cost' do
    # Everything the card asks of the block
    def draw(page)
      [page.rows, page.totals, page.totals.operators_limit, page.candidates, page.more_candidates?, page.free_accounts?]
    end

    it 'does not grow with the number of linked accounts or of free accounts' do
      linked_accounts(26)
      Array.new(22) { |index| create(:account, name: "Свободный #{index}") }
      draw(block)
      few = queries { draw(block) }

      linked_accounts(40)
      Array.new(40) { |index| create(:account, name: "Ещё свободный #{index}") }
      many = queries { draw(block) }

      expect(many.size).to eq(few.size)
    end
  end
end
