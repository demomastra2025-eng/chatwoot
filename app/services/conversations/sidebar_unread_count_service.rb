class Conversations::SidebarUnreadCountService
  attr_reader :account, :user

  def initialize(account:, user:)
    @account = account
    @user = user
  end

  def perform
    unread_scope = unread_message_scope
    crm_count_service = crm_unread_count_service(unread_scope)
    appointment_counter = appointment_count_service(unread_scope)

    unread_sidebar_counts(unread_scope).merge(
      pipelines: crm_count_service.conversation_pipeline_counts,
      stages: crm_count_service.conversation_stage_counts,
      appointment_statuses: appointment_counter.conversation_status_counts
    )
  end

  private

  def unread_sidebar_counts(scope)
    {
      all: unread_dialog_count(scope),
      statuses: normalize_enum_counts(scope.group(:status).distinct.count('conversations.id'), Conversation.statuses),
      inboxes: normalize_counts(scope.group(:inbox_id).distinct.count('conversations.id')),
      teams: normalize_counts(scope.where.not(team_id: nil).group(:team_id).distinct.count('conversations.id')),
      labels: normalize_counts(label_counts(scope))
    }
  end

  def crm_unread_count_service(scope)
    Crm::DealDialogUnreadCountService.new(
      account: account,
      conversation_scope: scope
    )
  end

  def appointment_count_service(scope)
    Scheduling::AppointmentDialogCountService.new(
      account: account,
      conversation_scope: scope
    )
  end

  def accessible_conversations
    Conversations::PermissionFilterService.new(
      account.conversations,
      user,
      account
    ).perform
  end

  def unread_message_scope
    Conversations::UnreadScopeBuilder.new(scope: accessible_conversations, account: account, user: user).perform
  end

  def label_counts(scope)
    scope.joins(
      'INNER JOIN taggings ON taggings.taggable_id = conversations.id ' \
      "AND taggings.taggable_type = 'Conversation' " \
      "AND taggings.context = 'labels'"
    ).joins('INNER JOIN tags ON tags.id = taggings.tag_id')
         .group('tags.name')
         .distinct
         .count('conversations.id')
  end

  def unread_dialog_count(scope)
    scope.distinct.count('conversations.id')
  end

  def normalize_counts(counts)
    counts.each_with_object({}) do |(key, value), result|
      next if key.blank?

      result[key.to_s] = value
    end
  end

  def normalize_enum_counts(counts, enum_mapping)
    counts.each_with_object({}) do |(key, value), result|
      enum_key = enum_mapping.key(key) || key.to_s
      next if enum_key.blank?

      result[enum_key] = value
    end
  end
end
