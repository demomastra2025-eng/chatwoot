# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reports::AiAgentsQuery do
  let(:account) { create(:account, reporting_timezone: 'Europe/Berlin') }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:specialist) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, created_at: Time.iso8601('2026-01-01T12:00:00Z')) }
  let(:event_at) { Time.iso8601('2026-03-29T12:00:00Z') }
  let(:date_params) { { from_date: '2026-03-29', to_date: '2026-03-29' } }

  def message_attributes(actor: assistant, chat: conversation, at: event_at, **attributes)
    {
      account_id: chat.account_id, conversation_id: chat.id, inbox_id: chat.inbox_id,
      sender_type: 'Captain::Assistant', sender_id: actor.id,
      message_type: Message.message_types.fetch('outgoing'), private: false,
      content: 'Public AI reply', created_at: at, updated_at: at
    }.merge(attributes)
  end

  def add_message(**attributes)
    Message.insert_all!([message_attributes(**attributes)])
  end

  # Audit fixtures keep their historic classification instead of invoking today's classifier callback.
  def add_outcome(actor: assistant, chat: conversation, at: event_at, state: 'completed', reason_id: nil, label: nil, **attributes)
    classification = { 'state' => state, 'duration_ms' => 999 }
    classification['reasons'] = [{ 'id' => reason_id, 'label' => label }] if reason_id
    metadata = state ? { 'outcome_classification' => classification } : {}
    metadata['outcome_reason_id'] = reason_id if reason_id
    ConversationStatusTransition.insert_all!([
      {
        account_id: chat.account_id, conversation_id: chat.id, actor_type: 'Captain::Assistant', actor_id: actor.id,
        from_status: 'pending', to_status: 'resolved', source: 'captain', reason: label,
        metadata: metadata, created_at: at, updated_at: at
      }.merge(attributes)
    ])
  end

  def report(**params)
    described_class.new(account: account, params: date_params.merge(params)).perform
  end

  it 'counts native AI authors and outcome actors in old conversations without treating closure as a sale' do
    add_message
    add_message(at: event_at + 1.minute)
    add_message(actor: specialist)
    add_outcome(reason_id: 'question_resolved', label: 'Question answered')
    add_outcome(actor: specialist, to_status: 'open', state: 'pending', source: 'system')

    payload = report

    expect(payload[:totals]).to include(message_count: 3, conversation_count: 1, outcome_count: 2, completion_count: 1, handoff_count: 1)
    expect(payload.dig(:totals, :classification_counts)).to include(completed: 1, pending: 1)
    expect(payload[:agent_breakdown]).to contain_exactly(
      include(assistant_id: assistant.id, message_count: 2, conversation_count: 1, completion_count: 1),
      include(assistant_id: specialist.id, message_count: 1, conversation_count: 1, handoff_count: 1)
    )
    expect(payload[:totals].keys.grep(/rate|sale|success/)).to be_empty
    expect(payload[:series].sole).to include(date: '2026-03-29', message_count: 3, conversation_count: 1)
  end

  it 'includes only public outgoing Captain messages and actual Captain/system status changes' do
    add_message
    add_message(status: Message.statuses.fetch('failed'))
    add_message(private: true)
    add_message(message_type: Message.message_types.fetch('incoming'))
    add_message(message_type: Message.message_types.fetch('activity'))
    add_message(sender_type: 'User')
    add_message(sender_type: 'AgentBot')
    add_outcome
    add_outcome(source: 'manual')
    add_outcome(source: 'auto_resolve')
    add_outcome(actor_type: 'User')
    add_outcome(from_status: 'resolved')
    add_outcome(to_status: 'pending', from_status: 'open')

    payload = report

    expect(payload[:totals]).to include(message_count: 2, outcome_count: 1, completion_count: 1, handoff_count: 0)
    expect(payload.dig(:totals, :classification_counts, :completed)).to eq(1)
  end

  it 'uses local event dates across DST with inclusive days and keeps total conversations distinct across days' do
    from_at = Time.iso8601('2026-03-28T23:00:00Z')
    next_day = Time.iso8601('2026-03-29T22:00:00Z')
    until_at = Time.iso8601('2026-03-30T22:00:00Z')
    add_message(at: from_at - 1.second)
    add_message(at: from_at)
    add_message(at: next_day)
    add_message(at: until_at)
    add_outcome(at: next_day - 1.second, to_status: 'open')
    add_outcome(at: next_day)
    add_outcome(at: until_at)

    query = described_class.new(account: account, params: date_params.merge(to_date: '2026-03-30'))
    payload = query.perform

    expect(payload[:totals]).to include(message_count: 2, conversation_count: 1, completion_count: 1, handoff_count: 1)
    expect(payload[:series]).to contain_exactly(
      include(date: '2026-03-29', message_count: 1, conversation_count: 1, completion_count: 0, handoff_count: 1),
      include(date: '2026-03-30', message_count: 1, conversation_count: 1, completion_count: 1, handoff_count: 0)
    )
    expect(payload[:series].sum { |row| row[:conversation_count] }).to eq(2)
    expect(query.meta).to include(from_date: '2026-03-29', to_date: '2026-03-30', timezone: 'Europe/Berlin', assistant_id: nil)
  end

  it 'separates incomplete and legacy classification from completed reasons and exposes no invented cost or response latency' do
    %w[completed pending processing failed insufficient_context].each do |state|
      add_outcome(state: state, reason_id: 'other', label: 'Other')
    end
    add_outcome(state: nil, reason_id: 'legacy_reason', label: 'Legacy explanation')
    add_outcome(state: 'future_state')
    add_outcome(metadata: { 'outcome_classification' => 'invalid historic value' })

    payload = report

    expect(payload.dig(:totals, :classification_counts)).to eq(
      completed: 1, pending: 1, processing: 1, failed: 1, insufficient_context: 1, unclassified: 3
    )
    expect(payload[:totals]).to include(outcome_count: 8, conversation_count: 1, message_count: 0)
    expect(payload[:reasons]).to contain_exactly(include(reason_id: 'other', count: 1, type: 'completion'))
    expect(payload[:availability]).to eq(
      latency: { available: false, reason: 'native_attribution_unavailable' },
      cost: { available: false, reason: 'native_attribution_unavailable' }
    )
  end

  it 'groups reasons by actor, native outcome type and stable ID even after a label changes' do
    add_outcome(reason_id: 'custom_reason', label: 'Old label')
    add_outcome(reason_id: 'custom_reason', label: 'Current snapshot label', at: event_at + 1.minute)
    add_outcome(reason_id: 'custom_reason', label: 'Handoff label', to_status: 'open')
    add_outcome(actor: specialist, reason_id: 'custom_reason', label: 'Specialist label')
    add_outcome(reason_id: 'custom_reason', label: 'Incomplete label', state: 'insufficient_context', at: event_at + 2.minutes)
    add_outcome(reason_id: 'other', label: 'Other', metadata: {
                  'outcome_classification' => { 'state' => 'completed', 'reasons' => 'malformed' },
                  'outcome_reason_id' => 'other'
                })

    expect(report[:reasons]).to contain_exactly(
      { assistant_id: assistant.id, type: 'completion', reason_id: 'custom_reason', label: 'Current snapshot label', count: 2 },
      { assistant_id: assistant.id, type: 'handoff', reason_id: 'custom_reason', label: 'Handoff label', count: 1 },
      { assistant_id: specialist.id, type: 'completion', reason_id: 'custom_reason', label: 'Specialist label', count: 1 },
      { assistant_id: assistant.id, type: 'completion', reason_id: 'other', label: 'Other', count: 1 }
    )
  end

  context 'with Microsoft Decision 1 outcome classifications' do
    let(:decision_model) { 'microsoft/microsoft-decision-1' }

    def decision_metadata(type:, label:, state: 'completed', reason_id: 'custom_reason', explanation: 'Generated model explanation')
      {
        'outcome_classification' => {
          'state' => state, 'type' => type, 'method' => 'classifier', 'model' => decision_model,
          'reason_id' => reason_id, 'explanation' => explanation,
          'reasons' => [{ 'id' => reason_id, 'label' => label }, { 'id' => 'other', 'label' => 'Other' }]
        },
        'outcome_reason_id' => reason_id, 'outcome_reason_type' => type, 'outcome_reason_explanation' => explanation
      }
    end

    it 'counts completed reasons by their native actor and outcome type using saved labels' do
      add_outcome(reason: 'Historical configured label', metadata: decision_metadata(type: 'completion', label: 'Historical configured label'))
      add_outcome(at: event_at + 1.minute, reason: 'Saved configured label',
                  metadata: decision_metadata(type: 'completion', label: 'Saved configured label'))
      add_outcome(actor: specialist, to_status: 'open', reason: 'Configured handoff label',
                  metadata: decision_metadata(type: 'handoff', label: 'Configured handoff label'))
      add_outcome(actor: specialist, reason: 'Specialist completion label',
                  metadata: decision_metadata(type: 'completion', label: 'Specialist completion label'))

      payload = report

      expect(payload[:totals]).to include(outcome_count: 4, completion_count: 3, handoff_count: 1)
      expect(payload.dig(:totals, :classification_counts, :completed)).to eq(4)
      expect(payload[:reasons]).to contain_exactly(
        { assistant_id: assistant.id, type: 'completion', reason_id: 'custom_reason', label: 'Saved configured label', count: 2 },
        { assistant_id: specialist.id, type: 'handoff', reason_id: 'custom_reason', label: 'Configured handoff label', count: 1 },
        { assistant_id: specialist.id, type: 'completion', reason_id: 'custom_reason', label: 'Specialist completion label', count: 1 }
      )
      expect(payload[:agent_breakdown]).to contain_exactly(
        include(assistant_id: assistant.id, name: assistant.name, outcome_count: 2, completion_count: 2, handoff_count: 0),
        include(assistant_id: specialist.id, name: specialist.name, outcome_count: 2, completion_count: 1, handoff_count: 1)
      )
    end

    it 'keeps pending and failed events separate even when they retain selected reason fields' do
      add_outcome(metadata: decision_metadata(type: 'completion', label: 'Completed reason'))
      add_outcome(to_status: 'open', metadata: decision_metadata(type: 'handoff', label: 'Pending reason', state: 'pending'))
      add_outcome(actor: specialist, metadata: decision_metadata(type: 'completion', label: 'Failed reason', state: 'failed'))

      payload = report

      expect(payload[:totals]).to include(outcome_count: 3, completion_count: 2, handoff_count: 1)
      expect(payload.dig(:totals, :classification_counts)).to eq(
        completed: 1, pending: 1, processing: 0, failed: 1, insufficient_context: 0, unclassified: 0
      )
      expect(payload[:series].sole[:classification_counts]).to eq(payload[:totals][:classification_counts])
      expect(payload[:reasons]).to eq([
        { assistant_id: assistant.id, type: 'completion', reason_id: 'custom_reason', label: 'Completed reason', count: 1 }
      ])
      expect(payload[:agent_breakdown]).to contain_exactly(
        include(assistant_id: assistant.id, classification_counts: include(completed: 1, pending: 1, failed: 0)),
        include(assistant_id: specialist.id, classification_counts: include(completed: 0, pending: 0, failed: 1))
      )
    end

    it 'does not create reason buckets from model text or allowed but unselected definitions' do
      generated_text = 'A new reason invented in the model explanation'
      add_outcome(metadata: decision_metadata(type: 'completion', label: 'Configured reason', explanation: generated_text))
      text_only = decision_metadata(type: 'completion', label: 'Unselected configured reason', explanation: generated_text)
                  .except('outcome_reason_id')
      add_outcome(reason: generated_text, metadata: text_only)

      payload = report

      expect(payload[:totals]).to include(outcome_count: 2, completion_count: 2)
      expect(payload.dig(:totals, :classification_counts, :completed)).to eq(2)
      expect(payload[:reasons]).to eq([
        { assistant_id: assistant.id, type: 'completion', reason_id: 'custom_reason', label: 'Configured reason', count: 1 }
      ])
    end

    it 'excludes Decision 1 events belonging to foreign accounts or inconsistent actor and conversation references' do
      foreign_account = create(:account)
      foreign_assistant = create(:captain_assistant, account: foreign_account, name: 'Foreign private agent')
      foreign_conversation = create(:conversation, account: foreign_account)
      foreign_metadata = decision_metadata(type: 'completion', reason_id: 'foreign_reason', label: 'Foreign private reason')
      add_outcome(metadata: decision_metadata(type: 'completion', label: 'Owned configured reason'))
      add_outcome(actor: foreign_assistant, metadata: foreign_metadata)
      add_outcome(chat: foreign_conversation, actor: foreign_assistant, metadata: foreign_metadata)
      add_outcome(chat: foreign_conversation, account_id: account.id, metadata: foreign_metadata)

      payload = report

      expect(payload[:totals]).to include(outcome_count: 1, completion_count: 1, conversation_count: 1)
      expect(payload.dig(:totals, :classification_counts, :completed)).to eq(1)
      expect(payload[:agent_breakdown]).to contain_exactly(include(assistant_id: assistant.id, outcome_count: 1))
      expect(payload[:reasons]).to eq([
        { assistant_id: assistant.id, type: 'completion', reason_id: 'custom_reason', label: 'Owned configured reason', count: 1 }
      ])
      expect(payload.to_json).not_to include('Foreign private agent', 'Foreign private reason')
      expect(report(assistant_id: assistant.id)[:reasons]).to eq(payload[:reasons])
    end
  end

  it 'filters the actual specialist including inactive historical actors without requiring an inbox assignment' do
    specialist.update!(active: false)
    add_message
    add_outcome
    add_message(actor: specialist)
    add_outcome(actor: specialist, to_status: 'open', state: 'failed')

    query = described_class.new(account: account, params: date_params.merge(assistant_id: specialist.id.to_s))
    payload = query.perform

    expect(payload[:totals]).to include(message_count: 1, conversation_count: 1, completion_count: 0, handoff_count: 1)
    expect(payload.dig(:totals, :classification_counts, :failed)).to eq(1)
    expect(payload[:agent_breakdown]).to contain_exactly(include(assistant_id: specialist.id, active: false))
    expect(payload[:agents]).to include({ id: specialist.id, name: specialist.name, active: false })
    expect(query.meta[:assistant_id]).to eq(specialist.id)
  end

  it 'excludes foreign account rows, actors and inconsistent conversation references' do
    foreign_account = create(:account)
    foreign_assistant = create(:captain_assistant, account: foreign_account)
    foreign_conversation = create(:conversation, account: foreign_account)
    add_message
    add_outcome
    add_message(actor: foreign_assistant)
    add_outcome(actor: foreign_assistant)
    add_message(chat: foreign_conversation, actor: foreign_assistant)
    add_outcome(chat: foreign_conversation, actor: foreign_assistant)
    add_message(chat: foreign_conversation, account_id: account.id)
    add_outcome(chat: foreign_conversation, account_id: account.id)

    payload = report

    expect(payload[:totals]).to include(message_count: 1, outcome_count: 1, conversation_count: 1)
    expect(payload[:agents].pluck(:id)).not_to include(foreign_assistant.id)
    expect(payload[:agent_breakdown]).to contain_exactly(include(assistant_id: assistant.id))
    expect(payload.to_json).not_to include(foreign_assistant.name)
  end

  it 'keeps deleted actor outcomes without inferring the author of messages nullified by native deletion' do
    add_message
    add_outcome(reason_id: 'question_resolved', label: 'Question answered')
    deleted_id = assistant.id
    assistant.destroy!

    payload = report

    expect(payload[:totals]).to include(message_count: 0, outcome_count: 1)
    expect(payload[:agent_breakdown]).to contain_exactly(include(assistant_id: deleted_id, name: nil, active: nil))
    expect(payload[:agents]).to be_empty
    expect(payload[:reasons]).to contain_exactly(include(assistant_id: deleted_id, reason_id: 'question_resolved', count: 1))
  end

  it 'counts imported orphan messages only when they retain an explicit native author ID' do
    deleted_id = assistant.id
    assistant.destroy!
    add_message
    add_message(sender_type: nil, sender_id: nil)

    payload = report

    expect(payload[:totals]).to include(message_count: 1, conversation_count: 1, outcome_count: 0)
    expect(payload[:agent_breakdown]).to contain_exactly(include(assistant_id: deleted_id, name: nil, active: nil))
    expect(payload[:agents]).to be_empty
  end

  it 'rejects foreign or malformed actor filters before producing a report' do
    foreign_assistant = create(:captain_assistant)

    [foreign_assistant.id, '0', '-1', 'assistant_1', '9223372036854775808', "1' OR 1=1 --", ['1']].each do |value|
      expect do
        described_class.new(account: account, params: date_params.merge(assistant_id: value))
      end.to raise_error(described_class::InvalidAssistantFilter, 'assistant_id must identify an assistant in this account')
    end
  end

  it 'aggregates every persisted message beyond legacy report sample limits' do
    Message.insert_all!(Array.new(1001) { message_attributes })

    payload = report

    expect(payload[:totals]).to include(message_count: 1001, conversation_count: 1)
    expect(payload[:series].sole[:message_count]).to eq(1001)
    expect(payload[:agent_breakdown].sole[:message_count]).to eq(1001)
  end

  it 'returns zero-filled days and all current account filter choices when no AI events exist' do
    assistant.update!(active: false)

    payload = report(to_date: '2026-03-31')

    expect(payload[:totals]).to include(message_count: 0, conversation_count: 0, outcome_count: 0)
    expect(payload.dig(:totals, :classification_counts).values).to all(eq(0))
    expect(payload[:series].pluck(:date)).to eq(%w[2026-03-29 2026-03-30 2026-03-31])
    expect(payload[:series].pluck(:message_count)).to eq([0, 0, 0])
    expect(payload[:agents]).to eq([{ id: assistant.id, name: assistant.name, active: false }])
    expect(payload.values_at(:agent_breakdown, :reasons)).to eq([[], []])
  end
end
