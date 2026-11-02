# frozen_string_literal: true

class Captain::CapabilitiesMigrationService
  def initialize(assistant:, actor:)
    @assistant = assistant
    @actor = actor
  end

  def activate!(expected_digest:)
    authorize!
    @assistant.with_lock do
      plan = Captain::ToolAccessMigrationPlan.for(@assistant)
      reject!('capability_migration_stale') unless plan[:source_digest] == expected_digest
      reject!('capability_migration_blocked') unless plan[:status] == 'ready'

      canonical = { 'version' => Captain::Capabilities::VERSION, 'scopes' => canonical_scopes(plan) }
      config = @assistant.config.to_h.deep_dup
      config[Captain::Capabilities::SNAPSHOT_KEY] = snapshot(plan, canonical)
      config[Captain::Capabilities::KEY] = canonical
      @assistant.update!(config: config)
    end
    @assistant
  end

  def rollback!
    authorize!
    @assistant.with_lock do
      config = @assistant.config.to_h.deep_dup
      snapshot = config[Captain::Capabilities::SNAPSHOT_KEY].to_h
      reject!('capability_rollback_stale') unless unchanged_since_activation?(config, snapshot)

      config.delete(Captain::Capabilities::KEY)
      config[Captain::Capabilities::SNAPSHOT_KEY]['rolled_back_at'] = Time.current.iso8601
      @assistant.update!(config: config)
    end
    @assistant
  end

  private

  def canonical_scopes(plan)
    plan[:scopes].transform_values { |scope| { 'enabled' => scope[:enabled], 'tool_ids' => scope[:proposed_tool_ids] } }
  end

  def snapshot(plan, canonical)
    {
      'source_digest' => plan[:source_digest], 'actor_id' => @actor.id, 'activated_at' => Time.current.iso8601,
      'legacy_tool_access' => @assistant.config.to_h['tool_access'],
      'instruction_sha256' => digest(@assistant.description), 'canonical_sha256' => digest(canonical),
      'instruction_tool_ids' => plan[:scopes].transform_values { |scope| scope[:instruction_tool_ids] }
    }
  end

  def unchanged_since_activation?(config, snapshot)
    config[Captain::Capabilities::KEY].present? && snapshot['instruction_sha256'] == digest(@assistant.description) &&
      snapshot['legacy_tool_access'] == config['tool_access'] && snapshot['canonical_sha256'] == digest(config[Captain::Capabilities::KEY])
  end

  def digest(value)
    Captain::Capabilities.digest(value)
  end

  def authorize!
    reject!('platform_managed_capabilities') unless Captain::PromptInspectorAccess.allowed?(user: @actor)
  end

  def reject!(code)
    raise Captain::AssistantConfigContract::Violation.new(code, ['config.capabilities'])
  end
end
