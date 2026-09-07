require 'rails_helper'

RSpec.describe Crm::Event do
  let(:account) { create(:account) }
  let(:deal) { create(:crm_deal, account: account) }
  let(:successful_job) { instance_double(EventDispatcherJob, successfully_enqueued?: true) }

  before do
    allow(Crm::Events::PublishJob).to receive(:perform_later!)
  end

  it 'registers granular task facts without removing legacy task events' do
    granular_events = %w[
      task_assigned task_rescheduled task_completed task_cancelled task_reopened task_waiting_changed
    ]

    expect(described_class::SUPPORTED_AUTOMATION_EVENT_TYPES).to include(*granular_events, 'task_updated', 'task_status_changed')
    expect(AutomationRule::TASK_EVENT_NAMES).to include(*granular_events, 'task_updated', 'task_status_changed')
    expect(CrmAutomationRuleListener::TASK_EVENT_NAMES).to include(*granular_events, 'task_updated', 'task_status_changed')
  end

  it 'registers and dispatches deal waiting facts to CRM automation' do
    waiting_events = %w[deal_waiting_set deal_waiting_cleared]
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_return(successful_job)

    expect(described_class::SUPPORTED_AUTOMATION_EVENT_TYPES).to include(*waiting_events)
    expect(AutomationRule::DEAL_EVENT_NAMES).to include(*waiting_events)
    expect(CrmAutomationRuleListener::DEAL_EVENT_NAMES).to include(*waiting_events)

    waiting_events.each do |event_type|
      event = create(:crm_event, account: account, eventable: deal, event_type: event_type)
      event.publish!

      expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
        event_type,
        kind_of(Time),
        hash_including(account: account, deal: deal, crm_event: event)
      )
    end
  end

  [false, nil].each do |result|
    it "keeps the event pending when listener dispatch returns #{result.inspect}" do
      event = create(:crm_event, account: account, eventable: deal)
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_return(result)

      expect { event.publish! }.to raise_error(ActiveJob::EnqueueError)
      expect(event.reload.published_at).to be_nil
      expect(event.publication_attempts).to eq(1)
      expect(event.publication_next_attempt_at).to be > Time.current
    end
  end

  [ActiveJob::EnqueueError, StandardError].each do |error_class|
    it "preserves the committed event after #{error_class} during initial enqueue" do
      allow(Crm::Events::PublishJob).to receive(:perform_later!).and_raise(error_class, 'queue unavailable')

      event = create(:crm_event, account: account, eventable: deal)

      expect(event.reload.published_at).to be_nil
      expect(event.publication_attempts).to eq(1)
      expect(event.publication_error).to eq('queue unavailable')
      expect(event.publication_next_attempt_at).to be > Time.current
    end
  end

  it 'is append-only after creation' do
    event = create(:crm_event, account: account, eventable: deal)

    expect { event.update!(source: 'changed') }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { event.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it 'prevents deleting an entity that owns historical events' do
    event = create(:crm_event, account: account, eventable: deal)

    expect(deal.destroy).to be(false)
    expect(event.reload).to be_present
  end

  it 'publishes once and records durable publication state' do
    event = create(:crm_event, account: account, eventable: deal)
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_return(successful_job)

    event.publish!
    event.publish!

    expect(Rails.configuration.dispatcher).to have_received(:dispatch).once
    expect(event.reload.published_at).to be_present
    expect(event.publication_attempts).to eq(1)
    expect(event.publication_error).to be_nil
  end

  it 'keeps an unpublished event available for retry after dispatch failure' do
    event = create(:crm_event, account: account, eventable: deal)
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_raise(StandardError, 'temporary failure')

    expect { event.publish! }.to raise_error(StandardError, 'temporary failure')

    event.reload
    expect(event.published_at).to be_nil
    expect(event.publication_attempts).to eq(1)
    expect(event.publication_error).to eq('temporary failure')
  end

  it 'does not mark an event published when listener enqueue fails silently' do
    event = create(:crm_event, account: account, eventable: deal)
    enqueue_error = ActiveJob::EnqueueError.new('queue unavailable')
    failed_job = instance_double(EventDispatcherJob, successfully_enqueued?: false, enqueue_error: enqueue_error)
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_return(failed_job)

    expect { event.publish! }.to raise_error(ActiveJob::EnqueueError, 'queue unavailable')

    expect(event.reload.published_at).to be_nil
    expect(event.publication_error).to eq('queue unavailable')
  end
end
