require 'rails_helper'

RSpec.describe CommunicationThreadStateTransitionFact do
  let(:account) { create(:account) }
  let(:thread) { create(:communication_thread, account: account) }
  let(:occurred_at) { Time.utc(2026, 9, 22, 18) }

  def create_fact(attributes = {})
    create(
      :communication_thread_state_transition_fact,
      account: account,
      communication_thread_id_snapshot: thread.id,
      thread_display_id_snapshot: thread.display_id,
      contact_id_snapshot: thread.contact_id,
      occurred_at: occurred_at,
      reliable_since: occurred_at,
      **attributes
    )
  end

  it 'stores historical identifiers without live business-dimension foreign keys' do
    assignee = create(:user, account: account, name: 'Historic owner')
    team = create(:team, account: account, name: 'Historic team')
    fact = create_fact(to_assignee_id: assignee.id, to_assignee_name: assignee.name, to_team_id: team.id, to_team_name: team.name)

    thread.destroy!
    account.account_users.find_by!(user_id: assignee.id).destroy!
    team.destroy!

    expect(fact.reload).to have_attributes(
      communication_thread_id_snapshot: thread.id,
      contact_id_snapshot: thread.contact_id,
      to_assignee_id: assignee.id,
      to_assignee_name: 'Historic owner',
      to_team_id: team.id,
      to_team_name: 'historic team'
    )
  end

  it 'rejects direct Active Record and SQL mutation' do
    fact = create_fact

    expect { fact.update!(source: 'changed') }.to raise_error(ActiveRecord::RecordInvalid, /immutable/)
    expect do
      described_class.transaction(requires_new: true) do
        described_class.where(id: fact.id).update_all(source: 'changed') # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect do
      described_class.transaction(requires_new: true) { described_class.where(id: fact.id).delete_all }
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it 'allows deletion only inside account teardown and resets authorization on rollback' do
    fact = create_fact
    thread.destroy!
    account_fact_count = described_class.where(account: account).count

    expect { account.destroy! }.to change(described_class, :count).by(-account_fact_count)
    expect(described_class.where(id: fact.id)).not_to exist

    other_account = create(:account)
    other_thread = create(:communication_thread, account: other_account)
    other_fact = create(
      :communication_thread_state_transition_fact,
      account: other_account,
      communication_thread_id_snapshot: other_thread.id,
      thread_display_id_snapshot: other_thread.display_id,
      contact_id_snapshot: other_thread.contact_id
    )
    described_class.transaction do
      quoted = described_class.connection.quote(other_account.id.to_s)
      described_class.connection.select_value("SELECT set_config('onelink.account_teardown_id', #{quoted}, true)")
      raise ActiveRecord::Rollback
    end

    expect do
      described_class.transaction(requires_new: true) { described_class.where(id: other_fact.id).delete_all }
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)

    expect do
      described_class.transaction(requires_new: true) do
        quoted = described_class.connection.quote(other_account.id.to_s)
        described_class.connection.select_value("SELECT set_config('onelink.account_teardown_id', #{quoted}, true)")
        described_class.where(id: other_fact.id).delete_all
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it 'cascades facts for a legacy account delete path without new model callbacks' do
    legacy_account = create(:account)
    legacy_thread = create(:communication_thread, account: legacy_account)
    legacy_fact_ids = described_class.where(account: legacy_account).pluck(:id)
    legacy_contact = legacy_thread.contact
    legacy_thread.destroy!
    legacy_contact.destroy!

    expect { Account.where(id: legacy_account.id).delete_all }.not_to raise_error
    expect(described_class.where(id: legacy_fact_ids)).to be_empty
  end

  it 'rejects an AccountUser source record from another tenant in the database' do
    foreign = create(:account)
    member = foreign.account_users.find_by!(user: create(:user, account: foreign))
    row = build(
      :communication_thread_state_transition_fact,
      account: account,
      communication_thread_id_snapshot: thread.id,
      thread_display_id_snapshot: thread.display_id,
      contact_id_snapshot: thread.contact_id,
      source_record_type: 'AccountUser',
      source_record_id: member.id
    ).attributes.except('id').merge('created_at' => Time.current)

    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([row]) } # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::StatementInvalid, /source account user must belong to account/)
  end

  it 'requires a request fingerprint for app writes but not legacy database fallback' do
    row = build(
      :communication_thread_state_transition_fact,
      account: account,
      communication_thread_id_snapshot: thread.id,
      thread_display_id_snapshot: thread.display_id,
      contact_id_snapshot: thread.contact_id
    ).attributes.except('id').merge('created_at' => Time.current)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.insert_all!([row.merge('request_fingerprint' => nil)]) # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /chk_thread_state_facts_request_fingerprint/)

    fallback = row.merge('source' => 'database_projection_fallback', 'request_fingerprint' => nil)
    expect do
      described_class.insert_all!([fallback]) # rubocop:disable Rails/SkipsModelValidations
    end.to change(described_class, :count).by(1)
  end

  it 'rejects a requested event time later than its effective ordering time in SQL' do
    row = build(
      :communication_thread_state_transition_fact,
      account: account,
      communication_thread_id_snapshot: thread.id,
      thread_display_id_snapshot: thread.display_id,
      contact_id_snapshot: thread.contact_id
    ).attributes.except('id').merge('created_at' => Time.current)
    row['requested_occurred_at'] = row.fetch('occurred_at') + 1.second

    expect do
      described_class.transaction(requires_new: true) do
        described_class.insert_all!([row]) # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /chk_thread_state_facts_requested_occurred_at/)
  end

  it 'enforces the state-change and tenant actor contracts in the database' do
    row = build(
      :communication_thread_state_transition_fact,
      account: account,
      communication_thread_id_snapshot: thread.id,
      thread_display_id_snapshot: thread.display_id,
      contact_id_snapshot: thread.contact_id,
      event_kind: 'state_changed',
      from_status: 'open',
      to_status: 'open'
    ).attributes.except('id').merge('created_at' => Time.current)

    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([row]) } # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::StatementInvalid, /effective_change/)

    foreign_actor = create(:user, account: create(:account))
    row = row.merge(
      to_status: 'pending',
      actor_kind: 'user',
      actor_id: foreign_actor.id,
      actor_name: foreign_actor.name,
      idempotency_key: SecureRandom.uuid
    )
    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([row]) } # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::StatementInvalid, /actor must belong to account/)

    foreign_assistant = create(:captain_assistant, account: create(:account))
    captain_row = row.merge(actor_kind: 'captain', actor_id: foreign_assistant.id,
                            actor_name: foreign_assistant.name, idempotency_key: SecureRandom.uuid)
    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([captain_row]) } # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::StatementInvalid, /captain actor must belong to account/)
  end

  it 'rejects foreign routing and contact snapshots in the database' do
    row = build(
      :communication_thread_state_transition_fact,
      account: account,
      communication_thread_id_snapshot: thread.id,
      thread_display_id_snapshot: thread.display_id,
      contact_id_snapshot: thread.contact_id,
      event_kind: 'routing_changed',
      from_status: 'open',
      to_status: 'open'
    ).attributes.except('id').merge('created_at' => Time.current)

    foreign_actor = create(:user, account: create(:account))
    foreign_team = create(:team, account: create(:account))
    local_assignee = create(:user, account: account)
    local_team = create(:team, account: account)
    dimension_rows = [
      row.merge(actor_kind: 'system', actor_id: nil, actor_name: 'System', event_kind: 'routing_changed',
                from_status: 'open', to_status: 'open', to_assignee_id: foreign_actor.id,
                idempotency_key: SecureRandom.uuid),
      row.merge(actor_kind: 'system', actor_id: nil, actor_name: 'System', event_kind: 'routing_changed',
                from_status: 'open', to_status: 'open', to_team_id: foreign_team.id,
                idempotency_key: SecureRandom.uuid),
      row.merge(actor_kind: 'system', actor_id: nil, actor_name: 'System', event_kind: 'routing_changed',
                from_status: 'open', to_status: 'open', from_assignee_id: local_assignee.id,
                to_assignee_id: foreign_actor.id, idempotency_key: SecureRandom.uuid),
      row.merge(actor_kind: 'system', actor_id: nil, actor_name: 'System', event_kind: 'routing_changed',
                from_status: 'open', to_status: 'open', from_team_id: local_team.id,
                to_team_id: foreign_team.id,
                idempotency_key: SecureRandom.uuid)
    ]
    dimension_rows.each do |dimension_row|
      expect do
        described_class.transaction(requires_new: true) { described_class.insert_all!([dimension_row]) } # rubocop:disable Rails/SkipsModelValidations
      end.to raise_error(ActiveRecord::StatementInvalid, /must belong to account/)
    end

    foreign_contact = create(:contact, account: create(:account))
    thread.update_column(:contact_id, foreign_contact.id) # rubocop:disable Rails/SkipsModelValidations
    contact_row = row.merge(
      actor_kind: 'system', actor_id: nil, actor_name: 'System',
      contact_id_snapshot: foreign_contact.id, idempotency_key: SecureRandom.uuid
    )
    expect do
      described_class.transaction(requires_new: true) { described_class.insert_all!([contact_row]) } # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::StatementInvalid, /contact snapshot must belong to account/)
  end
end
