# frozen_string_literal: true

module Reports
  class LeadsQuery
    PAID_AD_ATTRIBUTION_TYPES = %w[
      click_to_whatsapp_ad
      click_to_messenger_ad
      click_to_direct_ad
    ].freeze
    MAX_BREAKDOWN_ROWS = 20
    MAX_CREATIVE_ROWS = 50
    MAX_CONVERSATION_ROWS = 200
    MAX_SAMPLED_REFERRALS = 2_000
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
      details = build_meta_ads_details(scope)

      {
        event_count: scope.count,
        unique_contact_count: scope.where.not(contact_id: nil).distinct.count(:contact_id),
        events_without_contact_count: scope.where(contact_id: nil).count,
        explicit_paid_ad_event_count: paid_scope.count,
        other_or_unknown_event_count: scope.count - paid_scope.count,
        unique_ctwa_click_id_count: scope.where.not(ctwa_clid: [nil, '']).distinct.count(:ctwa_clid),
        attribution_breakdown: rows,
        attribution_breakdown_omitted_event_count: scope.count - rows.sum { |row| row[:event_count] }
      }.merge(details)
    end

    def build_meta_ads_details(scope)
      sampled = scope.includes(:contact, :conversation)
                     .order(:received_at, :id)
                     .limit(MAX_SAMPLED_REFERRALS)
                     .to_a

      creatives = build_creatives_breakdown(sampled)
      conversations = build_referral_conversations(sampled)

      {
        meta_ads_summary: {
          chats_count: conversations.size,
          contacts_count: conversations.filter_map { |row| row[:contact_id] }.uniq.size,
          events_count: conversations.sum { |row| row[:event_count] },
          ad_ids_count: creatives.count { |item| item[:ad_id].present? && item[:ad_id] != 'unknown' },
          answered_chats_count: conversations.count { |row| row[:answered] },
          incoming_messages_count: conversations.sum { |row| row[:incoming_count] },
          outgoing_messages_count: conversations.sum { |row| row[:outgoing_count] }
        },
        creatives_breakdown: creatives.first(MAX_CREATIVE_ROWS),
        referral_conversations: conversations.first(MAX_CONVERSATION_ROWS)
      }
    end

    def build_creatives_breakdown(referrals)
      by_ad = {}
      referrals.each do |ref|
        ad_key = ref.ad_id.presence || 'unknown'
        entry = (by_ad[ad_key] ||= {
          ad_id: ad_key,
          headlines: [],
          media_types: [],
          source_urls: [],
          chat_keys: Set.new,
          event_count: 0
        })
        headline = ref.headline.presence || 'Без названия'
        entry[:headlines] << headline unless entry[:headlines].include?(headline)
        entry[:media_types] << ref.media_type if ref.media_type.present? && !entry[:media_types].include?(ref.media_type)
        entry[:source_urls] << ref.source_url if ref.source_url.present? && !entry[:source_urls].include?(ref.source_url)
        entry[:chat_keys] << (ref.conversation_id || "ref:#{ref.id}")
        entry[:event_count] += 1
      end

      by_ad.values.map do |entry|
        {
          ad_id: entry[:ad_id],
          headlines: entry[:headlines],
          media_types: entry[:media_types],
          source_urls: entry[:source_urls],
          chats_count: entry[:chat_keys].size,
          event_count: entry[:event_count]
        }
      end.sort_by { |item| [-item[:chats_count], -item[:event_count], item[:ad_id].to_s] }
    end

    def build_referral_conversations(referrals)
      with_conversation = referrals.select { |ref| ref.conversation_id.present? && ref.conversation.present? }
      return [] if with_conversation.empty?

      conv_ids = with_conversation.map(&:conversation_id).uniq
      msg_counts = fetch_conversation_message_counts(conv_ids)
      min_first_at = with_conversation.filter_map(&:received_at).min
      outgoing_times = fetch_outgoing_message_times(conv_ids, min_first_at)

      by_conv = {}
      with_conversation.each do |ref|
        conv = ref.conversation
        contact = ref.contact || conv.contact
        item = (by_conv[conv.id] ||= {
          conversation_id: conv.id,
          display_id: conv.display_id,
          first_at_time: ref.received_at,
          last_at_time: ref.received_at,
          contact_id: contact&.id,
          contact_name: contact&.name.presence,
          phone: contact&.phone_number.presence,
          ad_ids: [],
          headlines: [],
          media_types: [],
          source_urls: [],
          event_count: 0,
          status: conv.status
        })
        item[:event_count] += 1
        item[:first_at_time] = [item[:first_at_time], ref.received_at].compact.min
        item[:last_at_time] = [item[:last_at_time], ref.received_at].compact.max
        append_unique(item[:ad_ids], ref.ad_id)
        append_unique(item[:headlines], ref.headline.presence || 'Без названия')
        append_unique(item[:media_types], ref.media_type)
        append_unique(item[:source_urls], ref.source_url)
      end

      by_conv.values.map do |item|
        counts = msg_counts[item[:conversation_id]] || { incoming: 0, outgoing: 0 }
        first_at = item[:first_at_time]
        replies = outgoing_times[item[:conversation_id]] || []
        first_reply_at = first_at ? replies.find { |ts| ts >= first_at } : nil
        response_minutes = first_reply_at && first_at ? ((first_reply_at - first_at) / 60.0).round(1) : nil

        {
          conversation_id: item[:conversation_id],
          display_id: item[:display_id],
          first_at: first_at&.iso8601,
          last_at: item[:last_at_time]&.iso8601,
          contact_id: item[:contact_id],
          contact_name: item[:contact_name],
          phone: item[:phone],
          ad_ids: item[:ad_ids],
          headlines: item[:headlines],
          media_types: item[:media_types],
          source_urls: item[:source_urls],
          event_count: item[:event_count],
          incoming_count: counts[:incoming],
          outgoing_count: counts[:outgoing],
          answered: first_reply_at.present?,
          response_minutes: response_minutes,
          status: item[:status]
        }
      end.sort_by { |row| [row[:first_at].to_s, row[:display_id].to_i] }
    end

    def append_unique(list, value)
      val = value.to_s.strip
      return if val.empty? || list.include?(val)

      list << val
    end

    def fetch_conversation_message_counts(conv_ids)
      return {} if conv_ids.empty?

      rows = account.messages
                    .unscope(:order)
                    .where(
                      conversation_id: conv_ids,
                      private: false,
                      created_at: date_range.from_at...date_range.until_at
                    )
                    .group(:conversation_id, :message_type)
                    .count

      result = {}
      rows.each do |(conv_id, msg_type), count|
        entry = (result[conv_id] ||= { incoming: 0, outgoing: 0 })
        if msg_type == 'incoming' || msg_type == 0
          entry[:incoming] += count
        elsif msg_type == 'outgoing' || msg_type == 1
          entry[:outgoing] += count
        end
      end
      result
    end

    def fetch_outgoing_message_times(conv_ids, min_first_at)
      return {} if conv_ids.empty? || min_first_at.nil?

      rows = account.messages
                    .where(
                      conversation_id: conv_ids,
                      message_type: :outgoing,
                      private: false,
                      created_at: min_first_at...date_range.until_at
                    )
                    .order(:created_at)
                    .pluck(:conversation_id, :created_at)

      rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(conv_id, created_at), map|
        map[conv_id] << created_at
      end
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
