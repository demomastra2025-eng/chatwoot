require 'rails_helper'

RSpec.describe Crm::Events::Writer do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:deal) { create(:crm_deal, account: account) }

  before do
    allow(Crm::Events::PublishJob).to receive(:perform_later!)
  end

  it 'writes a stable PII-safe envelope while preserving legacy meta' do
    event = described_class.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: 'deal_updated',
      meta: {
        changes: {
          'title' => ['Private old title', 'Private new title'],
          'stage_id' => [10, 20]
        }
      },
      source: 'api',
      correlation_id: SecureRandom.uuid,
      causation_id: SecureRandom.uuid
    )

    expect(event).to have_attributes(
      source: 'api',
      actor_kind: 'User',
      schema_version: 1,
      before_data: { 'stage_id' => 10 },
      after_data: { 'stage_id' => 20 }
    )
    expect(event.meta.dig('changes', 'title')).to eq(['Private old title', 'Private new title'])
    expect(event.meta.dig('automation_matching_snapshot', 'snapshot_version')).to eq(2)
    expect(event.meta.dig('automation_matching_snapshot', 'matcher_data', 'deal', 'title')).to eq(deal.title)
    expect(event.before_data).not_to have_key('title')
    expect(event.correlation_id).to be_present
    expect(event.causation_id).to be_present
  end

  it 'stores event-time webhook data in the matching snapshot' do
    deal = create(:crm_deal, account: account, title: 'Snapshot title')
    event = described_class.record!(
      account: account,
      eventable: deal,
      actor: actor,
      event_type: 'deal_updated'
    )

    expect(event.meta.dig('automation_matching_snapshot', 'webhook_data', 'deal', 'title')).to eq('Snapshot title')
  end

  it 'derives only allowlisted changed attributes from persisted command snapshots' do
    task = create(:crm_task, account: account, title: 'Before')
    event = described_class.record!(
      account: account,
      eventable: task,
      actor: actor,
      event_type: 'task_rescheduled',
      before_data: { 'due_at' => nil, 'position' => 0, 'secret' => 'hidden' },
      after_data: { 'due_at' => '2026-10-05T12:00:00Z', 'position' => 1, 'secret' => 'changed' }
    )

    expect(event.meta.dig('changes', 'due_at')).to eq([nil, '2026-10-05T12:00:00Z'])
    expect(event.meta.dig('changes', 'position')).to eq([0, 1])
    expect(event.meta['changes']).not_to have_key('secret')
  end

  it 'deduplicates retries by command and event identity' do
    attributes = {
      account: account,
      eventable: deal,
      actor: actor,
      event_type: 'deal_updated',
      command_key: 'request-123'
    }

    first = described_class.record!(**attributes)
    second = described_class.record!(**attributes)

    expect(second.id).to eq(first.id)
    expect(account.crm_events.where(command_key: 'request-123').count).to eq(1)
  end

  it 'recovers a database command-key collision without aborting the outer transaction' do
    attributes = {
      account: account,
      eventable: deal,
      actor: actor,
      event_type: 'deal_updated',
      command_key: 'request-race'
    }
    existing_event = described_class.record!(**attributes)
    association = account.crm_events
    identity = { eventable: deal, event_type: 'deal_updated', command_key: 'request-race' }
    scope = association.where(identity)
    first_lookup = true
    allow(account).to receive(:crm_events).and_return(association)
    allow(association).to receive(:where).with(identity).and_return(scope)
    allow(scope).to receive(:first).and_wrap_original do |original, *args|
      if first_lookup
        first_lookup = false
        nil
      else
        original.call(*args)
      end
    end

    ActiveRecord::Base.transaction do
      expect(described_class.record!(**attributes)).to eq(existing_event)
      expect(ActiveRecord::Base.connection.select_value('SELECT 1')).to eq(1)
    end
  end

  it 'persists automation provenance for asynchronous publication' do
    rule = create(:automation_rule, account: account)
    Current.executed_by = rule

    event = described_class.record!(account: account, eventable: deal, actor: nil, event_type: 'deal_updated')

    expect(event).to have_attributes(
      source: 'automation',
      performed_by_type: 'AutomationRule',
      performed_by_id: rule.id
    )
  ensure
    Current.executed_by = nil
  end
end
