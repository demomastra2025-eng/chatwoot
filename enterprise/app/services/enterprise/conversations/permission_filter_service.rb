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
    return base_scope if permissions.include?('conversation_manage')

    limited_permissions = permissions & %w[
      conversation_unassigned_manage
      conversation_participating_manage
      conversation_team_manage
    ]
    return Conversation.none if limited_permissions.empty?

    scopes = [base_scope.assigned_to(user)]
    scopes << base_scope.unassigned if permissions.include?('conversation_unassigned_manage')
    scopes << participating_scope(base_scope) if permissions.include?('conversation_participating_manage')
    scopes << team_scope(base_scope) if permissions.include?('conversation_team_manage')

    Conversation.from("(#{scopes.map(&:to_sql).join(' UNION ')}) as conversations")
                .where(account_id: account.id)
  end

  def participating_scope(base_scope)
    base_scope
      .joins(:conversation_participants)
      .where(conversation_participants: { user_id: user.id })
  end

  def team_scope(base_scope)
    base_scope.where(team_id: user.teams.where(account_id: account.id).select(:id))
  end
end
