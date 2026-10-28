require 'rails_helper'

RSpec.describe Integrations::Medelement::ScheduleChangeTracker do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:redis) { MockRedis.new }
  let(:pool) { ConnectionPool.new(size: 1, timeout: 1) { Redis::Namespace.new(:medelement_changes_spec, redis: redis) } }

  before { account.enable_features!('scheduling') }

  it 'marks only the mapped specialist and reception date without patient data' do
    resource = create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'fake-doctor' })
    tracker = described_class.new(hook: hook, pool: pool)
    tracker.mark_reception!('SPECIALIST_CODE' => 'fake-doctor', 'STARTTIME' => '2026-10-28 23:30:00',
                            'PATIENT_CODE' => 'fake-patient')

    changes = tracker.changes_for(resource.id)
    expect(changes.keys).to eq(['2026-10-28'])
    expect(changes.to_s).not_to include('fake-patient')
  end
end
