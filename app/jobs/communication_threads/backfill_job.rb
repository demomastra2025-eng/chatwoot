# frozen_string_literal: true

class CommunicationThreads::BackfillJob < ApplicationJob
  queue_as :low

  def perform(account_id: nil, dry_run: true, batch_size: 1000)
    @dry_run = dry_run
    @seen_new_thread_keys = Set.new
    @counts = fresh_counts

    conversation_scope(account_id).find_each(batch_size: batch_size) do |conversation|
      backfill_conversation(conversation)
    end

    counts
  end

  private

  attr_reader :counts, :dry_run, :seen_new_thread_keys

  def fresh_counts
    {
      scanned: 0,
      created_threads: 0,
      linked_conversations: 0,
      skipped: 0,
      dry_run: dry_run
    }
  end

  def conversation_scope(account_id)
    scope = Conversation.where.not(contact_id: nil)
    account_id.present? ? scope.where(account_id: account_id) : scope
  end

  def backfill_conversation(conversation)
    counts[:scanned] += 1
    count_expected_changes(conversation)
    return if dry_run

    Conversations::CommunicationThreadResolver.new(conversation: conversation).perform
  rescue ActiveRecord::ActiveRecordError => e
    counts[:skipped] += 1
    Rails.logger.warn("CommunicationThreads::BackfillJob skipped conversation=#{conversation.id}: #{e.class}: #{e.message}")
  end

  def count_expected_changes(conversation)
    thread_key = [conversation.account_id, conversation.contact_id]
    unless thread_exists?(conversation) || seen_new_thread_keys.include?(thread_key)
      counts[:created_threads] += 1
      seen_new_thread_keys.add(thread_key)
    end

    counts[:linked_conversations] += 1 unless link_exists?(conversation)
  end

  def thread_exists?(conversation)
    CommunicationThread.exists?(account_id: conversation.account_id, contact_id: conversation.contact_id)
  end

  def link_exists?(conversation)
    CommunicationThreadConversation.exists?(account_id: conversation.account_id, conversation_id: conversation.id)
  end
end
