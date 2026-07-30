require 'rails_helper'

RSpec.describe KaspiPay::ConversationDeliveryService do
  let(:account) { create(:account, locale: 'ru') }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:hook) { create(:integrations_hook, :kaspi_pay, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:payment) do
    create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      source: conversation,
      payment_type: 'qr',
      amount: 15_000,
      qr_token: 'https://pay.kaspi.kz/pay/link-token',
      qr_original_token: 'https://qr.kaspi.kz/original-token'
    )
  end

  describe '#deliver!' do
    it 'creates a native outgoing link message and deduplicates retries' do
      service = described_class.new(payment: payment, conversation: conversation, sender: assistant)

      first = service.deliver!(mode: 'link')
      second = service.deliver!(mode: 'link')

      message = conversation.messages.find(first[:message_id])
      expect(message).to be_outgoing
      expect(message.sender).to eq(assistant)
      expect(message.content).to include('15000 KZT', payment.qr_token)
      expect(first).to include(mode: 'link', sent: true, deduplicated: false)
      expect(second).to include(message_id: message.id, deduplicated: true)
      expect(conversation.messages.where(id: message.id).count).to eq(1)
    end

    it 'creates a native outgoing QR image attachment with a payment-link fallback' do
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("\x89PNG\r\n\x1A\nqr-image".b),
        filename: 'kaspi-pay.png',
        content_type: 'image/png',
        metadata: { account_id: account.id },
        identify: false
      )
      image_service = instance_double(KaspiPay::QrImageService, create_blob!: blob)
      allow(KaspiPay::QrImageService).to receive(:new).with(payment: payment).and_return(image_service)

      payload = described_class.new(payment: payment, conversation: conversation, sender: assistant).deliver!(mode: 'qr_image')

      message = conversation.messages.find(payload[:message_id])
      expect(message.content).to include(payment.qr_token)
      expect(message.attachments.one?).to be(true)
      expect(message.attachments.first.file_type).to eq('image')
      expect(message.attachments.first.file.blob).to eq(blob)
      expect(payload).to include(mode: 'qr_image', sent: true, deduplicated: false)
    end

    it 'rejects cross-conversation delivery' do
      other_conversation = create(:conversation, account: account)

      expect do
        described_class.new(payment: payment, conversation: other_conversation, sender: assistant).deliver!(mode: 'link')
      end.to raise_error(ArgumentError, /another conversation/)
    end
  end
end
