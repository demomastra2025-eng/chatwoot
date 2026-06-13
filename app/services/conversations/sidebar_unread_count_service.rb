class Conversations::SidebarUnreadCountService
  attr_reader :account, :user

  def initialize(account:, user:)
    @account = account
    @user = user
  end

  def perform
    unread_scope = unread_message_scope

    {
      all: unread_dialog_count(unread_scope),
      statuses: normalize_enum_counts(unread_scope.group(:status).distinct.count('conversations.id'), Conversation.statuses),
      inboxes: normalize_counts(unread_scope.group(:inbox_id).distinct.count('conversations.id')),
      teams: normalize_counts(unread_scope.where.not(team_id: nil).group(:team_id).distinct.count('conversations.id')),
      labels: normalize_counts(label_counts(unread_scope))
    }
  end

  private

  def accessible_conversations
    Conversations::PermissionFilterService.new(
      account.conversations,
      user,
      account
    ).perform
  end

  def unread_message_scope
    accessible_conversations.joins(:messages)
                            .where(messages: unread_message_filters)
                            .where(
                              'messages.created_at > COALESCE(conversations.agent_last_seen_at, ?)',
                              Time.zone.at(0)
                            )
  end

  def unread_message_filters
    {
      account_id: account.id,
      message_type: Message.message_types[:incoming],
      private: false
    }
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
