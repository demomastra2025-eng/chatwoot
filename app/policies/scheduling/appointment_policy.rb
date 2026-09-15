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

      scoped = relation.left_joins(:contact, :resource)
      own_sql = 'contacts.owner_id = :user_id OR scheduling_resources.user_id = :user_id'
      return scoped.where(own_sql, user_id: user.id).distinct if access_scope == 'own'

      team_ids = TeamMember.joins(:team).where(user_id: user.id, teams: { account_id: account.id }).pluck(:team_id)
      scoped.where(
        "(#{own_sql}) OR scheduling_appointments.team_id IN (:team_ids)",
        user_id: user.id,
        team_ids: team_ids
      ).distinct
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

  def finance?
    appointment_access?(:update_fields)
  end

  def view_finance?
    appointment_access?(:view_finance, record_scoped: record != Scheduling::Appointment)
  end

  def view_finance_legacy?
    appointment_access?(
      :view_finance,
      record_scoped: record != Scheduling::Appointment,
      legacy_allowed: account_user.present?
    )
  end

  def manage_finance?
    appointment_access?(:manage_finance, record_scoped: record != Scheduling::Appointment)
  end

  def manage_finance_legacy?
    appointment_access?(
      :manage_finance,
      record_scoped: record != Scheduling::Appointment,
      legacy_allowed: account_user.present?
    )
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
    return administrator_access? if %i[view_finance manage_finance].include?(capability)

    account_user.present?
  end
end
