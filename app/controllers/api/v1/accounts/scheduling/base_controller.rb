class Api::V1::Accounts::Scheduling::BaseController < Api::V1::Accounts::BaseController
  # An unencoded "+" in a query string reaches the server as a space, so "T10:00:00+05:00" arrives as "T10:00:00 05:00".
  # Without the repair the offset is dropped and the instant moves by five hours.
  SPACE_BEFORE_OFFSET = /\A(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?) (\d{2}:?\d{2})\z/

  before_action :ensure_scheduling_enabled!
  around_action :with_scheduling_actor

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid
  rescue_from ActiveRecord::RecordNotUnique, with: :render_record_not_unique
  rescue_from ActionController::ParameterMissing, with: :render_unprocessable_entity
  rescue_from ArgumentError, with: :render_unprocessable_entity
  rescue_from ::Crm::Error, with: :render_crm_error
  rescue_from Scheduling::Error, with: :render_scheduling_error

  private

  def with_scheduling_actor
    previous_actor = Current.executed_by
    Current.executed_by = Current.user if Current.user.present?
    yield
  ensure
    Current.executed_by = previous_actor
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

  def parse_id_list_param!(value, field_name:)
    Scheduling::IdListParamParser.parse(value, field_name: field_name)
  end

  # Time.zone.parse rolls a non-existent day (31 November) over to the next month, so a date or ISO 8601 datetime is
  # checked against the calendar first; the error is a 422 that names the field.
  def parse_datetime_param!(value, field_name:, required: true)
    if value.blank?
      raise ArgumentError, "#{field_name} is required" if required

      return nil
    end

    Scheduling::InputValidation.datetime(value.to_s.strip.sub(SPACE_BEFORE_OFFSET, '\1+\2'), field_name: field_name)
  end

  def ensure_ascending_range!(from, to)
    return if to > from

    raise Scheduling::Error.new(code: 'INVALID_DATE_RANGE', message: 'to must be greater than from', status: :unprocessable_content,
                                details: { field: 'to', reason: 'invalid_date_range' })
  end

  # Exactly YYYY-MM-DD: Date.iso8601 completes '2031-10' to 1 October and reads '31-10-14' as 2031-10-14.
  def parse_date_param!(value, field_name:)
    Scheduling::InputValidation.date(value, field_name: field_name)
  end

  # duration_min is documented as an integer from the minimum to the maximum appointment length; a smaller value is
  # rejected instead of being raised to the minimum when slots are built.
  def parse_duration_min_param!(value)
    return if value.blank?

    duration = Integer(value.to_s, 10, exception: false)
    allowed = Scheduling::Constants::MIN_DURATION_MINUTES..Scheduling::Constants::MAX_DURATION_MINUTES
    raise ArgumentError, "duration_min must be between #{allowed.min} and #{allowed.max}" unless duration && allowed.cover?(duration)

    duration
  end

  def normalize_integer_numeric_params!(attrs, *field_names)
    field_names.each do |field_name|
      next unless attrs.key?(field_name)

      attrs[field_name] = Scheduling::IntegerNumericNormalizer.normalize_or_zero(attrs[field_name], field_name: field_name)
    end

    attrs
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
    return 'APPOINTMENT_NOT_FOUND' if controller_name == 'appointments' || message.include?('Scheduling::Appointment')

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
