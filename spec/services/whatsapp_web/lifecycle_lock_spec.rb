require 'rails_helper'

RSpec.describe WhatsappWeb::LifecycleLock do
  subject(:lock) { described_class.new(channel_id: 42) }

  let(:lock_key) { 'WHATSAPP_WEB_LIFECYCLE_LOCK::42' }
  let(:token) { 'owner-token' }

  before do
    allow(SecureRandom).to receive(:uuid).and_return(token)
  end

  it 'acquires a bounded lease and releases only its ownership token' do
    expect(Redis::Alfred).to receive(:set)
      .with(lock_key, token, nx: true, ex: described_class::LOCK_TTL)
      .and_return(true)
    expect(Redis::Alfred).to receive(:delete_if_value).with(lock_key, token)

    expect(lock.with_lock { :completed }).to eq(:completed)
  end

  it 'rejects overlapping operations without deleting the active lease' do
    allow(Redis::Alfred).to receive(:set).and_return(false)
    expect(Redis::Alfred).not_to receive(:delete_if_value)

    expect { lock.with_lock { :not_reached } }
      .to raise_error(described_class::LockAcquisitionError, /already in progress/)
  end

  it 'releases its ownership token when the operation fails' do
    allow(Redis::Alfred).to receive(:set).and_return(true)
    expect(Redis::Alfred).to receive(:delete_if_value).with(lock_key, token)

    expect { lock.with_lock { raise 'provider failed' } }.to raise_error('provider failed')
  end

  it 'does not delete a successor lease after ownership changes' do
    Redis::Alfred.delete(lock_key)

    lock.with_lock do
      Redis::Alfred.set(lock_key, 'successor-token', ex: described_class::LOCK_TTL)
    end

    expect(Redis::Alfred.get(lock_key)).to eq('successor-token')
  ensure
    Redis::Alfred.delete(lock_key)
  end
end
