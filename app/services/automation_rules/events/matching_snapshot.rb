class AutomationRules::Events::MatchingSnapshot
  VERSION = 1

  class << self
    def for(record)
      case record
      when Conversation
        conversation(record)
      when Message
        conversation(record.conversation, trigger_message: record)
      when Scheduling::Appointment
        envelope('appointment', record.automation_webhook_data)
      else
        raise ArgumentError, "Unsupported Automation event subject: #{record.class.base_class.name}"
      end
    end

    def for_crm(record)
      return unless record.respond_to?(:automation_webhook_data)

      envelope(record.class.base_class.name.underscore, record.automation_webhook_data)
    end

    private

    def conversation(record, trigger_message: nil)
      envelope(
        'conversation',
        {
          conversation: record.attributes,
          contact: record.contact&.attributes,
          labels: record.cached_label_list_array,
          messages: record.messages.order(:id).map(&:attributes),
          trigger_message: trigger_message&.attributes
        }
      )
    end

    def envelope(kind, payload)
      {
        snapshot_version: VERSION,
        matcher_kind: kind,
        matcher_data: payload
      }
    end
  end
end
