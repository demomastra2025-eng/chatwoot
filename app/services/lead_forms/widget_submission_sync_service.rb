module LeadForms
  class WidgetSubmissionSyncService
    PHONE_KEYS = %w[phone phone_number phoneNumber mobile].freeze

    attr_reader :conversation, :params

    def initialize(conversation:, params: {})
      @conversation = conversation
      @params = normalize_params(params)
    end

    def perform
      return unless widget_pre_chat_conversation?
      return if lead_form.blank?
      return if lead_phone_number.blank?

      submission = lead_form.lead_submissions.find_or_initialize_by(idempotency_key: idempotency_key)
      return submission if submission.processed?

      submission.assign_attributes(submission_attributes)
      submission.save!
      create_message!(submission)
      submission
    rescue StandardError => e
      Rails.logger.warn("Widget lead submission sync failed: #{e.class}: #{e.message}")
      nil
    end

    private

    def account
      conversation.account
    end

    def create_message!(submission)
      return if conversation.messages.exists?(source_id: "lead_submission:#{submission.id}")

      conversation.messages.create!(
        account: account,
        inbox: conversation.inbox,
        sender: conversation.contact,
        message_type: :incoming,
        content_type: :form,
        content: "Новая заявка: #{lead_form.name}",
        content_attributes: {
          items: form_items,
          submitted_values: submitted_values
        },
        source_id: "lead_submission:#{submission.id}",
        additional_attributes: {
          lead_form_id: lead_form.id,
          lead_submission_id: submission.id,
          lead_source_kind: 'widget',
          external_ref: submission.external_ref
        }.compact
      )
    end

    def custom_attributes
      @custom_attributes ||= params.fetch('custom_attributes', {}).to_h.deep_stringify_keys.compact_blank
    end

    def external_ref
      "widget_conversation:#{conversation.id}"
    end

    def form_items
      schema_by_name = Array.wrap(lead_form.field_schema).each_with_object({}) do |field, result|
        field = field.to_h
        result[field['name'].to_s] = field if field['name'].present?
      end

      custom_attributes.keys.map do |name|
        schema = schema_by_name[name] || schema_by_name[name.underscore] || schema_by_name[name.camelize(:lower)] || {}
        {
          name: name,
          label: schema['label'].presence || name.to_s.humanize,
          type: schema['type'].presence || 'text'
        }
      end
    end

    def idempotency_key
      external_ref
    end

    def lead_form
      @lead_form ||= account.lead_forms.active.find_by(source_kind: 'widget', inbox_id: conversation.inbox_id)
    end

    def lead_phone_number
      PHONE_KEYS.filter_map { |key| custom_attributes[key].presence }.first
    end

    def normalize_params(raw_params)
      raw_params = raw_params.to_unsafe_h if raw_params.respond_to?(:to_unsafe_h)
      raw_params.to_h.deep_stringify_keys
    end

    def payload
      {
        'conversation_id' => conversation.id,
        'contact_inbox_id' => conversation.contact_inbox_id,
        'custom_attributes' => custom_attributes
      }.compact
    end

    def submitted_values
      custom_attributes.map do |name, value|
        {
          name: name,
          title: value,
          value: value
        }
      end
    end

    def submission_attributes
      {
        account: account,
        inbox: conversation.inbox,
        source_kind: 'widget',
        status: 'processed',
        external_ref: external_ref,
        field_values: custom_attributes,
        payload: payload,
        contact: conversation.contact,
        contact_inbox: conversation.contact_inbox,
        conversation: conversation,
        processing_errors: {},
        processed_at: Time.current
      }
    end

    def widget_pre_chat_conversation?
      conversation.inbox&.channel_type == 'Channel::WebWidget' &&
        conversation.inbox.channel.pre_chat_form_enabled?
    end
  end
end
