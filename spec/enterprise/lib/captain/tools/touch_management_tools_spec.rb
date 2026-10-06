require 'rails_helper'

RSpec.describe 'Captain touch management public tools', type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: conversation.contact_id } }) }

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
end
