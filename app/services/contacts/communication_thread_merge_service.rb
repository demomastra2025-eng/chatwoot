# frozen_string_literal: true

class Contacts::CommunicationThreadMergeService
  def initialize(base_contact:, mergee_contact:)
    @base_contact = base_contact
    @mergee_contact = mergee_contact
    @account_id = base_contact.account_id
  end

  def perform
    return unless table_exists?('communication_threads')

    now = Time.current
    base_thread = CommunicationThread.find_by(account_id: account_id, contact_id: base_contact.id)
    mergee_threads = CommunicationThread.where(account_id: account_id, contact_id: mergee_contact.id).order(:id).to_a
    return if mergee_threads.empty?

    if base_thread.blank?
      base_thread = mergee_threads.shift
      CommunicationThread.where(id: base_thread.id).update_all(contact_id: base_contact.id, updated_at: now) # rubocop:disable Rails/SkipsModelValidations
    end

    mergee_threads.each do |mergee_thread|
      consolidate_thread!(base_thread: base_thread, mergee_thread: mergee_thread, now: now)
    end
  end

  private

  attr_reader :base_contact, :mergee_contact, :account_id

  def consolidate_thread!(base_thread:, mergee_thread:, now:)
    move_thread_conversations!(base_thread: base_thread, mergee_thread: mergee_thread, now: now)
    move_thread_references!(base_thread: base_thread, mergee_thread: mergee_thread, now: now)
    merge_thread_counters!(base_thread: base_thread, mergee_thread: mergee_thread, now: now)
    CommunicationThread.where(id: mergee_thread.id).delete_all
  end

  # rubocop:disable Rails/SkipsModelValidations
  def move_thread_conversations!(base_thread:, mergee_thread:, now:)
    return unless table_exists?('communication_thread_conversations')

    existing_conv_ids = CommunicationThreadConversation.where(communication_thread_id: base_thread.id).select(:conversation_id)
    CommunicationThreadConversation.where(communication_thread_id: mergee_thread.id, conversation_id: existing_conv_ids).delete_all

    base_has_primary = CommunicationThreadConversation.exists?(communication_thread_id: base_thread.id, primary: true)
    updates = { communication_thread_id: base_thread.id, updated_at: now }
    updates[:primary] = false if base_has_primary
    CommunicationThreadConversation.where(communication_thread_id: mergee_thread.id).update_all(updates)

    ensure_primary_thread_conversation!(base_thread: base_thread, now: now)
  end

  def ensure_primary_thread_conversation!(base_thread:, now:)
    return if CommunicationThreadConversation.exists?(communication_thread_id: base_thread.id, primary: true)

    first_link_id = CommunicationThreadConversation.where(communication_thread_id: base_thread.id).order(:created_at, :id).pick(:id)
    return if first_link_id.blank?

    CommunicationThreadConversation.where(id: first_link_id).update_all(primary: true, updated_at: now)
  end

  def move_thread_references!(base_thread:, mergee_thread:, now:)
    if table_exists?('crm_deals')
      Crm::Deal.where(originating_communication_thread_id: mergee_thread.id)
               .update_all(originating_communication_thread_id: base_thread.id, updated_at: now)
    end
    if table_exists?('meta_ad_referrals')
      MetaAdReferral.where(communication_thread_id: mergee_thread.id)
                    .update_all(communication_thread_id: base_thread.id, updated_at: now)
    end
    return unless table_exists?('reminders')

    Reminder.where(account_id: account_id, remindable_type: 'CommunicationThread', remindable_id: mergee_thread.id)
            .update_all(remindable_id: base_thread.id, updated_at: now)
  end

  def merge_thread_counters!(base_thread:, mergee_thread:, now:)
    latest_activity = [base_thread.last_activity_at, mergee_thread.last_activity_at].compact.max
    total_unread = base_thread.unread_count.to_i + mergee_thread.unread_count.to_i
    CommunicationThread.where(id: base_thread.id).update_all(
      last_activity_at: latest_activity,
      unread_count: total_unread,
      updated_at: now
    )
    base_thread.assign_attributes(last_activity_at: latest_activity, unread_count: total_unread, updated_at: now)
  end
  # rubocop:enable Rails/SkipsModelValidations

  def table_exists?(table)
    ActiveRecord::Base.connection.data_source_exists?(table)
  end
end
