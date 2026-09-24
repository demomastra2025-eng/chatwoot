class Scheduling::AppointmentPolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    def initialize(user_context, scope, capability: 'view')
      super(user_context, scope)
      @capability = capability
    end

    def resolve
      account_scope = account.present? ? scope.where(account_id: account.id) : scope.none
      return missing_account_user_scope(account_scope) if account_user.blank?

      mode_resolution = AccessControl::ModeResolver.call(
        account_user: account_user,
        resource: 'appointments',
        capability: capability
      )
      instrument_shadow_scope(mode_resolution)
      return account_scope unless mode_resolution.authoritative_source == 'access_role'

      self.class.apply(
        account_scope,
        access_scope: mode_resolution.access_role_resolution&.scope || 'none',
        user: user,
        account: account
      )
    end

    def self.apply(relation, access_scope:, user:, account:)
      return relation if access_scope == 'all'
      return relation.none unless %w[own team].include?(access_scope)

      contact_ids = account.contacts.where(owner_id: user.id).select(:id)
      resource_ids = account.scheduling_resources.where(user_id: user.id).select(:id)
      own_scope = relation.where(contact_id: contact_ids).or(relation.where(resource_id: resource_ids))
      return own_scope if access_scope == 'own'

      team_ids = TeamMember.joins(:team)
                           .where(user_id: user.id, teams: { account_id: account.id })
                           .distinct
                           .pluck(:team_id)
                           .sort
      own_scope.or(relation.where(team_id: team_ids))
    end

    def self.intersection(user_context, relation, capabilities:)
      Array(capabilities).reduce(relation) do |effective_scope, capability|
        capability_scope = new(user_context, relation, capability: capability.to_s).resolve
        effective_scope.where(id: capability_scope.select(:id))
      end
    end

    private

    attr_reader :capability

    def missing_account_user_scope(account_scope)
      return account_scope if account.blank?

      AccessControl::ModeResolver.mode_for_account(account.id) == 'enforced' ? account_scope.none : account_scope
    end

    def instrument_shadow_scope(mode_resolution)
      return unless mode_resolution.mode == 'shadow'

      AccessControl::ModeAwareDecision.instrument_shadow_scope(mode_resolution: mode_resolution, legacy_scope: 'all')
    end
  end

  def index?
    appointment_access?(:view, record_scoped: false)
  end

  def show?
    appointment_access?(:view)
  end

  def create?
    appointment_access?(:create, record_scoped: false)
  end

  def update?
    appointment_access?(:update_fields)
  end

  def assign?
    appointment_access?(:assign, record_scoped: record != Scheduling::Appointment)
  end

  def transition?
    appointment_access?(:transition, record_scoped: record != Scheduling::Appointment)
  end

  def destroy?
    appointment_access?(:delete_archive)
  end

  def create_conversation?
    appointment_access?(:update_fields)
  end


  def view_reports?
    appointment_access?(:view_reports, record_scoped: false)
  end

  def override_schedule?
    appointment_access?(:override_schedule, record_scoped: record != Scheduling::Appointment)
  end

  private

  def appointment_access?(capability, record_scoped: true, legacy_allowed: nil)
    legacy_allowed = legacy_appointment_access?(capability) if legacy_allowed.nil?
    return legacy_allowed if account_user.blank?

    mode_resolution = appointment_mode_resolution(capability)
    access_scope = mode_resolution.access_role_resolution&.scope || 'none'
    access_role_allowed = appointment_scope_allows?(access_scope, record_scoped: record_scoped)
    AccessControl::ModeAwareDecision.call(
      mode_resolution: mode_resolution,
      legacy_allowed: legacy_allowed,
      access_role_allowed: access_role_allowed
    )
  end

  def appointment_mode_resolution(capability)
    AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: 'appointments',
      capability: capability.to_s
    )
  end

  def appointment_scope_allows?(access_scope, record_scoped:)
    return access_scope != 'none' unless record_scoped

    Scope.apply(
      account.scheduling_appointments,
      access_scope: access_scope,
      user: user,
      account: account
    ).exists?(id: record.id)
  end

  def legacy_appointment_access?(capability)
    return administrator_access? || has_permission?('scheduling_override') if capability == :override_schedule
    return administrator_access? || has_permission?('report_manage') if capability == :view_reports


    account_user.present?
  end
end
