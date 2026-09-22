class Telephony::LogicalCallOccurrencePolicy < ApplicationPolicy
  RESOURCE = 'telephony_calls'.freeze

  class Scope < ApplicationPolicy::Scope
    def initialize(user_context, scope, capabilities: %w[view view_reports])
      super(user_context, scope)
      @capabilities = Array(capabilities).map(&:to_s)
    end

    def resolve
      account_scope = account.present? ? scope.where(account_id: account.id) : scope.none
      return account_scope.none if account_user.blank?

      effective_scope = capabilities.reduce(account_scope) do |relation, capability|
        relation.merge(scope_for(account_scope, capability))
      end
      restrict_to_visible_voice_inboxes(effective_scope)
    end

    def self.intersection(user_context, relation, capabilities:)
      new(user_context, relation, capabilities: capabilities).resolve
    end

    def self.apply(relation, access_scope:, user:, account:)
      return relation if access_scope == 'all'
      return relation.none unless %w[own team].include?(access_scope)

      own_scope = relation.where(actor_kind: 'human', actor_id_snapshot: user.id)
      return own_scope if access_scope == 'own'

      team_ids = TeamMember.joins(:team)
                           .where(user_id: user.id, teams: { account_id: account.id })
                           .select(:team_id)
      own_scope.or(relation.where(actor_kind: 'human', actor_team_id_snapshot: team_ids))
    end

    private

    attr_reader :capabilities

    def scope_for(account_scope, capability)
      resolution = AccessControl::ModeResolver.call(
        account_user: account_user,
        resource: RESOURCE,
        capability: capability
      )
      instrument_shadow_scope(resolution)
      return account_scope if resolution.authoritative_source != 'access_role'

      self.class.apply(
        account_scope,
        access_scope: resolution.access_role_resolution&.scope || 'none',
        user: user,
        account: account
      )
    end

    def restrict_to_visible_voice_inboxes(relation)
      visible_ids = InboxPolicy::Scope.new(user_context, account.inboxes).resolve
                                      .where(channel_type: 'Channel::Voice')
                                      .select(:id)
      relation.where(inbox_id_snapshot: visible_ids)
    end

    def instrument_shadow_scope(resolution)
      return unless resolution.mode == 'shadow'

      AccessControl::ModeAwareDecision.instrument_shadow_scope(mode_resolution: resolution, legacy_scope: 'all')
    end
  end

  def view_reports?
    capability_allowed?('view') && capability_allowed?('view_reports')
  end

  private

  def capability_allowed?(capability)
    return false if account_user.blank?

    resolution = AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: RESOURCE,
      capability: capability
    )
    legacy_allowed = capability == 'view' ? account_user.present? : administrator_access? || has_permission?('report_manage')
    access_scope = resolution.access_role_resolution&.scope || 'none'

    AccessControl::ModeAwareDecision.call(
      mode_resolution: resolution,
      legacy_allowed: legacy_allowed,
      access_role_allowed: access_scope != 'none'
    )
  end
end
