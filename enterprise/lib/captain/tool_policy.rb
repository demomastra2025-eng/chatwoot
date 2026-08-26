class Captain::ToolPolicy
  AGENT_HIGH_RISK_LEVELS = %w[high custom].freeze

  class << self
    def runtime_allowed?(tool_definition, assistant:, scope_name:, user: nil)
      new(tool_definition, assistant: assistant, scope_name: scope_name, user: user).runtime_allowed?
    end

    def execution_allowed?(tool_definition, assistant:, scope_name:, user: nil)
      new(tool_definition, assistant: assistant, scope_name: scope_name, user: user).execution_allowed?
    end

    def execution_error_message(tool_definition, assistant:, scope_name:, user: nil)
      new(tool_definition, assistant: assistant, scope_name: scope_name, user: user).execution_error_message
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

    feature_requirements_satisfied? &&
      runtime_requirements_satisfied?
  end

  def execution_allowed?
    scope_allowed? &&
      feature_requirements_satisfied? &&
      runtime_requirements_satisfied? &&
      permission_requirements_satisfied?
  end

  def execution_error_message
    return 'Tool is not available for the current runtime scope' unless scope_allowed?
    return 'Required account feature is not enabled for this tool' unless feature_requirements_satisfied?
    return 'Required runtime setting is not enabled for this tool' unless runtime_requirements_satisfied?
    return 'Tool permission is not available for the current operator' unless permission_requirements_satisfied?

    'Tool is not available for the current runtime policy'
  end

  def selection_metadata
    {
      required_features: required_features,
      required_runtime_flags: required_runtime_flags,
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
    # Customer-facing agents do not have a human AccountUser. Their authority is the
    # prompt-bound/selected agent tool catalog; ToolWrapper enforces the current
    # agent's bound tool list at call time.
    return true if scope_name == Captain::ToolAccess::SCOPE_AGENT

    account_user = resolved_account_user
    return false if account_user.blank?

    if account_user.custom_role.present?
      required_permissions.any? { |permission| account_user.custom_role.permissions.include?(permission) }
    else
      account_user.administrator? || account_user.agent?
    end
  end

  def runtime_requirements_satisfied?
    return true if assistant.blank? || required_runtime_flags.blank?

    required_runtime_flags.all? do |flag|
      case flag
      when 'web_search'
        web_access_available?('web_search')
      when 'web_scrape'
        web_access_available?('web_scrape_url')
      else
        true
      end
    end
  end

  def web_access_available?(tool_id)
    Captain::Tools::FirecrawlService.configured? &&
      Captain::ToolAccess.per_assistant_web_tool_enabled?(assistant, tool_id, scope_name: scope_name)
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

  def required_runtime_flags
    Array(@tool_definition[:required_runtime_flags]).map(&:to_s)
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
end
