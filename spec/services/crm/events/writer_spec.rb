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
    expect(event.before_data).not_to have_key('title')
    expect(event.correlation_id).to be_present
    expect(event.causation_id).to be_present
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
