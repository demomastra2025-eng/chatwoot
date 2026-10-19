# frozen_string_literal: true

class Conversations::SingleDialogConsolidator # rubocop:disable Metrics/ClassLength
  SIMPLE_TABLES = %w[
    messages
    assignment_decision_logs
    assignment_quota_usages
    calls
    captain_follow_up_attempts
    confirmation_requests
    conversation_status_transitions
    copilot_threads
    events
    lead_submissions
    llm_events
    meta_ad_referrals
    reporting_events
    scheduling_appointments
    sla_events
    telephony_call_sessions
    whatsapp_flow_sessions
  ].freeze

  ORIGINATING_CONVERSATION_TABLES = %w[
    crm_deals
    crm_tasks
  ].freeze

  def initialize(account_id: nil, contact_id: nil, account: nil, contact: nil, dry_run: false)
    @account_id = account_id || account&.id
    @contact_id = contact_id || contact&.id
    @dry_run = dry_run
  end

  def perform
    stats = { groups_found: 0, groups_consolidated: 0, conversations_removed: 0, duplicate_activities_removed: 0 }
    duplicate_groups.each do |group|
      stats[:groups_found] += 1
      next if @dry_run

      consolidate_group!(group: group, stats: stats)
    end
    stats
  end

  private

  def duplicate_groups
    scope = Conversation.where.not(contact_id: nil)
    scope = scope.where(account_id: @account_id) if @account_id.present?
    scope = scope.where(contact_id: @contact_id) if @contact_id.present?

    scope
      .group(:account_id, :contact_id, :inbox_id)
      .having('COUNT(*) > 1')
      .pluck(:account_id, :contact_id, :inbox_id)
      .map { |acc_id, con_id, inb_id| { account_id: acc_id, contact_id: con_id, inbox_id: inb_id } }
  end

  def consolidate_group!(group:, stats:)
    ActiveRecord::Base.transaction do
      conversations = load_group_conversations(group)
      return if conversations.size <= 1

      canonical = select_canonical(conversations)
      duplicates = conversations.reject { |c| c.id == canonical.id }
      stats[:duplicate_activities_removed] += merge_group_records!(group, canonical, duplicates, conversations.map(&:id))
      stats[:groups_consolidated] += 1
      stats[:conversations_removed] += duplicates.size
    end
  end

  def merge_group_records!(group, canonical, duplicates, all_ids)
    duplicate_ids = duplicates.map(&:id)
    had_primary = thread_group_has_primary?(all_ids)
    removed_activities = remove_duplicate_activity_messages!(all_ids)
    reassign_all_associations!(canonical, duplicates, duplicate_ids)
    merge_canonical_attributes!(canonical, duplicates)
    Conversation.where(id: duplicate_ids).delete_all
    refresh_communication_thread!(group[:account_id], group[:contact_id], canonical, had_primary)
    removed_activities
  end

  def load_group_conversations(group)
    Conversation.where(group).lock.order(:id).to_a
  end

  def thread_group_has_primary?(conversation_ids)
    return false unless defined?(CommunicationThreadConversation)

    CommunicationThreadConversation.exists?(conversation_id: conversation_ids, primary: true)
  end

  def select_canonical(conversations)
    conversations.max_by do |c|
      [c.open? ? 1 : 0, (c.last_activity_at || c.updated_at || c.created_at).to_i, c.id]
    end
  end

  def remove_duplicate_activity_messages!(conversation_ids)
    activities = Message.where(conversation_id: conversation_ids, message_type: :activity).order(:created_at, :id).to_a
    return 0 if activities.size <= 1

    to_delete_ids = find_duplicate_activity_ids(activities)
    Message.where(id: to_delete_ids).delete_all if to_delete_ids.any?
    to_delete_ids.size
  end

  def find_duplicate_activity_ids(activities)
    kept = []
    activities.each_with_object([]) do |msg, to_delete|
      if duplicate_activity?(kept, msg)
        to_delete << msg.id
      else
        kept << msg
      end
    end
  end

  def duplicate_activity?(kept, msg)
    kept.any? do |k|
      k.content.present? &&
        k.content == msg.content &&
        (msg.created_at.to_f - k.created_at.to_f).abs <= 5.0
    end
  end

  def reassign_all_associations!(canonical, duplicates, duplicate_ids)
    reassign_simple_tables!(canonical.id, duplicate_ids)
    reassign_originating_tables!(canonical.id, duplicate_ids)
    reassign_reminders!(canonical.id, duplicate_ids)
    reassign_unique_associations!(canonical.id, duplicate_ids)
    reassign_notifications!(canonical.id, duplicate_ids)
    merge_conversation_labels!(canonical, duplicates)
  end

  def reassign_simple_tables!(canonical_id, duplicate_ids)
    conn = ActiveRecord::Base.connection
    SIMPLE_TABLES.each do |table|
      next unless conn.data_source_exists?(table) && conn.column_exists?(table, :conversation_id)

      conn.execute(
        ActiveRecord::Base.sanitize_sql_array(
          ["UPDATE #{table} SET conversation_id = ? WHERE conversation_id IN (?)", canonical_id, duplicate_ids]
        )
      )
    end
  end

  def reassign_originating_tables!(canonical_id, duplicate_ids)
    conn = ActiveRecord::Base.connection
    ORIGINATING_CONVERSATION_TABLES.each do |table|
      next unless conn.data_source_exists?(table) && conn.column_exists?(table, :originating_conversation_id)

      conn.execute(
        ActiveRecord::Base.sanitize_sql_array(
          ["UPDATE #{table} SET originating_conversation_id = ? WHERE originating_conversation_id IN (?)",
           canonical_id, duplicate_ids]
        )
      )
    end
  end

  def reassign_reminders!(canonical_id, duplicate_ids)
    conn = ActiveRecord::Base.connection
    return unless conn.data_source_exists?('reminders')

    sql = <<~SQL.squish
      UPDATE reminders
      SET
        conversation_id = CASE WHEN conversation_id IN (:dup_ids) THEN :canonical_id ELSE conversation_id END,
        target_conversation_id = CASE WHEN target_conversation_id IN (:dup_ids) THEN :canonical_id ELSE target_conversation_id END,
        remindable_id = CASE WHEN remindable_type = 'Conversation' AND remindable_id IN (:dup_ids) THEN :canonical_id ELSE remindable_id END
      WHERE conversation_id IN (:dup_ids)
         OR target_conversation_id IN (:dup_ids)
         OR (remindable_type = 'Conversation' AND remindable_id IN (:dup_ids))
    SQL
    conn.execute(
      ActiveRecord::Base.sanitize_sql_array([sql, { dup_ids: duplicate_ids, canonical_id: canonical_id }])
    )
  end

  def reassign_unique_associations!(canonical_id, duplicate_ids)
    reassign_user_scoped_model!(ConversationParticipant, canonical_id, duplicate_ids) if defined?(ConversationParticipant)
    reassign_user_scoped_model!(ConversationUserReadState, canonical_id, duplicate_ids) if defined?(ConversationUserReadState)
    reassign_user_scoped_model!(Mention, canonical_id, duplicate_ids) if defined?(Mention)
    reassign_single_row_model!(AppliedSla, canonical_id, duplicate_ids) if defined?(AppliedSla)
    reassign_single_row_model!(CsatSurveyResponse, canonical_id, duplicate_ids) if defined?(CsatSurveyResponse)
    reassign_single_row_model!(CommunicationThreadConversation, canonical_id, duplicate_ids) if defined?(CommunicationThreadConversation)
  end

  def reassign_user_scoped_model!(model_class, canonical_id, duplicate_ids)
    existing_user_ids = model_class.where(conversation_id: canonical_id).pluck(:user_id)
    model_class.where(conversation_id: duplicate_ids, user_id: existing_user_ids).delete_all
    dupe_ids_by_user = model_class.where(conversation_id: duplicate_ids).group(:user_id).minimum(:id).values
    model_class.where(conversation_id: duplicate_ids).where.not(id: dupe_ids_by_user).delete_all
    model_class.where(id: dupe_ids_by_user).update_all(conversation_id: canonical_id) # rubocop:disable Rails/SkipsModelValidations
  end

  def reassign_single_row_model!(model_class, canonical_id, duplicate_ids)
    unless model_class.exists?(conversation_id: canonical_id)
      keep_id = model_class.where(conversation_id: duplicate_ids).order(:id).pick(:id)
      model_class.where(id: keep_id).update_all(conversation_id: canonical_id) if keep_id # rubocop:disable Rails/SkipsModelValidations
    end
    model_class.where(conversation_id: duplicate_ids).delete_all
  end

  def reassign_notifications!(canonical_id, duplicate_ids)
    return unless defined?(Notification)

    Notification.where(primary_actor_type: 'Conversation', primary_actor_id: duplicate_ids)
                .update_all(primary_actor_id: canonical_id) # rubocop:disable Rails/SkipsModelValidations
    Notification.where(secondary_actor_type: 'Conversation', secondary_actor_id: duplicate_ids)
                .update_all(secondary_actor_id: canonical_id) # rubocop:disable Rails/SkipsModelValidations
  end

  def merge_conversation_labels!(canonical, duplicates)
    all_labels = ([canonical] + duplicates).flat_map(&:cached_label_list_array).compact.uniq
    if all_labels.any? && all_labels.sort != canonical.cached_label_list_array.sort
      canonical.skip_activity_messages = true
      canonical.update_labels(all_labels)
    end
    ActsAsTaggableOn::Tagging.where(taggable_type: 'Conversation', taggable_id: duplicates.map(&:id)).delete_all
  ensure
    canonical.skip_activity_messages = false
  end

  def merge_canonical_attributes!(canonical, duplicates)
    canonical.skip_activity_messages = true
    canonical.update_columns(merged_canonical_columns(canonical, duplicates)) # rubocop:disable Rails/SkipsModelValidations
  ensure
    canonical.skip_activity_messages = false
  end

  def merged_canonical_columns(canonical, duplicates)
    all_convs = ([canonical] + duplicates).reverse
    {
      custom_attributes: merged_jsonb_hash(all_convs, :custom_attributes),
      additional_attributes: merged_jsonb_hash(all_convs, :additional_attributes),
      assignee_id: fallback_attr(canonical, duplicates, :assignee_id),
      team_id: fallback_attr(canonical, duplicates, :team_id),
      last_activity_at: latest_conversation_activity_at(canonical),
      updated_at: Time.current
    }
  end

  def merged_jsonb_hash(conversations, attr_name)
    conversations.map { |c| c.public_send(attr_name) || {} }.reduce({}, :merge)
  end

  def fallback_attr(canonical, duplicates, attr_name)
    canonical.public_send(attr_name) || duplicates.reverse.filter_map(&attr_name).first
  end

  def latest_conversation_activity_at(canonical)
    latest_msg_at = Message.where(conversation_id: canonical.id).maximum(:created_at)
    [canonical.last_activity_at, latest_msg_at].compact.max || canonical.updated_at
  end

  def refresh_communication_thread!(account_id, contact_id, canonical, had_primary)
    return unless defined?(CommunicationThread)

    thread = CommunicationThread.find_by(account_id: account_id, contact_id: contact_id)
    return unless thread

    ensure_canonical_thread_link!(thread, canonical, had_primary)
    new_last_activity = [thread.last_activity_at, canonical.last_activity_at].compact.max
    thread.update_columns(last_activity_at: new_last_activity, updated_at: Time.current) if new_last_activity # rubocop:disable Rails/SkipsModelValidations
  end

  def ensure_canonical_thread_link!(thread, canonical, had_primary)
    link = CommunicationThreadConversation.find_by(account_id: thread.account_id, conversation_id: canonical.id)
    if link
      attrs = { contact_inbox_id: canonical.contact_inbox_id }
      attrs[:primary] = true if had_primary && !link.primary?
      link.update_columns(attrs) # rubocop:disable Rails/SkipsModelValidations
      return
    end

    return unless Inbox.exists?(id: canonical.inbox_id, account_id: thread.account_id)

    CommunicationThreadConversation.create!(
      account_id: thread.account_id,
      communication_thread_id: thread.id,
      conversation_id: canonical.id,
      inbox_id: canonical.inbox_id,
      contact_inbox_id: canonical.contact_inbox_id,
      primary: had_primary
    )
  end
end
