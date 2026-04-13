require 'rails_helper'

RSpec.describe Campaigns::TargetResolver do
  describe '#resolve' do
    let(:account) { create(:account) }
    let(:contact) { create(:contact, account: account, email: 'target@example.com', phone_number: '+15550001155') }

    it 'returns the email target for email inboxes' do
      inbox = create(:channel_email, account: account).inbox

      target = described_class.new(inbox: inbox, contact: contact).resolve

      expect(target).to eq('target@example.com')
    end

    it 'returns whatsapp web fallback source id from the phone number' do
      inbox = create(:channel_whatsapp_web, account: account).inbox

      target = described_class.new(inbox: inbox, contact: contact).resolve

      expect(target).to eq('15550001155')
    end

    it 'returns telegram personal target from contact attributes' do
      contact.update!(additional_attributes: { 'social_telegram_user_id' => 4242 })
      inbox = create(:channel_telegram_personal, account: account).inbox

      target = described_class.new(inbox: inbox, contact: contact).resolve

      expect(target).to eq('4242')
    end
  end
end
