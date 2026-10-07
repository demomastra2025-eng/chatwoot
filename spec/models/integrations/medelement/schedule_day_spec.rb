require 'rails_helper'

RSpec.describe Integrations::Medelement::ScheduleDay do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before { account.enable_features!('scheduling') }

  it 'has the additive provider-day uniqueness and resource/date lookup indexes' do
    indexes = ActiveRecord::Base.connection.indexes('medelement_schedule_days').index_by(&:name)

    expect(indexes.fetch('idx_medelement_schedule_days_provider_day').unique).to be(true)
    expect(indexes.fetch('idx_medelement_schedule_days_resource_date').columns).to eq(%w[account_id resource_id date])
  end

  it 'rejects a resource or hook from another account' do
    foreign_resource = create(:scheduling_resource, account: create(:account))
    day = described_class.new(account: account, hook: hook, resource: foreign_resource,
                              specialist_code: 'doctor-1', date: Date.new(2026, 10, 7))

    expect(day).not_to be_valid
    expect(day.errors[:account]).not_to be_empty
  end

  it 'keeps one row per hook, doctor and date' do
    attributes = { account: account, hook: hook, resource: resource, specialist_code: 'doctor-1', date: Date.new(2026, 10, 7) }
    described_class.create!(attributes)

    expect(described_class.new(attributes)).not_to be_valid
  end
end
