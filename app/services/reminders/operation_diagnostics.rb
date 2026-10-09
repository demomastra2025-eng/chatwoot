class Reminders::OperationDiagnostics
  class << self
    def report(operation:, error:, record:, status: 'failed', touch: nil, persisted_touch: nil)
      begin
        payload = {
          event: 'reminder_operation_diagnostic',
          operation: operation.to_s,
          entity_type: record.class.name,
          record_label: record_label(record),
          touch_label: touch_label(persisted_touch || touch),
          status: status,
          touch_status: touch&.status,
          error_class: error.class.name,
          error_code: error_code(error)
        }

        Rails.logger.warn(payload.compact.to_json)
      rescue StandardError
        nil
      end
    end

    def record_label(record)
      keyed_label('reminder-record', record)
    end

    private

    def touch_label(touch)
      return unless touch.is_a?(Reminder) && touch.persisted?

      keyed_label('reminder-touch', touch)
    end

    def keyed_label(namespace, record)
      identity = [namespace, record.class.name, record.try(:account_id), record.id].join(':')
      OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, identity).first(24)
    end

    def error_code(error)
      return unless error.is_a?(ActiveRecord::RecordInvalid)

      invalid_record = error.record
      duplicate_only = invalid_record.is_a?(Reminder) && invalid_record.errors.details == {
        base: [{ error: Reminder::DUPLICATE_OPEN_TOUCH_ERROR }]
      }
      duplicate_only ? 'duplicate_open_touch' : 'record_invalid'
    end
  end
end
