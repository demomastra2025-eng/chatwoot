# frozen_string_literal: true

class Captain::CustomToolHttpOptionsValidator
  def initialize(tool)
    @tool = tool
    @options = tool.http_options
  end

  def call
    validate_integer('timeout', 'open_seconds', 1..30)
    validate_integer('timeout', 'read_seconds', 1..120)
    validate_integer('retry', 'max_attempts', 1..3)
    validate_integer('retry', 'backoff_ms', 0..2000)
    validate_retry_statuses
    validate_integer('redirects', 'max_redirects', 1..5)
    validate_pagination
    validate_batching
    validate_mutating_retry
  end

  private

  attr_reader :tool, :options

  delegate :errors, :http_method, :parameter_definitions, to: :tool

  def validate_integer(section, key, range)
    value = options.dig(section, key)
    return if value.is_a?(Integer) && range.cover?(value)

    errors.add(:http_options, "#{section}.#{key} must be an integer between #{range.begin} and #{range.end}")
  end

  def validate_retry_statuses
    statuses = options.dig('retry', 'statuses')
    allowed = Concerns::CaptainCustomToolHttpOptions::RETRYABLE_HTTP_STATUSES
    return if statuses.is_a?(Array) && statuses.present? && statuses.all? { |status| status.is_a?(Integer) && allowed.include?(status) }

    errors.add(:http_options, "retry.statuses must contain only: #{allowed.join(', ')}")
  end

  def validate_pagination
    pagination = options['pagination']
    return unless pagination['enabled']

    validate_pagination_compatibility
    validate_pagination_limits
    validate_optional_path('pagination.items_path', pagination['items_path'])
    validate_pagination_mode(pagination)
  end

  def validate_pagination_compatibility
    errors.add(:http_options, 'pagination is only supported for GET tools') unless http_method.to_s == 'GET'
    errors.add(:http_options, 'pagination and batching cannot be enabled together') if options.dig('batching', 'enabled')
  end

  def validate_pagination_limits
    validate_integer('pagination', 'start_page', 0..1_000_000)
    validate_integer('pagination', 'max_pages', 1..25)
    validate_integer('pagination', 'interval_ms', 0..5000)
  end

  def validate_pagination_mode(pagination)
    allowed = Concerns::CaptainCustomToolHttpOptions::PAGINATION_MODES
    errors.add(:http_options, 'pagination.mode is invalid') unless allowed.include?(pagination['mode'])

    if pagination['mode'] == 'page_parameter'
      validate_page_parameter(pagination['parameter_name'])
    elsif pagination['mode'] == 'next_url'
      validate_next_url_path(pagination['next_url_path'])
    end
  end

  def validate_page_parameter(parameter_name)
    format = Concerns::CaptainCustomToolHttpOptions::QUERY_PARAMETER_FORMAT
    errors.add(:http_options, 'pagination.parameter_name is invalid') unless parameter_name.to_s.match?(format)
  end

  def validate_next_url_path(path)
    if path.blank?
      errors.add(:http_options, 'pagination.next_url_path is required for next URL mode')
    else
      validate_optional_path('pagination.next_url_path', path)
    end
  end

  def validate_batching
    batching = options['batching']
    return unless batching['enabled']

    validate_integer('batching', 'batch_size', 1..100)
    validate_integer('batching', 'interval_ms', 0..5000)
    validate_batch_parameter(batching['items_parameter'])
  end

  def validate_batch_parameter(parameter_name)
    definition = parameter_definitions.find { |item| item['name'] == parameter_name }
    return if definition && definition['type'] == 'array' && definition['source'] == tool.class::PARAM_SOURCE_AGENT

    errors.add(:http_options, 'batching.items_parameter must reference an agent array parameter')
  end

  def validate_mutating_retry
    return unless options.dig('retry', 'enabled')
    return if tool.class::SAFE_READ_ONLY_HTTP_METHODS.include?(http_method.to_s)
    return if options.dig('idempotency', 'enabled')

    errors.add(:http_options, 'idempotency must be enabled before retrying a mutating request')
  end

  def validate_optional_path(field_name, value)
    format = Concerns::CaptainCustomToolHttpOptions::PATH_FORMAT
    return if value.blank? || value.match?(format)

    errors.add(:http_options, "#{field_name} is invalid")
  end
end
