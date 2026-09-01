# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inboxes::ConversationPolicyNormalizer do
  describe '.perform' do
    it 'normalizes messenger, Twilio WhatsApp, and non-messenger inboxes' do
      account = create(:account)
      telegram_inbox = create(:channel_telegram, account: account).inbox
      twitter_channel = create(:channel_twitter_profile, account: account)
      twitter_inbox = create(:inbox, account: account, channel: twitter_channel)
      email_inbox = create(:channel_email, account: account).inbox
      twilio_whatsapp_inbox = create(:channel_twilio_sms, account: account, medium: :whatsapp).inbox
      twilio_sms_inbox = create(:channel_twilio_sms, account: account, medium: :sms).inbox

      telegram_inbox.update_column(:lock_to_single_conversation, false)
      twitter_inbox.update_column(:lock_to_single_conversation, false)
      email_inbox.update_column(:lock_to_single_conversation, true)
      twilio_whatsapp_inbox.update_column(:lock_to_single_conversation, false)
      twilio_sms_inbox.update_column(:lock_to_single_conversation, true)

      result = described_class.perform

      expect(result).to eq(
        mismatches_before: 5,
        rows_updated: 5,
        mismatches_after: 0
      )
      expect(telegram_inbox.reload[:lock_to_single_conversation]).to be(true)
      expect(twitter_inbox.reload[:lock_to_single_conversation]).to be(true)
      expect(email_inbox.reload[:lock_to_single_conversation]).to be(false)
      expect(twilio_whatsapp_inbox.reload[:lock_to_single_conversation]).to be(true)
      expect(twilio_sms_inbox.reload[:lock_to_single_conversation]).to be(false)
    end

    it 'is idempotent when inbox policies already match their channels' do
      account = create(:account)
      create(:channel_telegram, account: account)
      create(:channel_email, account: account)

      expect(described_class.perform).to eq(
        mismatches_before: 0,
        rows_updated: 0,
        mismatches_after: 0
      )
    end
  end
end
