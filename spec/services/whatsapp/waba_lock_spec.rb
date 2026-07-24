require 'rails_helper'

RSpec.describe Whatsapp::WabaLock do
  let(:waba_id) { "waba-lock-#{SecureRandom.hex(8)}" }

  it 'reuses a lock for nested work in the same thread and releases it afterward' do
    result = described_class.new(waba_id).with_lock do
      described_class.new(waba_id).with_lock { :completed }
    end

    expect(result).to eq(:completed)
    expect(described_class.new(waba_id).with_lock { :released }).to eq(:released)
  end

  it 'rejects overlapping work from another database session' do
    ready = Queue.new
    release = Queue.new
    holder = Thread.new do
      described_class.new(waba_id).with_lock do
        ready << true
        release.pop
      end
    end
    ready.pop

    expect { described_class.new(waba_id).with_lock { nil } }.to raise_error(described_class::LockAcquisitionError)
  ensure
    release << true
    holder&.value
  end

  it 'serializes the same WABA across independent PostgreSQL connections' do
    pool = ActiveRecord::Base.connection_pool
    owner_connection = pool.checkout
    contender_connection = pool.checkout
    owner = described_class.new(waba_id)
    contender = described_class.new(waba_id)

    expect(owner.send(:acquire_lock, owner_connection)).to be(true)
    owner_held = true
    expect(contender.send(:acquire_lock, contender_connection)).to be(false)

    owner.send(:release_lock, owner_connection)
    owner_held = false
    expect(contender.send(:acquire_lock, contender_connection)).to be(true)
    contender_held = true
  ensure
    owner&.send(:release_lock, owner_connection) if owner_held
    contender&.send(:release_lock, contender_connection) if contender_held
    pool&.checkin(owner_connection) if owner_connection
    pool&.checkin(contender_connection) if contender_connection
  end

  it 'acquires multiple WABA locks in a stable order' do
    first_lock = instance_double(described_class)
    second_lock = instance_double(described_class)
    allow(described_class).to receive(:new).with('waba-a').and_return(first_lock)
    allow(described_class).to receive(:new).with('waba-z').and_return(second_lock)
    expect(first_lock).to receive(:with_lock).ordered.and_yield
    expect(second_lock).to receive(:with_lock).ordered.and_yield

    result = described_class.with_locks(%w[waba-z waba-a waba-z]) { :completed }

    expect(result).to eq(:completed)
  end

  it 'requires a WABA ID' do
    expect { described_class.new(nil).with_lock { nil } }.to raise_error(ArgumentError, 'WABA ID is required')
  end
end
