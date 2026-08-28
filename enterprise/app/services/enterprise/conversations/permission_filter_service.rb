module Enterprise::Conversations::PermissionFilterService
  def perform
    return filter_by_permissions(permissions) if user_has_custom_role?

    super
  end

  def perform_operational
    return filter_by_permissions(permissions, operational_conversations) if user_has_custom_role?

    super
  end

  private

  def user_has_custom_role?
    user_role == 'agent' && account_user&.custom_role_id.present?
  end

  def permissions
    account_user&.permissions || []
  end

  def filter_by_permissions(permissions, base_scope = accessible_conversations)
    # Permission-based filtering with hierarchy
    # conversation_manage > conversation_unassigned_manage > conversation_participating_manage
    if permissions.include?('conversation_manage')
      base_scope
    elsif permissions.include?('conversation_unassigned_manage')
      filter_unassigned_and_mine(base_scope)
    elsif permissions.include?('conversation_participating_manage')
      filter_participating_and_mine(base_scope)
    else
      Conversation.none
    end
  end

  def filter_unassigned_and_mine(base_scope)
    mine = base_scope.assigned_to(user)
    unassigned = base_scope.unassigned

    Conversation.from("(#{mine.to_sql} UNION #{unassigned.to_sql}) as conversations")
                .where(account_id: account.id)
  end

  def filter_participating_and_mine(base_scope)
    mine = base_scope.assigned_to(user)
    participating = base_scope
                    .joins(:conversation_participants)
                    .where(conversation_participants: { user_id: user.id })

    Conversation.from("(#{mine.to_sql} UNION #{participating.to_sql}) as conversations")
                .where(account_id: account.id)
  end
end
