class Crm::DealPolicy < Crm::BasePolicy
  class Scope < Crm::BasePolicy::Scope
    def initialize(user_context, scope, capability: 'view')
      super(user_context, scope)
      @capability = capability
    end

    def resolve
      account_scope = super
      return missing_account_user_scope(account_scope) if account_user.blank?

      mode_resolution = AccessControl::ModeResolver.call(
        account_user: account_user,
        resource: 'deals',
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
      case access_scope
      when 'all'
        relation
      when 'team'
        team_ids = TeamMember.joins(:team).where(user_id: user.id, teams: { account_id: account.id }).select(:team_id)
        relation.where(owner_id: user.id).or(relation.where(team_id: team_ids))
      when 'own'
        relation.where(owner_id: user.id)
      else
        relation.none
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
    deal_access?(:view, record_scoped: false)
  end

  def show?
    deal_access?(:view)
  end

  def timeline?
    deal_access?(:view)
  end

  def create?
    deal_access?(:create, record_scoped: false)
  end

  def update?
    deal_access?(:update_fields)
  end

  def assign?
    deal_access?(:assign, record_scoped: record != ::Crm::Deal)
  end

  def transition_stage?
    deal_access?(:transition)
  end

  def archive?
    deal_access?(:delete_archive)
  end

  def unarchive?
    deal_access?(:delete_archive)
  end

  private

  def deal_access?(capability, record_scoped: true)
    legacy_allowed = legacy_deal_access?(capability)
    return legacy_allowed if account_user.blank?

    mode_resolution = deal_mode_resolution(capability)
    access_role_allowed = access_role_allows?(mode_resolution, record_scoped: record_scoped)
    AccessControl::ModeAwareDecision.call(
      mode_resolution: mode_resolution,
      legacy_allowed: legacy_allowed,
      access_role_allowed: access_role_allowed
    )
  end

  def legacy_deal_access?(capability)
    return deal_view_access? if capability == :view

    deal_manage_access?
  end

  def deal_mode_resolution(capability)
    @deal_mode_resolutions ||= {}
    @deal_mode_resolutions[capability] ||= AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: 'deals',
      capability: capability.to_s
    )
  end

  def access_role_allows?(mode_resolution, record_scoped:)
    access_scope = mode_resolution.access_role_resolution&.scope || 'none'
    return access_scope != 'none' unless record_scoped

    Scope.apply(
      account.crm_deals,
      access_scope: access_scope,
      user: user,
      account: account
    ).exists?(id: record.id)
  end
end
