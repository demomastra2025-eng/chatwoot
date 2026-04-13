require 'rails_helper'

RSpec.describe Channel::TelegramPersonal do
  around do |example|
    with_modified_env(
      'FRONTEND_URL' => 'https://app.example.com',
      'TELEGRAM_PERSONAL_DEFAULT_API_ID' => nil,
      'TELEGRAM_PERSONAL_DEFAULT_API_HASH' => nil
    ) do
      example.run
    end
  end

  describe 'defaults and derived fields' do
    it 'generates webhook credentials and callback url' do
      channel = create(:channel_telegram_personal, phone_number: '+77066318623')

      expect(channel.generated_inbox_name).to eq('77066318623')
      expect(channel.webhook_identifier).to be_present
      expect(channel.webhook_secret).to be_present
      expect(channel.callback_webhook_url).to eq(
        "https://app.example.com/webhooks/telegram_personal/#{channel.webhook_identifier}"
      )
    end

    it 'uses shared MTProto defaults when inbox-specific credentials are omitted' do
      channel = nil

      with_modified_env(
        'TELEGRAM_PERSONAL_DEFAULT_API_ID' => '24110447',
        'TELEGRAM_PERSONAL_DEFAULT_API_HASH' => 'sharedhash'
      ) do
        channel = described_class.create!(
          account: create(:account),
          phone_number: '+77066319999'
        )
      end

      expect(channel.api_id).to eq(24_110_447)
      expect(channel.api_hash).to eq('sharedhash')
      expect(channel.resolved_api_id).to eq(24_110_447)
      expect(channel.resolved_api_hash).to eq('sharedhash')
      expect(channel.uses_default_api_credentials?).to be(false)
    end
  end

  describe 'runtime identity updates' do
    it 'does not allow changing api_id after creation' do
      channel = create(:channel_telegram_personal)

      expect(channel.update(api_id: channel.api_id + 1)).to be(false)
      expect(channel.errors[:api_id]).to include('cannot be changed after creation')
    end

    it 'does not allow changing phone_number after creation' do
      channel = create(:channel_telegram_personal)

      expect(channel.update(phone_number: '+77070000000')).to be(false)
      expect(channel.errors[:phone_number]).to include('cannot be changed after creation')
    end
  end

  describe 'multitenant uniqueness' do
    it 'allows the same phone number in different accounts' do
      first = create(:channel_telegram_personal, phone_number: '+77066318623')
      second = build(
        :channel_telegram_personal,
        account: create(:account),
        phone_number: first.phone_number
      )

      expect(second).to be_valid
    end

    it 'allows multiple Telegram Personal channels in the same account when phone numbers differ' do
      account = create(:account)
      create(:channel_telegram_personal, account: account, phone_number: '+77066318623')
      second = build(
        :channel_telegram_personal,
        account: account,
        phone_number: '+77070000000'
      )

      expect(second).to be_valid
    end

    it 'does not allow the same phone number twice in the same account' do
      account = create(:account)
      create(:channel_telegram_personal, account: account, phone_number: '+77066318623')
      duplicate = build(
        :channel_telegram_personal,
        account: account,
        phone_number: '+77066318623'
      )

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:phone_number]).to be_present
    end
  end

  describe 'credential validation' do
    it 'requires credentials when neither inbox values nor global defaults are present' do
      channel = described_class.new(
        account: create(:account),
        phone_number: '+77066318888'
      )

      expect(channel).not_to be_valid
      expect(channel.errors[:api_id]).to include('must be present or configured globally')
      expect(channel.errors[:api_hash]).to include('must be present or configured globally')
    end
  end

  describe 'runtime lifecycle helpers' do
    it 'marks the channel as disconnected while pending deletion' do
      channel = create(
        :channel_telegram_personal,
        connection_state: 'connected',
        lifecycle_state: 'connected',
        last_error: 'boom'
      )

      channel.mark_pending_deletion!(timestamp: Time.zone.parse('2026-04-08 12:00:00'))
      channel.reload

      expect(channel.connection_state).to eq('disconnected')
      expect(channel.lifecycle_state).to eq('disconnected')
      expect(channel.last_error).to be_nil
      expect(channel.last_synced_at).to eq(Time.zone.parse('2026-04-08 12:00:00'))
    end

    it 'normalizes runtime_state into a durable checkpoint payload' do
      channel = create(
        :channel_telegram_personal,
        runtime_state: {
          history_sync_state: 'running',
          history_sync_checkpoint: {
            dialog_user_ids: [123, '456', nil],
            next_dialog_index: '2'
          }
        }
      )

      expect(channel.runtime_state_payload['history_sync_state']).to eq('running')
      expect(channel.history_sync_checkpoint).to include(
        'version' => 1,
        'dialog_user_ids' => %w[123 456],
        'next_dialog_index' => 2
      )
      expect(channel.runtime_state_payload['contacts_sync_count']).to eq(0)
    end

    it 'normalizes runtime_state updates received from the gateway' do
      channel = create(:channel_telegram_personal)

      channel.apply_runtime_update!(
        runtime_state: {
          history_sync_count: '7',
          history_sync_checkpoint: {
            dialog_user_ids: [42],
            next_dialog_index: 1
          }
        }
      )
      channel.reload

      expect(channel.runtime_state['history_sync_count']).to eq(7)
      expect(channel.runtime_state.dig('history_sync_checkpoint', 'dialog_user_ids')).to eq(['42'])
      expect(channel.runtime_state.dig('history_sync_checkpoint', 'next_dialog_index')).to eq(1)
      expect(channel.runtime_state).to have_key('contacts_sync_state')
    end
  end
end
