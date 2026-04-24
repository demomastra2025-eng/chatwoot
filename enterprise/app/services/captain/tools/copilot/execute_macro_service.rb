class Captain::Tools::Copilot::ExecuteMacroService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'execute_macro'
  end

  description 'Execute a macro for one or more conversations using conversation display IDs'
  param :macro_id, type: :integer, desc: 'Macro ID', required: true
  param :conversation_display_ids, type: :array,
                                   desc: 'Optional list of conversation display IDs. Defaults to the current conversation when available.', required: false

  def execute(macro_id:, conversation_display_ids: nil)
    macro = account.macros.find(macro_id)
    raise ArgumentError, 'You are not allowed to execute this macro' unless authorized_to_execute?(macro)

    ids = normalized_conversation_display_ids(conversation_display_ids)
    raise ArgumentError, 'At least one conversation display ID is required' if ids.blank?

    ::MacrosExecutionJob.perform_later(macro, conversation_ids: ids, user: @user)

    formatted_payload(
      action: 'execute_macro',
      macro: {
        id: macro.id,
        name: macro.name,
        visibility: macro.visibility,
        conversation_display_ids: ids
      }
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    current_account_user.present?
  end

  private

  def authorized_to_execute?(macro)
    macro.global? || macro.created_by == @user
  end

  def normalized_conversation_display_ids(value)
    ids = Array(value).flatten.filter_map { |item| item.to_s.strip.presence&.to_i }
    ids = [current_conversation.display_id] if ids.blank? && current_conversation.present?
    ids.uniq
  end
end
