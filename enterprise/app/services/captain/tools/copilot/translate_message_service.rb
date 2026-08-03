class Captain::Tools::Copilot::TranslateMessageService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'translate_message'
  end

  description 'Translate a conversation message into a target language and cache the translated text on the message'
  param :message_id, type: :integer, desc: 'Message ID to translate', required: true
  param :target_language, type: :string, desc: 'Target language code, for example ru, en, or kk', required: true

  def execute(message_id:, target_language:)
    message = find_permissible_message!(message_id)
    translated_content = if already_translated?(message, target_language)
                           message.translations[target_language]
                         else
                           translate_and_persist!(message, target_language)
                         end
    return tool_failure('Translation returned empty content') if translated_content.blank?

    formatted_payload(
      action: 'translate_message',
      message_id: message.id,
      conversation_id: message.conversation.display_id,
      target_language: target_language,
      content: translated_content
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    user_has_permission('conversation_manage') ||
      user_has_permission('conversation_unassigned_manage') ||
      user_has_permission('conversation_participating_manage')
  end

  private

  def already_translated?(message, target_language)
    message.translations.present? && message.translations[target_language].present?
  end

  def translate_and_persist!(message, target_language)
    translated_content = ::Integrations::GoogleTranslate::ProcessorService.new(
      message: message,
      target_language: target_language
    ).perform

    translations = (message.translations || {}).merge(target_language => translated_content)
    message.update!(translations: translations) if translated_content.present?
    translated_content
  end
end
