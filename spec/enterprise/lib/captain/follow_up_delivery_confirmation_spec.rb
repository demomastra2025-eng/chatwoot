require 'rails_helper'

RSpec.describe Captain::FollowUpDeliveryConfirmation do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_telegram, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'timing_mode' => 'relative_after_previous_send',
          'steps' => [
            { 'delay_seconds' => 1.hour.to_i, 'mode' => 'static', 'message' => 'First' },
            { 'delay_seconds' => 6.hours.to_i, 'mode' => 'static', 'message' => 'Second' }
          ]
        }
      }
    )
  end
  let!(:incoming_message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: 1.day.ago)
  end
  let!(:anchor_message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, created_at: 23.hours.ago)
  end
  let!(:follow_up_message) do
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :outgoing,
      status: :sent,
      additional_attributes: {
        'captain_follow_up' => {
          'assistant_id' => assistant.id,
          'anchor_message_id' => anchor_message.id,
          'step_index' => 0
        }
      }
    )
  end

  before { assistant.inboxes << inbox }

  it 'waits for a provider acknowledgement before scheduling the next step' do
    expect do
      described_class.new(message: follow_up_message).perform
    end.not_to change { Reminder.captain_follow_up.count }

    follow_up_message.update_column(:source_id, 'provider-message-id')

    expect do
      described_class.new(message: follow_up_message).perform
    end.to change { Reminder.captain_follow_up.count }.by(1)

    reminder = Reminder.captain_follow_up.last
    expect(reminder.metadata.dig('captain_follow_up', 'step_index')).to eq(1)
    expect(follow_up_message.reload.additional_attributes.dig('captain_follow_up', 'delivery_confirmed_at')).to be_present
  end

  it 'does not schedule after a provider failure even when a source id exists' do
    follow_up_message.update_columns(source_id: 'provider-message-id', status: Message.statuses[:failed])

    expect do
      described_class.new(message: follow_up_message).perform
    end.not_to change { Reminder.captain_follow_up.count }
  end

  it 'cancels the scheduled next step when an accepted message later fails' do
    follow_up_message.update_column(:source_id, 'provider-message-id')
    described_class.new(message: follow_up_message).perform
    reminder = Reminder.captain_follow_up.last

    follow_up_message.update_column(:status, Message.statuses[:failed])
    described_class.new(message: follow_up_message).perform

    expect(reminder.reload).to be_cancelled
    expect(reminder.last_error).to eq('Previous follow-up failed at the provider')
    expect(follow_up_message.reload.additional_attributes.dig('captain_follow_up', 'delivery_failed_at')).to be_present
  end

  it 'cancels an absolute next step after settings were disabled' do
    settings = assistant.config.deep_dup
    settings['follow_up_settings']['timing_mode'] = 'absolute_from_last_incoming'
    assistant.update!(config: settings)
    follow_up_message.update_column(:source_id, 'provider-message-id')
    described_class.new(message: follow_up_message).perform
    reminder = Reminder.captain_follow_up.last

    assistant.update!(config: assistant.config.deep_merge('follow_up_settings' => { 'enabled' => false }))
    follow_up_message.update_column(:status, Message.statuses[:failed])
    described_class.new(message: follow_up_message).perform

    expect(reminder.reload).to be_cancelled
  end

  it 'keeps a provider failure terminal when a late acknowledgement arrives' do
    follow_up_message.update_column(:status, Message.statuses[:failed])
    described_class.new(message: follow_up_message).perform

    follow_up_message.update_columns(status: Message.statuses[:sent], source_id: 'late-provider-message-id')

    expect do
      described_class.new(message: follow_up_message).perform
    end.not_to change { Reminder.captain_follow_up.count }
  end

  it 'schedules the next step only once for duplicate provider callbacks' do
    follow_up_message.update_column(:source_id, 'provider-message-id')

    expect do
      2.times { described_class.new(message: follow_up_message).perform }
    end.to change { Reminder.captain_follow_up.count }.by(1)
  end
end
