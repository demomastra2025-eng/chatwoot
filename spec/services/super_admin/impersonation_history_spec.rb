# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::ImpersonationHistory do
  let(:super_admin) { create(:super_admin, name: 'Айгерим Админ') }
  let(:account) { create(:account, name: 'Клиника «Алатау»') }
  let(:operator) { create(:user, name: 'Иван Петров', email: 'ivan@example.test', account: account) }

  def enter(account:, user:, actor: super_admin, at: Time.current)
    audit = SuperAdmin::AccountAudit.record(
      account: account, actor: actor, action: 'impersonate',
      changes: { 'impersonated_user_id' => user.id, 'impersonated_email' => user.email }
    )
    audit.update_columns(created_at: at) # rubocop:disable Rails/SkipsModelValidations
    audit
  end

  describe '.for_account' do
    it 'lists the entries into the account, newest first, with who entered and as whom' do
      enter(account: account, user: operator, at: 2.days.ago)
      enter(account: account, user: operator, at: 1.hour.ago)

      entries = described_class.for_account(account)

      expect(entries.size).to eq(2)
      expect(entries.first.at).to be > entries.last.at
      expect(entries.first).to have_attributes(
        actor_name: 'Айгерим Админ', actor_id: super_admin.id, user_label: 'Иван Петров · ivan@example.test',
        user_id: operator.id, user_known: true, account_name: 'Клиника «Алатау»', account_id: account.id
      )
    end

    it 'keeps the last twenty' do
      25.times { |index| enter(account: account, user: operator, at: index.minutes.ago) }

      expect(described_class.for_account(account).size).to eq(described_class::LIMIT)
    end

    it 'leaves out other accounts and other actions' do
      other = create(:account)
      enter(account: other, user: create(:user, account: other))
      SuperAdmin::AccountAudit.record(account: account, actor: super_admin, action: 'extend_trial', changes: {})

      expect(described_class.for_account(account)).to be_empty
    end

    it 'still names a user who has been deleted since, by the e-mail the entry kept' do
      enter(account: account, user: operator)
      operator.account_users.destroy_all
      operator.destroy!

      entry = described_class.for_account(account).first

      expect(entry).to have_attributes(user_label: 'ivan@example.test', user_known: false)
    end

    it 'names an actor who has been deleted by his number' do
      enter(account: account, user: operator)
      super_admin.destroy!

      entry = described_class.for_account(account).first

      expect(entry.actor_name).to be_nil
      expect(entry.actor_id).to eq(super_admin.id)
    end

    it 'is empty when nobody entered the account' do
      expect(described_class.for_account(account)).to eq([])
    end

    it 'costs the same number of queries for one entry and for many' do
      enter(account: account, user: operator)
      few = sql_queries_during { described_class.for_account(account) }.size
      5.times { enter(account: account, user: create(:user, account: account), actor: create(:super_admin)) }
      many = sql_queries_during { described_class.for_account(account) }.size

      expect(many).to eq(few)
    end
  end

  describe '.for_user' do
    let(:second_account) { create(:account, name: 'Сезим') }

    before { create(:account_user, user: operator, account: second_account) }

    it 'lists the entries as this user in each of his accounts' do
      enter(account: account, user: operator, at: 3.hours.ago)
      enter(account: second_account, user: operator, at: 1.hour.ago)

      entries = described_class.for_user(operator)

      expect(entries.map(&:account_name)).to eq(['Сезим', 'Клиника «Алатау»'])
      expect(entries.map(&:user_id).uniq).to eq([operator.id])
    end

    it 'leaves out the entries as other users of the same account' do
      colleague = create(:user, account: account)
      enter(account: account, user: colleague)

      expect(described_class.for_user(operator)).to be_empty
    end

    it 'is empty for a user who belongs to no account' do
      expect(described_class.for_user(create(:user))).to eq([])
    end
  end
end
