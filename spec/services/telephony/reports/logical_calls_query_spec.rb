require 'rails_helper'

RSpec.describe Telephony::Reports::LogicalCallsQuery do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account) }
  let(:voice_inbox) { voice_channel.inbox }
  let(:from_local) { '2026-01-01T00:00:00' }
  let(:to_local) { '2026-02-01T00:00:00' }
  let(:as_of) { '2026-02-02T00:00:00Z' }
  let(:base_params) { { from_local: from_local, to_local: to_local, as_of: as_of } }

  def create_source(ref:, inbox: voice_inbox, account_record: account, direction: 'inbound')
    conversation = create(:conversation, account: account_record, inbox: inbox)
    create(
      :telephony_call_session,
      account: account_record,
      conversation: conversation,
      contact: conversation.contact,
      inbox: inbox,
      number_binding: nil,
      external_call_ref: ref,
      provider: 'sipuni',
      direction: direction,
      started_at: nil,
      metadata: {}
    )
  end

  def insert_occurrence( # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
    kind:, identity:, occurred_at:, source: nil, created_at: occurred_at + 1.minute, **attributes
  )
    source ||= create_source(ref: identity)
    values = {
      account_id: source.account_id,
      logical_call_identity: identity,
      logical_call_ref: identity,
      occurrence_kind: kind,
      source_kind: 'telephony_call_session',
      source_id: source.id,
      source_ref: source.external_call_ref,
      provider: source.provider,
      direction: source.direction,
      inbox_id_snapshot: source.inbox_id,
      actor_kind: 'unknown',
      occurred_at: occurred_at,
      connected_at: kind == 'connected' ? occurred_at : nil,
      terminal_at: kind == 'terminal' ? occurred_at : nil,
      reliability: 'exact',
      reliable_since: created_at,
      source_version: 1,
      definition_version: 1,
      revision: 1,
      created_at: created_at
    }.merge(attributes)
    Telephony::LogicalCallOccurrence.insert_all!([values]) # rubocop:disable Rails/SkipsModelValidations
    Telephony::LogicalCallOccurrence.order(:id).last
  end

  def query(params = nil, scope: account.telephony_logical_call_occurrences, **keyword_params)
    described_class.new(
      account: account,
      occurrences_scope: scope,
      params: base_params.merge(params || {}).merge(keyword_params)
    )
  end

  before { voice_inbox }

  it 'counts logical calls by event-specific half-open windows and deduplicates superseded revisions' do
    inside = Time.utc(2026, 1, 10, 10)
    source = create_source(ref: 'call-one')
    insert_occurrence(kind: 'attempted', identity: 'call-one', occurred_at: inside, source: source)
    connected = insert_occurrence(kind: 'connected', identity: 'call-one', occurred_at: inside + 5.seconds, source: source)
    insert_occurrence(
      kind: 'connected', identity: 'call-one', occurred_at: inside + 6.seconds, source: source,
      revision: 2, supersedes_occurrence_id: connected.id, created_at: inside + 2.minutes
    )
    insert_occurrence(kind: 'terminal', identity: 'call-one', occurred_at: inside + 30.seconds, source: source, duration_seconds: 24)
    insert_occurrence(kind: 'attempted', identity: 'at-to-boundary', occurred_at: Time.utc(2026, 1, 31, 19))

    rows = query.aggregate_rows.index_by { |row| row[:metric] }

    expect(rows.slice('attempted', 'connected', 'terminal').transform_values { |row| row[:total_count] }).to eq(
      'attempted' => 1, 'connected' => 1, 'terminal' => 1
    )
    expect(rows).not_to have_key('long')
    current_connected = Telephony::LogicalCallOccurrence.find_by!(
      logical_call_identity: 'call-one', occurrence_kind: 'connected', revision: 2
    )
    expect(query(metric: 'connected').drill_down_rows.pluck(:occurrence_id)).to eq([current_connected.id])
  end

  it 'keeps operator-only calls out of connected and applies the inclusive long threshold' do
    occurred_at = Time.utc(2026, 1, 12, 8)
    insert_occurrence(kind: 'attempted', identity: 'operator-only', occurred_at: occurred_at)
    insert_occurrence(kind: 'terminal', identity: 'long-edge', occurred_at: occurred_at + 1.hour, duration_seconds: 25)
    insert_occurrence(kind: 'terminal', identity: 'short', occurred_at: occurred_at + 2.hours, duration_seconds: 24)
    insert_occurrence(
      kind: 'terminal', identity: 'unknown-duration', occurred_at: occurred_at + 3.hours,
      terminal_status: 'failed', terminal_reason: 'missing_duration', reliability: 'unknown'
    )

    expect(query(metric: 'connected').aggregate_rows).to be_empty
    threshold_rows = query(metric: 'long', long_threshold_seconds: 25).aggregate_rows
    expect(threshold_rows.sum { |row| row[:exact_count] }).to eq(1)
    expect(threshold_rows.sum { |row| row[:unknown_count] }).to eq(1)
    expect(query(metric: 'long', long_threshold_seconds: 26).aggregate_rows.sum { |row| row[:unknown_count] }).to eq(1)
  end

  it 'includes a completed outbound call with remote-answer evidence but no answer timestamp as unknown length' do
    travel_to(Time.utc(2026, 1, 12, 10)) do
      session = create(
        :telephony_call_session,
        account: account,
        inbox: voice_inbox,
        conversation: nil,
        contact: nil,
        number_binding: nil,
        external_call_ref: 'remote-completion-no-answer-time',
        provider: 'sipuni',
        direction: 'outbound',
        status: 'ringing',
        started_at: Time.current,
        from_number: '+155****0000',
        to_number: '+155****9999',
        metadata: {}
      )
      session.update!(
        status: 'completed', ended_at: Time.current + 15, end_reason: 'remote_hangup',
        metadata: { 'last_payload' => {
          'webphone_action' => 'operator_release', 'release_reason' => 'remote_hangup', 'release_status' => 'completed'
        } }
      )

      terminal = account.telephony_logical_call_occurrences.find_by!(occurrence_kind: 'terminal')
      expect(terminal).to have_attributes(duration_seconds: nil, reliability: 'unknown')
      expect(query(metric: 'long', as_of: Time.current.iso8601).aggregate_rows.sum { |row| row[:unknown_count] }).to eq(1)
    end
  end

  it 'preserves captured human, AI, system, unknown, team, assistant, provider and inbox attribution' do
    occurred_at = Time.utc(2026, 1, 15, 9)
    human = create(:user, account: account, name: 'Deleted Operator')
    team = create(:team, account: account, name: 'Historical Team')
    assistant = create(:captain_assistant, account: account, name: 'Voice AI')
    human_fact = insert_occurrence(
      kind: 'connected', identity: 'human', occurred_at: occurred_at,
      actor_kind: 'human', actor_id_snapshot: human.id, actor_name_snapshot: human.name,
      actor_team_id_snapshot: team.id, actor_team_name_snapshot: team.name
    )
    insert_occurrence(
      kind: 'connected', identity: 'ai', occurred_at: occurred_at + 1.minute,
      actor_kind: 'ai_agent', assistant_id_snapshot: assistant.id, assistant_name_snapshot: assistant.name
    )
    insert_occurrence(kind: 'connected', identity: 'system', occurred_at: occurred_at + 2.minutes, actor_kind: 'system')
    insert_occurrence(kind: 'connected', identity: 'unknown', occurred_at: occurred_at + 3.minutes, actor_kind: 'unknown')
    account.account_users.find_by!(user: human).destroy!
    team.destroy!

    actor_rows = query(metric: 'connected', dimension: 'actor').aggregate_rows
    expect(actor_rows.pluck(:bucket).pluck(:kind)).to contain_exactly('human', 'ai_agent', 'system', 'unknown')
    detail = query(metric: 'connected', actor_id: human.id).drill_down_rows.first
    expect(detail).to include(occurrence_id: human_fact.id)
    expect(detail[:actor]).to include(id: human.id, name: 'Deleted Operator', team_id: team.id, team_name: team.name)
    expect(query(metric: 'connected', dimension: 'assistant').aggregate_rows.pluck(:bucket)).to include(
      include(id: assistant.id, name: 'Voice AI', state: 'captured')
    )
    expect(detail).to include(provider: 'sipuni', inbox_id_snapshot: voice_inbox.id)
  end

  it 'supports every snapshot dimension and normalized filter without mutable catalog joins' do
    human = create(:user, account: account, name: 'Filter Operator')
    team = create(:team, account: account, name: 'Filter Team')
    assistant = create(:captain_assistant, account: account)
    connected_at = Time.utc(2026, 1, 10, 10)
    insert_occurrence(
      kind: 'connected', identity: 'human-filter', occurred_at: connected_at,
      actor_kind: 'human', actor_id_snapshot: human.id, actor_name_snapshot: human.name,
      actor_team_id_snapshot: team.id, actor_team_name_snapshot: team.name
    )
    insert_occurrence(
      kind: 'connected', identity: 'assistant-filter', occurred_at: connected_at + 1.minute,
      source: create_source(ref: 'assistant-filter', direction: 'outbound'), actor_kind: 'ai_agent',
      assistant_id_snapshot: assistant.id, assistant_name_snapshot: assistant.name
    )
    insert_occurrence(
      kind: 'terminal', identity: 'unknown-filter', occurred_at: connected_at + 2.minutes,
      terminal_status: 'failed', terminal_reason: 'provider_error', reliability: 'unknown'
    )

    {
      'actor' => human.id,
      'team' => team.id,
      'assistant' => assistant.id,
      'provider' => 'sipuni',
      'inbox' => voice_inbox.id
    }.each do |dimension, expected_value|
      buckets = query(metric: 'connected', dimension: dimension).aggregate_rows.pluck(:bucket)
      expect(buckets).to satisfy do |values|
        values.any? { |value| value[:id] == expected_value || value[:value] == expected_value }
      end
    end

    metric_filter = { metric: 'connected' }
    {
      direction: ['outbound', 1], provider: ['sipuni', 2], inbox_id: [voice_inbox.id, 2],
      actor_kind: ['human', 1], actor_id: [human.id, 1], actor_team_id: [team.id, 1],
      assistant_id: [assistant.id, 1], reliability: ['exact', 2]
    }.each do |filter, (value, expected_count)|
      expect(query(metric_filter.merge(filter => value)).meta[:total_count]).to eq(expected_count)
    end
    unknown_row = query(metric: 'terminal', terminal_status: 'failed', reliability: 'unknown').aggregate_rows.first
    expect(unknown_row).to include(exact_count: 0, unknown_count: 1, total_count: 1)
  end

  it 'excludes facts created after as_of and uses the revision current at the requested instant' do
    occurred_at = Time.utc(2026, 1, 20, 10)
    source = create_source(ref: 'late-revision')
    first = insert_occurrence(kind: 'connected', identity: 'late-revision', occurred_at: occurred_at, source: source)
    insert_occurrence(
      kind: 'connected', identity: 'late-revision', occurred_at: occurred_at + 1.minute, source: source,
      revision: 2, supersedes_occurrence_id: first.id, created_at: Time.utc(2026, 2, 3)
    )

    snapshot = query(metric: 'connected', as_of: '2026-02-02T00:00:00Z')
    later = query(metric: 'connected', as_of: '2026-02-04T00:00:00Z')

    expect(snapshot.drill_down_rows.pluck(:occurrence_id)).to eq([first.id])
    expect(later.drill_down_rows.pluck(:occurred_at)).to eq(['2026-01-20T10:01:00.000000Z'])
  end

  it 'keeps aggregate/detail parity, stable descending paging and a pagination-independent fingerprint' do
    occurred_at = Time.utc(2026, 1, 25, 10)
    first = insert_occurrence(kind: 'connected', identity: 'first', occurred_at: occurred_at)
    second = insert_occurrence(kind: 'connected', identity: 'second', occurred_at: occurred_at)
    aggregate = query(metric: 'connected', dimension: 'provider')
    first_page = query(metric: 'connected', dimension: 'provider', page: 1, per_page: 1)
    second_page = query(metric: 'connected', dimension: 'provider', page: 2, per_page: 1)

    expect(aggregate.aggregate_rows.sum { |row| row[:total_count] }).to eq(2)
    expect(first_page.drill_down_rows.pluck(:occurrence_id)).to eq([second.id])
    expect(second_page.drill_down_rows.pluck(:occurrence_id)).to eq([first.id])
    expect(first_page.pagination_meta[:total_count]).to eq(2)
    expect(aggregate.meta[:query_fingerprint]).to eq(first_page.pagination_meta[:query_fingerprint])
    expect(first_page.pagination_meta[:query_fingerprint]).to eq(second_page.pagination_meta[:query_fingerprint])
  end

  it 'uses indistinguishable validation for hidden, foreign and nonexistent snapshot filters' do
    occurred_at = Time.utc(2026, 1, 10, 10)
    represented_user = create(:user, account: account)
    insert_occurrence(
      kind: 'connected', identity: 'represented', occurred_at: occurred_at,
      actor_kind: 'human', actor_id_snapshot: represented_user.id, actor_name_snapshot: represented_user.name
    )
    foreign_user = create(:user, account: create(:account))
    hidden_scope = account.telephony_logical_call_occurrences.none

    [represented_user.id, foreign_user.id, 9_999_999].each do |actor_id|
      expect { query({ metric: 'connected', actor_id: actor_id }, scope: hidden_scope) }
        .to raise_error(Telephony::Error, 'actor_id is invalid')
    end
  end

  it 'reports empty coverage as unknown without a cutover marker and missing Voice configuration as not_configured' do
    empty = query(metric: 'attempted')
    expect(empty.aggregate_rows).to be_empty
    expect(empty.meta).to include(
      state: 'ready', coverage_state: 'unknown', exact_zero_supported: false, total_count: nil, observed_count: 0
    )

    unconfigured_account = create(:account, settings: { 'workspace_timezone' => 'UTC' })
    unconfigured = described_class.new(
      account: unconfigured_account,
      occurrences_scope: unconfigured_account.telephony_logical_call_occurrences,
      params: base_params
    )
    expect(unconfigured.meta).to include(state: 'not_configured', exact_zero_supported: false)
    expect do
      described_class.new(
        account: unconfigured_account,
        occurrences_scope: unconfigured_account.telephony_logical_call_occurrences,
        params: base_params.merge(inbox_id: 999_999)
      )
    end.not_to raise_error
  end

  it 'rejects offset local bounds, malformed as_of, oversized windows and unbounded pagination' do
    expect { query(from_local: '2026-01-01T00:00:00Z') }.to raise_error(Telephony::Error, /offset-free/)
    expect { query(as_of: '2026-02-02') }.to raise_error(Telephony::Error, /RFC3339/)
    expect { query(as_of: 1.hour.from_now.iso8601) }.to raise_error(Telephony::Error, /must not be in the future/)
    expect { query(to_local: '2027-02-01T00:00:01') }.to raise_error(Telephony::Error, /366 days/)
    expect { query(metric: 'attempted', per_page: 101).drill_down_rows }.to raise_error(Telephony::Error, /must not exceed 100/)
  end

  it 'rejects nonexistent and ambiguous DST wall times' do
    account.update!(settings: account.settings.merge('workspace_timezone' => 'America/New_York'))

    expect do
      query(from_local: '2026-03-08T02:30:00', to_local: '2026-03-08T04:00:00')
    end.to raise_error(Telephony::Error, /unambiguous existing/)
    expect do
      query(from_local: '2026-11-01T01:30:00', to_local: '2026-11-01T03:00:00')
    end.to raise_error(Telephony::Error, /unambiguous existing/)
  end
end
