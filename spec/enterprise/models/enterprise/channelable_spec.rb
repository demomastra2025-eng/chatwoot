require 'rails_helper'

# The update of a channel is written into the audit log of its inbox, which account administrators read: no secret of the
# channel may reach it (AuditLogs::SecretFilter).
RSpec.describe Enterprise::Channelable do
  def channel_audits(channel)
    Audited::Audit.where(auditable_type: 'Inbox', auditable_id: channel.inbox.id, action: 'update').order(:id)
  end

  def stored_text(channel)
    channel_audits(channel).pluck(Arel.sql('audited_changes::text AS raw_changes')).join("\n")
  end

  describe 'a Telegram personal channel' do
    let(:channel) { create(:channel_telegram_personal) }
    let(:session) { '1BVtsOK8Bu-telethon-session-string' }

    it 'writes the session string as [FILTERED] and leaves the runtime of the session out' do
      channel.apply_runtime_update!(
        connection_state: 'connected',
        lifecycle_state: 'connected',
        last_error: 'flood wait',
        last_synced_at: Time.current,
        string_session: session,
        runtime_state: {
          'qr_login_url' => 'tg://login?token=secret-login-token',
          'history_sync_checkpoint' => { 'dialog_user_ids' => %w[700100 700200] }
        }
      )

      expect(channel_audits(channel).map(&:audited_changes)).to eq([{ 'string_session' => [nil, '[FILTERED]'] }])
      expect(stored_text(channel)).not_to include(session, 'secret-login-token', '700100', 'flood wait')
    end

    it 'writes nothing when only the runtime of the session changes' do
      channel.apply_runtime_update!(
        connection_state: 'connected',
        lifecycle_state: 'connected',
        last_synced_at: Time.current,
        runtime_state: { 'history_sync_state' => 'running', 'history_sync_checkpoint' => { 'dialog_user_ids' => %w[700100] } }
      )

      expect(channel_audits(channel)).to be_empty
    end

    it 'keeps the settings the operator changed in the runtime snapshot, without the rest of it' do
      channel.update!(runtime_state: channel.runtime_state_payload.merge('sync_groups' => true, 'history_sync_state' => 'running'))

      expect(channel_audits(channel).last.audited_changes).to eq(
        'runtime_state' => [{ 'ignored_chat_ids' => [], 'sync_groups' => false }, { 'ignored_chat_ids' => [], 'sync_groups' => true }]
      )
    end

    it 'writes a new API hash as [FILTERED]' do
      channel.update!(api_hash: 'fresh-api-hash-value')

      expect(channel_audits(channel).last.audited_changes).to eq('api_hash' => ['[FILTERED]', '[FILTERED]'])
      expect(stored_text(channel)).not_to include('fresh-api-hash-value')
    end
  end

  describe 'the credentials of other channels' do
    it 'writes the passwords and the OAuth tokens of an e-mail channel as [FILTERED]' do
      channel = create(:channel_email, :microsoft_email)
      channel.update!(imap_password: 'imap-password-value', provider_config: { 'access_token' => 'oauth-access', 'expires_on' => 'soon' })

      changes = channel_audits(channel).last.audited_changes
      expect(changes['imap_password']).to eq(['', '[FILTERED]'])
      expect(changes['provider_config'].last).to eq('access_token' => '[FILTERED]', 'expires_on' => 'soon')
      expect(stored_text(channel)).not_to include('imap-password-value', 'oauth-access')
    end

    it 'writes the secret of an API channel as [FILTERED] and keeps its webhook' do
      channel = create(:channel_api)
      channel.update!(secret: 'api-channel-secret', webhook_url: 'https://example.com/hook')

      expect(channel_audits(channel).last.audited_changes).to eq(
        'secret' => ['[FILTERED]', '[FILTERED]'],
        'webhook_url' => ['http://example.com', 'https://example.com/hook']
      )
      expect(stored_text(channel)).not_to include('api-channel-secret')
    end

    it 'filters the API key inside the provider settings of a WhatsApp channel' do
      stub_request(:get, %r{graph\.facebook\.com/.*/message_templates}).to_return(status: 200, body: '', headers: {})
      channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
      channel.update!(provider_config: channel.provider_config.merge('api_key' => 'rotated-cloud-key'))

      expect(channel_audits(channel).last.audited_changes['provider_config'].last).to include(
        'api_key' => '[FILTERED]', 'phone_number_id' => channel.provider_config['phone_number_id']
      )
      expect(stored_text(channel)).not_to include('rotated-cloud-key')
    end
  end
end
