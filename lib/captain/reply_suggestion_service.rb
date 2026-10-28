class Captain::ReplySuggestionService < Captain::BaseTaskService
  LEGACY_ENGINE = 'legacy_prompt'.freeze
  MODERATION_ERROR_CODE = 422

  REQUEST_OPTIONS = %i[request_id engine assistant_id progress_context].freeze

  # conversation: the conversation the caller already resolved.
  # request: the options of a reply suggestion request (see Captain::ReplySuggestion::GenerateJob):
  #   request_id         the id of the request, shared by every llm event of the run
  #   engine             fixed when the request started (see #suggestion_engine)
  #   assistant_id       kept in the records of an earlier release, which named an agent; ignored (the router picks the agent)
  #   progress_context   what the live progress events need (suggestion_request_id, requested conversation id, timing)
  def initialize(account:, conversation_display_id:, user:, conversation: nil, **request)
    super(account: account, conversation_display_id: conversation_display_id)
    request.assert_valid_keys(*REQUEST_OPTIONS)
    @user = user
    @conversation = conversation
    @request_id = request[:request_id]
    @engine = request[:engine]
    @progress_context = request[:progress_context]
  end

  # Returns an outcome (see Captain::ReplySuggestion::Outcome), never a bare text.
  def perform
    perform_reply_suggestion
  end

  # The engine of this request, fixed when it starts and never changed afterwards. Without an agent the old one-shot prompt is the
  # only engine. (The enterprise edition returns the agent when the account has one.)
  def suggestion_engine
    { engine: LEGACY_ENGINE, assistant_id: nil }
  end

  # nil, or the code of the precondition that stops the request before it is queued.
  def start_error_code
    Llm::Config.initialize!
    return :disabled unless captain_tasks_enabled?

    :api_key_missing unless api_key_configured?
  end

  # Counters of the run (tools_called, turns, handoffs_count) for the outcome event; the agent engine fills them.
  def run_stats
    {}
  end

  private

  attr_reader :user

  def perform_reply_suggestion
    legacy_outcome(
      make_api_call(
        model: task_model,
        messages: [
          { role: 'system', content: system_prompt },
          { role: 'user', content: formatted_conversation }
        ]
      )
    )
  end

  # The old one-shot prompt as an outcome. Only an account without an agent comes here.
  def legacy_outcome(result)
    result = result.to_h
    return legacy_draft(result) if result[:message].present? && !result[:error]
    return legacy_error_outcome(result) if result[:error].present?

    Captain::ReplySuggestion::Outcome.failed('empty_output')
  end

  def legacy_draft(result)
    if Captain::ReplySuggestion::DraftClaims.unsupported_completed_actions(draft: result[:message], context: {}).any?
      return Captain::ReplySuggestion::Outcome.human_needed(
        reason: I18n.t('captain.reply_suggestion.reasons.unsupported_claims', claims: result[:message].to_s.squish.truncate(120)),
        reason_source: 'safety', engine: LEGACY_ENGINE
      )
    end

    Captain::ReplySuggestion::Outcome.draft(
      message: result[:message].to_s.strip, engine: LEGACY_ENGINE, usage: result[:usage], follow_up_context: result[:follow_up_context],
      agent: nil, captain_trace: nil, suggestion_meta: nil
    )
  end

  def legacy_error_outcome(result)
    code = result[:error_code].to_i
    if code == MODERATION_ERROR_CODE
      return Captain::ReplySuggestion::Outcome.human_needed(
        reason: I18n.t('captain.reply_suggestion.reasons.safety_blocked'), reason_source: 'safety', engine: LEGACY_ENGINE
      )
    end

    Captain::ReplySuggestion::Outcome.failed(Captain::ReplySuggestion::Outcome::ERROR_CODE_FAILURES.fetch(code, 'provider_error'))
  end

  def system_prompt
    render_task_prompt('reply', prompt_variables)
  end

  def prompt_variables
    staff_signature = account.account_users.find_by(user_id: user.id)&.reply_signature
    {
      'channel_type' => conversation.inbox.channel_type,
      'staff_signature' => staff_signature,
      'agent_name' => user.name,
      'agent_signature' => staff_signature.presence || user.message_signature.presence,
      'has_search_tool' => false
    }
  end

  def formatted_conversation
    LlmFormatter::ConversationLlmFormatter.new(conversation).format(token_limit: TOKEN_LIMIT)
  end

  def request_event_context(model)
    context = super
    @request_id.present? ? context.merge(request_id: @request_id) : context
  end

  def event_name
    'reply_suggestion'
  end

  def task_moderation_stages
    [:output]
  end
end

Captain::ReplySuggestionService.prepend_mod_with('Captain::ReplySuggestionService')
