# frozen_string_literal: true

module Reports
  class LeadsQuery
    PAID_AD_ATTRIBUTION_TYPES = %w[
      click_to_whatsapp_ad
      click_to_messenger_ad
      click_to_direct_ad
    ].freeze
    MAX_BREAKDOWN_ROWS = 20
    UTM_SQL_FIELDS = {
      'utm_source' => "COALESCE(NULLIF(utm ->> 'utm_source', ''), 'unknown')",
      'utm_campaign' => "COALESCE(NULLIF(utm ->> 'utm_campaign', ''), 'unknown')"
    }.freeze

    attr_reader :account, :params, :date_range

    def initialize(account:, params: {})
      @account = account
      @params = params.to_h.symbolize_keys
      @date_range = DateRange.new(account: account, params: @params)
    end

    def perform
      referral_scope = account.meta_ad_referrals.where(received_at: date_range.from_at...date_range.until_at)
      submission_scope = account.lead_submissions.where(created_at: date_range.from_at...date_range.until_at)

      {
        referrals: referral_summary(referral_scope),
        form_submissions: submission_summary(submission_scope),
        appointment_conversion: LeadAppointmentsQuery.new(account: account, date_range: date_range).perform,
        processing: processing_summary
      }
    end

    def meta
      date_range.meta
    end

    private

    def referral_summary(scope)
      attribution = scope.group(:provider, :attribution_type, :source_type, :referral_type)
                         .order(
                           Arel.sql('COUNT(*) DESC'),
                           :provider,
                           :attribution_type,
                           :source_type,
                           :referral_type
                         )
                         .limit(MAX_BREAKDOWN_ROWS)
                         .count
      rows = attribution.map do |keys, count|
        provider, attribution_type, source_type, referral_type = keys
        {
          provider: provider.presence || 'unknown',
          attribution_type: attribution_type.presence || 'unknown',
          source_type: source_type.presence || 'unknown',
          referral_type: referral_type.presence || 'unknown',
          event_count: count
        }
      end
      paid_scope = scope.where(attribution_type: PAID_AD_ATTRIBUTION_TYPES)

      {
        event_count: scope.count,
        unique_contact_count: scope.where.not(contact_id: nil).distinct.count(:contact_id),
        events_without_contact_count: scope.where(contact_id: nil).count,
        explicit_paid_ad_event_count: paid_scope.count,
        other_or_unknown_event_count: scope.count - paid_scope.count,
        unique_ctwa_click_id_count: scope.where.not(ctwa_clid: [nil, '']).distinct.count(:ctwa_clid),
        attribution_breakdown: rows,
        attribution_breakdown_omitted_event_count: scope.count - rows.sum { |row| row[:event_count] }
      }
    end

    def submission_summary(scope)
      status_counts = scope.group(:source_kind, :status).count
      utm_sources = grouped_utm_values(scope, 'utm_source')
      utm_campaigns = grouped_utm_values(scope, 'utm_campaign')
      form_rows = scope.joins(:lead_form)
                       .group('lead_submissions.lead_form_id', 'lead_forms.name', 'lead_submissions.source_kind')
                       .order(Arel.sql('COUNT(*) DESC'))
                       .limit(MAX_BREAKDOWN_ROWS)
                       .count

      {
        event_count: scope.count,
        unique_contact_count: scope.where.not(contact_id: nil).distinct.count(:contact_id),
        events_without_contact_count: scope.where(contact_id: nil).count,
        source_status_breakdown: status_counts.map do |(source_kind, status), count|
          {
            source_kind: source_kind.presence || 'unknown',
            status: status.presence || 'unknown',
            event_count: count
          }
        end,
        form_breakdown: form_rows.map do |(lead_form_id, form_name, source_kind), count|
          {
            lead_form_id: lead_form_id,
            lead_form_name: form_name.presence || 'unknown',
            source_kind: source_kind.presence || 'unknown',
            event_count: count
          }
        end,
        form_breakdown_omitted_event_count: scope.joins(:lead_form).count -
          form_rows.values.sum
      }.merge(utm_sources).merge(utm_campaigns)
    end

    def grouped_utm_values(scope, field)
      counts = scope.group(Arel.sql(UTM_SQL_FIELDS.fetch(field)))
                    .order(Arel.sql('COUNT(*) DESC'))
                    .limit(MAX_BREAKDOWN_ROWS)
                    .count
      key = field == 'utm_source' ? :utm_source_breakdown : :utm_campaign_breakdown
      omitted_key = if field == 'utm_source'
                      :utm_source_breakdown_omitted_event_count
                    else
                      :utm_campaign_breakdown_omitted_event_count
                    end
      total = scope.count
      {
        key => counts.map { |value, count| { value: value, event_count: count } },
        omitted_key => total - counts.values.sum
      }
    end

    def processing_summary
      submissions = account.lead_submissions.where(created_at: date_range.from_at...date_range.until_at)
      processed_in_period = account.lead_submissions.where(processed_at: date_range.from_at...date_range.until_at)
      processing_seconds = submissions.where.not(processed_at: nil)
                                       .average(Arel.sql('EXTRACT(EPOCH FROM (processed_at - created_at))'))

      {
        submissions_processed_in_selected_period: processed_in_period.count,
        selected_submissions_with_processed_at: submissions.where.not(processed_at: nil).count,
        average_processing_seconds: processing_seconds&.round(1)
      }
    end
  end
end
