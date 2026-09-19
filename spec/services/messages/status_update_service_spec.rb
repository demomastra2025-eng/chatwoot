require 'rails_helper'

describe Messages::StatusUpdateService do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:message) { create(:message, conversation: conversation, account: account) }

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
