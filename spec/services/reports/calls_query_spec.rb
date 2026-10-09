# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reports::CallsQuery do
  let(:account) { create(:account, reporting_timezone: 'Europe/Berlin') }

  def create_call(account:, started_at:, direction: 'inbound', status: 'completed', metadata: {}, **attributes)
    inbox = attributes[:inbox] || attributes[:conversation]&.inbox
    if inbox.present?
      attributes[:number_binding] ||= Telephony::NumberBinding.find_by(inbox_id: inbox.id)
      attributes[:number_binding] ||= create(
        :telephony_number_binding,
        account: account,
        inbox: inbox,
        provider: attributes[:provider] || 'sipuni'
      )
    end

    create(
      :telephony_call_session,
      account: account,
      direction: direction,
      status: status,
      metadata: metadata,
      started_at: started_at,
      created_at: started_at,
      updated_at: started_at,
      **attributes
    )
  end

  def native_handoff_metadata(logical_key)
    {
      'metadata' => {
        'telephony_sip_profile_id' => '70',
        'registration_instance_id' => 'registration-instance-1',
        'janus_session_id' => 'janus-session-1',
        'janus_handle_id' => 'janus-handle-1',
        'logical_call_key' => logical_key
      }
    }
  end

  def create_native_handoff_leg(context:, call_ref:, logical_key:, started_at:, ended_at:)
    create_call(
      **context,
      provider: 'binotel',
      external_call_ref: call_ref,
      direction: 'inbound',
      status: 'no_answer',
      started_at: started_at,
      ended_at: ended_at,
      end_reason: 'remote_hangup',
      from_number: '+77012345678',
      to_number: '+77098765432',
      metadata: native_handoff_metadata(logical_key)
    )
  end

  def create_native_handoff_pair(context:, first_started_at:, next_leg_started_at:)
    first_leg = create_native_handoff_leg(
      context: context,
      call_ref: 'native-history-first-leg',
      logical_key: 'native-live-key-first-leg',
      started_at: first_started_at,
      ended_at: next_leg_started_at - 1.second
    )
    next_leg = create_native_handoff_leg(
      context: context,
      call_ref: 'native-history-next-leg',
      logical_key: 'native-live-key-next-leg',
      started_at: next_leg_started_at,
      ended_at: next_leg_started_at + 10.seconds
    )

    [first_leg, next_leg]
  end

  def call_report_for(account:, date:)
    described_class.new(account: account, params: { from_date: date, to_date: date }).perform
  end

  def expect_native_handoff_linked(first_leg:, next_leg:)
    expect(first_leg.reload.logical_history_group_ref).to eq(first_leg.external_call_ref)
    expect(next_leg.reload.logical_history_group_ref).to eq(first_leg.external_call_ref)
    expect(next_leg.logical_history_key).to eq(first_leg.logical_history_key)
  end

  def create_history_group_scope_collisions(account:, inbox:, conversation:, group_ref:, started_at:)
    other_inbox = create(:inbox, account: account)
    other_conversation = create(:conversation, account: account, inbox: other_inbox)
    history_metadata = { 'history_handoff' => { 'group_ref' => group_ref } }
    [
      [other_inbox, other_conversation, 'binotel', started_at + 1.minute],
      [inbox, conversation, 'sipuni', started_at + 2.minutes]
    ].each do |collision_inbox, collision_conversation, provider, collision_started_at|
      create_call(
        account: account,
        inbox: collision_inbox,
        conversation: collision_conversation,
        provider: provider,
        started_at: collision_started_at,
        status: 'no_answer',
        metadata: history_metadata,
        answered_at: nil
      )
    end
  end

  it 'keeps an inbound handoff as one call and assigns it to the first-leg date' do
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox)
    group_metadata = { 'metadata' => { 'logical_call_key' => 'handoff:boundary-call' } }
    child_metadata = {
      'metadata' => {
        'logical_call_key' => 'handoff:boundary-call',
        'logical_call_group_ref' => 'handoff-root-call'
      }
    }
    parent_started_at = Time.iso8601('2026-03-28T22:59:55Z')
    answered_child_started_at = Time.iso8601('2026-03-28T23:00:20Z')
    create_call(
      account: account,
      inbox: inbox,
      conversation: conversation,
      started_at: parent_started_at,
      status: 'no_answer',
      metadata: group_metadata,
      external_call_ref: 'handoff-root-call',
      answered_at: nil,
      ended_at: parent_started_at + 20.seconds,
      duration_seconds: 0
    )
    create_call(
      account: account,
      inbox: inbox,
      conversation: conversation,
      started_at: answered_child_started_at,
      status: 'completed',
      metadata: child_metadata,
      external_call_ref: 'handoff-child-call',
      answered_at: answered_child_started_at + 5.seconds,
      answered_by: 'provider',
      ended_at: answered_child_started_at + 50.seconds,
      duration_seconds: 45
    )

    previous_day = described_class.new(
      account: account,
      params: { from_date: '2026-03-28', to_date: '2026-03-28' }
    ).perform
    next_day = described_class.new(
      account: account,
      params: { from_date: '2026-03-29', to_date: '2026-03-29' }
    ).perform

    expect(previous_day.dig(:summary, :logical_call_count)).to eq(1)
    expect(previous_day.dig(:summary, :answered_count)).to eq(1)
    expect(previous_day.dig(:summary, :average_answered_duration_seconds)).to eq(45.0)
    expect(previous_day.dig(:rows, 0, :started_at)).to eq(parent_started_at.iso8601)
    expect(next_day.dig(:summary, :logical_call_count)).to eq(0)
  end

  it 'joins explicit-key legs across midnight beyond the nearby-leg window without mixing inboxes or providers' do
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox)
    other_inbox = create(:inbox, account: account)
    other_conversation = create(:conversation, account: account, inbox: other_inbox)
    logical_key = 'binotel:reused-call-reference'
    metadata = { 'metadata' => { 'logical_call_key' => logical_key } }
    first_leg_started_at = Time.iso8601('2026-03-28T22:57:00Z')
    answered_leg_started_at = Time.iso8601('2026-03-28T23:01:00Z')

    create_call(
      account: account,
      inbox: inbox,
      conversation: conversation,
      provider: 'binotel',
      started_at: first_leg_started_at,
      status: 'no_answer',
      metadata: metadata,
      answered_at: nil,
      ended_at: first_leg_started_at + 30.seconds,
      duration_seconds: 0
    )
    create_call(
      account: account,
      inbox: inbox,
      conversation: conversation,
      provider: 'binotel',
      started_at: answered_leg_started_at,
      status: 'completed',
      metadata: metadata,
      answered_at: answered_leg_started_at + 15.seconds,
      answered_by: 'provider',
      ended_at: answered_leg_started_at + 60.seconds,
      duration_seconds: 45
    )
    create_call(
      account: account,
      inbox: other_inbox,
      conversation: other_conversation,
      provider: 'binotel',
      started_at: answered_leg_started_at + 1.minute,
      status: 'no_answer',
      metadata: metadata,
      answered_at: nil
    )
    create_call(
      account: account,
      inbox: inbox,
      conversation: conversation,
      provider: 'sipuni',
      started_at: answered_leg_started_at + 2.minutes,
      status: 'no_answer',
      metadata: metadata,
      answered_at: nil
    )

    first_day = described_class.new(
      account: account,
      params: { from_date: '2026-03-28', to_date: '2026-03-28' }
    ).perform
    next_day = described_class.new(
      account: account,
      params: { from_date: '2026-03-29', to_date: '2026-03-29' }
    ).perform

    expect(first_day.dig(:summary, :logical_call_count)).to eq(1)
    expect(first_day.dig(:summary, :answered_count)).to eq(1)
    expect(first_day.dig(:summary, :average_answered_duration_seconds)).to eq(45.0)
    expect(first_day.dig(:rows, 0, :started_at)).to eq(first_leg_started_at.iso8601)
    expect(next_day.dig(:summary, :logical_call_count)).to eq(2)
    expect(next_day.dig(:summary, :unanswered_count)).to eq(2)
  end

  it 'uses the native SIP history group across midnight when the handoff legs are created minutes apart' do
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox)
    number_binding = create(:telephony_number_binding, account: account, inbox: inbox, provider: 'binotel')
    first_leg_started_at = Time.iso8601('2026-03-28T22:57:00Z')
    next_leg_started_at = Time.iso8601('2026-03-28T23:01:00Z')
    context = { account: account, inbox: inbox, conversation: conversation, number_binding: number_binding }
    first_leg, next_leg = create_native_handoff_pair(
      context: context,
      first_started_at: first_leg_started_at,
      next_leg_started_at: next_leg_started_at
    )

    Telephony::TerminalNativeSipHandoffService.new(call_session: next_leg).perform

    expect_native_handoff_linked(first_leg: first_leg, next_leg: next_leg)

    create_history_group_scope_collisions(
      account: account,
      inbox: inbox,
      conversation: conversation,
      group_ref: first_leg.external_call_ref,
      started_at: next_leg_started_at
    )

    first_day = call_report_for(account: account, date: '2026-03-28')
    next_day = call_report_for(account: account, date: '2026-03-29')

    expect(first_day.dig(:summary, :logical_call_count)).to eq(1)
    expect(first_day.dig(:summary, :unanswered_count)).to eq(1)
    expect(first_day.dig(:rows, 0, :started_at)).to eq(first_leg_started_at.iso8601)
    expect(next_day.dig(:summary, :logical_call_count)).to eq(2)
    expect(next_day.dig(:summary, :unanswered_count)).to eq(2)
  end

  it 'does not merge different history groups that reuse one raw logical key' do
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox)
    logical_key = 'provider-reused-live-key'
    first_started_at = Time.iso8601('2026-03-29T12:00:00Z')
    second_started_at = first_started_at + 1.minute

    [
      ['history-group-first', first_started_at],
      ['history-group-second', second_started_at]
    ].each do |group_ref, started_at|
      create_call(
        account: account,
        inbox: inbox,
        conversation: conversation,
        provider: 'binotel',
        started_at: started_at,
        status: 'no_answer',
        metadata: {
          'metadata' => { 'logical_call_key' => logical_key },
          'history_handoff' => { 'group_ref' => group_ref }
        },
        answered_at: nil
      )
    end

    report = described_class.new(
      account: account,
      params: { from_date: '2026-03-29', to_date: '2026-03-29' }
    ).perform

    expect(report.dig(:summary, :logical_call_count)).to eq(2)
    expect(report.dig(:summary, :unanswered_count)).to eq(2)
  end

  it 'does not infer an answer from completed status or count another account call' do
    started_at = Time.iso8601('2026-03-29T12:00:00Z')
    create_call(
      account: account,
      started_at: started_at,
      direction: 'outbound',
      status: 'completed',
      answered_at: nil,
      duration_seconds: 90
    )
    create_call(
      account: create(:account, reporting_timezone: 'Europe/Berlin'),
      started_at: started_at,
      direction: 'outbound',
      status: 'completed',
      answered_at: started_at + 1.minute,
      duration_seconds: 90
    )

    report = described_class.new(
      account: account,
      params: { from_date: '2026-03-29', to_date: '2026-03-29' }
    ).perform

    expect(report.dig(:summary, :logical_call_count)).to eq(1)
    expect(report.dig(:summary, :answered_count)).to eq(0)
    expect(report.dig(:summary, :unanswered_count)).to eq(1)
    expect(report.dig(:summary, :average_answered_duration_seconds)).to be_nil
  end

  it 'marks a capped sample incomplete instead of presenting it as an exact total' do
    3.times do |index|
      create_call(
        account: account,
        started_at: Time.iso8601('2026-03-29T12:00:00Z') + index.minutes,
        direction: 'outbound',
        status: 'completed',
        answered_at: nil
      )
    end
    stub_const('Reports::CallsQuery::MAX_LOGICAL_CALLS', 1)

    report = described_class.new(
      account: account,
      params: { from_date: '2026-03-29', to_date: '2026-03-29' }
    ).perform

    expect(report.dig(:coverage, :complete)).to be(false)
    expect(report.dig(:coverage, :sampled_calls)).to eq(1)
  end
end
