# frozen_string_literal: true

# The operator-only implementation of the owner's 02.11.2026 decision. This is
# preparation, never a second runtime reader: activation writes capabilities v1.
class Captain::CapabilityPolicyTransitionPlan
  POLICY = 'preserve_ai_expand_mcp_20261102'
  DECISION = '2026-11-02-company-ai-release-integration#17'
  TOOL_ID = /\A[a-zA-Z0-9_:-]+\z/
  STRICT_POLICY_BLOCKERS = %w[unknown_tool_ids mcp_surface_difference voice_surface_difference canonical_surface_difference].freeze

  def initialize(assistant, actor:)
    @assistant = assistant
    @actor = actor
  end

  def plan
    # Live external discovery cannot be part of a source-only preparation. An
    # installed enabled server needs separately verified catalog evidence.
    Captain::Mcp::ToolCatalog.without_discovery do
      result = manifest
      result.merge(source_digest: digest([context, result]))
    end
  end

  private

  def manifest
    result = { assistant_id: @assistant.id, account_id: @assistant.account_id, actor_id: @actor.id,
               policy: POLICY, decision: DECISION, scopes: {}, quarantined_tool_ids: {}, surface_differences: {} }
    blockers = shape_blockers
    blockers.concat(reference_shape_blockers) if blockers.empty?
    blockers << 'already_canonical' if Captain::Capabilities.configured?(@assistant.config)
    return result.merge(status: 'blocked', blockers: blockers) if blockers.any?

    simulated_manifest(result)
  end

  def simulated_manifest(result)
    inventory = Captain::ToolAccessMigrationPlan.new(@assistant).inventory
    blockers = inventory[:blockers] - STRICT_POLICY_BLOCKERS
    scopes = Captain::ToolAccess::SCOPE_ORDER.index_with do |scope|
      transition_scope(scope, inventory[:scopes].fetch(scope), blockers, result[:quarantined_tool_ids])
    end
    inspected_manifest(result, scopes, blockers)
  end

  def inspected_manifest(result, scopes, blockers)
    simulation = Captain::CapabilitySurfaces.capture(@assistant, scopes)
    blockers.concat(simulation_blockers(simulation))
    validation = validate_candidate(scopes)
    blockers << 'invalid_assistant_metadata' if validation[:invalid_fields].any?
    blockers << 'assistant_validation_mutates_source' if validation[:changed_fields].any?
    result.merge(status: blockers.empty? ? 'ready' : 'blocked', blockers: blockers.uniq.sort,
                 scopes: scopes, before: simulation[:before], after: simulation[:after], surface_differences: simulation[:differences], **validation)
  end

  def validate_candidate(scopes)
    canonical = { 'version' => Captain::Capabilities::VERSION, 'scopes' => scopes.transform_values do |scope|
      { 'enabled' => scope[:enabled], 'tool_ids' => scope[:proposed_tool_ids] }
    end }
    runtime_scope = @assistant.internal_assistant? ? 'assistant' : 'agent'
    scope = scopes.fetch(runtime_scope)
    # Exactly these source mentions were already nonbinding. Unknown, dormant or
    # opposite-scope references never initialize a canonical grant.
    ignored = scope[:instruction_tool_ids] - scope[:effective_tool_ids]
    @assistant.capability_transition_validation(
      config: @assistant.config.merge(Captain::Capabilities::KEY => canonical), ignored_instruction_tool_ids: ignored
    )
  end

  def simulation_blockers(simulation)
    blockers = []
    blockers << 'ai_surface_difference' if simulation[:differences].keys.any? { |surface| !surface.to_s.start_with?('mcp_') }
    blockers << 'external_catalog_unverified' if @assistant.account.captain_mcp_servers.enabled.exists?
    blockers
  end

  def transition_scope(scope, legacy, blockers, quarantined)
    available = Captain::ToolAccess.available_tool_ids_for(@assistant, scope).map(&:to_s)
    audit_references(scope, legacy, available, blockers, quarantined)
    proposed = (legacy[:effective_tool_ids] | dormant_selections(scope, legacy, available)).sort
    { enabled: legacy[:enabled], proposed_tool_ids: proposed, dormant_tool_ids: (proposed - available).sort,
      instruction_tool_ids: legacy[:instruction_tool_ids].uniq.sort, effective_tool_ids: legacy[:effective_tool_ids].sort }
  end

  def audit_references(scope, legacy, available, blockers, quarantined)
    stored = legacy[:stored_tool_ids].uniq
    unresolved = (stored | legacy[:instruction_tool_ids]).reject { |id| known_tool?(id) || available.include?(id) }
    blockers << 'wrong_scope_tool_ids' if stored.any? { |id| known_tool?(id) && !known_in_scope?(id, scope) }
    external = unresolved.grep(/^mcp__/)
    blockers << 'unresolved_external_tool_ids' if external.any?
    quarantined[scope] = (unresolved - external).sort
  end

  def dormant_selections(scope, legacy, available)
    # Available but withheld selections (notably FAQ without entries) are not
    # dormant: their union with BEFORE would create new AI grants on cutover.
    legacy[:stored_tool_ids].select { |id| known_in_scope?(id, scope) && (!legacy[:enabled] || available.exclude?(id)) }
  end

  def known_tool?(id)
    Captain::ToolRegistry.definition_for(id).present? || @assistant.account.captain_custom_tools.exists?(slug: id)
  end

  def known_in_scope?(id, scope)
    definition = Captain::ToolRegistry.definition_for(id)
    return definition.supports_scope?(scope) if definition

    @assistant.account.captain_custom_tools.exists?(slug: id)
  end

  def reference_shape_blockers
    malformed = Captain::ToolAccess::SCOPE_ORDER.any? do |scope|
      @assistant.send(:referenced_tool_ids_for_scope, scope).any? { |id| !valid_tool_id?(id) }
    end
    malformed ? ['malformed_instruction_tool_ids'] : []
  end

  def shape_blockers
    return ['malformed_legacy_config'] unless @assistant.config.is_a?(Hash)

    access = @assistant.config['tool_access']
    return [] if access.nil?
    return ['malformed_legacy_access'] unless access.is_a?(Hash)

    blockers = []
    blockers << 'unknown_scopes' if (access.keys - Captain::ToolAccess::SCOPE_ORDER).any?
    blockers << 'malformed_legacy_scope' if access.values.any? { |scope| malformed_scope?(scope) }
    blockers
  end

  def malformed_scope?(scope)
    return true unless scope.is_a?(Hash)
    return true if scope.key?('enabled') && Captain::Capabilities::BOOLEANS.exclude?(scope['enabled'])
    return false unless scope.key?('tool_ids')

    !scope['tool_ids'].is_a?(Array) || scope['tool_ids'].any? { |id| !valid_tool_id?(id) }
  end

  def valid_tool_id?(id)
    id.is_a?(String) && TOOL_ID.match?(id)
  end

  # Only the hash is public. Include workspace policy plus catalog definitions
  # (confirmation/availability included) even when they leave today's sets equal.
  def context
    [@assistant.attributes.except('updated_at', 'config'), digest_config,
     @assistant.account.attributes,
     Captain::ToolRegistry.definitions.map(&:to_h), @assistant.account.captain_custom_tools.order(:id).map(&:attributes),
     @assistant.account.hooks.order(:id).map(&:attributes), @assistant.account.captain_mcp_servers.order(:id).map(&:attributes)]
  end

  def digest_config
    config = @assistant.config
    config.is_a?(Hash) ? config.except(Captain::Capabilities::SNAPSHOT_KEY) : config
  end

  def digest(value)
    Captain::Capabilities.digest(value)
  end
end
