class ContactPolicy < ApplicationPolicy
  VIEW_ACTIONS = %i[index active search filter show contactable_inboxes].freeze

  class Scope < ApplicationPolicy::Scope
    def initialize(user_context, scope, capability: 'view')
      super(user_context, scope)
      @capability = capability
    end

    def resolve
      account_scope = scope.where(account_id: account&.id)
      return account_scope.none if account_user.blank?

      mode_resolution = access_mode_resolution
      return account_scope if mode_resolution.authoritative_source != 'access_role'

      role_scope = role_scope_for(account_scope, mode_resolution)
      return role_scope unless capability == 'view'

      role_scope.or(participant_scope(account_scope))
    end

    def self.apply(account_scope, access_scope:, user:, account:)
      case access_scope
      when 'all'
        account_scope
      when 'team'
        team_ids = TeamMember.joins(:team)
                             .where(user_id: user.id, teams: { account_id: account.id })
                             .select(:team_id)
        team_contact_ids = CommunicationThread.where(account_id: account.id, team_id: team_ids).select(:contact_id)
        account_scope.where(owner_id: user.id).or(account_scope.where(id: team_contact_ids))
      when 'own'
        account_scope.where(owner_id: user.id)
      else
        account_scope.none
      end
    end

    private

    attr_reader :capability

    def access_mode_resolution
      AccessControl::ModeResolver.call(account_user: account_user, resource: 'contacts', capability: capability)
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
      participant_ids = CommunicationThread.joins(:communication_thread_participants).where(
        account_id: account.id,
        communication_thread_participants: { user_id: user.id }
      ).select(:contact_id)
      account_scope.where(id: participant_ids)
    end
  end

  VIEW_ACTIONS.each do |action|
    define_method("#{action}?") { contact_access?(:view, record_scoped: %i[index active search filter].exclude?(action)) }
  end

  def import?
    contact_access?(:create, record_scoped: false, legacy_capability: :import)
  end

  def export?
    contact_access?(:export, record_scoped: false)
  end

  def create?
    contact_access?(:create, record_scoped: false)
  end

  def update?
    contact_access?(:update_fields)
  end

  def avatar?
    update?
  end

  def destroy_custom_attributes?
    update?
  end

  def assign?
    contact_access?(:assign, record_scoped: record != Contact)
  end

  def destroy?
    contact_access?(:delete_archive)
  end

  private

  def contact_access?(capability, record_scoped: true, legacy_capability: capability)
    legacy_allowed = legacy_contact_access?(legacy_capability)
    return legacy_allowed if account_user.blank?

    mode_resolution = AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: 'contacts',
      capability: capability.to_s
    )
    AccessControl::ModeAwareDecision.call(
      mode_resolution: mode_resolution,
      legacy_allowed: legacy_allowed,
      access_role_allowed: access_role_allowed?(mode_resolution, capability, record_scoped)
    )
  end

  def access_role_allowed?(mode_resolution, capability, record_scoped)
    access_scope = mode_resolution.access_role_resolution&.scope || 'none'
    return contact_view_allowed?(record_scoped) if capability == :view
    return false if access_scope == 'none'
    return true unless record_scoped

    access_role_scope(access_scope).exists?(id: record.id)
  end

  def contact_view_allowed?(record_scoped)
    return true unless record_scoped

    visible_scope = Scope.new(user_context, Contact.where(account_id: account.id)).resolve
    visible_scope.exists?(id: record.id)
  end

  def access_role_scope(access_scope)
    Scope.apply(Contact.where(account_id: account.id), access_scope: access_scope, user: user, account: account)
  end

  def legacy_contact_access?(capability)
    return administrator_access? if %i[import export delete_archive].include?(capability)

    contact_access_legacy?
  end

  def contact_access_legacy?
    administrator_access? || plain_agent_access? || has_permission?('contact_manage')
  end
end
