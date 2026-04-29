require 'rails_helper'

RSpec.describe Channel::Weixin do
  around do |example|
    with_modified_env(
      'FRONTEND_URL' => 'https://app.example.com',
      'WEIXIN_ILINK_DEFAULT_TOKEN' => nil
    ) do
      example.run
    end
  end

  describe 'defaults and derived fields' do
    it 'can be created without an iLink token for QR-first login' do
      channel = described_class.create!(
        account: create(:account),
        display_name: 'Pending QR Login'
      )

      expect(channel.ilink_token).to be_blank
      expect(channel.token_fingerprint).to be_blank
      expect(channel.connection_state).to eq('disconnected')
      expect(channel.lifecycle_state).to eq('pending_auth')
    end

    it 'generates webhook credentials and callback url' do
      channel = create(:channel_weixin, provider_account_id: 'wxid_alice', display_name: 'Alice WeChat')

      expect(channel.generated_inbox_name).to eq('Alice WeChat')
      expect(channel.webhook_identifier).to be_present
      expect(channel.webhook_secret).to be_present
      expect(channel.callback_webhook_url).to eq(
        "https://app.example.com/webhooks/weixin/#{channel.webhook_identifier}"
      )
    end

    it 'uses shared iLink token default when inbox token is omitted' do
      channel = nil

      with_modified_env('WEIXIN_ILINK_DEFAULT_TOKEN' => 'shared-ilink-token') do
        channel = described_class.create!(
          account: create(:account),
          provider_account_id: 'wxid_shared',
          display_name: 'Shared Token Account'
        )
      end

      expect(channel.ilink_token).to eq('shared-ilink-token')
      expect(channel.resolved_ilink_token).to eq('shared-ilink-token')
      expect(channel.token_fingerprint).to be_present
    end
  end

  describe 'runtime identity updates' do
    it 'allows setting provider account and token once after QR login' do
      channel = described_class.create!(
        account: create(:account),
        display_name: 'Pending QR Login'
      )

      channel.apply_runtime_update!(
        ilink_token: 'qr-issued-token',
        provider_account_id: 'wxid_qr_bot',
        display_name: 'QR Bot',
        connection_state: 'connected',
        lifecycle_state: 'connected'
      )

      channel.reload
      expect(channel.ilink_token).to eq('qr-issued-token')
      expect(channel.resolved_ilink_token).to eq('qr-issued-token')
      expect(channel.token_fingerprint).to eq(Digest::SHA256.hexdigest('qr-issued-token'))
      expect(channel.provider_account_id).to eq('wxid_qr_bot')
      expect(channel.display_name).to eq('QR Bot')
      expect(channel.connection_state).to eq('connected')
      expect(channel.lifecycle_state).to eq('connected')
    end

    it 'does not allow changing provider_account_id after creation' do
      channel = create(:channel_weixin, provider_account_id: 'wxid_original')

      expect(channel.update(provider_account_id: 'wxid_changed')).to be(false)
      expect(channel.errors[:provider_account_id]).to include('cannot be changed after creation')
    end

    it 'does not allow changing token_fingerprint after creation' do
      channel = create(:channel_weixin, ilink_token: 'first-token')

      channel.ilink_token = 'second-token'
      expect(channel.save).to be(false)
      expect(channel.errors[:token_fingerprint]).to include('cannot be changed after creation')
    end
  end

  describe 'runtime lifecycle helpers' do
    it 'marks the channel as disconnected while pending deletion' do
      channel = create(
        :channel_weixin,
        connection_state: 'connected',
        lifecycle_state: 'connected',
        last_error: 'boom'
      )

      channel.mark_pending_deletion!(timestamp: Time.zone.parse('2026-04-28 12:00:00'))
      channel.reload

      expect(channel.connection_state).to eq('disconnected')
      expect(channel.lifecycle_state).to eq('disconnected')
      expect(channel.last_error).to be_nil
      expect(channel.last_synced_at).to eq(Time.zone.parse('2026-04-28 12:00:00'))
    end

    it 'normalizes runtime_state into durable iLink fields' do
      channel = create(
        :channel_weixin,
        runtime_state: {
          qr_login_state: 'ready',
          poller_state: 'running',
          last_update_id: 42,
          message_dedup: { ids: [123, '456', nil] }
        }
      )

      expect(channel.runtime_state_payload).to include(
        'qr_login_state' => 'ready',
        'poller_state' => 'running',
        'last_update_id' => '42'
      )
      expect(channel.runtime_state_payload.dig('message_dedup', 'ids')).to eq(%w[123 456])
    end

    it 'normalizes runtime_state updates received from the gateway' do
      channel = create(:channel_weixin)

      channel.apply_runtime_update!(
        runtime_state: {
          context_token_state: 'fresh',
          last_update_id: 99,
          message_dedup: { ids: [99] }
        },
        context_token: 'context-token-1'
      )
      channel.reload

      expect(channel.context_token).to eq('context-token-1')
      expect(channel.runtime_state['context_token_state']).to eq('fresh')
      expect(channel.runtime_state['last_update_id']).to eq('99')
      expect(channel.runtime_state.dig('message_dedup', 'ids')).to eq(['99'])
    end

    it 'does not write sensitive runtime fields to audit logs' do
      channel = create(:channel_weixin)

      channel.update!(
        connection_state: 'connected',
        context_token: 'audit-context-token',
        context_tokens: { 'wxid_contact' => 'audit-peer-token' },
        last_error: 'authorization token=secret'
      )

      audit_log = Enterprise::AuditLog.where(
        auditable_type: 'Inbox',
        auditable_id: channel.inbox.id,
        action: 'update'
      ).last

      expect(audit_log.audited_changes).to eq('connection_state' => %w[disconnected connected])
      expect(audit_log.audited_changes.keys).not_to include('context_token', 'context_tokens', 'last_error')
    end
  end
end
