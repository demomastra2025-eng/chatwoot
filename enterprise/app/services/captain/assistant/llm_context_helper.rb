# frozen_string_literal: true

module Captain::Assistant::LlmContextHelper
  private

  def llm_context_for_run
    api_key = runtime_api_key
    api_base = Llm::Config.api_base
    return nil if api_key.blank? && api_base.blank?

    Llm::Config.context(api_key: api_key, api_base: api_base)
  end

  def runtime_api_key
    @runtime_api_key ||= openai_hook&.settings&.dig('api_key').presence || system_api_key
  end

  def openai_hook
    @openai_hook ||= @assistant.account.hooks.find_by(app_id: 'openai', status: 'enabled')
  end

  def system_api_key
    @system_api_key ||= InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value.presence
  end
end
