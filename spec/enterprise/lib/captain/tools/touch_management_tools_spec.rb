require 'rails_helper'

RSpec.describe 'Captain touch management public tools', type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: conversation.contact_id } }) }

  let(:touch_definition) do
    {
      action_type: 'send_message',
      content_kind: 'free_text',
      text_mode: 'static',
      timing_mode: 'relative',
      relative_anchor: 'conversation.created_at',
      relative_offset_seconds: 1800,
      timezone: 'UTC',
      body: 'Plan follow-up',
      attachments: [],
      template_params: {},
      metadata: {
        nil_value: nil,
        blank_value: '',
        false_value: false,
        zero_value: 0,
        empty_list: []
      }
    }
  end

  it 'publishes the nested touch-plan item schema to providers' do
    schema = Captain::Tools::CreateTouchPlanTool.new(assistant).params_schema.deep_stringify_keys
    touch_item_schema = schema.dig('properties', 'touches', 'items')

    expect(touch_item_schema).to include('type' => 'object')
    expect(touch_item_schema.dig('properties', 'action_type', 'enum')).to eq(['send_message'])
    expect(touch_item_schema.dig('properties', 'timing_mode', 'enum')).to eq(%w[absolute relative])
    expect(touch_item_schema.dig('properties', 'target_inbox_id')).to include('type' => 'integer', 'minimum' => 1)
    expect(touch_item_schema.dig('properties', 'relative_time_of_day', 'pattern')).to eq('^(?:[01]\\d|2[0-3]):[0-5]\\d$')
  end

  it 'returns a normalized cancel_touch payload' do
    touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :pending)
    payload = JSON.parse(Captain::Tools::CancelTouchTool.new(assistant).perform(tool_context, touch_id: touch.id, reason: 'Done'))

    expect(payload).to include('action' => 'cancel_touch', 'touch_id' => touch.id, 'status' => 'cancelled', 'reason' => 'Done')
    expect(payload.dig('touch', 'id')).to eq(touch.id)
    expect(payload.dig('touch', 'status')).to eq('cancelled')
  end

  it 'returns the default cancellation reason when bulk cancelling without a reason' do
    create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :pending)

    payload = JSON.parse(Captain::Tools::CancelTouchesTool.new(assistant).perform(tool_context))

    expect(payload).to include(
      'action' => 'cancel_touches',
      'found_count' => 1,
      'cancellable_count' => 1,
      'cancelled_count' => 1,
      'skipped_count' => 0,
      'failed_count' => 0,
      'remaining_open_count' => 0,
      'reason' => Captain::Tools::Operations::TouchOperations::CAPTAIN_CANCEL_REASON
    )
    expect(payload['cancelled_touch_ids']).to contain_exactly(Reminder.last.id)
    expect(payload['scope']).to include('account_id' => account.id, 'remindable_type' => 'Conversation', 'remindable_id' => conversation.id)
  end

  it 'returns a normalized delete_touch payload' do
    touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :cancelled)
    payload = JSON.parse(Captain::Tools::DeleteTouchTool.new(assistant).perform(tool_context, touch_id: touch.id))

    expect(payload).to include(
      'action' => 'delete_touch',
      'deleted' => true,
      'deleted_touch_id' => touch.id,
      'touch_id' => touch.id,
      'status' => 'cancelled'
    )
    expect(account.reminders.exists?(touch.id)).to be(false)
  end

  it 'returns deferred enrollment metadata when Captain applies an appointment plan', :aggregate_failures do
    account.enable_features!('scheduling', 'deferred_touch_materialization')
    appointment = create(
      :scheduling_appointment,
      account: account,
      conversation: conversation,
      starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 30.minutes
    )
    touch_plan = create(
      :reminder_group,
      account: account,
      assistant: assistant,
      entity_kinds: ['appointment'],
      touches: [
        touch_definition.merge(
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -1.day.to_i
        )
      ]
    )

    payload = JSON.parse(
      Captain::Tools::ApplyTouchPlanTool.new(assistant).perform(
        tool_context,
        touch_plan_id: touch_plan.id,
        remindable_kind: 'appointment'
      )
    )
    enrollment = account.touch_plan_enrollments.sole
    cancel_payload = JSON.parse(
      Captain::Tools::CancelTouchesTool.new(assistant).perform(
        tool_context,
        touch_plan_id: touch_plan.id,
        remindable_kind: 'appointment',
        reason: 'Stop deferred plan'
      )
    )

    expect(payload).to include(
      'action' => 'apply_touch_plan',
      'touch_plan_id' => touch_plan.id,
      'touch_plan_name' => touch_plan.name,
      'execution_mode' => 'deferred',
      'enrollment_id' => enrollment.id,
      'created_count' => 0
    )
    expect(payload.dig('meta', 'execution_mode')).to eq('deferred')
    expect(payload.dig('meta', 'enrollment_id')).to eq(enrollment.id)
    expect(cancel_payload).to include(
      'cancelled_enrollment_count' => 1,
      'cancelled_enrollment_ids' => [enrollment.id],
      'remaining_open_enrollment_count' => 0
    )
    expect(enrollment.reload).to be_cancelled
    expect(account.reminders.where(remindable: appointment)).to be_empty
  end

  it 'creates, applies, cancels, and archives touch plans through public tools' do
    create_payload = JSON.parse(Captain::Tools::CreateTouchPlanTool.new(assistant).perform(
                                  tool_context,
                                  name: 'Conversation nurture',
                                  entity_kinds: ['conversation'],
                                  touches: [touch_definition]
                                ))
    touch_plan_id = create_payload.dig('touch_plan', 'id')

    apply_payload = JSON.parse(Captain::Tools::ApplyTouchPlanTool.new(assistant).perform(tool_context, touch_plan_id: touch_plan_id))
    cancel_payload = JSON.parse(Captain::Tools::CancelTouchesTool.new(assistant).perform(tool_context, touch_plan_id: touch_plan_id,
                                                                                                       reason: 'Stop plan'))
    archive_payload = JSON.parse(Captain::Tools::ArchiveTouchPlanTool.new(assistant).perform(tool_context, touch_plan_id: touch_plan_id))

    expect(create_payload).to include(
      'action' => 'create_touch_plan',
      'touch_plan_id' => touch_plan_id,
      'name' => 'Conversation nurture',
      'entity_kinds' => ['conversation'],
      'touch_count' => 1
    )
    expect(create_payload.dig('touch_plan', 'touches', 0, 'body')).to eq('Plan follow-up')
    expect(create_payload.dig('touch_plan', 'touches', 0, 'metadata')).to include(
      'nil_value' => nil,
      'blank_value' => '',
      'false_value' => false,
      'zero_value' => 0,
      'empty_list' => []
    )
    expect(apply_payload).to include(
      'action' => 'apply_touch_plan',
      'touch_plan_id' => touch_plan_id,
      'touch_plan_name' => 'Conversation nurture',
      'created_count' => 1
    )
    expect(apply_payload.dig('meta', 'count')).to eq(1)
    expect(apply_payload['touch_ids']).to contain_exactly(Reminder.last.id)
    expect(cancel_payload).to include(
      'action' => 'cancel_touches',
      'found_count' => 1,
      'cancelled_count' => 1,
      'remaining_open_count' => 0,
      'touch_plan_id' => touch_plan_id,
      'reason' => 'Stop plan'
    )
    expect(archive_payload).to include('action' => 'archive_touch_plan', 'touch_plan_id' => touch_plan_id, 'active' => false)
    expect(archive_payload.dig('touch_plan', 'archived_at')).to be_present
  end
end
