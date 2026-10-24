require 'rails_helper'

RSpec.describe Scheduling::ResourceServiceStat do
  let(:account) { create(:account) }

  it 'has a valid factory with the history source and the auto status' do
    stat = create(:scheduling_resource_service_stat, account: account)

    expect(stat).to be_persisted
    expect(stat).to have_attributes(source: 'history', status: 'auto')
  end

  it 'keeps one row per specialist and service' do
    stat = create(:scheduling_resource_service_stat, account: account)
    duplicate = build(:scheduling_resource_service_stat, account: account, resource: stat.resource, service: stat.service)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:resource_id]).to be_present
  end

  it 'rejects an unknown status and source' do
    expect(build(:scheduling_resource_service_stat, account: account, status: 'maybe')).not_to be_valid
    expect(build(:scheduling_resource_service_stat, account: account, source: 'guess')).not_to be_valid
  end

  it 'rejects a specialist or a service of another account' do
    foreign_resource = create(:scheduling_resource)
    foreign_service = create(:scheduling_service)

    expect(build(:scheduling_resource_service_stat, account: account, resource: foreign_resource)).not_to be_valid
    expect(build(:scheduling_resource_service_stat, account: account, service: foreign_service)).not_to be_valid
  end

  it 'counts only auto and confirmed rows as usable' do
    statuses = %w[auto confirmed disabled stale]
    statuses.each { |status| create(:scheduling_resource_service_stat, account: account, status: status) }

    expect(described_class.usable.pluck(:status)).to contain_exactly('auto', 'confirmed')
  end

  it 'tells a status set by staff from an automatic one' do
    expect(build(:scheduling_resource_service_stat, status: 'confirmed')).to be_manual
    expect(build(:scheduling_resource_service_stat, status: 'disabled')).to be_manual
    expect(build(:scheduling_resource_service_stat, status: 'auto')).not_to be_manual
    expect(build(:scheduling_resource_service_stat, status: 'stale')).not_to be_manual
  end
end
