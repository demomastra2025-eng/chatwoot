require 'rails_helper'

RSpec.describe CommunicationThreads::CollaborationOccurrencesQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:owner) { create(:user, account: account) }
  let(:thread) { create(:communication_thread, account: account, assignee: owner) }
  let(:scope) { CommunicationThread.where(account_id: account.id) }
  let(:window) { { from_date: '2026-09-21', to_date: '2026-09-22' } }

  def query(fact_kind, extra = {}, threads_scope: scope)
    described_class.new(
      account: account,
      threads_scope: threads_scope,
      params: window.merge(fact_kind: fact_kind).merge(extra)
    )
  end

  def linked_conversation(target_thread = thread)
    link = create(:communication_thread_conversation, account: account, communication_thread: target_thread)
    link.conversation
  end

  it 'reports immutable participant lifecycle occurrences with participant and action actor kept separate' do
    participant = create(:user, account: account)
    action_actor = create(:user, account: account)
    fact = create(
      :communication_thread_participant_lifecycle_fact,
      account: account,
      communication_thread: thread,
      participant_id: participant.id,
      actor_kind: 'user',
      actor_type: 'User',
      actor_id: action_actor.id,
      action: 'add',
      occurred_at: Time.utc(2026, 9, 21, 18),
      created_at: Time.utc(2026, 9, 21, 18),
      reliable_since: Time.utc(2026, 9, 21, 18)
    )

    report = query('participant_lifecycle', { as_of_date: '2026-09-22' })
    aggregate = report.aggregate_rows.sole
    detail = report.drill_down_rows.sole

    expect(aggregate).to include(
      fact_kind: 'participant_lifecycle', action: 'add', occurrence_count: 1, distinct_thread_count: 1,
      actor: include(kind: 'user', type: 'User', id: participant.id)
    )
    expect(detail).to include(
      occurrence_id: fact.id,
      communication_thread_id: thread.id,
      actor: include(id: participant.id),
      action_actor: include(kind: 'user', type: 'User', id: action_actor.id),
      reliability: 'exact_immutable_occurrence'
    )
    expect(detail.dig(:actor, :id)).not_to eq(owner.id)
    expect(report.meta).to include(
      total_count: 1,
      owner_definition: 'canonical_thread_owner_is_not_collaboration_actor_and_receives_no_credit_from_this_report'
    )
  end

  it 'uses half-open Workspace windows and participant as-of observation time' do
    participant = create(:user, account: account)
    inside = create(
      :communication_thread_participant_lifecycle_fact,
      account: account,
      communication_thread: thread,
      participant_id: participant.id,
      occurred_at: Time.utc(2026, 9, 20, 19),
      created_at: Time.utc(2026, 9, 20, 19),
      reliable_since: Time.utc(2026, 9, 20, 19)
    )
    create(
      :communication_thread_participant_lifecycle_fact,
      account: account,
      communication_thread: thread,
      participant_id: participant.id,
      action: 'remove',
      occurred_at: Time.utc(2026, 9, 21, 19),
      created_at: Time.utc(2026, 9, 21, 19),
      reliable_since: inside.reliable_since
    )

    report = query('participant_lifecycle', { from_date: '2026-09-21', to_date: '2026-09-21', as_of_date: '2026-09-21' })

    expect(report.drill_down_rows.pluck(:occurrence_id)).to eq([inside.id])
    expect(report.meta).to include(
      from: '2026-09-20T19:00:00.000000Z',
      to: '2026-09-21T19:00:00.000000Z',
      as_of: '2026-09-21T19:00:00.000000Z'
    )
  end

  it 'keeps local date windows correct across a DST transition' do
    account.update!(settings: account.settings.merge('workspace_timezone' => 'America/New_York'))

    report = query(
      'participant_lifecycle',
      { from_date: '2026-11-01', to_date: '2026-11-01', as_of_date: '2026-11-01' }
    )

    expect(report.meta).to include(
      from: '2026-11-01T04:00:00.000000Z',
      to: '2026-11-02T05:00:00.000000Z',
      as_of: '2026-11-02T05:00:00.000000Z'
    )
  end

  it 'applies the supplied visible Thread scope and account boundary' do
    participant = create(:user, account: account)
    hidden_thread = create(:communication_thread, account: account)
    foreign_account = create(:account)
    foreign_thread = create(:communication_thread, account: foreign_account)
    create(
      :communication_thread_participant_lifecycle_fact,
      account: account, communication_thread: thread, participant_id: participant.id, occurred_at: Time.utc(2026, 9, 21, 6)
    )
    create(
      :communication_thread_participant_lifecycle_fact,
      account: account, communication_thread: hidden_thread, participant_id: participant.id, occurred_at: Time.utc(2026, 9, 21, 7)
    )
    create(
      :communication_thread_participant_lifecycle_fact,
      account: foreign_account, communication_thread: foreign_thread, occurred_at: Time.utc(2026, 9, 21, 8)
    )

    report = query(
      'participant_lifecycle',
      { as_of_date: '2026-09-22' },
      threads_scope: CommunicationThread.where(id: thread.id)
    )

    expect(report.drill_down_rows.pluck(:communication_thread_id)).to eq([thread.id])
  end

  it 'reports public replies and private messages as separate retained partial sources' do
    author = create(:user, account: account)
    conversation = linked_conversation
    public_reply = create(:message, account: account, inbox: conversation.inbox, conversation: conversation, sender: author,
                                    message_type: :outgoing, private: false, created_at: Time.utc(2026, 9, 21, 9))
    private_message = create(:message, account: account, inbox: conversation.inbox, conversation: conversation, sender: author,
                                       message_type: :outgoing, private: true, created_at: Time.utc(2026, 9, 21, 10),
                                       content_attributes: { deleted: true })
    create(:message, account: account, inbox: conversation.inbox, conversation: conversation, sender: author,
                     message_type: :incoming, private: false, created_at: Time.utc(2026, 9, 21, 11))
    create(:message, account: account, inbox: conversation.inbox, conversation: conversation, sender: author,
                     message_type: :outgoing, private: false, content_type: :voice_call, created_at: Time.utc(2026, 9, 21, 12))
    automated = create(:message, account: account, inbox: conversation.inbox, conversation: conversation, sender: author,
                                 message_type: :outgoing, private: false, created_at: Time.utc(2026, 9, 21, 13))
    automated.update_columns(content_attributes: { automation_rule_id: 7 }) # rubocop:disable Rails/SkipsModelValidations
    external_echo = create(:message, account: account, inbox: conversation.inbox, conversation: conversation,
                                     message_type: :outgoing, private: false, created_at: Time.utc(2026, 9, 21, 13, 1))
    external_echo.update_columns(sender_type: nil, sender_id: nil, content_attributes: { external_echo: true }) # rubocop:disable Rails/SkipsModelValidations
    external_automation = create(:message, account: account, inbox: conversation.inbox, conversation: conversation,
                                           message_type: :outgoing, private: false, created_at: Time.utc(2026, 9, 21, 13, 2))
    external_automation.update_columns( # rubocop:disable Rails/SkipsModelValidations
      sender_type: nil, sender_id: nil, content_attributes: { external_echo: true, automation_rule_id: 7 }
    )
    external_campaign = create(:message, account: account, inbox: conversation.inbox, conversation: conversation,
                                         message_type: :outgoing, private: false, created_at: Time.utc(2026, 9, 21, 13, 3))
    external_campaign.update_columns( # rubocop:disable Rails/SkipsModelValidations
      sender_type: nil, sender_id: nil, content_attributes: { external_echo: true }, additional_attributes: { campaign_id: 9 }
    )
    malformed = create(:message, account: account, inbox: conversation.inbox, conversation: conversation,
                                 message_type: :outgoing, private: false, created_at: Time.utc(2026, 9, 21, 13, 4))
    malformed.update_columns(sender_type: nil, sender_id: nil, content_attributes: '{not-json') # rubocop:disable Rails/SkipsModelValidations
    physically_deleted = create(
      :message, account: account, inbox: conversation.inbox, conversation: conversation, sender: author,
                message_type: :outgoing, private: false, created_at: Time.utc(2026, 9, 21, 14)
    )
    physically_deleted.destroy!

    replies = query('authored_customer_reply')
    private_messages = query('private_message')

    expect(replies.drill_down_rows.pluck(:occurrence_id)).to eq([external_echo.id, public_reply.id])
    expect(replies.drill_down_rows.find { |row| row[:occurrence_id] == external_echo.id }[:actor]).to include(
      kind: 'unknown', type: nil, id: nil, identity_state: 'unknown_deleted_or_missing_identity'
    )
    expect(replies.drill_down_rows).to all(include(deleted: false))
    expect(private_messages.drill_down_rows).to contain_exactly(include(occurrence_id: private_message.id, deleted: true))
    expect(private_messages.aggregate_rows.sole).to include(occurrence_count: 1, deleted_count: 1, distinct_thread_count: 1)
    expect(replies.meta.dig(:source_contract, :reliability)).to eq('retained_but_deletable_partial_occurrence')
    expect(replies.meta.dig(:source_contract, :as_of_supported)).to be(false)
  end

  it 'preserves typed Captain, customer, system, deleted, and unknown sender identities without constantization' do
    conversation = linked_conversation
    rows = [
      ['Captain::Assistant', 91, 'captain', 'persisted_raw_identity', 'Captain::Assistant'],
      ['Contact', 92, 'customer', 'persisted_raw_identity', 'Contact'],
      [nil, nil, 'system', 'system', 'System'],
      [nil, 94, 'unknown', 'persisted_raw_identity', nil],
      ['User', nil, 'user', 'unknown_deleted_or_missing_identity', 'User'],
      ['Legacy::Actor', 93, 'unknown', 'persisted_raw_identity', 'Legacy::Actor']
    ]
    rows.each_with_index do |(type, id, _kind, _state, _payload_type), index|
      message = create(:message, account: account, inbox: conversation.inbox, conversation: conversation,
                                 message_type: :outgoing, private: true, created_at: Time.utc(2026, 9, 21, 9, index))
      message.update_columns(sender_type: type, sender_id: id) # rubocop:disable Rails/SkipsModelValidations
    end

    actors = query('private_message').drill_down_rows.map { |row| row.fetch(:actor) }

    rows.each do |_type, id, kind, state, payload_type|
      expect(actors).to include(include(type: payload_type, id: id, kind: kind, identity_state: state))
    end
  end

  it 'keeps aggregate and details parity, stable ordering, pagination, and fingerprint' do
    author = create(:user, account: account)
    conversation = linked_conversation
    first = create(:message, account: account, inbox: conversation.inbox, conversation: conversation, sender: author,
                             message_type: :outgoing, created_at: Time.utc(2026, 9, 21, 9))
    second = create(:message, account: account, inbox: conversation.inbox, conversation: conversation, sender: author,
                              message_type: :outgoing, created_at: Time.utc(2026, 9, 21, 10))

    aggregate = query('authored_customer_reply')
    details = query('authored_customer_reply', { page: 1, per_page: 1 })

    expect(aggregate.aggregate_rows.sole).to include(occurrence_count: 2, distinct_thread_count: 1)
    expect(details.drill_down_rows.pluck(:occurrence_id)).to eq([second.id])
    expect(details.pagination_meta).to include(total_count: 2, page: 1, per_page: 1)
    expect(aggregate.meta[:query_fingerprint]).to eq(details.pagination_meta[:query_fingerprint])
    plan = ApplicationRecord.connection.execute("EXPLAIN #{details.send(:relation).to_sql}")
    expect(plan.to_a).to be_present
    expect(first.id).to be < second.id
  end

  it 'rejects unsupported temporal claims, unavailable calls, invalid windows, and unbounded pagination' do
    expect { query('authored_customer_reply', { as_of_date: '2026-09-22' }) }
      .to raise_error(described_class::InvalidQuery, 'as_of_date is not supported for authored_customer_reply retained rows')
    expect { query('participant_lifecycle') }.to raise_error(described_class::InvalidQuery, 'as_of_date is required')
    expect { query('manual_call') }
      .to raise_error(described_class::InvalidQuery, 'manual_call occurrence source is unavailable: durable actor fact is missing')
    expect { query('unknown') }.to raise_error(described_class::InvalidQuery, 'fact_kind is invalid')
    expect { query('private_message', { to_date: '2026-09-20' }) }
      .to raise_error(described_class::InvalidQuery, 'to_date must be on or after from_date')
    expect { query('private_message', { per_page: 101 }).pagination_meta }
      .to raise_error(described_class::InvalidQuery, 'per_page must not exceed 100')
  end
end
