require 'timeout'

class Captain::Llm::TranslateQueryService < Captain::BaseTaskService
  MODEL = 'gpt-4.1-nano'.freeze
  REQUEST_TIMEOUT_SECONDS = 5

  pattr_initialize [:account!]

  def translate(query, target_language:)
    return query if query_in_target_language?(query)

    messages = [
      { role: 'system', content: system_prompt(target_language) },
      { role: 'user', content: query }
    ]

    response = Timeout.timeout(REQUEST_TIMEOUT_SECONDS) do
      make_api_call(model: MODEL, messages: messages)
    end
    return query if response[:error]

    response[:message].strip
  rescue StandardError => e
    Rails.logger.warn "TranslateQueryService failed: #{e.message}, falling back to original query"
    query
  end

  private

  def event_name
    'translate_query'
  end

  def task_moderation_stages
    []
  end

  # Translation is an internal operation, not customer-initiated.
  # Prefer the system key; fall back to the account hook key for self-hosted setups without one.
  def llm_credential
    @llm_credential ||= system_llm_credential || hook_llm_credential
  end

  def query_in_target_language?(query)
    detector = CLD3::NNetLanguageIdentifier.new(0, 1000)
    result = detector.find_language(query)

    result.reliable? && result.language == account_language_code
  rescue StandardError
    false
  end

  def account_language_code
    account.locale&.split('_')&.first
  end

  def system_prompt(target_language)
    render_task_prompt('translate_query', target_language: target_language)
  end
end
