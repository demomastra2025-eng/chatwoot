require 'securerandom'
require 'timeout'

class Api::V1::Accounts::Captain::TasksController < Api::V1::Accounts::BaseController
  VALID_FEEDBACK_OUTCOMES = %w[generated applied dismissed sent].freeze

  before_action :check_authorization
  before_action :ensure_text_improvement_enabled, except: [:label_suggestion, :feedback]

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

  def reply_suggestion
    result = safe_execute_task do
      Captain::ReplySuggestionService.new(
        account: Current.account,
        conversation_display_id: params[:conversation_display_id],
        user: Current.user
      ).perform
    end

    render_result(result, copilot_action: 'reply_suggestion')
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

    record_copilot_feedback_event(
      outcome: outcome,
      copilot_action: params[:copilot_action].presence || 'reply_suggestion',
      request_id: params[:request_id].presence,
      generated_text: params[:generated_text],
      final_text: params[:final_text],
      edited_before_send: params[:edited_before_send],
      follow_up_count: params[:follow_up_count],
      message_id: params[:message_id]
    )

    render json: { ok: true, status: 'ok' }
  end

  private

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

    record_copilot_feedback_event(
      outcome: 'generated',
      copilot_action: copilot_action,
      request_id: request_id,
      generated_text: result[:message]
    )
  end

  def build_task_response(result, request_id)
    {
      message: result[:message],
      request_id: request_id,
      follow_up_context: result[:follow_up_context],
      captain_trace: result[:captain_trace].presence,
      suggestion_meta: result[:suggestion_meta].presence
    }.compact
  end

  def record_copilot_feedback_event(attributes = {})
    Llm::EventBus.publish('copilot.feedback', build_copilot_feedback_payload(attributes))
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][TasksController] Failed to record copilot feedback: #{e.class}: #{e.message}")
    nil
  end

  def build_copilot_feedback_payload(attrs)
    copilot_action = attrs[:copilot_action].to_s
    copilot_context_attributes(copilot_action, attrs[:outcome]).merge(
      request_id: attrs[:request_id].presence || SecureRandom.uuid,
      edited_before_send: cast_optional_boolean(attrs[:edited_before_send]),
      follow_up_count: cast_optional_integer(attrs[:follow_up_count]),
      generated_reply_preview: sanitize_preview(attrs[:generated_text]),
      final_reply_preview: sanitize_preview(attrs[:final_text]),
      message_id: cast_optional_integer(attrs[:message_id])
    )
  end

  def copilot_context_attributes(copilot_action, outcome)
    {
      feature: action_name == 'feedback' ? copilot_action : action_name,
      runtime_mode: 'captain_task',
      status: outcome,
      account_id: Current.account&.id,
      user_id: Current.user&.id,
      user_name: Current.user&.name,
      source: copilot_action.presence || 'copilot_ui',
      copilot_action: copilot_action,
      suggestion_outcome: outcome
    }.merge(copilot_conversation_attributes)
  end

  def copilot_conversation_attributes
    conv = resolved_conversation
    {
      conversation_id: conv&.id,
      conversation_display_id: conv&.display_id || params[:conversation_display_id],
      channel_type: conv&.inbox&.channel_type
    }
  end

  def cast_optional_integer(value)
    value.present? ? value.to_i : nil
  end

  def cast_optional_boolean(value)
    return if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def sanitize_preview(text)
    return if text.blank?

    Llm::Monitoring::PayloadSanitizer.call(text.to_s.strip.first(1000))
  end

  def resolved_conversation
    return @resolved_conversation if defined?(@resolved_conversation)

    display_id = params[:conversation_display_id].presence
    @resolved_conversation = Current.account.conversations.find_by(display_id: display_id) if display_id
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

    render json: { error: I18n.t('captain.text_improvement_disabled') }, status: :forbidden
  end
end

Api::V1::Accounts::Captain::TasksController.prepend_mod_with('Api::V1::Accounts::Captain::TasksController')
