require 'rails_helper'

RSpec.describe SuperAdmin::AccountListStats do
  def stats_for(*accounts)
    described_class.new(accounts).tap { |stats| accounts.each { |account| stats.for(account) } }
  end

  def storage_key(account)
    "account:#{account.id}:storage_overview_v1"
  end

  # Counts the SQL statements a block runs (cached reads and schema lookups do not count)
  def query_count(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  describe 'operators' do
    let(:account) { create(:account) }

    it 'counts the members of the clinic' do
      create_list(:user, 3, account: account)

      row = stats_for(account).for(account)

      expect(row.operators_used).to eq(3)
    end

    it 'does not count the users the limit excludes' do
      excluded, *others = create_list(:user, 3, account: account)
      account.update!(custom_attributes: account.custom_attributes.merge('limit_counter_excluded_user_ids' => [excluded.id]))

      row = described_class.new([account]).for(account)

      expect(row.operators_used).to eq(others.size)
      expect(row.operators_used).to eq(account.countable_users_for_limits.count)
    end

    describe 'the limit' do
      # the installation limit is cached in Redis for a day; do not leak it into other examples
      after { GlobalConfig.clear_cache }

      def limit_of(account)
        described_class.new([account]).operators_limit(account)
      end

      def expected_limit(account)
        metadata = account.agent_limit_metadata
        metadata[:unlimited] ? nil : metadata[:value].to_i
      end

      it 'is the limit of the clinic itself' do
        account.update!(limits: { 'agents' => 12 })

        expect(limit_of(account)).to eq(12)
        expect(limit_of(account)).to eq(expected_limit(account))
      end

      it 'treats 0 as a limit, not as a missing one' do
        account.update!(limits: { 'agents' => 0 })

        expect(limit_of(account)).to eq(0)
        expect(limit_of(account)).to eq(expected_limit(account))
      end

      it 'is the subscribed quantity when there is one' do
        account.update!(custom_attributes: { 'subscribed_quantity' => 25 }, limits: { 'agents' => 12 })

        expect(limit_of(account)).to eq(25)
        expect(limit_of(account)).to eq(expected_limit(account))
      end

      it 'falls back to the installation limit' do
        create(:installation_config, name: 'ACCOUNT_AGENTS_LIMIT', value: 7, locked: false)
        GlobalConfig.clear_cache

        expect(limit_of(account)).to eq(7)
        expect(limit_of(account)).to eq(expected_limit(account))
      end

      it 'is nil (no limit) when nothing sets one' do
        GlobalConfig.clear_cache

        expect(limit_of(account)).to be_nil
        expect(expected_limit(account)).to be_nil
      end

      it 'counts as no limit when it is nil or the maximum limit a plan writes' do
        GlobalConfig.clear_cache
        stats = described_class.new([account])

        expect(stats.for(account)).to be_operators_unlimited
        account.update!(limits: { 'agents' => ChatwootApp.max_limit })
        expect(described_class.new([account]).for(account)).to be_operators_unlimited
        account.update!(limits: { 'agents' => 10 })
        expect(described_class.new([account]).for(account)).not_to be_operators_unlimited
      end
    end
  end

  describe 'channels' do
    it 'counts the inboxes of every clinic of the page' do
      first = create(:account)
      second = create(:account)
      create_list(:inbox, 2, account: first)
      create(:inbox, account: second)

      stats = described_class.new([first, second])

      expect(stats.for(first).channels).to eq(2)
      expect(stats.for(second).channels).to eq(1)
    end

    it 'is zero for a clinic without inboxes' do
      account = create(:account)

      expect(described_class.new([account]).for(account).channels).to eq(0)
    end
  end

  describe 'storage' do
    let(:account) { create(:account) }

    after { Redis::Alfred.delete(storage_key(account)) }

    def write_snapshot(**limits)
      Redis::Alfred.set(storage_key(account), JSON.generate(limits: { current_available: 0, unlimited: false }.merge(limits)))
    end

    it 'comes from the hourly snapshot and shows the share used' do
      write_snapshot(total_count: 50.gigabytes, consumed: 40.gigabytes)

      storage = described_class.new([account]).for(account).storage

      expect(storage).to have_attributes(consumed: 40.gigabytes, total: 50.gigabytes, unlimited: false, percent: 80.0, tone: :warn)
    end

    it 'is red from 95% and calm below 80%' do
      write_snapshot(total_count: 100, consumed: 96)
      expect(described_class.new([account]).for(account).storage.tone).to eq(:bad)

      write_snapshot(total_count: 100, consumed: 10)
      expect(described_class.new([account]).for(account).storage.tone).to eq(:good)
    end

    it 'has no share for an unlimited clinic' do
      write_snapshot(total_count: ChatwootApp.max_limit, consumed: 10.gigabytes, unlimited: true)

      storage = described_class.new([account]).for(account).storage

      expect(storage).to have_attributes(unlimited: true, percent: nil, tone: :idle)
    end

    it 'is nil while there is no snapshot, and does not queue a measurement' do
      expect(Accounts::StorageBreakdownRefreshJob).not_to receive(:new)

      expect(described_class.new([account]).for(account).storage).to be_nil
    end
  end

  describe 'status' do
    it 'is active, suspended or deleting (deleting wins)' do
      active = create(:account)
      suspended = create(:account, status: :suspended)
      deleting = create(:account, status: :suspended, custom_attributes: { 'marked_for_deletion_at' => 3.days.from_now.iso8601 })

      stats = described_class.new([active, suspended, deleting])

      expect([active, suspended, deleting].map { |account| stats.for(account).status }).to eq(%i[active suspended deleting])
    end
  end

  describe 'plan' do
    it 'carries the plan state of the clinic' do
      account = create(:account)
      Accounts::ApplyPlan.new(account: account, modules: %w[quality]).call

      row = described_class.new([account.reload]).for(account)

      expect(row.plan.chips.map(&:text)).to eq(['База', 'Контроль качества'])
    end
  end

  describe 'queries' do
    it 'costs the same for a page of 2 clinics and a page of 10' do
      GlobalConfig.get('ACCOUNT_AGENTS_LIMIT') # warm the configuration cache the first read fills
      small = create_list(:account, 2)
      small.each do |account|
        create(:inbox, account: account)
        create(:user, account: account)
        account.update!(custom_attributes: account.custom_attributes.merge('limit_counter_excluded_user_ids' => [account.users.first.id]))
        Accounts::ApplyPlan.new(account: account, modules: %w[ai_agents]).call
      end
      large = small + create_list(:account, 8)
      large.each { |account| create(:user, account: account) }

      small_count = query_count { stats_for(*Account.where(id: small.map(&:id)).to_a) }
      large_count = query_count { stats_for(*Account.where(id: large.map(&:id)).to_a) }

      expect(small_count).to be_positive
      expect(large_count).to eq(small_count)
    end
  end
end
