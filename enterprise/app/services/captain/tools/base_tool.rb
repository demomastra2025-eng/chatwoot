class Captain::Tools::BaseTool < RubyLLM::Tool
  include Captain::ToolResultOutput

  attr_accessor :assistant

  class << self
    def new(...)
      prepend_runtime_instrumentation!
      super
    end

    private

    def prepend_runtime_instrumentation!
      return if @_captain_runtime_instrumentation_prepared

      prepend(Captain::Tools::Instrumentation)
      @_captain_runtime_instrumentation_prepared = true
    end
  end

  def initialize(assistant, user: nil, conversation: nil, copilot_thread: nil)
    @assistant = assistant
    @user = user
    @conversation = conversation
    @copilot_thread = copilot_thread
    super()
  end

  def active?
    true
  end

  private

  def tool_scope_name
    Captain::ToolAccess::SCOPE_ASSISTANT
  end

  def tool_safety_feature
    :copilot
  end

  def tool_safety_account
    assistant&.account
  end

  def tool_safety_preferences
    tool_safety_account&.captain_preferences&.dig(:runtime)
  end

  def tool_definition
    definition = registry_definition ? registry_definition.to_h : {}
    definition[:id] ||= name
    definition[:title] ||= name.to_s.humanize
    definition[:requires_confirmation] = true if runtime_confirmation_required?(definition)
    definition
  end

  def registry_definition
    Captain::ToolRegistry.definition_for_class(self.class, scope_name: tool_scope_name) ||
      Captain::ToolRegistry.definition_for(name)
  end

  def runtime_confirmation_required?(definition)
    Captain::ToolCatalog.requires_confirmation_for_scope?(definition, tool_scope_name)
  end

  def tool_runtime_context
    {
      conversation_id: @conversation&.id,
      conversation_display_id: @conversation&.display_id
    }.compact
  end

  def user_has_permission(permission)
    return false if @user.blank?

    account_user = current_account_user
    return false if account_user.blank?

    return account_user.custom_role.permissions.include?(permission) if account_user.custom_role.present?

    account_user.administrator? || account_user.agent?
  end

  def current_account_user
    return nil if @user.blank? || @assistant.blank?

    @current_account_user ||= AccountUser.find_by(account_id: @assistant.account_id, user_id: @user.id)
  end

  def account_administrator?
    current_account_user&.administrator?
  end
end
