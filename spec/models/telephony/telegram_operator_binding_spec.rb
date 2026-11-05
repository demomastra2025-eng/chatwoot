require 'rails_helper'

RSpec.describe Telephony::TelegramOperatorBinding do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }

  before do
    account.enable_features!(:telegram_calls_bot)
    allow(TelegramCalls::Config).to receive_messages(
      bot_token: '123456:TEST_BOT_TOKEN',
      bot_username: 'onelink_calls_bot',
      gateway_url: 'http://gateway.internal:8790',
      gateway_token: 'gw-secret'
    )
  end

  describe 'validations and unique account-level telegram identity' do
    it 'rejects a user who is not a member of the account' do
      outsider = create(:user)
      binding = described_class.new(account: account, user: outsider)

      expect(binding).not_to be_valid
      expect(binding.errors[:user_id]).to be_present
    end

    it 'disconnects any stale binding in the same account when re-linking the same Telegram account' do
      second_user = create(:user, account: account, role: :agent)
      sync_service = instance_double(TelegramCalls::SipLineSyncService, deactivate!: { deactivated: true })
      allow(TelegramCalls::SipLineSyncService).to receive(:new).and_return(sync_service)

      old_binding = described_class.create!(
        account: account, user: user, telegram_user_id: '777001',
        telegram_chat_id: '777001', verified_at: Time.current, on_line: true
      )
      new_binding = described_class.create!(account: account, user: second_user)
      issued = new_binding.issue_link_token!

      consumed = described_class.consume_link_token!(
        issued[:token],
        from: { id: 777_001, username: 'rebound_op' },
        chat_id: 777_001
      )
      expect(consumed).to eq(new_binding)
      expect(old_binding.reload).not_to be_connected
      expect(old_binding.telegram_user_id).to be_nil
      expect(new_binding.reload.telegram_user_id).to eq('777001')
    end
  end

  describe 'single-use link token lifecycle and membership revocation' do
    it 'refuses a previously issued token after access is removed without linking an identity' do
      binding = described_class.create!(account: account, user: user)
      issued = binding.issue_link_token!
      Account.find(account.id).disable_features!(:telegram_calls_bot)

      expect(described_class.consume_link_token!(issued[:token], from: { id: 777_001 }, chat_id: 777_001)).to be_nil
      expect(binding.reload.telegram_user_id).to be_nil
      expect(binding.verified_at).to be_nil
    end

    it 'rejects token issuance and going online while OFF before invoking SIP sync' do
      binding = described_class.create!(account: account, user: user, telegram_user_id: '777001',
                                        telegram_chat_id: '777001', verified_at: Time.current)
      account.disable_features!(:telegram_calls_bot)
      expect(TelegramCalls::SipLineSyncService).not_to receive(:new)

      expect { binding.issue_link_token! }.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('TELEGRAM_CALLS_BOT_DISABLED') }
      expect { binding.go_on_line! }.to raise_error(Telephony::Error)
      expect(binding.reload.link_token_digest).to be_nil
      expect(binding).not_to be_on_line
    end

    it 'issues a hashed token, consumes it once, and blocks replay' do
      binding = described_class.create!(account: account, user: user)
      issued = binding.issue_link_token!

      expect(issued[:deep_link]).to eq("https://t.me/onelink_calls_bot?start=#{issued[:token]}")
      expect(binding.link_token_digest).not_to eq(issued[:token])

      consumed = described_class.consume_link_token!(
        issued[:token],
        from: { id: 777_001, username: 'aset_op', first_name: 'Aset' },
        chat_id: 777_001
      )
      expect(consumed).to eq(binding)
      expect(binding.reload).to be_connected

      replay = described_class.consume_link_token!(
        issued[:token],
        from: { id: 999_999, username: 'attacker' },
        chat_id: 999_999
      )
      expect(replay).to be_nil
    end

    it 'revokes connected scope immediately and disconnects cleanly in Agents::DestroyJob when AccountUser is removed' do
      sync_service = instance_double(TelegramCalls::SipLineSyncService, deactivate!: { deactivated: true })
      allow(TelegramCalls::SipLineSyncService).to receive(:new).and_return(sync_service)
      binding = described_class.create!(
        account: account, user: user, telegram_user_id: '777001',
        telegram_chat_id: '777001', verified_at: Time.current, on_line: true,
        sip_lease_meta: { 'group_key' => 'g1', 'lines' => [{ 'line_key' => 'l1', 'registered' => true }] }
      )

      account.account_users.where(user_id: user.id).delete_all
      expect(binding.reload).not_to be_connected
      expect(described_class.connected.where(id: binding.id)).to be_empty

      Agents::DestroyJob.perform_now(account, user)
      expect(binding.reload.telegram_user_id).to be_nil
      expect(binding).not_to be_on_line
    end

    it 'rejects expired link tokens' do
      binding = described_class.create!(account: account, user: user)
      issued = binding.issue_link_token!
      binding.update!(link_token_expires_at: 1.minute.ago)

      consumed = described_class.consume_link_token!(
        issued[:token],
        from: { id: 777_001, username: 'aset_op' },
        chat_id: 777_001
      )
      expect(consumed).to be_nil
      expect(binding.reload).not_to be_connected
    end
  end

  describe 'line state, fail-closed go_on_line!, and sanitized status_payload' do
    let(:sync_service) do
      instance_double(
        TelegramCalls::SipLineSyncService,
        activate!: { synced_lines: 1 },
        deactivate!: { deactivated: true }
      )
    end

    before do
      allow(TelegramCalls::SipLineSyncService).to receive(:new).and_return(sync_service)
    end

    it 'toggles on_line, strips lease secrets from status_payload, and disconnects cleanly' do
      binding = described_class.create!(
        account: account, user: user, telegram_user_id: '777001',
        telegram_chat_id: '777001', username: 'aset_op', verified_at: Time.current,
        sip_lease_meta: {
          'group_key' => 'g1',
          'lines' => [{ 'line_key' => 'l1', 'provider' => 'wazo', 'registered' => true, 'release_key' => 'secret-lease-key' }]
        }
      )

      binding.go_on_line!
      expect(binding).to be_on_line
      expect(sync_service).to have_received(:activate!)
      expect(binding.status_payload[:sip_lines].first).not_to have_key('release_key')

      expect(binding.update_verified_phone!('+7 (701) 555-44-33')).to be(true)
      expect(binding.phone_number).to eq('+77015554433')

      binding.disconnect!
      expect(binding.connected? || binding.on_line?).to be(false)
      expect(sync_service).to have_received(:deactivate!)
    end

    it 'stays off_line when SipLineSyncService#activate! raises Telephony::Error' do
      binding = described_class.create!(
        account: account, user: user, telegram_user_id: '777002',
        telegram_chat_id: '777002', verified_at: Time.current, on_line: false
      )
      allow(sync_service).to receive(:activate!).and_raise(
        Telephony::Error.new(code: 'TELEGRAM_SIP_SYNC_FAILED', message: 'Gateway unreachable', status: :bad_gateway)
      )

      expect { binding.go_on_line! }.to raise_error(Telephony::Error)
      expect(binding.reload).not_to be_on_line
    end
  end
end
