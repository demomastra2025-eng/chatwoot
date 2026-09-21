require 'rails_helper'

RSpec.describe AutomationRules::Events::CrmEventAdapter do
  let(:successful_job) { instance_double(EventDispatcherJob, successfully_enqueued?: true) }

  before do
    allow(Crm::Events::PublishJob).to receive(:perform_later!)
    allow(AutomationRules::PublishEventJob).to receive(:perform_later!)
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_return(successful_job)
  end

  it 'bridges a durable CRM fact idempotently before legacy publication completes' do
    deal = create(:crm_deal)
    crm_event = Crm::Events::Writer.record!(
      account: deal.account,
      eventable: deal,
      actor: nil,
      event_type: 'deal_updated',
      meta: { changes: { stage_id: [1, 2] } }
    )

    crm_event.publish!
    described_class.new(crm_event).capture!

    automation_event = AutomationEvent.find_by!(account: crm_event.account, dedupe_key: "crm-event:#{crm_event.id}")
    expect(automation_event).to have_attributes(
      event_name: crm_event.event_type,
      subject_type: 'Crm::Deal',
      subject_id: crm_event.eventable_id,
      producer: 'crm_event'
    )
    expect(automation_event.changes_snapshot).to eq('stage_id' => [1, 2])
    expect(AutomationEvent.where(account: crm_event.account, dedupe_key: "crm-event:#{crm_event.id}").count).to eq(1)
    expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
      crm_event.event_type,
      kind_of(Time),
      hash_including(crm_event: crm_event)
    ).once
  end

  it 'persists the durable bridge before an old publisher can mark the CRM event published' do
    deal = create(:crm_deal)
    crm_event = Crm::Events::Writer.record!(
      account: deal.account,
      eventable: deal,
      actor: nil,
      event_type: 'deal_updated'
    )

    crm_event.send(:with_publication_write) { crm_event.update!(published_at: Time.current) }

    expect(AutomationEvent.find_by!(dedupe_key: "crm-event:#{crm_event.id}")).to have_attributes(
      account_id: crm_event.account_id,
      subject_id: deal.id
    )
  end

  it 'uses the immutable CRM event-time matching snapshot after the record changes' do
    deal = create(:crm_deal, title: 'event-time-title')
    crm_event = Crm::Events::Writer.record!(
      account: deal.account,
      eventable: deal,
      actor: nil,
      event_type: 'deal_updated'
    )
    deal.update!(title: 'later-title')

    crm_event.publish!

    snapshot = AutomationEvent.find_by!(dedupe_key: "crm-event:#{crm_event.id}").payload_snapshot
    expect(snapshot).to include('snapshot_version' => 1, 'matcher_kind' => 'crm/deal')
    expect(snapshot.dig('matcher_data', 'deal', 'title')).to eq('event-time-title')
  end

  it 'replaces an untrusted caller snapshot and consumes only the Writer-owned event-time snapshot' do
    deal = create(:crm_deal, title: 'trusted-event-time-title')
    crm_event = Crm::Events::Writer.record!(
      account: deal.account,
      eventable: deal,
      actor: nil,
      event_type: 'deal_updated',
      meta: {
        automation_matching_snapshot: {
          snapshot_version: 999,
          matcher_kind: 'forged',
          matcher_data: { deal: { title: 'stale-caller-title' } }
        }
      }
    )

    writer_snapshot = crm_event.meta.fetch('automation_matching_snapshot')
    expect(writer_snapshot).to include('snapshot_version' => 1, 'matcher_kind' => 'crm/deal')
    expect(writer_snapshot.dig('matcher_data', 'deal', 'title')).to eq('trusted-event-time-title')

    deal.update!(title: 'later-title')
    crm_event.publish!

    adapter_snapshot = AutomationEvent.find_by!(dedupe_key: "crm-event:#{crm_event.id}").payload_snapshot
    expect(adapter_snapshot).to eq(writer_snapshot)
  end

  it 'keeps legacy CRM publication working for rows created by an old worker without a matching snapshot' do
    crm_event = create(:crm_event, meta: { changes: { stage_id: [1, 2] } })

    expect { crm_event.publish! }.not_to(change(AutomationEvent, :count))

    expect(crm_event.reload.published_at).to be_present
    expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
      crm_event.event_type,
      kind_of(Time),
      hash_including(crm_event: crm_event)
    ).once
  end

  it 'does not mark CRM publication complete when durable capture fails' do
    crm_event = create(:crm_event)
    adapter = instance_double(described_class)
    allow(adapter).to receive(:capture!).and_raise(StandardError, 'ledger unavailable')
    allow(described_class).to receive(:new).and_return(adapter)

    expect { crm_event.publish! }.to raise_error(StandardError, 'ledger unavailable')
    expect(crm_event.reload.published_at).to be_nil
  end
end
