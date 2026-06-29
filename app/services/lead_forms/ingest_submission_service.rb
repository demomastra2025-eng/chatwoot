module LeadForms
  class IngestSubmissionService
    REDACTED_KEY_PATTERN = /(token|secret|password|authorization|access_key|api_key)/i
    EMAIL_KEYS = %w[email email_address emailAddress].freeze
    PHONE_KEYS = %w[phone phone_number phoneNumber mobile].freeze
    NAME_KEYS = %w[name full_name fullName].freeze
    IDENTIFIER_KEYS = %w[identifier external_id externalId].freeze
    UTM_KEYS = %w[utm_source utm_medium utm_campaign utm_content utm_term gclid fbclid yclid].freeze

    attr_reader :lead_form, :params

    def initialize(lead_form:, params:)
      @lead_form = lead_form
      @params = normalize_params(params)
    end

    def perform
      raise ArgumentError, 'lead form is not active' unless lead_form.active?
      raise ArgumentError, 'lead form inbox is required' if lead_form.inbox.blank?

      submission = existing_submission
      return submission if submission&.processed?

      validate_required_fields!
      submission ||= build_submission
      refresh_submission_payload!(submission) unless submission.new_record?
      process_submission!(submission)
    rescue StandardError => e
      mark_failed!(submission, e) if defined?(submission) && submission&.persisted?
      raise
    end

    private

    def account
      lead_form.account
    end

    def build_submission
      lead_form.lead_submissions.new(
        account: account,
        inbox: lead_form.inbox,
        source_kind: lead_form.source_kind,
        status: 'received',
        external_ref: external_ref,
        idempotency_key: idempotency_key,
        field_values: field_values,
        utm: utm_values,
        payload: redacted_payload
      )
    end

    def contact_attributes
      explicit_contact = params.fetch('contact', {}).to_h
      attributes = {
        name: pick_value(explicit_contact, *NAME_KEYS) || pick_value(field_values, *NAME_KEYS) || composed_name,
        email: pick_value(explicit_contact, *EMAIL_KEYS) || pick_value(field_values, *EMAIL_KEYS),
        phone_number: pick_value(explicit_contact, *PHONE_KEYS) || pick_value(field_values, *PHONE_KEYS),
        identifier: pick_value(explicit_contact, *IDENTIFIER_KEYS) || pick_value(field_values, *IDENTIFIER_KEYS),
        additional_attributes: {
          lead_form_id: lead_form.id,
          lead_form_source: lead_form.source_kind,
          lead_submission_external_ref: external_ref
        }.compact,
        custom_attributes: params.fetch('contact_custom_attributes', {}).to_h
      }.compact

      attributes[:additional_attributes][:lead_fields] = field_values if field_values.present?
      attributes
    end

    def composed_name
      first_name = field_values['first_name'] || field_values['firstName']
      last_name = field_values['last_name'] || field_values['lastName']
      [first_name, last_name].compact_blank.join(' ').presence
    end

    def create_contact_inbox!
      ::ContactInboxWithContactBuilder.new(
        inbox: lead_form.inbox,
        source_id: contact_source_id,
        contact_attributes: contact_attributes,
        skip_runtime_events: true
      ).perform
    end

    def create_conversation!(submission, contact_inbox)
      conversation = account.conversations.new(
        inbox: lead_form.inbox,
        contact: contact_inbox.contact,
        contact_inbox: contact_inbox,
        status: conversation_status,
        additional_attributes: {
          source: 'lead_form',
          lead_form_id: lead_form.id,
          lead_submission_id: submission.id,
          lead_source_kind: lead_form.source_kind,
          referer_url: params['referer_url'],
          landing_url: params['landing_url']
        }.compact,
        custom_attributes: lead_form.settings.to_h.fetch('conversation_custom_attributes', {})
      )
      conversation.skip_runtime_events = true
      conversation.save!
      conversation
    end

    def create_deal!(submission, conversation)
      return unless account.feature_enabled?('crm_deals')

      ::Crm::Bootstrap::AccountService.new(account: account).perform
      reference = "lead_submission:#{submission.id}"
      existing = account.crm_deals.find_by(idempotency_key: reference) || account.crm_deals.find_by(external_ref: reference)
      return existing if existing.present?

      ::Crm::Deals::UpsertService.new(
        account: account,
        params: {
          title: deal_title,
          description: deal_description,
          originating_conversation_id: conversation.id,
          contact_ids: [conversation.contact_id],
          primary_contact_id: conversation.contact_id,
          external_ref: reference,
          idempotency_key: reference
        },
        actor: nil
      ).perform
    end

    def create_message!(submission, conversation)
      conversation.messages.create!(
        account: account,
        inbox: lead_form.inbox,
        sender: conversation.contact,
        message_type: :incoming,
        content_type: :text,
        content: message_content,
        source_id: "lead_submission:#{submission.id}",
        additional_attributes: {
          lead_form_id: lead_form.id,
          lead_submission_id: submission.id,
          lead_source_kind: lead_form.source_kind,
          external_ref: submission.external_ref
        }.compact
      )
    end

    def conversation_status
      status = lead_form.settings.to_h['conversation_status'].presence || 'open'
      Conversation.statuses.key?(status) ? status : 'open'
    end

    def contact_source_id
      raw = idempotency_key.presence || external_ref.presence || field_values.to_json
      digest = Digest::SHA256.hexdigest(raw.to_s)[0, 24]
      "lead_form:#{lead_form.id}:#{digest}"
    end

    def deal_description
      [
        "Source: #{lead_form.source_kind}",
        "Form: #{lead_form.name}",
        params['landing_url'].present? ? "Landing: #{params['landing_url']}" : nil,
        params['referer_url'].present? ? "Referer: #{params['referer_url']}" : nil,
        field_values.map { |key, value| "#{key}: #{value}" }
      ].flatten.compact.join("\n")
    end

    def deal_title
      name = pick_value(field_values, *NAME_KEYS) || composed_name
      phone = pick_value(field_values, *PHONE_KEYS)
      suffix = [name, phone].compact_blank.first
      ['Заявка', suffix, lead_form.name].compact_blank.join(' · ')
    end

    def existing_submission
      return lead_form.lead_submissions.find_by(external_ref: external_ref) if external_ref.present?
      return lead_form.lead_submissions.find_by(idempotency_key: idempotency_key) if idempotency_key.present?
    end

    def external_ref
      params['external_ref'].presence || params['leadgen_id'].presence || params['id'].presence
    end

    def field_values
      @field_values ||= begin
        raw = params['field_values'].presence || params['fields'].presence || params['data'].presence || {}
        raw = raw.to_h if raw.respond_to?(:to_h)
        raw.deep_stringify_keys
      end
    end

    def idempotency_key
      params['idempotency_key'].presence
    end

    def mark_failed!(submission, error)
      submission.update_columns(
        status: 'failed',
        processing_errors: {
          'class' => error.class.name,
          'message' => error.message.to_s.first(500)
        },
        updated_at: Time.current
      )
    end

    def message_content
      lines = ["Новая заявка: #{lead_form.name}"]
      lines << "Источник: #{lead_form.source_kind}"
      lines << "Страница: #{params['landing_url']}" if params['landing_url'].present?
      lines << "Referer: #{params['referer_url']}" if params['referer_url'].present?
      lines << '' if field_values.present?
      field_values.each { |key, value| lines << "#{key}: #{value}" }
      lines.join("\n")
    end

    def normalize_params(raw_params)
      raw_params = raw_params.to_unsafe_h if raw_params.respond_to?(:to_unsafe_h)
      raw_params.to_h.deep_stringify_keys
    end

    def pick_value(source, *keys)
      keys.each do |key|
        value = source[key]
        return value.to_s.strip if value.present?
      end
      nil
    end

    def process_submission!(submission)
      ApplicationRecord.transaction do
        submission.save! if submission.new_record?
        contact_inbox = submission.contact_inbox || create_contact_inbox!
        conversation = submission.conversation || create_conversation!(submission, contact_inbox)
        create_message!(submission, conversation) if conversation.messages.where(source_id: "lead_submission:#{submission.id}").blank?
        deal = submission.crm_deal || create_deal!(submission, conversation)

        submission.update!(
          contact: contact_inbox.contact,
          contact_inbox: contact_inbox,
          inbox: lead_form.inbox,
          conversation: conversation,
          crm_deal: deal,
          status: 'processed',
          processing_errors: {},
          processed_at: Time.current
        )
        submission
      end
    end

    def refresh_submission_payload!(submission)
      submission.assign_attributes(
        inbox: lead_form.inbox,
        source_kind: lead_form.source_kind,
        field_values: field_values,
        utm: utm_values,
        payload: redacted_payload,
        processing_errors: {}
      )
    end

    def redacted_payload
      redact(params)
    end

    def redact(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key] = key.to_s.match?(REDACTED_KEY_PATTERN) ? '[REDACTED]' : redact(item)
        end
      when Array
        value.map { |item| redact(item) }
      else
        value
      end
    end

    def utm_values
      params.slice(*UTM_KEYS).compact_blank
    end

    def required_schema_fields
      Array.wrap(lead_form.field_schema).select do |field|
        ActiveModel::Type::Boolean.new.cast(field.to_h['required'])
      end
    end

    def submitted_field_value(field_name)
      key = field_name.to_s
      candidates = [key, key.underscore, key.camelize(:lower)].uniq
      candidates.filter_map { |candidate| field_values[candidate] }.find(&:present?)
    end

    def validate_required_fields!
      missing_fields = required_schema_fields.filter_map do |field|
        name = field.to_h['name'].to_s
        next if submitted_field_value(name).present?

        field.to_h['label'].presence || name
      end

      return if missing_fields.blank?

      raise ArgumentError, "Missing required form fields: #{missing_fields.join(', ')}"
    end
  end
end
