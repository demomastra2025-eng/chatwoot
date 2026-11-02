# frozen_string_literal: true

# Inventory and candidate simulation: no prompts in reports and no data writes.
# Every binding surface must remain equivalent before activation can be offered.
class Captain::ToolAccessMigrationPlan
  SCOPE_BLOCKERS = {
    unknown_tool_ids: 'unknown_tool_ids', mcp_difference: 'mcp_surface_difference', voice_difference: 'voice_surface_difference'
  }.freeze

  def self.for(assistant)
    ActiveRecord::Base.cache { new(assistant).plan }
  end

  def initialize(assistant)
    @assistant = assistant
  end

  def plan
    inventory = self.inventory
    scopes = inventory[:scopes]
    differences = Captain::CapabilitySurfaces.compare(@assistant, scopes)
    blockers = inventory[:blockers]
    blockers << 'canonical_surface_difference' if differences.any?
    result = { assistant_id: @assistant.id, status: status(blockers), blockers: blockers, scopes: scopes, unknown_scopes: unknown_scopes,
               surface_differences: differences }
    result.merge(source_digest: Captain::Capabilities.digest([@assistant.config, @assistant.description, result]))
  end

  # Shared inventory for explicit policy preparation; ordinary plan still checks
  # equivalence against its strict candidate before advertising readiness.
  def inventory
    scopes = Captain::ToolAccess::SCOPE_ORDER.index_with { |scope| scope_plan(scope) }
    { scopes: scopes, blockers: blockers_for(scopes) }
  end

  private

  def status(blockers)
    return 'migrated' if Captain::Capabilities.configured?(@assistant.config)

    blockers.empty? ? 'ready' : 'blocked'
  end

  def scope_plan(scope)
    raw = Captain::ToolAccess.raw_scope(@assistant.config.to_h, scope) || {}
    available = Captain::ToolAccess.available_tool_ids_for(@assistant, scope).map(&:to_s)
    ids = scope_ids(scope, raw)
    # Stored dormant grants remain recoverable. A mention only becomes a binding
    # when the legacy reader actually granted it; ignored references stay provenance.
    proposed = proposed_ids(scope, ids)
    ids.merge(
      enabled: @assistant.normalized_tool_access.fetch(scope)['enabled'], proposed_tool_ids: proposed,
      ignored_instruction_tool_ids: ids[:instruction_tool_ids] - ids[:effective_tool_ids],
      mcp_difference: mcp_difference(scope, raw, available, ids[:effective_tool_ids]),
      voice_difference: voice_difference(scope, ids[:effective_tool_ids]),
      **availability_report(proposed, available)
    )
  end

  def proposed_ids(scope, ids)
    return Captain::Capabilities.scope(@assistant.config, scope).fetch('tool_ids', []).sort if Captain::Capabilities.configured?(@assistant.config)

    (ids[:stored_tool_ids] | ids[:effective_tool_ids]).sort
  end

  def scope_ids(scope, raw)
    {
      stored_tool_ids: Array(raw['tool_ids']).map(&:to_s),
      instruction_tool_ids: @assistant.send(:referenced_tool_ids_for_scope, scope).map(&:to_s),
      effective_tool_ids: @assistant.public_send("allowed_#{scope}_tool_ids")
    }
  end

  def availability_report(proposed, available)
    {
      dormant_tool_ids: (proposed - available).select { |id| known_tool?(id) },
      unknown_tool_ids: proposed.reject { |id| available.include?(id) || known_tool?(id) }
    }
  end

  def mcp_difference(scope, raw, available, effective)
    mcp = mcp_ids(scope, raw, available)
    ((mcp - effective) | (effective - mcp)).sort
  end

  def voice_difference(scope, effective)
    return [] unless scope == Captain::ToolAccess::SCOPE_AGENT

    current = @assistant.voice_runtime_agent_tools.pluck(:id).map(&:to_s)
    proposed = effective - ['get_appointment_provider_status']
    ((current - proposed) | (proposed - current)).sort
  end

  def known_tool?(id)
    Captain::ToolRegistry.definition_for(id).present? || @assistant.account.captain_custom_tools.exists?(slug: id)
  end

  def mcp_ids(scope, raw, available)
    return @assistant.public_send("allowed_#{scope}_tool_ids") if Captain::Capabilities.configured?(@assistant.config)

    return available unless Captain::ToolAccess.scope_configured?(@assistant, scope)

    defaults = Captain::ToolAccess.default_tool_ids_for(scope, Captain::ToolAccess.available_tools_for_scope(@assistant, scope))
    enabled = raw.key?('enabled') ? ActiveModel::Type::Boolean.new.cast(raw['enabled']) : defaults.any?
    enabled ? Array(raw.fetch('tool_ids', defaults)).map(&:to_s) & available : []
  end

  def blockers_for(scopes)
    blockers = legacy_shape_blockers
    blockers += SCOPE_BLOCKERS.filter_map { |key, code| code if scopes.values.any? { |scope| scope[key].any? } }
    blockers << 'unconverted_legacy_scenarios' if @assistant.scenarios.enabled.where.missing(:standalone_agent).exists?
    blockers << 'legacy_prompt_migration_required' if prompt_rewrite_required?
    blockers
  end

  def legacy_shape_blockers
    access = @assistant.config.to_h['tool_access']
    return [] if access.nil?
    return ['malformed_legacy_access'] unless access.is_a?(Hash)

    blockers = []
    blockers << 'unknown_scopes' if unknown_scopes.any?
    blockers << 'malformed_legacy_scope' if access.values.any? { |scope| malformed_scope?(scope) }
    blockers
  end

  def malformed_scope?(scope)
    !scope.is_a?(Hash) || (scope.key?('tool_ids') && !scope['tool_ids'].is_a?(Array))
  end

  def unknown_scopes
    access = @assistant.config.to_h['tool_access']
    access.is_a?(Hash) ? access.keys - Captain::ToolAccess::SCOPE_ORDER : []
  end

  def prompt_rewrite_required?
    attributes = Captain::Assistant::MergeLegacyRulesService.attributes_for(@assistant)
    attributes.fetch(:description, @assistant.description) != @assistant.description
  end
end
