# frozen_string_literal: true

class Llm::OpenRouterAdminOperations
  Operation = Struct.new(:id, :title, :status, :scope, :reason, :capabilities, keyword_init: true) do
    def implemented?
      status == 'implemented'
    end

    def deferred?
      status == 'deferred'
    end

    def to_h
      {
        id: id,
        title: title,
        status: status,
        scope: scope,
        reason: reason,
        capabilities: capabilities
      }.compact
    end
  end

  IMPLEMENTED_OPERATIONS = [
    Operation.new(
      id: 'key_health',
      title: 'OpenRouter key and credits health',
      status: 'implemented',
      scope: 'superadmin',
      reason: 'Refreshes key status and credits with CAPTAIN_OPENROUTER_MANAGEMENT_API_KEY when configured.',
      capabilities: %w[key_status credits]
    ),
    Operation.new(
      id: 'model_catalog_refresh',
      title: 'OpenRouter model catalog refresh',
      status: 'implemented',
      scope: 'superadmin',
      reason: 'Refreshes selectable model metadata outside user request paths.',
      capabilities: %w[models capabilities pricing modalities]
    ),
    Operation.new(
      id: 'endpoint_catalog_refresh',
      title: 'OpenRouter endpoint catalog refresh',
      status: 'implemented',
      scope: 'superadmin',
      reason: 'Refreshes provider endpoint metadata for routing and ZDR compatibility checks.',
      capabilities: %w[endpoints providers zdr routing]
    )
  ].freeze

  DEFERRED_OPERATIONS = [
    Operation.new(
      id: 'workspace_management',
      title: 'OpenRouter workspace management',
      status: 'deferred',
      scope: 'superadmin',
      reason: 'Workspace creation and membership changes remain external OpenRouter organization administration.',
      capabilities: %w[workspaces members]
    ),
    Operation.new(
      id: 'remote_guardrail_sync',
      title: 'OpenRouter remote guardrail sync',
      status: 'deferred',
      scope: 'superadmin',
      reason: 'Local OneLink guardrails are enforced in runtime; remote OpenRouter guardrail mutation needs explicit audit and rollout.',
      capabilities: %w[guardrails budgets provider_allowlist model_allowlist sensitive_info prompt_injection]
    ),
    Operation.new(
      id: 'remote_plugin_defaults',
      title: 'OpenRouter remote plugin defaults',
      status: 'deferred',
      scope: 'superadmin',
      reason: 'Per-request plugin policy is enforced in code to avoid hidden organization defaults changing production behavior.',
      capabilities: %w[plugins response_healing context_compression]
    ),
    Operation.new(
      id: 'provider_endpoint_manual_pinning',
      title: 'Manual OpenRouter provider endpoint pinning',
      status: 'deferred',
      scope: 'superadmin',
      reason: 'Provider order and ZDR policy are supported; account-level endpoint pinning needs audit, rollback, and stale-endpoint handling.',
      capabilities: %w[provider_endpoint_pinning routing_zdr rollback]
    )
  ].freeze

  class << self
    def call
      operations = IMPLEMENTED_OPERATIONS + DEFERRED_OPERATIONS
      {
        operations: operations.map(&:to_h),
        implemented: operations.select(&:implemented?).map(&:id),
        deferred: operations.select(&:deferred?).map(&:id)
      }
    end
  end
end
