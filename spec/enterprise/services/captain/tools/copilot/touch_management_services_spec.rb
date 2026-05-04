require 'rails_helper'

RSpec.describe 'Captain touch management copilot services' do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }

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
    pending_touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :pending)
    cancel_service = Captain::Tools::Copilot::CancelTouchService.new(assistant, user: user, conversation: conversation)
    cancel_payload = JSON.parse(cancel_service.execute(touch_id: pending_touch.id, reason: 'Done'))

    cancelled_touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :cancelled)
    delete_service = Captain::Tools::Copilot::DeleteTouchService.new(assistant, user: user, conversation: conversation)
    delete_payload = JSON.parse(delete_service.execute(touch_id: cancelled_touch.id))

    expect(cancel_payload).to include('action' => 'cancel_touch')
    expect(cancel_payload.dig('touch', 'status')).to eq('cancelled')
    expect(delete_payload).to include('action' => 'delete_touch', 'deleted_touch_id' => cancelled_touch.id)
    expect(account.reminders.exists?(cancelled_touch.id)).to be(false)
  end

  it 'creates, applies, cancels, and archives touch plans through copilot services' do
    create_payload = JSON.parse(Captain::Tools::Copilot::CreateTouchPlanService.new(assistant, user: user, conversation: conversation).execute(
                                  name: 'Conversation nurture',
                                  entity_kinds: ['conversation'],
                                  touches: [touch_definition]
                                ))
    touch_plan_id = create_payload.dig('touch_plan', 'id')

    apply_payload = JSON.parse(Captain::Tools::Copilot::ApplyTouchPlanService.new(assistant, user: user,
                                                                                             conversation: conversation).execute(touch_plan_id: touch_plan_id))
    cancel_payload = JSON.parse(Captain::Tools::Copilot::CancelTouchesService.new(assistant, user: user, conversation: conversation).execute(
                                  touch_plan_id: touch_plan_id,
                                  reason: 'Stop plan'
                                ))
    archive_payload = JSON.parse(Captain::Tools::Copilot::ArchiveTouchPlanService.new(assistant, user: user,
                                                                                                 conversation: conversation).execute(touch_plan_id: touch_plan_id))

    expect(create_payload).to include('action' => 'create_touch_plan')
    expect(apply_payload.dig('meta', 'count')).to eq(1)
    expect(cancel_payload).to include('action' => 'cancel_touches', 'cancelled_count' => 1)
    expect(archive_payload.dig('touch_plan', 'archived_at')).to be_present
  end
end
