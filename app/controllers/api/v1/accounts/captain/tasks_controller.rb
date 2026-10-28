require 'securerandom'
require 'timeout'

class Api::V1::Accounts::Captain::TasksController < Api::V1::Accounts::BaseController
  VALID_FEEDBACK_OUTCOMES = %w[generated applied dismissed sent notice_dismissed cancelled].freeze
  ACTIVE_SUGGESTION_STATUSES = Captain::ReplySuggestion::RequestStore::ACTIVE_STATUSES

  before_action :check_authorization
  before_action :ensure_text_improvement_enabled,
                except: [:label_suggestion, :feedback, :reply_suggestion_status, :cancel_reply_suggestion]

  def rewrite
    result = safe_execute_task do
      Captain::RewriteService.new(
        account: Current.account,
        content: params[:content],
        operation: params[:operation],
        conversation_display_id: params[:conversation_display_id]
      ).perform
    end

    render_result(result, copilot_action: params[:operation].presence || 'rewrite')
  end

  def summarize
    result = safe_execute_task do
      Captain::SummaryService.new(
        account: Current.account,
        conversation_display_id: params[:conversation_display_id]
      ).perform
    end

    render_result(result, copilot_action: 'summarize')
  end

  # Starts the suggestion in the background and answers at once (202); the result comes over ActionCable, or from #reply_suggestion_status.
  def reply_suggestion
    conversation = find_accessible_conversation
    return unless conversation

    result = Captain::ReplySuggestion::StartService.new(
      account: Current.account, user: Current.user, conversation: conversation, conversation_display_id: params[:conversation_display_id]
    ).perform
    render json: result.body, status: result.http_status
  end

  # The latest suggestion of this user in the conversation that was not acted on (it survives navigation), or the one asked for.
  def reply_suggestion_status
    conversation = find_accessible_conversation
    return unless conversation

    if params[:suggestion_request_id].present?
      record = find_owned_suggestion(params[:suggestion_request_id], conversation)
      return render_suggestion_error(:not_found, 'not_found') unless record
    else
      record = latest_open_suggestion(conversation)
    end
    render json: { suggestion: (Captain::ReplySuggestion::StatePresenter.new(record).as_json if record) }
  end

  # Stops the run on the server (the next checkpoint of the agent), and the suggestion never reappears.
  def cancel_reply_suggestion
    conversation = find_accessible_conversation
    return unless conversation

    record = find_owned_suggestion(params[:suggestion_request_id], conversation)
    return render_suggestion_error(:not_found, 'not_found') unless record

    status = ACTIVE_SUGGESTION_STATUSES.include?(record['status']) ? 'cancelling' : record['status']
    Captain::ReplySuggestion::RequestStore.request_cancel!(record['id'])
    Captain::ReplySuggestion::RequestStore.consume!(record['id'])
    record_cancelled_feedback(record, conversation)
    render json: { suggestion_request_id: record['id'], status: status }
  end

  def label_suggestion
    result = safe_execute_task do
      Captain::LabelSuggestionService.new(
        account: Current.account,
        conversation_display_id: params[:conversation_display_id]
      ).perform
    end

    render_result(result, copilot_action: 'label_suggestion')
  end

  def follow_up
    result = safe_execute_task do
      Captain::FollowUpService.new(
        account: Current.account,
        follow_up_context: params[:follow_up_context]&.to_unsafe_h,
        user_message: params[:message],
        conversation_display_id: params[:conversation_display_id]
      ).perform
    end

    render_result(result, copilot_action: 'follow_up')
  end

  def feedback
    outcome = params[:outcome].to_s
    return render json: { error: 'Invalid feedback outcome' }, status: :unprocessable_content unless VALID_FEEDBACK_OUTCOMES.include?(outcome)

    conversation = resolved_conversation
    return render_suggestion_error(:not_found, 'not_found') if conversation.nil? && params[:suggestion_request_id].present?
    return unless conversation.nil? || authorized_for_conversation?(conversation)

    record_feedback(outcome, conversation)
    render json: { ok: true, status: 'ok' }
  rescue Captain::ReplySuggestion::FeedbackService::NotFoundError
    render_suggestion_error(:not_found, 'not_found')
  end

  def approve_action
    action = action_approval_service.approve!(
      action_id: params[:action_id].to_s,
      digest: params[:digest].presence
    )
    render json: { ok: true, status: action['status'], action: action }
  rescue Captain::ReplySuggestion::ActionApprovalService::NotFoundError => e
    render json: { error: e.message }, status: :not_found
  rescue Captain::ReplySuggestion::ActionApprovalService::ForbiddenError => e
    render json: { error: e.message }, status: :forbidden
  rescue Captain::ReplySuggestion::ActionApprovalService::ExecutionError => e
    render json: { error: e.message, action: e.action }.compact, status: :unprocessable_content
  rescue Captain::ReplySuggestion::ActionApprovalService::Error => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  def reject_action
    action = action_approval_service.reject!(action_id: params[:action_id].to_s)
    render json: { ok: true, status: action['status'], action: action }
  rescue Captain::ReplySuggestion::ActionApprovalService::NotFoundError => e
    render json: { error: e.message }, status: :not_found
  rescue Captain::ReplySuggestion::ActionApprovalService::ForbiddenError => e
    render json: { error: e.message }, status: :forbidden
  rescue Captain::ReplySuggestion::ActionApprovalService::Error => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  private

  def action_approval_service
    Captain::ReplySuggestion::ActionApprovalService.new(
      account: Current.account,
      user: Current.user,
      conversation_display_id: params[:conversation_display_id]
    )
  end

  def safe_execute_task
    yield
  rescue StandardError => e
    Rails.logger.error("[CAPTAIN][TasksController] #{action_name} failed: #{e.class}: #{e.message}")
    {
      message: nil,
      fallback_error: true,
      error: I18n.t('captain.generation_failed', default: 'Failed to generate AI response. Please try again.')
    }
  end

  def render_result(result, copilot_action: action_name)
    return render json: { message: nil } if result.nil?
    return render json: { message: nil, error: result[:error] } if result[:fallback_error]
    return render json: { error: result[:error] }, status: :unprocessable_content if result[:error]

    request_id = resolve_request_id(result)
    record_generated_feedback(result, copilot_action, request_id)
    render json: build_task_response(result, request_id)
  end

  def resolve_request_id(result)
    result[:request_id].presence || result.dig(:follow_up_context, :request_id).presence || SecureRandom.uuid
  end

  def record_generated_feedback(result, copilot_action, request_id)
    return if result[:message].blank?

    record_copilot_feedback(outcome: 'generated', copilot_action: copilot_action, request_id: request_id, generated_text: result[:message])
  end

  def build_task_response(result, request_id)
    {
      message: result[:message],
      request_id: request_id,
      follow_up_context: result[:follow_up_context],
      captain_trace: result[:captain_trace].presence,
      suggestion_meta: result[:suggestion_meta].presence,
      pending_actions: result[:pending_actions].presence || result.dig(:suggestion_meta, 'pending_actions').presence
    }.compact
  end

  def record_feedback(outcome, conversation)
    copilot_action = params[:copilot_action].presence || 'reply_suggestion'
    return record_suggestion_feedback(outcome, copilot_action, conversation) if copilot_action == 'reply_suggestion'

    record_copilot_feedback(
      outcome: outcome, copilot_action: copilot_action, request_id: params[:request_id].presence, generated_text: params[:generated_text],
      final_text: params[:final_text], edited_before_send: params[:edited_before_send], follow_up_count: params[:follow_up_count],
      message_id: params[:message_id]
    )
  end

  def record_cancelled_feedback(record, conversation)
    Captain::ReplySuggestion::FeedbackService.new(
      account: Current.account, user: Current.user, conversation: conversation, outcome: 'cancelled', copilot_action: 'reply_suggestion',
      requested_display_id: params[:conversation_display_id], request_id: record['id'], suggestion_request_id: record['id']
    ).perform
  end

  def record_suggestion_feedback(outcome, copilot_action, conversation)
    Captain::ReplySuggestion::FeedbackService.new(
      account: Current.account, user: Current.user, conversation: conversation, outcome: outcome, copilot_action: copilot_action,
      requested_display_id: params[:conversation_display_id], request_id: params[:request_id].presence,
      suggestion_request_id: params[:suggestion_request_id].presence, generated_text: params[:generated_text],
      final_text: params[:final_text], edited_before_send: params[:edited_before_send], follow_up_count: params[:follow_up_count],
      message_id: params[:message_id]
    ).perform
  end

  def record_copilot_feedback(outcome:, copilot_action:, request_id:, **fields)
    Captain::CopilotFeedbackRecorder.record!(
      account: Current.account, user: Current.user, conversation: resolved_conversation, requested_display_id: params[:conversation_display_id],
      outcome: outcome, copilot_action: copilot_action, request_id: request_id,
      feature: action_name == 'feedback' ? copilot_action : action_name, **fields
    )
  end

  # The conversation of the request, when this user may see it. Otherwise the answer is already rendered and this returns nil.
  def find_accessible_conversation
    conversation = resolved_conversation
    if conversation.nil?
      render_suggestion_error(:not_found, 'conversation_not_found')
      return
    end

    conversation if authorized_for_conversation?(conversation)
  end

  def authorized_for_conversation?(conversation)
    authorize(conversation, :show?)
    true
  rescue Pundit::NotAuthorizedError
    render_suggestion_error(:forbidden, 'forbidden')
    false
  end

  # The suggestion has to be this user's, in this account and conversation: otherwise it does not exist for the caller.
  def find_owned_suggestion(id, conversation)
    record = Captain::ReplySuggestion::RequestStore.fetch(id.to_s)
    return unless record && record['account_id'] == Current.account.id && record['user_id'] == Current.user.id
    return unless record['conversation_id'] == conversation.id

    record
  end

  def latest_open_suggestion(conversation)
    id = Captain::ReplySuggestion::RequestStore.latest_id(Current.account.id, Current.user.id, conversation.id)
    return if id.blank? || Captain::ReplySuggestion::RequestStore.consumed?(id)

    record = Captain::ReplySuggestion::RequestStore.fetch(id)
    record if record && record['status'] != 'cancelled'
  end

  def render_suggestion_error(status, code)
    render json: { error: I18n.t("captain.reply_suggestion.errors.#{code}"), error_code: code }, status: status
  end

  # A display id of a conversation, or of a communication thread (the person): then the conversation in front of the thread, the
  # one whose status it shows (Conversations::CommunicationThreadResolver.front_first), not the newest one.
  def resolved_conversation
    return @resolved_conversation if defined?(@resolved_conversation)

    display_id = params[:conversation_display_id].presence
    return @resolved_conversation = nil unless display_id

    @resolved_conversation = Current.account.conversations.find_by(display_id: display_id) ||
                             Conversations::CommunicationThreadResolver.front_conversation(
                               CommunicationThread.find_by(account_id: Current.account.id, display_id: display_id)
                             )
  end

  def check_authorization
    return authorize(:'captain/tasks', :reply_suggestion?) if action_name == 'feedback'

    authorize(:'captain/tasks')
  end

  # "Text improvement" in AI settings (captain_features.editor) switches the
  # reply-box AI writing tools off for the whole account. Label suggestions
  # have their own switch.
  def ensure_text_improvement_enabled
    return if Current.account.captain_editor_enabled?

    publish_suggestion_unavailable('text_improvement_disabled') if action_name == 'reply_suggestion'
    render json: { error: I18n.t('captain.text_improvement_disabled'), error_code: 'text_improvement_disabled' }, status: :forbidden
  end

  def publish_suggestion_unavailable(error_code)
    Captain::ReplySuggestion::OutcomeEvent.publish_unavailable(
      account: Current.account, user: Current.user, conversation: resolved_conversation, error_code: error_code
    )
  end
end

Api::V1::Accounts::Captain::TasksController.prepend_mod_with('Api::V1::Accounts::Captain::TasksController')
