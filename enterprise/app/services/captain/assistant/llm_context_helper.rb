# frozen_string_literal: true

module Captain::Assistant::LlmContextHelper
  private

  def llm_context_for_run
    overrides = Llm::Models.providers.keys.each_with_object({}) do |provider_name, result|
      api_key = runtime_api_key(provider_name)
      api_base = Llm::Config.api_base(provider_name)
      next if api_key.blank? && api_base.blank?

      result[provider_name] = {
        api_key: api_key,
        api_base: api_base
      }.compact
    end
    return nil if overrides.blank?

    Llm::Config.context(overrides: overrides)
  end

  def runtime_api_key(provider_name)
    return openai_hook&.settings&.dig('api_key').presence || Llm::Config.api_key('openai') if provider_name.to_s == 'openai'

    Llm::Config.api_key(provider_name)
  end

  def openai_hook
    @openai_hook ||= @assistant.account.hooks.find_by(app_id: 'openai', status: 'enabled')
  end
end
