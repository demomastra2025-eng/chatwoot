class Api::V1::Accounts::LeadForms::BaseController < Api::V1::Accounts::BaseController
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid
  rescue_from ActiveRecord::RecordNotUnique, with: :render_conflict
  rescue_from ActionController::ParameterMissing, with: :render_unprocessable_entity
  rescue_from ArgumentError, with: :render_unprocessable_entity
  rescue_from ::Crm::Error, with: :render_crm_error

  private

  def parse_boolean(value, default: false)
    return default if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def render_conflict(error)
    render_error(code: 'CONFLICT', error: error.message, status: :conflict)
  end

  def render_crm_error(error)
    render_error(code: error.code, error: error.message, details: error.details, status: error.status)
  end

  def render_error(code:, error:, status:, details: nil)
    body = { code: code, error: error }
    body[:details] = details if details.present?
    render json: body, status: status
  end

  def render_not_found(error)
    render_error(code: 'NOT_FOUND', error: error.message, status: :not_found)
  end

  def render_payload(payload, status: :ok, meta: nil)
    body = { payload: payload }
    body[:meta] = meta if meta.present?
    render json: body, status: status
  end

  def render_record_invalid(error)
    render_error(
      code: 'VALIDATION_ERROR',
      error: error.record.errors.full_messages.to_sentence,
      details: error.record.errors.to_hash(true),
      status: :unprocessable_content
    )
  end

  def render_unprocessable_entity(error)
    render_error(code: 'VALIDATION_ERROR', error: error.message, status: :unprocessable_content)
  end
end
