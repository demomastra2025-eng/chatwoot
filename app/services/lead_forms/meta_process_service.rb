module LeadForms
  class MetaProcessService
    GRAPH_BASE_URI = 'https://graph.facebook.com'.freeze
    LEAD_FIELDS = %w[
      id
      created_time
      ad_id
      ad_name
      adset_id
      adset_name
      campaign_id
      campaign_name
      form_id
      field_data
      platform
    ].freeze
    REQUEST_TIMEOUT = 10

    attr_reader :payload

    def initialize(payload:)
      @payload = normalize_payload(payload)
    end

    def perform
      each_change do |change|
        lead_form = resolve_lead_form(change)
        next if lead_form.blank?

        enriched_change = enrich_change(lead_form, change)
        if field_values_for(enriched_change).blank?
          record_received_stub!(lead_form, enriched_change)
        else
          LeadForms::IngestSubmissionService.new(
            lead_form: lead_form,
            params: submission_params(enriched_change)
          ).perform
        end
      end
    end

    private

    def each_change
      Array(payload['entry']).each do |entry|
        Array(entry['changes']).each do |change|
          next unless change['field'].to_s == 'leadgen'

          yield change.fetch('value', {}).merge('entry_id' => entry['id'])
        end
      end
    end

    def enrich_change(lead_form, change)
      return change if field_values_for(change).present?

      fetched_payload = fetch_lead_details(lead_form, change)
      return change if fetched_payload.blank?

      change.merge(fetched_payload)
    end

    def fetch_lead_details(lead_form, change)
      lead_id = external_ref_for(change)
      access_token = access_token_for(lead_form)
      return {} if lead_id.blank? || access_token.blank?

      response = HTTParty.get(
        "#{GRAPH_BASE_URI}/#{facebook_api_version}/#{lead_id}",
        query: {
          fields: LEAD_FIELDS.join(','),
          access_token: access_token
        },
        headers: { 'Accept' => 'application/json' },
        timeout: REQUEST_TIMEOUT
      )
      return {} unless response.respond_to?(:success?) && response.success?

      parsed_response(response)
    rescue StandardError => e
      Rails.logger.warn("Meta lead details fetch failed: #{e.class}: #{e.message}")
      {}
    end

    def access_token_for(lead_form)
      channel = meta_connection_channel(lead_form)
      case channel
      when Channel::FacebookPage
        channel.page_access_token
      when Channel::Instagram
        channel.access_token
      when Channel::Whatsapp
        channel.provider_config.to_h['api_key'] if channel.provider == 'whatsapp_cloud'
      end
    end

    def external_ref_for(change)
      change['leadgen_id'].presence || change['lead_id'].presence || change['id'].presence
    end

    def facebook_api_version
      GlobalConfigService.load('FACEBOOK_API_VERSION', 'v18.0')
    end

    def field_values_for(change)
      raw_fields = change['field_data'] || change['field_values'] || change['fields'] || []
      if raw_fields.is_a?(Array)
        raw_fields.each_with_object({}) do |field, values|
          name = field['name'].presence || field['key'].presence
          next if name.blank?

          value = field['values'].is_a?(Array) ? field['values'].first : field['value']
          values[name] = value
        end
      else
        raw_fields.to_h
      end
    end

    def meta_connection_channel(lead_form)
      inbox_id = lead_form.settings.to_h['meta_connection_inbox_id'].presence
      lead_form.account.inboxes.find_by(id: inbox_id)&.channel
    end

    def normalize_payload(raw_payload)
      raw_payload = raw_payload.to_unsafe_h if raw_payload.respond_to?(:to_unsafe_h)
      raw_payload.to_h.deep_stringify_keys
    end

    def parsed_response(response)
      parsed = response.parsed_response
      return parsed.to_h.deep_stringify_keys if parsed.respond_to?(:to_h)

      JSON.parse(response.body.to_s).deep_stringify_keys
    rescue JSON::ParserError
      {}
    end

    def record_received_stub!(lead_form, change)
      external_ref = external_ref_for(change)
      return if external_ref.blank?

      submission = lead_form.lead_submissions.find_or_initialize_by(external_ref: external_ref)
      submission.assign_attributes(
        account: lead_form.account,
        inbox: lead_form.inbox,
        source_kind: 'meta',
        status: 'received',
        idempotency_key: external_ref,
        field_values: {},
        payload: change,
        processing_errors: {
          'code' => 'META_FIELD_DATA_NOT_FETCHED',
          'message' => 'Webhook delivered only leadgen_id; Graph API details were unavailable.'
        }
      )
      submission.save!
    end

    def resolve_lead_form(change)
      form_id = change['form_id'].presence || change['leadgen_form_id'].presence
      page_id = change['page_id'].presence || change['entry_id'].presence
      scope = LeadForm.active.where(source_kind: 'meta')
      (scope.find_by(external_ref: form_id) if form_id.present?) ||
        (scope.where("settings ->> 'meta_form_id' = ?", form_id).first if form_id.present?) ||
        (scope.where("settings ->> 'meta_page_id' = ?", page_id).first if page_id.present?)
    end

    def submission_params(change)
      {
        external_ref: external_ref_for(change),
        field_values: field_values_for(change),
        payload: change,
        idempotency_key: external_ref_for(change)
      }
    end
  end
end
