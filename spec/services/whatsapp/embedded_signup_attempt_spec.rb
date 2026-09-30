require 'rails_helper'

describe Whatsapp::EmbeddedSignupAttempt do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:nonce) { SecureRandom.urlsafe_base64(24) }
  let(:attempt) { described_class.new(account: account, user: user, nonce: nonce) }
  let(:state_key) do
    format(Redis::RedisKeys::WHATSAPP_EMBEDDED_SIGNUP_ATTEMPT,
           account_id: account.id, user_id: user.id, digest: OpenSSL::Digest::SHA256.hexdigest(nonce))
  end

  it 'rejects malformed nonces' do
    ['short', nil, 'a' * 21, "#{'a' * 30}/", 'a' * 129].each do |bad_nonce|
      expect { described_class.new(account: account, user: user, nonce: bad_nonce) }
        .to raise_error(described_class::InvalidNonceError)
    end
  end

  it 'registers a short-lived pending attempt without storing the nonce itself' do
    allow(Redis::Alfred).to receive(:set).and_call_original

    attempt.register(signup_type: 'coexistence')

    expect(attempt.client_state).to eq(status: 'pending', signup_type: 'coexistence')
    expect(Redis::Alfred).to have_received(:set).with(state_key, anything, nx: true, ex: 30.minutes.to_i)
    expect(Redis::Alfred.get(state_key)).not_to include(nonce)
    expect(state_key).not_to include(nonce)
  end

  it 'reports unknown for an attempt it never saw' do
    expect(attempt.client_state).to eq(status: 'unknown')
  end

  it 'allows exactly one completion claim' do
    attempt.register(signup_type: 'standard')

    expect(attempt.claim(signup_type: 'standard')).to be(true)
    expect(described_class.new(account: account, user: user, nonce: nonce).claim(signup_type: 'standard')).to be(false)
    expect(attempt.client_state[:status]).to eq('processing')
  end

  it 'does not let a late registration overwrite a claimed attempt' do
    attempt.claim(signup_type: 'standard')
    attempt.register(signup_type: 'standard')

    expect(attempt.client_state[:status]).to eq('processing')
  end

  it 'reports the created inbox only while it belongs to the account' do
    inbox = create(:inbox, account: account)
    attempt.claim(signup_type: 'standard')
    attempt.complete!(inbox.id)

    expect(attempt.client_state).to eq(status: 'completed', signup_type: 'standard', inbox_id: inbox.id)

    inbox.destroy!
    expect(attempt.client_state).to eq(status: 'completed', signup_type: 'standard')
  end

  it 'records failures with a short error code' do
    attempt.claim(signup_type: 'standard')
    attempt.fail!('waba_ambiguous')

    expect(attempt.client_state).to eq(status: 'failed', signup_type: 'standard', error_code: 'waba_ambiguous')
  end

  it 'is scoped to the user and the account' do
    attempt.claim(signup_type: 'standard')
    other_user = create(:user, account: account, role: :administrator)
    other_account = create(:account)

    expect(described_class.new(account: account, user: other_user, nonce: nonce).client_state).to eq(status: 'unknown')
    expect(described_class.new(account: other_account, user: user, nonce: nonce).client_state).to eq(status: 'unknown')
  end
end
