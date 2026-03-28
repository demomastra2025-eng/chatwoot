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

    config.excluded_exceptions += ['Rack::Timeout::RequestTimeoutException']

    # to track post data in sentry
    config.send_default_pii = true unless disable_pii
  end
end
