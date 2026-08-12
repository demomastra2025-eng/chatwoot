require 'rails_helper'

describe Integrations::Medelement::SyncConflictFilter do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:run) do
    Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'manual', status: 'partial')
  end
  let(:contact) { create(:contact, account: account, name: 'Patient') }
  let(:conflict) do
    Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: 'phone_owned_by_another_contact',
      entity_key: 'patient-1',
      details: { contact_id: contact.id }
    )
  end

  before { account.enable_features!('scheduling') }

  it 'finds a conflict by the exact numeric contact ID promised by the UI' do
    conflict
    result = described_class.new(hook: hook, filters: { contact: contact.id.to_s }).apply

    expect(result).to contain_exactly(conflict)
  end

  it 'keeps the exact numeric contact ID when text matches reach the search limit' do
    conflict
    allow(hook.account.contacts).to receive(:where).and_call_original
    allow(hook.account.contacts).to receive(:where)
      .with('name ILIKE :query OR email ILIKE :query OR phone_number ILIKE :query OR identifier ILIKE :query', anything)
      .and_return(hook.account.contacts.where.not(id: contact.id))

    result = described_class.new(hook: hook, filters: { contact: contact.id.to_s }).apply

    expect(result).to contain_exactly(conflict)
  end

  it 'treats a numeric query beyond the database bigint range as no match' do
    conflict

    result = described_class.new(hook: hook, filters: { contact: '9' * 30 }).apply

    expect(result).to be_empty
  end

  it 'keeps numeric contact ID lookup scoped to the current hook' do
    conflict
    another_account = create(:account)
    another_account.enable_features!('scheduling')
    another_hook = create(:integrations_hook, :medelement, account: another_account)
    another_run = Integrations::Medelement::SyncRun.create!(
      account: another_account,
      hook: another_hook,
      trigger: 'manual',
      status: 'partial'
    )
    Integrations::Medelement::ConflictTracker.new(sync_run: another_run).record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: 'phone_owned_by_another_contact',
      entity_key: 'patient-2',
      details: { contact_id: contact.id }
    )

    result = described_class.new(hook: hook, filters: { contact: contact.id.to_s }).apply

    expect(result).to contain_exactly(conflict)
  end
end
