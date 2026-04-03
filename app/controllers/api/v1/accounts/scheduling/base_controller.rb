class Api::V1::Accounts::Scheduling::BaseController < Api::V1::Accounts::BaseController
  before_action :ensure_scheduling_enabled!

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid
  rescue_from ActiveRecord::RecordNotUnique, with: :render_record_not_unique
  rescue_from ActionController::ParameterMissing, with: :render_unprocessable_entity
  rescue_from ArgumentError, with: :render_unprocessable_entity
  rescue_from ::Crm::Error, with: :render_crm_error
  rescue_from Scheduling::Error, with: :render_scheduling_error

  private

  def ensure_finance_enabled!
    return if Current.account.feature_enabled?('scheduling_finance')

    raise Scheduling::Error.new(
      code: 'FEATURE_DISABLED',
      message: 'Scheduling finance is not enabled for this account',
      status: :forbidden
    )
  end

  def ensure_scheduling_enabled!
    return if Current.account.feature_enabled?('scheduling')

    raise Scheduling::Error.new(
      code: 'FEATURE_DISABLED',
      message: 'Scheduling is not enabled for this account',
      status: :forbidden
    )
  end

  def parse_boolean(value, default: false)
    return default if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def parse_csv_ids(value)
    Array(value.to_s.split(',')).map(&:strip).reject(&:blank?)
  end

  def parse_datetime_param!(value, field_name:, required: true)
    if value.blank?
      raise ArgumentError, "#{field_name} is required" if required

      return nil
    end

    parsed = Time.zone.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a valid datetime" if parsed.blank?

    parsed
  end

  def custom_attribute_filters_param
    raw_filters = params[:custom_attribute_filters]
    return {} if raw_filters.blank?

    case raw_filters
    when ActionController::Parameters
      raw_filters.to_unsafe_h
    when Hash
      raw_filters
    else
      {}
    end
  end

  def render_error(code:, error:, status:, details: nil)
    body = {
      error: error,
      code: code
    }
    body[:details] = details if details.present?

    render json: body, status: status
  end

  def render_not_found(error)
    render_error(
      code: not_found_code(error),
      error: error.message,
      status: :not_found
    )
  end

  def render_payload(payload, status: :ok, meta: nil)
    body = { payload: payload }
    body[:meta] = meta if meta.present?
    render json: body, status: status
  end

  def render_record_invalid(error)
    code, status = validation_error_metadata_for(error.record)

    render_error(
      code: code,
      error: error.record.errors.full_messages.to_sentence,
      details: error.record.errors.to_hash(true),
      status: status
    )
  end

  def render_record_not_unique(error)
    constraint = record_not_unique_constraint(error)
    code = case constraint
           when /external_ref/
             'DUPLICATE_EXTERNAL_REF'
           when /idempotency_key/
             'DUPLICATE_IDEMPOTENCY_KEY'
           else
             'VALIDATION_ERROR'
           end

    render_error(
      code: code,
      error: code == 'VALIDATION_ERROR' ? error.message : conflict_message_for(code),
      status: code == 'VALIDATION_ERROR' ? :unprocessable_content : :conflict
    )
  end

  def render_scheduling_error(error)
    render_error(code: error.code, error: error.message, details: error.details, status: error.status)
  end

  def render_crm_error(error)
    render_error(code: error.code, error: error.message, details: error.details, status: error.status)
  end

  def render_unprocessable_entity(error)
    render_error(code: 'VALIDATION_ERROR', error: error.message, status: :unprocessable_content)
  end

  def conflict_message_for(code)
    case code
    when 'DUPLICATE_EXTERNAL_REF'
      'external_ref must be unique within account'
    when 'DUPLICATE_IDEMPOTENCY_KEY'
      'idempotency_key must be unique within account'
    else
      'Conflict'
    end
  end

  def duplicate_error?(record, attribute)
    record.errors.details.fetch(attribute, []).any? { |detail| detail[:error] == :taken } ||
      (
        record.errors.attribute_names.include?(attribute) &&
        record.errors[attribute].any? { |message| message.to_s.match?(/taken|unique/i) }
      )
  end

  def not_found_code(error)
    message = error.message.to_s
    return 'APPOINTMENT_NOT_FOUND' if controller_name.in?(%w[appointments appointment_payments]) || message.include?('Scheduling::Appointment')
    return 'EXPENSE_NOT_FOUND' if controller_name == 'expenses' || message.include?('Scheduling::Expense')

    'NOT_FOUND'
  end

  def record_not_unique_constraint(error)
    error.cause.respond_to?(:constraint) ? error.cause.constraint.to_s : error.message.to_s
  end

  def validation_error_metadata_for(record)
    return ['DUPLICATE_EXTERNAL_REF', :conflict] if duplicate_error?(record, :external_ref)
    return ['DUPLICATE_IDEMPOTENCY_KEY', :conflict] if duplicate_error?(record, :idempotency_key)

    ['VALIDATION_ERROR', :unprocessable_content]
  end
end
