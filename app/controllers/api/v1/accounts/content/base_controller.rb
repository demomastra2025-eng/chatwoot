class Api::V1::Accounts::Content::BaseController < Api::V1::Accounts::BaseController
  before_action :ensure_content_enabled!
  before_action :check_authorization

  rescue_from ::Content::Postiz::Error, with: :render_postiz_error
  rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActionController::ParameterMissing, with: :render_parameter_missing

  private

  def ensure_content_enabled!
    return if Current.account.feature_enabled?('content')

    render_error(code: 'FEATURE_DISABLED', message: 'Content module is not enabled for this account', status: :forbidden)
  end

  def check_authorization
    authorize(:hook, :create?)
  end

  def postiz_hook
    @postiz_hook ||= Current.account.hooks.find_by!(app_id: 'postiz')
  end

  def enabled_postiz_hook
    hook = postiz_hook
    return hook if hook.enabled?

    raise ::Content::Postiz::Error.new(
      code: 'POSTIZ_CONNECTION_DISABLED',
      message: 'Postiz connection is disabled',
      status: :unprocessable_content
    )
  end

  def postiz_client
    @postiz_client ||= ::Content::Postiz::Client.new(
      api_key: enabled_postiz_hook.access_token
    )
  end

  def render_payload(payload, status: :ok, meta: nil)
    body = { payload: payload }
    body[:meta] = meta if meta.present?
    render json: body, status: status
  end

  def render_error(code:, message:, status:, details: nil)
    body = { error: message, code: code }
    body[:details] = details if details.present?
    render json: body, status: status
  end

  def render_postiz_error(error)
    render_error(code: error.code, message: error.message, details: error.details, status: error.status)
  end

  def render_record_invalid(error)
    render_error(
      code: 'VALIDATION_ERROR',
      message: error.record.errors.full_messages.to_sentence,
      details: error.record.errors.to_hash(true),
      status: :unprocessable_content
    )
  end

  def render_not_found(error)
    render_error(code: 'NOT_FOUND', message: error.message, status: :not_found)
  end

  def render_parameter_missing(error)
    render_error(code: 'VALIDATION_ERROR', message: error.message, status: :unprocessable_content)
  end

  def postiz_hook_payload(hook)
    return { connected: false, enabled: false, settings: {} } if hook.blank?

    {
      connected: hook.access_token.present?,
      enabled: hook.enabled?,
      id: hook.id,
      app_id: hook.app_id,
      settings: hook.settings || {},
      token_configured: hook.access_token.present?,
      updated_at: hook.updated_at
    }
  end
end
