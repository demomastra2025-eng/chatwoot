module LeadForms
  class WidgetSubmissionSyncService
    attr_reader :conversation, :params

    def initialize(conversation:, params: {})
      @conversation = conversation
      @params = normalize_params(params)
    end

    def perform
      return unless widget_pre_chat_conversation?
      return if lead_form.blank?

      submission = lead_form.lead_submissions.find_or_initialize_by(idempotency_key: idempotency_key)
      return submission if submission.processed?

      submission.assign_attributes(submission_attributes)
      submission.save!
      submission
    rescue StandardError => e
      Rails.logger.warn("Widget lead submission sync failed: #{e.class}: #{e.message}")
      nil
    end

    private

    def account
      conversation.account
    end

    def crm_deal
      return unless account.feature_enabled?('crm_deals')

      existing = account.crm_deals.find_by(originating_conversation_id: conversation.id) ||
                 account.crm_deals.find_by(external_ref: external_ref) ||
                 account.crm_deals.find_by(idempotency_key: external_ref)
      return existing if existing.present?

      ::Crm::Bootstrap::AccountService.new(account: account).perform
      ::Crm::Deals::UpsertService.new(
        account: account,
        params: {
          title: deal_title,
          description: deal_description,
          originating_conversation_id: conversation.id,
          contact_ids: [conversation.contact_id],
          primary_contact_id: conversation.contact_id,
          external_ref: external_ref,
          idempotency_key: external_ref
        },
        actor: nil
      ).perform
    end

    def custom_attributes
      @custom_attributes ||= params.fetch('custom_attributes', {}).to_h.deep_stringify_keys.compact_blank
    end

    def deal_description
      [
        "Source: #{lead_form.source_kind}",
        "Form: #{lead_form.name}",
        custom_attributes.map { |key, value| "#{key}: #{value}" }
      ].flatten.compact.join("\n")
    end

    def deal_title
      name = custom_attributes['fullName'] || custom_attributes['full_name'] || conversation.contact&.name
      ['Заявка', name, lead_form.name].compact_blank.join(' · ')
    end

    def external_ref
      "widget_conversation:#{conversation.id}"
    end

    def idempotency_key
      external_ref
    end

    def lead_form
      @lead_form ||= account.lead_forms.active.find_by(source_kind: 'widget', inbox_id: conversation.inbox_id)
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
        crm_deal: crm_deal,
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
