class Captain::ToolPolicy
  AGENT_HIGH_RISK_LEVELS = %w[high custom].freeze

  class << self
    def runtime_allowed?(tool_definition, assistant:, scope_name:, user: nil)
      new(tool_definition, assistant: assistant, scope_name: scope_name, user: user).runtime_allowed?
    end

    def selection_metadata(tool_definition)
      new(tool_definition).selection_metadata
    end
  end

  def initialize(tool_definition, assistant: nil, scope_name: nil, user: nil)
    @tool_definition = (tool_definition || {}).with_indifferent_access
    @assistant = assistant
    @scope_name = scope_name.to_s.presence
    @user = user
  end

  def runtime_allowed?
    return false unless scope_allowed?

    feature_requirements_satisfied?
  end

  def selection_metadata
    {
      required_features: required_features,
      required_permissions: required_permissions,
      risk_level: risk_level,
      requires_confirmation: requires_confirmation?,
      agent_high_risk: agent_high_risk?
    }
  end

  private

  attr_reader :assistant, :scope_name, :user

  def scope_allowed?
    return true if allowed_scopes.blank? || scope_name.blank?

    allowed_scopes.include?(scope_name)
  end

  def feature_requirements_satisfied?
    return true if assistant.blank? || required_features.blank?

    required_features.all? { |feature_name| assistant.account.feature_enabled?(feature_name) }
  end

  def permission_requirements_satisfied?
    return true if required_permissions.blank?
    return agent_permission_requirements_satisfied? if scope_name == Captain::ToolAccess::SCOPE_AGENT

    account_user = resolved_account_user
    return false if account_user.blank?

    if account_user.custom_role.present?
      required_permissions.any? { |permission| account_user.custom_role.permissions.include?(permission) }
    else
      account_user.administrator? || account_user.agent?
    end
  end

  def agent_permission_requirements_satisfied?
    return false if assistant.blank?
    return true if capability_tool?

    Llm::RuntimePolicy.agent_permissioned_tool_allowed?(
      tool_id,
      account: assistant.account
    )
  end

  def agent_risk_requirements_satisfied?
    return true unless scope_name == Captain::ToolAccess::SCOPE_AGENT
    return true unless agent_high_risk?
    return false if assistant.blank?

    Llm::RuntimePolicy.agent_high_risk_tool_allowed?(
      tool_id,
      account: assistant.account
    )
  end

  def confirmation_requirements_satisfied?
    return true unless requires_confirmation?

    scope_name != Captain::ToolAccess::SCOPE_AGENT
  end

  def resolved_account_user
    return nil if assistant.blank? || user.blank?

    AccountUser.find_by(account_id: assistant.account_id, user_id: user.id)
  end

  def allowed_scopes
    Array(@tool_definition[:allowed_scopes]).map(&:to_s)
  end

  def required_features
    Array(@tool_definition[:required_features]).map(&:to_s)
  end

  def required_permissions
    Array(@tool_definition[:required_permissions]).map(&:to_s)
  end

  def risk_level
    @tool_definition[:risk_level].presence || 'medium'
  end

  def agent_high_risk?
    AGENT_HIGH_RISK_LEVELS.include?(risk_level.to_s)
  end

  def tool_id
    @tool_definition[:id].to_s
  end

  def requires_confirmation?
    ActiveModel::Type::Boolean.new.cast(@tool_definition[:requires_confirmation])
  end

  def capability_tool?
    ActiveModel::Type::Boolean.new.cast(@tool_definition[:capability_tool])
  end
end
