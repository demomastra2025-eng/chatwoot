# frozen_string_literal: true

require 'digest'

class CommunicationThreads::UnreadCountRepairService
  DEFAULT_BATCH_SIZE = 100

  def initialize(account:, dry_run: true, batch_size: DEFAULT_BATCH_SIZE)
    @account = account
    @dry_run = dry_run
    @batch_size = Integer(batch_size)
    raise ArgumentError, 'batch_size must be positive' unless @batch_size.positive?
  end

  def perform
    thread_rows = communication_threads.reorder(nil).pluck(:id, :contact_id, :unread_count)
    expected_by_thread_id = expected_unread_counts
    drifted_rows = drifted_thread_rows(thread_rows, expected_by_thread_id)
    result = repair_result(thread_rows, drifted_rows, expected_by_thread_id)
    return result if dry_run

    drifted_rows.each_slice(batch_size) do |batch|
      batch.each { |thread_id, contact_id, _stored_count| repair_thread(thread_id, contact_id, result) }
    end

    result
  end

  private

  attr_reader :account, :batch_size, :dry_run

  def drifted_thread_rows(thread_rows, expected_by_thread_id)
    thread_rows.reject do |thread_id, _contact_id, stored_count|
      stored_count == expected_by_thread_id.fetch(thread_id, 0)
    end
  end

  def repair_result(thread_rows, drifted_rows, expected_by_thread_id)
    {
      account_id: account.id,
      scanned_threads: thread_rows.size,
      drifted_threads: drifted_rows.size,
      updated_threads: 0,
      skipped_threads: 0,
      stored_unread_total: thread_rows.sum { |_thread_id, _contact_id, unread_count| unread_count },
      expected_unread_total: thread_rows.sum { |thread_id, _contact_id, _unread_count| expected_by_thread_id.fetch(thread_id, 0) },
      dry_run: dry_run
    }
  end

  def repair_thread(thread_id, contact_id, result)
    updated = CommunicationThread.transaction do
      lock_contact_thread!(contact_id)
      thread = communication_threads.lock.find(thread_id)
      expected_count = expected_unread_counts(thread_ids: [thread.id]).fetch(thread.id, 0)
      next false if thread.unread_count == expected_count

      thread.update_columns(unread_count: expected_count, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      true
    end
    result[:updated_threads] += 1 if updated
  rescue ActiveRecord::ActiveRecordError => e
    result[:skipped_threads] += 1
    Rails.logger.warn(
      "CommunicationThreads::UnreadCountRepairService skipped account=#{account.id} thread=#{thread_id}: #{e.class}: #{e.message}"
    )
  end

  def lock_contact_thread!(contact_id)
    identity = "communication-thread:#{account.id}:#{contact_id}"
    lock_id = Digest::SHA256.digest(identity).unpack1('q>')
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
  end

  def communication_threads
    CommunicationThread.where(account_id: account.id)
  end

  def expected_unread_counts(thread_ids: nil)
    scope = Message.without_imported_history
                   .reorder(nil)
                   .joins(conversation: :communication_thread_conversation)
                   .where(
                     messages: {
                       account_id: account.id,
                       message_type: Message.message_types[:incoming],
                       private: false
                     },
                     conversations: { account_id: account.id },
                     communication_thread_conversations: { account_id: account.id }
                   )
                   .where('messages.created_at > COALESCE(conversations.agent_last_seen_at, ?)', Time.zone.at(0))
    scope = scope.where(communication_thread_conversations: { communication_thread_id: thread_ids }) if thread_ids.present?

    scope.group('communication_thread_conversations.communication_thread_id').count
  end
end
