# frozen_string_literal: true

# Read-only inventory for a later atomic cutover to tool_access as the sole binding source.
# Never remove instruction references or stored grants before comparing this plan with all runtime scopes.
class Captain::ToolAccessMigrationPlan
  def self.for(assistant)
    new(assistant).plan
  end

  def initialize(assistant)
    @assistant = assistant
  end

  def plan
    {
      assistant_id: @assistant.id,
      status: 'inventory_only',
      runtime_cutover_required: true,
      scopes: Captain::ToolAccess::SCOPE_ORDER.index_with { |scope| scope_plan(scope) },
      unknown_scopes: unknown_scopes
    }
  end

  private

  def scope_plan(scope)
    raw = Captain::ToolAccess.raw_scope(@assistant.config.to_h, scope) || {}
    normalized = @assistant.normalized_tool_access.fetch(scope)
    available = Captain::ToolAccess.available_tool_ids_for(@assistant, scope).map(&:to_s)
    stored = Array(raw['tool_ids']).map(&:to_s)
    referenced = @assistant.send(:referenced_tool_ids_for_scope, scope).map(&:to_s)
    effective = @assistant.public_send("allowed_#{scope}_tool_ids")

    {
      enabled: normalized['enabled'],
      stored_tool_ids: stored,
      instruction_tool_ids: referenced,
      effective_tool_ids: effective,
      # Preserve dormant grants too: current feature availability is not permission to erase them.
      proposed_tool_ids: (stored | referenced | effective).sort,
      unavailable_tool_ids: ((stored | referenced) - available).sort
    }
  end

  def unknown_scopes
    access = @assistant.config.to_h['tool_access']
    access.is_a?(Hash) ? access.keys - Captain::ToolAccess::SCOPE_ORDER : []
  end
end
