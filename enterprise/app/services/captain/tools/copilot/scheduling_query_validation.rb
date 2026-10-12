# Error codes at the scheduling tool boundary let the model correct inputs without confusing
# an invalid range or unknown service with a provider outage or a server failure.
module Captain::Tools::Copilot::SchedulingQueryValidation
  # Codes that are failures of the system or of the provider, whatever status they carry.
  TECHNICAL_SCHEDULING_CODES = %w[INTERNAL_FAILURE PROVIDER_UNAVAILABLE MEDELEMENT_AVAILABILITY_UNVERIFIED].freeze

  private

  def scheduling_datetime(value, field_name:)
    Scheduling::InputValidation.datetime(value, field_name: field_name)
  end

  def scheduling_range!(range_from, range_to)
    Scheduling::RangeValidator.validate!(from: range_from, to: range_to, max_days: Scheduling::RangeValidator::MAX_RANGE_DAYS)
  rescue ArgumentError => e
    raise Scheduling::Error.new(code: 'INVALID_DATE_RANGE', message: e.message, status: :unprocessable_content,
                                details: { reason: 'invalid_date_range', max_range_days: Scheduling::RangeValidator::MAX_RANGE_DAYS })
  end

  def scheduling_service_id(value)
    normalized = optional_positive_id(value)
    return normalized if normalized || value.blank?
    return nil if Scheduling::IntegerNumericNormalizer.normalize(value, field_name: 'service_id') <= 0

    invalid_service_id!
  rescue ArgumentError
    invalid_service_id!
  end

  def invalid_service_id!
    raise Scheduling::Error.new(code: 'INVALID_SERVICE_ID', message: 'service_id must be an integer ID returned by the service catalog',
                                status: :unprocessable_content, details: { field: 'service_id', reason: 'invalid_service_id' })
  end

  def scheduling_resource_ids(value)
    parse_id_list(value, field_name: 'resource_ids')
  rescue ArgumentError => e
    raise Scheduling::Error.new(code: 'INVALID_RESOURCE_IDS', message: e.message, status: :unprocessable_content,
                                details: { field: 'resource_ids', reason: 'invalid_resource_ids' })
  end

  def scheduling_service!(service_id)
    return if service_id.blank?

    Scheduling::InputValidation.service!(account: account, value: service_id)
  end

  def scheduling_tool_failure(error)
    unless error.is_a?(Scheduling::Error)
      Rails.logger.warn("[CAPTAIN::SCHEDULING_QUERY] tool=#{self.class.name} error=#{error.class.name}")
      error = Scheduling::Error.new(code: 'INTERNAL_FAILURE', message: 'Scheduling could not be read because of an internal failure',
                                    status: :internal_server_error, details: { reason: 'internal_failure' })
    end
    Captain::ToolResult.failure_output(
      error: error.message, retryable: false,
      data: { code: error.code, reason: error.details.to_h[:reason], details: error.details, error_class: scheduling_error_class(error) }.compact
    )
  end

  # Declares what the agent runtime must do with the failure (see Captain::Runtime::ToolFailure): a failure of the server or of
  # the provider is technical and hands the conversation to staff; everything the model can answer or correct is a business
  # outcome: a resource, a service or a range that does not exist or is not allowed, a malformed id. The declaration wins over
  # any inference from the shape of the result.
  def scheduling_error_class(error)
    technical = error.status.to_i >= 500 || TECHNICAL_SCHEDULING_CODES.include?(error.code.to_s)
    technical ? Captain::Runtime::ToolFailure::TECHNICAL : Captain::Runtime::ToolFailure::BUSINESS
  end
end
