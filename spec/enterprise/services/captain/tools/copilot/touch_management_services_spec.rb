require 'rails_helper'

RSpec.describe 'Captain touch management copilot services' do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }

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
      metadata: {}
    }
  end

  it 'cancels and deletes single touches through copilot services' do
    pending_touch = create(
      :reminder,
      account: account,
      remindable: conversation,
      touch_conversation: conversation,
      status: :pending
    )
    cancel_service = copilot_service(Captain::Tools::Copilot::CancelTouchService)
    cancel_payload = JSON.parse(execute_confirmed(cancel_service, touch_id: pending_touch.id, reason: 'Done'))

    cancelled_touch = create(
      :reminder,
      account: account,
      remindable: conversation,
      touch_conversation: conversation,
      status: :cancelled,
      body: 'Delete me'
    )
    delete_service = copilot_service(Captain::Tools::Copilot::DeleteTouchService)
    delete_payload = JSON.parse(execute_confirmed(delete_service, touch_id: cancelled_touch.id))

    expect(cancel_payload).to include('action' => 'cancel_touch', 'touch_id' => pending_touch.id, 'status' => 'cancelled', 'reason' => 'Done')
    expect(cancel_payload.dig('touch', 'status')).to eq('cancelled')
    expect(delete_payload).to include('action' => 'delete_touch', 'deleted_touch_id' => cancelled_touch.id)
    expect(account.reminders.exists?(cancelled_touch.id)).to be(false)
  end

  it 'creates, applies, cancels, and archives touch plans through copilot services' do
    create_service = copilot_service(Captain::Tools::Copilot::CreateTouchPlanService)
    create_payload = JSON.parse(execute_confirmed(
                                  create_service,
                                  name: 'Conversation nurture',
                                  entity_kinds: ['conversation'],
                                  touches: [touch_definition]
                                ))
    touch_plan_id = create_payload.dig('touch_plan', 'id')

    apply_service = copilot_service(Captain::Tools::Copilot::ApplyTouchPlanService)
    apply_payload = JSON.parse(execute_confirmed(apply_service, touch_plan_id: touch_plan_id))
    created_touch_id = Reminder.last.id
    cancel_service = copilot_service(Captain::Tools::Copilot::CancelTouchesService)
    cancel_payload = JSON.parse(execute_confirmed(
                                  cancel_service,
                                  touch_plan_id: touch_plan_id,
                                  reason: 'Stop plan'
                                ))
    archive_service = copilot_service(Captain::Tools::Copilot::ArchiveTouchPlanService)
    archive_payload = JSON.parse(execute_confirmed(archive_service, touch_plan_id: touch_plan_id))

    expect(create_payload).to include('action' => 'create_touch_plan', 'touch_plan_id' => touch_plan_id, 'touch_count' => 1)
    expect(apply_payload).to include('action' => 'apply_touch_plan', 'touch_plan_id' => touch_plan_id, 'created_count' => 1)
    expect(apply_payload.dig('meta', 'count')).to eq(1)
    expect(apply_payload['touch_ids']).to contain_exactly(created_touch_id)
    expect(cancel_payload).to include('action' => 'cancel_touches', 'cancelled_count' => 1, 'touch_plan_id' => touch_plan_id, 'reason' => 'Stop plan')
    expect(archive_payload).to include('action' => 'archive_touch_plan', 'touch_plan_id' => touch_plan_id, 'active' => false)
    expect(archive_payload.dig('touch_plan', 'archived_at')).to be_present
  end

  def execute_confirmed(service, **arguments)
    first_result = service.execute(**arguments)
    first_payload = JSON.parse(first_result)
    return first_result unless first_payload.dig('data', 'confirmation_required')

    confirmation_token = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'confirmation_token')

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => "Подтверждаю #{confirmation_token}" }
    )

    service.execute(**arguments)
  end

  def copilot_service(service_class)
    service_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread)
  end
end
