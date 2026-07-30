# frozen_string_literal: true

class Captain::CustomToolHttpOptionsNormalizer
  def initialize(options, defaults: Concerns::CaptainCustomToolHttpOptions::DEFAULTS)
    @options = options.respond_to?(:to_h) ? options.to_h.deep_stringify_keys : {}
    @defaults = defaults
  end

  def call
    {
      'timeout' => timeout_options,
      'retry' => retry_options,
      'redirects' => redirect_options,
      'idempotency' => idempotency_options,
      'pagination' => pagination_options,
      'batching' => batching_options
    }
  end

  private

  attr_reader :options, :defaults

  def timeout_options
    source = section('timeout')
    {
      'open_seconds' => integer('timeout', 'open_seconds', source),
      'read_seconds' => integer('timeout', 'read_seconds', source)
    }
  end

  def retry_options
    source = section('retry')
    {
      'enabled' => boolean('retry', source),
      'max_attempts' => integer('retry', 'max_attempts', source),
      'backoff_ms' => integer('retry', 'backoff_ms', source),
      'statuses' => statuses(source['statuses'])
    }
  end

  def redirect_options
    source = section('redirects')
    {
      'enabled' => boolean('redirects', source),
      'max_redirects' => integer('redirects', 'max_redirects', source)
    }
  end

  def idempotency_options
    source = section('idempotency')
    { 'enabled' => boolean('idempotency', source) }
  end

  def pagination_options
    source = section('pagination')
    {
      'enabled' => boolean('pagination', source),
      'mode' => string('pagination', 'mode', source),
      'parameter_name' => string('pagination', 'parameter_name', source),
      'start_page' => integer('pagination', 'start_page', source),
      'max_pages' => integer('pagination', 'max_pages', source),
      'interval_ms' => integer('pagination', 'interval_ms', source),
      'items_path' => optional_string(source['items_path']),
      'next_url_path' => optional_string(source['next_url_path'])
    }
  end

  def batching_options
    source = section('batching')
    {
      'enabled' => boolean('batching', source),
      'items_parameter' => optional_string(source['items_parameter']),
      'batch_size' => integer('batching', 'batch_size', source),
      'interval_ms' => integer('batching', 'interval_ms', source)
    }
  end

  def section(name)
    value = options[name]
    value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
  end

  def integer(section_name, key, source)
    value = source[key]
    return defaults.dig(section_name, key) if value.nil? || value == ''

    Integer(value)
  rescue ArgumentError, TypeError
    value
  end

  def boolean(section_name, source)
    value = source['enabled']
    return defaults.dig(section_name, 'enabled') if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def string(section_name, key, source)
    optional_string(source[key]) || defaults.dig(section_name, key)
  end

  def optional_string(value)
    value.to_s.strip.presence
  end

  def statuses(value)
    values = value.nil? ? defaults.dig('retry', 'statuses') : Array(value)
    values.map { |status| normalize_status(status) }.uniq
  end

  def normalize_status(value)
    Integer(value)
  rescue ArgumentError, TypeError
    value
  end
end
