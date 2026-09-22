require 'rails_helper'

RSpec.describe CommunicationThreadManualCallOccurrence do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, name: 'Original caller') }
  let(:thread) { create(:communication_thread, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: thread.contact) }
  let(:call_session) do
    create(
      :telephony_call_session,
      :native_manual,
      account: account,
      conversation: conversation,
      initiator: actor,
      direction: 'outbound',
      started_at: Time.utc(2026, 9, 22, 8),
      external_call_ref: 'sipuni:local:manual-fact-1'
    )
  end

  def record
    described_class.record!(
      account: account,
      communication_thread: thread,
      actor: actor,
      call_session: call_session
    )
  end

  it 'atomically records one immutable source occurrence across retries' do
    first = record
    second = record

    expect(second.id).to eq(first.id)
    expect(described_class.where(account_id: account.id, source_id: call_session.id).count).to eq(1)
    expect(first).to have_attributes(
      communication_thread_id: thread.id,
      actor_type: 'User',
      actor_id: actor.id,
      actor_name: 'Original caller',
      source_kind: 'telephony_call_session',
      source_ref: call_session.external_call_ref,
      occurred_at: call_session.started_at,
      reliable_since: call_session.started_at
    )
  end

  it 'retains actor and source snapshots after mutable source identities are removed' do
    occurrence = record

    account.account_users.find_by!(user_id: actor.id).destroy!
    call_session.destroy!

    expect(occurrence.reload).to have_attributes(
      actor_id: actor.id,
      actor_name: 'Original caller',
      source_id: call_session.id,
      source_ref: 'sipuni:local:manual-fact-1'
    )
    expect(record.id).to eq(occurrence.id)
  end

  it 'rejects cross-account thread, actor, and source identities' do
    foreign_account = create(:account)
    foreign_thread = create(:communication_thread, account: foreign_account)
    foreign_actor = create(:user, account: foreign_account)
    foreign_session = create(
      :telephony_call_session,
      :native_manual,
      account: foreign_account,
      initiator: foreign_actor,
      direction: 'outbound'
    )

    expect do
      described_class.record!(account: account, communication_thread: foreign_thread, actor: actor, call_session: call_session)
    end.to raise_error(ActiveRecord::RecordInvalid, /communication thread must belong to the same account/i)
    expect do
      described_class.record!(account: account, communication_thread: thread, actor: foreign_actor, call_session: call_session)
    end.to raise_error(ActiveRecord::RecordInvalid, /workspace member in the same account/i)
    expect do
      described_class.record!(account: account, communication_thread: thread, actor: actor, call_session: foreign_session)
    end.to raise_error(ActiveRecord::RecordInvalid, /outbound call session in the same account/i)
  end

  it 'rejects non-manual inbound source sessions' do
    call_session.update!(direction: 'inbound')

    expect { record }.to raise_error(ActiveRecord::RecordInvalid, /outbound call session/)
  end

  it 'rejects AI, generic outbound, and mismatched same-account actor sources' do
    other_actor = create(:user, account: account)
    generic_session = create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: call_session.inbox,
      number_binding: call_session.number_binding,
      direction: 'outbound'
    )
    ai_session = create(
      :telephony_call_session,
      :native_manual,
      account: account,
      conversation: conversation,
      inbox: call_session.inbox,
      number_binding: call_session.number_binding,
      initiator: actor,
      metadata: call_session.metadata.merge('ai_voice' => { 'assistant_id' => 1 })
    )

    expect do
      described_class.record!(account: account, communication_thread: thread, actor: actor, call_session: generic_session)
    end.to raise_error(ActiveRecord::RecordInvalid, /outbound call session/)
    expect do
      described_class.record!(account: account, communication_thread: thread, actor: actor, call_session: ai_session)
    end.to raise_error(ActiveRecord::RecordInvalid, /outbound call session/)
    expect do
      described_class.record!(account: account, communication_thread: thread, actor: other_actor, call_session: call_session)
    end.to raise_error(ActiveRecord::RecordInvalid, /outbound call session/)
  end

  it 'enforces source provenance and actor binding on direct inserts' do
    other_actor = create(:user, account: account)
    attributes = {
      account_id: account.id,
      communication_thread_id: thread.id,
      actor_type: 'User',
      actor_id: other_actor.id,
      actor_name: other_actor.name,
      source_kind: 'telephony_call_session',
      source_id: call_session.id,
      source_ref: call_session.external_call_ref,
      occurred_at: call_session.started_at,
      reliable_since: call_session.started_at,
      schema_version: 1,
      created_at: Time.current
    }

    expect do
      described_class.insert_all!([attributes]) # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::StatementInvalid, /source must be an outbound call session/)
  end

  it 'rejects updates and deletes' do
    occurrence = record

    expect { occurrence.update!(actor_name: 'Changed') }.to raise_error(ActiveRecord::RecordInvalid, /immutable/)
    expect { described_class.where(id: occurrence.id).delete_all }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it 'allows deletion only during whole-account teardown' do
    occurrence = record

    thread.destroy!
    account.send(:authorize_participant_lifecycle_fact_teardown)
    expect { account.communication_thread_manual_call_occurrences.delete_all }
      .to change(described_class, :count).by(-1)
    expect(described_class.where(id: occurrence.id)).not_to exist
  end
end
