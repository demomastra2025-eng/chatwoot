# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreadParticipantLifecycleFact do
  subject(:fact) do
    build(
      :communication_thread_participant_lifecycle_fact,
      account: account,
      communication_thread: thread,
      participant_id: participant.id
    )
  end

  let(:account) { create(:account) }
  let(:thread) { create(:communication_thread, account: account) }
  let(:participant) { create(:user, account: account) }

  it 'is valid for a same-account participant and thread' do
    expect(fact).to be_valid
  end

  it 'rejects a thread from another account' do
    fact.communication_thread = create(:communication_thread, account: create(:account))

    expect(fact).not_to be_valid
    expect(fact.errors[:communication_thread]).to include('must belong to the same account')
  end

  it 'rejects a participant from another account' do
    fact.participant_id = create(:user, account: create(:account)).id

    expect(fact).not_to be_valid
    expect(fact.errors[:participant_id]).to include('must identify a workspace member in the same account')
  end

  it 'rejects a reliable boundary after the occurrence' do
    fact.reliable_since = fact.occurred_at + 1.second

    expect(fact).not_to be_valid
    expect(fact.errors[:reliable_since]).to include('must not be after occurred_at')
  end

  it 'rejects a cross-account actor through the insert trigger' do
    actor = create(:user, account: create(:account))
    row = fact.attributes.except('id').merge(actor_kind: 'user', actor_type: 'User', actor_id: actor.id)

    expect { described_class.insert_all!([row]) } # rubocop:disable Rails/SkipsModelValidations
      .to raise_error(ActiveRecord::StatementInvalid, /actor must belong to account/)
  end

  it 'rejects an invalid reliable boundary through the database check' do
    row = fact.attributes.except('id').merge(created_at: Time.current, reliable_since: fact.occurred_at + 1.second)

    expect { described_class.insert_all!([row]) } # rubocop:disable Rails/SkipsModelValidations
      .to raise_error(ActiveRecord::StatementInvalid, /reliable_since/)
  end

  it 'rejects Active Record updates after persistence' do
    fact.save!

    expect { fact.update!(reason: 'changed') }.to raise_error(ActiveRecord::RecordInvalid, /immutable/)
  end

  it 'rejects direct SQL updates at the database boundary' do
    fact.save!

    expect do
      described_class.where(id: fact.id).update_all(reason: 'changed') # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it 'rejects direct SQL deletes at the database boundary' do
    fact.save!

    expect do
      described_class.where(id: fact.id).delete_all
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it 'allows lifecycle facts to be erased only as part of whole-account teardown' do
    fact.save!
    fact.communication_thread.destroy!

    expect { account.destroy! }.to change(described_class, :count).by(-1)
    expect(described_class.where(id: fact.id)).not_to exist
  end

  it 'keeps actor identity after the actor workspace membership is deleted' do
    actor = create(:user, account: account)
    fact.assign_attributes(actor_kind: 'user', actor_type: 'User', actor_id: actor.id)
    fact.save!

    account.account_users.find_by!(user_id: actor.id).destroy!

    expect(fact.reload).to have_attributes(actor_kind: 'user', actor_type: 'User', actor_id: actor.id)
  end
end
