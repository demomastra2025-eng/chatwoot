# frozen_string_literal: true

module Captain::Assistant::LlmContextHelper
  private

  def llm_context_for_run
    overrides = Llm::Models.providers.keys.each_with_object({}) do |provider_name, result|
      api_key = runtime_api_key(provider_name)
      api_base = Llm::Config.api_base(provider_name, account: @assistant.account)
      next if api_key.blank? && api_base.blank?

      result[provider_name] = {
        api_key: api_key,
        api_base: api_base
      }.compact
    end
    return nil if overrides.blank?

    Llm::Config.context(overrides: overrides, account: @assistant.account)
  end

  def runtime_api_key(provider_name)
    Llm::Config.api_key(provider_name, account: @assistant.account)
  end
end
