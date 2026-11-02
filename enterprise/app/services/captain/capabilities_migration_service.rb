# frozen_string_literal: true

class Captain::CapabilitiesMigrationService
  def initialize(assistant:, actor:)
    @assistant = assistant
    @actor = actor
  end

  def prepare_transition(policy:, expected_account_id:)
    with_locked_source do
      transition_plan(policy, expected_account_id)
    end
  end

  def activate!(expected_digest:, policy: nil, expected_account_id: nil)
    with_locked_source do
      if policy
        validate_transition_context!(policy, expected_account_id)
        next if applied_transition?(expected_digest)
      end
      plan = policy ? transition_plan(policy, expected_account_id) : Captain::ToolAccessMigrationPlan.for(@assistant)
      reject!('capability_migration_stale') unless plan[:source_digest] == expected_digest
      reject!('capability_migration_blocked') unless plan[:status] == 'ready'

      canonical = { 'version' => Captain::Capabilities::VERSION, 'scopes' => canonical_scopes(plan) }
      config = @assistant.config.to_h.deep_dup
      config[Captain::Capabilities::SNAPSHOT_KEY] = snapshot(plan, canonical)
      config[Captain::Capabilities::KEY] = canonical
      persist_activation!(config, canonical, policy: policy)
    end
    @assistant
  end

  def rollback!
    with_locked_source do
      config = @assistant.config.to_h.deep_dup
      snapshot = config[Captain::Capabilities::SNAPSHOT_KEY].to_h
      reject!('capability_policy_rollback_requires_review') if snapshot['policy_transition'].present?
      reject!('capability_rollback_stale') unless unchanged_since_activation?(config, snapshot)

      config.delete(Captain::Capabilities::KEY)
      config[Captain::Capabilities::SNAPSHOT_KEY]['rolled_back_at'] = Time.current.iso8601
      @assistant.update!(config: config)
    end
    @assistant
  end

  private

  def persist_activation!(config, canonical, policy:)
    return @assistant.update!(config: config) unless policy

    # Normal validation runs unrelated legacy-rule rewriting. Preserve the
    # approved source and write only the validated canonical contract and audit.
    reject!('invalid_capabilities') unless Captain::Capabilities.valid?(canonical)
    @assistant.update_columns(config: config, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def with_locked_source
    authorize!
    account_id = @assistant.class.where(id: @assistant.id).pick(:account_id)
    reject!('capability_migration_account_mismatch') unless account_id == @assistant.account_id
    account = Account.find(account_id)
    account.with_lock do
      @assistant.with_lock do
        reject!('capability_migration_account_mismatch') unless @assistant.account_id == account_id
        @assistant.account = account
        authorize!(lock: true)
        yield
      end
    end
  end

  def transition_plan(policy, expected_account_id)
    validate_transition_context!(policy, expected_account_id)
    Captain::CapabilityPolicyTransitionPlan.new(@assistant, actor: @actor).plan
  end

  def validate_transition_context!(policy, expected_account_id)
    reject!('unsupported_capability_transition_policy') unless policy == Captain::CapabilityPolicyTransitionPlan::POLICY
    reject!('capability_migration_account_mismatch') unless expected_account_id.to_s == @assistant.account_id.to_s
  end

  def applied_transition?(expected_digest)
    return false unless @assistant.config.is_a?(Hash)

    config = @assistant.config.to_h
    snapshot = config[Captain::Capabilities::SNAPSHOT_KEY].to_h
    transition = snapshot['policy_transition'].to_h
    return false unless transition['manifest_digest'] == expected_digest && transition['actor_id'] == @actor.id

    # Reconstruct the original source in memory and replan with today's context.
    # A repeat may succeed only if the very same approved transition is still true.
    reject!('capability_migration_stale') unless unchanged_since_activation?(config, snapshot)
    original = @assistant.config
    begin
      @assistant.config = config.except(Captain::Capabilities::KEY, Captain::Capabilities::SNAPSHOT_KEY)
      plan = Captain::CapabilityPolicyTransitionPlan.new(@assistant, actor: @actor).plan
      reject!('capability_migration_stale') unless plan[:source_digest] == expected_digest
    ensure
      @assistant.config = original
    end
    true
  end

  def canonical_scopes(plan)
    plan[:scopes].transform_values { |scope| { 'enabled' => scope[:enabled], 'tool_ids' => scope[:proposed_tool_ids] } }
  end

  def snapshot(plan, canonical)
    result = {
      'source_digest' => plan[:source_digest], 'actor_id' => @actor.id, 'activated_at' => Time.current.iso8601,
      'legacy_tool_access' => @assistant.config.to_h['tool_access'],
      'instruction_sha256' => digest(@assistant.description), 'canonical_sha256' => digest(canonical),
      'instruction_tool_ids' => plan[:scopes].transform_values { |scope| scope[:instruction_tool_ids] }
    }
    if plan[:policy]
      result['policy_transition'] = {
        'policy' => plan[:policy], 'decision' => plan[:decision], 'manifest_digest' => plan[:source_digest], 'actor_id' => @actor.id,
        'manifest' => plan.deep_stringify_keys
      }
    end
    result
  end

  def unchanged_since_activation?(config, snapshot)
    config[Captain::Capabilities::KEY].present? && snapshot['instruction_sha256'] == digest(@assistant.description) &&
      snapshot['legacy_tool_access'] == config['tool_access'] && snapshot['canonical_sha256'] == digest(config[Captain::Capabilities::KEY])
  end

  def digest(value)
    Captain::Capabilities.digest(value)
  end

  def authorize!(lock: false)
    scope = lock ? User.lock : User
    @actor = scope.find_by(id: @actor&.id)
    reject!('platform_managed_capabilities') unless @actor && Captain::PromptInspectorAccess.allowed?(user: @actor)
  end

  def reject!(code)
    raise Captain::AssistantConfigContract::Violation.new(code, ['config.capabilities'])
  end
end
