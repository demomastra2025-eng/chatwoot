module LeadForms
  class PayloadBuilder
    class << self
      def form(lead_form)
        {
          id: lead_form.id,
          name: lead_form.name,
          description: lead_form.description,
          source_kind: lead_form.source_kind,
          status: lead_form.status,
          external_ref: lead_form.external_ref,
          public_token: lead_form.public_token,
          inbox_id: lead_form.inbox_id,
          inbox_name: lead_form.inbox&.name,
          field_schema: lead_form.field_schema,
          settings: lead_form.settings,
          created_at: lead_form.created_at&.iso8601,
          updated_at: lead_form.updated_at&.iso8601
        }
      end

      def submission(submission)
        {
          id: submission.id,
          lead_form_id: submission.lead_form_id,
          lead_form_name: submission.lead_form&.name,
          inbox_id: submission.inbox_id,
          source_kind: submission.source_kind,
          status: submission.status,
          external_ref: submission.external_ref,
          idempotency_key: submission.idempotency_key,
          field_values: submission.field_values,
          utm: submission.utm,
          payload: submission.payload,
          processing_errors: submission.processing_errors,
          contact_id: submission.contact_id,
          contact_name: submission.contact&.name,
          conversation_id: submission.conversation&.display_id,
          conversation_internal_id: submission.conversation_id,
          crm_deal_id: submission.crm_deal_id,
          processed_at: submission.processed_at&.iso8601,
          created_at: submission.created_at&.iso8601,
          updated_at: submission.updated_at&.iso8601
        }
      end
    end
  end
end
