require 'rails_helper'

RSpec.describe Telephony::AiVoice::AssistantAssignmentLock do
  self.use_transactional_tests = false

  let(:inbox_id) { SecureRandom.random_number(2**31) + 1 }

  it 'fences transaction-scoped assignment writers until the tool body finishes' do
    lock_id = described_class.send(:lock_id_for, inbox_id)
    pool = ActiveRecord::Base.connection_pool
    writer_connection = pool.checkout

    described_class.with_lock!(inbox_id) do
      expect(writer_can_acquire?(writer_connection, lock_id)).to be(false)
    end

    expect(writer_can_acquire?(writer_connection, lock_id)).to be(true)
  ensure
    pool&.checkin(writer_connection) if writer_connection
  end

  it 'keeps the fence until every nested acquisition is released' do
    lock_id = described_class.send(:lock_id_for, inbox_id)
    pool = ActiveRecord::Base.connection_pool
    writer_connection = pool.checkout

    described_class.with_lock!(inbox_id) do
      described_class.with_lock!(inbox_id) do
        expect(writer_can_acquire?(writer_connection, lock_id)).to be(false)
      end

      expect(writer_can_acquire?(writer_connection, lock_id)).to be(false)
    end

    expect(writer_can_acquire?(writer_connection, lock_id)).to be(true)
  ensure
    pool&.checkin(writer_connection) if writer_connection
  end

  it 'releases the session fence when the tool body raises' do
    lock_id = described_class.send(:lock_id_for, inbox_id)
    pool = ActiveRecord::Base.connection_pool
    writer_connection = pool.checkout

    expect do
      described_class.with_lock!(inbox_id) { raise 'tool failed' }
    end.to raise_error('tool failed')

    expect(writer_can_acquire?(writer_connection, lock_id)).to be(true)
  ensure
    pool&.checkin(writer_connection) if writer_connection
  end

  def writer_can_acquire?(writer_connection, lock_id)
    writer_connection.transaction(requires_new: true) do
      writer_connection.select_value("SELECT pg_try_advisory_xact_lock(#{lock_id})")
    end
  end
end
