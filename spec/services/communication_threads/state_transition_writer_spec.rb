require 'rails_helper'

RSpec.describe CommunicationThreads::StateTransitionWriter do
  let(:account) { create(:account) }
  let(:thread) { create(:communication_thread, account: account, status: :open) }
  let(:actor) { create(:user, account: account, name: 'Operator') }
  let(:event_id) { SecureRandom.uuid }
  let(:occurred_at) { Time.utc(2026, 9, 22, 18, 30) }

  def writer(attributes:, **)
    described_class.new(
      thread: thread,
      attributes: attributes,
      actor: actor,
      source: 'spec_command',
      source_record: thread,
      source_event_id: event_id,
      occurred_at: occurred_at,
      **
    )
  end

  it 'records one atomic routing change with before/after snapshots' do
    old_owner = create(:user, account: account, name: 'Old owner')
    old_team = create(:team, account: account, name: 'Old team')
    new_owner = create(:user, account: account, name: 'New owner')
    new_team = create(:team, account: account, name: 'New team')
    thread.update!(assignee: old_owner, team: old_team)

    expect do
      writer(attributes: { assignee_id: new_owner.id, team_id: new_team.id }).perform
    end.to change(CommunicationThreadStateTransitionFact, :count).by(1)

    expect(CommunicationThreadStateTransitionFact.last).to have_attributes(
      event_kind: 'routing_changed',
      from_assignee_id: old_owner.id,
      from_assignee_name: 'Old owner',
      to_assignee_id: new_owner.id,
      to_assignee_name: 'New owner',
      from_team_id: old_team.id,
      from_team_name: 'old team',
      to_team_id: new_team.id,
      to_team_name: 'new team',
      from_status: 'open',
      to_status: 'open',
      actor_kind: 'user',
      actor_id: actor.id,
      source_event_id: event_id,
      requested_occurred_at: occurred_at
    )
    expect(CommunicationThreadStateTransitionFact.last.reliable_since)
      .to eq(CommunicationThreadStateTransitionFact.last.occurred_at)
  end

  it 'classifies resolved, reopened and non-terminal status changes' do
    resolved = writer(attributes: { status: 'resolved' }).perform
    reopened = described_class.new(
      thread: thread,
      attributes: { status: 'open' },
      source_event_id: SecureRandom.uuid,
      occurred_at: occurred_at + 1.second
    ).perform
    changed = described_class.new(
      thread: thread,
      attributes: { status: 'pending' },
      source_event_id: SecureRandom.uuid,
      occurred_at: occurred_at + 2.seconds
    ).perform

    expect([resolved.event_kind, reopened.event_kind, changed.event_kind]).to eq(%w[resolved reopened state_changed])
  end

  it 'records owner and team unassignment as one routing fact' do
    owner = create(:user, account: account, name: 'Previous owner')
    team = create(:team, account: account, name: 'Previous team')
    thread.update!(assignee: owner, team: team)

    fact = writer(attributes: { assignee_id: nil, team_id: nil }).perform

    expect(fact).to have_attributes(
      event_kind: 'routing_changed',
      from_assignee_id: owner.id,
      from_assignee_name: 'Previous owner',
      to_assignee_id: nil,
      from_team_id: team.id,
      from_team_name: 'previous team',
      to_team_id: nil
    )
  end

  it 'stores a typed automation actor snapshot' do
    policy = create(:assignment_policy, account: account)
    team = create(:team, account: account)

    fact = described_class.new(
      thread: thread,
      attributes: { team_id: team.id },
      actor: policy,
      source: 'assignment_policy',
      source_record: policy,
      source_event_id: event_id,
      occurred_at: occurred_at
    ).perform

    expect(fact).to have_attributes(
      actor_kind: 'automation',
      actor_id: policy.id,
      source_record_type: 'AssignmentPolicy',
      source_record_id: policy.id
    )
  end

  it 'does not append a fact for a no-op or a non-state projection update' do
    thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)

    expect(writer(attributes: { status: 'open', priority: 'urgent' }).perform).to be_nil
    expect(thread.reload).to be_urgent
    expect(CommunicationThreadStateTransitionFact.where('id > ?', baseline_id)).to be_empty
  end

  it 'returns the same byte-equivalent fact for an exact replay' do
    operation = writer(attributes: { status: 'resolved' })
    first = operation.perform
    second = operation.perform

    expect(second).to eq(first)
    expect(second.attributes).to eq(first.reload.attributes)
    expect(CommunicationThreadStateTransitionFact.where(account: account, source_event_id: event_id).count).to eq(1)
  end

  it 'rejects a stale replay without rewinding a later Thread transition' do
    first = writer(attributes: { status: 'resolved' })
    first.perform
    described_class.new(thread: thread, attributes: { status: 'open' }, source_event_id: SecureRandom.uuid).perform
    baseline = CommunicationThreadStateTransitionFact.count

    expect { first.perform }.to raise_error(ArgumentError, /stale.*replay/)
    expect(thread.reload).to be_open
    expect(CommunicationThreadStateTransitionFact.count).to eq(baseline)
  end

  it 'recovers a unique-key race after rolling back its savepoint' do
    operation = writer(attributes: { status: 'resolved' })
    fact = operation.perform
    before_state = { assignee_id: nil, assignee_name: nil, team_id: nil, team_name: nil, status: 'open' }
    after_state = before_state.merge(status: 'resolved')
    payload = operation.send(:fact_payload, before_state, after_state)
    allow(CommunicationThreadStateTransitionFact).to receive(:find_by).and_return(nil)

    expect(operation.send(:persist_fact!, payload)).to eq(fact)
    expect(CommunicationThreadStateTransitionFact.where(account: account, source_event_id: event_id).count).to eq(1)
  end

  it 'normalizes an external non-UUID operation identity deterministically' do
    first = described_class.new(
      thread: thread,
      attributes: { status: 'resolved' },
      source_event_id: 'provider-event-42',
      occurred_at: occurred_at
    ).perform
    second = described_class.new(
      thread: thread,
      attributes: { status: 'resolved' },
      source_event_id: 'provider-event-42',
      occurred_at: occurred_at
    ).perform

    expect(second).to eq(first)
    expect(first.source_event_id).to match(CommunicationThreads::StateTransitionWriter::UUID_PATTERN)
  end

  it 'rejects a conflicting replay under the same operation identity' do
    writer(attributes: { status: 'resolved' }).perform

    conflicting = described_class.new(
      thread: thread,
      attributes: { status: 'resolved' },
      actor: actor,
      source: 'different_source',
      source_record: thread,
      source_event_id: event_id,
      occurred_at: occurred_at
    )

    expect { conflicting.perform }.to raise_error(ArgumentError, /idempotency key/)
  end

  it 'rejects a replay that adds or replaces a non-state projection field' do
    writer(attributes: { status: 'resolved' }).perform

    expect { writer(attributes: { status: 'resolved', priority: 'urgent' }).perform }
      .to raise_error(ArgumentError, /idempotency key/)
    expect { writer(attributes: { priority: 'urgent' }).perform }
      .to raise_error(ArgumentError, /idempotency key/)
    expect(thread.reload.priority).to be_nil
  end

  it 'rejects a replay that reuses the event UUID with another occurrence time' do
    writer(attributes: { status: 'resolved' }).perform

    conflicting = writer(attributes: { status: 'resolved' }, occurred_at: occurred_at + 1.second)

    expect { conflicting.perform }.to raise_error(ArgumentError, /idempotency key/)
    expect(CommunicationThreadStateTransitionFact.where(account: account, source_event_id: event_id).count).to eq(1)
  end

  it 'rejects cross-account actors and source records without changing projection' do
    thread
    baseline_id = CommunicationThreadStateTransitionFact.maximum(:id)
    foreign_account = create(:account)
    foreign_actor = create(:user, account: foreign_account)
    foreign_thread = create(:communication_thread, account: foreign_account)

    operation = described_class.new(
      thread: thread,
      attributes: { status: 'resolved' },
      actor: foreign_actor,
      source_record: foreign_thread
    )

    expect { operation.perform }.to raise_error(ActiveRecord::RecordNotFound, /actor belongs to another account/)
    expect(thread.reload).to be_open
    expect(CommunicationThreadStateTransitionFact.where(account: account).where('id > ?', baseline_id)).to be_empty
  end

  it 'rolls back the projection when fact insertion fails' do
    allow(CommunicationThreadStateTransitionFact).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'insert failed')

    expect { writer(attributes: { status: 'resolved' }).perform }
      .to raise_error(ActiveRecord::StatementInvalid, /insert failed/)
    expect(thread.reload).to be_open
  end
end
