class Crm::Deals::StageEntryPolicy
  def initialize(deal:, target_stage:, account:, actor:, **override_options)
    @deal = deal
    @target_stage = target_stage
    @account = account
    @actor = actor
    @override_requested = override_options[:override_requested]
    @override_reason = override_options[:override_reason].to_s.strip
  end

  def enforce!
    missing_fields = required_field_issues
    rule_violations = movement_rule_violations
    return if missing_fields.empty? && rule_violations.empty?
    return override_audit(rule_violations, missing_fields) if override_requested? && override_allowed?(missing_fields)

    raise_policy_error!(missing_fields, rule_violations)
  end

  private

  attr_reader :account, :actor, :deal, :override_reason, :target_stage

  def required_field_issues
    Crm::RequiredFieldsInspector.new(
      account: account,
      entity_kind: :deal,
      custom_attributes: deal.custom_attributes,
      context: 'deal_stage_transition',
      record: deal,
      requirements: target_stage.field_requirements.where(required: true),
      actor: actor
    ).missing_field_details
  end

  def movement_rule_violations
    stages = target_stage.pipeline.stages.active.ordered.to_a
    current_index = stages.index { |stage| stage.id == deal.stage_id }
    target_index = stages.index { |stage| stage.id == target_stage.id }
    return [] unless current_index && target_index && deal.pipeline_id == target_stage.pipeline_id

    [skipping_violation(current_index, target_index), backward_violation(current_index, target_index)].compact
  end

  def skipping_violation(current_index, target_index)
    return unless target_stage.pipeline.restrict_stage_skipping?
    return unless (target_index - current_index).abs > 1

    { code: 'STAGE_SKIPPING_RESTRICTED', from_index: current_index, to_index: target_index }
  end

  def backward_violation(current_index, target_index)
    return unless target_stage.pipeline.restrict_backward_move?
    return unless target_index < current_index

    { code: 'BACKWARD_STAGE_MOVE_RESTRICTED', from_index: current_index, to_index: target_index }
  end

  def override_requested?
    ActiveModel::Type::Boolean.new.cast(@override_requested) || override_reason.present?
  end

  def override_allowed?(missing_fields)
    ensure_override_permitted!
    ensure_fields_overrideable!(missing_fields)
    ensure_override_reason!
    true
  end

  def ensure_override_permitted!
    return if target_stage.pipeline.allow_stage_rule_override? && administrator?

    raise_override_error('Stage rule override is not allowed')
  end

  def ensure_fields_overrideable!(missing_fields)
    return if missing_fields.none? { |field| field[:scope] != 'stage' }

    raise_override_error('Global required fields cannot be overridden')
  end

  def ensure_override_reason!
    return if override_reason.present?

    raise Crm::Error.new(
      code: 'STAGE_RULE_OVERRIDE_REASON_REQUIRED',
      message: 'Override reason is required',
      status: :unprocessable_content
    )
  end

  def raise_override_error(message)
    raise Crm::Error.new(code: 'STAGE_RULE_OVERRIDE_FORBIDDEN', message: message, status: :forbidden)
  end

  def administrator?
    account.account_users.find_by(user_id: actor&.id)&.administrator?
  end

  def override_audit(rule_violations, missing_fields)
    {
      actor_id: actor.id,
      reason: override_reason,
      target_stage_id: target_stage.id,
      missing_field_keys: missing_fields.pluck(:key),
      rule_codes: rule_violations.pluck(:code)
    }
  end

  def raise_policy_error!(missing_fields, rule_violations)
    details = policy_error_details(missing_fields, rule_violations)
    raise missing_fields_error(missing_fields, details) if missing_fields.present?

    raise Crm::Error.new(
      code: 'DEAL_STAGE_ENTRY_RESTRICTED',
      message: 'This stage transition is restricted',
      status: :unprocessable_content,
      details: details
    )
  end

  def policy_error_details(missing_fields, rule_violations)
    {
      missing_fields: missing_fields,
      rule_violations: rule_violations,
      target_stage_id: target_stage.id,
      can_override: override_capable?(missing_fields)
    }
  end

  def missing_fields_error(missing_fields, details)
    labels = missing_fields.pluck(:label).join(', ')
    Crm::Error.new(
      code: 'DEAL_STAGE_REQUIRES_FIELDS',
      message: "Fill required fields before moving the deal: #{labels}",
      status: :unprocessable_content,
      details: details
    )
  end

  def override_capable?(missing_fields)
    target_stage.pipeline.allow_stage_rule_override? &&
      administrator? &&
      missing_fields.none? { |field| field[:scope] != 'stage' }
  end
end
