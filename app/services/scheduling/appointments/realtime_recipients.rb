class Scheduling::Appointments::RealtimeRecipients
  def initialize(account:, appointment:, changes: {})
    @account = account
    @appointment = appointment
    @changes = changes.to_h.with_indifferent_access
  end

  def tokens
    return ["account_#{account.id}"] unless enforced?

    account.account_users.includes(:user).filter_map do |account_user|
      account_user.user&.pubsub_token if visible_for_scope?(account_user.user, grants_by_role_id[account_user.access_role_id])
    end.uniq
  end

  private

  attr_reader :account, :appointment, :changes

  def enforced?
    AccessControl::ModeResolver.mode_for_account(account.id) == 'enforced'
  end

  def grants_by_role_id
    @grants_by_role_id ||= AccessRoleGrant.where(
      account_id: account.id,
      resource: 'appointments',
      capability: 'view'
    ).pluck(:access_role_id, :access_scope).to_h
  end

  def visible_for_scope?(user, access_scope)
    case access_scope
    when 'all'
      true
    when 'team'
      own_user_ids.include?(user.id) || team_user_ids.include?(user.id)
    when 'own'
      own_user_ids.include?(user.id)
    else
      false
    end
  end

  def own_user_ids
    @own_user_ids ||= (contact_owner_ids + resource_user_ids).uniq
  end

  def contact_owner_ids
    Contact.where(account_id: account.id, id: boundary_ids('contact_id', appointment.contact_id)).where.not(owner_id: nil).pluck(:owner_id)
  end

  def resource_user_ids
    Scheduling::Resource.where(account_id: account.id, id: boundary_ids('resource_id', appointment.resource_id))
                        .where.not(user_id: nil)
                        .pluck(:user_id)
  end

  def team_user_ids
    TeamMember.joins(:team).where(team_id: team_ids, teams: { account_id: account.id }).distinct.pluck(:user_id)
  end

  def team_ids
    @team_ids ||= boundary_ids('team_id', appointment.team_id)
  end

  def boundary_ids(key, current_id)
    values = changes[key].presence || [current_id]
    Array(values).compact.map(&:to_i).uniq
  end
end
