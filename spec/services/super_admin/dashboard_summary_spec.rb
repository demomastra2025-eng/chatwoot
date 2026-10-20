# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::DashboardSummary do
  def figures = described_class.new.figures

  def trial_account(expires_at, **attributes)
    create(:account, custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => expires_at.iso8601 }.merge(attributes))
  end

  it 'counts the accounts that work and the ones that are blocked' do
    create_list(:account, 2)
    create(:account, status: :suspended)

    expect(figures).to include(active: 2, suspended: 1)
  end

  it 'counts nothing but zeros on an empty platform' do
    expect(figures).to include(active: 0, suspended: 0, trial: 0, trial_ending: 0, recent: 0, messages_day: 0)
  end

  describe 'trials' do
    it 'counts the trials that run now, and the ones that end within three days among them' do
      trial_account(5.hours.from_now)
      trial_account(2.days.from_now)
      trial_account(10.days.from_now)

      expect(figures).to include(trial: 3, trial_ending: 2)
    end

    it 'leaves out the trials that ended, accounts without a trial and a date that cannot be read' do
      trial_account(1.day.ago)
      create(:account, custom_attributes: { 'plan_type' => 'paid', 'trial_expires_at' => 1.day.from_now.iso8601 })
      create(:account, custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 'soon' })
      create(:account, custom_attributes: { 'plan_type' => 'trial' })

      expect(figures).to include(trial: 0, trial_ending: 0)
    end

    it 'gives the same number as the filter «Пробные» of the list of accounts, which the tile opens' do
      trial_account(1.day.from_now)
      trial_account(6.days.from_now)
      trial_account(2.days.ago)

      listed = AccountDashboard::COLLECTION_FILTERS.fetch(:trial_active).call(Account.all).count

      expect(figures[:trial]).to eq(listed)
    end
  end

  describe 'new accounts' do
    it 'counts the ones made within thirty days, as the filter «Новые за 30 дней» does' do
      create(:account)
      create(:account, created_at: 29.days.ago)
      create(:account, created_at: 31.days.ago)

      expect(figures[:recent]).to eq(2)
      expect(figures[:recent]).to eq(AccountDashboard::COLLECTION_FILTERS.fetch(:recent).call(Account.all).count)
    end
  end

  describe 'messages of the last day' do
    let(:account) { create(:account) }

    it 'counts what clients wrote and operators answered, in the last twenty-four hours' do
      create(:message, account: account, message_type: :incoming)
      create(:message, account: account, message_type: :outgoing)
      create(:message, account: account, message_type: :incoming, created_at: 2.days.ago)

      expect(figures[:messages_day]).to eq(2)
    end

    it 'does not count the notes of operators and the lines the system writes into a chat' do
      create(:message, account: account, message_type: :outgoing, private: true)
      create(:message, account: account, message_type: :activity)

      expect(figures[:messages_day]).to eq(0)
    end
  end

  describe 'the chart of conversations' do
    it 'has a point for every one of the thirty days and counts the conversations made on them' do
      create(:conversation, created_at: 3.days.ago)
      create(:conversation, created_at: 3.days.ago)

      chart = figures[:chart]

      expect(chart.size).to be_between(30, 31)
      expect(chart.to_h[3.days.ago.to_date]).to eq(2)
    end
  end

  describe 'a figure that cannot be counted' do
    it 'is nil, not zero, and the others are still counted' do
      create(:account)
      allow(Message).to receive(:unscoped).and_raise(ActiveRecord::StatementInvalid, 'canceling statement due to statement timeout')

      expect(figures).to include(active: 1, messages_day: nil)
    end

    it 'leaves the chart empty when the conversations cannot be read' do
      allow(Conversation).to receive(:unscoped).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect(figures[:chart]).to eq([])
    end
  end

  describe '.build' do
    it 'asks the cache for the figures, and for fresh ones on a refresh' do
      allow(Rails.cache).to receive(:fetch).and_call_original

      described_class.build
      described_class.build(force_refresh: true)

      expect(Rails.cache).to have_received(:fetch).with(described_class::CACHE_KEY, expires_in: described_class::CACHE_TTL, force: false)
      expect(Rails.cache).to have_received(:fetch).with(described_class::CACHE_KEY, expires_in: described_class::CACHE_TTL, force: true)
    end

    it 'says nil for every figure, not zero, when nothing could be counted or kept' do
      allow(Rails.cache).to receive(:fetch).and_raise(StandardError, 'cache down')

      expect(described_class.build).to eq(
        active: nil, suspended: nil, trial: nil, trial_ending: nil, recent: nil, messages_day: nil, chart: []
      )
    end
  end
end
