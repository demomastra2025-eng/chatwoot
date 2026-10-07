require 'rails_helper'

RSpec.describe Integrations::Medelement::DeltaMissAudit do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:audit) { described_class.new(hook: hook) }

  before do
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => true))
    Integrations::Medelement::SyncCursor.create!(
      hook: hook, name: 'receptions_delta', value: 1.minute.ago, last_success_at: Time.current
    )
  end

  def record_change
    audit.record_change!(
      reception_code: 'reception-1', change_marker: 'marker-1', kind: 'changed',
      changed_fields: %w[starts_at status]
    )
  end

  it 'records one unexplained miss after a complete poll and the grace period' do
    record_change
    record_change
    travel 2.minutes do
      audit.resolve_candidates!(poll_completed_at: Time.current)
    end

    miss = Integrations::Medelement::DeltaMiss.find_by!(hook: hook)
    expect(miss).to have_attributes(classification: 'unexplained', kind: 'changed')
    expect(miss.changed_fields).to eq(%w[starts_at status])
    expect(Integrations::Medelement::DeltaMiss.where(hook: hook).count).to eq(1)
  end

  it 'classifies a recent successful own provider command separately' do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, operation: 'remove_reception', status: 'succeeded',
      provider_reception_code: 'reception-1', idempotency_key: 'fake-command-1'
    )
    record_change
    travel 2.minutes do
      audit.resolve_candidates!(poll_completed_at: Time.current)
    end

    expect(Integrations::Medelement::DeltaMiss.find_by!(hook: hook).classification).to eq('own_api_change')
  end

  it 'does not record a miss for a matching delta marker' do
    record_change
    Integrations::Medelement::DeltaSeenReception.create!(
      hook: hook, reception_code: 'reception-1', change_marker: 'marker-1', processed_at: Time.current
    )
    travel 2.minutes do
      audit.resolve_candidates!(poll_completed_at: Time.current)
    end

    expect(Integrations::Medelement::DeltaMiss.where(hook: hook)).to be_empty
  end

  it 'does not create a candidate when the delta feature is off' do
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => false))
    record_change

    expect(Integrations::Medelement::DeltaMissCandidate.where(hook: hook)).to be_empty
  end

  it 'prunes only seen markers older than seven days' do
    old = Integrations::Medelement::DeltaSeenReception.create!(
      hook: hook, reception_code: 'old', change_marker: 'old', processed_at: 8.days.ago
    )
    recent = Integrations::Medelement::DeltaSeenReception.create!(
      hook: hook, reception_code: 'recent', change_marker: 'recent', processed_at: 6.days.ago
    )

    audit.prune_seen!

    expect(Integrations::Medelement::DeltaSeenReception.exists?(old.id)).to be(false)
    expect(Integrations::Medelement::DeltaSeenReception.exists?(recent.id)).to be(true)
  end
end
