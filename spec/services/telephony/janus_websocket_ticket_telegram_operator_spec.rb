require 'rails_helper'

RSpec.describe Telephony::JanusWebsocketTicket do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_voice, :sipuni, account: account) }
  let(:profile) do
    create(:telephony_sip_profile, account: account, user: user, inbox: channel.inbox,
                                   availability_mode: 'browser_webphone', status: 'active', enabled: true)
  end
  let(:binding) do
    Telephony::TelegramOperatorBinding.create!(account: account, user: user, telegram_user_id: '900000001',
                                               telegram_chat_id: '900000001', verified_at: Time.current, on_line: false)
  end
  let(:server_url) { 'wss://app.example.test/janus-sipuni' }
  let(:registration_instance_id) do
    profile.acquire_browser_registration_lease!(client_instance_id: "telegram_softphone:#{binding.id}",
                                                browser_instance_id: "telegram_softphone:#{user.id}", user_id: user.id)
           .fetch(:registration_instance_id)
  end
  let(:ticket) { described_class.issue_for_telegram_operator(**issue_scope) }

  before { account.enable_features!(:channel_voice, :telegram_calls_bot) }

  def issue_scope
    { server_url: server_url, sip_profile: profile,
      binding: binding, registration_instance_id: registration_instance_id }
  end

  def valid_ticket?(value = ticket, origin: nil, path: '/janus-sipuni')
    described_class.valid?(ticket: value, origin: origin, path: path)
  end

  def signed_claims(changes)
    claims = described_class.send(:verified_payload, ticket).merge(changes.stringify_keys)
    described_class.send(:verifier).generate(claims, expires_in: 2.minutes, purpose: described_class::PURPOSE)
  end

  it 'authorizes initial activation while on_line is still false and Origin is missing' do
    expect(binding.on_line?).to be(false)
    expect(valid_ticket?).to be(true)
    expect(valid_ticket?(origin: '')).to be(true)
    payload = described_class.send(:verified_payload, ticket)
    expect(payload).to include('version' => 3, 'kind' => 'telegram_operator_sip', 'binding_id' => binding.id,
                               'account_id' => account.id, 'user_id' => user.id, 'sip_profile_id' => profile.id,
                               'registration_instance_id' => registration_instance_id, 'path' => '/janus-sipuni')
    expect(payload.keys).not_to include('sip_password', 'phone_number', 'telegram_user_id', 'api_hash', 'string_session')
  end

  it 'rejects every present Origin, including the usual matching browser origin' do
    ['https://app.example.test', 'https://foreign.example.test', ' ', 'null'].each do |origin|
      expect(valid_ticket?(origin: origin)).to be(false)
    end
  end

  it 'keeps the signed Janus endpoint binding' do
    expect(valid_ticket?(path: '/janus-asterisk')).to be(false)
  end

  it 'consumes a headless ticket only once' do
    expect(described_class.authorize?(ticket: ticket, origin: nil, path: '/janus-sipuni')).to be(true)
    expect(described_class.authorize?(ticket: ticket, origin: nil, path: '/janus-sipuni')).to be(false)
  end

  it 'expires the signed ticket' do
    issued = ticket
    travel_to 6.minutes.from_now do
      expect(described_class.send(:verified_payload, issued)).to be_nil
      expect(valid_ticket?(issued)).to be(false)
    end
  end

  it 'refuses foreign account, user and binding claims even when the payload has a valid signature' do
    other_account = create(:account)
    other_user = create(:user, account: account, role: :agent)
    other_binding = Telephony::TelegramOperatorBinding.create!(account: account, user: other_user)
    [{ account_id: other_account.id }, { user_id: other_user.id }, { binding_id: other_binding.id }].each do |claims|
      expect(valid_ticket?(signed_claims(claims))).to be(false)
    end
  end

  it 'refuses a foreign SIP profile and an unrecognized signed kind/version' do
    other_user = create(:user, account: account, role: :agent)
    other_profile = create(:telephony_sip_profile, account: account, user: other_user, inbox: channel.inbox,
                                                   availability_mode: 'browser_webphone', status: 'active')
    [{ sip_profile_id: other_profile.id }, { version: 1 }, { kind: 'unknown_headless' }].each do |claims|
      expect(valid_ticket?(signed_claims(claims))).to be(false)
    end
  end

  it 'refuses issuance for a foreign owner' do
    other_user = create(:user, account: account, role: :agent)
    other_profile = create(:telephony_sip_profile, account: account, user: other_user, inbox: channel.inbox,
                                                   availability_mode: 'browser_webphone', status: 'active')
    expect { described_class.issue_for_telegram_operator(**issue_scope, sip_profile: other_profile) }.to raise_error(ArgumentError)
  end

  it 'revokes a ticket when membership is removed' do
    issued = ticket
    AccountUser.where(account_id: account.id, user_id: user.id).delete_all
    expect(valid_ticket?(issued)).to be(false)
  end

  it 'revokes an already issued headless ticket when the bot flag is removed independently of native voice' do
    issued = ticket
    Account.find(account.id).disable_features!(:telegram_calls_bot)

    expect(account.feature_enabled?('channel_voice')).to be(true)
    expect(valid_ticket?(issued)).to be(false)
    expect(described_class.authorize?(ticket: issued, origin: nil, path: '/janus-sipuni')).to be(false)
    expect { described_class.issue_for_telegram_operator(**issue_scope) }.to raise_error(ArgumentError)
  end

  it 'revokes disconnected and unverified bindings' do
    issued = ticket
    binding.update!(verified_at: nil)
    expect(valid_ticket?(issued)).to be(false)
    expect { described_class.issue_for_telegram_operator(**issue_scope) }.to raise_error(ArgumentError)
  end

  it 'revokes a ticket when the provider policy is disabled' do
    issued = ticket
    allow(Telephony::ProviderPolicy).to receive(:enabled_for_profile?).and_return(false)
    expect(valid_ticket?(issued)).to be(false)
    expect { described_class.issue_for_telegram_operator(**issue_scope) }.to raise_error(ArgumentError)
  end

  it 'revokes disabled profiles, a changed mode and removed voice feature' do
    issued = ticket
    profile.update!(enabled: false)
    expect(valid_ticket?(issued)).to be(false)
    profile.update!(enabled: true, availability_mode: 'external_extension')
    expect(valid_ticket?(issued)).to be(false)
    profile.update!(availability_mode: 'browser_webphone')
    account.disable_features!(:channel_voice)
    expect(valid_ticket?(issued)).to be(false)
  end

  it 'revokes expired, replaced and foreign browser registration leases' do
    issued = ticket
    original = profile.reload.metadata.deep_dup
    %w[expires_at registration_instance_id client_instance_id browser_instance_id user_id].each do |key|
      metadata = original.deep_dup
      metadata['browser_registration_lease'][key] = key == 'expires_at' ? 1.second.ago.iso8601 : 'foreign-owner'
      profile.update!(metadata: metadata)
      expect(valid_ticket?(issued)).to be(false), key
    end
  end

  it 'does not reinterpret a browser ticket as headless even with operator-looking instance IDs' do
    browser = described_class.issue(**issue_scope.except(:binding), account: account, user: user)
    expect(valid_ticket?(browser)).to be(false)
    expect(valid_ticket?(browser, origin: 'https://app.example.test')).to be(true)
    expect(valid_ticket?(browser, origin: 'https://wrong.example.test')).to be(false)
  end
end
