require 'rails_helper'

describe ActivityMessageHandler do
  it 'annotates activity created by one communication-thread update' do
    conversation = build(:conversation)
    conversation.communication_thread_event_id = 'thread-event-1'

    params = conversation.send(:activity_message_params, 'Conversation resolved')

    expect(params[:additional_attributes]).to eq(
      communication_thread_event_id: 'thread-event-1'
    )
  end

  it 'does not annotate regular conversation activity' do
    conversation = build(:conversation)

    params = conversation.send(:activity_message_params, 'Conversation resolved')

    expect(params).not_to have_key(:additional_attributes)
  end
end
