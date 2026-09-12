class Crm::DealPolicy < Crm::BasePolicy
  def self.legacy_view_allowed?(account_user)
    return false if account_user.blank?

    permissions = Array(account_user.permissions)
    permissions.include?('administrator') ||
      (account_user.custom_role_id.blank? && permissions.include?('agent')) ||
      (permissions & %w[crm_deal_view crm_deal_manage]).any?
  end

  class Scope < Crm::BasePolicy::Scope
    ACCESS_SCOPE_PRIORITY = { 'none' => 0, 'own' => 1, 'team' => 2, 'all' => 3 }.freeze

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

    def self.intersection(user_context, relation, capabilities:)
      Array(capabilities).reduce(relation) do |effective_scope, capability|
        capability_scope = new(user_context, relation, capability: capability.to_s).resolve
        effective_scope.where(id: capability_scope.select(:id))
      end
    end

    def self.intersection_access_scope(user_context, capabilities:)
      account_user = user_context[:account_user]
      return 'none' if account_user.blank?

      resolutions = Array(capabilities).map do |capability|
        AccessControl::ModeResolver.call(
          account_user: account_user,
          resource: 'deals',
          capability: capability.to_s
        )
      end
      return 'all' unless resolutions.all? { |resolution| resolution.authoritative_source == 'access_role' }

      resolutions.map { |resolution| resolution.access_role_resolution&.scope || 'none' }
                 .min_by { |scope| ACCESS_SCOPE_PRIORITY.fetch(scope) }
    end

    def self.owner_ids(user_context, access_scope:)
      account = user_context[:account]
      user = user_context[:user]
      return [] if account.blank? || user.blank?

      case access_scope
      when 'all'
        account.account_users.pluck(:user_id)
      when 'team'
        team_ids = account.teams.joins(:team_members).where(team_members: { user_id: user.id }).select(:id)
        (TeamMember.where(team_id: team_ids).pluck(:user_id) + [user.id]).uniq
      when 'own'
        [user.id]
      else
        []
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

  def view_reports?
    deal_access?(:view_reports, record_scoped: false)
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
    return self.class.legacy_view_allowed?(account_user) if capability == :view
    return administrator_access? || has_permission?('report_manage') if capability == :view_reports

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
