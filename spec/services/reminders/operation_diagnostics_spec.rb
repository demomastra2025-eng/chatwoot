require 'rails_helper'

RSpec.describe Reminders::OperationDiagnostics do
  let(:conversation) { create(:conversation) }
  let(:persisted_touch) do
    create(:reminder, account: conversation.account, remindable: conversation, body: 'Sensitive reminder body')
  end

  it 'logs a typed duplicate with separate HMAC labels and no raw touch data' do
    attempted_touch = persisted_touch.dup
    attempted_touch.errors.add(
      :base,
      Reminder::DUPLICATE_OPEN_TOUCH_ERROR,
      message: Reminder::DUPLICATE_OPEN_TOUCH_MESSAGE
    )
    error = ActiveRecord::RecordInvalid.new(attempted_touch)

    expect(Rails.logger).to receive(:warn) do |encoded_payload|
      payload = JSON.parse(encoded_payload)

      expect(payload).to include(
        'operation' => 'create',
        'entity_type' => 'Conversation',
        'status' => 'failed',
        'error_class' => 'ActiveRecord::RecordInvalid',
        'error_code' => 'duplicate_open_touch'
      )
      expect(payload['record_label']).to be_present
      expect(payload['touch_label']).to be_present
      expect(payload['record_label']).not_to eq(payload['touch_label'])
      expect(payload.keys).not_to include('account_id', 'record_id', 'touch_id', 'fingerprint', 'body')
      expect(encoded_payload).not_to include('Sensitive reminder body')
      expect(payload.values).not_to include(persisted_touch.id.to_s)
    end

    described_class.report(
      operation: 'create',
      error: error,
      record: conversation,
      touch: attempted_touch,
      persisted_touch: persisted_touch
    )
  end

  it 'distinguishes other RecordInvalid failures from duplicate-open-touch validation' do
    invalid_touch = persisted_touch.dup
    invalid_touch.errors.add(:body, 'is invalid')
    error = ActiveRecord::RecordInvalid.new(invalid_touch)

    expect(Rails.logger).to receive(:warn) do |encoded_payload|
      expect(JSON.parse(encoded_payload)['error_code']).to eq('record_invalid')
    end

    described_class.report(operation: 'create', error: error, record: conversation, touch: invalid_touch)
  end

  it 'does not raise when warning logging fails' do
    allow(Rails.logger).to receive(:warn).and_raise(IOError, 'diagnostic logger unavailable')

    expect do
      described_class.report(operation: 'sync_route', error: IOError.new, record: conversation)
    end.not_to raise_error
  end

  it 'does not raise when HMAC label generation fails' do
    allow(OpenSSL::HMAC).to receive(:hexdigest).and_raise(RuntimeError, 'HMAC unavailable')

    expect do
      described_class.report(operation: 'sync_route', error: IOError.new, record: conversation)
    end.not_to raise_error
  end

  it 'does not raise when record-label access fails' do
    allow(conversation).to receive(:id).and_raise(RuntimeError, 'record id unavailable')

    expect do
      described_class.report(operation: 'sync_route', error: IOError.new, record: conversation)
    end.not_to raise_error
  end
end
