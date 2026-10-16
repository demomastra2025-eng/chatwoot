# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::OrganizationListStats do
  let(:organization) { create(:organization) }

  def stats_for(*organizations)
    described_class.new(organizations)
  end

  # An account of the organization with `operators` members and `channels` inboxes
  def account_of(organization, operators: 0, channels: 0, **attributes)
    create(:account, organization: organization, **attributes).tap do |account|
      create_list(:user, operators, account: account, role: :administrator)
      create_list(:inbox, channels, account: account)
    end
  end

  # Limits as old data may hold them (a text, a blank): the account form would not save them, the column keeps them
  def raw_limits(account, limits)
    account.update_columns(limits: limits) # rubocop:disable Rails/SkipsModelValidations
    account
  end

  def set_custom(account, **values)
    account.update!(custom_attributes: account.custom_attributes.to_h.merge(values.stringify_keys))
  end

  # Counts the SQL statements a block runs (cached reads and schema lookups do not count) and what kinds of rows they load
  def queries(&)
    statements = []
    subscriber = ->(*, payload) { statements << payload unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    statements
  end

  describe '#for' do
    it 'counts the accounts, the operators and the channels of each organization separately' do
      other = create(:organization)
      account_of(organization, operators: 2, channels: 1)
      account_of(organization, operators: 1, channels: 3)
      account_of(other, operators: 4, channels: 2)
      account_of(nil, operators: 5, channels: 5)

      stats = stats_for(organization, other)

      expect(stats.for(organization).to_h).to eq(accounts: 2, operators: 3, channels: 4)
      expect(stats.for(other).to_h).to eq(accounts: 1, operators: 4, channels: 2)
    end

    it 'gives zeros to an organization without accounts' do
      expect(stats_for(organization).for(organization).to_h).to eq(accounts: 0, operators: 0, channels: 0)
    end

    it 'does not count the members the limit of the account excludes, like the clinic list does' do
      account = account_of(organization, operators: 3, channels: 0)
      set_custom(account, limit_counter_excluded_user_ids: [account.users.first.id, account.users.second.id])
      plain = account_of(organization, operators: 2)

      row = stats_for(organization).for(organization)
      list = SuperAdmin::AccountListStats.new([account, plain])

      expect(row.operators).to eq(3)
      expect(row.operators).to eq(list.operators_used(account) + list.operators_used(plain))
      expect(row.operators).to eq([account, plain].sum { |record| record.countable_users_for_limits.count })
    end

    it 'keeps counting when the list of excluded members is damaged' do
      account = account_of(organization, operators: 2)
      set_custom(account, limit_counter_excluded_user_ids: 'oops')

      expect(stats_for(organization).for(organization).operators).to eq(2)
    end
  end

  describe 'cost' do
    it 'runs the same few grouped queries for 2 and for 30 accounts and loads no account' do
      2.times { account_of(organization, operators: 1, channels: 1) }
      stats_for(organization)
      few = queries { stats_for(organization).for(organization) }

      more = create(:organization)
      30.times { account_of(more, operators: 1, channels: 1) }
      many = queries { stats_for(organization, more).for(more) }

      expect(many.size).to eq(few.size)
      expect(few.size).to be <= 4
      expect((few + many).map { |payload| payload[:name] }).not_to include('Account Load')
      expect((few + many).pluck(:sql)).to all(include('GROUP BY').or(include('EXISTS')))
    end
  end

  describe '#operators_limit' do
    after { GlobalConfig.clear_cache }

    # What the rows of the clinic list say, added up the way the card of an organization adds them up
    def expected_limit(*accounts)
      list = SuperAdmin::AccountListStats.new(accounts)
      rows = accounts.map { |account| list.for(account) }
      rows.sum(&:operators_limit) if rows.any? && rows.none?(&:operators_unlimited?)
    end

    it 'is nil for an organization without accounts' do
      expect(stats_for(organization).operators_limit(organization)).to be_nil
    end

    it 'adds up the limits of the accounts' do
      accounts = [account_of(organization, limits: { 'agents' => 5 }), account_of(organization, limits: { 'agents' => 2 })]

      expect(stats_for(organization).operators_limit(organization)).to eq(7)
      expect(stats_for(organization).operators_limit(organization)).to eq(expected_limit(*accounts))
    end

    it 'is nil when an account has no limit' do
      account_of(organization, limits: { 'agents' => 5 })
      account_of(organization)
      GlobalConfig.clear_cache

      expect(stats_for(organization).operators_limit(organization)).to be_nil
    end

    it 'is nil when an account has no limit in the sense of the plans (the "no limit" number)' do
      account_of(organization, limits: { 'agents' => 5 })
      account_of(organization, limits: { 'agents' => ChatwootApp.max_limit })

      expect(stats_for(organization).operators_limit(organization)).to be_nil
    end

    it 'reads the limits the way the clinic list does: subscribed quantity, then the limit of the account, then the installation' do
      create(:installation_config, name: 'ACCOUNT_AGENTS_LIMIT', value: 7, locked: false)
      GlobalConfig.clear_cache
      accounts = [
        account_of(organization, limits: { 'agents' => 12 }),
        raw_limits(account_of(organization), { 'agents' => '3' }),
        account_of(organization, limits: { 'agents' => 0 }),
        raw_limits(account_of(organization), { 'agents' => ' ' }),
        account_of(organization),
        account_of(organization, limits: { 'agents' => 2 }).tap { |account| set_custom(account, subscribed_quantity: 25) },
        account_of(organization, limits: { 'agents' => 2 }).tap { |account| set_custom(account, subscribed_quantity: '4') },
        account_of(organization, limits: { 'agents' => 2 }).tap { |account| set_custom(account, subscribed_quantity: '') }
      ]

      limit = stats_for(organization).operators_limit(organization)

      expect(limit).to eq(12 + 3 + 0 + 7 + 7 + 25 + 4 + 2)
      expect(limit).to eq(expected_limit(*accounts))
    end

    it 'treats text that is not a number as 0, like to_i' do
      accounts = [raw_limits(account_of(organization), { 'agents' => 'many' }), raw_limits(account_of(organization), { 'agents' => '6 seats' })]

      expect(stats_for(organization).operators_limit(organization)).to eq(6)
      expect(stats_for(organization).operators_limit(organization)).to eq(expected_limit(*accounts))
    end

    it 'keeps the organizations apart' do
      other = create(:organization)
      account_of(organization, limits: { 'agents' => 5 })
      account_of(other, limits: { 'agents' => 9 })
      account_of(other)
      GlobalConfig.clear_cache

      stats = stats_for(organization, other)

      expect(stats.operators_limit(organization)).to eq(5)
      expect(stats.operators_limit(other)).to be_nil
    end

    it 'is not read until it is asked for' do
      account_of(organization, limits: { 'agents' => 5 })

      statements = queries { stats_for(organization).for(organization) }

      expect(statements.pluck(:sql).grep(/subscribed_quantity/)).to be_empty
    end
  end
end
