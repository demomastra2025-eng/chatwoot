# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channels::Stats do
  let(:account) { create(:account) }

  describe '.inbox_counts' do
    it 'counts the inboxes that exist per catalog channel' do
      create_list(:channel_api, 3, account: account)
      create(:channel_widget, account: account)
      create(:channel_telegram, account: account)

      counts = described_class.inbox_counts

      expect(counts['api']).to eq(3)
      expect(counts['website']).to eq(1)
      expect(counts['telegram_bot']).to eq(1)
      expect(counts['line']).to eq(0)
    end

    it 'splits Twilio by its medium and folds Bandwidth into SMS' do
      create(:channel_twilio_sms, account: account)
      create_list(:channel_twilio_sms, 2, :whatsapp, account: account)
      create(:channel_sms, account: account)

      counts = described_class.inbox_counts

      expect(counts['sms']).to eq(2)
      expect(counts['whatsapp_twilio']).to eq(2)
    end

    it 'does not count an inbox that is being deleted' do
      channel = create(:channel_api, account: account)
      channel.inbox.update_columns(deleting_at: Time.current) # rubocop:disable Rails/SkipsModelValidations

      expect(described_class.inbox_counts['api']).to eq(0)
    end
  end

  describe '.override_counts' do
    it 'counts the clinics that have an exception per channel' do
      other_account = create(:account)
      show_channels_for(account, 'api', 'sms')
      hide_channels_for(other_account, 'api')

      counts = described_class.override_counts

      expect(counts['api']).to eq(2)
      expect(counts['sms']).to eq(1)
      expect(counts['line']).to eq(0)
    end

    it 'does not trip over accounts without exceptions or with a broken value' do
      account.update!(custom_attributes: { 'channel_overrides' => 'shown' })
      create(:account)

      expect(described_class.override_counts['api']).to eq(0)
    end
  end
end
