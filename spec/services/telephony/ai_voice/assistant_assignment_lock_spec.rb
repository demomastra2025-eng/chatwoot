require 'rails_helper'

RSpec.describe Telephony::AiVoice::AssistantAssignmentLock do
  let(:inbox) { create(:inbox) }

  it 'fences transaction-scoped assignment writers until the tool body finishes' do
    lock_id = described_class.send(:lock_id_for, inbox.id)
    pool = ActiveRecord::Base.connection_pool
    writer_connection = pool.checkout

    described_class.with_lock!(inbox.id) do
      writer_connection.transaction(requires_new: true) do
        acquired = writer_connection.select_value("SELECT pg_try_advisory_xact_lock(#{lock_id})")
        expect(acquired).to be(false)
      end
    end

    writer_connection.transaction(requires_new: true) do
      acquired = writer_connection.select_value("SELECT pg_try_advisory_xact_lock(#{lock_id})")
      expect(acquired).to be(true)
    end
  ensure
    pool&.checkin(writer_connection) if writer_connection
  end

  it 'keeps the fence until every nested acquisition is released' do
    lock_id = described_class.send(:lock_id_for, inbox.id)
    pool = ActiveRecord::Base.connection_pool
    writer_connection = pool.checkout

    described_class.with_lock!(inbox.id) do
      described_class.with_lock!(inbox.id) do
        expect(writer_can_acquire?(writer_connection, lock_id)).to be(false)
      end

      expect(writer_can_acquire?(writer_connection, lock_id)).to be(false)
    end

    expect(writer_can_acquire?(writer_connection, lock_id)).to be(true)
  ensure
    pool&.checkin(writer_connection) if writer_connection
  end

  it 'releases the session fence when the tool body raises' do
    lock_id = described_class.send(:lock_id_for, inbox.id)
    pool = ActiveRecord::Base.connection_pool
    writer_connection = pool.checkout

    expect do
      described_class.with_lock!(inbox.id) { raise 'tool failed' }
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
