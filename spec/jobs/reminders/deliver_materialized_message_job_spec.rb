require 'rails_helper'

RSpec.describe Reminders::DeliverMaterializedMessageJob do
  it 'dispatches a materialized message once across duplicate jobs' do
    conversation = create(:conversation)
    touch = create(
      :reminder,
      account: conversation.account,
      conversation: conversation,
      remindable: conversation,
      status: :pending,
      body: 'Dispatch once'
    )
    active_claim = touch.mark_processing!
    message = create(
      :message,
      account: conversation.account,
      inbox: conversation.inbox,
      conversation: conversation,
      message_type: :outgoing,
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => touch.id, 'touch_source' => 'touch' }
    )
    touch.mark_delivery_materialized!(message.id)
    allow(SendReplyJob).to receive(:perform_now)

    2.times { described_class.perform_now(touch.id, message.id, active_claim) }

    expect(SendReplyJob).to have_received(:perform_now).with(message.id).once
    expect(touch.reload).to be_delivery_dispatched_for(message.id)
  end
end
