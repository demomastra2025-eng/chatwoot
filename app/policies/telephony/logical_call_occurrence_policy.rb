class Telephony::LogicalCallOccurrencePolicy < ApplicationPolicy
  RESOURCE = 'telephony_calls'.freeze

  def self.rbac_supported?(capability)
    AccessRoleGrant::RESOURCE_CAPABILITIES.fetch(RESOURCE, []).include?(capability)
  end

  class Scope < ApplicationPolicy::Scope
    def initialize(user_context, scope, capabilities: %w[view view_reports])
      super(user_context, scope)
      @capabilities = Array(capabilities).map(&:to_s)
    end

    def resolve(as_of: Time.current)
      account_scope = account.present? ? scope.where(account_id: account.id) : scope.none
      return account_scope.none if account_user.blank?

      effective_scope = capabilities.reduce(account_scope) do |relation, capability|
        relation.merge(scope_for(account_scope, capability))
      end
      restrict_to_visible_voice_inboxes(effective_scope, as_of: as_of)
    end

    def self.intersection(user_context, relation, capabilities:, as_of: Time.current)
      new(user_context, relation, capabilities: capabilities).resolve(as_of: as_of)
    end

    # Choose the current immutable same-call link first, then apply Voice visibility to that inbox.
    def effective_inbox_sql(as_of:)
      table = 'telephony_logical_call_occurrences'
      cutoff = ActiveRecord::Base.connection.quote(as_of)
      <<~SQL.squish
        COALESCE(#{table}.inbox_id_snapshot, (
          SELECT linked.inbox_id_snapshot FROM telephony_logical_call_occurrences linked
          WHERE linked.account_id = #{table}.account_id
            AND linked.logical_call_identity = #{table}.logical_call_identity
            AND linked.source_version = #{table}.source_version
            AND linked.occurrence_kind IN ('connected', 'terminal')
            AND linked.created_at <= #{cutoff}
            AND NOT EXISTS (
              SELECT 1 FROM telephony_logical_call_occurrences successor
              WHERE successor.supersedes_occurrence_id = linked.id
                AND successor.created_at <= #{cutoff}
            )
          ORDER BY linked.created_at DESC, linked.id DESC LIMIT 1
        ))
      SQL
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
      unless Telephony::LogicalCallOccurrencePolicy.rbac_supported?(capability)
        # The telephony grant contract is not registered yet. Never query an unsupported RBAC resource.
        return account_scope if AccessControl::ModeResolver.mode_for_account(account_user.account_id) == 'legacy'

        return account_scope.none
      end

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

    def restrict_to_visible_voice_inboxes(relation, as_of:)
      captured = relation.where(inbox_id_snapshot: visible_voice_inboxes)
      late_linked = relation.where(<<~SQL.squish)
        telephony_logical_call_occurrences.occurrence_kind = 'attempted'
        AND telephony_logical_call_occurrences.inbox_id_snapshot IS NULL
        AND #{effective_inbox_sql(as_of: as_of)} IN (#{visible_voice_inboxes.to_sql})
      SQL
      captured.or(late_linked)
    end

    def visible_voice_inboxes
      @visible_voice_inboxes ||= begin
        allowed = InboxPolicy::Scope.new(user_context, account.inboxes).resolve
        allowed.where(channel_type: 'Channel::Voice').select(:id)
      end
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
    return legacy_unsupported_capability_allowed?(capability) unless self.class.rbac_supported?(capability)

    resolution = AccessControl::ModeResolver.call(
      account_user: account_user,
      resource: RESOURCE,
      capability: capability
    )
    access_scope = resolution.access_role_resolution&.scope || 'none'

    AccessControl::ModeAwareDecision.call(
      mode_resolution: resolution,
      legacy_allowed: legacy_capability_allowed?(capability),
      access_role_allowed: access_scope != 'none'
    )
  end

  def legacy_unsupported_capability_allowed?(capability)
    return false unless AccessControl::ModeResolver.mode_for_account(account_user.account_id) == 'legacy'

    legacy_capability_allowed?(capability)
  end

  def legacy_capability_allowed?(capability)
    capability == 'view' || administrator_access? || has_permission?('report_manage')
  end
end
