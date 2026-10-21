# frozen_string_literal: true

require 'rails_helper'

# «Без ограничений» of a super admin (Accounts::LimitSettings) must be an answer of «no limit» in the code that enforces the limits, for
# EVERY limit. Where a counter goes up by itself and is set back by hand only (the AI answers and tokens, the mail of a day, the storage),
# the bare 100 000 that stands for no limit of a count would be a real quota that a busy account reaches: those limits get a number
# nobody reaches (Accounts::Plans.unlimited_value), and the enforcement recognises it.
RSpec.describe 'Account limits: «Без ограничений» in the code that enforces them', type: :model do
  let(:account) { create(:account) }
  let(:max) { ChatwootApp.max_limit }
  let(:keys) { Accounts::Plans::LIMIT_KEYS }

  before { GlobalConfig.clear_cache }

  def choose_unlimited(key)
    result = Accounts::LimitSettings.new(account.reload).apply(key => :unlimited)
    account.update!(limits: result.limits, custom_attributes: result.custom_attributes(account.custom_attributes))
    account.reload
  end

  # What a counter says it has counted (the AI answers and tokens count by themselves and are set back by hand only)
  def use_up(counter, count)
    account.update!(custom_attributes: account.custom_attributes.merge(counter => count))
  end

  # The summary the enforcement code reads for each limit: { total_count:, current_available:, consumed:, unlimited: }
  def summary(key)
    overview = account.account_usage_overview
    {
      'agents' => overview[:agents], 'inboxes' => overview[:inboxes], 'conversations' => overview[:conversations],
      'non_web_inboxes' => overview[:non_web_inboxes], 'storage_bytes' => overview[:storage], 'emails' => overview[:emails],
      'captain_responses' => overview[:captain][:responses], 'captain_documents' => overview[:captain][:documents],
      'captain_tokens' => overview[:captain][:tokens]
    }.fetch(key)
  end

  describe 'the number that stands for no limit' do
    it 'is a number nobody reaches where the counter goes up by itself, and 100 000 for the counts of things in the account' do
      expect(keys.index_with { |key| Accounts::Plans.unlimited_value(key) }).to eq(
        'agents' => max, 'inboxes' => max, 'conversations' => max, 'non_web_inboxes' => max,
        'storage_bytes' => max * 1.gigabyte, 'captain_tokens' => max * 1_000_000,
        'captain_responses' => max * 1_000, 'captain_documents' => max * 1_000, 'emails' => max * 1_000
      )
    end

    it 'is above 100 000 for every limit that a counter reaches, so a quota of 100 000 stays a quota' do
      %w[captain_responses captain_documents emails storage_bytes captain_tokens].each do |key|
        expect(Accounts::Plans.unlimited_value(key)).to be > max
        expect(Accounts::Plans.unlimited_value?(key, max)).to be(false)
      end
    end

    it 'is what a plan writes for `unlimited`, for every limit' do
      config = YAML.safe_load(File.read(Accounts::Plans::CONFIG_PATH))
      config['base']['limits'] = keys.index_with { 'unlimited' }

      expect(Accounts::Plans.new(config).limits_for([])).to eq(keys.index_with { |key| Accounts::Plans.unlimited_value(key) })
    end
  end

  describe 'choosing «Без ограничений»' do
    it 'leads to an unlimited answer of the enforcement for every limit' do
      keys.each do |key|
        choose_unlimited(key)

        expect(summary(key)).to include(unlimited: true), "#{key} is still a quota: #{summary(key).inspect}"
        expect(Accounts::LimitSettings.new(account).source(key)).to eq(:unlimited)
      end
    end

    it 'never leaves 100 000 where the counters would reach it' do
      %w[captain_responses captain_documents emails].each do |key|
        choose_unlimited(key)

        expect(account.limits[key]).to be > max
      end
    end

    it 'keeps the AI answers available however many were given, since the counter does not reset by itself' do
      choose_unlimited('captain_responses')
      use_up(Enterprise::Account::PlanUsageAndLimits::CAPTAIN_RESPONSES_USAGE, max + 50_000)

      expect(account.usage_limits[:captain][:responses]).to include(unlimited: true, consumed: max + 50_000)
      expect(account.captain_quota_available?).to be(true)
    end

    it 'keeps the AI tokens available however many were spent' do
      choose_unlimited('captain_tokens')
      use_up(Enterprise::Account::PlanUsageAndLimits::CAPTAIN_TOKENS_USAGE, max * 10_000_000)

      expect(account.usage_limits[:captain][:tokens]).to include(unlimited: true)
      expect(account.captain_quota_available?).to be(true)
    end

    it 'lets the mail of a day go however much was sent' do
      choose_unlimited('emails')
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
      allow(account).to receive(:emails_sent_today).and_return(max * 20)

      expect(account.within_email_rate_limit?).to be(true)
    end

    it 'does not let a real quota of 100 000 letters through when it is reached' do
      account.update!(limits: account.limits.merge('emails' => max))
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
      allow(account).to receive(:emails_sent_today).and_return(max)

      expect(account.within_email_rate_limit?).to be(false)
      expect(account.account_usage_overview[:emails]).to include(unlimited: false, total_count: max)
    end

    it 'keeps a quota of 100 000 AI answers a quota: used up, nothing more is answered' do
      account.update!(limits: account.limits.merge('captain_responses' => max))
      use_up(Enterprise::Account::PlanUsageAndLimits::CAPTAIN_RESPONSES_USAGE, max)

      expect(account.usage_limits[:captain][:responses]).to include(unlimited: false, current_available: 0)
      expect(account.captain_quota_available?).to be(false)
      # ... and a super admin who types that number gets a number of their own, not «без ограничений»
      expect(Accounts::LimitSettings.new(account).source('captain_responses')).to eq(:custom)
    end

    it 'lets the storage grow without a quota' do
      choose_unlimited('storage_bytes')
      service = AccountLimits::StorageUsageService.new(account: account)

      expect(service.within_limit?(extra_bytes: 10**15)).to be(true)
      expect(service.summary).to include(unlimited: true)
    end

    it 'lets dialogs and main channels in without a quota' do
      choose_unlimited('conversations')
      choose_unlimited('non_web_inboxes')

      expect(account.usage_limits[:conversations]).to be >= max
      expect(account.usage_limits[:non_web_inboxes]).to be >= max
    end

    it 'lets operators and channels in without a quota' do
      choose_unlimited('agents')
      choose_unlimited('inboxes')

      expect(account.usage_limits[:agents]).to be >= max
      expect(account.usage_limits[:inboxes]).to be >= max
    end
  end
end
