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
      metadata: {}
    }
  end

  it 'returns a normalized cancel_touch payload' do
    touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :pending)
    payload = JSON.parse(Captain::Tools::CancelTouchTool.new(assistant).perform(tool_context, touch_id: touch.id, reason: 'Done'))

    expect(payload).to include('action' => 'cancel_touch')
    expect(payload.dig('touch', 'id')).to eq(touch.id)
    expect(payload.dig('touch', 'status')).to eq('cancelled')
  end

  it 'returns a normalized delete_touch payload' do
    touch = create(:reminder, account: account, remindable: conversation, touch_conversation: conversation, status: :cancelled)
    payload = JSON.parse(Captain::Tools::DeleteTouchTool.new(assistant).perform(tool_context, touch_id: touch.id))

    expect(payload).to include('action' => 'delete_touch', 'deleted' => true, 'deleted_touch_id' => touch.id)
    expect(account.reminders.exists?(touch.id)).to be(false)
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

    expect(create_payload).to include('action' => 'create_touch_plan')
    expect(apply_payload).to include('action' => 'apply_touch_plan')
    expect(apply_payload.dig('meta', 'count')).to eq(1)
    expect(cancel_payload).to include('action' => 'cancel_touches', 'cancelled_count' => 1)
    expect(archive_payload).to include('action' => 'archive_touch_plan')
    expect(archive_payload.dig('touch_plan', 'archived_at')).to be_present
  end
end
