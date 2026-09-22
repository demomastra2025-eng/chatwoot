class CommunicationThreadPolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    def initialize(user_context, scope, capability: 'view', owner_only: false)
      super(user_context, scope)
      @capability = capability
      @owner_only = owner_only
    end

    def resolve
      account_scope = scope.where(account_id: account&.id)
      return account_scope.none if account_user.blank?

      mode_resolution = access_mode_resolution
      instrument_shadow_scope(mode_resolution)
      return account_scope if mode_resolution.authoritative_source != 'access_role'

      role_scope = role_scope_for(account_scope, mode_resolution)
      return role_scope unless capability == 'view' && !owner_only

      role_scope.or(participant_scope(account_scope))
    end

    def self.intersection(user_context, relation, capabilities:)
      Array(capabilities).reduce(relation) do |effective_scope, capability|
        capability_scope = new(
          user_context,
          relation,
          capability: capability.to_s,
          owner_only: true
        ).resolve
        effective_scope.where(id: capability_scope.select(:id))
      end
    end

    def self.apply(account_scope, access_scope:, user:, account:)
      case access_scope
      when 'all'
        account_scope
      when 'team'
        team_ids = TeamMember.joins(:team)
                             .where(user_id: user.id, teams: { account_id: account.id })
                             .select(:team_id)
        account_scope.where(assignee_id: user.id)
                     .or(account_scope.where(team_id: team_ids))
      when 'own'
        account_scope.where(assignee_id: user.id)
      else
        account_scope.none
      end
    end

    private

    attr_reader :capability, :owner_only

    def access_mode_resolution
      AccessControl::ModeResolver.call(account_user: account_user, resource: 'conversations', capability: capability)
    end

    def instrument_shadow_scope(mode_resolution)
      return unless mode_resolution.mode == 'shadow'

      AccessControl::ModeAwareDecision.instrument_shadow_scope(mode_resolution: mode_resolution, legacy_scope: 'all')
    end

    def role_scope_for(account_scope, mode_resolution)
      self.class.apply(
        account_scope,
        access_scope: mode_resolution.access_role_resolution&.scope || 'none',
        user: user,
        account: account
      )
    end

    def participant_scope(account_scope)
      participant_ids = CommunicationThreadParticipant
                        .where(account_id: account.id, user_id: user.id)
                        .select(:communication_thread_id)
      account_scope.where(id: participant_ids)
    end
  end

  def show?
    snapshot = user_context[:thread_access_snapshot]
    return snapshot[:participant] || capability_allowed?('view') if snapshot

    scope.exists?(id: record.id)
  end

  def reply?
    show?
  end

  def view_reports?
    capability_allowed?('view_reports', record_scoped: false)
  end

  def update?
    capability_allowed?('update_fields')
  end

  def assign?
    capability_allowed?('assign')
  end

  def transition?
    capability_allowed?('transition')
  end

  def destroy?
    capability_allowed?('delete_archive')
  end

  def manage_participants?
    record.assignee_id == user.id || participants_management_allowed?
  end

  def leave?
    participant?
  end

  private

  def participant?
    snapshot = user_context[:thread_access_snapshot]
    return snapshot[:participant] if snapshot

    record.communication_thread_participants.exists?(user_id: user.id)
  end

  def capability_allowed?(capability, record_scoped: true)
    return false if account_user.blank?

    mode_resolution = mode_resolution_for(capability)
    legacy_allowed = legacy_capability_allowed?(capability)
    access_role_allowed = access_role_allows?(mode_resolution, record_scoped: record_scoped)

    AccessControl::ModeAwareDecision.call(
      mode_resolution: mode_resolution,
      legacy_allowed: legacy_allowed,
      access_role_allowed: access_role_allowed
    )
  end

  def legacy_capability_allowed?(capability)
    return administrator_access? || has_permission?('report_manage') if capability == 'view_reports'

    administrator_access? || plain_agent_access? || has_permission?('conversation_manage')
  end

  def participants_management_allowed?
    return false if account_user.blank?

    mode_resolution = mode_resolution_for('assign')

    AccessControl::ModeAwareDecision.call(
      mode_resolution: mode_resolution,
      legacy_allowed: administrator_access? || has_permission?('conversation_manage'),
      access_role_allowed: access_role_allows?(mode_resolution)
    )
  end

  def access_role_allows?(mode_resolution, record_scoped: true)
    access_scope = mode_resolution.access_role_resolution&.scope || 'none'
    return access_scope != 'none' unless record_scoped

    snapshot = user_context[:thread_access_snapshot]
    return snapshot_scope_allows?(access_scope, snapshot) if snapshot

    Scope.apply(
      CommunicationThread.where(account_id: account.id),
      access_scope: access_scope,
      user: user,
      account: account
    ).exists?(id: record.id)
  end

  def mode_resolution_for(capability)
    user_context.dig(:thread_access_snapshot, :mode_resolutions, capability) || AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: 'conversations',
      capability: capability
    )
  end

  def snapshot_scope_allows?(access_scope, snapshot)
    case access_scope
    when 'all' then true
    when 'own' then record.assignee_id == user.id
    when 'team' then record.assignee_id == user.id || (record.team_id.present? && snapshot[:team_ids].include?(record.team_id))
    else false
    end
  end
end
