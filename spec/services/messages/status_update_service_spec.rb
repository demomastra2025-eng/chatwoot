require 'rails_helper'

describe Messages::StatusUpdateService do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:message) { create(:message, conversation: conversation, account: account) }

  def captain_follow_up_delivery_records
    account = create(:account)
    account.enable_features!('captain_integration')
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending)
    assistant = create(:captain_assistant, account: account, config: captain_follow_up_settings)
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    incoming = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    anchor = create_captain_follow_up_anchor(account, inbox, conversation, assistant)
    fence = captain_follow_up_fence(conversation, incoming)

    reminder = Captain::Conversation::FollowUpJob.schedule!(
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor,
      step: { index: 0, delay_seconds: 60 },
      control_fence: fence
    )
    message = materialize_confirmed_captain_follow_up(reminder, conversation, assistant, anchor, fence)
    { account: account, assistant: assistant, reminder: reminder, message: message }
  end

  def captain_follow_up_settings
    {
      'follow_up_settings' => {
        'enabled' => true,
        'prompt' => '',
        'steps' => [
          { 'mode' => 'static', 'message' => 'First check-in.', 'delay_seconds' => 60 },
          { 'mode' => 'static', 'message' => 'Second check-in.', 'delay_seconds' => 120 }
        ]
      }
    }
  end

  def create_captain_follow_up_anchor(account, inbox, conversation, assistant)
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: assistant,
      message_type: :outgoing,
      private: false,
      additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
    )
  end

  def captain_follow_up_fence(conversation, incoming)
    {
      control_generation: conversation.current_captain_control_generation,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i,
      last_message_id: incoming.id
    }
  end

  def materialize_confirmed_captain_follow_up(reminder, conversation, assistant, anchor, fence)
    reminder.mark_processing!
    marker = {
      'captain_follow_up' => {
        'assistant_id' => assistant.id,
        'anchor_message_id' => anchor.id,
        'step_index' => 0,
        'control_fence' => fence
      }
    }
    message = Reminders::MessageMaterializer.new(reminder: reminder, additional_attributes: marker).perform(
      conversation: conversation,
      sender: assistant,
      content: 'First check-in.',
      delivery_policy: nil
    )
    reminder.update!(status: :completed, completed_at: Time.current)
    reminder.mark_delivery_dispatched!(message.id, stage: 'provider_accepted')
    message
  end

  describe '#perform' do
    context 'when status is valid' do
      it 'updates the status of the message' do
        service = described_class.new(message, 'delivered')
        service.perform
        expect(message.reload.status).to eq('delivered')
      end

      it 'clears external_error when status is not failed' do
        message.update!(status: 'failed', external_error: 'previous error')
        service = described_class.new(message, 'delivered')
        service.perform
        expect(message.reload.status).to eq('delivered')
        expect(message.reload.external_error).to be_nil
      end

      it 'updates external_error when status is failed' do
        service = described_class.new(message, 'failed', 'some error')
        service.perform
        expect(message.reload.status).to eq('failed')
        expect(message.reload.external_error).to eq('some error')
      end

      it 'records provider delivery separately from touch materialization' do
        reminder = create(:reminder, account: account, touch_conversation: conversation)
        reminder.mark_delivery_materialized!(message.id)
        message.update!(additional_attributes: message.additional_attributes.to_h.merge('touch_id' => reminder.id))

        described_class.new(message, 'delivered').perform

        expect(reminder.reload.delivery_stage).to eq('delivered')
        expect(reminder.metadata['delivery_stage_updated_at']).to be_present
      end

      it 'classifies template rejection and fails the touch occurrence' do
        reminder = create(:reminder, account: account, touch_conversation: conversation)
        reminder.mark_delivery_materialized!(message.id)
        message.update!(additional_attributes: message.additional_attributes.to_h.merge('touch_id' => reminder.id))

        described_class.new(message, 'failed', 'WhatsApp template was rejected by provider').perform

        expect(reminder.reload).to be_failed
        expect(reminder.delivery_stage).to eq('template_rejected')
        expect(reminder.metadata['delivery_failure_category']).to eq('template_rejected')
      end
    end


    it 'advances the Captain follow-up after confirmed delivery and keeps webhook replays idempotent' do
      records = captain_follow_up_delivery_records

      2.times { described_class.new(records[:message], 'delivered').perform }

      next_step = records[:account].reminders.captain_follow_up.find_by!(
        idempotency_key: "captain_follow_up:#{records[:assistant].id}:#{records[:message].id}:1"
      )
      expect(next_step).to be_pending
      expect(records[:account].reminders.captain_follow_up.count).to eq(2)
    end

    context 'when status is invalid' do
      it 'returns false for invalid status' do
        service = described_class.new(message, 'invalid_status')
        expect(service.perform).to be false
      end

      it 'prevents transition from read to delivered' do
        message.update!(status: 'read')
        service = described_class.new(message, 'delivered')
        expect(service.perform).to be false
        expect(message.reload.status).to eq('read')
      end
    end
  end
end
