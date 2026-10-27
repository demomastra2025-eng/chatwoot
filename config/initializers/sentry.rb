if ENV['SENTRY_DSN'].present?
  Sentry.init do |config|
    enable_transactions = ActiveModel::Type::Boolean.new.cast(ENV['ENABLE_SENTRY_TRANSACTIONS'])
    disable_pii = ActiveModel::Type::Boolean.new.cast(ENV['DISABLE_SENTRY_PII'])

    config.dsn = ENV['SENTRY_DSN']
    config.enabled_environments = %w[staging production]
    config.release = GIT_HASH if defined?(GIT_HASH)

    # To activate performance monitoring, set one of these options.
    # We recommend adjusting the value in production:
    config.traces_sample_rate = ENV.fetch('SENTRY_TRACES_SAMPLE_RATE', 0.1).to_f if enable_transactions

    config.excluded_exceptions += ['Rack::Timeout::RequestTimeoutException', 'MutexApplicationJob::LockAcquisitionError']

    # to track post data in sentry
    config.send_default_pii = true unless disable_pii

    # Indexed patient lookups carry an IIN, phone or name in the provider URL.
    # Drop those outbound HTTP records rather than retaining their query strings.
    patient_lookup_path = '/doctor/v1/patients'
    config.before_breadcrumb = lambda do |breadcrumb, _hint|
      values = [breadcrumb.message, *breadcrumb.data.to_h.values]
      breadcrumb unless values.any? { |value| value.to_s.include?(patient_lookup_path) }
    end
    config.before_send_transaction = lambda do |event, _hint|
      event.spans.reject! do |span|
        values = [span[:description], span['description'], *span.fetch(:data, {}).to_h.values, *span.fetch('data', {}).to_h.values]
        values.any? { |value| value.to_s.include?(patient_lookup_path) }
      end
      event
    end
  end
end
