class Crm::Deals::RealtimeRecipients
  def initialize(account:, deal:, changes: {})
    @account = account
    @deal = deal
    @changes = changes.to_h.with_indifferent_access
  end

  def tokens
    account_users.filter_map do |account_user|
      account_user.user&.pubsub_token if visible?(account_user)
    end.uniq
  end

  private

  attr_reader :account, :deal, :changes

  def account_users
    @account_users ||= account.account_users.includes(:user, :custom_role).to_a
  end

  def visible?(account_user)
    return Crm::DealPolicy.legacy_view_allowed?(account_user) unless enforced?

    visible_in_assignment_scope?(grants_by_role_id[account_user.access_role_id], account_user.user_id)
  end

  def visible_in_assignment_scope?(access_scope, user_id)
    case access_scope || 'none'
    when 'all'
      true
    when 'team'
      owner_ids.include?(user_id) || team_user_ids.include?(user_id)
    when 'own'
      owner_ids.include?(user_id)
    else
      false
    end
  end

  def enforced?
    return @enforced if defined?(@enforced)

    @enforced = AccessControl::ModeResolver.mode_for_account(account.id) == 'enforced'
  end

  def grants_by_role_id
    @grants_by_role_id ||= AccessRoleGrant.where(
      account_id: account.id,
      resource: 'deals',
      capability: 'view'
    ).pluck(:access_role_id, :access_scope).to_h
  end

  def owner_ids
    @owner_ids ||= [deal.owner_id, previous_value('owner_id', deal.owner_id)].compact.uniq
  end

  def team_ids
    @team_ids ||= [deal.team_id, previous_value('team_id', deal.team_id)].compact.uniq
  end

  def team_user_ids
    @team_user_ids ||= TeamMember.where(team_id: team_ids).distinct.pluck(:user_id)
  end

  def previous_value(key, current_value)
    return current_value unless changes.key?(key)

    Array(changes[key]).first
  end
end
