class Scheduling::Appointments::AssignmentAuthorizer
  def self.call(account:, actor:, appointment:, capability: 'assign')
    new(account: account, actor: actor, appointment: appointment, capability: capability).call
  end

  def initialize(account:, actor:, appointment:, capability:)
    @account = account
    @actor = actor
    @appointment = appointment
    @capability = capability
  end

  def call
    return unless dashboard_actor?

    account_user = account_user!

    mode_resolution = AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: 'appointments',
      capability: capability
    )
    return unless mode_resolution.authoritative_source == 'access_role'

    access_scope = mode_resolution.access_role_resolution&.scope || 'none'
    deny! unless assignment_allowed?(access_scope)
  end

  private

  attr_reader :account, :actor, :appointment, :capability

  def dashboard_actor?
    actor.is_a?(User)
  end

  def account_user!
    account.account_users.find_by(user_id: actor.id) || deny!
  end

  def assignment_allowed?(access_scope)
    return true if access_scope == 'all'
    return false unless %w[own team].include?(access_scope)
    return false unless target_owner_allowed?(access_scope)
    return true if own_appointment?

    access_scope == 'team' && appointment.team_id.present? && actor_team_ids.include?(appointment.team_id)
  end

  def target_owner_allowed?(access_scope)
    return true if appointment.owner_id.blank? || appointment.owner_id == actor.id
    return false if access_scope == 'own'

    TeamMember.joins(:team).exists?(
      user_id: appointment.owner_id,
      team_id: actor_team_ids,
      teams: { account_id: account.id }
    )
  end

  def own_appointment?
    appointment.contact&.owner_id == actor.id || appointment.resource&.user_id == actor.id
  end

  def actor_team_ids
    @actor_team_ids ||= TeamMember.joins(:team)
                                  .where(user_id: actor.id, teams: { account_id: account.id })
                                  .pluck(:team_id)
  end

  def deny!
    raise Pundit::NotAuthorizedError, "not allowed to #{capability} this appointment"
  end
end
