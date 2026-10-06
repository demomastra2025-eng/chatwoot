require 'rails_helper'

RSpec.describe 'Captain touch management copilot services' do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }

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

    expect(cancel_payload).to include(
      'action' => 'cancel_touch',
      'touch_id' => pending_touch.id,
      'status' => 'cancelled',
      'reason' => 'Done'
    )
    expect(cancel_payload.dig('touch', 'status')).to eq('cancelled')
    expect(delete_payload).to include(
      'action' => 'delete_touch',
      'deleted_touch_id' => cancelled_touch.id,
      'touch_id' => cancelled_touch.id,
      'status' => 'cancelled'
    )
    expect(account.reminders.exists?(cancelled_touch.id)).to be(false)
  end

  def execute_confirmed(service, **arguments)
    first_result = service.execute(**arguments)
    first_payload = JSON.parse(first_result)
    expect(first_payload.dig('data', 'confirmation_required')).to be(true)

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
