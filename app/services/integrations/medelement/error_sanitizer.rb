class Integrations::Medelement::ErrorSanitizer
  EMAIL_PATTERN = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i
  PHONE_OR_IDENTIFIER_PATTERN = /\+?\d[\d\s().-]{5,}\d/
  TOKEN_PATTERN = /\b[A-Za-z0-9_-]{24,}\b/
  MAX_MESSAGE_LENGTH = 500

  class << self
    def digest(value)
      OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, value.to_s)
    end

    def exception_payload(error)
      {
        code: error.class.name.to_s.underscore.tr('/', '.'),
        message: public_message(error),
        status: error.respond_to?(:status) ? error.status : nil
      }.compact
    end

    def sanitize(value)
      value.to_s
           .gsub(EMAIL_PATTERN, '[redacted]')
           .gsub(PHONE_OR_IDENTIFIER_PATTERN, '[redacted]')
           .gsub(TOKEN_PATTERN, '[redacted]')
           .truncate(MAX_MESSAGE_LENGTH)
    end

    def sanitize_details(details)
      details.to_h.each_with_object({}) do |(key, value), result|
        result[key.to_s] = sanitize_detail_value(value)
      end
    end

    private

    def public_message(error)
      class_name = error.class.name.to_s
      return "Provider request failed#{http_status_suffix(error)}" if class_name == 'Integrations::Medelement::Client::ApiError'
      return 'Provider returned an incomplete snapshot' if class_name.end_with?('IncompleteSnapshotError')
      return 'Another MedElement synchronization is still running' if class_name.end_with?('LockAcquisitionError')
      return 'MedElement synchronization is unavailable' if class_name.end_with?('SyncUnavailableError')

      'MedElement synchronization failed'
    end

    def http_status_suffix(error)
      error.respond_to?(:status) && error.status.present? ? " (HTTP #{error.status})" : ''
    end

    def sanitize_detail_value(value)
      case value
      when Hash
        sanitize_details(value)
      when Array
        value.first(20).map { |item| sanitize_detail_value(item) }
      when Numeric, TrueClass, FalseClass, NilClass
        value
      else
        sanitize(value)
      end
    end
  end
end
