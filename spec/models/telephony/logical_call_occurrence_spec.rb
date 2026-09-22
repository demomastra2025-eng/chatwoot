require 'rails_helper'

RSpec.describe Telephony::LogicalCallOccurrence do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, name: 'Answering operator') }
  let(:conversation) { create(:conversation, account: account) }
  let(:started_at) { Time.utc(2026, 9, 22, 12) }

  def create_session(attributes = {})
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox,
      number_binding: nil,
      provider: 'sipuni',
      external_call_ref: SecureRandom.uuid,
      direction: 'inbound',
      status: 'ringing',
      started_at: started_at,
      created_at: started_at,
      metadata: {},
      **attributes
    )
  end

  def occurrences
    described_class.where(account_id: account.id).order(:id)
  end

  it 'records a forward-only attempted fact when initiation first acquires started_at' do
    session = create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox,
      number_binding: nil,
      provider: 'sipuni',
      external_call_ref: 'sipuni:accepted-later',
      direction: 'inbound',
      started_at: nil
    )

    expect { session.update!(started_at: started_at) }.to change(described_class, :count).by(1)
    expect(occurrences.first).to have_attributes(
      occurrence_kind: 'attempted',
      logical_call_ref: 'sipuni:accepted-later',
      source_id: session.id,
      source_ref: 'sipuni:accepted-later',
      direction: 'inbound',
      provider: 'sipuni',
      occurred_at: started_at,
      reliability: 'exact',
      source_version: 1,
      definition_version: 1,
      actor_kind: 'unknown'
    )
    expect(occurrences.first.reliable_since).to be >= started_at
  end

  it 'keeps logical identity stable when tenant-safe entity links arrive after initiation' do
    session = create(
      :telephony_call_session,
      account: account,
      conversation: nil,
      contact: nil,
      inbox: nil,
      number_binding: nil,
      from_number: '+15550000000',
      to_number: '+15559999999',
      provider: 'sipuni',
      external_call_ref: 'sipuni:linked-later',
      direction: 'inbound',
      started_at: started_at
    )
    attempted_identity = occurrences.find_by!(occurrence_kind: 'attempted').logical_call_identity

    session.update!(
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox,
      status: 'in_progress',
      answered_at: started_at + 1.second,
      answered_by: "user:#{user.id}"
    )

    connected = occurrences.find_by!(occurrence_kind: 'connected')
    expect(connected.logical_call_identity).to eq(attempted_identity)
    expect(connected).to have_attributes(
      conversation_id_snapshot: conversation.id,
      inbox_id_snapshot: conversation.inbox_id,
      contact_id_snapshot: conversation.contact_id
    )
  end

  it 'records human connected and terminal facts with immutable actor and duration snapshots' do
    team = create(:team, account: account, name: 'Call center')
    create(:team_member, team: team, user: user)
    session = create_session(
      external_call_ref: 'sipuni:human-answer',
      metadata: { 'last_payload' => { 'answered_team_id' => team.id } }
    )
    answered_at = started_at + 10.seconds
    ended_at = answered_at + 95.seconds

    session.update!(status: 'in_progress', answered_at: answered_at, answered_by: "user:#{user.id}")
    account.account_users.find_by!(user_id: user.id).destroy!
    team.destroy!
    session.update!(status: 'completed', ended_at: ended_at, end_reason: 'remote_hangup')

    connected = occurrences.find_by!(occurrence_kind: 'connected')
    terminal = occurrences.find_by!(occurrence_kind: 'terminal')
    expect(connected).to have_attributes(
      actor_kind: 'human',
      actor_id_snapshot: user.id,
      actor_name_snapshot: 'Answering operator',
      actor_team_id_snapshot: team.id,
      actor_team_name_snapshot: team.name,
      connected_at: answered_at
    )
    expect(terminal).to have_attributes(
      actor_kind: 'human',
      actor_id_snapshot: user.id,
      actor_team_id_snapshot: team.id,
      actor_team_name_snapshot: team.name,
      connected_at: answered_at,
      terminal_at: ended_at,
      duration_seconds: 95,
      duration_source: 'connected_to_terminal',
      terminal_status: 'completed',
      terminal_reason: 'remote_hangup'
    )

    session.destroy!
    expect(connected.reload).to have_attributes(actor_id_snapshot: user.id, actor_name_snapshot: 'Answering operator')
  end

  it 'does not count an outbound operator-only leg as connected but records a remote callee answer' do
    session = create_session(
      external_call_ref: 'sipuni:outbound-remote-answer',
      direction: 'outbound',
      status: 'in_progress',
      answered_at: started_at + 3.seconds,
      answered_by: "user:#{user.id}",
      legs: [{ 'leg' => 'operator', 'status' => 'in_progress' }]
    )

    expect(occurrences.where(occurrence_kind: 'connected')).to be_empty

    session.update!(
      metadata: {
        'last_payload' => {
          'event_type' => 'callee_answered',
          'callee_leg_answered' => true
        }
      }
    )

    expect(occurrences.find_by!(occurrence_kind: 'connected')).to have_attributes(
      actor_kind: 'human',
      actor_id_snapshot: user.id,
      connected_at: started_at + 3.seconds
    )
  end

  it 'records unanswered terminal facts idempotently without inventing connection or duration' do
    session = create_session(external_call_ref: 'sipuni:no-answer')

    session.update!(status: 'failed', ended_at: started_at + 4.seconds, end_reason: 'no_answer')
    session.update!(metadata: { 'last_payload' => { 'event_type' => 'failed' } })

    expect(occurrences.pluck(:occurrence_kind)).to contain_exactly('attempted', 'terminal')
    expect(occurrences.find_by!(occurrence_kind: 'terminal')).to have_attributes(
      actor_kind: 'unknown',
      connected_at: nil,
      duration_seconds: nil,
      duration_source: nil,
      terminal_reason: 'no_answer'
    )
  end

  it 'derives exact short and long durations only from connected and terminal facts' do
    # Late authoritative evidence must append a revision rather than mutate history.
    repaired = create_session(external_call_ref: 'sipuni:late-answer-repair', direction: 'outbound')
    repaired.update!(status: 'failed', ended_at: started_at + 30.seconds, end_reason: 'no_answer')
    repaired.update!(
      status: 'completed',
      answered_at: started_at + 10.seconds,
      ended_at: started_at + 35.seconds,
      end_reason: 'remote_hangup',
      metadata: { 'last_payload' => { 'callee_leg_answered' => true } }
    )

    terminal_revisions = occurrences.where(source_ref: repaired.external_call_ref, occurrence_kind: 'terminal').order(:revision)
    expect(terminal_revisions.pluck(:revision, :terminal_status, :duration_seconds)).to eq(
      [[1, 'failed', nil], [2, 'completed', 25]]
    )
    expect(terminal_revisions.last.supersedes_occurrence_id).to eq(terminal_revisions.first.id)
    expect(occurrences.current_revision.where(source_ref: repaired.external_call_ref, occurrence_kind: 'terminal'))
      .to contain_exactly(terminal_revisions.last)

    { 'sipuni:short' => 1, 'sipuni:long' => 3.days.to_i }.each do |call_ref, duration|
      session = create_session(external_call_ref: call_ref)
      answered_at = started_at + 2.seconds
      session.update!(status: 'in_progress', answered_at: answered_at, answered_by: "user:#{user.id}")
      session.update!(status: 'completed', ended_at: answered_at + duration.seconds)
    end

    durations = occurrences.current_revision.where(source_ref: %w[sipuni:short sipuni:long], occurrence_kind: 'terminal')
                           .order(:duration_seconds).pluck(:duration_seconds)
    expect(durations).to eq([1, 3.days.to_i])
  end

  it 'reconciles unknown and exact connected evidence across logical siblings' do
    logical_key = 'asterisk:remote-completed-logical'
    session = create_session(
      external_call_ref: 'asterisk:remote-completed',
      provider: 'asterisk_analog',
      direction: 'outbound',
      metadata: { 'metadata' => { 'logical_call_key' => logical_key } }
    )
    session.update!(
      status: 'completed',
      ended_at: started_at + 15.seconds,
      end_reason: 'remote_hangup',
      metadata: {
        'metadata' => { 'logical_call_key' => logical_key },
        'last_payload' => {
          'webphone_action' => 'operator_release',
          'release_reason' => 'remote_hangup',
          'release_status' => 'completed'
        }
      }
    )

    unknown = occurrences.find_by!(source_ref: session.external_call_ref, occurrence_kind: 'connected')
    expect(unknown).to have_attributes(reliability: 'unknown', connected_at: nil, occurred_at: started_at + 15.seconds)

    exact_sibling = create_session(
      external_call_ref: 'asterisk:remote-completed-exact-sibling',
      provider: 'asterisk_analog',
      direction: 'outbound',
      metadata: {
        'metadata' => {
          'logical_call_key' => logical_key,
          'logical_call_group_ref' => session.external_call_ref
        }
      }
    )
    exact_sibling.update!(
      status: 'in_progress',
      answered_at: started_at + 8.seconds,
      metadata: {
        'metadata' => { 'logical_call_key' => logical_key, 'logical_call_group_ref' => session.external_call_ref },
        'last_payload' => { 'callee_leg_answered' => true }
      }
    )

    connected_revisions = occurrences.where(occurrence_kind: 'connected').order(:revision)
    expect(connected_revisions.pluck(:revision, :reliability, :connected_at)).to eq(
      [[1, 'unknown', nil], [2, 'exact', started_at + 8.seconds]]
    )
    expect(occurrences.current_revision.where(occurrence_kind: 'connected')).to contain_exactly(connected_revisions.last)
  end

  it 'atomically deduplicates physical siblings and waits for the whole logical call to terminate' do
    logical_key = 'native-sip:logical-call-1'
    root = create_session(
      external_call_ref: 'sipuni:root-1',
      metadata: { 'metadata' => { 'logical_call_key' => logical_key } }
    )
    child = create_session(
      external_call_ref: 'sipuni:child-1',
      metadata: {
        'metadata' => {
          'logical_call_key' => logical_key,
          'logical_call_group_ref' => root.external_call_ref,
          'route_reason' => 'duplicate_broadcast_branch'
        }
      }
    )

    expect(occurrences.where(occurrence_kind: 'attempted').count).to eq(1)

    child.update!(status: 'in_progress', answered_at: started_at + 5.seconds, answered_by: "user:#{user.id}")
    child.update!(status: 'completed', ended_at: started_at + 30.seconds)
    expect(occurrences.where(occurrence_kind: 'connected').count).to eq(1)
    expect(occurrences.where(occurrence_kind: 'terminal')).to be_empty

    root.update!(status: 'completed', ended_at: started_at + 35.seconds)
    expect(occurrences.where(occurrence_kind: 'terminal').count).to eq(1)
    expect(occurrences.distinct.count(:logical_call_identity)).to eq(1)
  end

  it 'captures AI assistant identity separately and preserves it after deletion' do
    logical_key = 'native-sip:transitive-call'
    root = create_session(external_call_ref: 'sipuni:transitive-root', metadata: { 'logical_call_key' => logical_key })
    child = create_session(
      external_call_ref: 'sipuni:transitive-child',
      metadata: { 'logical_call_key' => logical_key, 'logical_call_group_ref' => root.external_call_ref }
    )
    create_session(
      external_call_ref: 'sipuni:transitive-grandchild',
      metadata: { 'logical_call_key' => logical_key, 'logical_call_group_ref' => child.external_call_ref }
    )

    expect(occurrences.where(source_ref: root.external_call_ref, occurrence_kind: 'attempted').count).to eq(1)
    transitive_occurrences = occurrences.where(logical_call_ref: root.external_call_ref)
    expect(transitive_occurrences.distinct.count(:logical_call_identity)).to eq(1)

    assistant = create(:captain_assistant, account: account, name: 'Voice concierge')
    session = create_session(
      external_call_ref: 'whatsapp:ai-answer',
      provider: 'whatsapp_cloud',
      metadata: { 'ai_voice' => { 'routing' => { 'captain_assistant_id' => assistant.id } } }
    )

    session.update!(status: 'in_progress', answered_at: started_at + 2.seconds, answered_by: 'ai_agent')
    connected = occurrences.find_by!(occurrence_kind: 'connected')
    expect(connected).to have_attributes(
      actor_kind: 'ai_agent',
      actor_id_snapshot: nil,
      assistant_id_snapshot: assistant.id,
      assistant_name_snapshot: 'Voice concierge'
    )

    assistant.destroy!
    session.update!(status: 'completed', ended_at: started_at + 20.seconds)
    terminal = occurrences.current_revision.find_by!(source_ref: session.external_call_ref, occurrence_kind: 'terminal')
    expect(connected.reload).to have_attributes(assistant_id_snapshot: assistant.id, assistant_name_snapshot: 'Voice concierge')
    expect(terminal).to have_attributes(assistant_id_snapshot: assistant.id, assistant_name_snapshot: 'Voice concierge')
  end

  it 'keeps system and ambiguous answer identities distinct from human binding context' do
    system_session = create_session(external_call_ref: 'sipuni:system-answer')
    unknown_session = create_session(
      external_call_ref: 'sipuni:unknown-answer',
      agent_binding: create(:telephony_agent_binding, account: account, user: user)
    )

    system_session.update!(status: 'in_progress', answered_at: started_at + 1.second, answered_by: 'system')
    unknown_session.update!(status: 'in_progress', answered_at: started_at + 1.second, answered_by: 'provider-extension-42')

    expect(occurrences.find_by!(source_ref: system_session.external_call_ref, occurrence_kind: 'connected').actor_kind).to eq('system')
    expect(occurrences.find_by!(source_ref: unknown_session.external_call_ref, occurrence_kind: 'connected')).to have_attributes(
      actor_kind: 'unknown',
      actor_id_snapshot: nil
    )
  end

  it 'does not fabricate occurrences for legacy sessions that had a start before the writer boundary' do
    session = create_session(external_call_ref: 'sipuni:forward-only')
    legacy_logical_key = 'native-sip:legacy-logical-group'
    legacy = create(:telephony_call_session, account: account, conversation: conversation, contact: conversation.contact,
                                             inbox: conversation.inbox, number_binding: nil, provider: 'sipuni',
                                             external_call_ref: 'sipuni:legacy', direction: 'inbound', started_at: nil,
                                             metadata: { 'metadata' => { 'logical_call_key' => legacy_logical_key } })
    legacy.update_columns(started_at: started_at, created_at: started_at) # rubocop:disable Rails/SkipsModelValidations
    legacy.update!(status: 'completed', answered_at: started_at + 1.second, ended_at: started_at + 2.seconds)
    late_sibling = create_session(
      external_call_ref: 'sipuni:legacy-late-sibling',
      metadata: {
        'metadata' => {
          'logical_call_key' => legacy_logical_key,
          'logical_call_group_ref' => legacy.external_call_ref
        }
      }
    )

    expect(occurrences.where(source_id: [legacy.id, late_sibling.id])).to be_empty
    expect(occurrences.where(source_ref: session.external_call_ref, occurrence_kind: 'attempted')).to exist
  end

  it 'rolls occurrence writes back with the authoritative session transaction' do
    expect do
      Telephony::CallSession.transaction do
        create_session(external_call_ref: 'sipuni:rolled-back')
        raise ActiveRecord::Rollback
      end
    end.not_to change(described_class, :count)
  end

  it 'rejects cross-account snapshot corruption at the database boundary' do
    session = create_session(external_call_ref: 'sipuni:tenant-safe')
    occurrence = occurrences.find_by!(occurrence_kind: 'attempted')
    foreign_inbox = create(:inbox, account: create(:account))
    attributes = occurrence.attributes.except('id').merge(
      'logical_call_identity' => "#{occurrence.logical_call_identity}:corrupt",
      'inbox_id_snapshot' => foreign_inbox.id,
      'created_at' => Time.current
    )

    described_class.transaction(requires_new: true) do
      expect { described_class.insert_all!([attributes]) } # rubocop:disable Rails/SkipsModelValidations
        .to raise_error(ActiveRecord::StatementInvalid, /inbox snapshot must belong to account/)
      raise ActiveRecord::Rollback
    end
    expect(session.reload.account_id).to eq(account.id)
  end

  it 'is append-only except for whole-account teardown' do
    create_session(external_call_ref: 'sipuni:immutable')
    occurrence = occurrences.first

    expect { occurrence.update!(provider: 'other') }.to raise_error(ActiveRecord::RecordInvalid, /immutable/)
    described_class.transaction(requires_new: true) do
      expect { described_class.where(id: occurrence.id).delete_all }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      raise ActiveRecord::Rollback
    end

    account.send(:authorize_participant_lifecycle_fact_teardown)
    expect { account.telephony_logical_call_occurrences.delete_all }.to change(described_class, :count).by(-1)
  end
end
