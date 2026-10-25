require 'rails_helper'

RSpec.describe AuditLogs::SecretFilter do
  # Columns of the channel tables that look like a credential by their name but are not one
  let(:public_channel_columns) do
    {
      'channel_tiktok' => %w[refresh_token_expires_at], # a date
      'channel_twilio_sms' => %w[api_key_sid], # the id of the key, its secret is auth_token
      'channel_web_widgets' => %w[website_token], # written into the widget script of the site
      'channel_weixins' => %w[token_fingerprint] # a digest, never written to the log (Enterprise::Channelable)
    }
  end

  describe '.filter' do
    it 'writes the credential columns as [FILTERED] and keeps blank sides and the other columns' do
      filtered = described_class.filter(
        'string_session' => [nil, '1BVtsOK8Bu'],
        'api_hash' => %w[old-hash new-hash],
        'bot_token' => ['123:abc', ''],
        'phone_number' => ['+77010000001', '+77010000002']
      )

      expect(filtered).to eq(
        'string_session' => [nil, '[FILTERED]'],
        'api_hash' => ['[FILTERED]', '[FILTERED]'],
        'bot_token' => ['[FILTERED]', ''],
        'phone_number' => ['+77010000001', '+77010000002']
      )
    end

    it 'filters the credential keys inside a JSON column and keeps the rest of it' do
      filtered = described_class.filter(
        'provider_config' => [
          { 'api_key' => 'old-key', 'phone_number_id' => '1', 'verification_pin' => '123456' },
          { 'api_key' => 'new-key', 'phone_number_id' => '1', 'auth' => { 'refresh_token' => 'r', 'expires_on' => 'x' } }
        ]
      )

      expect(filtered['provider_config']).to eq(
        [
          { 'api_key' => '[FILTERED]', 'phone_number_id' => '1', 'verification_pin' => '[FILTERED]' },
          { 'api_key' => '[FILTERED]', 'phone_number_id' => '1', 'auth' => { 'refresh_token' => '[FILTERED]', 'expires_on' => 'x' } }
        ]
      )
    end

    it 'keeps only the operator settings of a runtime snapshot' do
      old_settings = { 'sync_groups' => false, 'ignored_chat_ids' => [] }
      new_settings = { 'sync_groups' => true, 'ignored_chat_ids' => %w[5] }
      full_snapshot = old_settings.merge('qr_login_url' => 'tg://login?token=abc', 'history_sync_checkpoint' => { 'dialog_user_ids' => %w[1 2] })

      expect(described_class.filter('runtime_state' => [full_snapshot, full_snapshot.merge(new_settings)])).to eq(
        'runtime_state' => [old_settings, new_settings]
      )
      expect(described_class.filter('runtime_state' => full_snapshot)).to eq('runtime_state' => old_settings)
      expect(described_class.filter('runtime_state' => [{}, 'tg://login?token=abc'])).to eq('runtime_state' => [{}, '[FILTERED]'])
    end

    it 'leaves out a change of the runtime snapshot that keeps the settings as they were' do
      before = { 'sync_groups' => false, 'ignored_chat_ids' => [], 'history_sync_state' => 'running' }
      after = { 'sync_groups' => false, 'ignored_chat_ids' => [], 'history_sync_state' => 'completed', 'qr_login_url' => 'tg://x' }

      expect(described_class.filter('runtime_state' => [before, after], 'name' => %w[a b])).to eq('name' => %w[a b])
      expect(described_class.filter('runtime_state' => [{}, { 'qr_login_url' => 'tg://x' }])).to eq({})
    end

    it 'leaves a filtered entry as it is' do
      changes = {
        'string_session' => [nil, 'secret'], 'name' => %w[a b],
        'runtime_state' => [{ 'qr_login_url' => 'x', 'sync_groups' => false }, { 'sync_groups' => true }]
      }
      once = described_class.filter(changes)

      expect(once['runtime_state']).to eq([{ 'sync_groups' => false }, { 'sync_groups' => true }])
      expect(described_class.filter(once)).to eq(once)
    end
  end

  describe '.filter_stored' do
    it 'filters an entry kept as a JSON string and leaves other values as they are' do
      stored = { 'string_session' => [nil, 'secret'] }.to_json

      expect(described_class.filter_stored(stored)).to eq('string_session' => [nil, '[FILTERED]'])
      expect(described_class.filter_stored('not json')).to eq('not json')
      expect(described_class.filter_stored(nil)).to be_nil
    end
  end

  describe '.filter_audit' do
    it 'filters the entries of an inbox and shows the others as they are' do
      inbox_entry = Audited::Audit.new(auditable_type: 'Inbox', audited_changes: { 'bot_token' => %w[a b] })
      account_entry = Audited::Audit.new(auditable_type: 'Account', audited_changes: { 'limits' => [{}, { 'captain_tokens' => 5 }] })

      expect(described_class.filter_audit(inbox_entry)).to eq('bot_token' => ['[FILTERED]', '[FILTERED]'])
      expect(described_class.filter_audit(account_entry)).to eq('limits' => [{}, { 'captain_tokens' => 5 }])
    end
  end

  describe '.secret_key?' do
    it 'names the credentials and not the counts of AI tokens' do
      secrets = %w[access_token webhook_verify_token api_secret beeline_api_token verification_pin string_session]
      others = %w[captain_tokens max_tokens phone_number_id business_account_id authorization_status pinned]

      expect(secrets.select { |key| described_class.secret_key?(key) }).to eq(secrets)
      expect(others.select { |key| described_class.secret_key?(key) }).to eq([])
    end
  end

  # A new channel (or a new column) that keeps a credential has to be named here, or its value would reach the audit log
  it 'knows every credential column of the channel tables' do
    connection = ActiveRecord::Base.connection
    unknown = connection.tables.grep(/\Achannel_/).sort.flat_map do |table|
      connection.columns(table).map(&:name)
                .grep(described_class::SECRET_KEY_PATTERN)
                .reject { |column| described_class::SECRET_COLUMNS.include?(column) }
                .reject { |column| public_channel_columns.fetch(table, []).include?(column) }
                .map { |column| "#{table}.#{column}" }
    end

    expect(unknown).to eq([])
  end
end
